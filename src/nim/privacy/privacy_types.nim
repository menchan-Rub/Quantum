# privacy_types.nim
## プライバシー保護機能で使用する基本型の定義モジュール
## 追跡防止、フィンガープリント対策、データサニタイズなどで共通して使用する型を提供

import std/[
  sets,
  tables,
  options,
  times,
  strutils,
  uri,
  hashes
]

type
  TrackingSourceType* = enum
    ## トラッキングソースのタイプ
    tsAdvertising,    ## 広告関連
    tsAnalytics,      ## アナリティクス
    tsSocial,         ## ソーシャルメディア
    tsCryptomining,   ## 暗号通貨マイニング
    tsFingerprinting, ## ブラウザフィンガープリント
    tsCdn,            ## コンテンツ配信ネットワーク (CDN)
    tsEssential,      ## サイト機能に必須
    tsCustom,         ## ユーザー定義
    tsUnknown         ## 未分類

  TrackingMethod* = enum
    ## 追跡手法の分類
    tmCookie,         ## クッキーベース
    tmLocalStorage,   ## ローカルストレージ
    tmSessionStorage, ## セッションストレージ
    tmIndexedDB,      ## IndexedDB
    tmCache,          ## キャッシュ
    tmEtag,           ## ETags
    tmFingerprint,    ## ブラウザフィンガープリント
    tmPixel,          ## トラッキングピクセル
    tmReferrer,       ## リファラーベース
    tmCanvas,         ## Canvas指紋
    tmWebRTC,         ## WebRTC漏洩
    tmEvercookie,     ## 永続クッキー/スーパークッキー
    tmBeacon,         ## ビーコンAPI
    tmOther           ## その他

  FingerPrintProtectionLevel* = enum
    ## フィンガープリント保護レベル
    fpNone,           ## 保護なし
    fpMinimal,        ## 最小限の保護（誤検知防止）
    fpStandard,       ## 標準的な保護（バランス重視）
    fpStrict,         ## 厳格な保護（積極的に防止）
    fpCustom          ## カスタム設定

  BlockMode* = enum
    ## コンテンツブロックモード
    bmAllow,         ## 許可
    bmBlock,         ## ブロック
    bmRedirect,      ## リダイレクト
    bmModify,        ## 内容変更
    bmMock,          ## モック応答
    bmSanitize       ## サニタイズ

  TrackerCategory* = object
    ## トラッカーのカテゴリー情報
    name*: string             ## カテゴリ名
    description*: string      ## 説明
    sourceType*: TrackingSourceType  ## ソースタイプ
    defaultAction*: BlockMode ## デフォルトアクション
    methods*: set[TrackingMethod]  ## 使用する追跡手法

  TrackerInfo* = object
    ## トラッカーの詳細情報
    name*: string             ## トラッカー名
    company*: string          ## 運営会社
    category*: TrackerCategory  ## カテゴリ
    domains*: seq[string]     ## 関連ドメイン
    patterns*: seq[string]    ## マッチパターン
    useRegex*: bool           ## 正規表現を使用するか
    prevalence*: float        ## 普及率（%）
    exampleUrls*: seq[string] ## 例示URL
    description*: string      ## 説明
    lastUpdated*: Time        ## 最終更新日時

  TrackerRuleAction* = enum
    ## ルールのアクション
    traBlock,        ## ブロック
    traAllow,        ## 許可
    traRedirect,     ## リダイレクト
    traModify        ## 内容変更

  TrackerRule* = object
    ## トラッカールール
    id*: string              ## ルールID
    pattern*: string         ## マッチパターン
    isRegex*: bool           ## 正規表現フラグ
    domains*: seq[string]    ## 適用ドメイン（空なら全て）
    exceptDomains*: seq[string]  ## 除外ドメイン
    resourceTypes*: seq[string]  ## リソースタイプ（js, image等）
    action*: TrackerRuleAction   ## アクション
    case action*: TrackerRuleAction
    of traRedirect:
      redirectUrl*: string         ## リダイレクト先URL
    of traModify:
      modificationScript*: string  ## 変更用スクリプト
    else:
      discard

  ListProvider* = enum
    ## ブロックリストプロバイダー
    lpEasyList,      ## EasyList
    lpEasyPrivacy,   ## EasyPrivacy
    lpFanboy,        ## Fanboy's List
    lpAdGuard,       ## AdGuard
    lpUblock,        ## uBlock Origin
    lpDisconnect,    ## Disconnect.me
    lpCustom         ## カスタムリスト

  PrivacyListInfo* = object
    ## プライバシーリスト情報
    name*: string            ## リスト名
    provider*: ListProvider  ## プロバイダー
    url*: string             ## ダウンロードURL
    description*: string     ## 説明
    version*: string         ## バージョン
    lastUpdated*: Time       ## 最終更新日時
    expires*: Time           ## 有効期限
    count*: int              ## ルール数
    homepage*: string        ## ホームページ
    license*: string         ## ライセンス
    
  TrackerBlockerSeverity* = enum
    ## ブロッカーの厳格度
    tbsRelaxed,      ## 緩和（重要なもののみブロック）
    tbsStandard,     ## 標準（バランス）
    tbsStrict,       ## 厳格（積極的にブロック）
    tbsCustom        ## カスタム設定

  FingerprintVector* = enum
    ## フィンガープリントの要素
    fvUserAgent,         ## User-Agent
    fvPlugins,           ## プラグインリスト
    fvScreenResolution,  ## 画面解像度
    fvScreenColorDepth,  ## 画面色深度
    fvTimezone,          ## タイムゾーン
    fvLanguage,          ## 言語設定
    fvSystemFonts,       ## システムフォント
    fvCanvas,            ## Canvas指紋
    fvWebGL,             ## WebGL指紋
    fvHardware,          ## ハードウェア情報
    fvAudioContext,      ## AudioContext指紋
    fvBatteryStatus,     ## バッテリー状態
    fvMediaDevices,      ## メディアデバイス
    fvDomRect,           ## DOMRect値
    fvTouchpoints,       ## タッチポイント情報
    fvWebRTC,            ## WebRTC情報漏洩
    fvSpeechSynthesis,   ## 音声合成
    fvClientHints,       ## クライアントヒント

  HeaderModificationAction* = enum
    ## ヘッダー変更アクション
    hmaRemove,      ## 削除
    hmaReplace,     ## 置換
    hmaAdd,         ## 追加
    hmaTokenize     ## トークン化（ユニーク値を置換）

  HeaderModification* = object
    ## ヘッダー変更定義
    headerName*: string                ## ヘッダー名
    action*: HeaderModificationAction  ## アクション
    case action*: HeaderModificationAction
    of hmaReplace, hmaAdd:
      value*: string                   ## 新しい値
    of hmaTokenize:
      prefix*: string                  ## トークンプレフィックス
      persistent*: bool                ## セッション間で一貫性保持するか
    else:
      discard

  DataSanitizationMode* = enum
    ## データサニタイゼーションモード
    dsmNone,         ## サニタイズなし
    dsmRemove,       ## 削除
    dsmGeneralize,   ## 一般化
    dsmTruncate,     ## 一部削除
    dsmRandomize,    ## ランダム化

  ReferrerPolicy* = enum
    ## リファラーポリシー
    rpNoReferrer,               ## リファラーを送信しない
    rpNoReferrerWhenDowngrade,  ## HTTPSからHTTPの場合は送信しない
    rpSameOrigin,               ## 同一オリジンのみ送信
    rpOrigin,                   ## オリジンのみ送信（パスなし）
    rpStrictOrigin,             ## 同等以上のセキュリティの場合オリジンのみ
    rpOriginWhenCrossOrigin,    ## クロスオリジンの場合はオリジンのみ
    rpStrictOriginWhenCrossOrigin,  ## クロスオリジンかつ同等以上のセキュリティ
    rpUnsafeUrl                 ## 常に完全なURLを送信

  CookieControlPolicy* = enum
    ## クッキー制御ポリシー
    ccpAcceptAll,            ## すべて受け入れ
    ccpRejectThirdParty,     ## サードパーティを拒否
    ccpRejectTracking,       ## トラッキングクッキーを拒否
    ccpPartitionThirdParty,  ## サードパーティクッキーを分離保存
    ccpRejectAll,            ## すべて拒否（必須のみ許可）
    ccpCustom                ## カスタム設定

  PrivacyModeType* = enum
    ## プライバシーモードの種類
    pmStandard,      ## 標準ブラウジング
    pmPrivate,       ## プライベートブラウジング
    pmUltraPrivate   ## 超プライバシーモード（Tor等）

  PrivacySettings* = object
    ## プライバシー設定
    trackerBlocking*: TrackerBlockerSeverity     ## トラッカーブロック設定
    fingerPrintProtection*: FingerPrintProtectionLevel  ## フィンガープリント保護
    cookieControl*: CookieControlPolicy          ## クッキー制御
    referrerPolicy*: ReferrerPolicy              ## リファラーポリシー
    doNotTrack*: bool                            ## DNTヘッダー送信
    cookieLifetime*: int                         ## クッキー寿命（秒, 0=無期限）
    privateBrowsing*: bool                       ## プライベートブラウジング
    siteIsolation*: bool                         ## サイト分離
    webRtcPolicy*: bool                          ## WebRTC IPアドレス保護
    trackingParameterStripping*: bool            ## URL追跡パラメータ除去
    httpsOnly*: bool                             ## HTTPSのみ許可
    javascriptBlocking*: bool                    ## JavaScriptブロック
    localStorageCleaning*: bool                  ## ローカルストレージ自動クリア
    customRules*: seq[TrackerRule]               ## カスタムルール
    whitelistedDomains*: seq[string]             ## ホワイトリストドメイン

  PrivacyReport* = object
    ## プライバシーレポート
    url*: string                      ## 対象URL
    domain*: string                   ## ドメイン
    timestamp*: Time                  ## タイムスタンプ
    trackersBlocked*: int             ## ブロックされたトラッカー数
    cookiesBlocked*: int              ## ブロックされたクッキー数
    fingerprintingAttempts*: int      ## フィンガープリント試行数
    javascriptInterventions*: int     ## JavaScriptへの介入数
    totalRequests*: int               ## リクエスト総数
    blockedRequests*: int             ## ブロックされたリクエスト数
    modifiedHeaders*: int             ## 変更されたヘッダー数
    trackerDetails*: seq[tuple[name: string, category: string, url: string]]  ## トラッカー詳細

  BlockedResource* = object
    ## ブロックされたリソース情報
    url*: string                      ## URL
    type*: string                     ## リソースタイプ
    domain*: string                   ## ドメイン
    rule*: string                     ## 適用ルール
    timestamp*: Time                  ## タイムスタンプ
    parentUrl*: string                ## 親URL
    tracker*: Option[TrackerInfo]     ## トラッカー情報

# 文字列からトラッキングソースタイプへの変換
proc parseTrackingSourceType*(s: string): TrackingSourceType =
  ## 文字列からトラッキングソースタイプへの変換
  case s.toLowerAscii()
  of "advertising", "ads", "ad": result = tsAdvertising
  of "analytics": result = tsAnalytics
  of "social", "social media", "socialnet": result = tsSocial
  of "cryptomining", "mining", "crypto": result = tsCryptomining
  of "fingerprinting", "fingerprint": result = tsFingerprinting
  of "cdn", "content delivery": result = tsCdn
  of "essential", "required", "necessary": result = tsEssential
  of "custom": result = tsCustom
  else: result = tsUnknown

# デフォルトのプライバシー設定を生成
proc defaultPrivacySettings*(): PrivacySettings =
  ## デフォルトのプライバシー設定を生成
  result = PrivacySettings(
    trackerBlocking: tbsStandard,
    fingerPrintProtection: fpStandard,
    cookieControl: ccpRejectThirdParty,
    referrerPolicy: rpStrictOriginWhenCrossOrigin,
    doNotTrack: true,
    cookieLifetime: 7 * 24 * 60 * 60, # 7日
    privateBrowsing: false,
    siteIsolation: true,
    webRtcPolicy: true,
    trackingParameterStripping: true,
    httpsOnly: false,
    javascriptBlocking: false,
    localStorageCleaning: false,
    customRules: @[],
    whitelistedDomains: @[]
  )

# 強化されたプライバシー設定を生成
proc enhancedPrivacySettings*(): PrivacySettings =
  ## セキュリティとプライバシーを強化した設定を生成
  result = PrivacySettings(
    trackerBlocking: tbsStrict,
    fingerPrintProtection: fpStrict,
    cookieControl: ccpRejectTracking,
    referrerPolicy: rpSameOrigin,
    doNotTrack: true,
    cookieLifetime: 1 * 24 * 60 * 60, # 1日
    privateBrowsing: false,
    siteIsolation: true,
    webRtcPolicy: true,
    trackingParameterStripping: true,
    httpsOnly: true,
    javascriptBlocking: false,
    localStorageCleaning: true,
    customRules: @[],
    whitelistedDomains: @[]
  )

# プライベートモード用設定を生成
proc privateModePravacySettings*(): PrivacySettings =
  ## プライベートブラウジングモード用の設定を生成
  result = PrivacySettings(
    trackerBlocking: tbsStrict,
    fingerPrintProtection: fpStrict,
    cookieControl: ccpRejectAll,
    referrerPolicy: rpNoReferrerWhenDowngrade,
    doNotTrack: true,
    cookieLifetime: 0, # セッション終了で削除
    privateBrowsing: true,
    siteIsolation: true,
    webRtcPolicy: true,
    trackingParameterStripping: true,
    httpsOnly: true,
    javascriptBlocking: false,
    localStorageCleaning: true,
    customRules: @[],
    whitelistedDomains: @[]
  ) 