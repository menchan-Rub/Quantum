## CrystalとのIPC通信を処理するモジュール
##
## このモジュールはNimからCrystalプロセスへのIPC（プロセス間通信）を
## 実装します。通信は非同期で行われ、メッセージのシリアライズにはJSONを使用します。
##
## 主な機能:
## - NimからCrystalへのリクエスト送信
## - Crystalからのレスポンス受信
## - イベントの送受信

import std/[asyncdispatch, asyncnet, json, options, tables, os, strutils, times, random]
import binding

type
  RequestType* = enum
    ## リクエストタイプを表す列挙型
    rtMethodCall,  # メソッド呼び出し
    rtClassCreate, # クラス作成
    rtEventListen, # イベント監視登録
    rtEventUnlisten # イベント監視解除

  ResponseType* = enum
    ## レスポンスタイプを表す列挙型
    rsSuccess,   # 成功
    rsError,     # エラー
    rsEvent      # イベント通知

  IpcRequest* = object
    ## IPCリクエストを表すオブジェクト
    id*: string
    reqType*: RequestType
    target*: string  # クラス名またはインスタンスID
    method*: string  # メソッド名またはイベント名
    args*: seq[CrystalValue]

  IpcResponse* = object
    ## IPCレスポンスを表すオブジェクト
    id*: string
    resType*: ResponseType
    value*: CrystalValue
    error*: string

  IpcClient* = ref object
    ## IPC通信クライアントを表すオブジェクト
    socket*: AsyncSocket
    connected*: bool
    responseCallbacks*: Table[string, proc(response: IpcResponse) {.closure, gcsafe.}]
    eventCallbacks*: Table[string, seq[proc(event: CrystalEvent) {.closure, gcsafe.}]]
    reconnecting*: bool
    socketPath*: string

var 
  client: IpcClient
  pendingRequests: Table[string, IpcRequest]

proc generateRequestId(): string =
  ## 一意のリクエストIDを生成する
  let timestamp = getTime().toUnix()
  let random = rand(high(int32))
  result = $timestamp & "-" & $random

proc serialize(request: IpcRequest): string =
  ## リクエストをJSON文字列にシリアライズする
  var jsonObj = newJObject()
  jsonObj["id"] = newJString(request.id)
  jsonObj["type"] = newJInt(ord(request.reqType))
  jsonObj["target"] = newJString(request.target)
  jsonObj["method"] = newJString(request.method)
  
  var argsArray = newJArray()
  for arg in request.args:
    argsArray.add(toJson(arg))
  
  jsonObj["args"] = argsArray
  result = $jsonObj

proc deserializeResponse(data: string): IpcResponse =
  ## JSON文字列からレスポンスをデシリアライズする
  let jsonObj = parseJson(data)
  
  result.id = jsonObj["id"].getStr()
  result.resType = ResponseType(jsonObj["type"].getInt())
  
  if result.resType == rsError:
    result.error = jsonObj["error"].getStr()
  else:
    result.value = fromJson(jsonObj["value"])

proc deserializeEvent(data: string): CrystalEvent =
  ## JSON文字列からイベントをデシリアライズする
  let jsonObj = parseJson(data)
  
  let eventType = jsonObj["eventType"].getStr()
  let sourceId = jsonObj["sourceId"].getInt()
  let eventData = fromJson(jsonObj["data"])
  
  var source: CrystalInstance
  if sourceId > 0 and sourceId in runtime.instances:
    source = runtime.instances[sourceId]
  
  result = CrystalEvent(
    eventType: eventType,
    source: source,
    data: eventData
  )

proc onMessage(data: string) {.async.} =
  ## メッセージ受信時の処理
  try:
    let jsonObj = parseJson(data)
    if "eventType" in jsonObj:
      # イベントメッセージの処理
      let event = deserializeEvent(data)
      await dispatchEvent(event)
    else:
      # レスポンスメッセージの処理
      let response = deserializeResponse(data)
      
      if response.id in client.responseCallbacks:
        let callback = client.responseCallbacks[response.id]
        callback(response)
        client.responseCallbacks.del(response.id)
  except:
    echo "Error processing message: ", getCurrentExceptionMsg()

proc messageReader() {.async.} =
  ## ソケットからメッセージを読み込むループ
  var message = ""
  var size: int
  
  while client.connected:
    try:
      # メッセージサイズを受信（4バイト整数）
      let sizeData = await client.socket.recv(4)
      if sizeData.len < 4:
        # 接続が切れた可能性がある
        client.connected = false
        break
      
      # メッセージサイズを解析
      size = cast[ptr int32](unsafeAddr sizeData[0])[]
      
      # メッセージ本体を受信
      var remainingSize = size
      message = ""
      
      while remainingSize > 0:
        let chunkSize = min(4096, remainingSize)
        let chunk = await client.socket.recv(chunkSize)
        
        if chunk.len == 0:
          # 接続が切れた
          client.connected = false
          break
        
        message.add(chunk)
        remainingSize -= chunk.len
      
      if message.len > 0:
        await onMessage(message)
    except:
      echo "Error in message reader: ", getCurrentExceptionMsg()
      client.connected = false
      break
  
  # 接続が切れた場合の再接続処理
  if not client.reconnecting:
    client.reconnecting = true
    echo "Connection lost, attempting to reconnect..."
    await reconnect()
    client.reconnecting = false

proc reconnect(): Future[bool] {.async.} =
  ## 接続が切れた場合に再接続を試みる
  var retries = 0
  const maxRetries = 5
  const retryDelayMs = 1000
  
  while retries < maxRetries:
    try:
      echo "Reconnect attempt ", retries + 1, " of ", maxRetries
      
      client.socket = newAsyncSocket()
      await client.socket.connectUnix(client.socketPath)
      client.connected = true
      
      # 再接続成功後、読み込みループを再開
      asyncCheck messageReader()
      
      echo "Reconnected successfully"
      return true
    except:
      echo "Reconnect failed: ", getCurrentExceptionMsg()
      retries += 1
      
      if retries < maxRetries:
        # 再試行前に少し待機
        await sleepAsync(retryDelayMs)
  
  echo "Failed to reconnect after ", maxRetries, " attempts"
  return false

proc connect*(socketPath: string): Future[bool] {.async.} =
  ## Crystalプロセスに接続する
  ##
  ## Parameters:
  ##   socketPath: 接続先のUNIXソケットパス
  ##
  ## Returns:
  ##   接続に成功した場合はtrue、そうでない場合はfalse
  
  if client != nil and client.connected:
    return true
  
  randomize()  # リクエストIDの生成のためにランダムシードを初期化
  
  try:
    client = IpcClient(
      socket: newAsyncSocket(),
      connected: false,
      responseCallbacks: initTable[string, proc(response: IpcResponse) {.closure, gcsafe.}](),
      eventCallbacks: initTable[string, seq[proc(event: CrystalEvent) {.closure, gcsafe.}]](),
      reconnecting: false,
      socketPath: socketPath
    )
    
    # UNIXソケットに接続
    await client.socket.connectUnix(socketPath)
    client.connected = true
    
    # メッセージ読み込みループを開始
    asyncCheck messageReader()
    
    return true
  except:
    echo "Connection error: ", getCurrentExceptionMsg()
    return false

proc disconnect*(): Future[void] {.async.} =
  ## Crystalプロセスから切断する
  if client != nil and client.connected:
    client.connected = false
    client.socket.close()
    client = nil

proc sendRequest*(request: IpcRequest): Future[IpcResponse] {.async.} =
  ## リクエストを送信し、レスポンスを待機する
  ##
  ## Parameters:
  ##   request: 送信するリクエスト
  ##
  ## Returns:
  ##   受信したレスポンス
  
  if client == nil or not client.connected:
    var err = IpcResponse(
      id: request.id,
      resType: rsError,
      error: "Not connected to Crystal process"
    )
    return err
  
  let message = serialize(request)
  let messageSize = message.len
  
  # 完了通知のためのPromise
  var promise = newFuture[IpcResponse]("sendRequest")
  
  # レスポンスコールバックを登録
  client.responseCallbacks[request.id] = proc(response: IpcResponse) =
    if not promise.finished:
      promise.complete(response)
  
  try:
    # メッセージサイズを送信（4バイト整数）
    var sizeBuf: array[4, byte]
    cast[ptr int32](addr sizeBuf[0])[] = int32(messageSize)
    await client.socket.send(addr sizeBuf, 4)
    
    # メッセージ本体を送信
    await client.socket.send(message)
    
    # レスポンスを待機（タイムアウト付き）
    let response = await promise.withTimeout(10000)
    result = response
  except AsyncTimeoutError:
    client.responseCallbacks.del(request.id)
    var err = IpcResponse(
      id: request.id,
      resType: rsError,
      error: "Request timed out"
    )
    result = err
  except:
    client.responseCallbacks.del(request.id)
    var err = IpcResponse(
      id: request.id,
      resType: rsError,
      error: getCurrentExceptionMsg()
    )
    result = err

proc callMethod*(target: string, methodName: string, args: seq[CrystalValue] = @[]): Future[CrystalValue] {.async.} =
  ## Crystalメソッドを呼び出す（高レベルAPI）
  ##
  ## Parameters:
  ##   target: 呼び出し先のインスタンスID（文字列として）またはクラス名
  ##   methodName: 呼び出すメソッド名
  ##   args: メソッドに渡す引数
  ##
  ## Returns:
  ##   メソッド呼び出しの結果
  
  let requestId = generateRequestId()
  let request = IpcRequest(
    id: requestId,
    reqType: rtMethodCall,
    target: target,
    method: methodName,
    args: args
  )
  
  let response = await sendRequest(request)
  if response.resType == rsError:
    raise newException(CrystalBindingError, response.error)
  
  result = response.value

proc createInstance*(className: string, args: seq[CrystalValue] = @[]): Future[CrystalInstance] {.async.} =
  ## Crystalクラスのインスタンスを作成する（高レベルAPI）
  ##
  ## Parameters:
  ##   className: 作成するクラス名
  ##   args: コンストラクタに渡す引数
  ##
  ## Returns:
  ##   作成されたインスタンス
  
  let requestId = generateRequestId()
  let request = IpcRequest(
    id: requestId,
    reqType: rtClassCreate,
    target: className,
    method: "new",
    args: args
  )
  
  let response = await sendRequest(request)
  if response.resType == rsError:
    raise newException(CrystalBindingError, response.error)
  
  # レスポンスからインスタンスIDを取得
  if response.value.kind != cvkObject or "instanceId" notin response.value.objectVal:
    raise newException(CrystalBindingError, "Invalid response format: instanceId not found")
  
  let instanceId = response.value.objectVal["instanceId"].intVal
  
  let instance = CrystalInstance(
    instanceId: instanceId,
    className: className
  )
  
  runtime.instances[instanceId] = instance
  result = instance

proc registerEventListener*(eventType: string, handler: UiEventHandler): Future[void] {.async.} =
  ## イベントリスナーを登録する（高レベルAPI、IPC経由）
  ##
  ## Parameters:
  ##   eventType: 登録するイベントタイプ
  ##   handler: イベント発生時に呼び出されるハンドラ関数
  
  # ローカルイベントハンドラに登録
  addEventListener(eventType, handler)
  
  # Crystal側にもイベント監視を登録
  let requestId = generateRequestId()
  let request = IpcRequest(
    id: requestId,
    reqType: rtEventListen,
    target: "*",
    method: eventType,
    args: @[]
  )
  
  let response = await sendRequest(request)
  if response.resType == rsError:
    raise newException(CrystalBindingError, response.error)

proc unregisterEventListener*(eventType: string, handler: UiEventHandler): Future[void] {.async.} =
  ## イベントリスナーを削除する（高レベルAPI、IPC経由）
  ##
  ## Parameters:
  ##   eventType: 削除するイベントタイプ
  ##   handler: 削除するハンドラ関数
  
  # ローカルイベントハンドラから削除
  removeEventListener(eventType, handler)
  
  # Crystal側のイベント監視も削除
  # （このイベントタイプのハンドラが他に存在しない場合のみ）
  if eventType notin runtime.eventHandlers or runtime.eventHandlers[eventType].len == 0:
    let requestId = generateRequestId()
    let request = IpcRequest(
      id: requestId,
      reqType: rtEventUnlisten,
      target: "*",
      method: eventType,
      args: @[]
    )
    
    let response = await sendRequest(request)
    if response.resType == rsError:
      echo "Error unregistering event listener: ", response.error 