## Zigレンダリングエンジンを操作するための高レベルAPI
##
## このモジュールはNimからZigで実装されたレンダリングエンジンを
## 簡単に操作するための高レベルAPIを提供します。
##
## 主な機能:
## - レンダリングコンテキストの管理
## - シーンとオブジェクトの操作
## - テクスチャとマテリアルの管理
## - レンダリングパイプラインの制御

import std/[asyncdispatch, options, tables, strutils]
import binding

type
  RenderContextHandle* = distinct uint32
  SceneHandle* = distinct uint32
  MaterialHandle* = distinct uint32
  MeshHandle* = distinct uint32
  TextureHandle* = distinct uint32
  ShaderHandle* = distinct uint32
  BufferHandle* = distinct uint32
  ObjectHandle* = distinct uint32
  CameraHandle* = distinct uint32
  LightHandle* = distinct uint32

  Vec2* = object
    x*, y*: float32

  Vec3* = object
    x*, y*, z*: float32

  Vec4* = object
    x*, y*, z*, w*: float32

  Mat4* = object
    data*: array[16, float32]

  Color* = distinct Vec4

  Quaternion* = object
    x*, y*, z*, w*: float32

  Transform* = object
    position*: Vec3
    rotation*: Quaternion
    scale*: Vec3

  BoundingBox* = object
    min*: Vec3
    max*: Vec3

  Viewport* = object
    x*, y*: int32
    width*, height*: int32

  RenderQuality* = enum
    rqLow, rqMedium, rqHigh, rqUltra

  TextureFormat* = enum
    tfRGBA8, tfRGB8, tfRGBA16F, tfR8, tfRG8,
    tfBGRA8, tfDepth16, tfDepth24, tfDepth32F

  TextureFilter* = enum
    tfNearest, tfLinear, tfMipmap

  TextureWrap* = enum
    twClamp, twRepeat, twMirror

  ShaderType* = enum
    stVertex, stFragment, stCompute

  PrimitiveType* = enum
    ptPoints, ptLines, ptLineStrip, 
    ptTriangles, ptTriangleStrip

  BufferUsage* = enum
    buStatic, buDynamic, buStream

  BufferType* = enum
    btVertex, btIndex, btUniform

  LightType* = enum
    ltDirectional, ltPoint, ltSpot, ltArea

  ShadowType* = enum
    stNone, stHard, stSoft, stPCF

  BlendMode* = enum
    bmNone, bmAlpha, bmAdditive, bmMultiply

  CullMode* = enum
    cmNone, cmBack, cmFront, cmBoth

  RenderPass* = enum
    rpColor, rpDepth, rpShadow, rpPostProcess

# 内部管理用のリソーステーブル
var
  activeContext: RenderContextHandle
  scenes: Table[SceneHandle, string]
  materials: Table[MaterialHandle, string]
  meshes: Table[MeshHandle, string]
  textures: Table[TextureHandle, string]
  shaders: Table[ShaderHandle, string]
  buffers: Table[BufferHandle, string]
  objects: Table[ObjectHandle, string]
  cameras: Table[CameraHandle, string]
  lights: Table[LightHandle, string]

# 数学ユーティリティ関数

proc vec2*(x, y: float32): Vec2 =
  ## 2次元ベクトルを作成する
  result.x = x
  result.y = y

proc vec3*(x, y, z: float32): Vec3 =
  ## 3次元ベクトルを作成する
  result.x = x
  result.y = y
  result.z = z

proc vec4*(x, y, z, w: float32): Vec4 =
  ## 4次元ベクトルを作成する
  result.x = x
  result.y = y
  result.z = z
  result.w = w

proc color*(r, g, b, a: float32): Color =
  ## RGBAカラーを作成する
  result = Color(Vec4(x: r, y: g, z: b, w: a))

proc rgb*(r, g, b: float32): Color =
  ## RGBカラーを作成する（アルファは1.0）
  result = Color(Vec4(x: r, y: g, z: b, w: 1.0))

proc rgba*(r, g, b, a: float32): Color =
  ## RGBAカラーを作成する
  color(r, g, b, a)

proc identity*(): Mat4 =
  ## 単位行列を作成する
  result.data[0] = 1.0
  result.data[5] = 1.0
  result.data[10] = 1.0
  result.data[15] = 1.0

proc quaternion*(x, y, z, w: float32): Quaternion =
  ## クォータニオンを作成する
  result.x = x
  result.y = y
  result.z = z
  result.w = w

proc transform*(): Transform =
  ## デフォルトの変換（単位変換）を作成する
  result.position = vec3(0, 0, 0)
  result.rotation = quaternion(0, 0, 0, 1)
  result.scale = vec3(1, 1, 1)

# レンダリングコンテキスト管理

proc createRenderContext*(width, height: int32, quality: RenderQuality = rqMedium): RenderContextHandle =
  ## レンダリングコンテキストを作成する
  ##
  ## Parameters:
  ##   width: レンダリング領域の幅
  ##   height: レンダリング領域の高さ
  ##   quality: レンダリング品質
  ##
  ## Returns:
  ##   作成されたレンダリングコンテキストのハンドル
  
  # コマンドとリザルトの準備
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  # コマンドの設定
  commands[0].commandType = 1  # CREATE_CONTEXT
  commands[0].params[0] = uint64(width)
  commands[0].params[1] = uint64(height)
  commands[0].params[2] = uint64(ord(quality))
  
  # コマンドの実行
  if not binding.render(commands, results):
    raise newException(ZigBindingError, "Failed to create render context")
  
  if not results[0].success:
    raise newException(ZigBindingError, "Context creation failed: " & $results[0].errorCode)
  
  # ハンドルを返す
  result = RenderContextHandle(results[0].params[0])
  activeContext = result

proc setActiveContext*(context: RenderContextHandle): bool =
  ## アクティブなレンダリングコンテキストを設定する
  ##
  ## Parameters:
  ##   context: アクティブにするコンテキスト
  ##
  ## Returns:
  ##   成功した場合はtrue、失敗した場合はfalse
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  commands[0].commandType = 2  # SET_ACTIVE_CONTEXT
  commands[0].params[0] = uint64(context)
  
  if not binding.render(commands, results):
    return false
  
  if not results[0].success:
    return false
  
  activeContext = context
  return true

proc resizeContext*(width, height: int32): bool =
  ## アクティブなレンダリングコンテキストのサイズを変更する
  ##
  ## Parameters:
  ##   width: 新しい幅
  ##   height: 新しい高さ
  ##
  ## Returns:
  ##   成功した場合はtrue、失敗した場合はfalse
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  commands[0].commandType = 3  # RESIZE_CONTEXT
  commands[0].targetId = uint32(activeContext)
  commands[0].params[0] = uint64(width)
  commands[0].params[1] = uint64(height)
  
  if not binding.render(commands, results):
    return false
  
  return results[0].success

proc destroyContext*(context: RenderContextHandle): bool =
  ## レンダリングコンテキストを破棄する
  ##
  ## Parameters:
  ##   context: 破棄するコンテキスト
  ##
  ## Returns:
  ##   成功した場合はtrue、失敗した場合はfalse
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  commands[0].commandType = 4  # DESTROY_CONTEXT
  commands[0].params[0] = uint64(context)
  
  if not binding.render(commands, results):
    return false
  
  if not results[0].success:
    return false
  
  if activeContext == context:
    activeContext = RenderContextHandle(0)
  
  return true

# シーン管理

proc createScene*(name: string = ""): SceneHandle =
  ## 新しいシーンを作成する
  ##
  ## Parameters:
  ##   name: シーンの名前（オプション）
  ##
  ## Returns:
  ##   作成されたシーンのハンドル
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  # シーン名のためのメモリを確保
  let nameBytes = name.len + 1
  var nameRegion = allocateMemory(nameBytes, "scene_name")
  defer: freeMemory(nameRegion)
  
  let nameView = createMemoryView(nameRegion)
  let nameAddr = getViewAddress(nameView)
  
  # 名前をコピー
  if name.len > 0:
    copyMem(nameAddr, unsafeAddr name[0], name.len)
  
  # NULL終端
  cast[ptr char](cast[int](nameAddr) + name.len)[] = '\0'
  
  # コマンドの設定
  commands[0].commandType = 10  # CREATE_SCENE
  commands[0].targetId = uint32(activeContext)
  commands[0].params[0] = cast[uint64](nameAddr)
  
  # コマンドの実行
  if not binding.render(commands, results):
    raise newException(ZigBindingError, "Failed to create scene")
  
  if not results[0].success:
    raise newException(ZigBindingError, "Scene creation failed: " & $results[0].errorCode)
  
  # ハンドルを返す
  result = SceneHandle(results[0].params[0])
  
  # 名前を保存（空の場合は自動生成された名前を使用）
  let returnedName = if name == "": "scene_" & $uint32(result) else: name
  scenes[result] = returnedName

proc setActiveScene*(scene: SceneHandle): bool =
  ## アクティブなシーンを設定する
  ##
  ## Parameters:
  ##   scene: アクティブにするシーン
  ##
  ## Returns:
  ##   成功した場合はtrue、失敗した場合はfalse
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  commands[0].commandType = 11  # SET_ACTIVE_SCENE
  commands[0].targetId = uint32(activeContext)
  commands[0].params[0] = uint64(scene)
  
  if not binding.render(commands, results):
    return false
  
  return results[0].success

proc destroyScene*(scene: SceneHandle): bool =
  ## シーンを破棄する
  ##
  ## Parameters:
  ##   scene: 破棄するシーン
  ##
  ## Returns:
  ##   成功した場合はtrue、失敗した場合はfalse
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  commands[0].commandType = 12  # DESTROY_SCENE
  commands[0].targetId = uint32(activeContext)
  commands[0].params[0] = uint64(scene)
  
  if not binding.render(commands, results):
    return false
  
  if results[0].success:
    scenes.del(scene)
    return true
  
  return false

# カメラ管理

proc createCamera*(scene: SceneHandle, name: string = ""): CameraHandle =
  ## シーンにカメラを作成する
  ##
  ## Parameters:
  ##   scene: カメラを追加するシーン
  ##   name: カメラの名前（オプション）
  ##
  ## Returns:
  ##   作成されたカメラのハンドル
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  # カメラ名のためのメモリを確保
  let nameBytes = name.len + 1
  var nameRegion = allocateMemory(nameBytes, "camera_name")
  defer: freeMemory(nameRegion)
  
  let nameView = createMemoryView(nameRegion)
  let nameAddr = getViewAddress(nameView)
  
  # 名前をコピー
  if name.len > 0:
    copyMem(nameAddr, unsafeAddr name[0], name.len)
  
  # NULL終端
  cast[ptr char](cast[int](nameAddr) + name.len)[] = '\0'
  
  # コマンドの設定
  commands[0].commandType = 20  # CREATE_CAMERA
  commands[0].targetId = uint32(scene)
  commands[0].params[0] = cast[uint64](nameAddr)
  
  # コマンドの実行
  if not binding.render(commands, results):
    raise newException(ZigBindingError, "Failed to create camera")
  
  if not results[0].success:
    raise newException(ZigBindingError, "Camera creation failed: " & $results[0].errorCode)
  
  # ハンドルを返す
  result = CameraHandle(results[0].params[0])
  
  # 名前を保存
  let returnedName = if name == "": "camera_" & $uint32(result) else: name
  cameras[result] = returnedName

proc setCameraTransform*(camera: CameraHandle, transform: Transform): bool =
  ## カメラの変換行列を設定する
  ##
  ## Parameters:
  ##   camera: 設定するカメラ
  ##   transform: 設定する変換
  ##
  ## Returns:
  ##   成功した場合はtrue、失敗した場合はfalse
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  # 変換データのためのメモリを確保
  var transformRegion = allocateMemory(sizeof(Transform), "camera_transform")
  defer: freeMemory(transformRegion)
  
  let transformView = createMemoryView(transformRegion)
  let transformAddr = getViewAddress(transformView)
  
  # 変換データをコピー
  copyMem(transformAddr, unsafeAddr transform, sizeof(Transform))
  
  # コマンドの設定
  commands[0].commandType = 21  # SET_CAMERA_TRANSFORM
  commands[0].targetId = uint32(camera)
  commands[0].params[0] = cast[uint64](transformAddr)
  
  # コマンドの実行
  if not binding.render(commands, results):
    return false
  
  return results[0].success

proc setCameraProjection*(camera: CameraHandle, fov: float32, aspect: float32, near: float32, far: float32): bool =
  ## カメラのプロジェクション設定を行う
  ##
  ## Parameters:
  ##   camera: 設定するカメラ
  ##   fov: 視野角（ラジアン）
  ##   aspect: アスペクト比
  ##   near: ニアクリップ距離
  ##   far: ファークリップ距離
  ##
  ## Returns:
  ##   成功した場合はtrue、失敗した場合はfalse
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  # コマンドの設定
  commands[0].commandType = 22  # SET_CAMERA_PROJECTION
  commands[0].targetId = uint32(camera)
  commands[0].params[0] = cast[uint64](unsafeAddr fov)
  commands[0].params[1] = cast[uint64](unsafeAddr aspect)
  commands[0].params[2] = cast[uint64](unsafeAddr near)
  commands[0].params[3] = cast[uint64](unsafeAddr far)
  
  # コマンドの実行
  if not binding.render(commands, results):
    return false
  
  return results[0].success

proc setActiveCamera*(scene: SceneHandle, camera: CameraHandle): bool =
  ## シーンのアクティブカメラを設定する
  ##
  ## Parameters:
  ##   scene: カメラを設定するシーン
  ##   camera: アクティブにするカメラ
  ##
  ## Returns:
  ##   成功した場合はtrue、失敗した場合はfalse
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  commands[0].commandType = 23  # SET_ACTIVE_CAMERA
  commands[0].targetId = uint32(scene)
  commands[0].params[0] = uint64(camera)
  
  if not binding.render(commands, results):
    return false
  
  return results[0].success

# メッシュ操作

proc createMesh*(vertices: openArray[float32], indices: openArray[uint32], name: string = ""): MeshHandle =
  ## 頂点データとインデックスデータからメッシュを作成する
  ##
  ## Parameters:
  ##   vertices: 頂点データ（位置、法線、UV座標などを含む）
  ##   indices: インデックスデータ
  ##   name: メッシュの名前（オプション）
  ##
  ## Returns:
  ##   作成されたメッシュのハンドル
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  # 名前のためのメモリを確保
  let nameBytes = name.len + 1
  var nameRegion = allocateMemory(nameBytes, "mesh_name")
  defer: freeMemory(nameRegion)
  
  let nameView = createMemoryView(nameRegion)
  let nameAddr = getViewAddress(nameView)
  
  # 名前をコピー
  if name.len > 0:
    copyMem(nameAddr, unsafeAddr name[0], name.len)
  
  # NULL終端
  cast[ptr char](cast[int](nameAddr) + name.len)[] = '\0'
  
  # 頂点データのためのメモリを確保
  let verticesBytes = vertices.len * sizeof(float32)
  var verticesRegion = allocateMemory(verticesBytes, "mesh_vertices")
  defer: freeMemory(verticesRegion)
  
  let verticesView = createMemoryView(verticesRegion)
  let verticesAddr = getViewAddress(verticesView)
  
  # 頂点データをコピー
  if vertices.len > 0:
    copyMem(verticesAddr, unsafeAddr vertices[0], verticesBytes)
  
  # インデックスデータのためのメモリを確保
  let indicesBytes = indices.len * sizeof(uint32)
  var indicesRegion = allocateMemory(indicesBytes, "mesh_indices")
  defer: freeMemory(indicesRegion)
  
  let indicesView = createMemoryView(indicesRegion)
  let indicesAddr = getViewAddress(indicesView)
  
  # インデックスデータをコピー
  if indices.len > 0:
    copyMem(indicesAddr, unsafeAddr indices[0], indicesBytes)
  
  # コマンドの設定
  commands[0].commandType = 30  # CREATE_MESH
  commands[0].targetId = uint32(activeContext)
  commands[0].params[0] = cast[uint64](nameAddr)
  commands[0].params[1] = cast[uint64](verticesAddr)
  commands[0].params[2] = uint64(vertices.len)
  commands[0].params[3] = cast[uint64](indicesAddr)
  commands[0].params[4] = uint64(indices.len)
  
  # コマンドの実行
  if not binding.render(commands, results):
    raise newException(ZigBindingError, "Failed to create mesh")
  
  if not results[0].success:
    raise newException(ZigBindingError, "Mesh creation failed: " & $results[0].errorCode)
  
  # ハンドルを返す
  result = MeshHandle(results[0].params[0])
  
  # 名前を保存
  let returnedName = if name == "": "mesh_" & $uint32(result) else: name
  meshes[result] = returnedName

proc updateMesh*(mesh: MeshHandle, vertices: openArray[float32], indices: openArray[uint32]): bool =
  ## メッシュの頂点データとインデックスデータを更新する
  ##
  ## Parameters:
  ##   mesh: 更新するメッシュ
  ##   vertices: 新しい頂点データ
  ##   indices: 新しいインデックスデータ
  ##
  ## Returns:
  ##   成功した場合はtrue、失敗した場合はfalse
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  # 頂点データのためのメモリを確保
  let verticesBytes = vertices.len * sizeof(float32)
  var verticesRegion = allocateMemory(verticesBytes, "mesh_vertices_update")
  defer: freeMemory(verticesRegion)
  
  let verticesView = createMemoryView(verticesRegion)
  let verticesAddr = getViewAddress(verticesView)
  
  # 頂点データをコピー
  if vertices.len > 0:
    copyMem(verticesAddr, unsafeAddr vertices[0], verticesBytes)
  
  # インデックスデータのためのメモリを確保
  let indicesBytes = indices.len * sizeof(uint32)
  var indicesRegion = allocateMemory(indicesBytes, "mesh_indices_update")
  defer: freeMemory(indicesRegion)
  
  let indicesView = createMemoryView(indicesRegion)
  let indicesAddr = getViewAddress(indicesView)
  
  # インデックスデータをコピー
  if indices.len > 0:
    copyMem(indicesAddr, unsafeAddr indices[0], indicesBytes)
  
  # コマンドの設定
  commands[0].commandType = 31  # UPDATE_MESH
  commands[0].targetId = uint32(mesh)
  commands[0].params[0] = cast[uint64](verticesAddr)
  commands[0].params[1] = uint64(vertices.len)
  commands[0].params[2] = cast[uint64](indicesAddr)
  commands[0].params[3] = uint64(indices.len)
  
  # コマンドの実行
  if not binding.render(commands, results):
    return false
  
  return results[0].success

proc destroyMesh*(mesh: MeshHandle): bool =
  ## メッシュを破棄する
  ##
  ## Parameters:
  ##   mesh: 破棄するメッシュ
  ##
  ## Returns:
  ##   成功した場合はtrue、失敗した場合はfalse
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  commands[0].commandType = 32  # DESTROY_MESH
  commands[0].targetId = uint32(mesh)
  
  if not binding.render(commands, results):
    return false
  
  if results[0].success:
    meshes.del(mesh)
    return true
  
  return false

# レンダリング操作

proc renderFrame*(): bool =
  ## 現在のシーンをレンダリングする
  ##
  ## Returns:
  ##   成功した場合はtrue、失敗した場合はfalse
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  commands[0].commandType = 100  # RENDER_FRAME
  commands[0].targetId = uint32(activeContext)
  
  if not binding.render(commands, results):
    return false
  
  return results[0].success

proc renderSceneToTexture*(scene: SceneHandle, texture: TextureHandle): bool =
  ## シーンをテクスチャにレンダリングする
  ##
  ## Parameters:
  ##   scene: レンダリングするシーン
  ##   texture: レンダリング先のテクスチャ
  ##
  ## Returns:
  ##   成功した場合はtrue、失敗した場合はfalse
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  commands[0].commandType = 101  # RENDER_SCENE_TO_TEXTURE
  commands[0].targetId = uint32(scene)
  commands[0].params[0] = uint64(texture)
  
  if not binding.render(commands, results):
    return false
  
  return results[0].success

proc clearColor*(r, g, b, a: float32): bool =
  ## レンダリングターゲットをクリアする
  ##
  ## Parameters:
  ##   r, g, b, a: クリアカラー（RGBA）
  ##
  ## Returns:
  ##   成功した場合はtrue、失敗した場合はfalse
  
  var commands: array[1, ZigRenderCommand]
  var results: array[1, ZigRenderResult]
  
  # カラーデータのためのメモリを確保
  var colorData: array[4, float32] = [r, g, b, a]
  var colorRegion = allocateMemory(sizeof(colorData), "clear_color")
  defer: freeMemory(colorRegion)
  
  let colorView = createMemoryView(colorRegion)
  let colorAddr = getViewAddress(colorView)
  
  # カラーデータをコピー
  copyMem(colorAddr, addr colorData[0], sizeof(colorData))
  
  # コマンドの設定
  commands[0].commandType = 102  # CLEAR_COLOR
  commands[0].targetId = uint32(activeContext)
  commands[0].params[0] = cast[uint64](colorAddr)
  
  # コマンドの実行
  if not binding.render(commands, results):
    return false
  
  return results[0].success

# 初期化と終了

proc initializeRenderingEngine*(): bool =
  ## レンダリングエンジンを初期化する
  ##
  ## Returns:
  ##   初期化に成功した場合はtrue、失敗した場合はfalse
  
  # 基本バインディングを初期化
  if not binding.initialize():
    return false
  
  return true

proc shutdownRenderingEngine*(): bool =
  ## レンダリングエンジンをシャットダウンする
  ##
  ## Returns:
  ##   シャットダウンに成功した場合はtrue、失敗した場合はfalse
  
  # すべてのリソーステーブルをクリア
  scenes.clear()
  materials.clear()
  meshes.clear()
  textures.clear()
  shaders.clear()
  buffers.clear()
  objects.clear()
  cameras.clear()
  lights.clear()
  
  # バインディングをシャットダウン
  return binding.shutdown()