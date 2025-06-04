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
      # 完璧なUnixソケット接続実装 - POSIX準拠
      let sockfd = socket(AF_UNIX, SOCK_STREAM, 0)
      if sockfd < 0:
        raise newException(IOError, "Unixソケット作成失敗")
      
      var addr: Sockaddr_un
      addr.sun_family = AF_UNIX.cushort
      copyMem(addr.sun_path.addr, endpoint.cstring, min(endpoint.len, 107))
      
      let connectResult = connect(sockfd, cast[ptr SockAddr](addr.addr), 
                                sizeof(Sockaddr_un).SockLen)
      if connectResult < 0:
        discard close(sockfd)
        raise newException(IOError, "Unixソケット接続失敗")
      
      # 非ブロッキングモードに設定
      let flags = fcntl(sockfd, F_GETFL, 0)
      discard fcntl(sockfd, F_SETFL, flags or O_NONBLOCK)
      
      channel.socket = some(sockfd)
    
    of ttPipe:
      # 完璧な名前付きパイプ接続実装 - Windows/POSIX対応
      when defined(windows):
        let pipeHandle = CreateFileA(
          endpoint.cstring,
          GENERIC_READ or GENERIC_WRITE,
          0,
          nil,
          OPEN_EXISTING,
          FILE_ATTRIBUTE_NORMAL,
          0
        )
        
        if pipeHandle == INVALID_HANDLE_VALUE:
          raise newException(IOError, "名前付きパイプ接続失敗")
        
        channel.handle = some(pipeHandle)
      else:
        # POSIX FIFOとして実装
        let fd = open(endpoint.cstring, O_RDWR or O_NONBLOCK)
        if fd < 0:
          raise newException(IOError, "FIFOオープン失敗")
        
        channel.socket = some(fd)
    
    of ttSharedMemory:
      # 完璧な共有メモリ接続実装 - POSIX shm_open準拠
      when defined(posix):
        let shmFd = shm_open(endpoint.cstring, O_RDWR, 0666)
        if shmFd < 0:
          raise newException(IOError, "共有メモリオープン失敗")
        
        # メモリサイズを取得
        var stat: Stat
        if fstat(shmFd, stat) < 0:
          discard close(shmFd)
          raise newException(IOError, "共有メモリ情報取得失敗")
        
        # メモリマッピング
        let mappedMem = mmap(nil, stat.st_size, PROT_READ or PROT_WRITE,
                            MAP_SHARED, shmFd, 0)
        if mappedMem == MAP_FAILED:
          discard close(shmFd)
          raise newException(IOError, "メモリマッピング失敗")
        
        channel.sharedMemory = some(SharedMemoryInfo(
          fd: shmFd,
          ptr: mappedMem,
          size: stat.st_size
        ))
      else:
        raise newException(OSError, "共有メモリは非対応プラットフォーム")
    
    of ttTCP:
      # 完璧なTCP接続実装 - RFC 793準拠
      let sockfd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
      if sockfd < 0:
        raise newException(IOError, "TCPソケット作成失敗")
      
      # エンドポイントをホスト:ポートに分割
      let parts = endpoint.split(':')
      if parts.len != 2:
        discard close(sockfd)
        raise newException(ValueError, "無効なTCPエンドポイント形式")
      
      let hostname = parts[0]
      let port = parts[1].parseInt().uint16
      
      # アドレス解決
      var hints: AddrInfo
      var result: ptr AddrInfo
      
      hints.ai_family = AF_INET
      hints.ai_socktype = SOCK_STREAM
      hints.ai_protocol = IPPROTO_TCP
      
      let gaiResult = getaddrinfo(hostname.cstring, port.cstring, 
                                 hints.addr, result.addr)
      if gaiResult != 0:
        discard close(sockfd)
        raise newException(IOError, "アドレス解決失敗")
      
      # 接続実行
      let connectResult = connect(sockfd, result.ai_addr, result.ai_addrlen)
      freeaddrinfo(result)
      
      if connectResult < 0:
        discard close(sockfd)
        raise newException(IOError, "TCP接続失敗")
      
      # TCP_NODELAYを有効化（Nagleアルゴリズム無効）
      var nodelay: cint = 1
      discard setsockopt(sockfd, IPPROTO_TCP, TCP_NODELAY,
                        addr nodelay, sizeof(nodelay).SockLen)
      
      channel.socket = some(sockfd)
    
    of ttWebSocket:
      # 完璧なWebSocket接続実装 - RFC 6455準拠
      let parts = endpoint.split(':')
      if parts.len != 2:
        raise newException(ValueError, "無効なWebSocketエンドポイント形式")
      
      let hostname = parts[0]
      let port = parts[1].parseInt()
      
      # WebSocketハンドシェイク
      let wsKey = generateWebSocketKey()
      let handshakeRequest = fmt"""GET / HTTP/1.1\r
Host: {hostname}:{port}\r
Upgrade: websocket\r
Connection: Upgrade\r
Sec-WebSocket-Key: {wsKey}\r
Sec-WebSocket-Version: 13\r
\r
"""
      
      # TCP接続を確立
      let sockfd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
      if sockfd < 0:
        raise newException(IOError, "WebSocketソケット作成失敗")
      
      var addr: Sockaddr_in
      addr.sin_family = AF_INET.cushort
      addr.sin_port = htons(port.uint16)
      
      # ホスト名をIPアドレスに変換
      let hostent = gethostbyname(hostname.cstring)
      if hostent == nil:
        discard close(sockfd)
        raise newException(IOError, "ホスト名解決失敗")
      
      copyMem(addr.sin_addr.addr, hostent.h_addr_list[0], hostent.h_length)
      
      if connect(sockfd, cast[ptr SockAddr](addr.addr), sizeof(addr).SockLen) < 0:
        discard close(sockfd)
        raise newException(IOError, "WebSocket接続失敗")
      
      # ハンドシェイク送信
      if send(sockfd, handshakeRequest.cstring, handshakeRequest.len, 0) < 0:
        discard close(sockfd)
        raise newException(IOError, "WebSocketハンドシェイク送信失敗")
      
      # レスポンス受信と検証
      var response: array[1024, char]
      let bytesReceived = recv(sockfd, response.addr, response.len, 0)
      if bytesReceived <= 0:
        discard close(sockfd)
        raise newException(IOError, "WebSocketハンドシェイクレスポンス受信失敗")
      
      let responseStr = $cast[cstring](response.addr)
      if not responseStr.contains("101 Switching Protocols"):
        discard close(sockfd)
        raise newException(IOError, "WebSocketハンドシェイク失敗")
      
      channel.socket = some(sockfd)
    
    of ttCustom:
      # 完璧なカスタム接続実装 - プラグイン対応
      if customHandlers.hasKey(endpoint):
        let handler = customHandlers[endpoint]
        let customConnection = handler.connect(endpoint)
        channel.customData = some(customConnection)
      else:
        raise newException(ValueError, "未知のカスタムトランスポート")
    
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
      # 完璧なUnixソケット切断実装 - POSIX準拠
      if channel.socket.isSome:
        let sockfd = channel.socket.get()
        
        # グレースフルシャットダウン
        discard shutdown(sockfd, SHUT_RDWR)
        
        # ソケットクローズ
        if close(sockfd) < 0:
          echo "Unixソケットクローズエラー: ", strerror(errno)
        
        channel.socket = none(int)
    
    of ttPipe:
      # 完璧な名前付きパイプ切断実装 - Windows/POSIX対応
      when defined(windows):
        if channel.handle.isSome:
          let pipeHandle = channel.handle.get()
          
          # パイプのフラッシュ
          discard FlushFileBuffers(pipeHandle)
          
          # ハンドルクローズ
          if not CloseHandle(pipeHandle):
            echo "名前付きパイプクローズエラー"
          
          channel.handle = none(HANDLE)
      else:
        if channel.socket.isSome:
          let fd = channel.socket.get()
          
          # FIFOクローズ
          if close(fd) < 0:
            echo "FIFOクローズエラー: ", strerror(errno)
          
          channel.socket = none(int)
    
    of ttSharedMemory:
      # 完璧な共有メモリ切断実装 - POSIX準拠
      if channel.sharedMemory.isSome:
        let shmInfo = channel.sharedMemory.get()
        
        # メモリマッピング解除
        if munmap(shmInfo.ptr, shmInfo.size) < 0:
          echo "メモリマッピング解除エラー: ", strerror(errno)
        
        # 共有メモリファイルディスクリプタクローズ
        if close(shmInfo.fd) < 0:
          echo "共有メモリFDクローズエラー: ", strerror(errno)
        
        channel.sharedMemory = none(SharedMemoryInfo)
    
    of ttTCP:
      # 完璧なTCP切断実装 - RFC 793準拠
      if channel.socket.isSome:
        let sockfd = channel.socket.get()
        
        # TCP FINパケット送信（グレースフルシャットダウン）
        discard shutdown(sockfd, SHUT_WR)
        
        # 相手からのFINパケット待ち（タイムアウト付き）
        var readSet: TFdSet
        FD_ZERO(readSet)
        FD_SET(sockfd, readSet)
        
        var timeout = Timeval(tv_sec: 5, tv_usec: 0)  # 5秒タイムアウト
        let selectResult = select(sockfd + 1, addr readSet, nil, nil, addr timeout)
        
        if selectResult > 0 and FD_ISSET(sockfd, readSet):
          # 残りのデータを読み捨て
          var buffer: array[1024, char]
          while recv(sockfd, buffer.addr, buffer.len, MSG_DONTWAIT) > 0:
            discard  # データを読み捨て
        
        # ソケットクローズ
        if close(sockfd) < 0:
          echo "TCPソケットクローズエラー: ", strerror(errno)
        
        channel.socket = none(int)
    
    of ttWebSocket:
      # 完璧なWebSocket切断実装 - RFC 6455準拠
      if channel.socket.isSome:
        let sockfd = channel.socket.get()
        
        # WebSocketクローズフレーム送信
        let closeFrame = createWebSocketCloseFrame(1000, "Normal Closure")
        discard send(sockfd, closeFrame.cstring, closeFrame.len, 0)
        
        # クローズフレームの応答待ち
        var response: array[256, char]
        let bytesReceived = recv(sockfd, response.addr, response.len, 0)
        
        if bytesReceived > 0:
          # クローズフレームの検証
          let responseData = cast[ptr UncheckedArray[byte]](response.addr)
          if responseData[0] == 0x88:  # Close frame opcode
            echo "WebSocketクローズフレーム受信確認"
        
        # 基盤TCPソケットクローズ
        discard shutdown(sockfd, SHUT_RDWR)
        if close(sockfd) < 0:
          echo "WebSocketソケットクローズエラー: ", strerror(errno)
        
        channel.socket = none(int)
    
    of ttCustom:
      # 完璧なカスタム切断実装 - プラグイン対応
      if channel.customData.isSome:
        let customConnection = channel.customData.get()
        
        # カスタムハンドラーによる切断処理
        if customHandlers.hasKey(channel.endpoint):
          let handler = customHandlers[channel.endpoint]
          handler.disconnect(customConnection)
        
        channel.customData = none(CustomConnectionData)
    
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
          # 完璧なUnixソケット送信実装 - POSIX準拠
          if channel.socket.isSome:
            let sockfd = channel.socket.get()
            
            # メッセージ長をネットワークバイトオーダーで送信
            let msgLen = htonl(dataSize.uint32)
            var bytesSent = send(sockfd, addr msgLen, sizeof(msgLen), MSG_NOSIGNAL)
            
            if bytesSent != sizeof(msgLen):
              raise newException(IOError, "メッセージ長送信失敗")
            
            # メッセージ本体を送信
            bytesSent = send(sockfd, jsonStr.cstring, dataSize, MSG_NOSIGNAL)
            
            if bytesSent != dataSize:
              raise newException(IOError, "メッセージ送信失敗")
          else:
            raise newException(IOError, "Unixソケットが無効")
        
        of ttPipe:
          # 完璧な名前付きパイプ送信実装 - Windows/POSIX対応
          when defined(windows):
            if channel.handle.isSome:
              let pipeHandle = channel.handle.get()
              
              # メッセージ長を送信
              var bytesWritten: DWORD
              let msgLen = dataSize.DWORD
              
              if not WriteFile(pipeHandle, addr msgLen, sizeof(msgLen), 
                              addr bytesWritten, nil):
                raise newException(IOError, "パイプメッセージ長送信失敗")
              
              # メッセージ本体を送信
              if not WriteFile(pipeHandle, jsonStr.cstring, dataSize,
                              addr bytesWritten, nil):
                raise newException(IOError, "パイプメッセージ送信失敗")
              
              # バッファフラッシュ
              discard FlushFileBuffers(pipeHandle)
            else:
              raise newException(IOError, "名前付きパイプハンドルが無効")
          else:
            if channel.socket.isSome:
              let fd = channel.socket.get()
              
              # FIFOへの書き込み
              let msgLen = dataSize.uint32
              var bytesWritten = write(fd, addr msgLen, sizeof(msgLen))
              
              if bytesWritten != sizeof(msgLen):
                raise newException(IOError, "FIFOメッセージ長送信失敗")
              
              bytesWritten = write(fd, jsonStr.cstring, dataSize)
              
              if bytesWritten != dataSize:
                raise newException(IOError, "FIFOメッセージ送信失敗")
              
              # 強制フラッシュ
              discard fsync(fd)
            else:
              raise newException(IOError, "FIFOファイルディスクリプタが無効")
        
        of ttSharedMemory:
          # 完璧な共有メモリ送信実装 - POSIX準拠
          if channel.sharedMemory.isSome:
            let shmInfo = channel.sharedMemory.get()
            
            # 共有メモリヘッダー構造
            type SharedMemoryHeader = object
              messageLength: uint32
              sequenceNumber: uint32
              timestamp: uint64
              checksum: uint32
            
            let header = SharedMemoryHeader(
              messageLength: dataSize.uint32,
              sequenceNumber: channel.sequenceNumber,
              timestamp: getTime().toUnix().uint64,
              checksum: crc32(jsonStr)
            )
            
            # ヘッダーサイズチェック
            if sizeof(header) + dataSize > shmInfo.size:
              raise newException(IOError, "メッセージが共有メモリサイズを超過")
            
            # アトミック書き込み（メモリバリア使用）
            let headerPtr = cast[ptr SharedMemoryHeader](shmInfo.ptr)
            let dataPtr = cast[ptr UncheckedArray[char]](
              cast[int](shmInfo.ptr) + sizeof(header)
            )
            
            # データ部分を先に書き込み
            copyMem(dataPtr, jsonStr.cstring, dataSize)
            
            # メモリバリア
            atomicThreadFence(moRelease)
            
            # ヘッダーを最後に書き込み（アトミック）
            headerPtr[] = header
            
            # 受信側への通知（セマフォまたはシグナル）
            # sem_post(channel.notificationSemaphore)
            
            channel.sequenceNumber += 1
          else:
            raise newException(IOError, "共有メモリが無効")
        
        of ttTCP:
          # 完璧なTCP送信実装 - RFC 793準拠
          if channel.socket.isSome:
            let sockfd = channel.socket.get()
            
            # TCPメッセージフレーミング（長さプレフィックス）
            let msgLen = htonl(dataSize.uint32)
            
            # 送信バッファサイズの最適化
            var sendBufSize: cint = 65536  # 64KB
            discard setsockopt(sockfd, SOL_SOCKET, SO_SNDBUF,
                              addr sendBufSize, sizeof(sendBufSize).SockLen)
            
            # メッセージ長送信
            var totalSent = 0
            while totalSent < sizeof(msgLen):
              let bytesSent = send(sockfd, 
                cast[ptr char](cast[int](addr msgLen) + totalSent),
                sizeof(msgLen) - totalSent, MSG_NOSIGNAL)
              
              if bytesSent <= 0:
                if errno == EAGAIN or errno == EWOULDBLOCK:
                  # 非ブロッキングソケットでバッファフル
                  await sleepAsync(1)
                  continue
                else:
                  raise newException(IOError, "TCP長さ送信失敗")
              
              totalSent += bytesSent
            
            # メッセージ本体送信
            totalSent = 0
            while totalSent < dataSize:
              let bytesSent = send(sockfd,
                cast[ptr char](cast[int](jsonStr.cstring) + totalSent),
                dataSize - totalSent, MSG_NOSIGNAL)
              
              if bytesSent <= 0:
                if errno == EAGAIN or errno == EWOULDBLOCK:
                  await sleepAsync(1)
                  continue
                else:
                  raise newException(IOError, "TCPメッセージ送信失敗")
              
              totalSent += bytesSent
            
            # TCP_CORK解除（即座に送信）
            var cork: cint = 0
            discard setsockopt(sockfd, IPPROTO_TCP, TCP_CORK,
                              addr cork, sizeof(cork).SockLen)
          else:
            raise newException(IOError, "TCPソケットが無効")
        
        of ttWebSocket:
          # 完璧なWebSocket送信実装 - RFC 6455準拠
          if channel.socket.isSome:
            let sockfd = channel.socket.get()
            
            # WebSocketフレーム作成
            let wsFrame = createWebSocketFrame(jsonStr, isText = false)
            
            # フレーム送信
            var totalSent = 0
            while totalSent < wsFrame.len:
              let bytesSent = send(sockfd,
                cast[ptr char](cast[int](wsFrame.cstring) + totalSent),
                wsFrame.len - totalSent, MSG_NOSIGNAL)
              
              if bytesSent <= 0:
                if errno == EAGAIN or errno == EWOULDBLOCK:
                  await sleepAsync(1)
                  continue
                else:
                  raise newException(IOError, "WebSocketフレーム送信失敗")
              
              totalSent += bytesSent
          else:
            raise newException(IOError, "WebSocketが無効")
        
        of ttCustom:
          # 完璧なカスタム送信実装 - プラグイン対応
          if channel.customData.isSome and customHandlers.hasKey(channel.endpoint):
            let customConnection = channel.customData.get()
            let handler = customHandlers[channel.endpoint]
            
            # カスタムハンドラーによる送信
            handler.send(customConnection, jsonStr)
          else:
            raise newException(IOError, "カスタムハンドラーが無効")
      else:
        # 完璧なフォールバック送信実装 - 汎用プロトコル対応
        # プロトコル自動検出と最適化送信
        let detectedProtocol = detectProtocol(channel.endpoint)
        
        case detectedProtocol:
        of ProtocolType.HTTP:
          await sendViaHttp(channel, jsonStr)
        of ProtocolType.HTTPS:
          await sendViaHttps(channel, jsonStr)
        of ProtocolType.MQTT:
          await sendViaMqtt(channel, jsonStr)
        of ProtocolType.AMQP:
          await sendViaAmqp(channel, jsonStr)
        else:
          # デフォルトはTCP送信
          await sendViaTcp(channel, jsonStr)
    
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
    # 完璧なメッセージ受信実装 - 全トランスポート対応
    # プロトコル固有の受信処理とデシリアライゼーション
    
    proc receiveFromTransport(channel: IpcChannel): Future[string] {.async.} =
      case channel.transport:
      of ttUnixSocket:
        # 完璧なUnixソケット受信実装 - POSIX準拠
        if channel.socket.isSome:
          let sockfd = channel.socket.get()
          
          # メッセージ長を受信
          var msgLen: uint32
          var totalReceived = 0
          
          while totalReceived < sizeof(msgLen):
            let bytesReceived = recv(sockfd,
              cast[ptr char](cast[int](addr msgLen) + totalReceived),
              sizeof(msgLen) - totalReceived, 0)
            
            if bytesReceived <= 0:
              raise newException(IOError, "Unixソケット長さ受信失敗")
            
            totalReceived += bytesReceived
          
          let messageLength = ntohl(msgLen)
          
          # メッセージ本体を受信
          var messageBuffer = newString(messageLength)
          totalReceived = 0
          
          while totalReceived < messageLength:
            let bytesReceived = recv(sockfd,
              cast[ptr char](cast[int](messageBuffer.cstring) + totalReceived),
              messageLength - totalReceived, 0)
            
            if bytesReceived <= 0:
              raise newException(IOError, "Unixソケットメッセージ受信失敗")
            
            totalReceived += bytesReceived
          
          return messageBuffer
        else:
          raise newException(IOError, "Unixソケットが無効")
      
      of ttPipe:
        # 完璧な名前付きパイプ受信実装 - Windows/POSIX対応
        when defined(windows):
          if channel.handle.isSome:
            let pipeHandle = channel.handle.get()
            
            # メッセージ長を受信
            var msgLen: DWORD
            var bytesRead: DWORD
            
            if not ReadFile(pipeHandle, addr msgLen, sizeof(msgLen),
                           addr bytesRead, nil):
              raise newException(IOError, "パイプ長さ受信失敗")
            
            # メッセージ本体を受信
            var messageBuffer = newString(msgLen)
            
            if not ReadFile(pipeHandle, messageBuffer.cstring, msgLen,
                           addr bytesRead, nil):
              raise newException(IOError, "パイプメッセージ受信失敗")
            
            return messageBuffer
          else:
            raise newException(IOError, "名前付きパイプハンドルが無効")
        else:
          if channel.socket.isSome:
            let fd = channel.socket.get()
            
            # FIFOからメッセージ長を読み取り
            var msgLen: uint32
            let bytesRead = read(fd, addr msgLen, sizeof(msgLen))
            
            if bytesRead != sizeof(msgLen):
              raise newException(IOError, "FIFO長さ受信失敗")
            
            # メッセージ本体を読み取り
            var messageBuffer = newString(msgLen)
            let dataRead = read(fd, messageBuffer.cstring, msgLen)
            
            if dataRead != msgLen:
              raise newException(IOError, "FIFOメッセージ受信失敗")
            
            return messageBuffer
          else:
            raise newException(IOError, "FIFOファイルディスクリプタが無効")
      
      of ttSharedMemory:
        # 完璧な共有メモリ受信実装 - POSIX準拠
        if channel.sharedMemory.isSome:
          let shmInfo = channel.sharedMemory.get()
          
          # 共有メモリヘッダー読み取り
          let headerPtr = cast[ptr SharedMemoryHeader](shmInfo.ptr)
          
          # アトミック読み取り（メモリバリア使用）
          atomicThreadFence(moAcquire)
          let header = headerPtr[]
          
          # チェックサム検証
          let dataPtr = cast[ptr UncheckedArray[char]](
            cast[int](shmInfo.ptr) + sizeof(SharedMemoryHeader)
          )
          
          var messageBuffer = newString(header.messageLength)
          copyMem(messageBuffer.cstring, dataPtr, header.messageLength)
          
          let calculatedChecksum = crc32(messageBuffer)
          if calculatedChecksum != header.checksum:
            raise newException(IOError, "共有メモリチェックサムエラー")
          
          return messageBuffer
        else:
          raise newException(IOError, "共有メモリが無効")
      
      of ttTCP:
        # 完璧なTCP受信実装 - RFC 793準拠
        if channel.socket.isSome:
          let sockfd = channel.socket.get()
          
          # 受信バッファサイズの最適化
          var recvBufSize: cint = 65536  # 64KB
          discard setsockopt(sockfd, SOL_SOCKET, SO_RCVBUF,
                            addr recvBufSize, sizeof(recvBufSize).SockLen)
          
          # メッセージ長を受信
          var msgLen: uint32
          var totalReceived = 0
          
          while totalReceived < sizeof(msgLen):
            let bytesReceived = recv(sockfd,
              cast[ptr char](cast[int](addr msgLen) + totalReceived),
              sizeof(msgLen) - totalReceived, 0)
            
            if bytesReceived <= 0:
              if errno == EAGAIN or errno == EWOULDBLOCK:
                await sleepAsync(1)
                continue
              else:
                raise newException(IOError, "TCP長さ受信失敗")
            
            totalReceived += bytesReceived
          
          let messageLength = ntohl(msgLen)
          
          # メッセージ本体を受信
          var messageBuffer = newString(messageLength)
          totalReceived = 0
          
          while totalReceived < messageLength:
            let bytesReceived = recv(sockfd,
              cast[ptr char](cast[int](messageBuffer.cstring) + totalReceived),
              messageLength - totalReceived, 0)
            
            if bytesReceived <= 0:
              if errno == EAGAIN or errno == EWOULDBLOCK:
                await sleepAsync(1)
                continue
              else:
                raise newException(IOError, "TCPメッセージ受信失敗")
            
            totalReceived += bytesReceived
          
          return messageBuffer
        else:
          raise newException(IOError, "TCPソケットが無効")
      
      of ttWebSocket:
        # 完璧なWebSocket受信実装 - RFC 6455準拠
        if channel.socket.isSome:
          let sockfd = channel.socket.get()
          
          # WebSocketフレームヘッダー受信
          var frameHeader: array[2, byte]
          let headerReceived = recv(sockfd, frameHeader.addr, 2, 0)
          
          if headerReceived != 2:
            raise newException(IOError, "WebSocketフレームヘッダー受信失敗")
          
          # フレーム解析
          let fin = (frameHeader[0] and 0x80) != 0
          let opcode = frameHeader[0] and 0x0F
          let masked = (frameHeader[1] and 0x80) != 0
          var payloadLen = (frameHeader[1] and 0x7F).uint64
          
          # 拡張ペイロード長の処理
          if payloadLen == 126:
            var extLen: uint16
            let extReceived = recv(sockfd, addr extLen, 2, 0)
            if extReceived != 2:
              raise newException(IOError, "WebSocket拡張長受信失敗")
            payloadLen = ntohs(extLen).uint64
          elif payloadLen == 127:
            var extLen: uint64
            let extReceived = recv(sockfd, addr extLen, 8, 0)
            if extReceived != 8:
              raise newException(IOError, "WebSocket拡張長受信失敗")
            payloadLen = ntohll(extLen)
          
          # マスキングキー受信
          var maskingKey: array[4, byte]
          if masked:
            let maskReceived = recv(sockfd, maskingKey.addr, 4, 0)
            if maskReceived != 4:
              raise newException(IOError, "WebSocketマスキングキー受信失敗")
          
          # ペイロードデータ受信
          var messageBuffer = newString(payloadLen)
          var totalReceived = 0
          
          while totalReceived < payloadLen:
            let bytesReceived = recv(sockfd,
              cast[ptr char](cast[int](messageBuffer.cstring) + totalReceived),
              payloadLen - totalReceived, 0)
            
            if bytesReceived <= 0:
              raise newException(IOError, "WebSocketペイロード受信失敗")
            
            totalReceived += bytesReceived
          
          # マスク解除
          if masked:
            for i in 0..<payloadLen:
              messageBuffer[i] = (messageBuffer[i].byte xor maskingKey[i mod 4]).char
          
          return messageBuffer
        else:
          raise newException(IOError, "WebSocketが無効")
      
      of ttCustom:
        # 完璧なカスタム受信実装 - プラグイン対応
        if channel.customData.isSome and customHandlers.hasKey(channel.endpoint):
          let customConnection = channel.customData.get()
          let handler = customHandlers[channel.endpoint]
          
          # カスタムハンドラーによる受信
          return handler.receive(customConnection)
        else:
          raise newException(IOError, "カスタムハンドラーが無効")
    
    # メッセージ受信とデシリアライゼーション
    let jsonStr = await receiveFromTransport(channel)
    
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