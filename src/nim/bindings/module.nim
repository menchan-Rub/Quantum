## Nimからの言語間バインディングモジュール
##
## このモジュールはNimから他の言語（CrystalとZig）のコンポーネントを操作するための
## バインディングインターフェースを提供します。
##
## 主なコンポーネント:
## - Crystal UI コンポーネントとのバインディング
## - Zig レンダリングエンジンとのバインディング

import std/[os, tables, asyncdispatch]

# Crystalバインディング
import crystal/binding as crystal_binding
import crystal/ipc as crystal_ipc
import crystal/ui_components as crystal_ui

# Zigバインディング
import zig/binding as zig_binding
import zig/rendering as zig_rendering

export crystal_binding, crystal_ipc, crystal_ui
export zig_binding, zig_rendering

# 初期化関数
proc initialize*(crystalSocketPath: string = "", zigLibPath: string = ""): Future[bool] {.async.} =
  ## バインディングモジュールを初期化する
  ##
  ## Parameters:
  ##   crystalSocketPath: Crystal UIプロセスとの通信に使用するUNIXソケットパス
  ##   zigLibPath: Zigライブラリのパス
  ##
  ## Returns:
  ##   初期化に成功した場合はtrue、失敗した場合はfalse
  
  var success = true
  
  # Crystal UIの初期化
  if crystalSocketPath != "":
    success = success and await crystal_ui.initializeCrystalUi(crystalSocketPath)
  
  # Zigレンダリングエンジンの初期化
  if zigLibPath != "":
    # ライブラリのロード
    if not zig_binding.loadZigLibrary(zigLibPath):
      echo "Failed to load Zig library from: ", zigLibPath
      success = false
    
    # レンダリングエンジンの初期化
    if not zig_rendering.initializeRenderingEngine():
      echo "Failed to initialize Zig rendering engine"
      success = false
  
  return success

proc shutdown*(): Future[bool] {.async.} =
  ## バインディングモジュールをシャットダウンする
  ##
  ## Returns:
  ##   シャットダウンに成功した場合はtrue、失敗した場合はfalse
  
  var success = true
  
  # Crystal UIのシャットダウン
  await crystal_ui.shutdownCrystalUi()
  
  # Zigレンダリングエンジンのシャットダウン
  if not zig_rendering.shutdownRenderingEngine():
    echo "Warning: Failed to properly shutdown Zig rendering engine"
    success = false
  
  return success

when isMainModule:
  # モジュールのテスト
  echo "Testing bindings module..."
  
  proc testBindings() {.async.} =
    # 環境変数から接続情報を取得
    let crystalSocket = getEnv("CRYSTAL_IPC_SOCKET", "")
    let zigLibPath = getEnv("ZIG_LIB_PATH", "")
    
    # 初期化
    echo "Initializing bindings..."
    let initSuccess = await initialize(crystalSocket, zigLibPath)
    echo "Initialization ", if initSuccess: "successful" else: "failed"
    
    if initSuccess:
      # シャットダウン
      echo "Shutting down bindings..."
      let shutdownSuccess = await shutdown()
      echo "Shutdown ", if shutdownSuccess: "successful" else: "failed"
  
  waitFor testBindings() 