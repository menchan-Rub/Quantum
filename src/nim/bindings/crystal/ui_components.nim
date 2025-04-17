## Crystal UIコンポーネントを操作するための高レベルAPI
##
## このモジュールはNimからCrystalのUIコンポーネントを簡単に操作するための
## 高レベルAPIを提供します。UIコンポーネントの作成、操作、イベント処理などを
## 簡潔に記述できます。
##
## 主な機能:
## - UIコンポーネントの作成と管理
## - プロパティの設定
## - イベントハンドリング
## - レイアウト制御

import std/[asyncdispatch, json, options, tables, strutils]
import binding, ipc

type
  UiComponent* = ref object of RootObj
    ## UIコンポーネントの基本型
    instance*: CrystalInstance
    id*: string
    className*: string
    parent*: UiComponent
    children*: seq[UiComponent]

  UiContainer* = ref object of UiComponent
    ## 子要素を含むことができるコンテナコンポーネント
    layout*: string

  UiWindow* = ref object of UiContainer
    ## ウィンドウコンポーネント
    title*: string
    width*: int
    height*: int
    isModal*: bool

  UiPanel* = ref object of UiContainer
    ## パネルコンポーネント
    isScrollable*: bool

  UiButton* = ref object of UiComponent
    ## ボタンコンポーネント
    text*: string
    icon*: string
    isToggle*: bool
    isPressed*: bool

  UiLabel* = ref object of UiComponent
    ## ラベルコンポーネント
    text*: string
    alignment*: string
    isMultiline*: bool

  UiTextField* = ref object of UiComponent
    ## テキストフィールドコンポーネント
    text*: string
    placeholder*: string
    isPassword*: bool
    maxLength*: int

  UiCheckBox* = ref object of UiComponent
    ## チェックボックスコンポーネント
    text*: string
    isChecked*: bool

  UiRadioButton* = ref object of UiComponent
    ## ラジオボタンコンポーネント
    text*: string
    groupName*: string
    isSelected*: bool

  UiProgressBar* = ref object of UiComponent
    ## プログレスバーコンポーネント
    value*: float
    minValue*: float
    maxValue*: float
    isIndeterminate*: bool

  UiComboBox* = ref object of UiComponent
    ## コンボボックスコンポーネント
    items*: seq[string]
    selectedIndex*: int
    editable*: bool

  UiListBox* = ref object of UiComponent
    ## リストボックスコンポーネント
    items*: seq[string]
    selectedIndices*: seq[int]
    multiSelect*: bool

  UiTabView* = ref object of UiContainer
    ## タブビューコンポーネント
    tabs*: seq[string]
    activeTab*: int

  UiMenuBar* = ref object of UiContainer
    ## メニューバーコンポーネント
    menus*: seq[tuple[title: string, items: seq[tuple[title: string, action: proc()]]]]

  UiToolBar* = ref object of UiContainer
    ## ツールバーコンポーネント
    orientation*: string # "horizontal" or "vertical"

  UiEventCallback* = proc(sender: UiComponent, data: CrystalValue): Future[void] {.async.}
    ## UIイベントコールバック型

# マッピングテーブル（UiComponentとCrystalInstanceの対応）
var componentMap = initTable[int64, UiComponent]()

proc registerComponent(component: UiComponent) =
  ## コンポーネントとインスタンスのマッピングを登録
  componentMap[component.instance.instanceId] = component

proc findComponent(instanceId: int64): UiComponent =
  ## インスタンスIDからコンポーネントを取得
  if instanceId in componentMap:
    result = componentMap[instanceId]

# コンポーネント生成関数群

proc newComponent(className: string, args: seq[CrystalValue] = @[]): Future[UiComponent] {.async.} =
  ## 基本的なUIコンポーネントを作成する
  let instance = await createInstance(className, args)
  result = UiComponent(
    instance: instance,
    id: $instance.instanceId,
    className: className,
    parent: nil,
    children: @[]
  )
  registerComponent(result)

proc newContainer(className: string, layout: string = "vertical", args: seq[CrystalValue] = @[]): Future[UiContainer] {.async.} =
  ## コンテナコンポーネントを作成する
  let customArgs = args
  customArgs.add(newCrystalString(layout))
  let component = await newComponent(className, customArgs)
  result = UiContainer(component)
  result.layout = layout

proc newWindow*(title: string, width: int = 800, height: int = 600, isModal: bool = false): Future[UiWindow] {.async.} =
  ## ウィンドウを作成する
  ##
  ## Parameters:
  ##   title: ウィンドウのタイトル
  ##   width: ウィンドウの幅
  ##   height: ウィンドウの高さ
  ##   isModal: モーダルウィンドウかどうか
  ##
  ## Returns:
  ##   作成されたウィンドウコンポーネント
  
  let args = @[
    newCrystalString(title),
    newCrystalInt(width),
    newCrystalInt(height),
    newCrystalBool(isModal)
  ]
  
  let container = await newContainer("Window", "grid", args)
  result = UiWindow(container)
  result.title = title
  result.width = width
  result.height = height
  result.isModal = isModal

proc newPanel*(parent: UiContainer = nil, isScrollable: bool = false): Future[UiPanel] {.async.} =
  ## パネルを作成する
  ##
  ## Parameters:
  ##   parent: 親コンテナ（省略可）
  ##   isScrollable: スクロール可能かどうか
  ##
  ## Returns:
  ##   作成されたパネルコンポーネント
  
  let args = @[newCrystalBool(isScrollable)]
  let container = await newContainer("Panel", "vertical", args)
  result = UiPanel(container)
  result.isScrollable = isScrollable
  
  if parent != nil:
    result.parent = parent
    parent.children.add(result)
    
    # 親コンテナに追加するIPC呼び出し
    var addArgs = @[
      newCrystalInt(parent.instance.instanceId),
      newCrystalInt(result.instance.instanceId)
    ]
    discard await callMethod("Container", "addChild", addArgs)

proc newButton*(text: string, parent: UiContainer = nil, icon: string = "", isToggle: bool = false): Future[UiButton] {.async.} =
  ## ボタンを作成する
  ##
  ## Parameters:
  ##   text: ボタンのテキスト
  ##   parent: 親コンテナ（省略可）
  ##   icon: ボタンのアイコン（省略可）
  ##   isToggle: トグルボタンかどうか
  ##
  ## Returns:
  ##   作成されたボタンコンポーネント
  
  let args = @[
    newCrystalString(text),
    newCrystalString(icon),
    newCrystalBool(isToggle)
  ]
  
  let component = await newComponent("Button", args)
  result = UiButton(component)
  result.text = text
  result.icon = icon
  result.isToggle = isToggle
  result.isPressed = false
  
  if parent != nil:
    result.parent = parent
    parent.children.add(result)
    
    # 親コンテナに追加するIPC呼び出し
    var addArgs = @[
      newCrystalInt(parent.instance.instanceId),
      newCrystalInt(result.instance.instanceId)
    ]
    discard await callMethod("Container", "addChild", addArgs)

proc newLabel*(text: string, parent: UiContainer = nil, alignment: string = "left", isMultiline: bool = false): Future[UiLabel] {.async.} =
  ## ラベルを作成する
  ##
  ## Parameters:
  ##   text: ラベルのテキスト
  ##   parent: 親コンテナ（省略可）
  ##   alignment: テキストの揃え方 ("left", "center", "right")
  ##   isMultiline: 複数行表示かどうか
  ##
  ## Returns:
  ##   作成されたラベルコンポーネント
  
  let args = @[
    newCrystalString(text),
    newCrystalString(alignment),
    newCrystalBool(isMultiline)
  ]
  
  let component = await newComponent("Label", args)
  result = UiLabel(component)
  result.text = text
  result.alignment = alignment
  result.isMultiline = isMultiline
  
  if parent != nil:
    result.parent = parent
    parent.children.add(result)
    
    # 親コンテナに追加するIPC呼び出し
    var addArgs = @[
      newCrystalInt(parent.instance.instanceId),
      newCrystalInt(result.instance.instanceId)
    ]
    discard await callMethod("Container", "addChild", addArgs)

proc newTextField*(text: string = "", parent: UiContainer = nil, placeholder: string = "", isPassword: bool = false, maxLength: int = 0): Future[UiTextField] {.async.} =
  ## テキストフィールドを作成する
  ##
  ## Parameters:
  ##   text: 初期テキスト
  ##   parent: 親コンテナ（省略可）
  ##   placeholder: プレースホルダーテキスト
  ##   isPassword: パスワードフィールドかどうか
  ##   maxLength: 最大入力文字数（0は無制限）
  ##
  ## Returns:
  ##   作成されたテキストフィールドコンポーネント
  
  let args = @[
    newCrystalString(text),
    newCrystalString(placeholder),
    newCrystalBool(isPassword),
    newCrystalInt(maxLength)
  ]
  
  let component = await newComponent("TextField", args)
  result = UiTextField(component)
  result.text = text
  result.placeholder = placeholder
  result.isPassword = isPassword
  result.maxLength = maxLength
  
  if parent != nil:
    result.parent = parent
    parent.children.add(result)
    
    # 親コンテナに追加するIPC呼び出し
    var addArgs = @[
      newCrystalInt(parent.instance.instanceId),
      newCrystalInt(result.instance.instanceId)
    ]
    discard await callMethod("Container", "addChild", addArgs)

proc newCheckBox*(text: string, parent: UiContainer = nil, isChecked: bool = false): Future[UiCheckBox] {.async.} =
  ## チェックボックスを作成する
  ##
  ## Parameters:
  ##   text: チェックボックスのテキスト
  ##   parent: 親コンテナ（省略可）
  ##   isChecked: 初期状態でチェックするかどうか
  ##
  ## Returns:
  ##   作成されたチェックボックスコンポーネント
  
  let args = @[
    newCrystalString(text),
    newCrystalBool(isChecked)
  ]
  
  let component = await newComponent("CheckBox", args)
  result = UiCheckBox(component)
  result.text = text
  result.isChecked = isChecked
  
  if parent != nil:
    result.parent = parent
    parent.children.add(result)
    
    # 親コンテナに追加するIPC呼び出し
    var addArgs = @[
      newCrystalInt(parent.instance.instanceId),
      newCrystalInt(result.instance.instanceId)
    ]
    discard await callMethod("Container", "addChild", addArgs)

# プロパティ設定関数群

proc setText*(component: UiComponent, text: string): Future[bool] {.async.} =
  ## コンポーネントのテキストを設定する
  ##
  ## Parameters:
  ##   component: テキストを設定するコンポーネント
  ##   text: 設定するテキスト
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  let args = @[
    newCrystalInt(component.instance.instanceId),
    newCrystalString(text)
  ]
  
  try:
    discard await callMethod(component.className, "setText", args)
    
    # テキストプロパティを持つコンポーネントの場合、ローカルプロパティも更新
    if component of UiButton:
      UiButton(component).text = text
    elif component of UiLabel:
      UiLabel(component).text = text
    elif component of UiTextField:
      UiTextField(component).text = text
    elif component of UiCheckBox:
      UiCheckBox(component).text = text
    elif component of UiRadioButton:
      UiRadioButton(component).text = text
    elif component of UiWindow:
      UiWindow(component).title = text
      
    result = true
  except:
    echo "Error setting text: ", getCurrentExceptionMsg()
    result = false

proc setEnabled*(component: UiComponent, enabled: bool): Future[bool] {.async.} =
  ## コンポーネントの有効/無効状態を設定する
  ##
  ## Parameters:
  ##   component: 状態を設定するコンポーネント
  ##   enabled: 有効にする場合はtrue、無効にする場合はfalse
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  let args = @[
    newCrystalInt(component.instance.instanceId),
    newCrystalBool(enabled)
  ]
  
  try:
    discard await callMethod(component.className, "setEnabled", args)
    result = true
  except:
    echo "Error setting enabled state: ", getCurrentExceptionMsg()
    result = false

proc setVisible*(component: UiComponent, visible: bool): Future[bool] {.async.} =
  ## コンポーネントの表示/非表示を設定する
  ##
  ## Parameters:
  ##   component: 表示状態を設定するコンポーネント
  ##   visible: 表示する場合はtrue、非表示にする場合はfalse
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  let args = @[
    newCrystalInt(component.instance.instanceId),
    newCrystalBool(visible)
  ]
  
  try:
    discard await callMethod(component.className, "setVisible", args)
    result = true
  except:
    echo "Error setting visibility: ", getCurrentExceptionMsg()
    result = false

proc setProperty*(component: UiComponent, propertyName: string, value: CrystalValue): Future[bool] {.async.} =
  ## コンポーネントの任意のプロパティを設定する
  ##
  ## Parameters:
  ##   component: プロパティを設定するコンポーネント
  ##   propertyName: プロパティ名
  ##   value: 設定する値
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  let args = @[
    newCrystalInt(component.instance.instanceId),
    newCrystalString(propertyName),
    value
  ]
  
  try:
    discard await callMethod(component.className, "setProperty", args)
    result = true
  except:
    echo "Error setting property: ", getCurrentExceptionMsg()
    result = false

proc getProperty*(component: UiComponent, propertyName: string): Future[CrystalValue] {.async.} =
  ## コンポーネントの任意のプロパティを取得する
  ##
  ## Parameters:
  ##   component: プロパティを取得するコンポーネント
  ##   propertyName: プロパティ名
  ##
  ## Returns:
  ##   取得したプロパティ値
  
  let args = @[
    newCrystalInt(component.instance.instanceId),
    newCrystalString(propertyName)
  ]
  
  result = await callMethod(component.className, "getProperty", args)

# イベント処理関数群

proc addEventListener*(component: UiComponent, eventType: string, handler: UiEventCallback): Future[bool] {.async.} =
  ## コンポーネントにイベントリスナーを追加する
  ##
  ## Parameters:
  ##   component: イベントを監視するコンポーネント
  ##   eventType: イベントタイプ
  ##   handler: イベント発生時に呼び出されるコールバック関数
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  # コンポーネント固有のイベント名を生成
  let specificEventType = $component.instance.instanceId & ":" & eventType
  
  # イベントハンドラを作成・登録
  let eventHandler = proc(event: CrystalEvent): Future[void] {.async.} =
    if event.source != nil and event.source.instanceId == component.instance.instanceId:
      let comp = findComponent(event.source.instanceId)
      if comp != nil:
        await handler(comp, event.data)
  
  # Crystal側のイベントリスナーに登録
  await registerEventListener(specificEventType, eventHandler)
  
  # Crystal側のコンポーネントにもイベントリスナーを追加
  let args = @[
    newCrystalInt(component.instance.instanceId),
    newCrystalString(eventType),
    newCrystalString(specificEventType)
  ]
  
  try:
    discard await callMethod(component.className, "addEventListener", args)
    result = true
  except:
    echo "Error adding event listener: ", getCurrentExceptionMsg()
    result = false

proc removeEventListener*(component: UiComponent, eventType: string, handler: UiEventCallback): Future[bool] {.async.} =
  ## コンポーネントからイベントリスナーを削除する
  ##
  ## Parameters:
  ##   component: イベントの監視を解除するコンポーネント
  ##   eventType: イベントタイプ
  ##   handler: 削除するハンドラ関数
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  # コンポーネント固有のイベント名
  let specificEventType = $component.instance.instanceId & ":" & eventType
  
  # Crystal側のイベントリスナーも解除
  let args = @[
    newCrystalInt(component.instance.instanceId),
    newCrystalString(eventType),
    newCrystalString(specificEventType)
  ]
  
  try:
    discard await callMethod(component.className, "removeEventListener", args)
    result = true
  except:
    echo "Error removing event listener: ", getCurrentExceptionMsg()
    result = false

# レイアウト制御関数群

proc addChild*(container: UiContainer, child: UiComponent): Future[bool] {.async.} =
  ## コンテナに子要素を追加する
  ##
  ## Parameters:
  ##   container: 子要素を追加するコンテナ
  ##   child: 追加する子要素
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  # 既に親がある場合は一旦削除
  if child.parent != nil:
    child.parent.children.keepItIf(it != child)
  
  # 親子関係を更新
  child.parent = container
  container.children.add(child)
  
  # Crystal側のコンテナにも子要素を追加
  let args = @[
    newCrystalInt(container.instance.instanceId),
    newCrystalInt(child.instance.instanceId)
  ]
  
  try:
    discard await callMethod("Container", "addChild", args)
    result = true
  except:
    echo "Error adding child: ", getCurrentExceptionMsg()
    result = false

proc removeChild*(container: UiContainer, child: UiComponent): Future[bool] {.async.} =
  ## コンテナから子要素を削除する
  ##
  ## Parameters:
  ##   container: 子要素を削除するコンテナ
  ##   child: 削除する子要素
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  # 親子関係を更新
  container.children.keepItIf(it != child)
  child.parent = nil
  
  # Crystal側のコンテナからも子要素を削除
  let args = @[
    newCrystalInt(container.instance.instanceId),
    newCrystalInt(child.instance.instanceId)
  ]
  
  try:
    discard await callMethod("Container", "removeChild", args)
    result = true
  except:
    echo "Error removing child: ", getCurrentExceptionMsg()
    result = false

proc clearChildren*(container: UiContainer): Future[bool] {.async.} =
  ## コンテナから全ての子要素を削除する
  ##
  ## Parameters:
  ##   container: 子要素をクリアするコンテナ
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  # すべての子コンポーネントの親参照をクリア
  for child in container.children:
    child.parent = nil
  
  # 子リストをクリア
  container.children.setLen(0)
  
  # Crystal側のコンテナからも全ての子要素を削除
  let args = @[newCrystalInt(container.instance.instanceId)]
  
  try:
    discard await callMethod("Container", "clearChildren", args)
    result = true
  except:
    echo "Error clearing children: ", getCurrentExceptionMsg()
    result = false

proc setLayout*(container: UiContainer, layoutType: string): Future[bool] {.async.} =
  ## コンテナのレイアウトタイプを設定する
  ##
  ## Parameters:
  ##   container: レイアウトを設定するコンテナ
  ##   layoutType: レイアウトタイプ ("vertical", "horizontal", "grid", "flow")
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  # ローカルプロパティを更新
  container.layout = layoutType
  
  # Crystal側のコンテナのレイアウトも変更
  let args = @[
    newCrystalInt(container.instance.instanceId),
    newCrystalString(layoutType)
  ]
  
  try:
    discard await callMethod("Container", "setLayout", args)
    result = true
  except:
    echo "Error setting layout: ", getCurrentExceptionMsg()
    result = false

# ウィンドウ特有の操作関数

proc show*(window: UiWindow): Future[bool] {.async.} =
  ## ウィンドウを表示する
  ##
  ## Parameters:
  ##   window: 表示するウィンドウ
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  let args = @[newCrystalInt(window.instance.instanceId)]
  
  try:
    discard await callMethod("Window", "show", args)
    result = true
  except:
    echo "Error showing window: ", getCurrentExceptionMsg()
    result = false

proc hide*(window: UiWindow): Future[bool] {.async.} =
  ## ウィンドウを非表示にする
  ##
  ## Parameters:
  ##   window: 非表示にするウィンドウ
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  let args = @[newCrystalInt(window.instance.instanceId)]
  
  try:
    discard await callMethod("Window", "hide", args)
    result = true
  except:
    echo "Error hiding window: ", getCurrentExceptionMsg()
    result = false

proc close*(window: UiWindow): Future[bool] {.async.} =
  ## ウィンドウを閉じる（破棄する）
  ##
  ## Parameters:
  ##   window: 閉じるウィンドウ
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  let args = @[newCrystalInt(window.instance.instanceId)]
  
  try:
    discard await callMethod("Window", "close", args)
    
    # ウィンドウとその子要素をマッピングから削除
    proc removeFromMap(component: UiComponent) =
      componentMap.del(component.instance.instanceId)
      if component of UiContainer:
        for child in UiContainer(component).children:
          removeFromMap(child)
    
    removeFromMap(window)
    result = true
  except:
    echo "Error closing window: ", getCurrentExceptionMsg()
    result = false

proc setTitle*(window: UiWindow, title: string): Future[bool] {.async.} =
  ## ウィンドウのタイトルを設定する
  ##
  ## Parameters:
  ##   window: タイトルを設定するウィンドウ
  ##   title: 設定するタイトル
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  window.title = title
  result = await setText(window, title)

proc setSize*(window: UiWindow, width: int, height: int): Future[bool] {.async.} =
  ## ウィンドウのサイズを設定する
  ##
  ## Parameters:
  ##   window: サイズを設定するウィンドウ
  ##   width: ウィンドウの幅
  ##   height: ウィンドウの高さ
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  let args = @[
    newCrystalInt(window.instance.instanceId),
    newCrystalInt(width),
    newCrystalInt(height)
  ]
  
  try:
    discard await callMethod("Window", "setSize", args)
    window.width = width
    window.height = height
    result = true
  except:
    echo "Error setting window size: ", getCurrentExceptionMsg()
    result = false

# UIコンポーネント固有の操作関数

proc getValue*(component: UiComponent): Future[CrystalValue] {.async.} =
  ## コンポーネントの値を取得する
  ##
  ## Parameters:
  ##   component: 値を取得するコンポーネント
  ##
  ## Returns:
  ##   コンポーネントの値
  
  let args = @[newCrystalInt(component.instance.instanceId)]
  
  result = await callMethod(component.className, "getValue", args)

proc setValue*(component: UiComponent, value: CrystalValue): Future[bool] {.async.} =
  ## コンポーネントの値を設定する
  ##
  ## Parameters:
  ##   component: 値を設定するコンポーネント
  ##   value: 設定する値
  ##
  ## Returns:
  ##   成功した場合はtrue
  
  let args = @[
    newCrystalInt(component.instance.instanceId),
    value
  ]
  
  try:
    discard await callMethod(component.className, "setValue", args)
    
    # 型に応じたローカルプロパティの更新
    case component.className
    of "CheckBox":
      if value.kind == cvkBool:
        UiCheckBox(component).isChecked = value.boolVal
    of "TextField":
      if value.kind == cvkString:
        UiTextField(component).text = value.stringVal
    of "ProgressBar":
      if value.kind == cvkFloat:
        UiProgressBar(component).value = value.floatVal
      elif value.kind == cvkInt:
        UiProgressBar(component).value = float(value.intVal)
    of "ComboBox":
      if value.kind == cvkInt:
        UiComboBox(component).selectedIndex = int(value.intVal)
    
    result = true
  except:
    echo "Error setting value: ", getCurrentExceptionMsg()
    result = false

# 初期化・終了処理

proc initializeCrystalUi*(socketPath: string = ""): Future[bool] {.async.} =
  ## Crystal UIシステムを初期化する
  ##
  ## Parameters:
  ##   socketPath: Crystal UIプロセスとの通信に使用するUNIXソケットパス
  ##
  ## Returns:
  ##   初期化に成功した場合はtrue
  
  # Crystal基本バインディングを初期化
  if not binding.initialize(socketPath):
    return false
  
  # IPC接続を確立
  if not await connect(socketPath):
    return false
  
  result = true

proc shutdownCrystalUi*(): Future[void] {.async.} =
  ## Crystal UIシステムを終了する
  await disconnect() 