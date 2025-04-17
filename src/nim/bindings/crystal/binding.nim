## Crystal言語との連携のためのバインディングモジュール
## 
## このモジュールはNimからCrystalで実装されたUIコンポーネントを操作するための
## インターフェースを提供します。
##
## 主な機能:
## - Crystal UIコンポーネントの生成と操作
## - イベント処理システムとの連携
## - データの相互変換

import std/[json, options, tables, asyncdispatch, os, strutils]

type
  CrystalBindingError* = object of CatchableError
    ## Crystalバインディング操作中に発生したエラーを表す例外型

  CrystalValueKind* = enum
    ## Crystalとの間でやり取りする値の種類を表す列挙型
    cvkNil,     # Nil値
    cvkBool,    # 真偽値
    cvkInt,     # 整数
    cvkFloat,   # 浮動小数点数
    cvkString,  # 文字列
    cvkArray,   # 配列
    cvkObject,  # オブジェクト/ハッシュ
    cvkBinary,  # バイナリデータ
    cvkSymbol   # シンボル

  CrystalValue* = ref object
    ## Crystal-Nim間でデータをやり取りするための共通型
    case kind*: CrystalValueKind
    of cvkNil: discard
    of cvkBool: boolVal*: bool
    of cvkInt: intVal*: int64
    of cvkFloat: floatVal*: float64
    of cvkString: stringVal*: string
    of cvkSymbol: symbolVal*: string
    of cvkArray: arrayVal*: seq[CrystalValue]
    of cvkObject: objectVal*: Table[string, CrystalValue]
    of cvkBinary: binaryVal*: seq[byte]

  CrystalCallback* = proc(args: seq[CrystalValue]): CrystalValue {.gcsafe.}
    ## Crystalから呼び出されるコールバック関数の型

  CrystalMethod* = object
    ## Crystalクラスに登録するメソッドを表す型
    name*: string
    callback*: CrystalCallback

  CrystalClass* = ref object
    ## Crystalクラスとの連携を表現するためのオブジェクト
    name*: string
    methods*: seq[CrystalMethod]
    initialize*: CrystalCallback

  CrystalInstance* = ref object
    ## Crystalオブジェクトのインスタンスを表すオブジェクト
    instanceId*: int64
    className*: string

  CrystalEvent* = ref object
    ## Crystalから送信されるイベントを表すオブジェクト
    eventType*: string
    source*: CrystalInstance
    data*: CrystalValue

  UiEventHandler* = proc(event: CrystalEvent): Future[void] {.async.}
    ## UIイベントを処理するためのハンドラ型

  CrystalRuntime* = ref object
    ## Crystalランタイムとの連携を管理するオブジェクト
    initialized*: bool
    classes*: Table[string, CrystalClass]
    instances*: Table[int64, CrystalInstance]
    eventHandlers*: Table[string, seq[UiEventHandler]]
    channelId*: string

var runtime = CrystalRuntime(
  initialized: false,
  classes: initTable[string, CrystalClass](),
  instances: initTable[int64, CrystalInstance](),
  eventHandlers: initTable[string, seq[UiEventHandler]](),
  channelId: ""
)

# 値コンストラクタ関数群

proc newCrystalNil*(): CrystalValue =
  ## Crystal nil値を作成する
  CrystalValue(kind: cvkNil)

proc newCrystalBool*(val: bool): CrystalValue =
  ## Crystal真偽値を作成する
  CrystalValue(kind: cvkBool, boolVal: val)

proc newCrystalInt*(val: int64): CrystalValue =
  ## Crystal整数値を作成する
  CrystalValue(kind: cvkInt, intVal: val)

proc newCrystalFloat*(val: float64): CrystalValue =
  ## Crystal浮動小数点数を作成する
  CrystalValue(kind: cvkFloat, floatVal: val)

proc newCrystalString*(val: string): CrystalValue =
  ## Crystal文字列を作成する
  CrystalValue(kind: cvkString, stringVal: val)

proc newCrystalSymbol*(val: string): CrystalValue =
  ## Crystalシンボルを作成する
  CrystalValue(kind: cvkSymbol, symbolVal: val)

proc newCrystalArray*(val: seq[CrystalValue] = @[]): CrystalValue =
  ## Crystal配列を作成する
  CrystalValue(kind: cvkArray, arrayVal: val)

proc newCrystalObject*(val: Table[string, CrystalValue] = initTable[string, CrystalValue]()): CrystalValue =
  ## Crystalオブジェクト/ハッシュを作成する
  CrystalValue(kind: cvkObject, objectVal: val)

proc newCrystalBinary*(val: seq[byte]): CrystalValue =
  ## Crystalバイナリデータを作成する
  CrystalValue(kind: cvkBinary, binaryVal: val)

# JSON変換関数

proc fromJson*(node: JsonNode): CrystalValue =
  ## JSONからCrystalValueに変換する
  case node.kind
  of JNull:
    result = newCrystalNil()
  of JBool:
    result = newCrystalBool(node.getBool())
  of JInt:
    result = newCrystalInt(node.getInt())
  of JFloat:
    result = newCrystalFloat(node.getFloat())
  of JString:
    let str = node.getStr()
    if str.startsWith("__sym__:"):
      result = newCrystalSymbol(str[8..^1])
    else:
      result = newCrystalString(str)
  of JArray:
    var arr: seq[CrystalValue] = @[]
    for item in node:
      arr.add(fromJson(item))
    result = newCrystalArray(arr)
  of JObject:
    var obj = initTable[string, CrystalValue]()
    for key, value in node.fields:
      obj[key] = fromJson(value)
    result = newCrystalObject(obj)

proc toJson*(val: CrystalValue): JsonNode =
  ## CrystalValueからJSONに変換する
  case val.kind
  of cvkNil:
    result = newJNull()
  of cvkBool:
    result = newJBool(val.boolVal)
  of cvkInt:
    result = newJInt(val.intVal)
  of cvkFloat:
    result = newJFloat(val.floatVal)
  of cvkString:
    result = newJString(val.stringVal)
  of cvkSymbol:
    result = newJString("__sym__:" & val.symbolVal)
  of cvkArray:
    result = newJArray()
    for item in val.arrayVal:
      result.add(toJson(item))
  of cvkObject:
    result = newJObject()
    for key, value in val.objectVal:
      result[key] = toJson(value)
  of cvkBinary:
    # バイナリデータはBase64エンコードして文字列として格納
    import base64
    let encoded = encode(val.binaryVal)
    result = newJObject()
    result["__binary__"] = newJString(encoded)

# ランタイム操作関数
proc initialize*(socketPath: string = ""): bool =
  ## Crystalランタイムを初期化する
  ## 
  ## Parameters:
  ##   socketPath: Crystalプロセスとの通信に使用するUNIXソケットパス
  ##
  ## Returns:
  ##   初期化に成功した場合はtrue、そうでない場合はfalse
  
  if runtime.initialized:
    return true

  # ソケットパスが指定されていなければ環境変数から取得
  var actualSocketPath = socketPath
  if actualSocketPath == "":
    actualSocketPath = getEnv("CRYSTAL_IPC_SOCKET", "")
    if actualSocketPath == "":
      echo "Crystal IPC socket path not specified and CRYSTAL_IPC_SOCKET environment variable not set"
      return false

  # チャンネルIDはプロセスIDを使用
  runtime.channelId = $getCurrentProcessId()
  
  try:
    # UNIXソケットに接続
    runtime.socket = newSocket(AF_UNIX, SOCK_STREAM, 0)
    runtime.socket.connectUnix(actualSocketPath)
    runtime.socket.setSockOpt(OptNoDelay, true)
    
    # 初期化メッセージを送信
    let initMsg = %*{
      "type": "init",
      "channel_id": runtime.channelId,
      "process_type": "nim",
      "version": NIM_BINDING_VERSION
    }
    
    let serialized = $initMsg
    let msgLen = serialized.len.uint32
    var lenBytes = newStringOfCap(4)
    lenBytes.add(char(msgLen and 0xFF))
    lenBytes.add(char((msgLen shr 8) and 0xFF))
    lenBytes.add(char((msgLen shr 16) and 0xFF))
    lenBytes.add(char((msgLen shr 24) and 0xFF))
    
    runtime.socket.send(lenBytes)
    runtime.socket.send(serialized)
    
    # レスポンスを受信
    var respLenBytes = newString(4)
    if runtime.socket.recv(respLenBytes, 4) != 4:
      raise newException(CrystalBindingError, "Failed to receive response length")
    
    let respLen = (uint32(respLenBytes[0]) or
                  (uint32(respLenBytes[1]) shl 8) or
                  (uint32(respLenBytes[2]) shl 16) or
                  (uint32(respLenBytes[3]) shl 24)).int
    
    var respData = newString(respLen)
    if runtime.socket.recv(respData, respLen) != respLen:
      raise newException(CrystalBindingError, "Failed to receive complete response")
    
    let response = parseJson(respData)
    if response["status"].getStr() != "ok":
      raise newException(CrystalBindingError, "Initialization failed: " & response["error"].getStr())
    
    # 非同期通信用のスレッドを開始
    runtime.messageQueue = newChannel[JsonNode](100)
    runtime.responseQueue = newTable[string, Channel[JsonNode]]()
    runtime.running = true
    
    runtime.communicationThread = spawn communicationThreadProc()
    
    runtime.initialized = true
    result = true
    
  except:
    let msg = getCurrentExceptionMsg()
    echo "Failed to initialize Crystal runtime: ", msg
    if runtime.socket != nil:
      runtime.socket.close()
      runtime.socket = nil
    runtime.initialized = false
    result = false
    raise newException(CrystalBindingError, "Crystal runtime not initialized")
  
  if name in runtime.classes:
    return runtime.classes[name]
  
  let cls = CrystalClass(
    name: name,
    methods: @[],
    initialize: initialize
  )
  
  runtime.classes[name] = cls
  result = cls

proc addMethod*(cls: CrystalClass, name: string, callback: CrystalCallback) =
  ## Crystalクラスにメソッドを追加する
  ##
  ## Parameters:
  ##   cls: メソッドを追加するクラス
  ##   name: メソッド名
  ##   callback: メソッド呼び出し時に実行されるコールバック関数
  
  cls.methods.add(CrystalMethod(name: name, callback: callback))

proc callMethod*(instance: CrystalInstance, methodName: string, args: seq[CrystalValue] = @[]): CrystalValue =
  ## Crystalインスタンスのメソッドを呼び出す
  ##
  ## Parameters:
  ##   instance: メソッドを呼び出すインスタンス
  ##   methodName: 呼び出すメソッド名
  ##   args: メソッドに渡す引数
  ##
  ## Returns:
  ##   メソッド呼び出しの結果
  
  if not runtime.initialized:
    raise newException(CrystalBindingError, "Crystal runtime not initialized")
  
  let requestId = generateRequestId()
  let argsJson = newJArray()
  
  for arg in args:
    argsJson.add(arg.toJson())
  
  let request = %*{
    "type": "method_call",
    "request_id": requestId,
    "instance_id": instance.id,
    "method": methodName,
    "args": argsJson
  }
  
  # レスポンスを受け取るためのチャネルを作成
  let responseChannel = newChannel[JsonNode](1)
  runtime.responseQueue[requestId] = responseChannel
  
  # リクエストを送信
  let requestData = $request
  let requestLen = requestData.len
  
  try:
    # 長さプレフィックスを送信
    var lenBytes = pack(uint32(requestLen))
    if runtime.socket.send(lenBytes, 4) != 4:
      raise newException(CrystalBindingError, "Failed to send request length")
    
    # リクエスト本体を送信
    if runtime.socket.send(requestData, requestLen) != requestLen:
      raise newException(CrystalBindingError, "Failed to send complete request")
    
    # レスポンスを待機
    let response = responseChannel.recv()
    
    # チャネルをクリーンアップ
    runtime.responseQueue.del(requestId)
    
    # エラー処理
    if response.hasKey("error"):
      let errorMsg = response["error"].getStr()
      raise newException(CrystalBindingError, "Method call failed: " & errorMsg)
    
    # 結果を変換して返す
    if response.hasKey("result"):
      result = jsonToCrystalValue(response["result"])
    else:
      result = newCrystalNil()
      
  except TimeoutError:
    runtime.responseQueue.del(requestId)
    raise newException(CrystalBindingError, "Method call timed out: " & methodName)
  except:
    runtime.responseQueue.del(requestId)
    let msg = getCurrentExceptionMsg()
    raise newException(CrystalBindingError, "Method call failed: " & msg)

proc addEventListener*(eventType: string, handler: UiEventHandler) =
  ## イベントリスナーを登録する
  ##
  ## Parameters:
  ##   eventType: 登録するイベントタイプ
  ##   handler: イベント発生時に呼び出されるハンドラ関数
  
  if not runtime.initialized:
    raise newException(CrystalBindingError, "Crystal runtime not initialized")
  
  if eventType notin runtime.eventHandlers:
    runtime.eventHandlers[eventType] = @[]
  
  runtime.eventHandlers[eventType].add(handler)

proc removeEventListener*(eventType: string, handler: UiEventHandler) =
  ## イベントリスナーを削除する
  ##
  ## Parameters:
  ##   eventType: 削除するイベントタイプ
  ##   handler: 削除するハンドラ関数
  
  if eventType notin runtime.eventHandlers:
    return
  
  var index = -1
  for i, h in runtime.eventHandlers[eventType]:
    if cast[pointer](h) == cast[pointer](handler):
      index = i
      break
  
  if index >= 0:
    runtime.eventHandlers[eventType].delete(index)

proc dispatchEvent*(event: CrystalEvent): Future[void] {.async.} =
  ## イベントを処理する
  ##
  ## Parameters:
  ##   event: 処理するイベント
  
  if event.eventType notin runtime.eventHandlers:
    return
  
  let handlers = runtime.eventHandlers[event.eventType]
  var futures: seq[Future[void]] = @[]
  
  for handler in handlers:
    futures.add(handler(event))
  
  if futures.len > 0:
    await all(futures)

# 外部向け公開例
type
  UiElement* = CrystalInstance
  UiButton* = CrystalInstance
  UiTextField* = CrystalInstance

proc createButton*(text: string): Future[UiButton] {.async.} =
  ## ボタン要素を作成する
  ##
  ## Parameters:
  ##   text: ボタンのテキスト
  ##
  ## Returns:
  ##   作成されたボタン要素
  
  if not runtime.initialized:
    raise newException(CrystalBindingError, "Crystal runtime not initialized")
  
  let params = %* {"text": text}
  let response = await runtime.callCrystalMethod("UI", "createButton", params)
  
  if response.kind != JObject:
    raise newException(CrystalBindingError, "Invalid response from Crystal runtime")
  
  let instanceId = response["instanceId"].getInt()
  let instance = CrystalInstance(
    instanceId: instanceId,
    className: "Button"
  )
  
  runtime.instances[instanceId] = instance
  result = UiButton(instance)

proc setText*(button: UiButton, text: string): Future[void] {.async.} =
  ## ボタンのテキストを設定する
  ##
  ## Parameters:
  ##   button: テキストを設定するボタン
  ##   text: 設定するテキスト
  
  if not runtime.initialized:
    raise newException(CrystalBindingError, "Crystal runtime not initialized")
  
  let params = %* {
    "instanceId": button.instanceId,
    "text": text
  }
  
  discard await runtime.callCrystalMethod("UI", "setText", params)

proc onClick*(button: UiButton, handler: proc(): Future[void]): Future[void] {.async.} =
  ## ボタンのクリックイベントハンドラを設定する
  ##
  ## Parameters:
  ##   button: ハンドラを設定するボタン
  ##   handler: クリック時に実行する関数
  
  if not runtime.initialized:
    raise newException(CrystalBindingError, "Crystal runtime not initialized")
  
  let eventType = "button_click_" & $button.instanceId
  
  # イベントハンドラを登録
  addEventListener(eventType, proc(event: CrystalEvent): Future[void] =
    return handler()
  )
  
  # Crystalにイベントリスナーを登録
  let params = %* {
    "instanceId": button.instanceId,
    "eventType": "click",
    "callbackId": eventType
  }
  
  discard await runtime.callCrystalMethod("UI", "addEventListener", params)

proc createTextField*(placeholder: string = "", initialValue: string = ""): Future[UiTextField] {.async.} =
  ## テキストフィールド要素を作成する
  ##
  ## Parameters:
  ##   placeholder: プレースホルダーテキスト
  ##   initialValue: 初期値
  ##
  ## Returns:
  ##   作成されたテキストフィールド要素
  
  if not runtime.initialized:
    raise newException(CrystalBindingError, "Crystal runtime not initialized")
  
  let params = %* {
    "placeholder": placeholder,
    "initialValue": initialValue
  }
  
  let response = await runtime.callCrystalMethod("UI", "createTextField", params)
  
  if response.kind != JObject:
    raise newException(CrystalBindingError, "Invalid response from Crystal runtime")
  
  let instanceId = response["instanceId"].getInt()
  let instance = CrystalInstance(
    instanceId: instanceId,
    className: "TextField"
  )
  
  runtime.instances[instanceId] = instance
  result = UiTextField(instance)

proc getValue*(textField: UiTextField): Future[string] {.async.} =
  ## テキストフィールドの値を取得する
  ##
  ## Parameters:
  ##   textField: 値を取得するテキストフィールド
  ##
  ## Returns:
  ##   テキストフィールドの現在の値
  
  if not runtime.initialized:
    raise newException(CrystalBindingError, "Crystal runtime not initialized")
  
  let params = %* {
    "instanceId": textField.instanceId
  }
  
  let response = await runtime.callCrystalMethod("UI", "getTextFieldValue", params)
  
  if response.kind != JString:
    raise newException(CrystalBindingError, "Invalid response from Crystal runtime")
  
  result = response.getStr()

proc setValue*(textField: UiTextField, value: string): Future[void] {.async.} =
  ## テキストフィールドの値を設定する
  ##
  ## Parameters:
  ##   textField: 値を設定するテキストフィールド
  ##   value: 設定する値
  
  if not runtime.initialized:
    raise newException(CrystalBindingError, "Crystal runtime not initialized")
  
  let params = %* {
    "instanceId": textField.instanceId,
    "value": value
  }
  
  discard await runtime.callCrystalMethod("UI", "setTextFieldValue", params)

proc onTextChange*(textField: UiTextField, handler: proc(newValue: string): Future[void]): Future[void] {.async.} =
  ## テキストフィールドの値変更イベントハンドラを設定する
  ##
  ## Parameters:
  ##   textField: ハンドラを設定するテキストフィールド
  ##   handler: 値変更時に実行する関数
  
  if not runtime.initialized:
    raise newException(CrystalBindingError, "Crystal runtime not initialized")
  
  let eventType = "textfield_change_" & $textField.instanceId
  
  # イベントハンドラを登録
  addEventListener(eventType, proc(event: CrystalEvent): Future[void] =
    if event.data.kind != JObject or not event.data.hasKey("value"):
      return newFuture[void]()
    
    let newValue = event.data["value"].getStr()
    return handler(newValue)
  )
  
  # Crystalにイベントリスナーを登録
  let params = %* {
    "instanceId": textField.instanceId,
    "eventType": "change",
    "callbackId": eventType
  }
  
  discard await runtime.callCrystalMethod("UI", "addEventListener", params)