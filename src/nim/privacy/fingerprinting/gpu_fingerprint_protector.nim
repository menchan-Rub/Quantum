# gpu_fingerprint_protector.nim
## GPU関連フィンガープリント保護の強化モジュール
## WebGLやCanvas、GPUに関する情報を詳細に制御・偽装する機能を提供

import std/[
  options,
  tables,
  sets,
  hashes,
  strutils,
  strformat,
  sequtils,
  algorithm,
  times,
  random,
  json,
  logging,
  math
]

type
  GpuFingerprintProtector* = ref GpuFingerprintProtectorObj
  GpuFingerprintProtectorObj = object
    enabled*: bool                ## 有効フラグ
    uniformNoiseLevel*: float     ## WebGL uniformに適用するノイズレベル
    precisionReduction*: bool     ## 精度を落とすかどうか
    vendorSpoofing*: bool         ## ベンダー情報偽装
    parameterRestriction*: bool   ## パラメータ制限
    consistentProfile*: bool      ## 一貫したプロファイル使用
    sessionKey*: string           ## セッションキー
    logger*: Logger               ## ロガー
    webglProfile*: WebGLProfile   ## 使用するWebGLプロファイル
    shaderHashWhitelist*: HashSet[string]  ## 許可するシェーダーハッシュ

  WebGLProfile* = object
    vendor*: string               ## ベンダー名
    renderer*: string             ## レンダラー名
    shadingLanguageVersion*: string  ## シェーダー言語バージョン
    maxTextureSize*: int          ## 最大テクスチャサイズ
    maxCubeMapTextureSize*: int   ## 最大キューブマップテクスチャサイズ
    maxRenderbufferSize*: int     ## 最大レンダーバッファサイズ
    maxViewportDims*: tuple[width, height: int]  ## 最大ビューポートサイズ
    maxVertexAttribs*: int        ## 最大頂点属性数
    maxVertexUniformVectors*: int ## 最大頂点Uniform変数数
    maxFragmentUniformVectors*: int  ## 最大フラグメントUniform変数数
    maxVertexTextureImageUnits*: int  ## 最大頂点テクスチャイメージユニット数
    maxTextureImageUnits*: int    ## 最大テクスチャイメージユニット数
    precision*: tuple[vertex, fragment: string]  ## 精度情報
    supportedExtensions*: seq[string]  ## サポートする拡張機能
    antialiasing*: bool           ## アンチエイリアシングサポート

  ShaderNoiseMethod* = enum
    snmNone,                      ## ノイズなし
    snmUniformValue,              ## Uniform値にノイズ追加
    snmTextureCoords,             ## テクスチャ座標にノイズ追加
    snmColorOutput,               ## 出力色にノイズ追加
    snmPrecisionLoss              ## 精度を落とす

  GpuCapabilityScope* = enum
    gcsWebGL1,                    ## WebGL 1.0
    gcsWebGL2,                    ## WebGL 2.0
    gcsCanvas2D,                  ## Canvas 2D
    gcsWebGPU                     ## WebGPU

const
  # 標準的なWebGLプロファイル
  STANDARD_WEBGL_PROFILES = [
    WebGLProfile(
      vendor: "Google Inc.",
      renderer: "ANGLE (Intel, Intel(R) UHD Graphics 620 Direct3D11 vs_5_0 ps_5_0)",
      shadingLanguageVersion: "WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)",
      maxTextureSize: 8192,
      maxCubeMapTextureSize: 8192,
      maxRenderbufferSize: 8192,
      maxViewportDims: (width: 8192, height: 8192),
      maxVertexAttribs: 16,
      maxVertexUniformVectors: 251,
      maxFragmentUniformVectors: 221,
      maxVertexTextureImageUnits: 16,
      maxTextureImageUnits: 16,
      precision: (vertex: "highp", fragment: "mediump"),
      supportedExtensions: @[
        "ANGLE_instanced_arrays",
        "EXT_blend_minmax",
        "EXT_color_buffer_half_float",
        "EXT_float_blend",
        "EXT_texture_filter_anisotropic",
        "OES_element_index_uint",
        "OES_standard_derivatives",
        "OES_texture_float",
        "OES_texture_float_linear",
        "OES_texture_half_float",
        "OES_texture_half_float_linear",
        "OES_vertex_array_object",
        "WEBGL_color_buffer_float",
        "WEBGL_compressed_texture_s3tc",
        "WEBGL_debug_renderer_info",
        "WEBGL_debug_shaders",
        "WEBGL_lose_context",
        "WEBGL_multi_draw"
      ],
      antialiasing: true
    ),
    WebGLProfile(
      vendor: "Google Inc.",
      renderer: "ANGLE (NVIDIA, NVIDIA GeForce GTX 1060 Direct3D11 vs_5_0 ps_5_0)",
      shadingLanguageVersion: "WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)",
      maxTextureSize: 16384,
      maxCubeMapTextureSize: 16384,
      maxRenderbufferSize: 16384,
      maxViewportDims: (width: 16384, height: 16384),
      maxVertexAttribs: 16,
      maxVertexUniformVectors: 4096,
      maxFragmentUniformVectors: 1024,
      maxVertexTextureImageUnits: 32,
      maxTextureImageUnits: 32,
      precision: (vertex: "highp", fragment: "highp"),
      supportedExtensions: @[
        "ANGLE_instanced_arrays",
        "EXT_blend_minmax",
        "EXT_color_buffer_half_float",
        "EXT_disjoint_timer_query",
        "EXT_float_blend",
        "EXT_shader_texture_lod",
        "EXT_texture_compression_bptc",
        "EXT_texture_compression_rgtc",
        "EXT_texture_filter_anisotropic",
        "OES_element_index_uint",
        "OES_standard_derivatives",
        "OES_texture_float",
        "OES_texture_float_linear",
        "OES_texture_half_float",
        "OES_texture_half_float_linear",
        "OES_vertex_array_object",
        "WEBGL_color_buffer_float",
        "WEBGL_compressed_texture_s3tc",
        "WEBGL_compressed_texture_s3tc_srgb",
        "WEBGL_debug_renderer_info",
        "WEBGL_debug_shaders",
        "WEBGL_lose_context",
        "WEBGL_multi_draw"
      ],
      antialiasing: true
    ),
    WebGLProfile(
      vendor: "Mozilla",
      renderer: "Mozilla",
      shadingLanguageVersion: "WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0)",
      maxTextureSize: 8192,
      maxCubeMapTextureSize: 8192,
      maxRenderbufferSize: 8192,
      maxViewportDims: (width: 8192, height: 8192),
      maxVertexAttribs: 16,
      maxVertexUniformVectors: 4096,
      maxFragmentUniformVectors: 1024,
      maxVertexTextureImageUnits: 16,
      maxTextureImageUnits: 16,
      precision: (vertex: "highp", fragment: "mediump"),
      supportedExtensions: @[
        "ANGLE_instanced_arrays",
        "EXT_blend_minmax",
        "EXT_color_buffer_half_float",
        "EXT_float_blend",
        "EXT_texture_filter_anisotropic",
        "OES_element_index_uint",
        "OES_standard_derivatives",
        "OES_texture_float",
        "OES_texture_float_linear",
        "OES_texture_half_float",
        "OES_texture_half_float_linear",
        "OES_vertex_array_object",
        "WEBGL_color_buffer_float",
        "WEBGL_compressed_texture_s3tc",
        "WEBGL_debug_renderer_info",
        "WEBGL_lose_context"
      ],
      antialiasing: false
    ),
    WebGLProfile(
      vendor: "Apple Inc.",
      renderer: "Apple GPU",
      shadingLanguageVersion: "WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0)",
      maxTextureSize: 8192,
      maxCubeMapTextureSize: 8192,
      maxRenderbufferSize: 8192,
      maxViewportDims: (width: 8192, height: 8192),
      maxVertexAttribs: 16,
      maxVertexUniformVectors: 1024,
      maxFragmentUniformVectors: 1024,
      maxVertexTextureImageUnits: 16,
      maxTextureImageUnits: 16,
      precision: (vertex: "highp", fragment: "highp"),
      supportedExtensions: @[
        "ANGLE_instanced_arrays",
        "EXT_blend_minmax",
        "EXT_color_buffer_half_float",
        "EXT_float_blend",
        "EXT_shader_texture_lod",
        "EXT_texture_filter_anisotropic",
        "OES_element_index_uint",
        "OES_standard_derivatives",
        "OES_texture_float",
        "OES_texture_float_linear",
        "OES_texture_half_float",
        "OES_texture_half_float_linear",
        "OES_vertex_array_object",
        "WEBGL_color_buffer_float",
        "WEBGL_compressed_texture_s3tc",
        "WEBGL_debug_renderer_info",
        "WEBGL_lose_context"
      ],
      antialiasing: true
    )
  ]

  # シェーダーノイズ用トランスフォーマーコード
  SHADER_NOISE_TRANSFORMER = """
  // 決定論的なノイズ生成関数
  float deterministicNoise(vec2 co) {
    // 同じ入力から同じ出力を生成
    float a = 12.9898;
    float b = 78.233;
    float c = 43758.5453;
    float dt = dot(co, vec2(a, b));
    float sn = mod(dt, 3.14159);
    return fract(sin(sn) * c) * 2.0 - 1.0;
  }
  
  // テクスチャ座標にノイズを追加
  vec2 applyNoiseToTexCoord(vec2 texCoord, float noiseLevel, vec2 seed) {
    float noiseX = deterministicNoise(texCoord + seed) * noiseLevel;
    float noiseY = deterministicNoise(texCoord + seed + vec2(1.0, 1.0)) * noiseLevel;
    return texCoord + vec2(noiseX, noiseY);
  }
  
  // 色出力にノイズを追加
  vec4 applyNoiseToColor(vec4 color, float noiseLevel, vec2 seed) {
    float noiseR = deterministicNoise(seed) * noiseLevel;
    float noiseG = deterministicNoise(seed + vec2(1.0, 0.0)) * noiseLevel;
    float noiseB = deterministicNoise(seed + vec2(0.0, 1.0)) * noiseLevel;
    return vec4(
      clamp(color.r + noiseR, 0.0, 1.0),
      clamp(color.g + noiseG, 0.0, 1.0),
      clamp(color.b + noiseB, 0.0, 1.0),
      color.a
    );
  }
  
  // 精度を落とす
  vec4 reducePrecision(vec4 color, float level) {
    float steps = 255.0 * (1.0 - level);
    return floor(color * steps) / steps;
  }
  """

# ユーティリティ関数
proc generateSessionKey(): string =
  ## 一貫性保持用のセッションキーを生成
  var r = initRand()
  result = ""
  for i in 0..<32:
    result.add(chr(r.rand(25) + ord('a')))

proc deterministicRandom(seed: string, min: int, max: int): int =
  ## 決定論的な乱数生成（同じシードからは同じ値を生成）
  var h = 0
  for c in seed:
    h = h * 31 + ord(c)
  result = (abs(h) mod (max - min + 1)) + min

proc hashString(s: string): int =
  ## 文字列のハッシュ値を計算
  var h = 0
  for c in s:
    h = h * 31 + ord(c)
  result = abs(h)

# シェーダー処理関連
proc hashShader*(shaderSource: string): string =
  ## シェーダーソースコードのハッシュを計算
  ## 単純なハッシュ計算（実際の実装ではもっと堅牢な方法を使用）
  let h = hashString(shaderSource)
  return $h

proc applyShaderTransformation*(
  shaderSource: string, 
  noiseMethod: ShaderNoiseMethod, 
  noiseLevel: float,
  sessionKey: string
): string =
  ## シェーダーにノイズ追加トランスフォーメーションを適用
  if noiseMethod == snmNone:
    return shaderSource
  
  # ノイズレベルの文字列表現
  let noiseLevelStr = formatFloat(noiseLevel, ffDecimal, 6)
  
  # シードの生成（セッションキーとシェーダーハッシュから決定論的に生成）
  let shaderHash = hashShader(shaderSource)
  let seed = hashString(sessionKey & shaderHash) mod 10000
  let seedStr = $seed & ".0, " & $(seed mod 137) & ".0"
  
  # シェーダーの種類を判定（頂点シェーダーかフラグメントシェーダーか）
  let isVertexShader = shaderSource.contains("attribute ") or
                      shaderSource.contains("gl_Position")
  let isFragmentShader = shaderSource.contains("gl_FragColor") or
                       (shaderSource.contains("precision ") and 
                        shaderSource.contains("varying "))
  
  # シェーダーの種類に応じた処理
  if isVertexShader:
    var modifiedSource = shaderSource
    
    # ユーティリティ関数を追加
    if not modifiedSource.contains("deterministicNoise"):
      let insertPos = modifiedSource.find("void main")
      if insertPos > 0:
        modifiedSource = modifiedSource[0..<insertPos] & 
                        SHADER_NOISE_TRANSFORMER & 
                        modifiedSource[insertPos..^1]
    
    # 特定のノイズメソッドに基づく変換
    case noiseMethod
    of snmUniformValue:
      # 単純な例：gl_Positionに微小なノイズを追加
      modifiedSource = modifiedSource.replace(
        "gl_Position = ",
        "gl_Position = vec4(deterministicNoise(vec2(" & seedStr & ")) * " & noiseLevelStr & ", 0.0, 0.0, 0.0) + "
      )
    of snmTextureCoords:
      # テクスチャ座標に適用（頂点シェーダーでvaryingとして渡す場合）
      if modifiedSource.contains("varying vec2 vTexCoord"):
        modifiedSource = modifiedSource.replace(
          "vTexCoord = ",
          "vTexCoord = applyNoiseToTexCoord(", 
          ")",
          ", " & noiseLevelStr & ", vec2(" & seedStr & "))"
        )
    of snmPrecisionLoss:
      # 頂点位置の精度を下げる
      modifiedSource = modifiedSource.replace(
        "gl_Position = ",
        "vec4 _tempPos = ;\ngl_Position = vec4(floor(_tempPos.x * 1024.0) / 1024.0, floor(_tempPos.y * 1024.0) / 1024.0, _tempPos.z, _tempPos.w)"
      )
    else:
      # その他のメソッドは頂点シェーダーには適用しない
      discard
    
    return modifiedSource
    
  elif isFragmentShader:
    var modifiedSource = shaderSource
    
    # ユーティリティ関数を追加
    if not modifiedSource.contains("deterministicNoise"):
      let insertPos = modifiedSource.find("void main")
      if insertPos > 0:
        modifiedSource = modifiedSource[0..<insertPos] & 
                        SHADER_NOISE_TRANSFORMER & 
                        modifiedSource[insertPos..^1]
    
    # 特定のノイズメソッドに基づく変換
    case noiseMethod
    of snmColorOutput:
      # 出力色にノイズを追加
      modifiedSource = modifiedSource.replace(
        "gl_FragColor = ",
        "gl_FragColor = applyNoiseToColor("
      )
      modifiedSource = modifiedSource.replace(
        ";",
        ", " & noiseLevelStr & ", vec2(" & seedStr & "));"
      )
    of snmTextureCoords:
      # texture2D呼び出しを探して置換
      if modifiedSource.contains("texture2D("):
        modifiedSource = modifiedSource.replace(
          "texture2D(",
          "texture2D(", 
          ",",
          "applyNoiseToTexCoord(", ", " & noiseLevelStr & ", vec2(" & seedStr & ")),")
    of snmPrecisionLoss:
      # 出力色の精度を下げる
      modifiedSource = modifiedSource.replace(
        "gl_FragColor = ",
        "gl_FragColor = reducePrecision(", 
        ";",
        ", " & noiseLevelStr & ");"
      )
    else:
      # その他のメソッドはフラグメントシェーダーには適用しない
      discard
    
    return modifiedSource
    
  else:
    # シェーダータイプが判別できない場合は元のコードを返す
    return shaderSource

# メインのGpuFingerprintProtectorの実装
proc newGpuFingerprintProtector*(): GpuFingerprintProtector =
  ## 新しいGPUフィンガープリント保護モジュールを作成
  new(result)
  result.enabled = true
  result.uniformNoiseLevel = 0.001  # デフォルトノイズレベル（0.1%）
  result.precisionReduction = true
  result.vendorSpoofing = true
  result.parameterRestriction = true
  result.consistentProfile = true
  result.sessionKey = generateSessionKey()
  result.logger = newConsoleLogger()
  
  # デフォルトWebGLプロファイルを選択
  let profileIdx = deterministicRandom(result.sessionKey, 0, STANDARD_WEBGL_PROFILES.high)
  result.webglProfile = STANDARD_WEBGL_PROFILES[profileIdx]
  
  # シェーダーハッシュホワイトリストを初期化
  result.shaderHashWhitelist = initHashSet[string]()

proc setWebGLProfile*(protector: GpuFingerprintProtector, profile: WebGLProfile) =
  ## WebGLプロファイルを設定
  protector.webglProfile = profile

proc getWebGLProfile*(protector: GpuFingerprintProtector): WebGLProfile =
  ## 現在のWebGLプロファイルを取得
  return protector.webglProfile

proc enable*(protector: GpuFingerprintProtector) =
  ## 保護を有効化
  protector.enabled = true

proc disable*(protector: GpuFingerprintProtector) =
  ## 保護を無効化
  protector.enabled = false

proc isEnabled*(protector: GpuFingerprintProtector): bool =
  ## 保護が有効かどうか
  return protector.enabled

proc setNoiseLevel*(protector: GpuFingerprintProtector, level: float) =
  ## ノイズレベルを設定（0.0〜0.1の範囲を推奨）
  protector.uniformNoiseLevel = max(0.0, min(level, 0.1))

proc whitelistShader*(protector: GpuFingerprintProtector, shaderHash: string) =
  ## 特定のシェーダーを保護対象外に追加
  protector.shaderHashWhitelist.incl(shaderHash)

proc isShaderWhitelisted*(protector: GpuFingerprintProtector, shaderSource: string): bool =
  ## シェーダーが保護対象外かどうか
  let hash = hashShader(shaderSource)
  return hash in protector.shaderHashWhitelist

proc selectShaderNoiseMethod*(
  protector: GpuFingerprintProtector, 
  shaderSource: string
): ShaderNoiseMethod =
  ## シェーダーに適用するノイズメソッドを選択
  if not protector.enabled or protector.isShaderWhitelisted(shaderSource):
    return snmNone
  
  # シェーダーの特性に基づいてノイズメソッドを選択
  let isVertexShader = shaderSource.contains("attribute ") or
                      shaderSource.contains("gl_Position")
  let isFragmentShader = shaderSource.contains("gl_FragColor") or
                        (shaderSource.contains("precision ") and 
                         shaderSource.contains("varying "))
  
  # シェーダーハッシュを用いて決定論的に選択
  let hash = hashShader(shaderSource)
  let methodSeed = protector.sessionKey & hash
  let methodIdx = deterministicRandom(methodSeed, 0, 3)
  
  if isVertexShader:
    case methodIdx:
    of 0: return snmNone
    of 1: return snmUniformValue
    of 2: return snmPrecisionLoss
    else: return snmTextureCoords
  
  elif isFragmentShader:
    case methodIdx:
    of 0: return snmTextureCoords
    of 1: return snmColorOutput
    of 2: return snmPrecisionLoss
    else: return snmNone
  
  else:
    return snmNone

proc transformShader*(
  protector: GpuFingerprintProtector,
  shaderSource: string
): string =
  ## シェーダーを変換してフィンガープリントを防止
  if not protector.enabled or protector.isShaderWhitelisted(shaderSource):
    return shaderSource
  
  let noiseMethod = protector.selectShaderNoiseMethod(shaderSource)
  return applyShaderTransformation(
    shaderSource,
    noiseMethod,
    protector.uniformNoiseLevel,
    protector.sessionKey
  )

proc getWebGLParameters*(protector: GpuFingerprintProtector): JsonNode =
  ## WebGLパラメータを取得（偽装）
  if not protector.enabled:
    return newJNull()
  
  let profile = protector.webglProfile
  
  result = %*{
    "vendor": profile.vendor,
    "renderer": profile.renderer,
    "unmaskedVendor": profile.vendor,
    "unmaskedRenderer": profile.renderer,
    "shadingLanguageVersion": profile.shadingLanguageVersion,
    "maxTextureSize": profile.maxTextureSize,
    "maxCubeMapTextureSize": profile.maxCubeMapTextureSize,
    "maxRenderbufferSize": profile.maxRenderbufferSize,
    "maxViewportDims": [profile.maxViewportDims.width, profile.maxViewportDims.height],
    "maxVertexAttribs": profile.maxVertexAttribs,
    "maxVertexUniformVectors": profile.maxVertexUniformVectors,
    "maxFragmentUniformVectors": profile.maxFragmentUniformVectors,
    "maxVertexTextureImageUnits": profile.maxVertexTextureImageUnits,
    "maxTextureImageUnits": profile.maxTextureImageUnits,
    "precision": {
      "vertex": profile.precision.vertex,
      "fragment": profile.precision.fragment
    },
    "supportedExtensions": profile.supportedExtensions,
    "antialiasing": profile.antialiasing
  }

proc getCanvasContextAttributes*(
  protector: GpuFingerprintProtector,
  contextType: string
): JsonNode =
  ## Canvas contextの属性を取得（偽装）
  if not protector.enabled:
    return newJNull()
  
  case contextType
  of "webgl", "webgl2":
    result = %*{
      "alpha": true,
      "depth": true,
      "stencil": true,
      "antialias": protector.webglProfile.antialiasing,
      "premultipliedAlpha": true,
      "preserveDrawingBuffer": false,
      "powerPreference": "default",
      "failIfMajorPerformanceCaveat": false,
      "desynchronized": false,
      "xrCompatible": false
    }
  of "2d":
    result = %*{
      "alpha": true,
      "desynchronized": false,
      "colorSpace": "srgb",
      "willReadFrequently": false
    }
  else:
    result = newJNull()

# パフォーマンス最適化のための設定
proc optimizeForPerformance*(protector: GpuFingerprintProtector) =
  ## パフォーマンスを優先する設定に切り替え
  protector.uniformNoiseLevel = 0.0005  # ノイズレベルを下げる
  protector.precisionReduction = false   # 精度低下を無効化

# セキュリティ重視の設定
proc optimizeForSecurity*(protector: GpuFingerprintProtector) =
  ## セキュリティを優先する設定に切り替え
  protector.uniformNoiseLevel = 0.002   # ノイズレベルを上げる
  protector.precisionReduction = true    # 精度低下を有効化

proc getProtectionStatus*(protector: GpuFingerprintProtector): JsonNode =
  ## 保護状態をJSON形式で取得
  result = %*{
    "enabled": protector.enabled,
    "noiseLevel": protector.uniformNoiseLevel,
    "precisionReduction": protector.precisionReduction,
    "vendorSpoofing": protector.vendorSpoofing,
    "parameterRestriction": protector.parameterRestriction,
    "consistentProfile": protector.consistentProfile,
    "profile": {
      "vendor": protector.webglProfile.vendor,
      "renderer": protector.webglProfile.renderer,
      "extensions": protector.webglProfile.supportedExtensions.len
    },
    "whitelistedShaders": protector.shaderHashWhitelist.len
  }

when isMainModule:
  # テスト用コード
  let protector = newGpuFingerprintProtector()
  
  # 簡単なシェーダーでテスト
  let vertexShader = """
  attribute vec2 aPosition;
  attribute vec2 aTexCoord;
  varying vec2 vTexCoord;
  void main() {
    vTexCoord = aTexCoord;
    gl_Position = vec4(aPosition, 0.0, 1.0);
  }
  """
  
  let fragmentShader = """
  precision mediump float;
  varying vec2 vTexCoord;
  uniform sampler2D uTexture;
  void main() {
    gl_FragColor = texture2D(uTexture, vTexCoord);
  }
  """
  
  echo "Original vertex shader:\n", vertexShader
  echo "Transformed vertex shader:\n", protector.transformShader(vertexShader)
  
  echo "Original fragment shader:\n", fragmentShader
  echo "Transformed fragment shader:\n", protector.transformShader(fragmentShader)
  
  # WebGLパラメータのテスト
  echo "WebGL Parameters:\n", protector.getWebGLParameters() 