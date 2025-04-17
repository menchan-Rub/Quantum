# proxy_cache.nim
# プロキシキャッシュシステムの実装
# プロキシ設定とレスポンスのキャッシュを管理し、パフォーマンスを向上させます

import std/[tables, times, hashes, options, strutils, sequtils, uri, os, json]
import std/[asyncdispatch, asyncnet, httpclient]
import logging

import ../http/http_proxy_types
import ../socks/socks_proxy_types
import ../../utils/ip_utils
import ../../utils/url_utils

type
  CacheEntryType* = enum
    cetProxyConfig,  # プロキシ設定のキャッシュ
    cetProxyResult,  # プロキシリクエスト結果のキャッシュ
    cetPacResult     # PAC評価結果のキャッシュ

  CacheStorageType* = enum
    cstMemory,    # メモリ内キャッシュ
    cstDisk       # ディスクベースのキャッシュ

  CacheEntryState* = enum
    cesValid,     # 有効なエントリ
    cesExpired,   # 期限切れだが使用可能
    cesInvalid    # 無効なエントリ

  ProxyCacheEntry* = ref object
    createdAt*: DateTime       # エントリ作成時刻
    lastAccessedAt*: DateTime  # 最後にアクセスされた時刻
    expiresAt*: Option[DateTime] # 有効期限（設定されている場合）
    accessCount*: int          # アクセス回数
    case entryType*: CacheEntryType
    of cetProxyConfig:
      configKey*: string       # 設定エントリのキー
      httpProxySettings*: Option[HttpProxySettings]  # HTTPプロキシ設定
      socksProxySettings*: Option[SocksProxySettings] # SOCKSプロキシ設定
    of cetProxyResult:
      resultKey*: string       # 結果エントリのキー
      requestUrl*: string      # リクエストURL
      statusCode*: int         # ステータスコード
      latency*: int            # レイテンシ（ミリ秒）
      success*: bool           # 成功したかどうか
    of cetPacResult:
      pacKey*: string          # PACエントリのキー
      pacUrl*: string          # PAC URL
      targetUrl*: string       # ターゲットURL
      foundProxy*: string      # 見つかったプロキシ

  ProxyCacheConfig* = ref object
    enabled*: bool             # キャッシュが有効かどうか
    storageType*: CacheStorageType # ストレージタイプ
    maxEntries*: int           # 最大エントリ数
    defaultTTL*: int           # デフォルトのTTL（秒）
    configTTL*: int            # プロキシ設定のTTL（秒）
    resultTTL*: int            # プロキシ結果のTTL（秒）
    pacTTL*: int               # PAC結果のTTL（秒）
    diskCachePath*: string     # ディスクキャッシュのパス
    cleanupInterval*: int      # クリーンアップ間隔（秒）

  ProxyCache* = ref object
    config*: ProxyCacheConfig  # キャッシュ設定
    memoryEntries*: Table[string, ProxyCacheEntry]  # メモリ内エントリ
    logger*: Logger            # ロガー
    lastCleanupTime*: DateTime # 最後のクリーンアップ時刻

const
  DefaultMaxEntries* = 1000
  DefaultDefaultTTL* = 3600      # 1時間
  DefaultConfigTTL* = 14400      # 4時間
  DefaultResultTTL* = 300        # 5分
  DefaultPacTTL* = 1800          # 30分
  DefaultCleanupInterval* = 600  # 10分
  DefaultDiskCachePath* = ".cache/proxy_cache"

proc newProxyCacheConfig*(
  enabled: bool = true,
  storageType: CacheStorageType = cstMemory,
  maxEntries: int = DefaultMaxEntries,
  defaultTTL: int = DefaultDefaultTTL,
  configTTL: int = DefaultConfigTTL,
  resultTTL: int = DefaultResultTTL,
  pacTTL: int = DefaultPacTTL,
  diskCachePath: string = DefaultDiskCachePath,
  cleanupInterval: int = DefaultCleanupInterval
): ProxyCacheConfig =
  ## 新しいプロキシキャッシュ設定を作成します
  result = ProxyCacheConfig(
    enabled: enabled,
    storageType: storageType,
    maxEntries: maxEntries,
    defaultTTL: defaultTTL,
    configTTL: configTTL,
    resultTTL: resultTTL,
    pacTTL: pacTTL,
    diskCachePath: diskCachePath,
    cleanupInterval: cleanupInterval
  )

proc newProxyCache*(config: ProxyCacheConfig = nil, logger: Logger = nil): ProxyCache =
  ## 新しいプロキシキャッシュを作成します
  let actualConfig = if config.isNil: newProxyCacheConfig() else: config
  let actualLogger = if logger.isNil: newConsoleLogger() else: logger
  
  result = ProxyCache(
    config: actualConfig,
    memoryEntries: initTable[string, ProxyCacheEntry](),
    logger: actualLogger,
    lastCleanupTime: now()
  )
  
  # ディスクキャッシュを使用する場合はディレクトリを作成
  if actualConfig.storageType == cstDisk:
    try:
      createDir(actualConfig.diskCachePath)
    except:
      actualLogger.log(lvlError, "ディスクキャッシュディレクトリの作成に失敗しました: " & getCurrentExceptionMsg())

proc generateKey(url: string, additionalData: string = ""): string =
  ## キャッシュキーを生成します
  if additionalData.len > 0:
    result = url & "|" & additionalData
  else:
    result = url

proc getEntryState*(entry: ProxyCacheEntry): CacheEntryState =
  ## エントリの状態を取得します
  if entry.isNil:
    return cesInvalid
  
  let currentTime = now()
  
  # 有効期限が設定されている場合はチェック
  if entry.expiresAt.isSome:
    if currentTime > entry.expiresAt.get:
      return cesExpired
  
  return cesValid

proc getCacheFilePath(cache: ProxyCache, key: string): string =
  ## キャッシュファイルのパスを取得します
  let sanitizedKey = key.replace({'/': '_', '\\': '_', ':': '_', '*': '_', '?': '_', '"': '_', '<': '_', '>': '_', '|': '_'})
  result = cache.config.diskCachePath / sanitizedKey & ".json"

proc serializeEntry(entry: ProxyCacheEntry): JsonNode =
  ## エントリをJSONに変換します
  result = %*{
    "createdAt": $entry.createdAt,
    "lastAccessedAt": $entry.lastAccessedAt,
    "accessCount": entry.accessCount,
    "entryType": $entry.entryType
  }
  
  if entry.expiresAt.isSome:
    result["expiresAt"] = %($entry.expiresAt.get)
  
  case entry.entryType:
  of cetProxyConfig:
    result["configKey"] = %entry.configKey
    if entry.httpProxySettings.isSome:
      let http = entry.httpProxySettings.get
      result["httpProxy"] = %*{
        "host": http.host,
        "port": http.port,
        "username": http.username,
        "authScheme": $http.authScheme,
        "connectionMode": $http.connectionMode
      }
    if entry.socksProxySettings.isSome:
      let socks = entry.socksProxySettings.get
      result["socksProxy"] = %*{
        "host": socks.host,
        "port": socks.port,
        "username": socks.username,
        "version": socks.version
      }
  of cetProxyResult:
    result["resultKey"] = %entry.resultKey
    result["requestUrl"] = %entry.requestUrl
    result["statusCode"] = %entry.statusCode
    result["latency"] = %entry.latency
    result["success"] = %entry.success
  of cetPacResult:
    result["pacKey"] = %entry.pacKey
    result["pacUrl"] = %entry.pacUrl
    result["targetUrl"] = %entry.targetUrl
    result["foundProxy"] = %entry.foundProxy

proc deserializeEntry(json: JsonNode): ProxyCacheEntry =
  ## JSONからエントリを復元します
  try:
    let entryType = parseEnum[CacheEntryType](json["entryType"].getStr)
    result = ProxyCacheEntry(
      createdAt: parse($json["createdAt"].getStr, "yyyy-MM-dd\'T\'HH:mm:sszzz"),
      lastAccessedAt: parse($json["lastAccessedAt"].getStr, "yyyy-MM-dd\'T\'HH:mm:sszzz"),
      accessCount: json["accessCount"].getInt,
      entryType: entryType
    )
    
    if json.hasKey("expiresAt"):
      result.expiresAt = some(parse(json["expiresAt"].getStr, "yyyy-MM-dd\'T\'HH:mm:sszzz"))
    
    case entryType:
    of cetProxyConfig:
      result.configKey = json["configKey"].getStr
      if json.hasKey("httpProxy"):
        let http = json["httpProxy"]
        result.httpProxySettings = some(HttpProxySettings(
          host: http["host"].getStr,
          port: http["port"].getInt,
          username: http["username"].getStr,
          authScheme: parseEnum[HttpProxyAuthScheme](http["authScheme"].getStr),
          connectionMode: parseEnum[HttpProxyConnectionMode](http["connectionMode"].getStr)
        ))
      if json.hasKey("socksProxy"):
        let socks = json["socksProxy"]
        result.socksProxySettings = some(SocksProxySettings(
          host: socks["host"].getStr,
          port: socks["port"].getInt,
          username: socks["username"].getStr,
          version: socks["version"].getInt
        ))
    of cetProxyResult:
      result.resultKey = json["resultKey"].getStr
      result.requestUrl = json["requestUrl"].getStr
      result.statusCode = json["statusCode"].getInt
      result.latency = json["latency"].getInt
      result.success = json["success"].getBool
    of cetPacResult:
      result.pacKey = json["pacKey"].getStr
      result.pacUrl = json["pacUrl"].getStr
      result.targetUrl = json["targetUrl"].getStr
      result.foundProxy = json["foundProxy"].getStr
  except:
    return nil

proc saveToDisk(cache: ProxyCache, key: string, entry: ProxyCacheEntry) =
  ## エントリをディスクに保存します
  if cache.config.storageType != cstDisk:
    return
  
  try:
    let filePath = cache.getCacheFilePath(key)
    let json = serializeEntry(entry)
    writeFile(filePath, $json)
  except:
    cache.logger.log(lvlError, "キャッシュエントリをディスクに保存できませんでした: " & getCurrentExceptionMsg())

proc loadFromDisk(cache: ProxyCache, key: string): ProxyCacheEntry =
  ## ディスクからエントリを読み込みます
  if cache.config.storageType != cstDisk:
    return nil
  
  let filePath = cache.getCacheFilePath(key)
  if not fileExists(filePath):
    return nil
  
  try:
    let content = readFile(filePath)
    let json = parseJson(content)
    result = deserializeEntry(json)
  except:
    cache.logger.log(lvlError, "ディスクからキャッシュエントリを読み込めませんでした: " & getCurrentExceptionMsg())
    return nil

proc addEntry*(cache: ProxyCache, key: string, entry: ProxyCacheEntry): bool =
  ## キャッシュにエントリを追加します
  if not cache.config.enabled:
    return false
  
  # キャッシュが最大容量に達している場合は古いエントリを削除
  if cache.memoryEntries.len >= cache.config.maxEntries:
    var oldestKey = ""
    var oldestTime = now()
    
    for k, v in cache.memoryEntries:
      if v.lastAccessedAt < oldestTime:
        oldestTime = v.lastAccessedAt
        oldestKey = k
    
    if oldestKey.len > 0:
      cache.memoryEntries.del(oldestKey)
  
  cache.memoryEntries[key] = entry
  
  # ディスクキャッシュの場合は保存
  if cache.config.storageType == cstDisk:
    cache.saveToDisk(key, entry)
  
  return true

proc getEntry*(cache: ProxyCache, key: string): Option[ProxyCacheEntry] =
  ## キャッシュからエントリを取得します
  if not cache.config.enabled:
    return none(ProxyCacheEntry)
  
  # メモリキャッシュからチェック
  if cache.memoryEntries.hasKey(key):
    let entry = cache.memoryEntries[key]
    let state = entry.getEntryState()
    
    if state == cesValid:
      # アクセス情報を更新
      entry.lastAccessedAt = now()
      entry.accessCount += 1
      return some(entry)
    elif state == cesExpired:
      # 期限切れだが使用可能
      cache.logger.log(lvlDebug, "期限切れのキャッシュエントリを使用: " & key)
      entry.lastAccessedAt = now()
      entry.accessCount += 1
      return some(entry)
    else:
      # 無効なエントリを削除
      cache.memoryEntries.del(key)
  
  # ディスクキャッシュをチェック
  if cache.config.storageType == cstDisk:
    let entry = cache.loadFromDisk(key)
    if not entry.isNil:
      let state = entry.getEntryState()
      
      if state in {cesValid, cesExpired}:
        # メモリキャッシュに追加
        entry.lastAccessedAt = now()
        entry.accessCount += 1
        cache.memoryEntries[key] = entry
        return some(entry)
  
  return none(ProxyCacheEntry)

proc calculateTTL(cache: ProxyCache, entryType: CacheEntryType): int =
  ## エントリタイプに基づいてTTLを計算します
  case entryType:
  of cetProxyConfig:
    result = cache.config.configTTL
  of cetProxyResult:
    result = cache.config.resultTTL
  of cetPacResult:
    result = cache.config.pacTTL
  
  if result <= 0:
    result = cache.config.defaultTTL

proc cacheProxyConfig*(cache: ProxyCache, configId: string, 
                     httpSettings: Option[HttpProxySettings] = none(HttpProxySettings),
                     socksSettings: Option[SocksProxySettings] = none(SocksProxySettings)): bool =
  ## プロキシ設定をキャッシュします
  if not cache.config.enabled:
    return false
  
  let ttl = cache.calculateTTL(cetProxyConfig)
  let currentTime = now()
  let expiresAt = currentTime + initTimeInterval(seconds = ttl)
  
  let entry = ProxyCacheEntry(
    entryType: cetProxyConfig,
    createdAt: currentTime,
    lastAccessedAt: currentTime,
    expiresAt: some(expiresAt),
    accessCount: 1,
    configKey: configId,
    httpProxySettings: httpSettings,
    socksProxySettings: socksSettings
  )
  
  let key = "config:" & configId
  return cache.addEntry(key, entry)

proc getCachedProxyConfig*(cache: ProxyCache, configId: string): tuple[http: Option[HttpProxySettings], socks: Option[SocksProxySettings]] =
  ## キャッシュからプロキシ設定を取得します
  result = (http: none(HttpProxySettings), socks: none(SocksProxySettings))
  
  if not cache.config.enabled:
    return
  
  let key = "config:" & configId
  let entryOpt = cache.getEntry(key)
  
  if entryOpt.isSome and entryOpt.get.entryType == cetProxyConfig:
    let entry = entryOpt.get
    result.http = entry.httpProxySettings
    result.socks = entry.socksProxySettings

proc cacheProxyResult*(cache: ProxyCache, url: string, statusCode: int, 
                      latency: int, success: bool, additionalData: string = ""): bool =
  ## プロキシリクエスト結果をキャッシュします
  if not cache.config.enabled:
    return false
  
  let ttl = cache.calculateTTL(cetProxyResult)
  let currentTime = now()
  let expiresAt = currentTime + initTimeInterval(seconds = ttl)
  let resultKey = generateKey(url, additionalData)
  
  let entry = ProxyCacheEntry(
    entryType: cetProxyResult,
    createdAt: currentTime,
    lastAccessedAt: currentTime,
    expiresAt: some(expiresAt),
    accessCount: 1,
    resultKey: resultKey,
    requestUrl: url,
    statusCode: statusCode,
    latency: latency,
    success: success
  )
  
  let key = "result:" & resultKey
  return cache.addEntry(key, entry)

proc getCachedProxyResult*(cache: ProxyCache, url: string, additionalData: string = ""): Option[ProxyCacheEntry] =
  ## キャッシュからプロキシリクエスト結果を取得します
  if not cache.config.enabled:
    return none(ProxyCacheEntry)
  
  let resultKey = generateKey(url, additionalData)
  let key = "result:" & resultKey
  
  let entryOpt = cache.getEntry(key)
  if entryOpt.isSome and entryOpt.get.entryType == cetProxyResult:
    return entryOpt
  
  return none(ProxyCacheEntry)

proc cachePacResult*(cache: ProxyCache, pacUrl: string, targetUrl: string, foundProxy: string): bool =
  ## PAC評価結果をキャッシュします
  if not cache.config.enabled:
    return false
  
  let ttl = cache.calculateTTL(cetPacResult)
  let currentTime = now()
  let expiresAt = currentTime + initTimeInterval(seconds = ttl)
  let pacKey = generateKey(pacUrl, targetUrl)
  
  let entry = ProxyCacheEntry(
    entryType: cetPacResult,
    createdAt: currentTime,
    lastAccessedAt: currentTime,
    expiresAt: some(expiresAt),
    accessCount: 1,
    pacKey: pacKey,
    pacUrl: pacUrl,
    targetUrl: targetUrl,
    foundProxy: foundProxy
  )
  
  let key = "pac:" & pacKey
  return cache.addEntry(key, entry)

proc getCachedPacResult*(cache: ProxyCache, pacUrl: string, targetUrl: string): Option[string] =
  ## キャッシュからPAC評価結果を取得します
  if not cache.config.enabled:
    return none(string)
  
  let pacKey = generateKey(pacUrl, targetUrl)
  let key = "pac:" & pacKey
  
  let entryOpt = cache.getEntry(key)
  if entryOpt.isSome and entryOpt.get.entryType == cetPacResult:
    return some(entryOpt.get.foundProxy)
  
  return none(string)

proc invalidateEntry*(cache: ProxyCache, key: string): bool =
  ## キャッシュエントリを無効化します
  if not cache.config.enabled:
    return false
  
  var found = false
  
  # メモリキャッシュから削除
  if cache.memoryEntries.hasKey(key):
    cache.memoryEntries.del(key)
    found = true
  
  # ディスクキャッシュから削除
  if cache.config.storageType == cstDisk:
    let filePath = cache.getCacheFilePath(key)
    if fileExists(filePath):
      try:
        removeFile(filePath)
        found = true
      except:
        cache.logger.log(lvlError, "ディスクキャッシュからエントリを削除できませんでした: " & getCurrentExceptionMsg())
  
  return found

proc invalidateConfigCache*(cache: ProxyCache, configId: string): bool =
  ## 設定キャッシュを無効化します
  let key = "config:" & configId
  return cache.invalidateEntry(key)

proc invalidateResultCache*(cache: ProxyCache, url: string, additionalData: string = ""): bool =
  ## 結果キャッシュを無効化します
  let resultKey = generateKey(url, additionalData)
  let key = "result:" & resultKey
  return cache.invalidateEntry(key)

proc invalidatePacCache*(cache: ProxyCache, pacUrl: string, targetUrl: string): bool =
  ## PACキャッシュを無効化します
  let pacKey = generateKey(pacUrl, targetUrl)
  let key = "pac:" & pacKey
  return cache.invalidateEntry(key)

proc cleanupExpiredEntries*(cache: ProxyCache) =
  ## 期限切れのエントリをクリーンアップします
  if not cache.config.enabled:
    return
  
  let currentTime = now()
  
  # 最後のクリーンアップからの経過時間をチェック
  let timeSinceLastCleanup = currentTime - cache.lastCleanupTime
  if timeSinceLastCleanup.inSeconds < cache.config.cleanupInterval:
    return
  
  cache.logger.log(lvlDebug, "期限切れのキャッシュエントリをクリーンアップしています...")
  
  # メモリキャッシュのクリーンアップ
  var keysToRemove: seq[string] = @[]
  for key, entry in cache.memoryEntries:
    if entry.getEntryState() == cesInvalid:
      keysToRemove.add(key)
  
  for key in keysToRemove:
    cache.memoryEntries.del(key)
  
  # ディスクキャッシュのクリーンアップ
  if cache.config.storageType == cstDisk:
    try:
      for kind, path in walkDir(cache.config.diskCachePath):
        if kind == pcFile and path.endsWith(".json"):
          try:
            let content = readFile(path)
            let json = parseJson(content)
            let entry = deserializeEntry(json)
            
            if not entry.isNil and entry.getEntryState() == cesInvalid:
              removeFile(path)
          except:
            cache.logger.log(lvlError, "ディスクキャッシュエントリの処理中にエラーが発生しました: " & getCurrentExceptionMsg())
    except:
      cache.logger.log(lvlError, "ディスクキャッシュのクリーンアップ中にエラーが発生しました: " & getCurrentExceptionMsg())
  
  cache.lastCleanupTime = currentTime
  cache.logger.log(lvlDebug, "キャッシュのクリーンアップが完了しました。" & $keysToRemove.len & "個のエントリを削除しました。")

proc getStats*(cache: ProxyCache): JsonNode =
  ## キャッシュの統計情報を取得します
  var configEntries = 0
  var resultEntries = 0
  var pacEntries = 0
  var validEntries = 0
  var expiredEntries = 0
  
  for key, entry in cache.memoryEntries:
    case entry.entryType:
    of cetProxyConfig: configEntries += 1
    of cetProxyResult: resultEntries += 1
    of cetPacResult: pacEntries += 1
    
    case entry.getEntryState():
    of cesValid: validEntries += 1
    of cesExpired: expiredEntries += 1
    else: discard
  
  result = %*{
    "totalEntries": cache.memoryEntries.len,
    "configEntries": configEntries,
    "resultEntries": resultEntries,
    "pacEntries": pacEntries,
    "validEntries": validEntries,
    "expiredEntries": expiredEntries,
    "storageType": $cache.config.storageType,
    "enabled": cache.config.enabled,
    "lastCleanupTime": $cache.lastCleanupTime
  }

proc clearCache*(cache: ProxyCache): int =
  ## キャッシュをクリアします
  if not cache.config.enabled:
    return 0
  
  result = cache.memoryEntries.len
  cache.memoryEntries.clear()
  
  # ディスクキャッシュをクリア
  if cache.config.storageType == cstDisk:
    try:
      for kind, path in walkDir(cache.config.diskCachePath):
        if kind == pcFile and path.endsWith(".json"):
          try:
            removeFile(path)
          except:
            cache.logger.log(lvlError, "ディスクキャッシュファイルの削除中にエラーが発生しました: " & getCurrentExceptionMsg())
    except:
      cache.logger.log(lvlError, "ディスクキャッシュのクリア中にエラーが発生しました: " & getCurrentExceptionMsg())
  
  cache.lastCleanupTime = now()
  cache.logger.log(lvlInfo, "キャッシュをクリアしました。" & $result & "個のエントリを削除しました。") 