## プロキシ自動設定(PAC)ファイル処理
##
## プロキシ自動設定(PAC)ファイルの解析、実行、および管理を行います。
## JavaScript関数の実行には組み込みの簡易JavaScriptエンジンを使用します。

import std/[asyncdispatch, httpclient, json, options, os, re, strformat, strutils, times, uri]
import ../../../core/logging/logger
import ../../http/client/http_client
import ../http/http_proxy_types
import ../socks/socks_types

type
  PacContext* = ref object
    ## PAC実行コンテキスト
    script*: string                   # PACスクリプト内容
    url*: string                      # PACファイルURL
    lastUpdated*: Time                # 最終更新時間
    lastError*: string                # 最後のエラーメッセージ
    cacheExpiry*: Time                # キャッシュ有効期限
    isValid*: bool                    # スクリプトが有効かどうか
    logger: Logger                    # ロガー
    pacFunctions: seq[string]         # PACで定義されている関数名リスト

  ProxyAutoConfigClient* = ref object
    ## プロキシ自動設定クライアント
    context*: PacContext              # PAC実行コンテキスト
    updateInterval*: int              # 更新間隔（秒）
    cacheTime*: int                   # キャッシュ有効時間（秒）
    lastProxies*: Table[string, string]  # 最後に決定されたプロキシ（URL→プロキシ）
    logger: Logger                    # ロガー
    httpClient: HttpClient            # HTTPクライアント
    useSystemPac*: bool               # システムPACを使用するかどうか
    systemPacUrl*: string             # システムPAC URL

const
  DefaultUpdateInterval = 60 * 60     # デフォルト更新間隔（1時間）
  DefaultCacheTime = 5 * 60           # デフォルトキャッシュ時間（5分）

const PacHelperFunctions = """
// PAC標準関数の定義

// クライアントのIPアドレスを返す
function myIpAddress() {
  return "127.0.0.1";
}

// DNSでホスト名を解決した結果のIPアドレスを返す
function dnsResolve(host) {
  // 実際のDNS解決を行う（実装はネイティブコードで行われる）
  if (host === "localhost") return "127.0.0.1";
  return null; // 実際の実装では適切なIPアドレスを返す
}

// 与えられたホストがIPアドレスパターンとマスクの範囲内かどうかを判定
function isInNet(host, pattern, mask) {
  // IPアドレスがパターンとマスクで指定された範囲内にあるかチェック
  // 例: isInNet("192.168.1.1", "192.168.1.0", "255.255.255.0")
  var hostIP = dnsResolve(host);
  if (!hostIP) return false;
  
  // IPアドレスを数値に変換して比較（簡易実装）
  var hostParts = hostIP.split(".");
  var patternParts = pattern.split(".");
  var maskParts = mask.split(".");
  
  for (var i = 0; i < 4; i++) {
    if ((hostParts[i] & maskParts[i]) !== (patternParts[i] & maskParts[i])) {
      return false;
    }
  }
  return true;
}

// 与えられたパターンがホストとマッチするかどうかを判定
function shExpMatch(host, pattern) {
  // シェルワイルドカードパターンマッチング
  // * は0文字以上の任意の文字列、? は任意の1文字
  pattern = pattern.replace(/\./g, "\\.");
  pattern = pattern.replace(/\*/g, ".*");
  pattern = pattern.replace(/\?/g, ".");
  var regex = new RegExp("^" + pattern + "$", "i"); // 大文字小文字を区別しない
  return regex.test(host);
}

// ドットを含まないホスト名かどうかを判定（ローカルホスト判定に使用）
function isPlainHostName(host) {
  return (host.indexOf(".") === -1);
}

// 与えられたホストが指定されたドメインに含まれるかどうかを判定
function dnsDomainIs(host, domain) {
  // ホストがドメインで終わるかどうかをチェック
  // 例: dnsDomainIs("www.example.com", "example.com") => true
  if (!host || !domain) return false;
  return (host.length >= domain.length &&
          host.toLowerCase().substring(host.length - domain.length) === domain.toLowerCase());
}

// 週末かどうかを判定
function weekdayRange(wd1, wd2, gmt) {
  var useGMT = (arguments.length > 2);
  var date = new Date();
  if (useGMT) date = new Date(date.getTime() + date.getTimezoneOffset() * 60000);
  
  var days = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"];
  var today = days[date.getDay()];
  
  if (wd2) {
    // 範囲指定の場合
    var wd1Index = days.indexOf(wd1.toUpperCase());
    var wd2Index = days.indexOf(wd2.toUpperCase());
    var todayIndex = days.indexOf(today);
    
    if (wd1Index <= wd2Index) {
      // 通常の範囲（例: MON-FRI）
      return (wd1Index <= todayIndex && todayIndex <= wd2Index);
    } else {
      // 週をまたぐ範囲（例: SAT-TUE）
      return (wd1Index <= todayIndex || todayIndex <= wd2Index);
    }
  } else {
    // 単一日指定の場合
    return (wd1.toUpperCase() === today);
  }
}

// 日付範囲内かどうかを判定
function dateRange() {
  var date = new Date();
  var useGMT = false;
  
  // 引数の解析
  var argc = arguments.length;
  if (argc > 1 && arguments[argc-1] === "GMT") {
    useGMT = true;
    argc--;
  }
  
  if (useGMT) date = new Date(date.getTime() + date.getTimezoneOffset() * 60000);
  
  var currentYear = date.getFullYear();
  var currentMonth = date.getMonth() + 1; // 0-11から1-12へ
  var currentDate = date.getDate();
  
  // 引数の数によって処理を分岐
  if (argc === 1) {
    // 単一日付または月指定
    var value = parseInt(arguments[0]);
    if (isNaN(value)) {
      // 月名指定（例: "JAN"）
      var months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];
      return months.indexOf(arguments[0].toUpperCase()) + 1 === currentMonth;
    } else if (value <= 31) {
      // 日付指定
      return value === currentDate;
    } else {
      // 年指定
      return value === currentYear;
    }
  } else if (argc === 2) {
    // 範囲指定
    var from = arguments[0];
    var to = arguments[1];
    
    // 月名指定の場合
    if (isNaN(parseInt(from))) {
      var months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"];
      var fromIndex = months.indexOf(from.toUpperCase()) + 1;
      var toIndex = months.indexOf(to.toUpperCase()) + 1;
      
      if (fromIndex <= toIndex) {
        return (fromIndex <= currentMonth && currentMonth <= toIndex);
      } else {
        return (fromIndex <= currentMonth || currentMonth <= toIndex);
      }
    } else {
      // 数値指定の場合
      var fromVal = parseInt(from);
      var toVal = parseInt(to);
      
      if (fromVal <= 31 && toVal <= 31) {
        // 日付範囲
        if (fromVal <= toVal) {
          return (fromVal <= currentDate && currentDate <= toVal);
        } else {
          return (fromVal <= currentDate || currentDate <= toVal);
        }
      } else {
        // 年範囲
        return (fromVal <= currentYear && currentYear <= toVal);
      }
    }
  }
  
  // その他の複雑なケース（年月日指定など）は省略
  return false;
}

// 時間範囲内かどうかを判定
function timeRange() {
  var date = new Date();
  var useGMT = false;
  
  // 引数の解析
  var argc = arguments.length;
  if (argc > 1 && arguments[argc-1] === "GMT") {
    useGMT = true;
    argc--;
  }
  
  if (useGMT) date = new Date(date.getTime() + date.getTimezoneOffset() * 60000);
  
  var currentHour = date.getHours();
  var currentMin = date.getMinutes();
  var currentSec = date.getSeconds();
  
  // 引数の数によって処理を分岐
  if (argc === 1) {
    // 時間のみ指定
    return parseInt(arguments[0]) === currentHour;
  } else if (argc === 2) {
    // 時間範囲指定
    var fromHour = parseInt(arguments[0]);
    var toHour = parseInt(arguments[1]);
    
    if (fromHour <= toHour) {
      return (fromHour <= currentHour && currentHour <= toHour);
    } else {
      return (fromHour <= currentHour || currentHour <= toHour);
    }
  } else if (argc === 4) {
    // 時分指定の範囲
    var fromHour = parseInt(arguments[0]);
    var fromMin = parseInt(arguments[1]);
    var toHour = parseInt(arguments[2]);
    var toMin = parseInt(arguments[3]);
    
    var fromTime = fromHour * 60 + fromMin;
    var toTime = toHour * 60 + toMin;
    var currentTime = currentHour * 60 + currentMin;
    
    if (fromTime <= toTime) {
      return (fromTime <= currentTime && currentTime <= toTime);
    } else {
      return (fromTime <= currentTime || currentTime <= toTime);
    }
  } else if (argc === 6) {
    // 時分秒指定の範囲
    var fromHour = parseInt(arguments[0]);
    var fromMin = parseInt(arguments[1]);
    var fromSec = parseInt(arguments[2]);
    var toHour = parseInt(arguments[3]);
    var toMin = parseInt(arguments[4]);
    var toSec = parseInt(arguments[5]);
    
    var fromTime = (fromHour * 60 + fromMin) * 60 + fromSec;
    var toTime = (toHour * 60 + toMin) * 60 + toSec;
    var currentTime = (currentHour * 60 + currentMin) * 60 + currentSec;
    
    if (fromTime <= toTime) {
      return (fromTime <= currentTime && currentTime <= toTime);
    } else {
      return (fromTime <= currentTime || currentTime <= toTime);
    }
  }
  
  return false;
}

// メインのFindProxyForURL関数が呼ばれる
"""

proc newPacContext*(script: string = "", url: string = "", logger: Logger = nil): PacContext =
  ## 新しいPAC実行コンテキストを作成する
  ##
  ## 引数:
  ##   script: PACスクリプト内容
  ##   url: PACファイルのURL
  ##   logger: ロガー
  ##
  ## 戻り値:
  ##   PacContextオブジェクト
  
  # ロガーを初期化
  let contextLogger = if logger.isNil: newLogger("PacContext") else: logger
  
  result = PacContext(
    script: script,
    url: url,
    lastUpdated: if script.len > 0: getTime() else: Time(),
    lastError: "",
    cacheExpiry: if script.len > 0: getTime() + initDuration(minutes = 5) else: Time(),
    isValid: script.len > 0,
    logger: contextLogger,
    pacFunctions: @[]
  )
  
  if script.len > 0:
    # PACスクリプトに含まれる関数名を抽出
    let funcRegex = re"function\s+([a-zA-Z0-9_]+)\s*\("
    var matches: array[1, string]
    var pos = 0
    while pos < script.len:
      pos = script.find(funcRegex, matches, pos)
      if pos < 0:
        break
      result.pacFunctions.add(matches[0])
      pos += 1
    
    result.logger.debug(fmt"Found PAC functions: {result.pacFunctions}")
    
    # FindProxyForURL関数が含まれているか確認
    if not ("FindProxyForURL" in result.pacFunctions):
      result.isValid = false
      result.lastError = "PAC file does not contain FindProxyForURL function"
      result.logger.error("PAC file does not contain required FindProxyForURL function")

proc newProxyAutoConfigClient*(pacUrl: string = "", 
                             updateInterval: int = DefaultUpdateInterval,
                             cacheTime: int = DefaultCacheTime,
                             logger: Logger = nil): ProxyAutoConfigClient =
  ## 新しいプロキシ自動設定クライアントを作成する
  ##
  ## 引数:
  ##   pacUrl: PACファイルのURL
  ##   updateInterval: 更新間隔（秒）
  ##   cacheTime: キャッシュ有効時間（秒）
  ##   logger: ロガー
  ##
  ## 戻り値:
  ##   ProxyAutoConfigClientオブジェクト
  
  # ロガーを初期化
  let clientLogger = if logger.isNil: newLogger("ProxyAutoConfigClient") else: logger
  
  result = ProxyAutoConfigClient(
    context: newPacContext("", pacUrl, clientLogger),
    updateInterval: updateInterval,
    cacheTime: cacheTime,
    lastProxies: initTable[string, string](),
    logger: clientLogger,
    httpClient: newHttpClient(),
    useSystemPac: false,
    systemPacUrl: ""
  )

proc detectSystemPac*(client: ProxyAutoConfigClient): Future[bool] {.async.} =
  ## システムのプロキシ自動設定を検出する
  ##
  ## 戻り値:
  ##   システムPACが検出された場合はtrue、それ以外はfalse
  
  client.logger.info("Detecting system proxy auto-config settings")
  
  # 環境変数からPAC URLを検出
  let autoConfigUrl = getEnv("AUTO_PROXY_URL")
  if autoConfigUrl.len > 0:
    client.systemPacUrl = autoConfigUrl
    client.useSystemPac = true
    client.logger.info(fmt"Found system PAC URL from environment: {autoConfigUrl}")
    return true
  
  # Windows環境での検出方法
  when defined(windows):
    try:
      # WinHTTPからAutoConfigURLを取得
      var buffer: array[1024, char]
      var bufferSize: DWORD = DWORD(buffer.len)
      var winHttpIEProxyConfig: WINHTTP_CURRENT_USER_IE_PROXY_CONFIG
      
      if WinHttpGetIEProxyConfigForCurrentUser(addr winHttpIEProxyConfig) != 0:
        if winHttpIEProxyConfig.lpszAutoConfigUrl != nil:
          client.systemPacUrl = $winHttpIEProxyConfig.lpszAutoConfigUrl
          client.useSystemPac = true
          client.logger.info(fmt"Found system PAC URL from Windows registry: {client.systemPacUrl}")
          
          # メモリ解放
          if winHttpIEProxyConfig.lpszAutoConfigUrl != nil:
            GlobalFree(winHttpIEProxyConfig.lpszAutoConfigUrl)
          if winHttpIEProxyConfig.lpszProxy != nil:
            GlobalFree(winHttpIEProxyConfig.lpszProxy)
          if winHttpIEProxyConfig.lpszProxyBypass != nil:
            GlobalFree(winHttpIEProxyConfig.lpszProxyBypass)
            
          return true
      
      # WinHTTPでAutoConfigURLが見つからない場合はWPADを試みる
      var winHttpAutoProxyOptions: WINHTTP_AUTOPROXY_OPTIONS
      var winHttpProxyInfo: WINHTTP_PROXY_INFO
      
      winHttpAutoProxyOptions.dwFlags = WINHTTP_AUTOPROXY_AUTO_DETECT
      winHttpAutoProxyOptions.dwAutoDetectFlags = WINHTTP_AUTO_DETECT_TYPE_DHCP or WINHTTP_AUTO_DETECT_TYPE_DNS_A
      winHttpAutoProxyOptions.lpszAutoConfigUrl = nil
      
      let hSession = WinHttpOpen(nil, WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0)
      if hSession != 0:
        if WinHttpGetProxyForUrl(hSession, "http://www.example.com", addr winHttpAutoProxyOptions, addr winHttpProxyInfo) != 0:
          if winHttpProxyInfo.lpszProxy != nil:
            client.systemPacUrl = "WPAD://detected"
            client.useSystemPac = true
            client.logger.info("Found system PAC via WPAD")
            
            # メモリ解放
            if winHttpProxyInfo.lpszProxy != nil:
              GlobalFree(winHttpProxyInfo.lpszProxy)
            if winHttpProxyInfo.lpszProxyBypass != nil:
              GlobalFree(winHttpProxyInfo.lpszProxyBypass)
              
            WinHttpCloseHandle(hSession)
            return true
        
        WinHttpCloseHandle(hSession)
    except:
      client.logger.warn(fmt"Error detecting Windows system PAC: {getCurrentExceptionMsg()}")
  
  # macOS環境での検出方法
  when defined(macosx):
    try:
      # SCDynamicStoreを使用してシステム設定からPAC URLを取得
      let store = SCDynamicStoreCreate(nil, "ProxyAutoConfigClient".cstring, nil, nil)
      if store != nil:
        let proxySettings = SCDynamicStoreCopyProxies(store)
        if proxySettings != nil:
          # ProxyAutoConfigURLキーの値を取得
          let pacUrlRef = CFDictionaryGetValue(proxySettings, CFSTR("ProxyAutoConfigURL"))
          if pacUrlRef != nil:
            var buffer: array[1024, char]
            if CFStringGetCString(CFStringRef(pacUrlRef), addr buffer[0], buffer.len.CFIndex, kCFStringEncodingUTF8) != 0:
              client.systemPacUrl = $buffer
              client.useSystemPac = true
              client.logger.info(fmt"Found system PAC URL from macOS settings: {client.systemPacUrl}")
              
              CFRelease(proxySettings)
              CFRelease(store)
              return true
          
          CFRelease(proxySettings)
        
        CFRelease(store)
    except:
      client.logger.warn(fmt"Error detecting macOS system PAC: {getCurrentExceptionMsg()}")
  
  # Linux環境での検出方法
  when defined(linux):
    try:
      # GNOMEの場合
      let (gnomeOutput, gnomeExitCode) = execCmdEx("gsettings get org.gnome.system.proxy autoconfig-url")
      if gnomeExitCode == 0 and gnomeOutput.len > 0:
        # 出力から引用符を削除
        var pacUrl = gnomeOutput.strip()
        if pacUrl.startsWith("'") and pacUrl.endsWith("'"):
          pacUrl = pacUrl[1..^2]
        
        if pacUrl != "" and pacUrl != "''":
          client.systemPacUrl = pacUrl
          client.useSystemPac = true
          client.logger.info(fmt"Found system PAC URL from GNOME settings: {client.systemPacUrl}")
          return true
      
      # KDEの場合
      let kdeConfigFile = getHomeDir() / ".config/kioslaverc"
      if fileExists(kdeConfigFile):
        let configContent = readFile(kdeConfigFile)
        let proxyTypeRegex = re"ProxyType=(\d+)"
        let pacUrlRegex = re"Proxy Config Script=(.+)"
        
        var proxyType = 0
        var matches: array[1, string]
        if configContent.find(proxyTypeRegex, matches):
          proxyType = parseInt(matches[0])
        
        # ProxyType=2はPACを意味する
        if proxyType == 2 and configContent.find(pacUrlRegex, matches):
          client.systemPacUrl = matches[0].strip()
          client.useSystemPac = true
          client.logger.info(fmt"Found system PAC URL from KDE settings: {client.systemPacUrl}")
          return true
      
      # NetworkManagerの設定を確認
      let nmcliCmd = "nmcli con show --active | awk '{print $1}' | head -1"
      let (activeConn, exitCode) = execCmdEx(nmcliCmd)
      if exitCode == 0 and activeConn.len > 0:
        let connName = activeConn.strip()
        let proxyCmd = fmt"nmcli con show '{connName}' | grep proxy.pac"
        let (proxyOutput, proxyExitCode) = execCmdEx(proxyCmd)
        
        if proxyExitCode == 0 and proxyOutput.len > 0:
          let pacUrlMatch = proxyOutput.find(re"proxy\.pac-url:\s+(.+)")
          if pacUrlMatch >= 0:
            let pacUrl = proxyOutput.split(":", 1)[1].strip()
            if pacUrl.len > 0:
              client.systemPacUrl = pacUrl
              client.useSystemPac = true
              client.logger.info(fmt"Found system PAC URL from NetworkManager: {client.systemPacUrl}")
              return true
    except:
      client.logger.warn(fmt"Error detecting Linux system PAC: {getCurrentExceptionMsg()}")
  
  client.logger.info("No system PAC configuration found")
  return false
  
  client.logger.info(fmt"Fetching PAC file from: {pacUrl}")
  
  # URLがファイルパスの場合
  if pacUrl.startsWith("file://"):
    let filePath = pacUrl.replace("file://", "")
    try:
      client.context.script = readFile(filePath)
      client.context.lastUpdated = getTime()
      client.context.cacheExpiry = getTime() + initDuration(seconds = client.cacheTime)
      client.context.isValid = true
      client.context.lastError = ""
      
      # PACスクリプト内の関数を検出
      var context = newPacContext(client.context.script, pacUrl, client.logger)
      client.context.pacFunctions = context.pacFunctions
      client.context.isValid = context.isValid
      
      if not client.context.isValid:
        client.context.lastError = context.lastError
        client.logger.error(fmt"Invalid PAC file: {context.lastError}")
        return false
      
      client.logger.info(fmt"Successfully loaded PAC file from: {pacUrl}")
      return true
    except:
      let errMsg = getCurrentExceptionMsg()
      client.context.lastError = fmt"Failed to read PAC file: {errMsg}"
      client.logger.error(client.context.lastError)
      return false
  
  # HTTP/HTTPS URLからダウンロード
  try:
    let response = await client.httpClient.getAsync(pacUrl)
    
    if response.code != Http200:
      client.context.lastError = fmt"HTTP error: {response.code}"
      client.logger.error(fmt"Failed to download PAC file: {client.context.lastError}")
      return false
    
    # Content-Typeをチェック（application/x-javascript, application/x-ns-proxy-autoconfig, text/plain など）
    let contentType = response.headers.getOrDefault("content-type").toLowerAscii()
    let validTypes = ["application/x-javascript", "application/x-ns-proxy-autoconfig", 
                     "text/javascript", "text/plain", "application/javascript"]
    
    var isValidType = false
    for vtype in validTypes:
      if contentType.contains(vtype):
        isValidType = true
        break
    
    if not isValidType:
      client.logger.warn(fmt"PAC file has unexpected content type: {contentType}")
    
    # PACスクリプトを取得
    client.context.script = response.body
    client.context.lastUpdated = getTime()
    client.context.cacheExpiry = getTime() + initDuration(seconds = client.cacheTime)
    
    # PACスクリプト内の関数を検出
    var context = newPacContext(client.context.script, pacUrl, client.logger)
    client.context.pacFunctions = context.pacFunctions
    client.context.isValid = context.isValid
    
    if not client.context.isValid:
      client.context.lastError = context.lastError
      client.logger.error(fmt"Invalid PAC file: {context.lastError}")
      return false
    
    client.logger.info(fmt"Successfully downloaded PAC file from: {pacUrl}")
    return true
  except:
    let errMsg = getCurrentExceptionMsg()
    client.context.lastError = fmt"Download error: {errMsg}"
    client.logger.error(fmt"Failed to download PAC file: {errMsg}")
    return false

proc parseProxyString*(proxyStr: string): tuple[mode: HttpProxyConnectionMode, host: string, port: int] =
  ## PACファイルから返されるプロキシ文字列を解析する
  ##
  ## 引数:
  ##   proxyStr: PACファイルから返されるプロキシ文字列
  ##
  ## 戻り値:
  ##   (モード, ホスト, ポート) のタプル
  
  # デフォルト値
  result = (mode: hpcmDirect, host: "", port: 0)
  
  if proxyStr.len == 0 or proxyStr == "DIRECT":
    return
  
  # PROXY, SOCKS, SOCKS5, HTTPS の形式を解析
  let parts = proxyStr.split(" ")
  if parts.len < 2:
    return
  
  let proxyType = parts[0].toUpperAscii()
  let hostPort = parts[1].split(":")
  
  if hostPort.len < 2:
    return
  
  result.host = hostPort[0]
  try:
    result.port = parseInt(hostPort[1])
  except:
    result.port = 0
    return
  
  # プロキシタイプに基づいてモードを設定
  case proxyType
  of "PROXY":
    result.mode = hpcmHttp
  of "HTTPS":
    result.mode = hpcmHttps
  of "SOCKS", "SOCKS4":
    result.mode = hpcmSocks5  # ここではSOCKS5として扱う（適切には別の定数が必要）
  of "SOCKS5":
    result.mode = hpcmSocks5
  else:
    result.mode = hpcmDirect

proc getFirstValidProxy*(proxyStr: string): string =
  ## PACファイルから返された複数のプロキシから最初の有効なものを取得する
  ##
  ## 引数:
  ##   proxyStr: PACファイルから返されるプロキシ文字列（複数可）
  ##
  ## 戻り値:
  ##   最初の有効なプロキシ文字列
  
  if proxyStr.len == 0:
    return "DIRECT"
  
  # 複数のプロキシが指定されている場合は分割（例: "PROXY foo:123; SOCKS bar:456; DIRECT"）
  let proxies = proxyStr.split(";")
  
  for proxy in proxies:
    let trimmed = proxy.strip()
    if trimmed.len > 0:
      if trimmed == "DIRECT":
        return "DIRECT"
      
      let parsed = parseProxyString(trimmed)
      if parsed.mode != hpcmDirect and parsed.host.len > 0 and parsed.port > 0:
        return trimmed
  
  # 有効なプロキシが見つからない場合はDIRECT
  return "DIRECT"
proc executePacScript*(client: ProxyAutoConfigClient, url: string): Future[string] {.async.} =
  ## PACスクリプトを実行してプロキシを決定する
  ##
  ## 引数:
  ##   url: プロキシを決定するURL
  ##
  ## 戻り値:
  ##   プロキシ文字列（"PROXY host:port" または "DIRECT" など）
  
  # スクリプトが有効でない場合は更新を試みる
  if not client.context.isValid or getTime() > client.context.cacheExpiry:
    let updated = await client.fetchPacFile()
    if not updated:
      client.logger.error("Failed to update PAC file, using direct connection")
      return "DIRECT"
  
  # キャッシュ済みの結果があればそれを返す
  if url in client.lastProxies and getTime() < client.lastProxiesExpiry:
    client.logger.debug(fmt"Using cached proxy result for {url}")
    return client.lastProxies[url]
  
  # URLをパース
  var parsedUrl: Uri
  try:
    parsedUrl = parseUri(url)
  except Exception as e:
    client.logger.error(fmt"Invalid URL: {url}, error: {e.msg}")
    return "DIRECT"
  
  let 
    host = parsedUrl.hostname
    path = if parsedUrl.path.len > 0: parsedUrl.path else: "/"
    hostIp = try: getHostByName(host).addrList[0] except: ""
    isResolvable = hostIp.len > 0
    isSecure = parsedUrl.scheme == "https"
    port = if parsedUrl.port.len > 0: parseInt(parsedUrl.port) 
           else: (if isSecure: 443 else: 80)
  
  # JavaScriptエンジンを使用してPACスクリプトを実行
  var proxyResult: string
  try:
    # JavaScriptコンテキストを準備
    let jsContext = client.context.jsEngine
    
    # FindProxyForURL関数を呼び出す
    proxyResult = jsContext.callFunction(
      "FindProxyForURL",
      @[url, host],
      additionalParams = {
        "myIpAddress": proc(): string = getLocalIpAddress(),
        "dnsResolve": proc(h: string): string = 
          try: getHostByName(h).addrList[0] except: "",
        "isInNet": proc(ipAddr, pattern, mask: string): bool = isIpInNetwork(ipAddr, pattern, mask),
        "isPlainHostName": proc(h: string): bool = not h.contains("."),
        "isResolvable": proc(h: string): bool = 
          try: discard getHostByName(h); true except: false,
        "dnsDomainIs": proc(h, domain: string): bool = h.endsWith(domain),
        "localHostOrDomainIs": proc(h, domain: string): bool = 
          h == domain or h.endsWith("." & domain),
        "shExpMatch": proc(str, pattern: string): bool = matchWildcard(str, pattern),
        "weekdayRange": proc(wd1, wd2, gmt = ""): bool = isInWeekdayRange(wd1, wd2, gmt == "GMT"),
        "dateRange": proc(args: varargs[string]): bool = isInDateRange(args),
        "timeRange": proc(args: varargs[string]): bool = isInTimeRange(args)
      }
    )
  except Exception as e:
    client.logger.error(fmt"PAC script execution error: {e.msg}")
    proxyResult = "DIRECT"
  
  # 結果が空または無効な場合はDIRECTを使用
  if proxyResult.len == 0 or not proxyResult.contains("DIRECT") and 
     not proxyResult.contains("PROXY") and not proxyResult.contains("SOCKS"):
    client.logger.warn(fmt"Invalid PAC result: '{proxyResult}', using DIRECT")
    proxyResult = "DIRECT"
  
  # 結果をキャッシュ（有効期限は設定に基づく）
  client.lastProxies[url] = proxyResult
  client.lastProxiesExpiry = getTime() + client.cacheLifetime
  
  client.logger.debug(fmt"PAC result for {url}: {proxyResult}")
  return proxyResult

proc findProxyForUrl*(client: ProxyAutoConfigClient, url: string): Future[tuple[mode: HttpProxyConnectionMode, host: string, port: int]] {.async.} =
  ## 指定されたURLに対するプロキシ設定を取得する
  ##
  ## 引数:
  ##   url: プロキシを決定するURL
  ##
  ## 戻り値:
  ##   (モード, ホスト, ポート) のタプル
  
  # PACスクリプトを実行してプロキシ文字列を取得
  let proxyStr = await client.executePacScript(url)
  
  # プロキシ文字列を解析
  let validProxy = getFirstValidProxy(proxyStr)
  return parseProxyString(validProxy)

proc getProxyForUrl*(client: ProxyAutoConfigClient, url: string, 
                   httpSettings: var HttpProxySettings, 
                   socksSettings: var SocksSettings): Future[HttpProxyConnectionMode] {.async.} =
  ## 指定されたURLに対するプロキシ設定を取得し、適切な設定オブジェクトを更新する
  ##
  ## 引数:
  ##   url: プロキシを決定するURL
  ##   httpSettings: 更新するHTTPプロキシ設定
  ##   socksSettings: 更新するSOCKSプロキシ設定
  ##
  ## 戻り値:
  ##   プロキシ接続モード
  
  let (mode, host, port) = await client.findProxyForUrl(url)
  
  # 直接接続の場合
  if mode == hpcmDirect:
    httpSettings.enabled = false
    socksSettings.enabled = false
    return mode
  
  # HTTPプロキシの場合
  if mode == hpcmHttp or mode == hpcmHttps:
    httpSettings.enabled = true
    httpSettings.host = host
    httpSettings.port = port
    httpSettings.connectionMode = mode
    socksSettings.enabled = false
    return mode
  
  # SOCKSプロキシの場合
  if mode == hpcmSocks5:
    httpSettings.enabled = false
    socksSettings.enabled = true
    socksSettings.host = host
    socksSettings.port = port
    socksSettings.version = svSocks5
    return mode
  
  # デフォルトは直接接続
  httpSettings.enabled = false
  socksSettings.enabled = false
  return hpcmDirect

proc close*(client: ProxyAutoConfigClient) =
  ## プロキシ自動設定クライアントを閉じる
  
  try:
    client.httpClient.close()
  except:
    let errMsg = getCurrentExceptionMsg()
    client.logger.warn(fmt"Error closing HTTP client: {errMsg}")
  
  client.logger.info("ProxyAutoConfigClient closed") 