import std/[strutils, options, tables, sequtils, algorithm]
import ./parser

type
  HttpVersionNegotiator* = object
    supportedVersions*: seq[HttpVersion]
    preferredOrder*: seq[HttpVersion]
    forceVersion*: Option[HttpVersion]
    minimumVersion*: Option[HttpVersion]
    alpnProtocols*: Table[string, HttpVersion]
  
  NegotiationResult* = object
    selectedVersion*: HttpVersion
    alpnProtocol*: Option[string]
    fallbackRequired*: bool
    reason*: string

proc newHttpVersionNegotiator*(): HttpVersionNegotiator =
  ## 新しいHTTPバージョンネゴシエーターを作成する
  result = HttpVersionNegotiator()
  
  # デフォルトでサポートされているバージョン
  result.supportedVersions = @[
    HttpVersions["1.0"],
    HttpVersions["1.1"],
    HttpVersions["2.0"]
  ]
  
  # デフォルトの優先順位（新しいバージョンが優先）
  result.preferredOrder = @[
    HttpVersions["2.0"],
    HttpVersions["1.1"],
    HttpVersions["1.0"]
  ]
  
  # ALPNプロトコル識別子とHTTPバージョンのマッピング
  result.alpnProtocols = {
    "http/1.0": HttpVersions["1.0"],
    "http/1.1": HttpVersions["1.1"],
    "h2": HttpVersions["2.0"],
    "h3": HttpVersions["3.0"]
  }.toTable

proc addSupportedVersion*(self: var HttpVersionNegotiator, version: HttpVersion) =
  ## サポートするHTTPバージョンを追加する
  if version notin self.supportedVersions:
    self.supportedVersions.add(version)
    # 優先順位リストにも追加（存在しない場合）
    if version notin self.preferredOrder:
      self.preferredOrder.add(version)

proc removeSupportedVersion*(self: var HttpVersionNegotiator, version: HttpVersion) =
  ## サポートするHTTPバージョンから指定したバージョンを削除する
  self.supportedVersions.keepIf(proc(v: HttpVersion): bool = not isSameVersion(v, version))
  self.preferredOrder.keepIf(proc(v: HttpVersion): bool = not isSameVersion(v, version))

proc setPreferredOrder*(self: var HttpVersionNegotiator, versions: seq[HttpVersion]) =
  ## HTTPバージョンの優先順位を設定する
  ## バージョンはすべてサポート対象である必要がある
  var validVersions: seq[HttpVersion] = @[]
  for v in versions:
    if v in self.supportedVersions:
      validVersions.add(v)
  
  # サポートされているバージョンで優先順位リストを更新
  self.preferredOrder = validVersions
  
  # 優先順位に含まれていないサポート対象バージョンを追加
  for v in self.supportedVersions:
    if v notin self.preferredOrder:
      self.preferredOrder.add(v)

proc setForceVersion*(self: var HttpVersionNegotiator, version: HttpVersion) =
  ## 特定のHTTPバージョンを強制的に使用するよう設定する
  if version in self.supportedVersions:
    self.forceVersion = some(version)
  else:
    raise newException(ValueError, "指定されたバージョンはサポートされていません: " & versionToString(version))

proc clearForceVersion*(self: var HttpVersionNegotiator) =
  ## 強制HTTPバージョン設定をクリアする
  self.forceVersion = none(HttpVersion)

proc setMinimumVersion*(self: var HttpVersionNegotiator, version: HttpVersion) =
  ## 最小HTTPバージョン要件を設定する
  self.minimumVersion = some(version)

proc clearMinimumVersion*(self: var HttpVersionNegotiator) =
  ## 最小HTTPバージョン要件をクリアする
  self.minimumVersion = none(HttpVersion)

proc getSupportedVersions*(self: HttpVersionNegotiator): seq[HttpVersion] =
  ## サポートしているHTTPバージョンのリストを取得する
  return self.supportedVersions

proc getPreferredOrder*(self: HttpVersionNegotiator): seq[HttpVersion] =
  ## HTTPバージョンの優先順位リストを取得する
  return self.preferredOrder

proc isVersionSupported*(self: HttpVersionNegotiator, version: HttpVersion): bool =
  ## 指定したHTTPバージョンがサポートされているかを確認する
  return version in self.supportedVersions

proc parseVersionFromHeader*(versionStr: string): Option[HttpVersion] =
  ## HTTP リクエスト/レスポンスライン内のバージョン文字列をパースする
  ## 例: "HTTP/1.1"
  return parseHttpVersion(versionStr)

proc negotiateFromClientPreferences*(self: HttpVersionNegotiator, clientPreferences: seq[HttpVersion]): NegotiationResult =
  ## クライアントの優先順位に基づいてHTTPバージョンをネゴシエートする
  ## クライアント側のコードで使用
  var selectedVersion: HttpVersion
  var reason = ""
  var fallbackRequired = false
  
  # 強制バージョンが設定されている場合はそれを使用
  if self.forceVersion.isSome:
    selectedVersion = self.forceVersion.get()
    reason = "強制バージョン設定により選択"
    return NegotiationResult(
      selectedVersion: selectedVersion,
      alpnProtocol: none(string),
      fallbackRequired: false,
      reason: reason
    )
  
  # 最小バージョン要件を適用
  var filteredClientPrefs: seq[HttpVersion] = clientPreferences
  if self.minimumVersion.isSome:
    let minVer = self.minimumVersion.get()
    filteredClientPrefs = clientPreferences.filterIt(not isOlderThan(it, minVer))
    if filteredClientPrefs.len == 0 and clientPreferences.len > 0:
      # 最小バージョン要件を満たすものがない場合は、対応する最小バージョンを使用
      selectedVersion = minVer
      reason = "クライアント優先順位が最小バージョン要件を満たさないため、最小バージョンにフォールバック"
      fallbackRequired = true
      return NegotiationResult(
        selectedVersion: selectedVersion,
        alpnProtocol: none(string),
        fallbackRequired: fallbackRequired,
        reason: reason
      )
  
  # クライアント優先順位とサーバーサポートの交差を見つける
  for clientVer in filteredClientPrefs:
    if clientVer in self.supportedVersions:
      selectedVersion = clientVer
      reason = "クライアント優先順位とサーバーサポートに基づいて選択"
      return NegotiationResult(
        selectedVersion: selectedVersion,
        alpnProtocol: none(string),
        fallbackRequired: false,
        reason: reason
      )
  
  # 一致するものが見つからない場合は、サーバーの最優先バージョンを使用
  if self.preferredOrder.len > 0:
    selectedVersion = self.preferredOrder[0]
    reason = "一致するバージョンがないため、サーバー優先バージョンにフォールバック"
    fallbackRequired = true
  else:
    # これは起こるべきではない
    selectedVersion = HttpVersions["1.1"] # HTTP/1.1をデフォルトとして使用
    reason = "バージョンネゴシエーション失敗、HTTP/1.1にフォールバック"
    fallbackRequired = true
  
  return NegotiationResult(
    selectedVersion: selectedVersion,
    alpnProtocol: none(string),
    fallbackRequired: fallbackRequired,
    reason: reason
  )

proc negotiateFromServerAdvertisement*(self: HttpVersionNegotiator, serverAdvertisedVersions: seq[HttpVersion]): NegotiationResult =
  ## サーバーがアドバタイズしたHTTPバージョンに基づいてネゴシエートする
  ## サーバー側のコードで使用
  var selectedVersion: HttpVersion
  var reason = ""
  var fallbackRequired = false
  
  # 強制バージョンが設定されている場合はそれを使用
  if self.forceVersion.isSome:
    selectedVersion = self.forceVersion.get()
    reason = "強制バージョン設定により選択"
    
    # サーバーがこのバージョンをサポートしているか確認
    if selectedVersion notin serverAdvertisedVersions:
      fallbackRequired = true
      reason &= "（サーバーがサポートしていないため、互換性の問題が発生する可能性あり）"
    
    return NegotiationResult(
      selectedVersion: selectedVersion,
      alpnProtocol: none(string),
      fallbackRequired: fallbackRequired,
      reason: reason
    )
  
  # 最小バージョン要件を適用
  var filteredServerVersions = serverAdvertisedVersions
  if self.minimumVersion.isSome:
    let minVer = self.minimumVersion.get()
    filteredServerVersions = serverAdvertisedVersions.filterIt(not isOlderThan(it, minVer))
    
    if filteredServerVersions.len == 0 and serverAdvertisedVersions.len > 0:
      # サーバーが最小バージョン要件を満たすものを提供していない
      # この場合、最小バージョンを使用するが、互換性の問題が発生する可能性がある
      selectedVersion = minVer
      reason = "サーバーが最小バージョン要件を満たすバージョンを提供していないため、互換性の問題が発生する可能性あり"
      fallbackRequired = true
      return NegotiationResult(
        selectedVersion: selectedVersion,
        alpnProtocol: none(string),
        fallbackRequired: fallbackRequired,
        reason: reason
      )
  
  # 優先順位に従って選択
  for preferredVer in self.preferredOrder:
    if preferredVer in filteredServerVersions and preferredVer in self.supportedVersions:
      selectedVersion = preferredVer
      reason = "クライアント優先順位とサーバーサポートに基づいて選択"
      return NegotiationResult(
        selectedVersion: selectedVersion,
        alpnProtocol: none(string),
        fallbackRequired: false,
        reason: reason
      )
  
  # 一致するものが見つからない場合
  if serverAdvertisedVersions.len > 0:
    # サーバーがサポートする最高バージョンを選択
    var highestServerVersion = serverAdvertisedVersions[0]
    for v in serverAdvertisedVersions:
      if isNewerThan(v, highestServerVersion):
        highestServerVersion = v
    
    if highestServerVersion in self.supportedVersions:
      selectedVersion = highestServerVersion
      reason = "クライアント優先順位との一致がないため、サーバーの最高バージョンを選択"
      fallbackRequired = true
    else:
      # サーバーのバージョンがクライアントでサポートされていない場合
      selectedVersion = self.preferredOrder[0]
      reason = "互換性のあるバージョンがないため、クライアント優先バージョンを使用（互換性の問題が発生する可能性あり）"
      fallbackRequired = true
  else:
    # サーバーがバージョン情報を提供していない場合
    selectedVersion = self.preferredOrder[0]
    reason = "サーバーがバージョン情報を提供していないため、クライアント優先バージョンを使用"
    fallbackRequired = true
  
  return NegotiationResult(
    selectedVersion: selectedVersion,
    alpnProtocol: none(string),
    fallbackRequired: fallbackRequired,
    reason: reason
  )

proc negotiateFromAlpn*(self: HttpVersionNegotiator, alpnProtocol: string): NegotiationResult =
  ## ALPNプロトコル識別子に基づいてHTTPバージョンをネゴシエートする
  var selectedVersion: HttpVersion
  var reason = ""
  var fallbackRequired = false
  
  # ALPNプロトコル識別子からHTTPバージョンを取得
  if alpnProtocol in self.alpnProtocols:
    let version = self.alpnProtocols[alpnProtocol]
    
    # バージョンがサポートされていることを確認
    if version in self.supportedVersions:
      # 最小バージョン要件をチェック
      if self.minimumVersion.isSome and isOlderThan(version, self.minimumVersion.get()):
        selectedVersion = self.minimumVersion.get()
        reason = "ALPNプロトコルで選択されたバージョンが最小要件を満たさないため、最小バージョンにフォールバック"
        fallbackRequired = true
      else:
        selectedVersion = version
        reason = "ALPNネゴシエーションに基づいて選択"
    else:
      # ALPNで選択されたバージョンがサポートされていない場合
      selectedVersion = self.preferredOrder[0]
      reason = "ALPNプロトコルで選択されたバージョンがサポートされていないため、優先バージョンにフォールバック"
      fallbackRequired = true
  else:
    # 未知のALPNプロトコル識別子
    selectedVersion = self.preferredOrder[0]
    reason = "未知のALPNプロトコル識別子のため、優先バージョンにフォールバック"
    fallbackRequired = true
  
  return NegotiationResult(
    selectedVersion: selectedVersion,
    alpnProtocol: some(alpnProtocol),
    fallbackRequired: fallbackRequired,
    reason: reason
  )

proc getAlpnProtocolsForVersions*(self: HttpVersionNegotiator, versions: seq[HttpVersion]): seq[string] =
  ## 指定したHTTPバージョンに対応するALPNプロトコル識別子のリストを取得する
  result = @[]
  for v in versions:
    for alpn, ver in self.alpnProtocols.pairs:
      if isSameVersion(v, ver):
        result.add(alpn)

proc getSupportedAlpnProtocols*(self: HttpVersionNegotiator): seq[string] =
  ## サポートしているすべてのHTTPバージョンに対応するALPNプロトコル識別子のリストを取得する
  return self.getAlpnProtocolsForVersions(self.supportedVersions)

proc parseVersionsFromHeader*(versionHeader: string): seq[HttpVersion] =
  ## 複数のHTTPバージョンを含むヘッダー値からバージョンのリストをパースする
  ## 例: "HTTP/2, HTTP/1.1, HTTP/1.0"
  result = @[]
  let versionStrs = versionHeader.split(',')
  for vStr in versionStrs:
    let cleaned = vStr.strip()
    let versionOpt = parseHttpVersion(cleaned)
    if versionOpt.isSome:
      result.add(versionOpt.get())

proc selectBestVersionForRequest*(
  self: HttpVersionNegotiator, 
  requestVersion: HttpVersion,
  upgradeHeader: Option[string] = none(string),
  alpnProtocol: Option[string] = none(string)
): NegotiationResult =
  ## HTTPリクエストに対して最適なHTTPバージョンを選択する
  ## requestVersion: リクエストで使用されているHTTPバージョン
  ## upgradeHeader: Upgradeヘッダーの値（存在する場合）
  ## alpnProtocol: TLS接続で使用されているALPNプロトコル（存在する場合）
  
  # ALPNが指定されている場合は、それを優先
  if alpnProtocol.isSome:
    return self.negotiateFromAlpn(alpnProtocol.get())
  
  # Upgradeヘッダーがある場合は、そこからバージョンを抽出
  var upgradeVersions: seq[HttpVersion] = @[]
  if upgradeHeader.isSome:
    let protocols = upgradeHeader.get().split(',')
    for proto in protocols:
      let cleaned = proto.strip().toLowerAscii()
      if cleaned == "h2c":
        upgradeVersions.add(HttpVersions["2.0"])
      elif cleaned == "http/1.1":
        upgradeVersions.add(HttpVersions["1.1"])
  
  # リクエストバージョンとアップグレード候補を組み合わせて優先順位リストを作成
  var clientPreferences: seq[HttpVersion] = @[]
  clientPreferences.add(requestVersion)
  for v in upgradeVersions:
    if v notin clientPreferences:
      clientPreferences.add(v)
  
  # クライアント優先順位に基づいてネゴシエーション
  return self.negotiateFromClientPreferences(clientPreferences)

proc formatVersionsForHeader*(versions: seq[HttpVersion]): string =
  ## HTTPバージョンのリストをヘッダー値形式にフォーマットする
  ## 例: "HTTP/2, HTTP/1.1, HTTP/1.0"
  var versionStrs: seq[string] = @[]
  for v in versions:
    versionStrs.add(versionToString(v))
  return versionStrs.join(", ")

proc getVersionsForUpgradeHeader*(self: HttpVersionNegotiator, currentVersion: HttpVersion): seq[HttpVersion] =
  ## 現在のバージョンからアップグレード可能なバージョンのリストを取得する
  result = @[]
  for v in self.preferredOrder:
    if isNewerThan(v, currentVersion) and v in self.supportedVersions:
      result.add(v)

proc formatUpgradeHeaderValue*(self: HttpVersionNegotiator, currentVersion: HttpVersion): string =
  ## 現在のバージョンからアップグレード可能なバージョンをUpgradeヘッダー値形式にフォーマットする
  var protocols: seq[string] = @[]
  let upgradeVersions = self.getVersionsForUpgradeHeader(currentVersion)
  
  for v in upgradeVersions:
    if isHttp2(v):
      protocols.add("h2c")  # HTTP/2 cleartext
    elif isHttp11(v):
      protocols.add("http/1.1")
  
  return protocols.join(", ") 