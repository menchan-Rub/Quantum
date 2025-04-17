# ipc_manager.nim
## プロセス間通信マネージャモジュール
## 
## このモジュールはブラウザの各プロセス間通信を管理する中心的なコンポーネントです。
## 高速なデータ転送と効率的なメッセージング機能を提供します。

import std/[
  os,
  strutils,
  strformat,
  tables,
  sets,
  options,
  asyncdispatch,
  json,
  locks,
  hashes,
  times,
  streams,
  uri
]

type
  ChannelMode* = enum
    ## 通信チャネルのモード
    cmRead = "read",              # 読み取り専用
    cmWrite = "write",            # 書き込み専用
    cmReadWrite = "readwrite",    # 読み書き両方
    cmDuplex = "duplex"           # 双方向独立

  ConnectionStatus* = enum
    ## 接続ステータス
    csInitializing = "initializing",  # 初期化中
    csConnecting = "connecting",      # 接続中
    csConnected = "connected",        # 接続済み
    csDisconnecting = "disconnecting", # 切断中
    csDisconnected = "disconnected",  # 切断済み
    csError = "error"                # エラー状態

  ProcessType* = enum
    ## プロセスの種類
    ptMain = "main",              # メインプロセス
    ptRenderer = "renderer",      # レンダリングプロセス
    ptNetwork = "network",        # ネットワークプロセス
    ptUtility = "utility",        # ユーティリティプロセス
    ptExtension = "extension",    # 拡張機能プロセス
    ptGPU = "gpu",                # GPUプロセス
    ptStorage = "storage",        # ストレージプロセス
    ptAudio = "audio",            # オーディオプロセス
    ptCustom = "custom"           # カスタムプロセス

  MessagePriority* = enum
    ## メッセージの優先度
    mpLow = "low",                # 低優先度
    mpNormal = "normal",          # 通常優先度
    mpHigh = "high",              # 高優先度
    mpCritical = "critical"       # 最高優先度

  MessageType* = enum
    ## メッセージの種類
    mtRequest = "request",        # リクエスト
    mtResponse = "response",      # レスポンス
    mtEvent = "event",            # イベント
    mtError = "error",            # エラー
    mtCommand = "command",        # コマンド
    mtStream = "stream",          # ストリームデータ
    mtBinary = "binary",          # バイナリデータ
    mtCustom = "custom"           # カスタム

  TransportType* = enum
    ## 通信トランスポートの種類
    ttUnixSocket = "unix_socket",   # Unixソケット
    ttPipe = "pipe",                # 名前付きパイプ
    ttSharedMemory = "shared_mem",  # 共有メモリ
    ttTCP = "tcp",                  # TCPソケット
    ttWebSocket = "websocket",      # WebSocket
    ttCustom = "custom"             # カスタム実装

  SecurityLevel* = enum
    ## セキュリティレベル
    slNone = "none",              # セキュリティなし
    slBasic = "basic",            # 基本的なセキュリティ
    slEncrypted = "encrypted",    # 暗号化通信
    slIsolated = "isolated",      # 完全分離
    slSecure = "secure"           # 最高セキュリティ

  IPCError* = object of CatchableError
    ## IPC関連エラー
    code*: int                   # エラーコード

  IPCTimeoutError* = object of IPCError
    ## タイムアウトエラー

  IPCMessage* = ref object
    ## IPCメッセージ
    id*: string                  # メッセージID
    sourceId*: string            # 送信元ID
    targetId*: string            # 宛先ID
    messageType*: MessageType    # メッセージタイプ
    priority*: MessagePriority   # 優先度
    timestamp*: Time             # タイムスタンプ
    payload*: JsonNode           # データ内容
    replyTo*: Option[string]     # 返信先ID
    ttl*: int                    # Time to Live
    headers*: Table[string, string]  # メタデータ

  IPCChannel* = ref object
    ## IPC通信チャネル
    id*: string                  # チャネルID
    mode*: ChannelMode           # モード
    transport*: TransportType    # トランスポート種類
    status*: ConnectionStatus    # ステータス
    securityLevel*: SecurityLevel # セキュリティレベル
    processType*: ProcessType    # プロセスタイプ
    isBlocking*: bool            # ブロッキングモード
    readBuffer*: seq[byte]       # 読み込みバッファ
    writeBuffer*: seq[byte]      # 書き込みバッファ
    lock*: Lock                  # 同期ロック
    handlers*: Table[string, proc(msg: IPCMessage): Future[void] {.async.}]
    errorHandler*: proc(err: ref IPCError): Future[void] {.async.}
    connectionHandler*: proc(status: ConnectionStatus): Future[void] {.async.}

  IPCManager* = ref object
    ## IPCマネージャ
    instanceId*: string          # インスタンスID
    processType*: ProcessType    # プロセスタイプ
    channels*: Table[string, IPCChannel]  # チャネルテーブル
    defaultTransport*: TransportType  # デフォルトトランスポート
    activeConnections*: HashSet[string]  # アクティブ接続
    isRunning*: bool             # 実行中フラグ
    mainLock*: Lock              # メインロック
    messageCounter*: int         # メッセージカウンタ
    globalHandlers*: Table[string, proc(msg: IPCMessage): Future[void] {.async.}]
    errorHandler*: proc(err: ref IPCError): Future[void] {.async.}
    discoveryEnabled*: bool      # ディスカバリー有効
    pendingResponses*: Table[string, Future[IPCMessage]]  # 保留中のレスポンス
    statistics*: IPCStatistics   # 統計情報
    maxQueueSize*: int           # 最大キューサイズ
    defaultTimeout*: int         # デフォルトタイムアウト（ミリ秒）
    config*: IPCConfig           # 設定

  IPCStatistics* = ref object
    ## IPC統計情報
    messagesSent*: int           # 送信メッセージ数
    messagesReceived*: int       # 受信メッセージ数
    bytesTransferred*: int64     # 転送バイト数
    errors*: int                 # エラー数
    activeChannels*: int         # アクティブチャネル数
    avgResponseTime*: float      # 平均応答時間
    startTime*: Time             # 開始時間

  IPCConfig* = ref object
    ## IPC設定
    bufferSize*: int             # バッファサイズ
    maxConnections*: int         # 最大接続数
    autoReconnect*: bool         # 自動再接続
    reconnectInterval*: int      # 再接続間隔（ミリ秒）
    heartbeatInterval*: int      # ハートビート間隔（ミリ秒）
    compressionEnabled*: bool    # 圧縮有効
    encryptionEnabled*: bool     # 暗号化有効
    logEnabled*: bool            # ログ有効

# 定数定義
const
  DEFAULT_BUFFER_SIZE = 8192     # デフォルトバッファサイズ
  DEFAULT_TIMEOUT = 30000        # デフォルトタイムアウト 30秒
  MAX_CONNECTIONS = 100          # 最大接続数
  HEARTBEAT_INTERVAL = 10000     # ハートビート間隔 10秒
  MAX_RETRY_COUNT = 5            # 最大リトライ回数
  ERROR_CODES = {
    "TIMEOUT": 100,
    "DISCONNECTED": 101,
    "CONNECTION_REFUSED": 102,
    "INVALID_MESSAGE": 103,
    "SECURITY_VIOLATION": 104,
    "UNKNOWN_ERROR": 999
  }

# ユーティリティ関数

proc generateId(prefix: string = ""): string =
  ## ユニークなIDを生成する
  let timestamp = getTime().toUnix()
  let random = rand(high(int))
  result = &"{prefix}{timestamp}-{random:x}"

proc hashMessage(msg: IPCMessage): Hash =
  ## メッセージのハッシュを計算する
  var h: Hash = 0
  h = h !& hash(msg.id)
  h = h !& hash(msg.sourceId)
  h = h !& hash(msg.targetId)
  h = h !& hash($msg.messageType)
  h = h !& hash($msg.priority)
  h = h !& hash($msg.payload)
  result = !$h

# IPCManager 実装

proc newIPCConfig*(): IPCConfig =
  ## 新しいIPC設定を作成する
  result = IPCConfig(
    bufferSize: DEFAULT_BUFFER_SIZE,
    maxConnections: MAX_CONNECTIONS,
    autoReconnect: true,
    reconnectInterval: 5000,  # 5秒
    heartbeatInterval: HEARTBEAT_INTERVAL,
    compressionEnabled: true,
    encryptionEnabled: true,
    logEnabled: true
  )

proc newIPCStatistics*(): IPCStatistics =
  ## 新しい統計オブジェクトを作成する
  result = IPCStatistics(
    messagesSent: 0,
    messagesReceived: 0,
    bytesTransferred: 0,
    errors: 0,
    activeChannels: 0,
    avgResponseTime: 0.0,
    startTime: getTime()
  )

proc newIPCManager*(processType: ProcessType, config: IPCConfig = nil): IPCManager =
  ## 新しいIPCマネージャを作成する
  let instanceId = generateId("ipc-")
  let actualConfig = if config.isNil: newIPCConfig() else: config
  
  result = IPCManager(
    instanceId: instanceId,
    processType: processType,
    channels: initTable[string, IPCChannel](),
    defaultTransport: ttUnixSocket,
    activeConnections: initHashSet[string](),
    isRunning: false,
    messageCounter: 0,
    globalHandlers: initTable[string, proc(msg: IPCMessage): Future[void] {.async.}](),
    discoveryEnabled: true,
    pendingResponses: initTable[string, Future[IPCMessage]](),
    statistics: newIPCStatistics(),
    maxQueueSize: 1000,
    defaultTimeout: DEFAULT_TIMEOUT,
    config: actualConfig
  )
  
  # ロックの初期化
  initLock(result.mainLock)

proc newIPCMessage*(source: string, target: string, msgType: MessageType, payload: JsonNode): IPCMessage =
  ## 新しいIPCメッセージを作成する
  result = IPCMessage(
    id: generateId("msg-"),
    sourceId: source,
    targetId: target,
    messageType: msgType,
    priority: mpNormal,
    timestamp: getTime(),
    payload: payload,
    replyTo: none(string),
    ttl: 60,  # 60秒デフォルト
    headers: initTable[string, string]()
  )

proc createChannel*(manager: IPCManager, id: string, mode: ChannelMode, 
                    transport: TransportType, processType: ProcessType,
                    securityLevel: SecurityLevel = slSecure): Future[IPCChannel] {.async.} =
  ## 新しいチャネルを作成する
  let channelId = if id.len > 0: id else: generateId("ch-")
  
  if manager.channels.hasKey(channelId):
    raise newException(IPCError, "Channel with ID " & channelId & " already exists")
  
  let channel = IPCChannel(
    id: channelId,
    mode: mode,
    transport: transport,
    status: csInitializing,
    securityLevel: securityLevel,
    processType: processType,
    isBlocking: false,
    readBuffer: newSeq[byte](manager.config.bufferSize),
    writeBuffer: newSeq[byte](manager.config.bufferSize),
    handlers: initTable[string, proc(msg: IPCMessage): Future[void] {.async.}]()
  )
  
  initLock(channel.lock)
  
  # チャネルをマネージャに登録
  withLock manager.mainLock:
    manager.channels[channelId] = channel
    manager.statistics.activeChannels = manager.channels.len
  
  return channel

proc connectChannel*(manager: IPCManager, channel: IPCChannel): Future[bool] {.async.} =
  ## チャネルを接続する
  if channel.status == csConnected:
    return true
  
  try:
    # 接続ステータスを変更
    channel.status = csConnecting
    
    # トランスポートタイプに応じた接続処理
    case channel.transport
    of ttUnixSocket:
      # Unixソケット接続処理（実装省略）
      await sleepAsync(100)  # ダミー処理
    
    of ttPipe:
      # 名前付きパイプ接続処理（実装省略）
      await sleepAsync(100)  # ダミー処理
    
    of ttSharedMemory:
      # 共有メモリ接続処理（実装省略）
      await sleepAsync(100)  # ダミー処理
    
    of ttTCP:
      # TCP接続処理（実装省略）
      await sleepAsync(100)  # ダミー処理
    
    of ttWebSocket:
      # WebSocket接続処理（実装省略）
      await sleepAsync(100)  # ダミー処理
    
    of ttCustom:
      # カスタム接続処理（実装省略）
      await sleepAsync(100)  # ダミー処理
    
    # 接続成功
    channel.status = csConnected
    
    # アクティブ接続リストに追加
    withLock manager.mainLock:
      manager.activeConnections.incl(channel.id)
    
    # 接続ハンドラを呼び出し
    if not channel.connectionHandler.isNil:
      await channel.connectionHandler(csConnected)
    
    return true
  
  except:
    # 接続エラー
    channel.status = csError
    
    # エラーハンドラを呼び出し
    let err = new IPCError
    err.msg = "Failed to connect: " & getCurrentExceptionMsg()
    err.code = ERROR_CODES["CONNECTION_REFUSED"]
    
    if not channel.errorHandler.isNil:
      await channel.errorHandler(err)
    
    return false

proc disconnectChannel*(manager: IPCManager, channelId: string): Future[bool] {.async.} =
  ## チャネルを切断する
  if not manager.channels.hasKey(channelId):
    return false
  
  var channel = manager.channels[channelId]
  if channel.status == csDisconnected:
    return true
  
  try:
    # 切断ステータスを設定
    channel.status = csDisconnecting
    
    # トランスポートタイプに応じた切断処理
    case channel.transport
    of ttUnixSocket:
      # Unixソケット切断処理（実装省略）
      await sleepAsync(50)  # ダミー処理
    
    of ttPipe:
      # 名前付きパイプ切断処理（実装省略）
      await sleepAsync(50)  # ダミー処理
    
    of ttSharedMemory:
      # 共有メモリ切断処理（実装省略）
      await sleepAsync(50)  # ダミー処理
    
    of ttTCP:
      # TCP切断処理（実装省略）
      await sleepAsync(50)  # ダミー処理
    
    of ttWebSocket:
      # WebSocket切断処理（実装省略）
      await sleepAsync(50)  # ダミー処理
    
    of ttCustom:
      # カスタム切断処理（実装省略）
      await sleepAsync(50)  # ダミー処理
    
    # 切断完了
    channel.status = csDisconnected
    
    # アクティブ接続リストから削除
    withLock manager.mainLock:
      manager.activeConnections.excl(channelId)
    
    # 接続ハンドラを呼び出し
    if not channel.connectionHandler.isNil:
      await channel.connectionHandler(csDisconnected)
    
    return true
  
  except:
    # 切断エラー
    channel.status = csError
    
    # エラーハンドラを呼び出し
    let err = new IPCError
    err.msg = "Failed to disconnect: " & getCurrentExceptionMsg()
    err.code = ERROR_CODES["UNKNOWN_ERROR"]
    
    if not channel.errorHandler.isNil:
      await channel.errorHandler(err)
    
    return false

proc sendMessage*(manager: IPCManager, channelId: string, message: IPCMessage): Future[void] {.async.} =
  ## メッセージを送信する
  if not manager.channels.hasKey(channelId):
    raise newException(IPCError, "Channel not found: " & channelId)
  
  let channel = manager.channels[channelId]
  if channel.status != csConnected:
    raise newException(IPCError, "Channel not connected")
  
  try:
    # メッセージをJSONにシリアライズ
    let jsonData = %*{
      "id": message.id,
      "sourceId": message.sourceId,
      "targetId": message.targetId,
      "messageType": $message.messageType,
      "priority": $message.priority,
      "timestamp": message.timestamp.toUnix(),
      "payload": message.payload,
      "ttl": message.ttl,
      "headers": message.headers
    }
    
    if message.replyTo.isSome:
      jsonData["replyTo"] = %message.replyTo.get()
    
    let jsonStr = $jsonData
    let dataSize = jsonStr.len
    
    # ブロッキング処理の場合は排他制御
    if channel.isBlocking:
      withLock channel.lock:
        # トランスポートタイプに応じた送信処理
        case channel.transport
        of ttUnixSocket:
          # Unixソケット送信処理（実装省略）
          await sleepAsync(10)  # ダミー処理
        
        of ttPipe:
          # 名前付きパイプ送信処理（実装省略）
          await sleepAsync(10)  # ダミー処理
        
        of ttSharedMemory:
          # 共有メモリ送信処理（実装省略）
          await sleepAsync(10)  # ダミー処理
        
        of ttTCP:
          # TCP送信処理（実装省略）
          await sleepAsync(10)  # ダミー処理
        
        of ttWebSocket:
          # WebSocket送信処理（実装省略）
          await sleepAsync(10)  # ダミー処理
        
        of ttCustom:
          # カスタム送信処理（実装省略）
          await sleepAsync(10)  # ダミー処理
    else:
      # ノンブロッキング処理
      # トランスポートタイプに応じた送信処理（実装省略）
      await sleepAsync(10)  # ダミー処理
    
    # 統計情報を更新
    withLock manager.mainLock:
      inc manager.statistics.messagesSent
      manager.statistics.bytesTransferred += dataSize.int64
  
  except:
    # 送信エラー
    let err = new IPCError
    err.msg = "Failed to send message: " & getCurrentExceptionMsg()
    err.code = ERROR_CODES["UNKNOWN_ERROR"]
    
    # エラーハンドラを呼び出し
    if not channel.errorHandler.isNil:
      await channel.errorHandler(err)
    elif not manager.errorHandler.isNil:
      await manager.errorHandler(err)
    else:
      raise err

proc receiveMessage*(manager: IPCManager, channelId: string, timeout: int = -1): Future[IPCMessage] {.async.} =
  ## メッセージを受信する
  if not manager.channels.hasKey(channelId):
    raise newException(IPCError, "Channel not found: " & channelId)
  
  let channel = manager.channels[channelId]
  if channel.status != csConnected:
    raise newException(IPCError, "Channel not connected")
  
  let actualTimeout = if timeout < 0: manager.defaultTimeout else: timeout
  let startTime = getTime()
  
  try:
    # トランスポートタイプに応じた受信処理
    var jsonStr: string
    
    # 受信処理（実装省略、ダミーデータで代用）
    await sleepAsync(50)  # ダミー処理
    jsonStr = """{"id":"msg-123","sourceId":"process-1","targetId":"process-2","messageType":"request","priority":"normal","timestamp":1609459200,"payload":{"action":"test"},"ttl":60,"headers":{}}"""
    
    if jsonStr.len == 0:
      return nil
    
    # JSONからメッセージを復元
    let jsonNode = parseJson(jsonStr)
    let message = IPCMessage(
      id: jsonNode["id"].getStr(),
      sourceId: jsonNode["sourceId"].getStr(),
      targetId: jsonNode["targetId"].getStr(),
      messageType: parseEnum[MessageType](jsonNode["messageType"].getStr()),
      priority: parseEnum[MessagePriority](jsonNode["priority"].getStr()),
      timestamp: fromUnix(jsonNode["timestamp"].getInt()),
      payload: jsonNode["payload"],
      ttl: jsonNode["ttl"].getInt(),
      headers: initTable[string, string]()
    )
    
    # ヘッダー情報の復元
    for key, value in jsonNode["headers"].pairs:
      message.headers[key] = value.getStr()
    
    # replyTo属性があれば設定
    if jsonNode.hasKey("replyTo"):
      message.replyTo = some(jsonNode["replyTo"].getStr())
    
    # 統計情報を更新
    withLock manager.mainLock:
      inc manager.statistics.messagesReceived
      manager.statistics.bytesTransferred += jsonStr.len.int64
    
    return message
  
  except:
    # 受信エラー
    let err = new IPCError
    err.msg = "Failed to receive message: " & getCurrentExceptionMsg()
    err.code = ERROR_CODES["UNKNOWN_ERROR"]
    
    # エラーハンドラを呼び出し
    if not channel.errorHandler.isNil:
      await channel.errorHandler(err)
    elif not manager.errorHandler.isNil:
      await manager.errorHandler(err)
    else:
      raise err
    
    return nil

proc sendAndReceive*(manager: IPCManager, channelId: string, message: IPCMessage, 
                    timeout: int = -1): Future[IPCMessage] {.async.} =
  ## メッセージを送信して応答を待機する
  let responsePromise = newFuture[IPCMessage]("sendAndReceive")
  
  # 応答待ちリストに登録
  withLock manager.mainLock:
    manager.pendingResponses[message.id] = responsePromise
  
  # メッセージ送信
  await manager.sendMessage(channelId, message)
  
  # タイムアウト処理
  let actualTimeout = if timeout < 0: manager.defaultTimeout else: timeout
  
  let timeoutFuture = sleepAsync(actualTimeout)
  
  # レスポンスを待機
  await racing(responsePromise, timeoutFuture)
  
  if not responsePromise.finished:
    # タイムアウト発生
    withLock manager.mainLock:
      manager.pendingResponses.del(message.id)
    
    let err = new IPCTimeoutError
    err.msg = &"Timed out waiting for response to message {message.id}"
    err.code = ERROR_CODES["TIMEOUT"]
    
    # エラーハンドラを呼び出し
    if not manager.errorHandler.isNil:
      await manager.errorHandler(err)
    
    raise err
  
  return await responsePromise

proc registerHandler*(manager: IPCManager, channelId: string, messageType: MessageType, 
                    handler: proc(msg: IPCMessage): Future[void] {.async.}): bool =
  ## メッセージハンドラを登録する
  if not manager.channels.hasKey(channelId):
    return false
  
  let channel = manager.channels[channelId]
  
  # ハンドラを登録
  channel.handlers[$messageType] = handler
  return true

proc registerGlobalHandler*(manager: IPCManager, messageType: MessageType, 
                          handler: proc(msg: IPCMessage): Future[void] {.async.}): bool =
  ## グローバルメッセージハンドラを登録する
  manager.globalHandlers[$messageType] = handler
  return true

proc registerErrorHandler*(manager: IPCManager, channelId: string, 
                         handler: proc(err: ref IPCError): Future[void] {.async.}): bool =
  ## エラーハンドラを登録する
  if not manager.channels.hasKey(channelId):
    return false
  
  let channel = manager.channels[channelId]
  channel.errorHandler = handler
  return true

proc registerConnectionHandler*(manager: IPCManager, channelId: string, 
                              handler: proc(status: ConnectionStatus): Future[void] {.async.}): bool =
  ## 接続状態変更ハンドラを登録する
  if not manager.channels.hasKey(channelId):
    return false
  
  let channel = manager.channels[channelId]
  channel.connectionHandler = handler
  return true

proc processIncoming*(manager: IPCManager): Future[void] {.async.} =
  ## 受信メッセージを処理する
  let channelIds = toSeq(manager.channels.keys)
  
  for channelId in channelIds:
    let channel = manager.channels[channelId]
    
    if channel.status != csConnected:
      continue
    
    # メッセージを受信
    let message = await manager.receiveMessage(channelId)
    if message.isNil:
      continue
    
    # 応答待ちメッセージか確認
    if message.replyTo.isSome:
      let replyToId = message.replyTo.get()
      
      # 応答を待っているプロミスがあるか確認
      if manager.pendingResponses.hasKey(replyToId):
        let promise = manager.pendingResponses[replyToId]
        manager.pendingResponses.del(replyToId)
        promise.complete(message)
        continue
    
    # チャネル固有のハンドラを確認
    let messageType = $message.messageType
    if channel.handlers.hasKey(messageType):
      await channel.handlers[messageType](message)
    # グローバルハンドラを確認
    elif manager.globalHandlers.hasKey(messageType):
      await manager.globalHandlers[messageType](message)

proc start*(manager: IPCManager): Future[bool] {.async.} =
  ## IPCマネージャを開始する
  if manager.isRunning:
    return true
  
  try:
    manager.isRunning = true
    
    # 全チャネルを接続
    for _, channel in manager.channels:
      if channel.status != csConnected:
        discard await manager.connectChannel(channel)
    
    # メッセージ処理ループを非同期で開始
    asyncCheck (proc() {.async.} =
      while manager.isRunning:
        await manager.processIncoming()
        await sleepAsync(10)  # 短い待機
    )()
    
    # ハートビート処理を非同期で開始
    if manager.config.heartbeatInterval > 0:
      asyncCheck (proc() {.async.} =
        while manager.isRunning:
          # 全接続チャネルにハートビートを送信
          for channelId in manager.activeConnections:
            if not manager.channels.hasKey(channelId):
              continue
            
            let channel = manager.channels[channelId]
            if channel.status == csConnected:
              let heartbeat = newIPCMessage(
                manager.instanceId,
                "heartbeat",
                mtEvent,
                %*{"type": "heartbeat", "timestamp": getTime().toUnix()}
              )
              
              try:
                await manager.sendMessage(channelId, heartbeat)
              except:
                # ハートビート送信エラーは無視
                discard
          
          # 次のハートビートまで待機
          await sleepAsync(manager.config.heartbeatInterval)
      )()
    
    return true
  
  except:
    manager.isRunning = false
    
    # エラーハンドラを呼び出し
    let err = new IPCError
    err.msg = "Failed to start IPC manager: " & getCurrentExceptionMsg()
    err.code = ERROR_CODES["UNKNOWN_ERROR"]
    
    if not manager.errorHandler.isNil:
      await manager.errorHandler(err)
    
    return false

proc stop*(manager: IPCManager): Future[bool] {.async.} =
  ## IPCマネージャを停止する
  if not manager.isRunning:
    return true
  
  try:
    manager.isRunning = false
    
    # 全チャネルを切断
    let channelIds = toSeq(manager.channels.keys)
    for channelId in channelIds:
      discard await manager.disconnectChannel(channelId)
    
    # 保留中のレスポンスをすべてキャンセル
    withLock manager.mainLock:
      for _, promise in manager.pendingResponses:
        if not promise.finished:
          let err = new IPCError
          err.msg = "IPC manager stopped"
          err.code = ERROR_CODES["DISCONNECTED"]
          promise.fail(err)
      
      manager.pendingResponses.clear()
    
    return true
  
  except:
    # エラーハンドラを呼び出し
    let err = new IPCError
    err.msg = "Failed to stop IPC manager: " & getCurrentExceptionMsg()
    err.code = ERROR_CODES["UNKNOWN_ERROR"]
    
    if not manager.errorHandler.isNil:
      await manager.errorHandler(err)
    
    return false

proc getStats*(manager: IPCManager): IPCStatistics =
  ## 統計情報を取得する
  result = manager.statistics
  
  # アクティブチャネル数を更新
  result.activeChannels = 0
  for _, channel in manager.channels:
    if channel.status == csConnected:
      inc result.activeChannels

proc listChannels*(manager: IPCManager): seq[string] =
  ## 接続中のチャネルIDリストを取得する
  result = newSeq[string]()
  
  for id, channel in manager.channels:
    if channel.status == csConnected:
      result.add(id)

proc hasActiveConnection*(manager: IPCManager, channelId: string): bool =
  ## 指定したチャネルがアクティブか確認する
  if not manager.channels.hasKey(channelId):
    return false
  
  return manager.channels[channelId].status == csConnected

proc setChannelBlockingMode*(manager: IPCManager, channelId: string, blocking: bool): bool =
  ## チャネルのブロッキングモードを設定する
  if not manager.channels.hasKey(channelId):
    return false
  
  manager.channels[channelId].isBlocking = blocking
  return true

proc setTimeout*(manager: IPCManager, timeout: int) =
  ## デフォルトタイムアウト時間を設定する
  manager.defaultTimeout = timeout

# エクスポート関数
export IPCManager, IPCChannel, IPCMessage, IPCError, IPCTimeoutError, IPCStatistics, IPCConfig
export ChannelMode, ConnectionStatus, ProcessType, MessagePriority, MessageType, TransportType, SecurityLevel
export newIPCManager, newIPCMessage, newIPCConfig, newIPCStatistics
export createChannel, connectChannel, disconnectChannel, sendMessage, receiveMessage, sendAndReceive
export registerHandler, registerGlobalHandler, registerErrorHandler, registerConnectionHandler
export start, stop, getStats, listChannels, hasActiveConnection, setChannelBlockingMode, setTimeout 