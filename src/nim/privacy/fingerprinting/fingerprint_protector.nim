# fingerprint_protector.nim
## ブラウザフィンガープリント保護モジュール
## ユーザーの識別に使用される様々なフィンガープリント要素を保護・偽装する機能を提供

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
  math,
  httpclient,
  base64
]

import ../privacy_types

# フォワード宣言
type
  FingerprintProtector* = ref FingerprintProtectorObj
  FingerprintProtectorObj = object
    ## フィンガープリント保護モジュール
    protectionLevel*: FingerPrintProtectionLevel  ## 保護レベル
    enabled*: bool                               ## 有効フラグ
    vectorStates*: Table[FingerprintVector, bool] ## 各ベクターの保護状態
    spoofedValues*: Table[FingerprintVector, JsonNode] ## 偽装値
    consistentValues*: bool                      ## 一貫した値を使用するか
    sessionKey*: string                          ## セッションキー（一貫性保持用）
    logger*: Logger                              ## ロガー
    allowedDomains*: HashSet[string]             ## 保護を適用しないドメイン
    customRules*: Table[string, int]             ## ドメイン別カスタムルール

  CanvasModification* = enum
    ## Canvas変更方法
    cmNoise,        ## ノイズ追加
    cmColorShift,   ## 色シフト
    cmBlockData,    ## データアクセスブロック
    cmFakeData      ## 偽データ返却

  WebGLModification* = enum
    ## WebGL変更方法
    wgmVendorSpoofing,  ## ベンダー情報偽装
    wgmParameterLimit,  ## パラメータ制限
    wgmDisable,         ## 無効化
    wgmNoise            ## ノイズ追加

  UserAgentMode* = enum
    ## UserAgent偽装モード
    uamReal,         ## 実際のUA
    uamGeneric,      ## 一般的なUA
    uamRandom,       ## ランダムUA
    uamRotating      ## 定期的に変更

  FontFingerprintMode* = enum
    ## フォント指紋対策モード
    ffmSubset,       ## サブセット制限
    ffmCommonOnly,   ## 一般的なフォントのみ
    ffmRandomize,    ## ランダム化
    ffmBlock         ## ブロック

const
  # デフォルト保護ベクター（標準保護レベル）
  DEFAULT_PROTECTED_VECTORS = {
    fvCanvas,
    fvWebGL,
    fvAudioContext,
    fvMediaDevices,
    fvSystemFonts,
    fvBatteryStatus,
    fvClientHints
  }

  # 高度保護ベクター（厳格保護レベル、標準レベルを含む）
  STRICT_PROTECTED_VECTORS = DEFAULT_PROTECTED_VECTORS + {
    fvUserAgent,
    fvPlugins,
    fvScreenResolution,
    fvTimezone,
    fvWebRTC,
    fvDomRect,
    fvSpeechSynthesis
  }

  # 標準的なUserAgent
  STANDARD_USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/123.0",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
  ]

  # 一般的なフォント
  COMMON_FONTS = [
    "Arial", "Arial Black", "Arial Narrow", "Arial Rounded MT Bold",
    "Calibri", "Cambria", "Cambria Math",
    "Comic Sans MS", "Courier", "Courier New",
    "Georgia", "Helvetica", "Impact", "Lucida Sans", "Lucida Console",
    "Tahoma", "Times", "Times New Roman", "Trebuchet MS", "Verdana"
  ]

  # 一般的な画面解像度
  COMMON_RESOLUTIONS = [
    (1366, 768),
    (1440, 900),
    (1536, 864),
    (1600, 900),
    (1920, 1080),
    (2560, 1440),
    (3840, 2160)
  ]

#----------------------------------------
# ユーティリティ関数
#----------------------------------------

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

#----------------------------------------
# FingerprintProtectorの実装
#----------------------------------------

proc newFingerprintProtector*(protectionLevel: FingerPrintProtectionLevel = fpStandard): FingerprintProtector =
  ## 新しいフィンガープリント保護モジュールを作成
  new(result)
  result.protectionLevel = protectionLevel
  result.enabled = true
  result.vectorStates = initTable[FingerprintVector, bool]()
  result.spoofedValues = initTable[FingerprintVector, JsonNode]()
  result.consistentValues = true
  result.sessionKey = generateSessionKey()
  result.logger = newConsoleLogger()
  result.allowedDomains = initHashSet[string]()
  result.customRules = initTable[string, int]()
  
  # 保護レベルに基づいてデフォルト設定
  case protectionLevel
  of fpNone:
    # 保護なし
    for vector in FingerprintVector:
      result.vectorStates[vector] = false
  
  of fpMinimal:
    # 最小限の保護
    for vector in FingerprintVector:
      result.vectorStates[vector] = vector in {fvCanvas, fvWebGL}
  
  of fpStandard:
    # 標準的な保護
    for vector in FingerprintVector:
      result.vectorStates[vector] = vector in DEFAULT_PROTECTED_VECTORS
  
  of fpStrict:
    # 厳格な保護
    for vector in FingerprintVector:
      result.vectorStates[vector] = vector in STRICT_PROTECTED_VECTORS
  
  of fpCustom:
    # カスタム設定
    for vector in FingerprintVector:
      result.vectorStates[vector] = false

proc setProtectionLevel*(protector: FingerprintProtector, level: FingerPrintProtectionLevel) =
  ## 保護レベルを設定
  protector.protectionLevel = level
  
  # 保護レベルに基づいて設定を更新
  case level
  of fpNone:
    # 保護なし
    for vector in FingerprintVector:
      protector.vectorStates[vector] = false
  
  of fpMinimal:
    # 最小限の保護
    for vector in FingerprintVector:
      protector.vectorStates[vector] = vector in {fvCanvas, fvWebGL}
  
  of fpStandard:
    # 標準的な保護
    for vector in FingerprintVector:
      protector.vectorStates[vector] = vector in DEFAULT_PROTECTED_VECTORS
  
  of fpStrict:
    # 厳格な保護
    for vector in FingerprintVector:
      protector.vectorStates[vector] = vector in STRICT_PROTECTED_VECTORS
  
  of fpCustom:
    # 設定は変更しない
    discard

proc setVectorProtection*(protector: FingerprintProtector, vector: FingerprintVector, enabled: bool) =
  ## 特定のベクターに対する保護設定を変更
  protector.vectorStates[vector] = enabled
  # カスタムモードに変更
  protector.protectionLevel = fpCustom

proc isVectorProtected*(protector: FingerprintProtector, vector: FingerprintVector): bool =
  ## 特定のベクターが保護対象かどうかを返す
  return protector.enabled and protector.vectorStates.getOrDefault(vector, false)

proc allowDomain*(protector: FingerprintProtector, domain: string) =
  ## ドメインを保護対象外に追加
  protector.allowedDomains.incl(domain)

proc isDomainAllowed*(protector: FingerprintProtector, domain: string): bool =
  ## ドメインが保護対象外かどうか
  return domain in protector.allowedDomains

proc setConsistentValues*(protector: FingerprintProtector, consistent: bool) =
  ## 一貫した値を使用するかどうかを設定
  protector.consistentValues = consistent
  if consistent and protector.sessionKey.len == 0:
    protector.sessionKey = generateSessionKey()

proc enable*(protector: FingerprintProtector) =
  ## 保護を有効化
  protector.enabled = true

proc disable*(protector: FingerprintProtector) =
  ## 保護を無効化
  protector.enabled = false

proc isEnabled*(protector: FingerprintProtector): bool =
  ## 保護が有効かどうか
  return protector.enabled

proc getProtectionStatus*(protector: FingerprintProtector): JsonNode =
  ## 保護状態をJSON形式で取得
  var vectorStatus = newJObject()
  for vector in FingerprintVector:
    vectorStatus[$vector] = %protector.vectorStates.getOrDefault(vector, false)
  
  result = %*{
    "enabled": protector.enabled,
    "protectionLevel": $protector.protectionLevel,
    "consistentValues": protector.consistentValues,
    "vectorStatus": vectorStatus,
    "allowedDomains": toSeq(protector.allowedDomains)
  }

#----------------------------------------
# 偽装値の生成
#----------------------------------------

proc getSpoofedUserAgent*(protector: FingerprintProtector, mode: UserAgentMode = uamGeneric): string =
  ## 偽装されたUserAgentを取得
  ##
  ## Parameters:
  ## - mode: UserAgent偽装モード
  ##
  ## Returns:
  ## - 偽装されたUserAgent文字列

  if mode == uamReal:
    # 実際のUserAgentを使用
    return ""  # 呼び出し元がデフォルトのUAを使用

  if mode == uamGeneric:
    # 一般的なユーザーエージェントを使用
    return STANDARD_USER_AGENTS[0]

  if mode == uamRandom:
    # セッションベースの乱数を使用して、現実的なユーザーエージェントを生成
    let platforms = @["Windows", "Macintosh", "Linux", "Android", "iPhone"]
    let browsers = @["Chrome", "Firefox", "Safari", "Edge"]
    let osVersions = {
      "Windows": @["10.0", "11.0"],
      "Macintosh": @["10_15_7", "11_0_1", "12_0_1", "13_0"],
      "Linux": @["x86_64"],
      "Android": @["10", "11", "12", "13"],
      "iPhone": @["14_4", "15_0", "16_0", "17_0"]
    }.toTable
    let browserVersions = {
      "Chrome": @["100.0.4896.127", "103.0.5060.134", "108.0.0.0", "110.0.0.0", "120.0.0.0"],
      "Firefox": @["100.0", "108.0", "110.0", "115.0", "123.0"],
      "Safari": @["14.0.3", "15.4", "16.0", "17.0", "17.2"],
      "Edge": @["99.0.1150.55", "100.0.1185.50", "108.0.1462.76", "110.0.1587.69", "120.0.0.0"]
    }.toTable

    # セッションキーと現在の日付に基づいた一貫した選択（日付は定期的な変更用）
    let today = getTime().local().format("yyyyMMdd")
    let seed = if protector.consistentValues: protector.sessionKey & today else: $rand(1000000)
    
    # プラットフォームとブラウザの選択
    let platformIdx = deterministicRandom(seed & "platform", 0, platforms.len - 1)
    let platform = platforms[platformIdx]
    
    var browserIdx = deterministicRandom(seed & "browser", 0, browsers.len - 1)
    
    # プラットフォームとブラウザの互換性チェック
    if platform == "iPhone" and browsers[browserIdx] != "Safari":
      browserIdx = browsers.find("Safari")
    
    let browser = browsers[browserIdx]
    
    # OSバージョンとブラウザバージョンの選択
    let osVersionIdx = deterministicRandom(seed & "os", 0, osVersions[platform].len - 1)
    let osVersion = osVersions[platform][osVersionIdx]
    
    let browserVersionIdx = deterministicRandom(seed & "browser_ver", 0, browserVersions[browser].len - 1)
    let browserVersion = browserVersions[browser][browserVersionIdx]
    
    # UserAgentの構築
    case platform
    of "Windows":
      case browser
      of "Chrome":
        return fmt"Mozilla/5.0 (Windows NT {osVersion}; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{browserVersion} Safari/537.36"
      of "Firefox":
        return fmt"Mozilla/5.0 (Windows NT {osVersion}; Win64; x64; rv:{browserVersion.split('.')[0]}) Gecko/20100101 Firefox/{browserVersion}"
      of "Edge":
        return fmt"Mozilla/5.0 (Windows NT {osVersion}; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{browserVersion} Safari/537.36 Edg/{browserVersion}"
      of "Safari":
        # WindowsでのSafariは現実的ではないが、一応対応
        return fmt"Mozilla/5.0 (Windows NT {osVersion}; Win64; x64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0 Safari/605.1.15"
      else:
        return STANDARD_USER_AGENTS[0]
    
    of "Macintosh":
      case browser
      of "Chrome":
        return fmt"Mozilla/5.0 (Macintosh; Intel Mac OS X {osVersion}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{browserVersion} Safari/537.36"
      of "Firefox":
        return fmt"Mozilla/5.0 (Macintosh; Intel Mac OS X {osVersion}; rv:{browserVersion.split('.')[0]}) Gecko/20100101 Firefox/{browserVersion}"
      of "Safari":
        return fmt"Mozilla/5.0 (Macintosh; Intel Mac OS X {osVersion}) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/{browserVersion.split('.')[0]}.{browserVersion.split('.')[1]} Safari/605.1.15"
      of "Edge":
        return fmt"Mozilla/5.0 (Macintosh; Intel Mac OS X {osVersion}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{browserVersion} Safari/537.36 Edg/{browserVersion}"
      else:
        return STANDARD_USER_AGENTS[1]
    
    of "Linux":
      case browser
      of "Chrome":
        return fmt"Mozilla/5.0 (X11; Linux {osVersion}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{browserVersion} Safari/537.36"
      of "Firefox":
        return fmt"Mozilla/5.0 (X11; Linux {osVersion}; rv:{browserVersion.split('.')[0]}) Gecko/20100101 Firefox/{browserVersion}"
      else:
        return fmt"Mozilla/5.0 (X11; Linux {osVersion}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{browserVersion} Safari/537.36"
    
    of "Android":
      case browser
      of "Chrome":
        return fmt"Mozilla/5.0 (Linux; Android {osVersion}; SM-G998B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{browserVersion} Mobile Safari/537.36"
      of "Firefox":
        return fmt"Mozilla/5.0 (Android {osVersion}; Mobile; rv:{browserVersion.split('.')[0]}) Gecko/{browserVersion.split('.')[0]}.0 Firefox/{browserVersion} KAIOS/2.5"
      else:
        return fmt"Mozilla/5.0 (Linux; Android {osVersion}; SM-G998B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{browserVersion} Mobile Safari/537.36"
    
    of "iPhone":
      # iPhoneはSafariが主流
      return fmt"Mozilla/5.0 (iPhone; CPU iPhone OS {osVersion.replace('_', '')} like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/{browserVersion.split('.')[0]}.0 Mobile/15E148 Safari/604.1"
    
    else:
      return STANDARD_USER_AGENTS[0]

  if mode == uamRotating:
    # 定期的に変更するUAの場合、日付を取得して日付ごとに異なるUAを返す
    let today = getTime().local().format("yyyyMMdd")
    let seed = protector.sessionKey & today
    let idx = deterministicRandom(seed, 0, STANDARD_USER_AGENTS.len - 1)
    return STANDARD_USER_AGENTS[idx]
  
  # デフォルトでは一般的なUAを返す
  return STANDARD_USER_AGENTS[0]

proc getSpoofedScreenResolution*(protector: FingerprintProtector, originalWidth, originalHeight: int): tuple[width, height: int] =
  ## 偽装画面解像度を取得
  if not protector.isVectorProtected(fvScreenResolution):
    return (originalWidth, originalHeight)
  
  # 一般的な解像度から選択
  let idx = if protector.consistentValues:
              deterministicRandom(protector.sessionKey & "screen", 0, COMMON_RESOLUTIONS.high)
            else:
              rand(0..COMMON_RESOLUTIONS.high)
  
  result = COMMON_RESOLUTIONS[idx]

proc getSpoofedLanguage*(protector: FingerprintProtector, originalLang: string): string =
  ## 偽装言語設定を取得
  if not protector.isVectorProtected(fvLanguage):
    return originalLang
  
  let languages = ["en-US", "en-GB", "fr-FR", "de-DE", "es-ES", "ja-JP", "zh-CN"]
  
  let idx = if protector.consistentValues:
              deterministicRandom(protector.sessionKey & "lang", 0, languages.high)
            else:
              rand(0..languages.high)
  
  return languages[idx]

proc getModifiedFonts*(protector: FingerprintProtector, mode: FontFingerprintMode = ffmCommonOnly): seq[string] =
  ## 偽装フォントリストを取得
  if not protector.isVectorProtected(fvSystemFonts):
    return @[] # 実際のフォントリストをそのまま使用
  
  case mode
  of ffmSubset:
    # フォントのサブセットを返す
    var fonts = COMMON_FONTS
    let maxFonts = if protector.consistentValues:
                     deterministicRandom(protector.sessionKey & "fontcount", 5, 15)
                   else:
                     rand(5..15)
    
    if protector.consistentValues:
      # 決定論的なシャッフル
      let seed = hashString(protector.sessionKey & "fonts")
      var indices = newSeq[int](fonts.len)
      for i in 0..<fonts.len:
        indices[i] = i
      
      # Fisher-Yatesシャッフル
      for i in countdown(fonts.high, 1):
        let j = deterministicRandom(protector.sessionKey & $i, 0, i)
        swap(indices[i], indices[j])
      
      var shuffled = newSeq[string](fonts.len)
      for i in 0..<fonts.len:
        shuffled[i] = fonts[indices[i]]
      
      return shuffled[0..<min(maxFonts, fonts.len)]
    else:
      shuffle(fonts)
      return fonts[0..<min(maxFonts, fonts.len)]
  
  of ffmCommonOnly:
    # 一般的なフォントのみ
    return COMMON_FONTS
  
  of ffmRandomize:
    # ランダム化（実際にはもっと現実的なアプローチが必要）
    var fonts = COMMON_FONTS
    
    if protector.consistentValues:
      # 決定論的なシャッフル
      let seed = hashString(protector.sessionKey & "fonts")
      var indices = newSeq[int](fonts.len)
      for i in 0..<fonts.len:
        indices[i] = i
      
      # Fisher-Yatesシャッフル
      for i in countdown(fonts.high, 1):
        let j = deterministicRandom(protector.sessionKey & $i, 0, i)
        swap(indices[i], indices[j])
      
      var shuffled = newSeq[string](fonts.len)
      for i in 0..<fonts.len:
        shuffled[i] = fonts[indices[i]]
      
      return shuffled
    else:
      shuffle(fonts)
      return fonts
  
  of ffmBlock:
    # フォント列挙をブロック
    return @[]

proc getCanvasNoiseFunction*(protector: FingerprintProtector, method: CanvasModification = cmNoise): JsonNode =
  ## Canvasノイズ生成関数を取得
  if not protector.isVectorProtected(fvCanvas):
    return %*{"enabled": false}
  
  case method
  of cmNoise:
    # ノイズ追加
    let noiseLevel = if protector.consistentValues:
                      deterministicRandom(protector.sessionKey & "canvas", 1, 5) / 100.0
                     else:
                      rand(1..5) / 100.0
    
    return %*{
      "enabled": true,
      "method": "noise",
      "params": {
        "level": noiseLevel,
        "seed": hashString(protector.sessionKey & "canvasNoise")
      }
    }
  
  of cmColorShift:
    # 色シフト
    let rShift = if protector.consistentValues:
                  deterministicRandom(protector.sessionKey & "canvasR", -5, 5)
                 else:
                  rand(-5..5)
    
    let gShift = if protector.consistentValues:
                  deterministicRandom(protector.sessionKey & "canvasG", -5, 5)
                 else:
                  rand(-5..5)
    
    let bShift = if protector.consistentValues:
                  deterministicRandom(protector.sessionKey & "canvasB", -5, 5)
                 else:
                  rand(-5..5)
    
    return %*{
      "enabled": true,
      "method": "colorShift",
      "params": {
        "rShift": rShift,
        "gShift": gShift,
        "bShift": bShift
      }
    }
  
  of cmBlockData:
    # データアクセスをブロック
    return %*{
      "enabled": true,
      "method": "block"
    }
  
  of cmFakeData:
    # 偽データを返す
    return %*{
      "enabled": true,
      "method": "fakeData",
      "params": {
        "seed": hashString(protector.sessionKey & "canvasFake")
      }
    }

proc getWebGLFingerprint*(protector: FingerprintProtector, method: WebGLModification = wgmVendorSpoofing): JsonNode =
  ## WebGL指紋対策設定を取得
  if not protector.isVectorProtected(fvWebGL):
    return %*{"enabled": false}
  
  case method
  of wgmVendorSpoofing:
    # ベンダー情報偽装
    let vendors = [
      ("Google Inc.", "ANGLE (Intel, Intel(R) UHD Graphics Direct3D11 vs_5_0 ps_5_0)"),
      ("Google Inc.", "ANGLE (NVIDIA, NVIDIA GeForce GTX 1060 Direct3D11 vs_5_0 ps_5_0)"),
      ("Mozilla", "Mesa/X.org, llvmpipe (LLVM 12.0.0, 128 bits)"),
      ("Apple Inc.", "Apple GPU"),
      ("Google Inc.", "ANGLE (Intel, Intel(R) Iris(TM) Plus Graphics 640 Direct3D11 vs_5_0 ps_5_0)")
    ]
    
    let idx = if protector.consistentValues:
                deterministicRandom(protector.sessionKey & "webgl", 0, vendors.high)
              else:
                rand(0..vendors.high)
    
    let (vendor, renderer) = vendors[idx]
    
    return %*{
      "enabled": true,
      "method": "vendorSpoofing",
      "params": {
        "vendor": vendor,
        "renderer": renderer
      }
    }
  
  of wgmParameterLimit:
    # パラメータ制限
    return %*{
      "enabled": true,
      "method": "parameterLimit",
      "params": {
        "maxAnisotropy": 2,
        "maxPrecision": "medium"
      }
    }
  
  of wgmDisable:
    # 無効化
    return %*{
      "enabled": true,
      "method": "disable"
    }
  
  of wgmNoise:
    # ノイズ追加
    return %*{
      "enabled": true,
      "method": "noise",
      "params": {
        "level": if protector.consistentValues:
                  deterministicRandom(protector.sessionKey & "webglNoise", 1, 5) / 100.0
                 else:
                  rand(1..5) / 100.0,
        "seed": hashString(protector.sessionKey & "webglNoiseSeed")
      }
    }

proc getAudioContextFingerprint*(protector: FingerprintProtector): JsonNode =
  ## AudioContext指紋対策設定を取得
  if not protector.isVectorProtected(fvAudioContext):
    return %*{"enabled": false}
  
  # ノイズレベル
  let noiseLevel = if protector.consistentValues:
                    deterministicRandom(protector.sessionKey & "audio", 1, 5) / 100.0
                   else:
                    rand(1..5) / 100.0
  
  return %*{
    "enabled": true,
    "method": "noise",
    "params": {
      "level": noiseLevel,
      "seed": hashString(protector.sessionKey & "audioSeed")
    }
  }

proc getClientHintsConfiguration*(protector: FingerprintProtector): JsonNode =
  ## Client Hints対策設定を取得
  if not protector.isVectorProtected(fvClientHints):
    return %*{"enabled": false}
  
  return %*{
    "enabled": true,
    "method": "block",
    "allowedHints": ["Sec-CH-UA"] # 最小限のClient Hintsのみ許可
  }

proc getBatteryApiConfig*(protector: FingerprintProtector): JsonNode =
  ## バッテリーAPI対策設定を取得
  if not protector.isVectorProtected(fvBatteryStatus):
    return %*{"enabled": false}
  
  # バッテリーレベルを偽装
  let level = if protector.consistentValues:
               deterministicRandom(protector.sessionKey & "battery", 50, 100) / 100.0
              else:
               rand(50..100) / 100.0
  
  let charging = if protector.consistentValues:
                  deterministicRandom(protector.sessionKey & "charging", 0, 1) == 1
                 else:
                  rand(0..1) == 1
  
  return %*{
    "enabled": true,
    "method": "spoof",
    "params": {
      "level": level,
      "charging": charging,
      "chargingTime": if charging: 0 else: 3600,
      "dischargingTime": if charging: 3600 else: deterministicRandom(protector.sessionKey & "dischargeTime", 1800, 10800)
    }
  }

proc getMediaDevicesConfig*(protector: FingerprintProtector): JsonNode =
  ## メディアデバイス対策設定を取得
  if not protector.isVectorProtected(fvMediaDevices):
    return %*{"enabled": false}
  
  # 標準的なデバイスセットを返す
  return %*{
    "enabled": true,
    "method": "standardize",
    "params": {
      "audioInputs": 1,
      "audioOutputs": 1,
      "videoInputs": if protector.consistentValues and deterministicRandom(protector.sessionKey & "hasCamera", 0, 1) == 1: 1 else: 0
    }
  }

proc getDomRectConfig*(protector: FingerprintProtector): JsonNode =
  ## DOMRect測定対策設定を取得
  if not protector.isVectorProtected(fvDomRect):
    return %*{"enabled": false}
  
  return %*{
    "enabled": true,
    "method": "noise",
    "params": {
      "level": if protector.consistentValues:
                deterministicRandom(protector.sessionKey & "domrect", 1, 3) / 10.0
               else:
                rand(1..3) / 10.0,
      "seed": hashString(protector.sessionKey & "domrectSeed")
    }
  }

proc getWebRTCProtection*(protector: FingerprintProtector): JsonNode =
  ## WebRTC IP漏洩保護設定を取得
  if not protector.isVectorProtected(fvWebRTC):
    return %*{"enabled": false}
  
  return %*{
    "enabled": true,
    "method": "block",
    "params": {
      "blockIPv6": true,
      "blockUDP": true,
      "blockTCP": false,
      "blockLocalIPs": true
    }
  }

proc getFullFingerprintProtection*(protector: FingerprintProtector, domain: string = ""): JsonNode =
  ## すべてのフィンガープリント保護設定を取得
  
  # ドメインが保護対象外ならば
  if domain.len > 0 and protector.isDomainAllowed(domain):
    return %*{"enabled": false}
  
  if not protector.enabled:
    return %*{"enabled": false}
  
  result = %*{
    "enabled": true,
    "protectionLevel": $protector.protectionLevel,
    "userAgent": {
      "protection": protector.isVectorProtected(fvUserAgent),
      "value": protector.getSpoofedUserAgent("", uamGeneric)
    },
    "canvas": protector.getCanvasNoiseFunction(cmNoise),
    "webgl": protector.getWebGLFingerprint(wgmVendorSpoofing),
    "audioContext": protector.getAudioContextFingerprint(),
    "clientHints": protector.getClientHintsConfiguration(),
    "battery": protector.getBatteryApiConfig(),
    "mediaDevices": protector.getMediaDevicesConfig(),
    "domRect": protector.getDomRectConfig(),
    "webrtc": protector.getWebRTCProtection(),
    "fonts": {
      "protection": protector.isVectorProtected(fvSystemFonts),
      "list": if protector.isVectorProtected(fvSystemFonts): protector.getModifiedFonts() else: @[]
    },
    "consitentIdentity": protector.consistentValues,
    "session": {
      "id": hashString(protector.sessionKey) mod 1000000, # セッションID（開示しない）
      "created": toUnix(getTime())
    }
  }

proc resetSession*(protector: FingerprintProtector) =
  ## セッションをリセット（新しい偽装値を生成）
  protector.sessionKey = generateSessionKey()
  protector.spoofedValues.clear()

proc initFromPrivacySettings*(protector: FingerprintProtector, settings: PrivacySettings) =
  ## プライバシー設定からの初期化
  protector.setProtectionLevel(settings.fingerPrintProtection)
  
  # カスタム設定の場合はドメインを設定
  for domain in settings.whitelistedDomains:
    protector.allowDomain(domain)

when isMainModule:
  # テスト用コード
  let protector = newFingerprintProtector(fpStandard)
  
  # サンプル出力
  echo "Protection Status: ", protector.getProtectionStatus()
  echo "Full Protection Config: ", protector.getFullFingerprintProtection()
  
  # UserAgent偽装のテスト
  echo "Spoofed UA: ", protector.getSpoofedUserAgent("original UA", uamGeneric)
  
  # Canvas保護のテスト
  echo "Canvas Protection: ", protector.getCanvasNoiseFunction(cmNoise) 