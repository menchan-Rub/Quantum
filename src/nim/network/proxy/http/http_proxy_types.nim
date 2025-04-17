## HTTP プロキシ型定義
##
## HTTPプロキシで使用される型定義と関連するユーティリティ関数を提供します。

type
  HttpProxyConnectionMode* = enum
    ## HTTPプロキシ接続モード
    hpcmDirect,       # 直接接続（プロキシなし）
    hpcmHttp,         # HTTP プロキシ
    hpcmHttps,        # HTTPS プロキシ
    hpcmHttpTunnel,   # HTTP CONNECT トンネル
    hpcmSocks5        # SOCKS5 プロキシ

  HttpProxyError* = object of CatchableError
    ## HTTPプロキシ関連のエラー

  HttpProxyAuthScheme* = enum
    ## HTTPプロキシ認証スキーム
    hpasNone,        # 認証なし
    hpasBasic,       # Basic認証
    hpasDigest,      # Digest認証
    hpasNTLM,        # NTLM認証
    hpasNegotiate    # Negotiate (SPNEGO) 認証

  HttpProxySettings* = object
    ## HTTPプロキシ設定
    enabled*: bool                       # プロキシ有効フラグ
    host*: string                        # プロキシホスト
    port*: int                           # プロキシポート
    username*: string                    # ユーザー名
    password*: string                    # パスワード
    authScheme*: HttpProxyAuthScheme     # 認証スキーム
    connectionMode*: HttpProxyConnectionMode  # 接続モード
    bypassList*: seq[string]             # プロキシをバイパスするホスト/ドメインリスト
    autoDetect*: bool                    # 自動検出フラグ
    autoConfigUrl*: string               # 自動設定スクリプトURL

  HttpProxyEvent* = enum
    ## HTTPプロキシイベント
    hpeConnecting,           # プロキシに接続中
    hpeConnected,            # プロキシに接続済み
    hpeAuthenticating,       # プロキシ認証中
    hpeAuthenticated,        # プロキシ認証済み
    hpeTunnelEstablishing,   # トンネル確立中
    hpeTunnelEstablished,    # トンネル確立済み
    hpeRequestSending,       # リクエスト送信中
    hpeRequestSent,          # リクエスト送信済み
    hpeResponseReceiving,    # レスポンス受信中
    hpeResponseReceived,     # レスポンス受信済み
    hpeError,                # エラー発生
    hpeDisconnected          # 切断

  # プロキシ選択ポリシー
  HttpProxyPolicy* = enum
    ## プロキシ選択ポリシー
    hppDirect,       # 直接接続を優先
    hppProxyOnly,    # プロキシのみ使用
    hppAutoDetect,   # 自動検出
    hppFailover      # フェイルオーバー（プロキシ失敗時に直接接続）

proc newHttpProxySettings*(): HttpProxySettings =
  ## デフォルトのHTTPプロキシ設定を作成
  result = HttpProxySettings(
    enabled: false,
    host: "",
    port: 8080,
    username: "",
    password: "",
    authScheme: hpasNone,
    connectionMode: hpcmHttp,
    bypassList: @[],
    autoDetect: false,
    autoConfigUrl: ""
  )

proc shouldBypassProxy*(settings: HttpProxySettings, host: string): bool =
  ## 指定したホストがプロキシをバイパスすべきかどうかを判定
  ##
  ## 引数:
  ##   settings: プロキシ設定
  ##   host: チェックするホスト
  ##
  ## 戻り値:
  ##   バイパスする場合はtrue、そうでない場合はfalse
  
  # プロキシが無効な場合は常にバイパス
  if not settings.enabled:
    return true
  
  # バイパスリストが空の場合はバイパスしない
  if settings.bypassList.len == 0:
    return false
  
  # localhost と 127.0.0.1 は常にバイパス
  if host == "localhost" or host == "127.0.0.1" or host == "::1":
    return true
  
  # バイパスリストをチェック
  for pattern in settings.bypassList:
    # 完全一致
    if pattern == host:
      return true
    
    # ワイルドカード（先頭の*）
    if pattern.startsWith("*"):
      let suffix = pattern[1..^1]
      if host.endsWith(suffix):
        return true
    
    # ワイルドカード（末尾の*）
    if pattern.endsWith("*"):
      let prefix = pattern[0..^2]
      if host.startsWith(prefix):
        return true
    
    # サブドメイン（先頭の.）
    if pattern.startsWith(".") and host.endsWith(pattern):
      return true
  
  # バイパスしない
  return false

proc getProxyUrlFromSettings*(settings: HttpProxySettings): string =
  ## プロキシ設定からプロキシURLを取得
  ##
  ## 引数:
  ##   settings: プロキシ設定
  ##
  ## 戻り値:
  ##   プロキシURL文字列
  
  if not settings.enabled:
    return ""
  
  let scheme = if settings.connectionMode == hpcmHttps: "https" else: "http"
  
  if settings.username.len > 0:
    # RFC 3986に準拠したエンコード（簡易版）
    var encodedUsername = settings.username
    var encodedPassword = settings.password
    
    encodedUsername = encodedUsername.replace("%", "%25").replace(":", "%3A").replace("@", "%40")
    encodedPassword = encodedPassword.replace("%", "%25").replace(":", "%3A").replace("@", "%40")
    
    result = fmt"{scheme}://{encodedUsername}:{encodedPassword}@{settings.host}:{settings.port}"
  else:
    result = fmt"{scheme}://{settings.host}:{settings.port}" 