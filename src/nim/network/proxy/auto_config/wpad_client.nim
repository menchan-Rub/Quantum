## Web Proxy Auto-Discovery (WPAD) クライアント
##
## WPADプロトコルを使用してプロキシ自動設定(PAC)ファイルの場所を自動検出します。
## DHCPおよびDNSベースの検出メカニズムをサポートします。

import std/[asyncdispatch, httpclient, net, nativesockets, options, os, random, sequtils, strformat, strutils, uri]
import ../../../core/logging/logger
import ./proxy_auto_config

type
  WpadDiscoveryMethod* = enum
    ## WPAD検出方法
    wdmDhcp,      ## DHCPベースの検出
    wdmDns        ## DNSベースの検出

  WpadClient* = ref object
    ## WPAD（Web Proxy Auto-Discovery）クライアント
    logger: Logger              ## ロガー
    httpClient: HttpClient      ## HTTPクライアント
    pacClient*: ProxyAutoConfigClient  ## PACクライアント
    foundUrl*: string           ## 検出されたPAC URL
    discoveryMethods*: seq[WpadDiscoveryMethod]  ## 使用する検出方法
    timeout*: int               ## タイムアウト（ミリ秒）
    maxRetries*: int            ## 最大再試行回数
    userAgent*: string          ## ユーザーエージェント文字列

const
  DefaultTimeout = 5000         ## デフォルトタイムアウト（5秒）
  MaxRedirects = 5              ## 最大リダイレクト数
  DnsDomainLevels = 5           ## DNSドメインレベル（wpad.example.com, wpad.co.jp など）
  DefaultMaxRetries = 3         ## デフォルト最大再試行回数
  DefaultUserAgent = "Mozilla/5.0 NimWpadClient/1.0"  ## デフォルトユーザーエージェント

proc newWpadClient*(logger: Logger = nil): WpadClient =
  ## 新しいWPADクライアントを作成する
  ##
  ## 引数:
  ##   logger: ロガー
  ##
  ## 戻り値:
  ##   WpadClientオブジェクト
  
  # ロガーを初期化
  let clientLogger = if logger.isNil: newLogger("WpadClient") else: logger
  
  # カスタムHTTPクライアントを作成
  var httpClient = newHttpClient()
  httpClient.timeout = DefaultTimeout
  
  var client = WpadClient(
    logger: clientLogger,
    httpClient: httpClient,
    pacClient: nil,
    foundUrl: "",
    discoveryMethods: @[wdmDns, wdmDhcp],  # デフォルトはDNS、DHCPの順
    timeout: DefaultTimeout,
    maxRetries: DefaultMaxRetries,
    userAgent: DefaultUserAgent
  )
  
  # PACクライアントを初期化
  client.pacClient = newProxyAutoConfigClient("", logger = clientLogger)
  
  # カスタムヘッダーを設定
  httpClient.headers = newHttpHeaders({
    "User-Agent": client.userAgent,
    "Accept": "application/javascript, application/x-javascript, application/x-ns-proxy-autoconfig, */*"
  })
  
  return client

proc detectDhcp*(client: WpadClient): Future[Option[string]] {.async.} =
  ## DHCPを使用してWPAD URLを検出する
  ##
  ## 戻り値:
  ##   成功した場合はPAC URLを含むOption、失敗した場合はnone
  
  client.logger.info("Attempting DHCP-based WPAD detection")
  
  when defined(windows):
    # Windows環境での実装
    # WinAPIを使用してDHCPオプション252（Proxy Auto Config）を取得
    client.logger.debug("Windows DHCP WPAD detection started")
    try:
      # WinHTTP APIを使用してWPAD URLを取得
      const winHttpDll = "winhttp.dll"
      type
        WINHTTP_AUTOPROXY_OPTIONS = object
          dwFlags: DWORD
          dwAutoDetectFlags: DWORD
          lpszAutoConfigUrl: LPCWSTR
          lpvReserved: pointer
          dwReserved: DWORD
          fAutoLogonIfChallenged: BOOL
        
        WINHTTP_PROXY_INFO = object
          dwAccessType: DWORD
          lpszProxy: LPWSTR
          lpszProxyBypass: LPWSTR
      
      const
        WINHTTP_AUTO_DETECT_TYPE_DHCP = 0x00000001
        WINHTTP_AUTOPROXY_AUTO_DETECT = 0x00000001
      
      # DLLをロード
      let winHttpLib = loadLib(winHttpDll)
      if winHttpLib == nil:
        client.logger.warn("Failed to load winhttp.dll")
        return none(string)
      
      # 関数ポインタを取得
      let winHttpGetProxyForUrl = cast[proc(hSession: HINTERNET, lpcwszUrl: LPCWSTR, 
                                          pAutoProxyOptions: ptr WINHTTP_AUTOPROXY_OPTIONS,
                                          pProxyInfo: ptr WINHTTP_PROXY_INFO): BOOL {.stdcall.}](
                                          symAddr(winHttpLib, "WinHttpGetProxyForUrl"))
      
      let winHttpOpen = cast[proc(lpszAgent: LPCWSTR, dwAccessType: DWORD, 
                                lpszProxy: LPCWSTR, lpszProxyBypass: LPCWSTR, 
                                dwFlags: DWORD): HINTERNET {.stdcall.}](
                                symAddr(winHttpLib, "WinHttpOpen"))
      
      let winHttpCloseHandle = cast[proc(hInternet: HINTERNET): BOOL {.stdcall.}](
                                symAddr(winHttpLib, "WinHttpCloseHandle"))
      
      if winHttpGetProxyForUrl == nil or winHttpOpen == nil or winHttpCloseHandle == nil:
        client.logger.warn("Failed to get WinHTTP function pointers")
        unloadLib(winHttpLib)
        return none(string)
      
      # WinHTTPセッションを開く
      let hSession = winHttpOpen(newWideCString(client.userAgent), 0, nil, nil, 0)
      if hSession == nil:
        client.logger.warn("Failed to open WinHTTP session")
        unloadLib(winHttpLib)
        return none(string)
      
      # 自動検出オプションを設定
      var autoProxyOptions = WINHTTP_AUTOPROXY_OPTIONS(
        dwFlags: WINHTTP_AUTOPROXY_AUTO_DETECT,
        dwAutoDetectFlags: WINHTTP_AUTO_DETECT_TYPE_DHCP,
        lpszAutoConfigUrl: nil,
        lpvReserved: nil,
        dwReserved: 0,
        fAutoLogonIfChallenged: 0
      )
      
      var proxyInfo = WINHTTP_PROXY_INFO()
      
      # テスト用URL（実際のURLは関係ない、DHCPベースの検出のため）
      let testUrl = newWideCString("http://example.com")
      
      # プロキシ情報を取得
      let result = winHttpGetProxyForUrl(hSession, testUrl, addr autoProxyOptions, addr proxyInfo)
      
      # リソースを解放
      winHttpCloseHandle(hSession)
      unloadLib(winHttpLib)
      
      if result != 0:
        # 成功した場合、PACのURLを返す
        if proxyInfo.lpszProxy != nil:
          let pacUrl = $proxyInfo.lpszProxy
          client.logger.info(fmt"Found WPAD URL from Windows DHCP: {pacUrl}")
          return some(pacUrl)
      
      client.logger.debug("No WPAD URL found via Windows DHCP")
      return none(string)
    except:
      let errMsg = getCurrentExceptionMsg()
      client.logger.warn(fmt"Error in Windows DHCP detection: {errMsg}")
      return none(string)
  
  when defined(linux):
    # Linux環境での実装
    # DHCPクライアントのリース情報ファイルやDBを読み取り
    try:
      # dhclientのリースファイルからオプション252を探す
      let dhcpLeasesDir = "/var/lib/dhcp/"
      let dhcpLeasesFiles = ["dhclient.leases", "dhclient-*.leases"]
      
      for filePattern in dhcpLeasesFiles:
        for leaseFile in walkFiles(dhcpLeasesDir & filePattern):
          client.logger.debug(fmt"Checking DHCP lease file: {leaseFile}")
          
          if fileExists(leaseFile):
            # リースファイルを読み込み、option 252を検索
            let content = readFile(leaseFile)
            let optionRegex = re"option\s+wpad\s+\"([^\"]+)\"|\boption\s+252\s+\"([^\"]+)\""
            var matches: array[2, string]
            
            if content.find(optionRegex, matches):
              let wpadUrl = if matches[0].len > 0: matches[0] else: matches[1]
              if wpadUrl.len > 0:
                client.logger.info(fmt"Found WPAD URL from DHCP: {wpadUrl}")
                return some(wpadUrl)
      
      # dhcpcdの設定ファイルを確認
      let dhcpcdLeasesDir = "/var/lib/dhcpcd/"
      for leaseFile in walkFiles(dhcpcdLeasesDir & "*.lease"):
        client.logger.debug(fmt"Checking dhcpcd lease file: {leaseFile}")
        
        if fileExists(leaseFile):
          let content = readFile(leaseFile)
          let optionRegex = re"wpad=([^\n]+)|\boption 252 ([^\n]+)"
          var matches: array[2, string]
          
          if content.find(optionRegex, matches):
            let wpadUrl = if matches[0].len > 0: matches[0] else: matches[1]
            if wpadUrl.len > 0:
              client.logger.info(fmt"Found WPAD URL from dhcpcd: {wpadUrl}")
              return some(wpadUrl)
      
      # systemd-networkdのDHCPリース情報を確認
      let systemdNetworkDir = "/run/systemd/netif/leases/"
      for leaseFile in walkFiles(systemdNetworkDir & "*.lease"):
        client.logger.debug(fmt"Checking systemd-networkd lease file: {leaseFile}")
        
        if fileExists(leaseFile):
          let content = readFile(leaseFile)
          let optionRegex = re"WPAD=([^\n]+)|\bOPTION_252=([^\n]+)"
          var matches: array[2, string]
          
          if content.find(optionRegex, matches):
            let wpadUrl = if matches[0].len > 0: matches[0] else: matches[1]
            if wpadUrl.len > 0:
              client.logger.info(fmt"Found WPAD URL from systemd-networkd: {wpadUrl}")
              return some(wpadUrl)
              
      # NetworkManagerのDHCPリース情報を確認
      let nmLeasesDir = "/var/lib/NetworkManager/"
      for leaseFile in walkFiles(nmLeasesDir & "*.lease"):
        if fileExists(leaseFile):
          let content = readFile(leaseFile)
          # NetworkManagerのリース形式に合わせたパターンを使用
          let optionRegex = re"WPAD_URL=([^\n]+)|\bDHCP4_OPTION_WPAD=([^\n]+)|\bDHCP4_OPTION_252=([^\n]+)"
          var matches: array[3, string]
          
          if content.find(optionRegex, matches):
            let wpadUrl = if matches[0].len > 0: matches[0] else: 
                          if matches[1].len > 0: matches[1] else: matches[2]
            if wpadUrl.len > 0:
              client.logger.info(fmt"Found WPAD URL from NetworkManager: {wpadUrl}")
              return some(wpadUrl)
      
      # dnsmasqのDHCPリース情報を確認
      let dnsmasqLeasesFile = "/var/lib/misc/dnsmasq.leases"
      if fileExists(dnsmasqLeasesFile):
        client.logger.debug(fmt"Checking dnsmasq lease file: {dnsmasqLeasesFile}")
        let content = readFile(dnsmasqLeasesFile)
        let optionRegex = re"tag:wpad,([^\s]+)|\btag:option252,([^\s]+)"
        var matches: array[2, string]
        
        if content.find(optionRegex, matches):
          let wpadUrl = if matches[0].len > 0: matches[0] else: matches[1]
          if wpadUrl.len > 0:
            client.logger.info(fmt"Found WPAD URL from dnsmasq: {wpadUrl}")
            return some(wpadUrl)
      
      # dhcpdumpを使用して直接DHCPパケットを解析（root権限が必要）
      if execCmd("which dhcpdump > /dev/null") == 0:
        try:
          # 利用可能なネットワークインターフェースを取得
          let interfaces = execProcess("ip link show | grep -v lo | grep -o '^[0-9]\\+: [^:]*' | cut -d' ' -f2").strip().splitLines()
          
          for iface in interfaces:
            if iface.len == 0:
              continue
              
            client.logger.debug(fmt"Attempting to capture DHCP packets on interface: {iface}")
            
            # 非同期でdhcpdumpを実行（タイムアウト付き）
            let dhcpDumpFuture = execProcessAsync(fmt"timeout 3 dhcpdump -i {iface} | grep -m 1 'Option 252'")
            let dhcpDumpResult = await dhcpDumpFuture
            
            if dhcpDumpResult.len > 0:
              let optionRegex = re"Option 252: \"([^\"]+)\""
              var matches: array[1, string]
              
              if dhcpDumpResult.find(optionRegex, matches):
                let wpadUrl = matches[0]
                if wpadUrl.len > 0:
                  client.logger.info(fmt"Found WPAD URL from dhcpdump: {wpadUrl}")
                  return some(wpadUrl)
        except:
          let errMsg = getCurrentExceptionMsg()
          client.logger.debug(fmt"Error in dhcpdump capture: {errMsg}")
      
      client.logger.debug("No WPAD URL found in DHCP lease files")
      return none(string)
    except:
      let errMsg = getCurrentExceptionMsg()
      client.logger.warn(fmt"Error in DHCP detection: {errMsg}")
      return none(string)
  
  when defined(macosx):
    # macOS環境での実装
    try:
      # macOSでは`ipconfig getpacket <interface>`コマンドを使って
      # DHCPからの情報を取得できる
      
      # 利用可能なネットワークインターフェースを取得
      let interfaces = execProcess("networksetup -listallhardwareports | grep Device | cut -d: -f2").strip().splitLines()
      
      for iface in interfaces:
        let ifaceName = iface.strip()
        if ifaceName.len == 0:
          continue
        
        client.logger.debug(fmt"Checking DHCP packet for interface: {ifaceName}")
        
        let output = execProcess(fmt"ipconfig getpacket {ifaceName}")
        
        # オプション252（WPAD）またはオプション72（WWW Server）を検索
        let optionRegex = re"(option_252|option_72|wpad_url)=([^\n]+)"
        var matches: array[2, string]
        
        if output.find(optionRegex, matches):
          let wpadUrl = matches[1].strip()
          if wpadUrl.len > 0:
            client.logger.info(fmt"Found WPAD URL from macOS DHCP: {wpadUrl}")
            return some(wpadUrl)
      
      # scutilコマンドを使用してDHCP情報を取得（代替方法）
      let scutilOutput = execProcess("scutil --dns")
      let scutilRegex = re"WPAD URL\s*:\s*([^\n]+)"
      var scutilMatches: array[1, string]
      
      if scutilOutput.find(scutilRegex, scutilMatches):
        let wpadUrl = scutilMatches[0].strip()
        if wpadUrl.len > 0:
          client.logger.info(fmt"Found WPAD URL from scutil: {wpadUrl}")
          return some(wpadUrl)
      
      # defaults読み取りを使用してシステム設定からプロキシ自動設定URLを取得
      let defaultsOutput = execProcess("defaults read /Library/Preferences/SystemConfiguration/preferences.plist")
      let defaultsRegex = re"ProxyAutoConfigURLString\s*=\s*\"([^\"]+)\""
      var defaultsMatches: array[1, string]
      
      if defaultsOutput.find(defaultsRegex, defaultsMatches):
        let wpadUrl = defaultsMatches[0].strip()
        if wpadUrl.len > 0:
          client.logger.info(fmt"Found WPAD URL from system preferences: {wpadUrl}")
          return some(wpadUrl)
      
      client.logger.debug("No WPAD URL found in macOS DHCP")
      return none(string)
    except:
      let errMsg = getCurrentExceptionMsg()
      client.logger.warn(fmt"Error in macOS DHCP detection: {errMsg}")
      return none(string)
  
  when defined(freebsd) or defined(openbsd) or defined(netbsd):
    # BSD系OSでの実装
    try:
      # dhclientのリースファイルを確認
      let dhcpLeasesDir = "/var/db/dhclient/"
      for leaseFile in walkFiles(dhcpLeasesDir & "*.lease*"):
        client.logger.debug(fmt"Checking BSD DHCP lease file: {leaseFile}")
        
        if fileExists(leaseFile):
          let content = readFile(leaseFile)
          let optionRegex = re"option wpad \"([^\"]+)\"|\boption 252 \"([^\"]+)\""
          var matches: array[2, string]
          
          if content.find(optionRegex, matches):
            let wpadUrl = if matches[0].len > 0: matches[0] else: matches[1]
            if wpadUrl.len > 0:
              client.logger.info(fmt"Found WPAD URL from BSD DHCP: {wpadUrl}")
              return some(wpadUrl)
      
      # bpfを使用してDHCPパケットを直接キャプチャする方法も可能だが、
      # 権限の問題があるため、ここでは実装しない
      
      client.logger.debug("No WPAD URL found in BSD DHCP lease files")
      return none(string)
    except:
      let errMsg = getCurrentExceptionMsg()
      client.logger.warn(fmt"Error in BSD DHCP detection: {errMsg}")
      return none(string)
  
  # サポートされていないプラットフォーム
  client.logger.warn("DHCP-based WPAD detection not supported on this platform")
  return none(string)

proc getDomainComponents(hostname: string): seq[string] =
  ## ホスト名からドメイン部分を取得する
  ##
  ## 引数:
  ##   hostname: ホスト名（例: pc1.dept.example.co.jp）
  ##
  ## 戻り値:
  ##   ドメインコンポーネントのシーケンス（例: ["co.jp", "example.co.jp", "dept.example.co.jp"]）
  
  result = @[]
  let parts = hostname.split('.')
  
  if parts.len <= 1:
    return result
  
  # ドメイン部分のみを取得（ホスト名を除く）
  let domainParts = parts[1..^1]
  
  # ドメインの各レベルを階層的に構築
  var currentDomain = ""
  for i in countdown(domainParts.len - 1, 0):
    if currentDomain.len > 0:
      currentDomain = domainParts[i] & "." & currentDomain
    else:
      currentDomain = domainParts[i]
    result.add(currentDomain)

proc generateWpadUrls*(domain: string): seq[string] =
  ## ドメインからWPAD URLの候補を生成する
  ##
  ## 引数:
  ##   domain: ドメイン名（例: example.com）
  ##
  ## 戻り値:
  ##   WPAD URLの候補リスト
  
  result = @[]
  
  # 標準的なWPAD URLの候補を生成
  result.add(fmt"http://wpad.{domain}/wpad.dat")
  
  # 代替パスの候補（順序は重要性に基づく）
  let alternativePaths = @[
    "/proxy.pac", 
    "/wpad.pac", 
    "/wpad.da",
    "/proxy.da",
    "/pac/wpad.dat", 
    "/pac/proxy.pac",
    "/autodiscover/proxy.pac",
    "/auto/wpad.dat"
  ]
  
  for path in alternativePaths:
    result.add(fmt"http://wpad.{domain}{path}")
  
  # 同じドメインの非WPADホスト名も試す
  # 企業環境ではプロキシサーバー名や構成サーバー名が使われることが多い
  let alternativeHosts = @[
    "proxy", 
    "autoconfig",
    "autoproxy",
    "pac",
    "config"
  ]
  
  for host in alternativeHosts:
    result.add(fmt"http://{host}.{domain}/wpad.dat")
    for path in alternativePaths:
      result.add(fmt"http://{host}.{domain}{path}")
  
  # HTTPSの候補も追加
  result.add(fmt"https://wpad.{domain}/wpad.dat")
  for host in alternativeHosts:
    result.add(fmt"https://{host}.{domain}/wpad.dat")

proc parseChunkedBody(client: WpadClient, chunkedBody: string): string =
  ## チャンク転送エンコーディングされたボディを解析する
  ##
  ## 引数:
  ##   chunkedBody: チャンク転送エンコーディングされたボディ
  ##
  ## 戻り値:
  ##   デコードされたボディ
  
  result = ""
  var pos = 0
  
  while pos < chunkedBody.len:
    # チャンクサイズを読み取る
    var chunkSizeEnd = chunkedBody.find("\r\n", pos)
    if chunkSizeEnd < 0:
      client.logger.error("Invalid chunked encoding: no CRLF after chunk size")
      break
    
    var chunkSizeHex = chunkedBody[pos ..< chunkSizeEnd].strip()
    # チャンクサイズ行には拡張（chunk-ext）が含まれることがある
    if ";" in chunkSizeHex:
      chunkSizeHex = chunkSizeHex.split(";")[0].strip()
    
    # 16進数からサイズに変換
    var chunkSize: int
    try:
      chunkSize = parseHexInt(chunkSizeHex)
    except:
      client.logger.error(fmt"Invalid chunk size: {chunkSizeHex}")
      break
    
    # チャンクサイズが0ならデータ終了
    if chunkSize == 0:
      break
    
    # データの開始位置
    let dataStart = chunkSizeEnd + 2
    if dataStart + chunkSize > chunkedBody.len:
      client.logger.error("Incomplete chunk data")
      break
    
    # チャンクデータを結果に追加
    let chunkData = chunkedBody[dataStart ..< dataStart + chunkSize]
    result.add(chunkData)
    
    # 次のチャンクの位置に移動（CRLF分を飛ばす）
    pos = dataStart + chunkSize + 2
  
  return result

proc testWpadUrl*(client: WpadClient, url: string): Future[bool] {.async.} =
  ## WPAD URLが有効かテストする
  ##
  ## 引数:
  ##   url: テストするWPAD URL
  ##
  ## 戻り値:
  ##   URLが有効な場合はtrue、それ以外はfalse
  
  client.logger.debug(fmt"Testing WPAD URL: {url}")
  
  # 再試行カウンタ
  var retryCount = 0
  var success = false
  
  while not success and retryCount <= client.maxRetries:
    if retryCount > 0:
      client.logger.debug(fmt"Retry #{retryCount} for URL: {url}")
    
    try:
      # タイムアウト設定
      client.httpClient.timeout = client.timeout
      
      # リダイレクトを手動で処理するため、自動リダイレクトは無効化
      let oldRedirect = client.httpClient.maxRedirects
      client.httpClient.maxRedirects = 0
      
      # リダイレクトを手動で追跡
      var currentUrl = url
      var redirectCount = 0
      var finalResponse: Response = nil
      
      while redirectCount < MaxRedirects:
        client.logger.debug(fmt"Requesting: {currentUrl}")
        let response = await client.httpClient.getAsync(currentUrl)
        
        # 成功または最終応答
        if response.code == Http200:
          finalResponse = response
          break
        
        # リダイレクトを処理
        if response.code in {Http301, Http302, Http307, Http308}:
          if not response.headers.hasKey("location"):
            client.logger.warn(fmt"Redirect without Location header from: {currentUrl}")
            break
          
          let location = response.headers["location"]
          var nextUrl = location
          
          # 相対URLを処理
          if not (location.startsWith("http://") or location.startsWith("https://")):
            let baseUri = parseUri(currentUrl)
            let locationUri = parseUri(location)
            nextUrl = $baseUri.combine(locationUri)
          
          client.logger.debug(fmt"Redirected from {currentUrl} to {nextUrl}")
          currentUrl = nextUrl
          redirectCount += 1
        else:
          # 成功でもリダイレクトでもない場合は終了
          client.logger.debug(fmt"Non-success status code: {response.code}")
          break
      
      # 元のリダイレクト設定を復元
      client.httpClient.maxRedirects = oldRedirect
      
      # 応答がない場合はエラー
      if finalResponse.isNil:
        client.logger.debug(fmt"No valid response from {url}")
        retryCount += 1
        await sleepAsync(retryCount * 500) # バックオフ遅延
        continue
      
      # Content-Typeのチェック
      let contentType = finalResponse.headers.getOrDefault("content-type").toLowerAscii()
      let validTypes = ["application/x-javascript", "application/x-ns-proxy-autoconfig", 
                       "text/javascript", "text/plain", "application/javascript"]
      
      var isValidType = false
      for vtype in validTypes:
        if contentType.contains(vtype):
          isValidType = true
          break
      
      if not isValidType:
        client.logger.debug(fmt"Invalid content type: {contentType} for URL: {currentUrl}")
        retryCount += 1
        await sleepAsync(retryCount * 500) # バックオフ遅延
        continue
      
      # レスポンスボディの取得
      var content = finalResponse.body
      
      # チャンク転送エンコーディングの処理
      let transferEncoding = finalResponse.headers.getOrDefault("transfer-encoding").toLowerAscii()
      if transferEncoding.contains("chunked"):
        client.logger.debug("Processing chunked transfer encoding")
        content = client.parseChunkedBody(content)
      
      # 最低限のPAC構文チェック
      if not content.contains("FindProxyForURL") or not content.contains("function"):
        client.logger.debug("Content doesn't contain PAC functions")
        retryCount += 1
        await sleepAsync(retryCount * 500) # バックオフ遅延
        continue
      
      # スクリプトがJavaScriptとして構文的に有効かを簡易チェック
      if content.contains("<<<") or content.contains(">>>") or content.contains("}{"):
        client.logger.debug("Content contains invalid JavaScript syntax")
        retryCount += 1
        await sleepAsync(retryCount * 500) # バックオフ遅延
        continue
      
      # 有効なPAC URLと確認
      client.logger.info(fmt"Valid WPAD URL found: {currentUrl}")
      client.foundUrl = currentUrl
      
      # PACクライアントのURLを更新
      client.pacClient.context.url = currentUrl
      
      # スクリプト内容も設定
      client.pacClient.context.script = content
      client.pacClient.context.lastUpdated = getTime()
      client.pacClient.context.isValid = true
      
      success = true
      return true
      
    except:
      let errMsg = getCurrentExceptionMsg()
      client.logger.debug(fmt"Error testing WPAD URL {url}: {errMsg}")
      retryCount += 1
      await sleepAsync(retryCount * 500) # バックオフ遅延
  
  return false

proc detectDns*(client: WpadClient): Future[Option[string]] {.async.} =
  ## DNSを使用してWPAD URLを検出する
  ##
  ## 戻り値:
  ##   成功した場合はPAC URLを含むOption、失敗した場合はnone
  
  client.logger.info("Attempting DNS-based WPAD detection")
  
  try:
    # 現在のホスト名とドメインを取得
    let hostname = getHostname()
    client.logger.debug(fmt"Current hostname: {hostname}")
    
    # 構成済みのネットワークインターフェースを取得
    var domains: seq[string] = @[]
    
    # ホスト名からドメイン部分を抽出
    let domainComponents = getDomainComponents(hostname)
    domains.extend(domainComponents)
    
    # DNS検索ドメインの設定を取得
    when defined(windows):
      # Windows実装：レジストリからサーチドメインを取得
      try:
        # WinAPIを使用して検索ドメインを取得
        # 例: NetGetJoinInformationやDnsQueryConfigなどを使う
        client.logger.debug("Windows DNS search domain detection not fully implemented")
        
        # 代替手段としてipconfig /all の出力から検索ドメインを抽出
        let output = execProcess("ipconfig /all")
        let dnsRegex = re"DNS Suffix Search List[^\n]+\n((?:[ \t]+[^\n]+\n)+)"
        var matches: array[1, string]
        
        if output.find(dnsRegex, matches):
          let domainsList = matches[0].strip()
          for line in domainsList.splitLines():
            let domain = line.strip()
            if domain.len > 0:
              domains.add(domain)
      except:
        let errMsg = getCurrentExceptionMsg()
        client.logger.warn(fmt"Error reading Windows DNS search domains: {errMsg}")
    
    elif defined(linux):
      # Linux実装：/etc/resolv.confからサーチドメインを取得
      try:
        let resolvConfPath = "/etc/resolv.conf"
        if fileExists(resolvConfPath):
          for line in lines(resolvConfPath):
            let trimmedLine = line.strip()
            if trimmedLine.startsWith("search "):
              let searchDomains = trimmedLine[7..^1].strip().split()
              domains.extend(searchDomains)
            elif trimmedLine.startsWith("domain "):
              let domain = trimmedLine[7..^1].strip()
              if domain.len > 0:
                domains.add(domain)
        
        # NetworkManagerの追加検索ドメインも確認
        let nmDir = "/etc/NetworkManager/system-connections/"
        if dirExists(nmDir):
          for file in walkFiles(nmDir & "/*.nmconnection"):
            if fileExists(file):
              let content = readFile(file)
              let domainRegex = re"dns-search=([^;]+)"
              var matches: array[1, string]
              
              if content.find(domainRegex, matches):
                let searchDomains = matches[0].strip().split(";")
                domains.extend(searchDomains)
      except:
        let errMsg = getCurrentExceptionMsg()
        client.logger.warn(fmt"Error reading DNS search domains: {errMsg}")
    
    elif defined(macosx):
      # macOS実装：scutil --dns で検索ドメインを取得
      try:
        let output = execProcess("scutil --dns")
        let searchRegex = re"search domain\[(\d+)\] : ([^\n]+)"
        var pos = 0
        var matches: array[2, string]
        
        while true:
          pos = output.find(searchRegex, matches, pos)
          if pos < 0:
            break
          
          let domain = matches[1].strip()
          if domain.len > 0:
            domains.add(domain)
          
          pos += 1
      except:
        let errMsg = getCurrentExceptionMsg()
        client.logger.warn(fmt"Error reading macOS DNS search domains: {errMsg}")
    
    # 重複を削除
    domains = deduplicate(domains)
    
    client.logger.debug(fmt"DNS domains for WPAD detection: {domains}")
    
    # ドメインごとにWPAD URLを生成してテスト
    for domain in domains:
      if domain.len == 0:
        continue
      
      let wpadUrls = generateWpadUrls(domain)
      
      # 各URLをランダムな順序でテスト（負荷分散のため）
      var urlsToTest = wpadUrls
      randomize()
      shuffle(urlsToTest)
      
      for wpadUrl in urlsToTest:
        if await client.testWpadUrl(wpadUrl):
          return some(wpadUrl)
    
    # 特別なケース：ローカルホストのWPADをテスト
    let localUrls = @[
      "http://wpad/wpad.dat",
      "http://localhost/wpad.dat",
      "http://127.0.0.1/wpad.dat"
    ]
    
    for localUrl in localUrls:
      if await client.testWpadUrl(localUrl):
        return some(localUrl)
    
    client.logger.info("No valid WPAD URL found via DNS")
    return none(string)
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.warn(fmt"Error in DNS-based WPAD detection: {errMsg}")
    return none(string)

proc detect*(client: WpadClient): Future[bool] {.async.} =
  ## WPAD URLを検出する
  ##
  ## 戻り値:
  ##   検出に成功した場合はtrue、失敗した場合はfalse
  
  client.logger.info("Starting WPAD detection")
  
  # 各検出方法を順番に試す
  for method in client.discoveryMethods:
    case method
    of wdmDhcp:
      client.logger.info("Trying DHCP-based WPAD detection")
      let dhcpResult = await client.detectDhcp()
      if dhcpResult.isSome:
        client.foundUrl = dhcpResult.get()
        client.pacClient.context.url = client.foundUrl
        client.logger.info(fmt"WPAD URL found via DHCP: {client.foundUrl}")
        
        # PACファイルを取得して検証
        let pacResult = await client.pacClient.fetchPacFile()
        if pacResult:
          client.logger.info("Successfully loaded PAC file")
          return true
        else:
          client.logger.warn("Failed to load PAC file from DHCP-provided URL")
    
    of wdmDns:
      client.logger.info("Trying DNS-based WPAD detection")
      let dnsResult = await client.detectDns()
      if dnsResult.isSome:
        client.foundUrl = dnsResult.get()
        client.pacClient.context.url = client.foundUrl
        client.logger.info(fmt"WPAD URL found via DNS: {client.foundUrl}")
        return true
  
  client.logger.warn("WPAD detection failed")
  return false

proc close*(client: WpadClient) =
  ## WPADクライアントを閉じる
  
  try:
    if not client.httpClient.isNil:
      client.httpClient.close()
    
    if not client.pacClient.isNil:
      client.pacClient.close()
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.warn(fmt"Error closing WPAD client: {errMsg}")
  
  client.logger.info("WPAD client closed") 