## Zig言語との連携のためのバインディングモジュール
## 
## このモジュールはNimからZigで実装されたレンダリングエンジンや
## 低レベルコンポーネントを操作するためのインターフェースを提供します。
##
## 主な機能:
## - Zigコンポーネントの呼び出しと操作
## - メモリの共有と効率的なデータ交換
## - 非同期レンダリング要求の管理

import std/[os, dynlib, macros, strutils, strformat, options]

# エラータイプ
type
  ZigBindingError* = object of CatchableError
    ## Zigバインディング操作中に発生したエラーを表す例外型

  ZigMemoryError* = object of ZigBindingError
    ## メモリ操作中に発生したエラーを表す例外型

  ZigFunctionError* = object of ZigBindingError
    ## 関数呼び出し中に発生したエラーを表す例外型

  ZigInitError* = object of ZigBindingError
    ## 初期化中に発生したエラーを表す例外型

  ZigShutdownError* = object of ZigBindingError
    ## 終了処理中に発生したエラーを表す例外型

# メモリ共有のための型定義
type
  ZigMemoryRegion* = object
    ## Zigと共有するメモリ領域を表す型
    address*: pointer
    size*: int
    name*: string
    isOwner*: bool

  ZigMemoryView* = object
    ## 共有メモリへのビューを表す型
    region*: ZigMemoryRegion
    offset*: int
    length*: int

  ZigRenderCommand* = object
    ## レンダリングコマンドを表す型
    commandType*: uint32
    targetId*: uint32
    params*: array[8, uint64]

  ZigRenderResult* = object
    ## レンダリング結果を表す型
    success*: bool
    errorCode*: uint32
    resultData*: pointer
    resultSize*: int

# FFI型定義
type
  ZigInitFunc = proc(): cint {.cdecl.}
  ZigShutdownFunc = proc(): cint {.cdecl.}
  ZigAllocateMemoryFunc = proc(size: csize_t, name: cstring): pointer {.cdecl.}
  ZigFreeMemoryFunc = proc(ptr: pointer): void {.cdecl.}
  ZigRenderFunc = proc(commands: pointer, count: csize_t, results: pointer): cint {.cdecl.}
  ZigQueryInfoFunc = proc(infoType: cint, result: pointer, resultSize: csize_t): cint {.cdecl.}
  ZigRegisterCallbackFunc = proc(callbackType: cint, callback: pointer): cint {.cdecl.}

# ライブラリハンドルと関数ポインタ
var
  zigLib: LibHandle
  zigInitFn: ZigInitFunc
  zigShutdownFn: ZigShutdownFunc
  zigAllocateMemoryFn: ZigAllocateMemoryFunc
  zigFreeMemoryFn: ZigFreeMemoryFunc
  zigRenderFn: ZigRenderFunc
  zigQueryInfoFn: ZigQueryInfoFunc
  zigRegisterCallbackFn: ZigRegisterCallbackFunc

# 初期化フラグ
var zigInitialized = false

# メモリ管理のための内部データ構造
var allocatedRegions = newSeq[ZigMemoryRegion]()

proc loadZigLibrary*(libPath: string = ""): bool =
  ## Zigライブラリをロードする
  ##
  ## Parameters:
  ##   libPath: ライブラリファイルのパス（省略時は環境変数やデフォルトパスから検索）
  ##
  ## Returns:
  ##   ロードに成功した場合はtrue、失敗した場合はfalse
  
  if zigInitialized:
    return true
  
  # ライブラリパスの決定
  var actualLibPath = libPath
  if actualLibPath == "":
    # 環境変数をチェック
    actualLibPath = getEnv("ZIG_LIB_PATH", "")
    if actualLibPath == "":
      # デフォルトパスを使用
      when defined(windows):
        actualLibPath = "zigengine.dll"
      elif defined(macosx):
        actualLibPath = "libzigengine.dylib"
      else:
        actualLibPath = "libzigengine.so"
  
  # ライブラリのロード
  zigLib = loadLib(actualLibPath)
  if zigLib == nil:
    echo "Failed to load Zig library: ", actualLibPath
    return false
  
  # 関数ポインタの取得
  zigInitFn = cast[ZigInitFunc](symAddr(zigLib, "zig_init"))
  if zigInitFn == nil:
    echo "Failed to find zig_init function"
    unloadLib(zigLib)
    return false
  
  zigShutdownFn = cast[ZigShutdownFunc](symAddr(zigLib, "zig_shutdown"))
  if zigShutdownFn == nil:
    echo "Failed to find zig_shutdown function"
    unloadLib(zigLib)
    return false
  
  zigAllocateMemoryFn = cast[ZigAllocateMemoryFunc](symAddr(zigLib, "zig_allocate_memory"))
  if zigAllocateMemoryFn == nil:
    echo "Failed to find zig_allocate_memory function"
    unloadLib(zigLib)
    return false
  
  zigFreeMemoryFn = cast[ZigFreeMemoryFunc](symAddr(zigLib, "zig_free_memory"))
  if zigFreeMemoryFn == nil:
    echo "Failed to find zig_free_memory function"
    unloadLib(zigLib)
    return false
  
  zigRenderFn = cast[ZigRenderFunc](symAddr(zigLib, "zig_render"))
  if zigRenderFn == nil:
    echo "Failed to find zig_render function"
    unloadLib(zigLib)
    return false
  
  zigQueryInfoFn = cast[ZigQueryInfoFunc](symAddr(zigLib, "zig_query_info"))
  if zigQueryInfoFn == nil:
    echo "Failed to find zig_query_info function"
    unloadLib(zigLib)
    return false
  
  zigRegisterCallbackFn = cast[ZigRegisterCallbackFunc](symAddr(zigLib, "zig_register_callback"))
  if zigRegisterCallbackFn == nil:
    echo "Failed to find zig_register_callback function"
    unloadLib(zigLib)
    return false
  
  return true

proc initialize*(): bool =
  ## Zigエンジンを初期化する
  ##
  ## Returns:
  ##   初期化に成功した場合はtrue、失敗した場合はfalse
  
  if zigInitialized:
    return true
  
  if zigLib == nil:
    if not loadZigLibrary():
      return false
  
  let result = zigInitFn()
  if result != 0:
    echo "Failed to initialize Zig engine: error code ", result
    return false
  
  zigInitialized = true
  return true

proc shutdown*(): bool =
  ## Zigエンジンをシャットダウンする
  ##
  ## Returns:
  ##   シャットダウンに成功した場合はtrue、失敗した場合はfalse
  
  if not zigInitialized:
    return true
  
  # 割り当てられたメモリをすべて解放
  for region in allocatedRegions:
    if region.isOwner and region.address != nil:
      zigFreeMemoryFn(region.address)
  
  allocatedRegions.setLen(0)
  
  # エンジンのシャットダウン
  let result = zigShutdownFn()
  if result != 0:
    echo "Warning: Zig engine shutdown returned error code ", result
  
  # ライブラリのアンロード
  if zigLib != nil:
    unloadLib(zigLib)
    zigLib = nil
  
  zigInitialized = false
  return true

proc allocateMemory*(size: int, name: string = ""): ZigMemoryRegion =
  ## Zigエンジンを介してメモリを割り当てる
  ##
  ## Parameters:
  ##   size: 割り当てるメモリサイズ（バイト単位）
  ##   name: メモリ領域の識別名（デバッグ用）
  ##
  ## Returns:
  ##   割り当てられたメモリ領域を表すZigMemoryRegion
  ##
  ## Raises:
  ##   ZigMemoryError: メモリ割り当てに失敗した場合
  
  if not zigInitialized:
    if not initialize():
      raise newException(ZigInitError, "Zig engine not initialized")
  
  if size <= 0:
    raise newException(ZigMemoryError, "Invalid memory allocation size")
  
  let actualName = if name == "": "anonymous_region" else: name
  let address = zigAllocateMemoryFn(csize_t(size), actualName.cstring)
  
  if address == nil:
    raise newException(ZigMemoryError, "Failed to allocate memory")
  
  result = ZigMemoryRegion(
    address: address,
    size: size,
    name: actualName,
    isOwner: true
  )
  
  allocatedRegions.add(result)

proc freeMemory*(region: var ZigMemoryRegion) =
  ## 割り当てられたメモリを解放する
  ##
  ## Parameters:
  ##   region: 解放するメモリ領域
  ##
  ## Raises:
  ##   ZigMemoryError: メモリ解放に失敗した場合
  
  if not zigInitialized:
    raise newException(ZigInitError, "Zig engine not initialized")
  
  if region.address == nil:
    return
  
  if not region.isOwner:
    raise newException(ZigMemoryError, "Cannot free memory region not owned by this process")
  
  zigFreeMemoryFn(region.address)
  
  # 割り当て済みリージョンから削除
  for i in 0..<allocatedRegions.len:
    if allocatedRegions[i].address == region.address:
      allocatedRegions.delete(i)
      break
  
  region.address = nil
  region.size = 0
  region.isOwner = false

proc createMemoryView*(region: ZigMemoryRegion, offset: int = 0, length: int = -1): ZigMemoryView =
  ## メモリ領域のビューを作成する
  ##
  ## Parameters:
  ##   region: 元となるメモリ領域
  ##   offset: 領域内のオフセット（バイト単位）
  ##   length: ビューの長さ（-1の場合は領域の残りすべて）
  ##
  ## Returns:
  ##   作成されたメモリビュー
  ##
  ## Raises:
  ##   ZigMemoryError: 無効なオフセットや長さが指定された場合
  
  if region.address == nil:
    raise newException(ZigMemoryError, "Cannot create view from null memory region")
  
  if offset < 0 or offset >= region.size:
    raise newException(ZigMemoryError, "Invalid memory view offset")
  
  let actualLength = if length < 0: region.size - offset else: length
  
  if offset + actualLength > region.size:
    raise newException(ZigMemoryError, "Memory view extends beyond region bounds")
  
  result = ZigMemoryView(
    region: region,
    offset: offset,
    length: actualLength
  )

proc getViewAddress*(view: ZigMemoryView): pointer =
  ## メモリビューのアドレスを取得する
  ##
  ## Parameters:
  ##   view: アドレスを取得するメモリビュー
  ##
  ## Returns:
  ##   ビューの開始アドレス
  
  if view.region.address == nil:
    return nil
  
  result = cast[pointer](cast[int](view.region.address) + view.offset)

proc render*(commands: openArray[ZigRenderCommand], results: var openArray[ZigRenderResult]): bool =
  ## レンダリングコマンドをZigエンジンに送信する
  ##
  ## Parameters:
  ##   commands: 実行するレンダリングコマンドの配列
  ##   results: 各コマンドの結果を格納する配列
  ##
  ## Returns:
  ##   レンダリングが成功した場合はtrue、失敗した場合はfalse
  ##
  ## Raises:
  ##   ZigBindingError: レンダリング処理に失敗した場合
  
  if not zigInitialized:
    if not initialize():
      raise newException(ZigInitError, "Zig engine not initialized")
  
  if commands.len == 0:
    return true
  
  if results.len < commands.len:
    raise newException(ZigBindingError, "Results array size must match or exceed commands array size")
  
  let commandsPtr = unsafeAddr commands[0]
  let resultsPtr = addr results[0]
  
  let returnCode = zigRenderFn(commandsPtr, csize_t(commands.len), resultsPtr)
  if returnCode != 0:
    raise newException(ZigBindingError, "Render operation failed with code " & $returnCode)
  
  return true

type
  InfoType* = enum
    ## 取得可能な情報タイプを表す列挙型
    itVersion = 1,         # バージョン情報
    itFeatures = 2,        # サポート機能情報
    itPerformance = 3,     # パフォーマンス指標
    itMemoryUsage = 4,     # メモリ使用状況
    itRenderStats = 5      # レンダリング統計

  VersionInfo* = object
    ## バージョン情報を表す型
    major*: int32
    minor*: int32
    patch*: int32
    gitHash*: array[8, char]

  FeatureInfo* = object
    ## サポート機能情報を表す型
    hasWebGL*: bool
    hasWebGPU*: bool
    hasHardwareAcceleration*: bool
    maxTextureSize*: int32
    supportedImageFormats*: uint32

  PerformanceInfo* = object
    ## パフォーマンス指標を表す型
    frameTime*: float32
    cpuTime*: float32
    gpuTime*: float32
    memoryBandwidth*: float32

  MemoryUsageInfo* = object
    ## メモリ使用状況を表す型
    totalAllocated*: uint64
    peakAllocated*: uint64
    currentUsage*: uint64
    allocationCount*: uint32

  RenderStatInfo* = object
    ## レンダリング統計を表す型
    drawCalls*: uint32
    triangleCount*: uint32
    vertexCount*: uint32
    shaderSwitches*: uint32
    textureBinds*: uint32
    bufferUpdates*: uint32

proc queryInfo*[T](infoType: InfoType): T =
  ## Zigエンジンから情報を取得する
  ##
  ## Parameters:
  ##   infoType: 取得する情報のタイプ
  ##
  ## Returns:
  ##   取得した情報（指定した型に応じて適切なデータ構造が返される）
  ##
  ## Raises:
  ##   ZigBindingError: 情報取得に失敗した場合
  
  if not zigInitialized:
    if not initialize():
      raise newException(ZigInitError, "Zig engine not initialized")
  
  var resultObj: T
  let resultSize = sizeof(T)
  let resultPtr = addr resultObj
  
  let returnCode = zigQueryInfoFn(cint(infoType), resultPtr, csize_t(resultSize))
  if returnCode != 0:
    raise newException(ZigBindingError, "Query info operation failed with code " & $returnCode)
  
  return resultObj

type
  CallbackType* = enum
    ## コールバックタイプを表す列挙型
    cbRenderComplete = 1,    # レンダリング完了
    cbResourceLoaded = 2,    # リソースロード完了
    cbErrorOccurred = 3,     # エラー発生
    cbSceneReady = 4,        # シーン準備完了
    cbFrameStart = 5,        # フレーム開始
    cbFrameEnd = 6           # フレーム終了

  RenderCompleteCallback* = proc(commandId: uint32, success: bool): void {.cdecl.}
  ResourceLoadedCallback* = proc(resourceId: uint32, success: bool): void {.cdecl.}
  ErrorCallback* = proc(errorCode: uint32, message: cstring): void {.cdecl.}
  SceneReadyCallback* = proc(sceneId: uint32): void {.cdecl.}
  FrameCallback* = proc(frameNumber: uint64, timestamp: float64): void {.cdecl.}

var
  renderCompleteCallback: RenderCompleteCallback
  resourceLoadedCallback: ResourceLoadedCallback
  errorCallback: ErrorCallback
  sceneReadyCallback: SceneReadyCallback
  frameStartCallback: FrameCallback
  frameEndCallback: FrameCallback

proc registerCallback*[T](callbackType: CallbackType, callback: T): bool =
  ## Zigエンジンにコールバック関数を登録する
  ##
  ## Parameters:
  ##   callbackType: 登録するコールバックのタイプ
  ##   callback: コールバック関数
  ##
  ## Returns:
  ##   登録に成功した場合はtrue、失敗した場合はfalse
  
  if not zigInitialized:
    if not initialize():
      return false
  
  case callbackType
  of cbRenderComplete:
    renderCompleteCallback = cast[RenderCompleteCallback](callback)
    let returnCode = zigRegisterCallbackFn(cint(callbackType), cast[pointer](renderCompleteCallback))
    result = (returnCode == 0)
  
  of cbResourceLoaded:
    resourceLoadedCallback = cast[ResourceLoadedCallback](callback)
    let returnCode = zigRegisterCallbackFn(cint(callbackType), cast[pointer](resourceLoadedCallback))
    result = (returnCode == 0)
  
  of cbErrorOccurred:
    errorCallback = cast[ErrorCallback](callback)
    let returnCode = zigRegisterCallbackFn(cint(callbackType), cast[pointer](errorCallback))
    result = (returnCode == 0)
  
  of cbSceneReady:
    sceneReadyCallback = cast[SceneReadyCallback](callback)
    let returnCode = zigRegisterCallbackFn(cint(callbackType), cast[pointer](sceneReadyCallback))
    result = (returnCode == 0)
  
  of cbFrameStart:
    frameStartCallback = cast[FrameCallback](callback)
    let returnCode = zigRegisterCallbackFn(cint(callbackType), cast[pointer](frameStartCallback))
    result = (returnCode == 0)
  
  of cbFrameEnd:
    frameEndCallback = cast[FrameCallback](callback)
    let returnCode = zigRegisterCallbackFn(cint(callbackType), cast[pointer](frameEndCallback))
    result = (returnCode == 0)

# ユーティリティ関数

proc copyToMemory*[T](data: openArray[T], dest: ZigMemoryView): bool =
  ## データをZigメモリ領域にコピーする
  ##
  ## Parameters:
  ##   data: コピー元のデータ配列
  ##   dest: コピー先のメモリビュー
  ##
  ## Returns:
  ##   コピーに成功した場合はtrue、失敗した場合はfalse
  
  let dataSize = sizeof(T) * data.len
  if dataSize > dest.length:
    return false
  
  let destAddr = getViewAddress(dest)
  if destAddr == nil:
    return false
  
  if data.len > 0:
    copyMem(destAddr, unsafeAddr data[0], dataSize)
  
  return true

proc copyFromMemory*[T](src: ZigMemoryView, data: var openArray[T]): bool =
  ## Zigメモリ領域からデータをコピーする
  ##
  ## Parameters:
  ##   src: コピー元のメモリビュー
  ##   data: コピー先のデータ配列
  ##
  ## Returns:
  ##   コピーに成功した場合はtrue、失敗した場合はfalse
  
  let maxElements = src.length div sizeof(T)
  if maxElements <= 0 or data.len <= 0:
    return false
  
  let srcAddr = getViewAddress(src)
  if srcAddr == nil:
    return false
  
  let copyElements = min(data.len, maxElements)
  let copySize = sizeof(T) * copyElements
  
  if copyElements > 0:
    copyMem(addr data[0], srcAddr, copySize)
  
  return true 