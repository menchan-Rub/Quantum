# css_js_protection.nim
## CSS/JSエンジン特性の隠蔽モジュール
## ブラウザのCSS/JavaScript処理特性を均質化し、指紋追跡を防止する

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
  parsecfg,
  re
]

type
  CssJsProtector* = ref CssJsProtectorObj
  CssJsProtectorObj = object
    enabled*: bool                   ## 有効フラグ
    cssFeatureSet*: CssFeatureSet    ## CSSの機能セット
    jsFeatureSet*: JsFeatureSet      ## JavaScriptの機能セット
    protectionLevel*: ProtectionLevel  ## 保護レベル
    sessionKey*: string              ## セッションキー
    logger*: Logger                  ## ロガー
    customCssRules*: seq[string]     ## カスタムCSSルール
    customJsInterceptions*: seq[string]  ## カスタムJS傍受対象

  ProtectionLevel* = enum
    plMinimal,    ## 最小限の保護
    plStandard,   ## 標準的な保護
    plExtensive,  ## 広範な保護
    plMaximum     ## 最大の保護

  CssFeatureSet* = object
    animationTiming*: bool           ## アニメーションタイミング機能
    gridLayout*: bool                ## グリッドレイアウト
    flexbox*: bool                   ## フレックスボックス
    customProperties*: bool          ## カスタムプロパティ
    transforms3D*: bool              ## 3D変換
    fontVariations*: bool            ## フォントバリエーション
    colorFunctions*: bool            ## 色関数
    maskImages*: bool                ## マスク画像
    modernSelectors*: bool           ## モダンセレクタ
    containment*: bool               ## コンテインメント

  JsFeatureSet* = object
    modernTimers*: bool              ## 高精度タイマー
    asyncAwait*: bool                ## async/await機能
    proxies*: bool                   ## Proxyオブジェクト
    webWorkers*: bool                ## Web Workers
    webAssembly*: bool               ## WebAssembly
    intlAPIs*: bool                  ## Intl APIs
    domRectPrecision*: bool          ## DOMRect精度
    websockets*: bool                ## WebSockets
    audioAPIs*: bool                 ## Audio APIs
    webRTC*: bool                    ## WebRTC APIs

const
  # CSS標準化用のルール
  CSS_STANDARDIZATION_RULES = [
    """
    /* ワークアラウンドのためのグローバルルール */
    * {
      /* アニメーション挙動を均一化 */
      animation-timing-function: ease !important;
      transition-timing-function: ease !important;
      
      /* フォントレンダリングを均一化 */
      text-rendering: optimizeLegibility !important;
      font-feature-settings: normal !important;
      
      /* スクロール挙動を均一化 */
      scroll-behavior: auto !important;
      
      /* レンダリング挙動を均一化 */
      transform-style: flat !important;
    }
    """,
    
    """
    /* Grid/Flexの挙動を均一化 */
    .grid, [class*="grid"], [style*="display: grid"] {
      grid-gap: 0 !important;
      gap: 0 !important;
      align-items: center !important;
      justify-items: center !important;
    }
    
    .flex, [class*="flex"], [style*="display: flex"] {
      align-items: center !important;
      justify-content: center !important;
    }
    """,
    
    """
    /* カスタムプロパティの使用を制限 */
    :root {
      --fp-safe-1: #000000;
      --fp-safe-2: #FFFFFF;
      --fp-safe-3: #FF0000;
      --fp-safe-4: #00FF00;
      --fp-safe-5: #0000FF;
    }
    """,
    
    """
    /* フォント関連の均一化 */
    * {
      font-variant: normal !important;
      font-variant-ligatures: no-common-ligatures !important;
      font-variant-position: normal !important;
      font-variant-caps: normal !important;
      font-variant-numeric: normal !important;
      font-variant-east-asian: normal !important;
    }
    """
  ]

  # JS標準化用のインターセプター
  JS_STANDARDIZATION_INTERCEPTORS = [
    """
    // 高精度タイマーの精度を下げる
    const originalPerformanceNow = Performance.prototype.now;
    Performance.prototype.now = function() {
      return Math.floor(originalPerformanceNow.call(this) * 10) / 10;
    };
    
    // Dateの精度も下げる
    const originalDateNow = Date.now;
    Date.now = function() {
      return Math.floor(originalDateNow() / 10) * 10;
    };
    
    const originalDateGetTime = Date.prototype.getTime;
    Date.prototype.getTime = function() {
      return Math.floor(originalDateGetTime.call(this) / 10) * 10;
    };
    """,
    
    """
    // DOMRect関連の精度を下げる
    (function() {
      const domRectProps = ['x', 'y', 'width', 'height', 'top', 'right', 'bottom', 'left'];
      
      // DOMRectプロトタイプがある場合
      if (typeof DOMRect !== 'undefined') {
        const originalDOMRectProto = DOMRect.prototype;
        
        for (const prop of domRectProps) {
          const original = Object.getOwnPropertyDescriptor(originalDOMRectProto, prop);
          if (original && original.get) {
            Object.defineProperty(originalDOMRectProto, prop, {
              get: function() {
                const value = original.get.call(this);
                return Math.floor(value * 100) / 100;
              }
            });
          }
        }
      }
      
      // ClientRect/DOMRectReadOnlyのサポート
      for (const rectConstructor of ['ClientRect', 'DOMRectReadOnly']) {
        if (typeof window[rectConstructor] !== 'undefined') {
          const proto = window[rectConstructor].prototype;
          
          for (const prop of domRectProps) {
            const original = Object.getOwnPropertyDescriptor(proto, prop);
            if (original && original.get) {
              Object.defineProperty(proto, prop, {
                get: function() {
                  const value = original.get.call(this);
                  return Math.floor(value * 100) / 100;
                }
              });
            }
          }
        }
      }
    })();
    """,
    
    """
    // ブラウザの挙動を標準化
    (function() {
      // キャンバス指紋対策
      if (HTMLCanvasElement.prototype.getContext) {
        const originalGetContext = HTMLCanvasElement.prototype.getContext;
        HTMLCanvasElement.prototype.getContext = function(contextType, ...args) {
          const context = originalGetContext.call(this, contextType, ...args);
          if (context && contextType === '2d') {
            const originalMeasureText = context.measureText;
            context.measureText = function(text) {
              const metrics = originalMeasureText.call(this, text);
              // 測定値の精度を下げる
              for (const prop in metrics) {
                if (typeof metrics[prop] === 'number') {
                  metrics[prop] = Math.floor(metrics[prop] * 10) / 10;
                }
              }
              return metrics;
            };
          }
          return context;
        };
      }
      
      // Audio API指紋対策
      if (typeof AudioBuffer !== 'undefined') {
        const originalGetChannelData = AudioBuffer.prototype.getChannelData;
        AudioBuffer.prototype.getChannelData = function(channel) {
          const data = originalGetChannelData.call(this, channel);
          // データをわずかに変更
          if (data.length > 0) {
            // 最初と最後の数サンプルだけ変更（パフォーマンスのため）
            for (let i = 0; i < Math.min(10, data.length); i++) {
              data[i] = Math.floor(data[i] * 1000) / 1000;
            }
            for (let i = Math.max(0, data.length - 10); i < data.length; i++) {
              data[i] = Math.floor(data[i] * 1000) / 1000;
            }
          }
          return data;
        };
      }
    })();
    """,
    
    """
    // Proxyの標準化
    (function() {
      // Proxyの特性を隠す
      if (typeof Proxy !== 'undefined') {
        Proxy.toString = function() { 
          return "function Proxy() { [native code] }"; 
        };
      }
      
      // JSON.stringifyの挙動を均一化
      const originalStringify = JSON.stringify;
      JSON.stringify = function(...args) {
        // 循環参照を検出するためのシンプルな実装
        const seen = new WeakSet();
        const replacer = (key, value) => {
          if (typeof value === 'object' && value !== null) {
            if (seen.has(value)) {
              return '[Circular]';
            }
            seen.add(value);
          }
          return value;
        };
        
        // 第2引数がreplacerの場合はそれを使用
        if (typeof args[1] === 'function') {
          const originalReplacer = args[1];
          args[1] = function(key, value) {
            return originalReplacer(key, replacer(key, value));
          };
        } else if (args[1] === undefined) {
          args[1] = replacer;
        }
        
        return originalStringify.apply(JSON, args);
      };
    })();
    """,
    
    """
    // WebRTC関連の保護
    (function() {
      if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
        const originalEnumerateDevices = navigator.mediaDevices.enumerateDevices;
        navigator.mediaDevices.enumerateDevices = async function() {
          const devices = await originalEnumerateDevices.call(this);
          // デバイスIDとラベルを一般化
          return devices.map((device, index) => {
            device.deviceId = `standardized-id-${device.kind}-${index}`;
            device.groupId = `standardized-group-${device.kind}`;
            device.label = device.label ? `${device.kind} Device ${index}` : '';
            return device;
          });
        };
      }
    })();
    """
  ]

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

# CssJsProtectorの実装
proc newCssJsProtector*(level: ProtectionLevel = plStandard): CssJsProtector =
  ## 新しいCSS/JS保護モジュールを作成
  new(result)
  result.enabled = true
  result.protectionLevel = level
  result.sessionKey = generateSessionKey()
  result.logger = newConsoleLogger()
  result.customCssRules = @[]
  result.customJsInterceptions = @[]
  
  # デフォルト機能セットを設定
  result.cssFeatureSet = CssFeatureSet(
    animationTiming: true,
    gridLayout: true,
    flexbox: true,
    customProperties: true,
    transforms3D: true,
    fontVariations: true,
    colorFunctions: true,
    maskImages: true,
    modernSelectors: true,
    containment: true
  )
  
  result.jsFeatureSet = JsFeatureSet(
    modernTimers: true,
    asyncAwait: true,
    proxies: true,
    webWorkers: true,
    webAssembly: true,
    intlAPIs: true,
    domRectPrecision: true,
    websockets: true,
    audioAPIs: true,
    webRTC: true
  )
  
  # 保護レベルに基づいて機能を設定
  case level
  of plMinimal:
    # 最小限の保護
    result.cssFeatureSet.transforms3D = false
    result.cssFeatureSet.maskImages = false
    result.jsFeatureSet.domRectPrecision = false
    result.jsFeatureSet.modernTimers = false
  
  of plStandard:
    # 標準的な保護
    result.cssFeatureSet.transforms3D = false
    result.cssFeatureSet.fontVariations = false
    result.cssFeatureSet.maskImages = false
    result.jsFeatureSet.domRectPrecision = false
    result.jsFeatureSet.modernTimers = false
    result.jsFeatureSet.audioAPIs = false
  
  of plExtensive:
    # 広範な保護
    result.cssFeatureSet.transforms3D = false
    result.cssFeatureSet.fontVariations = false
    result.cssFeatureSet.maskImages = false
    result.cssFeatureSet.colorFunctions = false
    result.cssFeatureSet.modernSelectors = false
    result.jsFeatureSet.domRectPrecision = false
    result.jsFeatureSet.modernTimers = false
    result.jsFeatureSet.audioAPIs = false
    result.jsFeatureSet.proxies = false
    result.jsFeatureSet.webRTC = false
  
  of plMaximum:
    # 最大の保護（ほとんどの機能を制限）
    result.cssFeatureSet.animationTiming = false
    result.cssFeatureSet.gridLayout = false
    result.cssFeatureSet.transforms3D = false
    result.cssFeatureSet.fontVariations = false
    result.cssFeatureSet.maskImages = false
    result.cssFeatureSet.colorFunctions = false
    result.cssFeatureSet.modernSelectors = false
    result.cssFeatureSet.containment = false
    result.jsFeatureSet.modernTimers = false
    result.jsFeatureSet.proxies = false
    result.jsFeatureSet.webWorkers = false
    result.jsFeatureSet.webAssembly = false
    result.jsFeatureSet.intlAPIs = false
    result.jsFeatureSet.domRectPrecision = false
    result.jsFeatureSet.websockets = false
    result.jsFeatureSet.audioAPIs = false
    result.jsFeatureSet.webRTC = false

proc setProtectionLevel*(protector: CssJsProtector, level: ProtectionLevel) =
  ## 保護レベルを設定
  protector.protectionLevel = level
  
  # 保護レベルに基づいて機能を再設定
  var newProtector = newCssJsProtector(level)
  protector.cssFeatureSet = newProtector.cssFeatureSet
  protector.jsFeatureSet = newProtector.jsFeatureSet

proc enable*(protector: CssJsProtector) =
  ## 保護を有効化
  protector.enabled = true

proc disable*(protector: CssJsProtector) =
  ## 保護を無効化
  protector.enabled = false

proc isEnabled*(protector: CssJsProtector): bool =
  ## 保護が有効かどうか
  return protector.enabled

proc addCustomCssRule*(protector: CssJsProtector, cssRule: string) =
  ## カスタムCSSルールを追加
  protector.customCssRules.add(cssRule)

proc addCustomJsInterception*(protector: CssJsProtector, jsCode: string) =
  ## カスタムJavaScriptインターセプションを追加
  protector.customJsInterceptions.add(jsCode)

proc generateCssOverrides*(protector: CssJsProtector): string =
  ## CSS上書きルールを生成
  if not protector.enabled:
    return ""
  
  var rules: seq[string] = @[]
  
  # 標準化ルールを適用
  for rule in CSS_STANDARDIZATION_RULES:
    rules.add(rule)
  
  # カスタムルールを追加
  for rule in protector.customCssRules:
    rules.add(rule)
  
  # CSS機能セットに基づいて特定の機能を無効化するルール
  if not protector.cssFeatureSet.animationTiming:
    rules.add("""
    * {
      animation: none !important;
      transition: none !important;
      animation-timing-function: linear !important;
      transition-timing-function: linear !important;
    }
    """)
  
  if not protector.cssFeatureSet.gridLayout:
    rules.add("""
    * {
      display: block !important;
      grid-template-columns: none !important;
      grid-template-rows: none !important;
      grid-template-areas: none !important;
      grid-template: none !important;
    }
    """)
  
  if not protector.cssFeatureSet.flexbox:
    rules.add("""
    * {
      display: block !important;
      flex: none !important;
      flex-direction: row !important;
      flex-wrap: nowrap !important;
      flex-flow: row nowrap !important;
      justify-content: flex-start !important;
      align-items: flex-start !important;
      align-content: flex-start !important;
    }
    """)
  
  if not protector.cssFeatureSet.transforms3D:
    rules.add("""
    * {
      transform: none !important;
      transform-style: flat !important;
      perspective: none !important;
      backface-visibility: visible !important;
    }
    """)
  
  if not protector.cssFeatureSet.fontVariations:
    rules.add("""
    * {
      font-variation-settings: normal !important;
      font-feature-settings: normal !important;
      font-variant: normal !important;
      font-variant-ligatures: normal !important;
      font-variant-position: normal !important;
      font-variant-caps: normal !important;
      font-variant-numeric: normal !important;
      font-variant-east-asian: normal !important;
      font-weight: normal !important;
      font-stretch: normal !important;
    }
    """)
  
  return rules.join("\n\n")

proc generateJsInterceptors*(protector: CssJsProtector): string =
  ## JavaScript傍受コードを生成
  if not protector.enabled:
    return ""
  
  var interceptors: seq[string] = @[]
  
  # 標準化インターセプターを適用
  for interceptor in JS_STANDARDIZATION_INTERCEPTORS:
    interceptors.add(interceptor)
  
  # カスタムインターセプターを追加
  for interceptor in protector.customJsInterceptions:
    interceptors.add(interceptor)
  
  # JS機能セットに基づいて特定の機能を無効化/標準化するコード
  if not protector.jsFeatureSet.modernTimers:
    interceptors.add("""
    // 高精度タイマーを完全に無効化
    Performance.prototype.now = function() {
      return Math.floor(Date.now() / 100) * 100;
    };
    
    Date.now = function() {
      return Math.floor(new Date().getTime() / 100) * 100;
    };
    
    Date.prototype.getTime = function() {
      return Math.floor(new Date(this).valueOf() / 100) * 100;
    };
    """)
  
  if not protector.jsFeatureSet.webAssembly:
    interceptors.add("""
    // WebAssemblyを無効化
    if (typeof WebAssembly !== 'undefined') {
      WebAssembly = {};
    }
    """)
  
  if not protector.jsFeatureSet.intlAPIs:
    interceptors.add("""
    // Intl APIの挙動を均一化
    if (typeof Intl !== 'undefined') {
      const originalDateTimeFormat = Intl.DateTimeFormat;
      Intl.DateTimeFormat = function(...args) {
        // タイムゾーン情報を標準化
        if (args.length > 0 && typeof args[1] === 'object') {
          args[1].timeZone = 'UTC';
        }
        return originalDateTimeFormat.apply(this, args);
      };
    }
    """)
  
  if not protector.jsFeatureSet.webRTC:
    interceptors.add("""
    // WebRTCを無効化
    if (navigator.mediaDevices) {
      navigator.mediaDevices.getUserMedia = function() {
        return new Promise((resolve, reject) => {
          reject(new Error('getUserMedia is disabled for privacy reasons'));
        });
      };
      
      navigator.mediaDevices.getDisplayMedia = function() {
        return new Promise((resolve, reject) => {
          reject(new Error('getDisplayMedia is disabled for privacy reasons'));
        });
      };
      
      navigator.mediaDevices.enumerateDevices = function() {
        return new Promise((resolve) => {
          resolve([]);
        });
      };
    }
    
    if (window.RTCPeerConnection) {
      window.RTCPeerConnection = function() {
        throw new Error('RTCPeerConnection is disabled for privacy reasons');
      };
    }
    """)
  
  return interceptors.join("\n\n")

proc transformCss*(protector: CssJsProtector, cssCode: string): string =
  ## CSSコードを変換してフィンガープリント追跡を防止
  if not protector.enabled:
    return cssCode
  
  var result = cssCode
  
  # CSSの変換処理
  # フォントバリエーション
  if not protector.cssFeatureSet.fontVariations:
    result = result.replace(re"font-variation-settings\s*:.*?;", "font-variation-settings: normal;")
  
  # 3D変換
  if not protector.cssFeatureSet.transforms3D:
    result = result.replace(re"transform-style\s*:.*?;", "transform-style: flat;")
    result = result.replace(re"perspective\s*:.*?;", "perspective: none;")
  
  # カラー関数
  if not protector.cssFeatureSet.colorFunctions:
    # カラー関数をシンプルなRGBに置き換え
    result = result.replace(re"rgba?\(.*?\)", "rgb(0, 0, 0)")
    result = result.replace(re"hsla?\(.*?\)", "rgb(0, 0, 0)")
  
  # カスタムプロパティの標準化
  if not protector.cssFeatureSet.customProperties:
    result = result.replace(re"var\s*\(\s*--(?!fp-safe-).*?\)", "var(--fp-safe-1)")
  
  # CSSオーバーライドルールを追加
  let overrides = protector.generateCssOverrides()
  result = result & "\n\n" & overrides
  
  return result

proc transformJs*(protector: CssJsProtector, jsCode: string): string =
  ## JavaScriptコードを変換してフィンガープリント追跡を防止
  if not protector.enabled:
    return jsCode
  
  var result = jsCode
  
  # JSインターセプターを先頭に追加
  let interceptors = protector.generateJsInterceptors()
  result = interceptors & "\n\n" & result
  
  return result

proc getProtectionStatus*(protector: CssJsProtector): JsonNode =
  ## 保護状態をJSON形式で取得
  var cssFeatures = newJObject()
  for name, value in fieldPairs(protector.cssFeatureSet):
    cssFeatures[name] = %value
  
  var jsFeatures = newJObject()
  for name, value in fieldPairs(protector.jsFeatureSet):
    jsFeatures[name] = %value
  
  result = %*{
    "enabled": protector.enabled,
    "protectionLevel": $protector.protectionLevel,
    "cssFeatures": cssFeatures,
    "jsFeatures": jsFeatures,
    "customCssRules": protector.customCssRules.len,
    "customJsInterceptions": protector.customJsInterceptions.len
  }

when isMainModule:
  # テスト用コード
  let protector = newCssJsProtector(plStandard)
  
  # CSSの変換テスト
  let testCss = """
  .container {
    display: grid;
    grid-template-columns: 1fr 1fr;
    transform-style: preserve-3d;
    font-variation-settings: "wght" 400;
    color: rgba(255, 0, 0, 0.5);
  }
  
  .box {
    --custom-color: #ff0000;
    background-color: var(--custom-color);
  }
  """
  
  echo "Original CSS:\n", testCss
  echo "\nTransformed CSS:\n", protector.transformCss(testCss)
  
  # JSの変換テスト
  let testJs = """
  function measureTimings() {
    const start = performance.now();
    // 何らかの処理
    const end = performance.now();
    console.log(`処理時間: ${end - start}ms`);
  }
  
  function getBoundingBox(element) {
    const rect = element.getBoundingClientRect();
    return {
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height
    };
  }
  """
  
  echo "\nOriginal JS:\n", testJs
  # 実際の変換内容は長いので、インターセプターの数だけを表示
  let transformed = protector.transformJs(testJs)
  echo "\nTransformed JS (contains ", JS_STANDARDIZATION_INTERCEPTORS.len, " interceptors)"
  
  # 保護状態のテスト
  echo "\nProtection Status:\n", protector.getProtectionStatus() 