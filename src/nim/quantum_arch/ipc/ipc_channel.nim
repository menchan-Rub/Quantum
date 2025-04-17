# ipc_channel.nim
## IPCチャネルモジュール
## 高パフォーマンスかつ安全なプロセス間通信を実現する

import std/[
  os,
  asyncdispatch,
  json,
  tables,
  options,
  strutils,
  strformat,
  streams,
  hashes,
  times,
  logging,
  sequtils,
  algorithm,
  atomics,
  locks
]

# 型定義
type
  MessageType* = enum
    mtRequest,       ## リクエストメッセージ
    mtResponse,      ## レスポンスメッセージ
    mtNotification,  ## 通知メッセージ
    mtSignal,        ## シグナルメッセージ
    mtStream,        ## ストリームデータ
    mtHandshake,     ## ハンドシェイクメッセージ
    mtError          ## エラーメッセージ

  MessagePriority* = enum
    mpLow,           ## 低優先度（バックグラウンド転送）
    mpNormal,        ## 通常優先度
    mpHigh,          ## 高優先度（UI操作など）
    mpCritical       ## 最高優先度（セキュリティ関連など）

  MessageStatus* = enum
    msPending,       ## 送信待ち
    msSending,       ## 送信中
    msDelivered,     ## 配信済み
    msReceived,      ## 受信済み
    msProcessed,     ## 処理済み
    msFailed         ## 失敗

  # シリアライゼーション方式
  SerializationFormat* = enum
    sfJson,          ## JSONシリアライゼーション
    sfBinary,        ## バイナリシリアライゼーション
    sfProtobuf,      ## Protocol Buffersシリアライゼーション
    sfMessagePack    ## MessagePackシリアライゼーション

  # トランスポート方式
  TransportType* = enum
    ttNamedPipe,     ## 名前付きパイプ
    ttSharedMemory,  ## 共有メモリ
    ttSocket,        ## ソケット通信
    ttMessageQueue   ## メッセージキュー

  # メッセージID型
  MessageId* = distinct int64

  # チャネルID型
  ChannelId* = distinct int

  # メッセージ定義
  Message* = ref object
    id*: MessageId                   ## メッセージID
    messageType*: MessageType        ## メッセージ種別
    priority*: MessagePriority       ## 優先度
    senderId*: ChannelId             ## 送信元チャネルID
    receiverId*: ChannelId           ## 受信先チャネルID
    timestamp*: Time                 ## タイムスタンプ
    status*: MessageStatus           ## ステータス
    ttl*: int                        ## 有効期限（ミリ秒）
    route*: string                   ## ルーティングパス
    payload*: JsonNode               ## ペイロード
    isCompressed*: bool              ## 圧縮フラグ
    size*: int                       ## ペイロードサイズ（バイト）
    errorCode*: Option[int]          ## エラーコード
    errorMessage*: Option[string]    ## エラーメッセージ
    headers*: Table[string, string]  ## メタデータヘッダー
    correlationId*: Option[MessageId] ## 関連メッセージID（リクエスト-レスポンス）

  # IPC チャネル設定
  IpcChannelConfig* = object
    bufferSize*: int                  ## バッファサイズ
    timeout*: int                     ## タイムアウト（ミリ秒）
    serialization*: SerializationFormat  ## シリアライゼーション形式
    transport*: TransportType         ## トランスポート方式
    compression*: bool                ## 圧縮有効フラグ
    compressionThreshold*: int        ## 圧縮閾値（バイト）
    encryptionEnabled*: bool          ## 暗号化有効フラグ
    retryCount*: int                  ## 再試行回数
    retryInterval*: int               ## 再試行間隔（ミリ秒）
    validateMessages*: bool           ## メッセージ検証フラグ
    queueSize*: int                   ## キューサイズ
    handshakeTimeout*: int            ## ハンドシェイクタイムアウト（ミリ秒）

  # メッセージハンドラ型
  MessageHandler* = proc(message: Message): Future[void] {.async.}

  # IPC チャネル
  IpcChannel* = ref object
    id*: ChannelId                   ## チャネルID
    name*: string                    ## チャネル名
    config*: IpcChannelConfig        ## 設定
    isOpen*: bool                    ## オープン状態フラグ
    logger*: Logger                  ## ロガー
    connectedChannels*: seq[ChannelId]  ## 接続チャネル
    messageQueue*: seq[Message]      ## メッセージキュー
    handlers*: Table[string, MessageHandler]  ## メッセージハンドラ
    pendingResponses*: Table[MessageId, Future[Message]]  ## 保留中レスポンス
    nextMessageId*: Atomic[int64]    ## 次のメッセージID
    lock*: Lock                      ## 排他制御ロック
    case config.transport*: TransportType
    of ttNamedPipe:
      pipeName*: string              ## パイプ名
      pipeHandle*: FileHandle        ## パイプハンドル
    of ttSharedMemory:
      shmName*: string               ## 共有メモリ名
      shmSize*: int                  ## 共有メモリサイズ
      shmAddress*: pointer           ## 共有メモリアドレス
    of ttSocket:
      host*: string                  ## ホスト
      port*: int                     ## ポート
    of ttMessageQueue:
      queueName*: string             ## キュー名

# ハッシュ関数と等価演算子
proc hash*(id: MessageId): Hash = hash(id.int64)
proc hash*(id: ChannelId): Hash = hash(id.int)

proc `==`*(a, b: MessageId): bool = a.int64 == b.int64
proc `==`*(a, b: ChannelId): bool = a.int == b.int

# デフォルト設定の取得
proc getDefaultIpcConfig*(): IpcChannelConfig =
  ## デフォルトIPC設定を返す
  result.bufferSize = 64 * 1024            # 64KB
  result.timeout = 30000                   # 30秒
  result.serialization = sfJson            # JSON形式
  result.transport = ttNamedPipe           # 名前付きパイプ
  result.compression = true                # 圧縮有効
  result.compressionThreshold = 4096       # 4KB以上で圧縮
  result.encryptionEnabled = true          # 暗号化有効
  result.retryCount = 3                    # 3回再試行
  result.retryInterval = 500               # 500ms間隔
  result.validateMessages = true           # メッセージ検証有効
  result.queueSize = 1000                  # 1000メッセージ
  result.handshakeTimeout = 5000           # 5秒

# 新しいIPCチャネルの作成
proc newIpcChannel*(id: ChannelId, name: string = "", config: IpcChannelConfig = getDefaultIpcConfig()): IpcChannel =
  ## 新しいIPCチャネルを作成する
  new(result)
  result.id = id
  result.name = if name == "": "channel-" & $id.int else: name
  result.config = config
  result.isOpen = false
  result.logger = newConsoleLogger()
  result.connectedChannels = @[]
  result.messageQueue = @[]
  result.handlers = initTable[string, MessageHandler]()
  result.pendingResponses = initTable[MessageId, Future[Message]]()
  result.nextMessageId = initAtomic(1)
  initLock(result.lock)

  # トランスポート種別に応じた初期化
  case config.transport
  of ttNamedPipe:
    result.pipeName = "ipc_" & $id.int
  of ttSharedMemory:
    result.shmName = "ipc_shm_" & $id.int
    result.shmSize = config.bufferSize * 10
  of ttSocket:
    result.host = "127.0.0.1"
    result.port = 8000 + id.int mod 1000  # 簡易的なポート割り当て
  of ttMessageQueue:
    result.queueName = "ipc_queue_" & $id.int

# プロセスIDからのチャネル作成
proc newIpcChannel*(processId: int): IpcChannel =
  ## プロセスIDを使用してチャネルIDを生成し、新しいIPCチャネルを作成する
  newIpcChannel(ChannelId(processId))
# チャネルのオープン
proc open*(channel: IpcChannel): Future[bool] {.async.} =
  ## チャネルをオープンする
  if channel.isOpen:
    return true

  try:
    # トランスポート種別に応じた初期化処理
    case channel.config.transport
    of ttNamedPipe:
      # 名前付きパイプの作成
      channel.logger.log(lvlInfo, "名前付きパイプを作成: " & channel.pipeName)
      when defined(windows):
        let pipePath = r"\\.\pipe\" & channel.pipeName
        channel.pipeHandle = createNamedPipe(
          pipePath,
          PIPE_ACCESS_DUPLEX,
          PIPE_TYPE_MESSAGE or PIPE_READMODE_MESSAGE or PIPE_WAIT,
          PIPE_UNLIMITED_INSTANCES,
          channel.config.bufferSize.DWORD,
          channel.config.bufferSize.DWORD,
          0,
          nil
        )
        if channel.pipeHandle == INVALID_HANDLE_VALUE:
          raise newException(IOError, "名前付きパイプの作成に失敗: " & $getLastError())
      elif defined(posix):
        let pipePath = "/tmp/" & channel.pipeName
        if mkfifo(pipePath, 0o666) != 0 and errno != EEXIST:
          raise newException(IOError, "名前付きパイプの作成に失敗: " & $strerror(errno))
        channel.pipeFd = open(pipePath, O_RDWR or O_NONBLOCK)
        if channel.pipeFd < 0:
          raise newException(IOError, "パイプのオープンに失敗: " & $strerror(errno))
      else:
        raise newException(OSError, "未サポートのプラットフォーム")
    
    of ttSharedMemory:
      # 共有メモリセグメントの作成
      channel.logger.log(lvlInfo, "共有メモリを作成: " & channel.shmName & " サイズ: " & $channel.shmSize)
      when defined(windows):
        channel.shmHandle = createFileMapping(
          INVALID_HANDLE_VALUE,
          nil,
          PAGE_READWRITE,
          0,
          channel.shmSize.DWORD,
          channel.shmName
        )
        if channel.shmHandle == 0:
          raise newException(IOError, "共有メモリの作成に失敗: " & $getLastError())
        
        channel.shmAddress = mapViewOfFile(
          channel.shmHandle,
          FILE_MAP_ALL_ACCESS,
          0,
          0,
          channel.shmSize
        )
        if channel.shmAddress == nil:
          CloseHandle(channel.shmHandle)
          raise newException(IOError, "共有メモリのマッピングに失敗: " & $getLastError())
      elif defined(posix):
        channel.shmFd = shm_open(
          channel.shmName,
          O_CREAT or O_RDWR,
          S_IRUSR or S_IWUSR
        )
        if channel.shmFd < 0:
          raise newException(IOError, "共有メモリのオープンに失敗: " & $strerror(errno))
        
        if ftruncate(channel.shmFd, channel.shmSize) != 0:
          close(channel.shmFd)
          raise newException(IOError, "共有メモリのサイズ設定に失敗: " & $strerror(errno))
        
        channel.shmAddress = mmap(
          nil,
          channel.shmSize,
          PROT_READ or PROT_WRITE,
          MAP_SHARED,
          channel.shmFd,
          0
        )
        if channel.shmAddress == MAP_FAILED:
          close(channel.shmFd)
          raise newException(IOError, "共有メモリのマッピングに失敗: " & $strerror(errno))
      else:
        raise newException(OSError, "未サポートのプラットフォーム")
      
      # 共有メモリヘッダの初期化
      let header = cast[ptr ShmHeader](channel.shmAddress)
      header.magic = SHM_MAGIC
      header.version = SHM_VERSION
      header.readOffset = sizeof(ShmHeader).uint32
      header.writeOffset = sizeof(ShmHeader).uint32
      header.messageCount = 0
      initLock(header.lock)
    
    of ttSocket:
      # ソケットの設定
      channel.logger.log(lvlInfo, "ソケットを設定: " & channel.host & ":" & $channel.port)
      channel.socket = newAsyncSocket()
      try:
        await channel.socket.bindAddr(Port(channel.port), channel.host)
        await channel.socket.listen()
        # 接続受付スレッドの開始
        channel.acceptThread = createThread(acceptConnectionsThread, channel)
      except:
        if not channel.socket.isNil:
          channel.socket.close()
        raise getCurrentException()
    
    of ttMessageQueue:
      # メッセージキューの作成
      channel.logger.log(lvlInfo, "メッセージキューを作成: " & channel.queueName)
      when defined(windows):
        channel.mqHandle = createMessageQueue(
          channel.queueName,
          channel.config.queueSize,
          channel.config.bufferSize
        )
        if channel.mqHandle == INVALID_HANDLE_VALUE:
          raise newException(IOError, "メッセージキューの作成に失敗: " & $getLastError())
      elif defined(posix):
        let attr = newMessageQueueAttr()
        attr.mq_flags = 0
        attr.mq_maxmsg = channel.config.queueSize.clong
        attr.mq_msgsize = channel.config.bufferSize.clong
        attr.mq_curmsgs = 0
        
        channel.mqFd = mq_open(
          channel.queueName,
          O_CREAT or O_RDWR or O_NONBLOCK,
          S_IRUSR or S_IWUSR or S_IRGRP or S_IWGRP,
          attr
        )
        if channel.mqFd == -1:
          raise newException(IOError, "メッセージキューの作成に失敗: " & $strerror(errno))
      else:
        raise newException(OSError, "未サポートのプラットフォーム")
    
    # 暗号化が有効な場合は鍵を初期化
    if channel.config.encryptionEnabled:
      channel.encryptionKey = generateEncryptionKey()
      channel.iv = generateRandomIV()
    
    # メッセージ処理スレッドの開始
    channel.processingThread = createThread(processMessagesThread, channel)
    
    # ハンドシェイク処理の実行
    if not await channel.performHandshake():
      raise newException(IOError, "ハンドシェイクに失敗しました")
    
    channel.isOpen = true
    channel.logger.log(lvlInfo, "チャネルオープン成功: " & channel.name)
    return true
  except:
    channel.logger.log(lvlError, "チャネルオープンエラー: " & getCurrentExceptionMsg())
    return false

# チャネルのクローズ
proc close*(channel: IpcChannel): Future[void] {.async.} =
  ## チャネルをクローズする
  if not channel.isOpen:
    return

  try:
    # リソース解放
    case channel.config.transport
    of ttNamedPipe:
      # closeHandle(channel.pipeHandle)
      discard
    of ttSharedMemory:
      # unmapSharedMemory(channel.shmAddress, channel.shmSize)
      discard
    of ttSocket:
      # closeSocket(...)
      discard
    of ttMessageQueue:
      # closeMessageQueue(...)
      discard
    
    # 保留中のレスポンスをキャンセル
    for id, future in channel.pendingResponses:
      if not future.finished:
        future.fail(newException(IOError, "Channel closed"))
    
    channel.isOpen = false
    channel.logger.log(lvlInfo, "チャネルクローズ: " & channel.name)
  
  except:
    channel.logger.log(lvlError, "チャネルクローズエラー: " & getCurrentExceptionMsg())

# 新しいメッセージの作成
proc newMessage*(
  channel: IpcChannel,
  messageType: MessageType,
  route: string,
  payload: JsonNode,
  receiverId: ChannelId,
  priority: MessagePriority = mpNormal
): Message =
  ## 新しいメッセージを作成する
  result = Message(
    id: MessageId(channel.nextMessageId.fetchAdd(1)),
    messageType: messageType,
    priority: priority,
    senderId: channel.id,
    receiverId: receiverId,
    timestamp: getTime(),
    status: msPending,
    ttl: 60000,  # デフォルト1分
    route: route,
    payload: payload,
    isCompressed: false,
    size: 0,  # 後で計算
    errorCode: none(int),
    errorMessage: none(string),
    headers: initTable[string, string](),
    correlationId: none(MessageId)
  )
  
  # ペイロードサイズを概算
  if payload != nil:
    result.size = ($payload).len

# メッセージの送信
proc sendMessage*(channel: IpcChannel, message: Message): Future[void] {.async.} =
  ## メッセージを送信する
  if not channel.isOpen:
    raise newException(IOError, "Channel is not open")
  
  # 送信前の状態更新
  message.status = msSending
  
  # 圧縮処理
  if channel.config.compression and message.size >= channel.config.compressionThreshold:
    # 実際の実装では圧縮処理を行う
    # message.payload = compress(message.payload)
    message.isCompressed = true
  
  # シリアライズ
  var serializedData: string
  case channel.config.serialization
  of sfJson:
    # JSON形式に変換
    var msgObj = %*{
      "id": message.id.int64,
      "type": $message.messageType,
      "priority": $message.priority,
      "sender": message.senderId.int,
      "receiver": message.receiverId.int,
      "timestamp": $message.timestamp,
      "ttl": message.ttl,
      "route": message.route,
      "payload": message.payload,
      "compressed": message.isCompressed,
      "size": message.size,
      "headers": newJObject()
    }
    
    # ヘッダーの追加
    for key, value in message.headers:
      msgObj["headers"][key] = %value
    
    # エラー情報の追加
    if message.errorCode.isSome:
      msgObj["errorCode"] = %message.errorCode.get()
    if message.errorMessage.isSome:
      msgObj["errorMessage"] = %message.errorMessage.get()
    
    # 関連IDの追加
    if message.correlationId.isSome:
      msgObj["correlationId"] = %message.correlationId.get().int64
    
    serializedData = $msgObj
  
  of sfBinary:
    # バイナリシリアライズ形式
    var buffer = newStringOfCap(1024)
    buffer.add(pack(message.id.int64))
    buffer.add(pack(ord(message.messageType)))
    buffer.add(pack(ord(message.priority)))
    buffer.add(pack(message.senderId.int))
    buffer.add(pack(message.receiverId.int))
    buffer.add(pack(message.timestamp))
    buffer.add(pack(message.ttl))
    buffer.add(pack(message.route.len))
    buffer.add(message.route)
    
    # ペイロードの追加
    let payloadStr = if message.payload != nil: $message.payload else: ""
    buffer.add(pack(payloadStr.len))
    buffer.add(payloadStr)
    
    # 圧縮フラグとサイズ
    buffer.add(pack(ord(message.isCompressed)))
    buffer.add(pack(message.size))
    
    # ヘッダー数とヘッダー内容
    buffer.add(pack(message.headers.len))
    for key, value in message.headers:
      buffer.add(pack(key.len))
      buffer.add(key)
      buffer.add(pack(value.len))
      buffer.add(value)
    
    # エラー情報
    buffer.add(pack(message.errorCode.isSome))
    if message.errorCode.isSome:
      buffer.add(pack(message.errorCode.get()))
    
    buffer.add(pack(message.errorMessage.isSome))
    if message.errorMessage.isSome:
      let errMsg = message.errorMessage.get()
      buffer.add(pack(errMsg.len))
      buffer.add(errMsg)
    
    # 関連ID
    buffer.add(pack(message.correlationId.isSome))
    if message.correlationId.isSome:
      buffer.add(pack(message.correlationId.get().int64))
    
    serializedData = buffer
  
  of sfProtobuf:
    # Protobufシリアライズ形式
    var pb = initProtoBuffer()
    pb.writeInt64(1, message.id.int64)
    pb.writeEnum(2, ord(message.messageType))
    pb.writeEnum(3, ord(message.priority))
    pb.writeInt32(4, message.senderId.int)
    pb.writeInt32(5, message.receiverId.int)
    pb.writeInt64(6, message.timestamp)
    pb.writeInt32(7, message.ttl)
    pb.writeString(8, message.route)
    
    # ペイロード
    if message.payload != nil:
      pb.writeString(9, $message.payload)
    
    pb.writeBool(10, message.isCompressed)
    pb.writeInt32(11, message.size)
    
    # ヘッダー
    for key, value in message.headers:
      let headerMsg = initProtoBuffer()
      headerMsg.writeString(1, key)
      headerMsg.writeString(2, value)
      pb.writeMessage(12, headerMsg)
    
    # エラー情報
    if message.errorCode.isSome:
      pb.writeInt32(13, message.errorCode.get())
    
    if message.errorMessage.isSome:
      pb.writeString(14, message.errorMessage.get())
    
    # 関連ID
    if message.correlationId.isSome:
      pb.writeInt64(15, message.correlationId.get().int64)
    
    serializedData = pb.finish()
  
  of sfMessagePack:
    # MessagePackシリアライズ形式
    var packer = initMsgPack()
    packer.pack_map(12 + 
                    (if message.errorCode.isSome: 1 else: 0) + 
                    (if message.errorMessage.isSome: 1 else: 0) + 
                    (if message.correlationId.isSome: 1 else: 0))
    
    packer.pack_str("id")
    packer.pack_int(message.id.int64)
    
    packer.pack_str("type")
    packer.pack_int(ord(message.messageType))
    
    packer.pack_str("priority")
    packer.pack_int(ord(message.priority))
    
    packer.pack_str("sender")
    packer.pack_int(message.senderId.int)
    
    packer.pack_str("receiver")
    packer.pack_int(message.receiverId.int)
    
    packer.pack_str("timestamp")
    packer.pack_int(message.timestamp)
    
    packer.pack_str("ttl")
    packer.pack_int(message.ttl)
    
    packer.pack_str("route")
    packer.pack_str(message.route)
    
    packer.pack_str("payload")
    if message.payload != nil:
      packer.pack_str($message.payload)
    else:
      packer.pack_nil()
    
    packer.pack_str("compressed")
    packer.pack_bool(message.isCompressed)
    
    packer.pack_str("size")
    packer.pack_int(message.size)
    
    # ヘッダー
    packer.pack_str("headers")
    packer.pack_map(message.headers.len)
    for key, value in message.headers:
      packer.pack_str(key)
      packer.pack_str(value)
    
    # エラー情報
    if message.errorCode.isSome:
      packer.pack_str("errorCode")
      packer.pack_int(message.errorCode.get())
    
    if message.errorMessage.isSome:
      packer.pack_str("errorMessage")
      packer.pack_str(message.errorMessage.get())
    
    # 関連ID
    if message.correlationId.isSome:
      packer.pack_str("correlationId")
      packer.pack_int(message.correlationId.get().int64)
    
    serializedData = packer.getBytes()
  
  # 暗号化（実際の実装では適切な暗号化処理）
  if channel.config.encryptionEnabled:
    # serializedData = encrypt(serializedData)
    discard
  
  # トランスポート種別に応じた送信処理
  case channel.config.transport
  of ttNamedPipe:
    # 名前付きパイプに書き込み
    # writeToPipe(channel.pipeHandle, serializedData)
    await sleepAsync(10)  # デモ用の遅延
  
  of ttSharedMemory:
    # 共有メモリに書き込み
    # writeToSharedMemory(channel.shmAddress, serializedData)
    await sleepAsync(5)  # デモ用の遅延
  
  of ttSocket:
    # ソケットで送信
    # send(socket, serializedData)
    await sleepAsync(15)  # デモ用の遅延
  
  of ttMessageQueue:
    # メッセージキューに送信
    # sendToQueue(channel.queueName, serializedData)
    await sleepAsync(8)  # デモ用の遅延
  
  # 送信完了後の状態更新
  message.status = msDelivered
  channel.logger.log(lvlDebug, "メッセージ送信完了: " & $message.id.int64 & " ルート: " & message.route)
  ## リクエストを送信し、レスポンスを待機する
  if not channel.isOpen:
    raise newException(IOError, "Channel is not open")
  
  # タイムアウトの設定
  let actualTimeout = if timeout < 0: channel.config.timeout else: timeout
  
  # リクエストメッセージの作成
  let request = newMessage(
    channel,
    mtRequest,
    route,
    payload,
    receiverId,
    priority
  )
  
  # レスポンス用のFutureを作成
  var responseFuture = newFuture[Message]("ipc.sendRequest")
  
  # 保留中レスポンステーブルに追加
  withLock(channel.lock):
    channel.pendingResponses[request.id] = responseFuture
  
  # リクエスト送信
  try:
    await channel.sendMessage(request)
    
    # タイムアウト処理
    let timeoutFuture = sleepAsync(actualTimeout)
    await race(responseFuture, timeoutFuture)
    
    if not responseFuture.finished:
      # タイムアウト
      withLock(channel.lock):
        channel.pendingResponses.del(request.id)
      responseFuture.fail(newException(TimeoutError, "Request timed out"))
    
    return await responseFuture
  
  except:
    # エラー処理
    withLock(channel.lock):
      channel.pendingResponses.del(request.id)
    raise

# 通知の送信（レスポンス不要）
proc sendNotification*(
  channel: IpcChannel,
  route: string,
  payload: JsonNode,
  receiverId: ChannelId,
  priority: MessagePriority = mpNormal
): Future[void] {.async.} =
  ## 通知メッセージを送信する（レスポンス不要）
  if not channel.isOpen:
    raise newException(IOError, "Channel is not open")
  
  # 通知メッセージの作成
  let notification = newMessage(
    channel,
    mtNotification,
    route,
    payload,
    receiverId,
    priority
  )
  
  # 送信
  await channel.sendMessage(notification)

# レスポンス送信
proc sendResponse*(
  channel: IpcChannel,
  requestId: MessageId,
  payload: JsonNode,
  receiverId: ChannelId,
  isError: bool = false,
  errorCode: Option[int] = none(int),
  errorMessage: Option[string] = none(string)
): Future[void] {.async.} =
  ## リクエストに対するレスポンスを送信する
  if not channel.isOpen:
    raise newException(IOError, "Channel is not open")
  
  # レスポンスメッセージの作成
  let response = newMessage(
    channel,
    if isError: mtError else: mtResponse,
    "",  # ルートは空（リクエスト元に自動ルーティング）
    payload,
    receiverId
  )
  
  # 関連ID設定
  response.correlationId = some(requestId)
  
  # エラー情報の設定
  if isError:
    response.errorCode = errorCode
    response.errorMessage = errorMessage
  
  # 送信
  await channel.sendMessage(response)

# メッセージハンドラの登録
proc registerHandler*(channel: IpcChannel, route: string, handler: MessageHandler) =
  ## 特定ルートのメッセージハンドラを登録する
  withLock(channel.lock):
    channel.handlers[route] = handler
    channel.logger.log(lvlInfo, "ハンドラ登録: " & route)

# メッセージハンドラの解除
proc unregisterHandler*(channel: IpcChannel, route: string) =
  ## ハンドラの登録を解除する
  withLock(channel.lock):
    if route in channel.handlers:
      channel.handlers.del(route)
      channel.logger.log(lvlInfo, "ハンドラ登録解除: " & route)

# 受信メッセージの処理
proc processIncomingMessage*(channel: IpcChannel, messageData: string): Future[void] {.async.} =
  ## 受信したメッセージを処理する
  try:
    # メッセージのデシリアライズ
    let msgObj = parseJson(messageData)
    
    # メッセージオブジェクトの構築
    var message = Message(
      id: MessageId(msgObj["id"].getInt()),
      messageType: parseEnum[MessageType](msgObj["type"].getStr()),
      priority: parseEnum[MessagePriority](msgObj["priority"].getStr()),
      senderId: ChannelId(msgObj["sender"].getInt()),
      receiverId: ChannelId(msgObj["receiver"].getInt()),
      timestamp: parseTime(msgObj["timestamp"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc()),
      status: msReceived,
      ttl: msgObj["ttl"].getInt(),
      route: msgObj["route"].getStr(),
      payload: msgObj["payload"],
      isCompressed: msgObj["compressed"].getBool(),
      size: msgObj["size"].getInt(),
      headers: initTable[string, string]()
    )
    
    # ヘッダーの解析
    if "headers" in msgObj and msgObj["headers"].kind == JObject:
      for key, value in msgObj["headers"].fields:
        message.headers[key] = value.getStr()
    
    # エラー情報の解析
    if "errorCode" in msgObj:
      message.errorCode = some(msgObj["errorCode"].getInt())
    
    if "errorMessage" in msgObj:
      message.errorMessage = some(msgObj["errorMessage"].getStr())
    
    # 関連IDの解析
    if "correlationId" in msgObj:
      message.correlationId = some(MessageId(msgObj["correlationId"].getInt()))
    
    # メッセージ種別に応じた処理
    case message.messageType
    of mtResponse, mtError:
      # レスポンスの処理
      if message.correlationId.isSome:
        let requestId = message.correlationId.get()
        withLock(channel.lock):
          if requestId in channel.pendingResponses:
            let future = channel.pendingResponses[requestId]
            channel.pendingResponses.del(requestId)
            if not future.finished:
              if message.messageType == mtError:
                let errorMsg = if message.errorMessage.isSome: message.errorMessage.get() else: "Unknown error"
                future.fail(newException(IOError, errorMsg))
              else:
                future.complete(message)
    
  )
  
  # 関連ID設定
  response.correlationId = some(requestId)
  
  # エラー情報の設定
  if isError:
    response.errorCode = errorCode
    response.errorMessage = errorMessage
  
  # 送信
  await channel.sendMessage(response)

# メッセージハンドラの登録
proc registerHandler*(channel: IpcChannel, route: string, handler: MessageHandler) =
  ## 特定ルートのメッセージハンドラを登録する
  withLock(channel.lock):
    channel.handlers[route] = handler
    channel.logger.log(lvlInfo, "ハンドラ登録: " & route)

# メッセージハンドラの解除
proc unregisterHandler*(channel: IpcChannel, route: string) =
  ## ハンドラの登録を解除する
  withLock(channel.lock):
    if route in channel.handlers:
      channel.handlers.del(route)
      channel.logger.log(lvlInfo, "ハンドラ登録解除: " & route)

# 受信メッセージの処理
proc processIncomingMessage*(channel: IpcChannel, messageData: string): Future[void] {.async.} =
  ## 受信したメッセージを処理する
  try:
    # メッセージのデシリアライズ
    let msgObj = parseJson(messageData)
    
    # メッセージオブジェクトの構築
    var message = Message(
      id: MessageId(msgObj["id"].getInt()),
      messageType: parseEnum[MessageType](msgObj["type"].getStr()),
      priority: parseEnum[MessagePriority](msgObj["priority"].getStr()),
      senderId: ChannelId(msgObj["sender"].getInt()),
      receiverId: ChannelId(msgObj["receiver"].getInt()),
      timestamp: parseTime(msgObj["timestamp"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc()),
      status: msReceived,
      ttl: msgObj["ttl"].getInt(),
      route: msgObj["route"].getStr(),
      payload: msgObj["payload"],
      isCompressed: msgObj["compressed"].getBool(),
      size: msgObj["size"].getInt(),
      headers: initTable[string, string]()
    )
    
    # ヘッダーの解析
    if "headers" in msgObj and msgObj["headers"].kind == JObject:
      for key, value in msgObj["headers"].fields:
        message.headers[key] = value.getStr()
    
    # エラー情報の解析

# チャネル間の接続確立
proc connect*(channel: IpcChannel, targetId: ChannelId): Future[bool] {.async.} =
  ## 他のチャネルとの接続を確立する
  if not channel.isOpen:
    await channel.open()
  
  # 既に接続済みかチェック
  for id in channel.connectedChannels:
    if id == targetId:
      return true
  
  try:
    # ハンドシェイクメッセージの送信
    let handshakePayload = %*{
      "version": "1.0",
      "channelId": channel.id.int,
      "name": channel.name,
      "timestamp": $getTime()
    }
    
    let handshakeMsg = newMessage(
      channel,
      mtHandshake,
      "system.handshake",
      handshakePayload,
      targetId,
      mpHigh
    )
    
    await channel.sendMessage(handshakeMsg)
    
    # 接続先リストに追加
    channel.connectedChannels.add(targetId)
    channel.logger.log(lvlInfo, "チャネル接続確立: " & $channel.id.int & " -> " & $targetId.int)
    
    return true
  
  except:
    channel.logger.log(lvlError, "チャネル接続失敗: " & getCurrentExceptionMsg())
    return false

# 切断処理
proc disconnect*(channel: IpcChannel, targetId: ChannelId): Future[void] {.async.} =
  ## 接続を切断する
  try:
    # 切断通知の送信
    let disconnectPayload = %*{
      "channelId": channel.id.int,
      "reason": "Disconnected by user",
      "timestamp": $getTime()
    }
    
    let disconnectMsg = newMessage(
      channel,
      mtNotification,
      "system.disconnect",
      disconnectPayload,
      targetId
    )
    
    await channel.sendMessage(disconnectMsg)
    
    # 接続先リストから削除
    channel.connectedChannels.keepItIf(it != targetId)
    channel.logger.log(lvlInfo, "チャネル切断: " & $channel.id.int & " -> " & $targetId.int)
  
  except:
    channel.logger.log(lvlError, "チャネル切断エラー: " & getCurrentExceptionMsg())

# メッセージキューのフラッシュ処理
proc flushQueue*(channel: IpcChannel): Future[void] {.async.} =
  ## 送信キューのメッセージを一括送信する
  if not channel.isOpen:
    return
  
  var messagesToSend: seq[Message]
  
  # キューからメッセージを取り出し
  withLock(channel.lock):
    messagesToSend = channel.messageQueue
    channel.messageQueue = @[]
  
  # 優先度でソート
  messagesToSend.sort do (a, b: Message) -> int:
    case a.priority
    of mpCritical: -3
    of mpHigh: -2
    of mpNormal: -1
    of mpLow: 0
    ord(a.priority) - ord(b.priority)
  
  # メッセージ送信
  for msg in messagesToSend:
    try:
      await channel.sendMessage(msg)
    except:
      channel.logger.log(lvlError, "キューメッセージ送信エラー: " & getCurrentExceptionMsg())
      
      # エラーの場合、再キューイング
      withLock(channel.lock):
        if channel.messageQueue.len < channel.config.queueSize:
          channel.messageQueue.add(msg)

# キューにメッセージを追加
proc queueMessage*(channel: IpcChannel, message: Message) =
  ## メッセージをキューに追加する
  withLock(channel.lock):
    if channel.messageQueue.len < channel.config.queueSize:
      channel.messageQueue.add(message)
      channel.logger.log(lvlDebug, "メッセージをキューに追加: " & $message.id.int64)
    else:
      channel.logger.log(lvlWarn, "メッセージキューが満杯: " & $message.id.int64)

# チャネル状態のJSON変換
proc toJson*(channel: IpcChannel): JsonNode =
  ## チャネル情報をJSONに変換する
  result = %*{
    "id": channel.id.int,
    "name": channel.name,
    "isOpen": channel.isOpen,
    "transport": $channel.config.transport,
    "serialization": $channel.config.serialization,
    "compression": channel.config.compression,
    "encryption": channel.config.encryptionEnabled,
    "connectedChannels": channel.connectedChannels.mapIt(it.int),
    "queueSize": channel.messageQueue.len,
    "handlers": channel.handlers.keys.toSeq,
    "pendingResponses": channel.pendingResponses.len
  }

# リソース解放
proc dispose*(channel: IpcChannel) {.async.} =
  ## リソースを解放する
  if channel.isOpen:
    await channel.close()
  
  deinitLock(channel.lock)

# メイン処理関数例 (テスト用)
when isMainModule:
  # チャネルの作成と初期化
  let channel1 = newIpcChannel(ChannelId(1), "test-channel-1")
  let channel2 = newIpcChannel(ChannelId(2), "test-channel-2")
  
  # メッセージハンドラの登録
  channel2.registerHandler "test.echo", proc(message: Message): Future[void] {.async.} =
    echo "メッセージ受信: ", message.payload
    
    # エコーレスポンスを返す
    if message.messageType == mtRequest:
      await channel2.sendResponse(
        message.id,
        message.payload,  # 同じペイロードをエコー
        message.senderId
      )
  
  # チャネルをオープン
  asyncCheck channel1.open()
  asyncCheck channel2.open()
  
  # 少し遅延を入れる
  waitFor sleepAsync(100)
  
  # チャネル間の接続確立
  asyncCheck channel1.connect(channel2.id)
  
  # テストリクエストの送信
  proc testRequest() {.async.} =
    try:
      let payload = %*{
        "message": "こんにちは、IPCチャネル",
        "timestamp": $getTime()
      }
      
      let response = await channel1.sendRequest(
        "test.echo",
        payload,
        channel2.id
      )
      
      echo "レスポンス受信: ", response.payload
    except:
      echo "エラー: ", getCurrentExceptionMsg()
  
  # テスト実行
  waitFor testRequest()
  
  # チャネルのクローズ
  asyncCheck channel1.close()
  asyncCheck channel2.close()
  
  # 少し待機して終了
  waitFor sleepAsync(100) 