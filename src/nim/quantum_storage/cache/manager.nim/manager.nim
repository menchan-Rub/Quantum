# キャッシュマネージャーモジュール
# ブラウザのキャッシュ管理機能を提供します

import std/[
  os, 
  times, 
  strutils, 
  strformat, 
  tables, 
  json, 
  options, 
  sequtils,
  sugar,
  asyncdispatch,
  httpclient,
  uri,
  parseutils
]

import pkg/[
  chronicles
]

import ../../quantum_utils/[config, files]
import ../common/base
import ./storage

type
  CacheMode* = enum
    ## キャッシュモード
    cmNormal,      # 通常モード（キャッシュ使用）
    cmOffline,     # オフラインモード（キャッシュ優先）
    cmBypassCache, # キャッシュバイパス（常に再取得）
    cmOnlyIfCached # キャッシュのみ使用（ネットワーク不使用）

  ValidationResult* = enum
    ## キャッシュ検証結果
    vrValid,       # 有効
    vrInvalid,     # 無効
    vrNeedsRevalidation, # 再検証が必要
    vrUncacheable  # キャッシュ不可

  CacheContext* = object
    ## リクエストのキャッシュコンテキスト
    url*: string              # リクエストURL
    cacheMode*: CacheMode     # キャッシュモード
    requestHeaders*: Table[string, string] # リクエストヘッダ
    cacheKey*: string         # キャッシュキー
    isFresh*: bool            # フレッシュ判定
    cacheControl*: Table[string, string] # Cache-Control解析結果

  CacheResult* = object
    ## キャッシュ結果
    isHit*: bool             # キャッシュヒットフラグ
    entry*: Option[CacheEntry] # キャッシュエントリ
    needsRevalidation*: bool  # 再検証が必要
    
  CacheRequestOption* = object
    ## キャッシュリクエストオプション
    forceFresh*: bool         # フレッシュ強制フラグ
    acceptStale*: bool        # 期限切れも許可
    priority*: CachePriority  # 優先度
    maxAge*: Option[Duration] # 最大保持期間
    
  CacheManager* = ref object
    ## キャッシュマネージャ
    storage*: CacheStorage    # ストレージ
    httpClient*: AsyncHttpClient # HTTPクライアント
    isEnabled*: bool          # 有効/無効フラグ
    offlineMode*: bool        # オフラインモード
    defaultTtl*: Duration     # デフォルトのTTL
    initialized*: bool        # 初期化済みフラグ

# 定数
const
  # Cache-Control解析用
  MAX_AGE_DIRECTIVE = "max-age"
  NO_CACHE_DIRECTIVE = "no-cache"
  NO_STORE_DIRECTIVE = "no-store"
  MUST_REVALIDATE_DIRECTIVE = "must-revalidate"
  PRIVATE_DIRECTIVE = "private"
  PUBLIC_DIRECTIVE = "public"
  IMMUTABLE_DIRECTIVE = "immutable"
  
  # デフォルト値
  DEFAULT_CACHE_TTL = 4.hours  # デフォルトのTTL
  
  # キャッシュ不可能なステータスコード
  UNCACHEABLE_STATUS_CODES = [204, 206, 303, 305, 400, 401, 403, 404, 405, 407, 409, 410, 411, 412, 413, 414, 415, 416, 417, 418, 500, 501, 502, 503, 504, 505, 507]

# ヘルパー関数
proc parseCacheControl(headers: Table[string, string]): Table[string, string] =
  ## Cache-Controlヘッダーを解析
  result = initTable[string, string]()
  
  if headers.hasKey("Cache-Control"):
    let directivesList = headers["Cache-Control"].split(',')
    
    for directive in directivesList:
      let trimmed = directive.strip()
      let parts = trimmed.split('=', 1)
      
      if parts.len == 1:
        # 値のないディレクティブ（例: no-cache）
        result[parts[0].strip().toLowerAscii()] = ""
      else:
        # 値を持つディレクティブ（例: max-age=3600）
        result[parts[0].strip().toLowerAscii()] = parts[1].strip().toLowerAscii()

proc calculateFreshness(entry: CacheEntry, defaultTtl: Duration): (bool, Duration) =
  ## キャッシュエントリのフレッシュ判定と残り時間
  let now = now()
  
  # 期限切れをチェック
  if entry.metadata.expires.isSome:
    let expires = entry.metadata.expires.get()
    if expires > now:
      # まだ有効
      return (true, expires - now)
    else:
      # 期限切れ
      return (false, Duration())
  
  # Cache-Controlを解析
  let cacheControl = parseCacheControl(entry.metadata.headers)
  
  # max-ageディレクティブをチェック
  if cacheControl.hasKey(MAX_AGE_DIRECTIVE):
    var maxAgeSeconds = 0
    if parseutils.parseInt(cacheControl[MAX_AGE_DIRECTIVE], maxAgeSeconds) > 0:
      let maxAge = maxAgeSeconds.seconds
      let age = now - entry.metadata.created
      
      if age < maxAge:
        # まだフレッシュ
        return (true, maxAge - age)
      else:
        # 期限切れ
        return (false, Duration())
  
  # デフォルトTTLを使用
  let age = now - entry.metadata.created
  if age < defaultTtl:
    return (true, defaultTtl - age)
  else:
    return (false, Duration())

proc isCacheable(statusCode: int, headers: Table[string, string]): bool =
  ## レスポンスがキャッシュ可能かを判定
  # 特定のステータスコードはキャッシュ不可
  if statusCode in UNCACHEABLE_STATUS_CODES:
    return false
  
  # Cache-Controlを解析
  let cacheControl = parseCacheControl(headers)
  
  # no-storeディレクティブがあればキャッシュ不可
  if cacheControl.hasKey(NO_STORE_DIRECTIVE):
    return false
  
  # Pragmaヘッダチェック
  if headers.hasKey("Pragma") and headers["Pragma"] == "no-cache":
    return false
  
  # Authorization付きのリクエストは通常キャッシュ不可
  # ただし、Cache-Controlに明示的なディレクティブがある場合は除く
  if headers.hasKey("Authorization") and
     not (cacheControl.hasKey(PUBLIC_DIRECTIVE) or 
          cacheControl.hasKey(MAX_AGE_DIRECTIVE) or
          cacheControl.hasKey(IMMUTABLE_DIRECTIVE)):
    return false
  
  return true

proc extractResponseHeaders(response: AsyncResponse): Table[string, string] =
  ## HTTPレスポンスからヘッダーテーブルに変換
  result = initTable[string, string]()
  for key, val in response.headers.pairs:
    result[key] = val

proc extractExpirationFromHeaders(headers: Table[string, string], defaultTtl: Duration): Option[DateTime] =
  ## レスポンスヘッダーから有効期限を抽出
  let now = now()
  
  # Cache-Controlを解析
  let cacheControl = parseCacheControl(headers)
  
  # max-ageディレクティブをチェック
  if cacheControl.hasKey(MAX_AGE_DIRECTIVE):
    var maxAgeSeconds = 0
    if parseutils.parseInt(cacheControl[MAX_AGE_DIRECTIVE], maxAgeSeconds) > 0:
      return some(now + maxAgeSeconds.seconds)
  
  # Expiresヘッダをチェック
  if headers.hasKey("Expires"):
    try:
      let expiresTime = times.parse(headers["Expires"], "ddd, dd MMM yyyy HH:mm:ss 'GMT'")
      return some(expiresTime)
    except:
      # 解析失敗した場合
      discard
  
  # デフォルトTTLを使用
  return some(now + defaultTtl)

# CacheManagerの実装
proc newCacheManager*(cacheDir: string): CacheManager =
  ## 新しいキャッシュマネージャを作成
  let storage = newCacheStorage(cacheDir, StorageType.stHybrid)
  let httpClient = newAsyncHttpClient()
  
  result = CacheManager(
    storage: storage,
    httpClient: httpClient,
    isEnabled: true,
    offlineMode: false,
    defaultTtl: DEFAULT_CACHE_TTL,
    initialized: true
  )
  
  # クリーンアップタスク開始
  asyncCheck storage.cleanupTask()
  
  info "Cache manager initialized", 
       cache_dir = cacheDir, 
       entries = storage.stats.entries

proc close*(self: CacheManager) =
  ## マネージャを閉じる
  self.storage.close()
  self.httpClient.close()
  info "Cache manager closed"

proc setEnabled*(self: CacheManager, enabled: bool) =
  ## キャッシュ有効/無効を切り替え
  self.isEnabled = enabled
  info "Cache system", enabled = enabled

proc setOfflineMode*(self: CacheManager, offline: bool) =
  ## オフラインモードを切り替え
  self.offlineMode = offline
  info "Offline mode", enabled = offline

proc setDefaultTtl*(self: CacheManager, ttl: Duration) =
  ## デフォルトTTLを設定
  self.defaultTtl = ttl
  info "Default TTL set", ttl = ttl

proc createCacheContext(self: CacheManager, url: string, cacheMode: CacheMode, 
                       requestHeaders: Table[string, string]): CacheContext =
  ## キャッシュコンテキストを作成
  result = CacheContext(
    url: url,
    cacheMode: cacheMode,
    requestHeaders: requestHeaders,
    cacheKey: generateCacheKey(url),
    isFresh: false,
    cacheControl: parseCacheControl(requestHeaders)
  )

proc validateCache*(self: CacheManager, context: CacheContext, entry: CacheEntry): ValidationResult =
  ## キャッシュエントリが有効かを検証
  # キャッシュバイパスモードの場合は無効
  if context.cacheMode == CacheMode.cmBypassCache:
    return ValidationResult.vrInvalid
    
  # 強制再検証ディレクティブをチェック
  let cacheControl = context.cacheControl
  if cacheControl.hasKey(NO_CACHE_DIRECTIVE):
    return ValidationResult.vrNeedsRevalidation
  
  # Cache-Controlのmax-ageディレクティブをチェック
  if cacheControl.hasKey(MAX_AGE_DIRECTIVE):
    var maxAgeSeconds = 0
    if parseutils.parseInt(cacheControl[MAX_AGE_DIRECTIVE], maxAgeSeconds) > 0:
      let age = now() - entry.metadata.created
      if age > maxAgeSeconds.seconds:
        return ValidationResult.vrNeedsRevalidation
  
  # フレッシュ判定
  let (isFresh, _) = calculateFreshness(entry, self.defaultTtl)
  
  # オフラインモードの場合、または「キャッシュのみ」モードの場合は期限切れでも有効
  if self.offlineMode or context.cacheMode == CacheMode.cmOnlyIfCached:
    return ValidationResult.vrValid
  
  # 通常はフレッシュかどうかで判断
  if isFresh:
    return ValidationResult.vrValid
  else:
    # レスポンスヘッダからmust-revalidateチェック
    let responseCacheControl = parseCacheControl(entry.metadata.headers)
    if responseCacheControl.hasKey(MUST_REVALIDATE_DIRECTIVE):
      return ValidationResult.vrNeedsRevalidation
    else:
      # 期限切れているが再検証必須ではない場合
      return ValidationResult.vrNeedsRevalidation

proc getCachedResponse*(self: CacheManager, url: string, 
                       cacheMode: CacheMode = CacheMode.cmNormal,
                       requestHeaders: Table[string, string] = initTable[string, string]()): CacheResult =
  ## URLに対するキャッシュレスポンスを取得
  result = CacheResult(
    isHit: false,
    entry: none(CacheEntry),
    needsRevalidation: false
  )
  
  # キャッシュ無効またはバイパスモードの場合
  if not self.isEnabled or cacheMode == CacheMode.cmBypassCache:
    return result
  
  # コンテキスト作成
  let context = self.createCacheContext(url, cacheMode, requestHeaders)
  
  # キャッシュ検索
  let cachedEntryOption = self.storage.get(context.cacheKey)
  if cachedEntryOption.isNone:
    return result
  
  let cachedEntry = cachedEntryOption.get()
  
  # 検証
  let validationResult = self.validateCache(context, cachedEntry)
  case validationResult:
    of ValidationResult.vrValid:
      # 有効なキャッシュ
      result.isHit = true
      result.entry = some(cachedEntry)
      result.needsRevalidation = false
      
    of ValidationResult.vrNeedsRevalidation:
      # 再検証が必要
      result.isHit = true
      result.entry = some(cachedEntry)
      result.needsRevalidation = true
      
    of ValidationResult.vrInvalid, ValidationResult.vrUncacheable:
      # 無効なキャッシュ
      discard
  
  if result.isHit:
    info "Cache hit", url = url, needs_revalidation = result.needsRevalidation
  else:
    info "Cache miss", url = url

proc addToCache*(self: CacheManager, url: string, content: string, contentType: string, 
                statusCode: int, responseHeaders: Table[string, string], 
                options: CacheRequestOption = CacheRequestOption()): string =
  ## レスポンスをキャッシュに追加
  # キャッシュ無効の場合
  if not self.isEnabled:
    return ""
  
  # キャッシュ可能かどうかチェック
  if not isCacheable(statusCode, responseHeaders):
    info "Response not cacheable", url = url, status = statusCode
    return ""
  
  # 有効期限を抽出
  var 
    effectiveTtl = if options.maxAge.isSome: options.maxAge.get() else: self.defaultTtl
    expires = extractExpirationFromHeaders(responseHeaders, effectiveTtl)
  
  # キャッシュに追加
  let key = self.storage.put(
    url = url,
    data = content,
    contentType = contentType,
    headers = responseHeaders,
    expires = expires,
    priority = options.priority
  )
  
  info "Added to cache", url = url, key = key, expires = if expires.isSome: $expires.get() else: "none"
  return key

proc revalidateCache*(self: CacheManager, entry: CacheEntry): Future[bool] {.async.} =
  ## キャッシュエントリを再検証
  # 検証方法に基づいてリクエストヘッダーを設定
  var headers = newHttpHeaders()
  
  case entry.metadata.validationMethod:
    of CacheValidationMethod.cvmEtag:
      if entry.metadata.etag.len > 0:
        headers["If-None-Match"] = entry.metadata.etag
        info "Revalidating with ETag", url = entry.metadata.url, etag = entry.metadata.etag
      else:
        return false
        
    of CacheValidationMethod.cvmLastModified:
      if entry.metadata.lastModified.len > 0:
        headers["If-Modified-Since"] = entry.metadata.lastModified
        info "Revalidating with Last-Modified", url = entry.metadata.url, last_modified = entry.metadata.lastModified
      else:
        return false
        
    of CacheValidationMethod.cvmNone:
      # 検証方法がない場合は単純に新しいリクエストを行う
      return false
  
  try:
    # 条件付きリクエスト実行
    let response = await self.httpClient.request(
      url = entry.metadata.url,
      httpMethod = HttpGet,
      headers = headers
    )
    
    # 304 Not Modifiedの場合、キャッシュは有効
    if response.code == Http304:
      # 最終アクセス日時だけ更新
      discard self.storage.touch(entry.metadata.key)
      info "Cache revalidated", url = entry.metadata.url
      return true
    
    # その他のレスポンスの場合、キャッシュを更新
    if response.code.is2xx:
      let 
        content = await response.body
        responseHeaders = extractResponseHeaders(response)
        contentType = if responseHeaders.hasKey("Content-Type"): responseHeaders["Content-Type"] else: ""
      
      discard self.addToCache(
        url = entry.metadata.url,
        content = content,
        contentType = contentType,
        statusCode = response.code.int,
        responseHeaders = responseHeaders,
        options = CacheRequestOption(priority: entry.metadata.priority)
      )
      
      info "Cache updated after revalidation", url = entry.metadata.url
      return true
  except:
    error "Failed to revalidate cache", 
          url = entry.metadata.url, 
          error = getCurrentExceptionMsg()
  
  return false

proc clearCache*(self: CacheManager) =
  ## キャッシュをすべてクリア
  self.storage.clear()
  info "Cache cleared"

proc getCacheStats*(self: CacheManager): JsonNode =
  ## キャッシュ統計情報を取得
  return self.storage.getStatsJson()

proc removeCachedItem*(self: CacheManager, url: string): bool =
  ## 指定URLのキャッシュアイテムを削除
  return self.storage.deleteByUrl(url)

proc purgeExpiredItems*(self: CacheManager): int =
  ## 期限切れのアイテムを削除
  return self.storage.purgeExpired()

# 非同期リクエスト処理
proc fetchUrl*(self: CacheManager, url: string, 
              cacheMode: CacheMode = CacheMode.cmNormal,
              requestHeaders: Table[string, string] = initTable[string, string](),
              requestOptions: CacheRequestOption = CacheRequestOption()): Future[tuple[content: string, headers: Table[string, string], fromCache: bool]] {.async.} =
  ## URLからコンテンツを取得（キャッシュ使用）
  # キャッシュチェック
  let cacheResult = self.getCachedResponse(url, cacheMode, requestHeaders)
  
  # キャッシュヒットで再検証が不要な場合
  if cacheResult.isHit and not cacheResult.needsRevalidation:
    let entry = cacheResult.entry.get()
    return (entry.data, entry.metadata.headers, true)
  
  # キャッシュヒットで再検証が必要な場合
  if cacheResult.isHit and cacheResult.needsRevalidation:
    let entry = cacheResult.entry.get()
    
    # オフラインモードなら再検証せずキャッシュを使用
    if self.offlineMode:
      return (entry.data, entry.metadata.headers, true)
    
    # キャッシュのみモードの場合も同様
    if cacheMode == CacheMode.cmOnlyIfCached:
      return (entry.data, entry.metadata.headers, true)
    
    # 再検証
    let revalidated = await self.revalidateCache(entry)
    if revalidated:
      # 再検証成功、最新キャッシュで返す
      let updatedCacheResult = self.getCachedResponse(url, cacheMode, requestHeaders)
      if updatedCacheResult.isHit:
        let updatedEntry = updatedCacheResult.entry.get()
        return (updatedEntry.data, updatedEntry.metadata.headers, true)
      else:
        # 何かの理由でキャッシュが消えた場合は古いエントリを使用
        return (entry.data, entry.metadata.headers, true)
  
  # キャッシュなし、または再検証が必要だがキャッシュが使えない場合
  
  # キャッシュのみモードでキャッシュミスの場合はエラー
  if cacheMode == CacheMode.cmOnlyIfCached:
    raise newException(IOError, "Resource not in cache and only-if-cached specified")
  
  # オフラインモードでキャッシュミスの場合もエラー
  if self.offlineMode:
    raise newException(IOError, "Resource not in cache and offline mode enabled")
  
  # 通常のHTTPリクエスト
  try:
    var headers = newHttpHeaders()
    for k, v in requestHeaders.pairs:
      headers[k] = v
    
    let response = await self.httpClient.request(
      url = url,
      httpMethod = HttpGet,
      headers = headers
    )
    
    if not response.code.is2xx:
      raise newException(IOError, "HTTP error: " & $response.code)
    
    let 
      content = await response.body
      responseHeaders = extractResponseHeaders(response)
      contentType = if responseHeaders.hasKey("Content-Type"): responseHeaders["Content-Type"] else: ""
    
    # 条件に合えばキャッシュする
    if cacheMode != CacheMode.cmBypassCache:
      discard self.addToCache(
        url = url,
        content = content,
        contentType = contentType,
        statusCode = response.code.int,
        responseHeaders = responseHeaders,
        options = requestOptions
      )
    
    return (content, responseHeaders, false)
  except:
    # エラー時にキャッシュがあれば使用
    if cacheResult.isHit:
      let entry = cacheResult.entry.get()
      info "Network error, using stale cache", 
           url = url, error = getCurrentExceptionMsg()
      return (entry.data, entry.metadata.headers, true)
    else:
      raise

# -----------------------------------------------
# テストコード
# -----------------------------------------------

when isMainModule:
  # テスト用コード
  proc testCacheManager() {.async.} =
    # テンポラリディレクトリを使用
    let tempDir = getTempDir() / "cache_manager_test"
    createDir(tempDir)
    
    # キャッシュマネージャ作成
    let manager = newCacheManager(tempDir)
    
    # テストURL
    let testUrl = "https://example.com"
    
    try:
      # 通常モードでフェッチ
      echo "Fetching with normal mode..."
      let result1 = await manager.fetchUrl(testUrl)
      echo "Content length: ", result1.content.len
      echo "From cache: ", result1.fromCache
      
      # 再度フェッチ (キャッシュヒットするはず)
      echo "\nFetching again..."
      let result2 = await manager.fetchUrl(testUrl)
      echo "Content length: ", result2.content.len
      echo "From cache: ", result2.fromCache
      
      # バイパスモードでフェッチ
      echo "\nFetching with bypass mode..."
      let result3 = await manager.fetchUrl(testUrl, CacheMode.cmBypassCache)
      echo "Content length: ", result3.content.len
      echo "From cache: ", result3.fromCache
      
      # 統計表示
      let stats = manager.getCacheStats()
      echo "\nCache stats: ", stats.pretty
      
      # キャッシュアイテム削除
      echo "\nRemoving cache item..."
      echo "Removed: ", manager.removeCachedItem(testUrl)
      
      # 期限切れアイテム削除
      echo "\nPurging expired items..."
      echo "Purged count: ", manager.purgeExpiredItems()
      
    except:
      echo "Error: ", getCurrentExceptionMsg()
    
    # キャッシュクリア
    manager.clearCache()
    
    # マネージャを閉じる
    manager.close()
    
    # テンポラリディレクトリ削除
    removeDir(tempDir)
  
  # テスト実行
  waitFor testCacheManager() 