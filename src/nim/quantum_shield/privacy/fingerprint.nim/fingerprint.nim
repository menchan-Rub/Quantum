# fingerprint.nim
## フィンガープリント保護モジュール
## ブラウザフィンガープリンティングによるトラッキングを防止します

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
  uri,
  random,
  json,
  logging,
  asyncdispatch
]

import ../../../network/http/client/http_client_types
import ../../../utils/[logging, errors]

type
  FingerprintProtectionLevel* = enum
    ## フィンガープリント保護レベル
    fpDisabled,       ## 保護無効
    fpStandard,       ## 標準保護
    fpStrict,         ## 厳格保護
    fpMaximum        ## 最大保護

  UserAgentMode* = enum
    ## ユーザーエージェント偽装モード
    uamNone,          ## 偽装なし
    uamMinimal,       ## 最小偽装
    uamGeneric,       ## 一般化
    uamRotating,      ## ローテーション
    uamCustom         ## カスタム

  CanvasMode* = enum
    ## Canvas API 保護モード
    cmNone,           ## 保護なし
    cmWarn,           ## 警告のみ
    cmNoise,          ## ノイズ追加
    cmBlock           ## ブロック

  WebGLMode* = enum
    ## WebGL保護モード
    wgmNone,          ## 保護なし
    wgmMinimal,       ## 最小保護
    wgmBlock          ## ブロック

  TimeResolutionMode* = enum
    ## 時間精度保護モード
    trmNone,          ## 保護なし
    trmLow,           ## 低精度
    trmVeryLow        ## 非常に低精度

  FontProtectionMode* = enum
    ## フォント列挙保護モード
    fpmNone,          ## 保護なし
    fpmCommon,        ## 一般的なフォントのみ
    fpmBlock          ## ブロック

  FingerprintingTechnique* = enum
    ## フィンガープリンティング技術
    ftUserAgent,      ## ユーザーエージェント情報
    ftCanvas,         ## Canvas API
    ftWebGL,          ## WebGL
    ftWebRTC,         ## WebRTC
    ftAudio,          ## AudioContext
    ftFonts,          ## フォント列挙
    ftScreen,         ## 画面情報
    ftHardware,       ## ハードウェア情報
    ftTiming,         ## 精細なタイミング情報
    ftMediaQuery,     ## メディアクエリ
    ftBattery,        ## バッテリー情報
    ftTouchscreen,    ## タッチスクリーン情報
    ftLanguage,       ## 言語情報
    ftPlugins,        ## プラグイン情報
    ftDNT,            ## DoNotTrack情報
    ftStorage,        ## ストレージ情報
    ftCssProps        ## CSS特性情報

  FingerprintDetection* = object
    ## フィンガープリント検出情報
    technique*: FingerprintingTechnique  ## 技術
    domain*: string                     ## 検出ドメイン
    timestamp*: Time                    ## 検出時刻
    details*: string                    ## 詳細情報
    blocked*: bool                      ## ブロックされたかどうか

  FingerprintProtection* = ref object
    ## フィンガープリント保護
    enabled*: bool                      ## 有効フラグ
    level*: FingerprintProtectionLevel  ## 保護レベル
    logger: Logger                      ## ロガー
    
    # モード設定
    userAgentMode*: UserAgentMode       ## UAモード
    canvasMode*: CanvasMode             ## Canvasモード
    webglMode*: WebGLMode               ## WebGLモード
    timeResolutionMode*: TimeResolutionMode  ## 時間精度モード
    fontProtectionMode*: FontProtectionMode  ## フォント保護モード
    
    # 各種保護設定
    blockMediaQueries*: bool            ## メディアクエリブロック
    blockHardwareInfo*: bool            ## ハードウェア情報ブロック
    blockBatteryAPI*: bool              ## バッテリーAPIブロック
    blockAudioAPI*: bool                ## AudioAPIブロック
    randomizeScreenSize*: bool          ## 画面サイズランダム化
    
    customUserAgent*: string            ## カスタムUA
    exemptDomains*: HashSet[string]     ## 例外ドメイン
    detectionHistory*: seq[FingerprintDetection]  ## 検出履歴
    
    # ローテーション設定
    userAgentRotationInterval*: Duration  ## UAローテーション間隔
    lastRotationTime*: Time             ## 最終ローテーション時刻
    rotationUserAgents*: seq[string]    ## ローテーションUA一覧

const
  # 標準的なユーザーエージェント一覧
  COMMON_USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/98.0.4758.102 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/99.0.4844.51 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/98.0.4758.102 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.3 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:97.0) Gecko/20100101 Firefox/97.0",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/98.0.4758.102 Safari/537.36"
  ]
  
  # 一般的なフォント（プラットフォーム間で共通）
  COMMON_FONTS = [
    "Arial",
    "Arial Black",
    "Comic Sans MS",
    "Courier New",
    "Georgia",
    "Impact",
    "Times New Roman",
    "Trebuchet MS",
    "Verdana"
  ]

#----------------------------------------
# 初期化と設定
#----------------------------------------

proc newFingerprintProtection*(): FingerprintProtection =
  ## 新しいフィンガープリント保護を作成
  randomize()
  
  new(result)
  result.enabled = true
  result.level = fpStandard
  result.logger = newLogger("FingerprintProtection")
  
  # デフォルト設定（標準保護レベル）
  result.userAgentMode = uamMinimal
  result.canvasMode = cmNoise
  result.webglMode = wgmMinimal
  result.timeResolutionMode = trmLow
  result.fontProtectionMode = fpmCommon
  
  result.blockMediaQueries = false
  result.blockHardwareInfo = false
  result.blockBatteryAPI = true
  result.blockAudioAPI = false
  result.randomizeScreenSize = false
  
  result.customUserAgent = ""
  result.exemptDomains = initHashSet[string]()
  result.detectionHistory = @[]
  
  result.userAgentRotationInterval = initDuration(hours = 24)
  result.lastRotationTime = getTime()
  result.rotationUserAgents = @COMMON_USER_AGENTS

proc setProtectionLevel*(protection: FingerprintProtection, level: FingerprintProtectionLevel) =
  ## 保護レベルを設定
  protection.level = level
  
  # レベルに応じた設定
  case level
  of fpDisabled:
    protection.enabled = false
    protection.userAgentMode = uamNone
    protection.canvasMode = cmNone
    protection.webglMode = wgmNone
    protection.timeResolutionMode = trmNone
    protection.fontProtectionMode = fpmNone
    protection.blockMediaQueries = false
    protection.blockHardwareInfo = false
    protection.blockBatteryAPI = false
    protection.blockAudioAPI = false
    protection.randomizeScreenSize = false
    
  of fpStandard:
    protection.enabled = true
    protection.userAgentMode = uamMinimal
    protection.canvasMode = cmNoise
    protection.webglMode = wgmMinimal
    protection.timeResolutionMode = trmLow
    protection.fontProtectionMode = fpmCommon
    protection.blockMediaQueries = false
    protection.blockHardwareInfo = false
    protection.blockBatteryAPI = true
    protection.blockAudioAPI = false
    protection.randomizeScreenSize = false
    
  of fpStrict:
    protection.enabled = true
    protection.userAgentMode = uamGeneric
    protection.canvasMode = cmBlock
    protection.webglMode = wgmMinimal
    protection.timeResolutionMode = trmLow
    protection.fontProtectionMode = fpmCommon
    protection.blockMediaQueries = true
    protection.blockHardwareInfo = true
    protection.blockBatteryAPI = true
    protection.blockAudioAPI = true
    protection.randomizeScreenSize = true
    
  of fpMaximum:
    protection.enabled = true
    protection.userAgentMode = uamRotating
    protection.canvasMode = cmBlock
    protection.webglMode = wgmBlock
    protection.timeResolutionMode = trmVeryLow
    protection.fontProtectionMode = fpmBlock
    protection.blockMediaQueries = true
    protection.blockHardwareInfo = true
    protection.blockBatteryAPI = true
    protection.blockAudioAPI = true
    protection.randomizeScreenSize = true
  
  protection.logger.info("フィンガープリント保護レベルを変更: " & $level)

proc setUserAgentMode*(protection: FingerprintProtection, mode: UserAgentMode) =
  ## ユーザーエージェントモードを設定
  protection.userAgentMode = mode
  protection.logger.info("ユーザーエージェントモードを変更: " & $mode)

proc setCanvasMode*(protection: FingerprintProtection, mode: CanvasMode) =
  ## Canvasモードを設定
  protection.canvasMode = mode
  protection.logger.info("Canvasモードを変更: " & $mode)

proc setWebGLMode*(protection: FingerprintProtection, mode: WebGLMode) =
  ## WebGLモードを設定
  protection.webglMode = mode
  protection.logger.info("WebGLモードを変更: " & $mode)

proc setTimeResolutionMode*(protection: FingerprintProtection, mode: TimeResolutionMode) =
  ## 時間精度モードを設定
  protection.timeResolutionMode = mode
  protection.logger.info("時間精度モードを変更: " & $mode)

proc setFontProtectionMode*(protection: FingerprintProtection, mode: FontProtectionMode) =
  ## フォント保護モードを設定
  protection.fontProtectionMode = mode
  protection.logger.info("フォント保護モードを変更: " & $mode)

proc setCustomUserAgent*(protection: FingerprintProtection, userAgent: string) =
  ## カスタムユーザーエージェントを設定
  protection.customUserAgent = userAgent
  protection.userAgentMode = uamCustom
  protection.logger.info("カスタムユーザーエージェントを設定")

proc addExemptDomain*(protection: FingerprintProtection, domain: string) =
  ## 例外ドメインを追加
  protection.exemptDomains.incl(domain)
  protection.logger.info("フィンガープリント保護の例外ドメインを追加: " & domain)

proc removeExemptDomain*(protection: FingerprintProtection, domain: string) =
  ## 例外ドメインを削除
  protection.exemptDomains.excl(domain)
  protection.logger.info("フィンガープリント保護の例外ドメインを削除: " & domain)

proc isExemptDomain*(protection: FingerprintProtection, domain: string): bool =
  ## ドメインが例外かどうかチェック
  if domain in protection.exemptDomains:
    return true
  
  # サブドメインのチェック
  for d in protection.exemptDomains:
    if domain.endsWith("." & d):
      return true
  
  return false

proc recordDetection*(protection: FingerprintProtection, technique: FingerprintingTechnique, 
                    domain: string, details: string, blocked: bool) =
  ## フィンガープリント検出を記録
  let detection = FingerprintDetection(
    technique: technique,
    domain: domain,
    timestamp: getTime(),
    details: details,
    blocked: blocked
  )
  
  protection.detectionHistory.add(detection)
  
  # 履歴サイズの制限（最新の100件のみ保持）
  if protection.detectionHistory.len > 100:
    protection.detectionHistory.delete(0)
  
  protection.logger.info("フィンガープリント検出: " & $technique & " on " & domain & 
                       (if blocked: " (ブロック)" else: " (許可)"))

#----------------------------------------
# フィンガープリント対策機能
#----------------------------------------

proc getEffectiveUserAgent*(protection: FingerprintProtection): string =
  ## 効果的なユーザーエージェントを取得
  if not protection.enabled:
    return ""  # 元のUAを使用
  
  case protection.userAgentMode
  of uamNone:
    return ""  # 元のUAを使用
    
  of uamMinimal:
    # プラットフォーム情報を最小限に
    return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/98.0.4758.102 Safari/537.36"
    
  of uamGeneric:
    # よりジェネリックなUA
    return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/98.0.0.0 Safari/537.36"
    
  of uamRotating:
    # 定期的なローテーション
    let now = getTime()
    if now - protection.lastRotationTime > protection.userAgentRotationInterval:
      protection.lastRotationTime = now
      # ランダムにUAを選択
    
    let index = rand(protection.rotationUserAgents.high)
    return protection.rotationUserAgents[index]
    
  of uamCustom:
    # カスタムUA
    if protection.customUserAgent.len > 0:
      return protection.customUserAgent
    else:
      return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/98.0.4758.102 Safari/537.36"

proc modifyRequestHeaders*(protection: FingerprintProtection, request: HttpRequest, domain: string): HttpRequest =
  ## リクエストヘッダーを修正
  if not protection.enabled or protection.isExemptDomain(domain):
    return request
  
  var modifiedRequest = request
  var foundUA = false
  
  # ヘッダーの修正
  var newHeaders: seq[(string, string)] = @[]
  for (name, value) in request.headers:
    if name.toLowerAscii() == "user-agent":
      foundUA = true
      let effectiveUA = protection.getEffectiveUserAgent()
      if effectiveUA.len > 0:
        newHeaders.add(("User-Agent", effectiveUA))
        protection.recordDetection(ftUserAgent, domain, value, true)
      else:
        newHeaders.add((name, value))
    elif name.toLowerAscii() == "accept-language":
      # 言語設定を一般化
      if protection.level >= fpStrict:
        newHeaders.add(("Accept-Language", "en-US,en;q=0.9"))
        protection.recordDetection(ftLanguage, domain, value, true)
      else:
        newHeaders.add((name, value))
    elif name.toLowerAscii() == "dnt":
      # DoNotTrackヘッダーの処理
      if protection.level >= fpStrict:
        newHeaders.add(("DNT", "1"))  # 常に追跡拒否に設定
        protection.recordDetection(ftDNT, domain, value, true)
      else:
        newHeaders.add((name, value))
    else:
      newHeaders.add((name, value))
  
  # User-Agentが見つからなかった場合は追加
  if not foundUA:
    let effectiveUA = protection.getEffectiveUserAgent()
    if effectiveUA.len > 0:
      newHeaders.add(("User-Agent", effectiveUA))
  
  modifiedRequest.headers = newHeaders
  return modifiedRequest

proc getCanvasJavaScript*(protection: FingerprintProtection): string =
  ## Canvas保護のためのJavaScriptを生成
  if not protection.enabled:
    return ""
  
  case protection.canvasMode
  of cmNone:
    return ""
    
  of cmWarn:
    # 警告のみ（許可の要求）
    return """
      (function() {
        const originalToDataURL = HTMLCanvasElement.prototype.toDataURL;
        const originalGetImageData = CanvasRenderingContext2D.prototype.getImageData;
        
        HTMLCanvasElement.prototype.toDataURL = function() {
          if (confirm('ウェブサイトがCanvasフィンガープリントを取得しようとしています。許可しますか？')) {
            return originalToDataURL.apply(this, arguments);
          }
          return 'data:,';
        };
        
        CanvasRenderingContext2D.prototype.getImageData = function() {
          if (confirm('ウェブサイトがCanvasフィンガープリントを取得しようとしています。許可しますか？')) {
            return originalGetImageData.apply(this, arguments);
          }
          const fakeData = originalGetImageData.apply(this, arguments);
          return fakeData;
        };
      })();
    """
    
  of cmNoise:
    # 微小なノイズを追加
    return """
      (function() {
        const originalToDataURL = HTMLCanvasElement.prototype.toDataURL;
        const originalGetImageData = CanvasRenderingContext2D.prototype.getImageData;
        
        HTMLCanvasElement.prototype.toDataURL = function() {
          const result = originalToDataURL.apply(this, arguments);
          
          // 元のキャンバスに微小なノイズを追加
          const context = this.getContext('2d');
          const imageData = context.getImageData(0, 0, this.width, this.height);
          const pixels = imageData.data;
          
          // 数ピクセルだけランダムに変更（検出されにくいノイズ）
          for (let i = 0; i < 10; i++) {
            const position = Math.floor(Math.random() * pixels.length / 4) * 4;
            pixels[position] = pixels[position] ^ 1;  // 1ビット変更
          }
          
          context.putImageData(imageData, 0, 0);
          return result;
        };
        
        CanvasRenderingContext2D.prototype.getImageData = function() {
          const result = originalGetImageData.apply(this, arguments);
          
          // 結果に微小なノイズを追加
          for (let i = 0; i < 10; i++) {
            const position = Math.floor(Math.random() * result.data.length / 4) * 4;
            result.data[position] = result.data[position] ^ 1;  // 1ビット変更
          }
          
          return result;
        };
      })();
    """
    
  of cmBlock:
    # 完全にブロック
    return """
      (function() {
        HTMLCanvasElement.prototype.toDataURL = function() {
          return 'data:,';
        };
        
        HTMLCanvasElement.prototype.toBlob = function(callback) {
          callback(new Blob([''], {type: 'image/png'}));
        };
        
        CanvasRenderingContext2D.prototype.getImageData = function() {
          const fakeData = new ImageData(1, 1);
          return fakeData;
        };
      })();
    """

proc getWebGLJavaScript*(protection: FingerprintProtection): string =
  ## WebGL保護のためのJavaScriptを生成
  if not protection.enabled:
    return ""
  
  case protection.webglMode
  of wgmNone:
    return ""
    
  of wgmMinimal:
    # 最小限の保護（識別子の一般化）
    return """
      (function() {
        // WebGLレンダラー情報を一般化
        const getParameterProxied = WebGLRenderingContext.prototype.getParameter;
        WebGLRenderingContext.prototype.getParameter = function(parameter) {
          if (parameter === 37445) { // UNMASKED_VENDOR_WEBGL
            return 'Generic GPU Vendor';
          }
          if (parameter === 37446) { // UNMASKED_RENDERER_WEBGL
            return 'Generic GPU Renderer';
          }
          return getParameterProxied.apply(this, arguments);
        };
      })();
    """
    
  of wgmBlock:
    # 完全にブロック
    return """
      (function() {
        // WebGLを無効化
        HTMLCanvasElement.prototype.getContext = (function() {
          const origGetContext = HTMLCanvasElement.prototype.getContext;
          return function(type, ...args) {
            if (type === 'webgl' || type === 'webgl2' || type === 'experimental-webgl') {
              return null;
            }
            return origGetContext.apply(this, [type, ...args]);
          };
        })();
      })();
    """

proc getTimingJavaScript*(protection: FingerprintProtection): string =
  ## タイミング保護のためのJavaScriptを生成
  if not protection.enabled:
    return ""
  
  case protection.timeResolutionMode
  of trmNone:
    return ""
    
  of trmLow:
    # 低精度（ミリ秒単位に丸め）
    return """
      (function() {
        // 時間計測APIの精度を下げる
        const originalPerformanceNow = Performance.prototype.now;
        Performance.prototype.now = function() {
          return Math.floor(originalPerformanceNow.apply(this, arguments)) + Math.random();
        };
        
        const originalDateNow = Date.now;
        Date.now = function() {
          return Math.floor(originalDateNow() / 10) * 10;
        };
        
        const originalDateGetTime = Date.prototype.getTime;
        Date.prototype.getTime = function() {
          return Math.floor(originalDateGetTime.apply(this, arguments) / 10) * 10;
        };
      })();
    """
    
  of trmVeryLow:
    # 非常に低精度（100ミリ秒単位に丸め）
    return """
      (function() {
        // 時間計測APIの精度を大幅に下げる
        const originalPerformanceNow = Performance.prototype.now;
        Performance.prototype.now = function() {
          return Math.floor(originalPerformanceNow.apply(this, arguments) / 100) * 100;
        };
        
        const originalDateNow = Date.now;
        Date.now = function() {
          return Math.floor(originalDateNow() / 100) * 100;
        };
        
        const originalDateGetTime = Date.prototype.getTime;
        Date.prototype.getTime = function() {
          return Math.floor(originalDateGetTime.apply(this, arguments) / 100) * 100;
        };
      })();
    """

proc getFontsJavaScript*(protection: FingerprintProtection): string =
  ## フォント保護のためのJavaScriptを生成
  if not protection.enabled:
    return ""
  
  case protection.fontProtectionMode
  of fpmNone:
    return ""
    
  of fpmCommon:
    # 一般的なフォントのみ許可
    let fontList = COMMON_FONTS.join("\", \"")
    return fmt"""
      (function() {{
        // FontFace APIをフック
        const originalFontFace = window.FontFace;
        window.FontFace = function(family, source, descriptors) {{
          const commonFonts = ["{fontList}"];
          if (commonFonts.includes(family)) {{
            return new originalFontFace(family, source, descriptors);
          }}
          // 一般的でないフォントは最も近い一般的なフォントに置き換え
          return new originalFontFace('Arial', source, descriptors);
        }};
        
        // CSSフォントチェックを妨害
        Object.defineProperty(document.body.style, 'fontFamily', {{
          get: function() {{ return this.getAttribute('font-family') || ''; }},
          set: function(value) {{ 
            const commonFonts = ["{fontList}"];
            if (commonFonts.some(font => value.includes(font))) {{
              this.setAttribute('font-family', value);
            }} else {{
              this.setAttribute('font-family', 'Arial');
            }}
          }}
        }});
      }})();
    """
    
  of fpmBlock:
    # フォント検出を完全にブロック
    return """
      (function() {
        // フォント検出を一括でブロック
        const originalGetComputedStyle = window.getComputedStyle;
        window.getComputedStyle = function(element, pseudoElt) {
          const result = originalGetComputedStyle(element, pseudoElt);
          
          // フォント関連プロパティへのアクセスを監視
          const fontProps = ['font', 'fontFamily', 'fontSize', 'fontWeight', 'fontStyle'];
          fontProps.forEach(prop => {
            Object.defineProperty(result, prop, {
              get: function() {
                if (prop === 'fontFamily') return 'Arial';
                if (prop === 'fontSize') return '16px';
                if (prop === 'fontWeight') return '400';
                if (prop === 'fontStyle') return 'normal';
                if (prop === 'font') return 'normal normal 16px Arial';
                return originalGetComputedStyle(element, pseudoElt)[prop];
              }
            });
          });
          
          return result;
        };
        
        // FontFace APIをブロック
        window.FontFace = function() {
          return {
            load: function() {
              return new Promise((resolve, reject) => {
                reject(new Error('Font loading blocked'));
              });
            },
            family: 'Arial'
          };
        };
      })();
    """

proc getOtherProtectionsJavaScript*(protection: FingerprintProtection): string =
  ## その他の保護のためのJavaScriptを生成
  if not protection.enabled:
    return ""
  
  var js = ""
  
  # バッテリーAPIブロック
  if protection.blockBatteryAPI:
    js &= """
      // バッテリーAPIを無効化
      if (navigator.getBattery) {
        navigator.getBattery = function() {
          return Promise.resolve({
            charging: true,
            chargingTime: Infinity,
            dischargingTime: Infinity,
            level: 1.0,
            addEventListener: function() {},
            removeEventListener: function() {}
          });
        };
      }
    """
  
  # AudioAPIブロック
  if protection.blockAudioAPI:
    js &= """
      // AudioContext APIを無効化
      if (window.AudioContext || window.webkitAudioContext) {
        const AudioContextProxy = function() {
          return {
            createOscillator: function() { return {}; },
            createAnalyser: function() { 
              return {
                fftSize: 2048,
                frequencyBinCount: 1024,
                getFloatFrequencyData: function(array) {
                  for (let i = 0; i < array.length; i++) {
                    array[i] = -100.0;
                  }
                },
                getByteFrequencyData: function(array) {
                  for (let i = 0; i < array.length; i++) {
                    array[i] = 0;
                  }
                }
              };
            },
            destination: {}
          };
        };
        window.AudioContext = AudioContextProxy;
        window.webkitAudioContext = AudioContextProxy;
      }
    """
  
  # 画面サイズのランダム化
  if protection.randomizeScreenSize:
    js &= """
      // 画面サイズにノイズを追加
      Object.defineProperty(window, 'innerWidth', {
        get: function() { return window.outerWidth - Math.floor(Math.random() * 10); }
      });
      Object.defineProperty(window, 'innerHeight', {
        get: function() { return window.outerHeight - Math.floor(Math.random() * 10); }
      });
      Object.defineProperty(screen, 'width', {
        get: function() { return screen.availWidth - Math.floor(Math.random() * 10); }
      });
      Object.defineProperty(screen, 'height', {
        get: function() { return screen.availHeight - Math.floor(Math.random() * 10); }
      });
    """
  
  # ハードウェア情報ブロック
  if protection.blockHardwareInfo:
    js &= """
      // ハードウェア情報を一般化
      Object.defineProperty(navigator, 'hardwareConcurrency', {
        get: function() { return 4; }
      });
      Object.defineProperty(navigator, 'deviceMemory', {
        get: function() { return 8; }
      });
      // GPUデータを一般化
      if (navigator.getGPUInfo) {
        navigator.getGPUInfo = function() {
          return Promise.resolve({
            vendor: "Generic",
            renderer: "Generic GPU",
            display: "Generic Display"
          });
        };
      }
    """
  
  # メディアクエリのブロック
  if protection.blockMediaQueries:
    js &= """
      // メディアクエリを一般化
      const originalMatchMedia = window.matchMedia;
      window.matchMedia = function(query) {
        // color-scheme、preferredColorScheme、prefers-reduced-motion などの
        // フィンガープリントに使われやすいクエリを一般化
        if (query.includes('color-scheme') || 
            query.includes('prefers-color-scheme') || 
            query.includes('prefers-reduced-motion') ||
            query.includes('prefers-reduced-transparency') ||
            query.includes('prefers-contrast') ||
            query.includes('forced-colors') ||
            query.includes('inverted-colors')) {
          return {
            matches: false,
            media: query,
            addEventListener: function() {},
            removeEventListener: function() {}
          };
        }
        return originalMatchMedia(query);
      };
    """
  
  return js

proc getProtectionJavaScript*(protection: FingerprintProtection, domain: string): string =
  ## すべての保護用JavaScriptを生成
  if not protection.enabled or protection.isExemptDomain(domain):
    return ""
  
  var js = """
    // フィンガープリント保護スクリプト
    (function() {
      // 保護アクティベーションフラグ
      window.__browser_fingerprint_protection = true;
  """
  
  js &= protection.getCanvasJavaScript()
  js &= protection.getWebGLJavaScript()
  js &= protection.getTimingJavaScript()
  js &= protection.getFontsJavaScript()
  js &= protection.getOtherProtectionsJavaScript()
  
  js &= """
    })();
  """
  
  return js

proc toJson*(protection: FingerprintProtection): JsonNode =
  ## JSONシリアライズ
  result = newJObject()
  result["enabled"] = %protection.enabled
  result["level"] = %($protection.level)
  result["userAgentMode"] = %($protection.userAgentMode)
  result["canvasMode"] = %($protection.canvasMode)
  result["webglMode"] = %($protection.webglMode)
  result["timeResolutionMode"] = %($protection.timeResolutionMode)
  result["fontProtectionMode"] = %($protection.fontProtectionMode)
  
  result["blockMediaQueries"] = %protection.blockMediaQueries
  result["blockHardwareInfo"] = %protection.blockHardwareInfo
  result["blockBatteryAPI"] = %protection.blockBatteryAPI
  result["blockAudioAPI"] = %protection.blockAudioAPI
  result["randomizeScreenSize"] = %protection.randomizeScreenSize
  
  if protection.customUserAgent.len > 0:
    result["customUserAgent"] = %protection.customUserAgent
  
  var exemptDomains = newJArray()
  for domain in protection.exemptDomains:
    exemptDomains.add(%domain)
  result["exemptDomains"] = exemptDomains
  
  var detections = newJArray()
  for detection in protection.detectionHistory:
    var item = newJObject()
    item["technique"] = %($detection.technique)
    item["domain"] = %detection.domain
    item["timestamp"] = %($detection.timestamp)
    item["details"] = %detection.details
    item["blocked"] = %detection.blocked
    detections.add(item)
  result["detections"] = detections 