# cookie_integrations.nim
## クッキー統合モジュール - 他システムとの連携機能

import std/[
  uri,
  options,
  tables,
  json,
  os,
  times,
  strutils,
  streams,
  httpclient,
  strformat,
  asyncdispatch,
  parseutils
]
import ./cookie_types
import ./store/cookie_store
import ./security/cookie_security
import ./policy/cookie_policy

type
  BrowserType* = enum
    ## 対応ブラウザタイプ
    btChrome,        # Google Chrome
    btFirefox,       # Mozilla Firefox
    btSafari,        # Apple Safari
    btEdge,          # Microsoft Edge
    btOpera,         # Opera
    btUnknown        # 不明/その他

  ImportOptions* = object
    ## インポートオプション
    applyPolicy*: bool             # インポート時にポリシーを適用するか
    filterExpired*: bool           # 期限切れのクッキーを除外するか
    secureOnly*: bool              # セキュアクッキーのみをインポートするか
    validateDomains*: bool         # ドメイン検証を行うか
    mergeDuplicates*: bool         # 重複をマージするか

  ExportFormat* = enum
    ## エクスポート形式
    efJson,          # JSON形式
    efNetscape,      # Netscape形式
    efHar            # HAR (HTTP Archive)形式

  IntegrationManager* = ref object
    ## 統合マネージャー
    importOptions*: ImportOptions   # インポートオプション
    cookiePolicy*: CookiePolicy     # 適用ポリシー
    importedCount*: Table[BrowserType, int]  # ブラウザ別インポート数
    lastImport*: Time               # 最終インポート時刻
    lastExport*: Time               # 最終エクスポート時刻

# デフォルトパス
const
  CHROME_COOKIE_PATHS = [
    "~/.config/google-chrome/Default/Cookies",
    "~/Library/Application Support/Google/Chrome/Default/Cookies",
    "~/AppData/Local/Google/Chrome/User Data/Default/Cookies"
  ]
  
  FIREFOX_COOKIE_PATHS = [
    "~/.mozilla/firefox/*.default/cookies.sqlite",
    "~/Library/Application Support/Firefox/Profiles/*.default/cookies.sqlite",
    "~/AppData/Roaming/Mozilla/Firefox/Profiles/*.default/cookies.sqlite"
  ]
  
  EDGE_COOKIE_PATHS = [
    "~/.config/microsoft-edge/Default/Cookies",
    "~/Library/Application Support/Microsoft Edge/Default/Cookies",
    "~/AppData/Local/Microsoft/Edge/User Data/Default/Cookies"
  ]

###################
# 初期化
###################

proc newIntegrationManager*(policy: CookiePolicy = nil): IntegrationManager =
  ## 新しい統合マネージャーを作成
  result = IntegrationManager(
    importOptions: ImportOptions(
      applyPolicy: true,
      filterExpired: true,
      secureOnly: false,
      validateDomains: true,
      mergeDuplicates: true
    ),
    cookiePolicy: policy,
    importedCount: initTable[BrowserType, int](),
    lastImport: Time(),
    lastExport: Time()
  )
  
  # 統計初期化
  for browser in BrowserType:
    result.importedCount[browser] = 0

proc setImportOptions*(manager: IntegrationManager, options: ImportOptions) =
  ## インポートオプションを設定
  manager.importOptions = options

proc setCookiePolicy*(manager: IntegrationManager, policy: CookiePolicy) =
  ## 適用ポリシーを設定
  manager.cookiePolicy = policy

###################
# ブラウザ検出
###################

proc findBrowserCookieFile*(browserType: BrowserType): string =
  ## ブラウザのクッキーファイルパスを検出
  let paths = case browserType
    of btChrome: CHROME_COOKIE_PATHS
    of btFirefox: FIREFOX_COOKIE_PATHS
    of btEdge: EDGE_COOKIE_PATHS
    else: @[]
  
  for path in paths:
    let expandedPath = path.replace("~", getHomeDir().stripTrailingSlash())
    
    # ワイルドカード対応
    if "*" in expandedPath:
      let (dir, pattern) = expandedPath.splitPath()
      if dirExists(dir):
        for file in walkFiles(expandedPath):
          if fileExists(file):
            return file
    else:
      if fileExists(expandedPath):
        return expandedPath
  
  return ""

proc detectInstalledBrowsers*(): seq[BrowserType] =
  ## インストール済みのブラウザを検出
  result = @[]
  
  for browser in [btChrome, btFirefox, btEdge, btOpera]:
    let cookiePath = findBrowserCookieFile(browser)
    if cookiePath.len > 0:
      result.add(browser)

###################
# インポート機能
###################

proc importCookiesFromJson*(manager: IntegrationManager, jsonData: JsonNode): seq[Cookie] =
  ## JSON形式からクッキーをインポート
  var imported: seq[Cookie] = @[]
  let now = getTime()
  
  try:
    if jsonData.kind != JArray:
      return @[]
    
    for item in jsonData:
      # 必須フィールドの確認
      if not (item.hasKey("name") and item.hasKey("domain") and item.hasKey("value")):
        continue
      
      let name = item["name"].getStr()
      let domain = item["domain"].getStr()
      let value = item["value"].getStr()
      
      if name.len == 0 or domain.len == 0:
        continue
      
      # パスの取得
      var path = "/"
      if item.hasKey("path"):
        path = item["path"].getStr()
      
      # 期限の取得
      var expiryTime: Option[Time] = none(Time)
      if item.hasKey("expirationDate") or item.hasKey("expires"):
        let expiryField = if item.hasKey("expirationDate"): "expirationDate" else: "expires"
        let expiry = item[expiryField]
        
        if expiry.kind == JInt:
          expiryTime = some(fromUnix(expiry.getInt()))
        elif expiry.kind == JFloat:
          expiryTime = some(fromUnix(int(expiry.getFloat())))
        elif expiry.kind == JString:
          try:
            # ISO日付形式を解析
            expiryTime = some(parse(expiry.getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'"))
          except:
            try:
              # Unix時間を解析
              var seconds: int
              if parseutils.parseInt(expiry.getStr(), seconds) > 0:
                expiryTime = some(fromUnix(seconds))
            except:
              # 解析失敗、期限なしクッキーとして扱う
              discard
      
      # 期限切れフィルター
      if manager.importOptions.filterExpired and expiryTime.isSome and expiryTime.get() <= now:
        continue
      
      # セキュリティ設定
      var isSecure = false
      if item.hasKey("secure"):
        if item["secure"].kind == JBool:
          isSecure = item["secure"].getBool()
        elif item["secure"].kind == JInt:
          isSecure = item["secure"].getInt() != 0
      
      # セキュアクッキーのみフィルター
      if manager.importOptions.secureOnly and not isSecure:
        continue
      
      var isHttpOnly = false
      if item.hasKey("httpOnly"):
        if item["httpOnly"].kind == JBool:
          isHttpOnly = item["httpOnly"].getBool()
        elif item["httpOnly"].kind == JInt:
          isHttpOnly = item["httpOnly"].getInt() != 0
      
      # SameSite設定
      var sameSite = ssNone
      if item.hasKey("sameSite"):
        let siteStr = item["sameSite"].getStr().toLowerAscii()
        case siteStr
        of "lax": sameSite = ssLax
        of "strict": sameSite = ssStrict
        of "none": sameSite = ssNone
        else: sameSite = ssNone
      
      # クッキーオブジェクト作成
      let cookie = newCookie(
        name = name,
        value = value,
        domain = domain,
        path = path,
        expirationTime = expiryTime,
        isSecure = isSecure,
        isHttpOnly = isHttpOnly,
        sameSite = sameSite,
        source = csImported
      )
      
      # ポリシー適用
      if manager.importOptions.applyPolicy and manager.cookiePolicy != nil:
        let rule = manager.cookiePolicy.getRuleForDomain(domain)
        if rule == prBlock:
          continue
        elif rule == prAllowSession and cookie.expirationTime.isSome:
          var sessionCookie = cookie
          sessionCookie.expirationTime = none(Time)
          imported.add(sessionCookie)
        else:
          imported.add(cookie)
      else:
        imported.add(cookie)
  except:
    # インポートエラーは無視して続行
    discard
  
  return imported

proc importCookiesFromNetscape*(manager: IntegrationManager, content: string): seq[Cookie] =
  ## Netscape形式からクッキーをインポート
  var imported: seq[Cookie] = @[]
  let now = getTime()
  
  try:
    let lines = content.splitLines()
    for line in lines:
      if line.startsWith("#") or line.strip().len == 0:
        continue
      
      let parts = line.split('\t')
      if parts.len < 7:
        continue
      
      let domain = parts[0]
      var hostOnly = false
      
      # フラグの解析 (TRUE/FALSE)
      let httpOnly = parts.len >= 8 and parts[7].toLowerAscii() == "true"
      let isSecure = parts[3].toLowerAscii() == "true"
      
      # 期限切れの確認
      let expiry = try: fromUnix(parseInt(parts[4])) except: getTime()
      if manager.importOptions.filterExpired and expiry <= now:
        continue
      
      # セキュアクッキーのみフィルター
      if manager.importOptions.secureOnly and not isSecure:
        continue
      
      # クッキーオブジェクト作成
      let cookie = newCookie(
        name = parts[5],
        value = parts[6],
        domain = domain,
        path = parts[2],
        expirationTime = some(expiry),
        isSecure = isSecure,
        isHttpOnly = httpOnly,
        sameSite = ssNone,
        source = csImported
      )
      
      # ポリシー適用
      if manager.importOptions.applyPolicy and manager.cookiePolicy != nil:
        let rule = manager.cookiePolicy.getRuleForDomain(domain)
        if rule == prBlock:
          continue
        elif rule == prAllowSession:
          var sessionCookie = cookie
          sessionCookie.expirationTime = none(Time)
          imported.add(sessionCookie)
        else:
          imported.add(cookie)
      else:
        imported.add(cookie)
  except:
    # インポートエラーは無視して続行
    discard
  
  return imported

proc importCookiesFromHar*(manager: IntegrationManager, harData: JsonNode): seq[Cookie] =
  ## HAR形式からクッキーをインポート
  var imported: seq[Cookie] = @[]
  
  try:
    if not (harData.hasKey("log") and harData["log"].hasKey("entries")):
      return @[]
    
    for entry in harData["log"]["entries"]:
      if not entry.hasKey("response"):
        continue
      
      let response = entry["response"]
      if not response.hasKey("cookies"):
        continue
      
      let url = if entry.hasKey("request") and entry["request"].hasKey("url"):
                  entry["request"]["url"].getStr()
                else: ""
      
      var uri: Uri
      try:
        if url.len > 0:
          uri = parseUri(url)
      except:
        uri = nil
      
      for cookieJson in response["cookies"]:
        if not (cookieJson.hasKey("name") and cookieJson.hasKey("value")):
          continue
        
        let name = cookieJson["name"].getStr()
        let value = cookieJson["value"].getStr()
        
        # ドメインの取得（URLまたは明示的ドメイン）
        var domain = ""
        if cookieJson.hasKey("domain"):
          domain = cookieJson["domain"].getStr()
        elif uri != nil:
          domain = uri.hostname
        
        if domain.len == 0:
          continue
        
        # パスの取得
        var path = "/"
        if cookieJson.hasKey("path"):
          path = cookieJson["path"].getStr()
        
        # 期限の取得
        var expiryTime: Option[Time] = none(Time)
        if cookieJson.hasKey("expires"):
          try:
            expiryTime = some(parse(cookieJson["expires"].getStr(), "yyyy-MM-dd'T'HH:mm:ss.fff'Z'"))
          except:
            try:
              expiryTime = some(parse(cookieJson["expires"].getStr(), "EEE, dd MMM yyyy HH:mm:ss 'GMT'"))
            except:
              # その他の形式は無視
              discard
        
        # セキュリティ設定
        let isSecure = if cookieJson.hasKey("secure"): cookieJson["secure"].getBool() else: false
        let isHttpOnly = if cookieJson.hasKey("httpOnly"): cookieJson["httpOnly"].getBool() else: false
        
        # クッキーオブジェクト作成
        let cookie = newCookie(
          name = name,
          value = value,
          domain = domain,
          path = path,
          expirationTime = expiryTime,
          isSecure = isSecure,
          isHttpOnly = isHttpOnly,
          sameSite = ssNone,
          source = csImported
        )
        
        # ポリシー適用とフィルタリング
        let addCookie = if manager.importOptions.applyPolicy and manager.cookiePolicy != nil:
                          manager.cookiePolicy.getRuleForDomain(domain) != prBlock
                        else: true
        
        if addCookie and 
           (not manager.importOptions.secureOnly or isSecure) and
           (not manager.importOptions.filterExpired or expiryTime.isNone or expiryTime.get() > getTime()):
          imported.add(cookie)
      
      # リクエストクッキーも含める
      if entry.hasKey("request") and entry["request"].hasKey("cookies"):
        for cookieJson in entry["request"]["cookies"]:
          if not (cookieJson.hasKey("name") and cookieJson.hasKey("value")):
            continue
          
          let name = cookieJson["name"].getStr()
          let value = cookieJson["value"].getStr()
          
          # 既に同じ名前のクッキーがあれば追加しない
          if imported.anyIt(it.name == name and (uri == nil or it.domain == uri.hostname)):
            continue
          
          # ドメインの取得（URLから）
          if uri == nil:
            continue
          let domain = uri.hostname
          
          # クッキーオブジェクト作成
          let cookie = newCookie(
            name = name,
            value = value,
            domain = domain,
            path = "/",
            isSecure = false,
            isHttpOnly = false,
            sameSite = ssNone,
            source = csImported
          )
          
          # ポリシー適用
          if manager.importOptions.applyPolicy and manager.cookiePolicy != nil:
            if manager.cookiePolicy.getRuleForDomain(domain) != prBlock:
              imported.add(cookie)
          else:
            imported.add(cookie)
  except:
    # インポートエラーは無視して続行
    discard
  
  return imported

proc importCookiesFromFile*(manager: IntegrationManager, filePath: string): seq[Cookie] =
  ## ファイルからクッキーをインポート
  if not fileExists(filePath):
    return @[]
  
  let fileContent = readFile(filePath)
  let fileExt = filePath.splitFile().ext.toLowerAscii()
  
  try:
    case fileExt
    of ".json":
      let jsonData = parseJson(fileContent)
      return manager.importCookiesFromJson(jsonData)
    
    of ".har":
      let jsonData = parseJson(fileContent)
      return manager.importCookiesFromHar(jsonData)
    
    of ".txt":
      # Netscape形式と仮定
      return manager.importCookiesFromNetscape(fileContent)
    
    else:
      # 自動判定を試みる
      try:
        let jsonData = parseJson(fileContent)
        if jsonData.kind == JArray:
          return manager.importCookiesFromJson(jsonData)
        elif jsonData.hasKey("log") and jsonData["log"].hasKey("entries"):
          return manager.importCookiesFromHar(jsonData)
      except:
        # JSONではない場合はNetscape形式を試みる
        if fileContent.startsWith("# Netscape HTTP Cookie File"):
          return manager.importCookiesFromNetscape(fileContent)
        elif "\t" in fileContent:
          # タブ区切りならNetscape形式の可能性
          return manager.importCookiesFromNetscape(fileContent)
  except:
    # インポートエラーは無視
    discard
  
  return @[]

proc importCookiesFromBrowser*(manager: IntegrationManager, browserType: BrowserType): Future[seq[Cookie]] {.async.} =
  ## ブラウザからクッキーをインポート
  # Note: このプロシージャは実際には外部コマンドやSQLiteアクセスが必要で複雑なため
  # 実際の実装ではブラウザごとの専用ロジックが必要
  
  # 代わりにダミー実装
  var dummyCookies: seq[Cookie] = @[]
  
  # ブラウザからのインポートを模擬
  let domains = ["example.com", "google.com", "github.com"]
  let now = getTime()
  
  for domain in domains:
    let cookie = newCookie(
      name = "session_id_" & $browserType,
      value = "dummy_value_" & $now.toUnix(),
      domain = domain,
      path = "/",
      expirationTime = some(now + initDuration(days = 7)),
      isSecure = true,
      isHttpOnly = true,
      sameSite = ssLax,
      source = csImported
    )
    
    dummyCookies.add(cookie)
  
  manager.importedCount[browserType] += dummyCookies.len
  manager.lastImport = getTime()
  
  return dummyCookies

###################
# エクスポート機能
###################

proc cookiesToJson*(cookies: seq[Cookie]): JsonNode =
  ## クッキーをJSON形式に変換
  result = newJArray()
  
  for cookie in cookies:
    var cookieObj = %*{
      "name": cookie.name,
      "value": cookie.value,
      "domain": cookie.domain,
      "path": cookie.path,
      "secure": cookie.isSecure,
      "httpOnly": cookie.isHttpOnly,
      "sameSite": $cookie.sameSite
    }
    
    if cookie.expirationTime.isSome:
      cookieObj["expirationDate"] = %cookie.expirationTime.get().toUnix()
      
      # 人間可読形式も含める
      cookieObj["expires"] = %cookie.expirationTime.get().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    
    result.add(cookieObj)

proc cookiesToNetscape*(cookies: seq[Cookie]): string =
  ## クッキーをNetscape形式に変換
  result = "# Netscape HTTP Cookie File\n"
  result &= "# https://curl.haxx.se/docs/http-cookies.html\n"
  result &= "# This file was generated by our browser. Edit at your own risk.\n\n"
  
  for cookie in cookies:
    # format: domain flag path secure expiry name value
    let domain = cookie.domain
    let includeSubdomains = domain.startsWith(".")
    let flag = if includeSubdomains: "TRUE" else: "FALSE"
    let secure = if cookie.isSecure: "TRUE" else: "FALSE"
    let expiry = if cookie.expirationTime.isSome: $cookie.expirationTime.get().toUnix() else: "0"
    let httpOnly = if cookie.isHttpOnly: "TRUE" else: "FALSE"
    
    result &= &"{domain}\t{flag}\t{cookie.path}\t{secure}\t{expiry}\t{cookie.name}\t{cookie.value}\t{httpOnly}\n"

proc cookiesToHar*(cookies: seq[Cookie]): JsonNode =
  ## クッキーをHAR形式に変換
  var cookiesArray = newJArray()
  
  for cookie in cookies:
    var cookieObj = %*{
      "name": cookie.name,
      "value": cookie.value,
      "path": cookie.path,
      "domain": cookie.domain,
      "httpOnly": cookie.isHttpOnly,
      "secure": cookie.isSecure
    }
    
    if cookie.expirationTime.isSome:
      cookieObj["expires"] = %cookie.expirationTime.get().format("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    
    cookiesArray.add(cookieObj)
  
  let entryObj = %*{
    "startedDateTime": getTime().format("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"),
    "request": {
      "method": "GET",
      "url": "https://example.com/",
      "cookies": []
    },
    "response": {
      "status": 200,
      "cookies": cookiesArray
    }
  }
  
  let entriesArray = newJArray()
  entriesArray.add(entryObj)
  
  result = %*{
    "log": {
      "version": "1.2",
      "creator": {
        "name": "Cookie Integration Module",
        "version": "1.0"
      },
      "entries": entriesArray
    }
  }

proc exportCookies*(cookies: seq[Cookie], format: ExportFormat, filePath: string): bool =
  ## クッキーをファイルにエクスポート
  try:
    var content = ""
    
    case format
    of efJson:
      let jsonData = cookiesToJson(cookies)
      content = $jsonData
    
    of efNetscape:
      content = cookiesToNetscape(cookies)
    
    of efHar:
      let jsonData = cookiesToHar(cookies)
      content = $jsonData
    
    writeFile(filePath, content)
    return true
  except:
    return false

###################
# 統計・レポート
###################

proc getImportStats*(manager: IntegrationManager): JsonNode =
  ## インポート統計を取得
  var statsObj = newJObject()
  var totalImported = 0
  
  for browser, count in manager.importedCount:
    statsObj[$browser] = %count
    totalImported += count
  
  result = %*{
    "total_imported": totalImported,
    "by_browser": statsObj,
    "last_import": if manager.lastImport == Time(): nil else: %manager.lastImport.format("yyyy-MM-dd HH:mm:ss")
  }

proc formatCookieForReport*(cookie: Cookie): JsonNode =
  ## レポート用にクッキーを整形
  result = %*{
    "name": cookie.name,
    "domain": cookie.domain,
    "path": cookie.path,
    "secure": cookie.isSecure,
    "httpOnly": cookie.isHttpOnly,
    "sameSite": $cookie.sameSite,
    "source": $cookie.source
  }
  
  if cookie.expirationTime.isSome:
    result["expires"] = %cookie.expirationTime.get().format("yyyy-MM-dd HH:mm:ss")
    
    # 有効期限までの日数
    let daysRemaining = (cookie.expirationTime.get() - getTime()).inDays
    result["days_remaining"] = %daysRemaining 