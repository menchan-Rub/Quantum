## プロキシ管理システム
##
## 異なるプロキシ検出・設定メカニズムを統合し、URLに応じた最適なプロキシ接続を提供します。
## WPAD、PAC、手動設定、システム設定など複数のプロキシ設定方法をサポートします。

import std/[asyncdispatch, options, strformat, strutils, tables, times, uri]
import ../../../core/logging/logger
import ../http/http_proxy_client
import ../http/http_proxy_types
import ../socks/socks_client
import ../socks/socks_types
import ./auto_config/proxy_auto_config
import ./auto_config/wpad_client

type
  ProxyConfigMode* = enum
    ## プロキシ設定モード
    pcmDirect,        ## 直接接続（プロキシなし）
    pcmManual,        ## 手動設定
    pcmPacUrl,        ## PAC URL指定
    pcmAutoDetect,    ## 自動検出（WPAD）
    pcmSystemSettings ## システム設定

  ProxySelectionPolicy* = enum
    ## プロキシ選択ポリシー
    pspDirect,        ## 直接接続を優先
    pspProxyOnly,     ## プロキシのみ使用
    pspAutoDetect,    ## 自動検出を使用
    pspFailover       ## フェイルオーバー（プロキシ接続失敗時に直接接続）

  ProxyManagerConfig* = object
    ## プロキシマネージャー設定
    mode*: ProxyConfigMode                ## 設定モード
    httpSettings*: HttpProxySettings      ## HTTP/HTTPSプロキシ設定
    socksSettings*: SocksSettings         ## SOCKSプロキシ設定
    pacUrl*: string                       ## PAC URL
    autoDetect*: bool                     ## 自動検出有効フラグ
    bypassList*: seq[string]              ## プロキシをバイパスするホスト/ドメインリスト
    selectionPolicy*: ProxySelectionPolicy ## プロキシ選択ポリシー
    autoConfigUpdateInterval*: int        ## 自動設定更新間隔（秒）

  ProxyCacheEntry = object
    ## プロキシキャッシュエントリ
    url: string                      ## 対象URL
    mode: HttpProxyConnectionMode    ## 接続モード
    host: string                     ## プロキシホスト
    port: int                        ## プロキシポート
    expiry: Time                     ## 有効期限

  ProxyManager* = ref object
    ## プロキシマネージャー
    logger: Logger                    ## ロガー
    config*: ProxyManagerConfig       ## プロキシ設定
    wpadClient: WpadClient            ## WPADクライアント
    pacClient: ProxyAutoConfigClient  ## PACクライアント
    httpClient: HttpProxyClient       ## HTTPプロキシクライアント
    socksClient: SocksClient          ## SOCKSプロキシクライアント
    proxyCache: Table[string, ProxyCacheEntry] ## プロキシ解決キャッシュ
    lastWpadCheck: Time               ## 最後のWPAD検出時刻
    wpadDetected: bool                ## WPAD検出成功フラグ
    initialized: bool                 ## 初期化済みフラグ

const
  DefaultCacheExpiry = 5 * 60       ## デフォルトキャッシュ有効時間（5分）
  DefaultUpdateInterval = 60 * 60   ## デフォルト更新間隔（1時間）
  WpadRetryInterval = 20 * 60       ## WPAD再試行間隔（20分）

proc newProxyManagerConfig*(): ProxyManagerConfig =
  ## 新しいプロキシマネージャー設定を作成する
  ##
  ## 戻り値:
  ##   デフォルト設定のProxyManagerConfig
  
  result = ProxyManagerConfig(
    mode: pcmSystemSettings,
    httpSettings: newHttpProxySettings(),
    socksSettings: SocksSettings(
      enabled: false,
      host: "",
      port: 1080,
      username: "",
      password: "",
      version: svSocks5
    ),
    pacUrl: "",
    autoDetect: true,
    bypassList: @[
      "localhost", 
      "127.0.0.1", 
      "::1", 
      "*.local"
    ],
    selectionPolicy: pspFailover,
    autoConfigUpdateInterval: DefaultUpdateInterval
  )

proc newProxyManager*(config: ProxyManagerConfig = newProxyManagerConfig(), 
                     logger: Logger = nil): ProxyManager =
  ## 新しいプロキシマネージャーを作成する
  ##
  ## 引数:
  ##   config: プロキシマネージャー設定
  ##   logger: ロガー
  ##
  ## 戻り値:
  ##   ProxyManagerオブジェクト
  
  # ロガーを初期化
  let managerLogger = if logger.isNil: newLogger("ProxyManager") else: logger
  
  result = ProxyManager(
    logger: managerLogger,
    config: config,
    wpadClient: nil,
    pacClient: nil,
    httpClient: nil,
    socksClient: nil,
    proxyCache: initTable[string, ProxyCacheEntry](),
    lastWpadCheck: Time(),
    wpadDetected: false,
    initialized: false
  )

proc init*(manager: ProxyManager): Future[bool] {.async.} =
  ## プロキシマネージャーを初期化する
  ##
  ## 戻り値:
  ##   初期化に成功した場合はtrue、失敗した場合はfalse
  
  if manager.initialized:
    return true
  
  manager.logger.info("Initializing proxy manager")
  
  try:
    # 設定モードに応じて初期化
    case manager.config.mode
    of pcmDirect:
      # 直接接続モードでは何もしない
      manager.logger.info("Direct connection mode")
    
    of pcmManual:
      # 手動設定モード
      manager.logger.info("Manual proxy configuration mode")
      
      # HTTP/HTTPSプロキシクライアントを初期化
      if manager.config.httpSettings.enabled:
        manager.httpClient = newHttpProxyClient(
          manager.config.httpSettings.host,
          manager.config.httpSettings.port,
          manager.config.httpSettings.username,
          manager.config.httpSettings.password,
          logger = manager.logger
        )
        manager.logger.info(fmt"HTTP proxy configured: {manager.config.httpSettings.host}:{manager.config.httpSettings.port}")
      
      # SOCKSプロキシクライアントを初期化
      if manager.config.socksSettings.enabled:
        manager.socksClient = newSocksClient(
          manager.config.socksSettings.host,
          manager.config.socksSettings.port,
          manager.config.socksSettings.username,
          manager.config.socksSettings.password,
          manager.config.socksSettings.version,
          logger = manager.logger
        )
        manager.logger.info(fmt"SOCKS proxy configured: {manager.config.socksSettings.host}:{manager.config.socksSettings.port}")
    
    of pcmPacUrl:
      # PAC URL指定モード
      if manager.config.pacUrl.len > 0:
        manager.logger.info(fmt"PAC URL configuration mode: {manager.config.pacUrl}")
        manager.pacClient = newProxyAutoConfigClient(
          manager.config.pacUrl,
          manager.config.autoConfigUpdateInterval,
          logger = manager.logger
        )
        
        # PACファイルを取得
        let success = await manager.pacClient.fetchPacFile()
        if not success:
          manager.logger.error(fmt"Failed to fetch PAC file from: {manager.config.pacUrl}")
      else:
        manager.logger.error("PAC URL configuration mode selected but no URL provided")
    
    of pcmAutoDetect:
      # 自動検出モード（WPAD）
      manager.logger.info("Auto-detect (WPAD) configuration mode")
      manager.wpadClient = newWpadClient(manager.logger)
      
      let detected = await manager.wpadClient.detect()
      if detected:
        manager.wpadDetected = true
        manager.pacClient = manager.wpadClient.pacClient
        manager.logger.info(fmt"WPAD detected PAC URL: {manager.wpadClient.foundUrl}")
      else:
        manager.logger.warn("WPAD detection failed, will retry later")
        manager.lastWpadCheck = getTime()
    
    of pcmSystemSettings:
      # システム設定モード
      manager.logger.info("System proxy settings mode")
      
      # システムプロキシ設定を検出
      let systemProxy = detectSystemProxy()
      
      if systemProxy.enabled:
        # システムプロキシ設定が有効な場合
        if systemProxy.autoDetect:
          # 自動検出が有効な場合
          manager.config.mode = pcmAutoDetect
          manager.wpadClient = newWpadClient(manager.logger)
          
          let detected = await manager.wpadClient.detect()
          if detected:
            manager.wpadDetected = true
            manager.pacClient = manager.wpadClient.pacClient
            manager.logger.info(fmt"WPAD detected PAC URL: {manager.wpadClient.foundUrl}")
          else:
            manager.logger.warn("WPAD detection failed, will retry later")
            manager.lastWpadCheck = getTime()
        
        elif systemProxy.autoConfigUrl.len > 0:
          # PAC URLが設定されている場合
          manager.config.mode = pcmPacUrl
          manager.config.pacUrl = systemProxy.autoConfigUrl
          manager.pacClient = newProxyAutoConfigClient(
            systemProxy.autoConfigUrl,
            manager.config.autoConfigUpdateInterval,
            logger = manager.logger
          )
          
          # PACファイルを取得
          let success = await manager.pacClient.fetchPacFile()
          if not success:
            manager.logger.error(fmt"Failed to fetch PAC file from: {systemProxy.autoConfigUrl}")
        
        else:
          # 手動プロキシ設定の場合
          manager.config.mode = pcmManual
          manager.config.httpSettings = systemProxy
          
          if systemProxy.connectionMode == hpcmHttp or 
             systemProxy.connectionMode == hpcmHttps or
             systemProxy.connectionMode == hpcmHttpTunnel:
            # HTTP/HTTPSプロキシ
            manager.httpClient = newHttpProxyClient(
              systemProxy.host,
              systemProxy.port,
              systemProxy.username,
              systemProxy.password,
              logger = manager.logger
            )
            manager.logger.info(fmt"System HTTP proxy configured: {systemProxy.host}:{systemProxy.port}")
          
          elif systemProxy.connectionMode == hpcmSocks5:
            # SOCKSプロキシ
            let socksSettings = SocksSettings(
              enabled: true,
              host: systemProxy.host,
              port: systemProxy.port,
              username: systemProxy.username,
              password: systemProxy.password,
              version: svSocks5
            )
            manager.config.socksSettings = socksSettings
            
            manager.socksClient = newSocksClient(
              socksSettings.host,
              socksSettings.port,
              socksSettings.username,
              socksSettings.password,
              socksSettings.version,
              logger = manager.logger
            )
            manager.logger.info(fmt"System SOCKS proxy configured: {socksSettings.host}:{socksSettings.port}")
      else:
        # システムプロキシ設定が無効な場合は直接接続
        manager.config.mode = pcmDirect
        manager.logger.info("No system proxy configured, using direct connection")
    
    manager.initialized = true
    manager.logger.info("Proxy manager initialized successfully")
    return true
  
  except:
    let errMsg = getCurrentExceptionMsg()
    manager.logger.error(fmt"Error initializing proxy manager: {errMsg}")
    return false

proc shouldBypassProxy*(manager: ProxyManager, url: string): bool =
  ## 指定したURLがプロキシをバイパスすべきかどうかを判定する
  ##
  ## 引数:
  ##   url: チェックするURL
  ##
  ## 戻り値:
  ##   バイパスする場合はtrue、そうでない場合はfalse
  
  # URLを解析
  var uri: Uri
  try:
    uri = parseUri(url)
  except:
    # 無効なURLの場合はバイパスしない
    return false
  
  let host = uri.hostname
  
  # バイパスリストが空の場合はバイパスしない
  if manager.config.bypassList.len == 0:
    return false
  
  # localhost と 127.0.0.1 は常にバイパス
  if host == "localhost" or host == "127.0.0.1" or host == "::1":
    return true
  
  # バイパスリストをチェック
  for pattern in manager.config.bypassList:
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

proc getProxyForUrl*(manager: ProxyManager, url: string): Future[tuple[mode: HttpProxyConnectionMode, host: string, port: int]] {.async.} =
  ## 指定したURLに対するプロキシ設定を取得する
  ##
  ## 引数:
  ##   url: プロキシを決定するURL
  ##
  ## 戻り値:
  ##   (モード, ホスト, ポート) のタプル
  
  # 初期化確認
  if not manager.initialized:
    discard await manager.init()
  
  # キャッシュ有効期限のチェック
  let currentTime = getTime()
  
  # キャッシュにエントリがあるか確認
  if manager.proxyCache.hasKey(url):
    let entry = manager.proxyCache[url]
    
    # キャッシュが有効かチェック
    if entry.expiry > currentTime:
      return (entry.mode, entry.host, entry.port)
    
    # 期限切れのエントリを削除
    manager.proxyCache.del(url)
  
  # プロキシをバイパスすべきかチェック
  if manager.shouldBypassProxy(url):
    return (hpcmDirect, "", 0)
  
  # 設定モードに応じてプロキシを決定
  case manager.config.mode
  of pcmDirect:
    # 直接接続モード
    return (hpcmDirect, "", 0)
  
  of pcmManual:
    # 手動設定モード
    if manager.config.httpSettings.enabled:
      return (manager.config.httpSettings.connectionMode,
              manager.config.httpSettings.host,
              manager.config.httpSettings.port)
    
    elif manager.config.socksSettings.enabled:
      return (hpcmSocks5,
              manager.config.socksSettings.host,
              manager.config.socksSettings.port)
    
    else:
      return (hpcmDirect, "", 0)
  
  of pcmPacUrl, pcmAutoDetect:
    # PAC/WPAD モード
    
    # WPAD再検出の必要性をチェック
    if manager.config.mode == pcmAutoDetect and
       not manager.wpadDetected and
       currentTime - manager.lastWpadCheck > initDuration(seconds = WpadRetryInterval):
      
      manager.logger.info("Retrying WPAD detection")
      if not manager.wpadClient.isNil:
        let detected = await manager.wpadClient.detect()
        if detected:
          manager.wpadDetected = true
          manager.pacClient = manager.wpadClient.pacClient
          manager.logger.info(fmt"WPAD detected PAC URL: {manager.wpadClient.foundUrl}")
        else:
          manager.logger.warn("WPAD detection failed again")
      
      manager.lastWpadCheck = currentTime
    
    # PACクライアントが利用可能かチェック
    if not manager.pacClient.isNil and 
       (manager.config.mode == pcmPacUrl or manager.wpadDetected):
      
      # PACスクリプトを実行
      let (mode, host, port) = await manager.pacClient.findProxyForUrl(url)
      
      # 結果をキャッシュ
      let entry = ProxyCacheEntry(
        url: url,
        mode: mode,
        host: host,
        port: port,
        expiry: currentTime + initDuration(seconds = DefaultCacheExpiry)
      )
      manager.proxyCache[url] = entry
      
      return (mode, host, port)
    
    # PACが利用できない場合は直接接続
    return (hpcmDirect, "", 0)
  
  of pcmSystemSettings:
    # システム設定モードはinit時に他のモードに変換されているはず
    manager.logger.warn("Unexpected system settings mode, defaulting to direct connection")
    return (hpcmDirect, "", 0)

proc getHttpProxyClient*(manager: ProxyManager, url: string): Future[HttpProxyClient] {.async.} =
  ## 指定したURL向けのHTTPプロキシクライアントを取得する
  ##
  ## 引数:
  ##   url: 接続先URL
  ##
  ## 戻り値:
  ##   HttpProxyClientオブジェクト、プロキシが不要な場合はnil
  
  # プロキシ設定を取得
  let (mode, host, port) = await manager.getProxyForUrl(url)
  
  # 直接接続の場合はnilを返す
  if mode == hpcmDirect:
    return nil
  
  # HTTP/HTTPSプロキシの場合
  if mode == hpcmHttp or mode == hpcmHttps or mode == hpcmHttpTunnel:
    # 既存のクライアントがあり、同じホスト/ポートを使用している場合は再利用
    if not manager.httpClient.isNil and
       manager.httpClient.host == host and
       manager.httpClient.port == port:
      return manager.httpClient
    
    # 新しいクライアントを作成
    let proxyClient = newHttpProxyClient(
      host,
      port,
      manager.config.httpSettings.username,
      manager.config.httpSettings.password,
      logger = manager.logger
    )
    
    # 今後の再利用のためにクライアントを保存
    manager.httpClient = proxyClient
    return proxyClient
  
  # SOCKS5プロキシの場合はHTTPプロキシを使用できない
  if mode == hpcmSocks5:
    manager.logger.warn("SOCKS proxy cannot be used with HTTP client directly")
    return nil
  
  # その他の場合（通常は発生しない）
  return nil

proc getSocksClient*(manager: ProxyManager, url: string): Future[SocksClient] {.async.} =
  ## 指定したURL向けのSOCKSプロキシクライアントを取得する
  ##
  ## 引数:
  ##   url: 接続先URL
  ##
  ## 戻り値:
  ##   SocksClientオブジェクト、プロキシが不要な場合はnil
  
  # プロキシ設定を取得
  let (mode, host, port) = await manager.getProxyForUrl(url)
  
  # 直接接続の場合はnilを返す
  if mode == hpcmDirect:
    return nil
  
  # SOCKS5プロキシの場合
  if mode == hpcmSocks5:
    # 既存のクライアントがあり、同じホスト/ポートを使用している場合は再利用
    if not manager.socksClient.isNil and
       manager.socksClient.host == host and
       manager.socksClient.port == port:
      return manager.socksClient
    
    # 新しいクライアントを作成
    let socksClient = newSocksClient(
      host,
      port,
      manager.config.socksSettings.username,
      manager.config.socksSettings.password,
      svSocks5,
      logger = manager.logger
    )
    
    # 今後の再利用のためにクライアントを保存
    manager.socksClient = socksClient
    return socksClient
  
  # HTTP/HTTPSプロキシの場合はSOCKSプロキシを使用できない
  if mode == hpcmHttp or mode == hpcmHttps or mode == hpcmHttpTunnel:
    manager.logger.warn("HTTP proxy cannot be used with SOCKS client directly")
    return nil
  
  # その他の場合（通常は発生しない）
  return nil

proc refresh*(manager: ProxyManager): Future[bool] {.async.} =
  ## プロキシ設定を再読み込みする
  ##
  ## 戻り値:
  ##   更新に成功した場合はtrue、失敗した場合はfalse
  
  manager.logger.info("Refreshing proxy settings")
  
  # キャッシュをクリア
  manager.proxyCache.clear()
  
  # 設定モードに応じた更新処理
  case manager.config.mode
  of pcmPacUrl:
    # PAC URLモードの場合、PACファイルを再取得
    if not manager.pacClient.isNil:
      let success = await manager.pacClient.fetchPacFile()
      if not success:
        manager.logger.error("Failed to refresh PAC file")
        return false
  
  of pcmAutoDetect:
    # 自動検出モードの場合、WPADを再検出
    if not manager.wpadClient.isNil:
      let detected = await manager.wpadClient.detect()
      if detected:
        manager.wpadDetected = true
        manager.pacClient = manager.wpadClient.pacClient
        manager.logger.info(fmt"WPAD detected PAC URL: {manager.wpadClient.foundUrl}")
      else:
        manager.wpadDetected = false
        manager.logger.warn("WPAD detection failed during refresh")
      
      manager.lastWpadCheck = getTime()
  
  of pcmSystemSettings:
    # システム設定モードの場合、システム設定を再検出
    manager.initialized = false
    return await manager.init()
  
  of pcmDirect, pcmManual:
    # 直接接続モードと手動設定モードでは特に何もしない
    discard
  
  return true

proc close*(manager: ProxyManager) =
  ## プロキシマネージャーを閉じる
  
  try:
    # 各クライアントを閉じる
    if not manager.wpadClient.isNil:
      manager.wpadClient.close()
    
    if not manager.pacClient.isNil and manager.pacClient != manager.wpadClient.pacClient:
      manager.pacClient.close()
    
    if not manager.httpClient.isNil:
      manager.httpClient.close()
    
    if not manager.socksClient.isNil:
      manager.socksClient.close()
    
    # キャッシュをクリア
    manager.proxyCache.clear()
    
    manager.initialized = false
    manager.logger.info("Proxy manager closed")
  except:
    let errMsg = getCurrentExceptionMsg()
    manager.logger.error(fmt"Error closing proxy manager: {errMsg}") 