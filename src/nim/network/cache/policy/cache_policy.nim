import std/[times, tables, strutils, options]
import ../memory

type
  CacheControlFlags* = enum
    ## HTTPキャッシュ制御フラグ
    ccfPrivate,         # プライベートキャッシュのみが保存可能
    ccfPublic,          # 共有キャッシュで保存可能
    ccfNoCache,         # 再検証なしでキャッシュから提供できない
    ccfNoStore,         # キャッシュに保存してはならない
    ccfNoTransform,     # プロキシが内容を変換してはならない
    ccfMustRevalidate,  # 期限切れの場合、必ず再検証する
    ccfProxyRevalidate, # 共有キャッシュに対する再検証要求
    ccfImmutable,       # リソースが変更されないことを示す
    ccfOnlyIfCached     # キャッシュからのみレスポンスを返す

  CachePolicy* = object
    ## キャッシュの動作を制御するポリシー
    maxAgeSec*: int                 # キャッシュの有効期間（秒）
    staleWhileRevalidateSec*: int   # 再検証中に古いコンテンツを提供できる期間（秒）
    staleIfErrorSec*: int           # エラー時に古いコンテンツを提供できる期間（秒）
    minFreshSec*: int               # 最小フレッシュ時間（秒）
    maxStaleSec*: int               # 許容される古さの最大値（秒）
    flags*: set[CacheControlFlags]  # キャッシュ制御フラグ

  CachePolicyResult* = enum
    ## キャッシュポリシーの評価結果
    cprMustFetch,       # 必ずオリジンからフェッチする
    cprCanUseStored,    # 保存されたレスポンスを使用可能
    cprMustRevalidate   # 再検証が必要

proc newCachePolicy*(): CachePolicy =
  ## デフォルトのキャッシュポリシーを作成する
  result = CachePolicy(
    maxAgeSec: -1,
    staleWhileRevalidateSec: 0,
    staleIfErrorSec: 0,
    minFreshSec: 0,
    maxStaleSec: 0,
    flags: {}
  )

proc parseCacheControl*(header: string): CachePolicy =
  ## Cache-Controlヘッダーからポリシーを解析する
  result = newCachePolicy()
  
  if header.len == 0:
    return
  
  let directives = header.split(',')
  for directive in directives:
    let parts = directive.strip().split('=', 1)
    let name = parts[0].strip().toLowerAscii()
    
    case name
    of "private":
      result.flags.incl(ccfPrivate)
    of "public":
      result.flags.incl(ccfPublic)
    of "no-cache":
      result.flags.incl(ccfNoCache)
    of "no-store":
      result.flags.incl(ccfNoStore)
    of "no-transform":
      result.flags.incl(ccfNoTransform)
    of "must-revalidate":
      result.flags.incl(ccfMustRevalidate)
    of "proxy-revalidate":
      result.flags.incl(ccfProxyRevalidate)
    of "immutable":
      result.flags.incl(ccfImmutable)
    of "only-if-cached":
      result.flags.incl(ccfOnlyIfCached)
    of "max-age":
      if parts.len > 1:
        try:
          result.maxAgeSec = parseInt(parts[1].strip())
        except:
          discard
    of "s-maxage":
      if parts.len > 1:
        try:
          # 共有キャッシュ用のmax-age（ブラウザでは通常無視）
          discard
        except:
          discard
    of "stale-while-revalidate":
      if parts.len > 1:
        try:
          result.staleWhileRevalidateSec = parseInt(parts[1].strip())
        except:
          discard
    of "stale-if-error":
      if parts.len > 1:
        try:
          result.staleIfErrorSec = parseInt(parts[1].strip())
        except:
          discard
    of "min-fresh":
      if parts.len > 1:
        try:
          result.minFreshSec = parseInt(parts[1].strip())
        except:
          discard
    of "max-stale":
      if parts.len > 1:
        try:
          result.maxStaleSec = parseInt(parts[1].strip())
        except:
          discard
      else:
        # 値なしの場合は無制限
        result.maxStaleSec = high(int)
    else:
      # 不明なディレクティブは無視
      discard

proc parsePragma*(header: string): CachePolicy =
  ## Pragmaヘッダーからポリシーを解析する
  result = newCachePolicy()
  
  if header.len == 0:
    return
  
  let directives = header.split(',')
  for directive in directives:
    let name = directive.strip().toLowerAscii()
    if name == "no-cache":
      result.flags.incl(ccfNoCache)

proc calculateFreshnessLifetime*(
  responseTime: Time,
  maxAge: int,
  expires: Option[Time],
  lastModified: Option[Time]
): int =
  ## レスポンスのフレッシュネス寿命を計算する
  ##
  ## 優先順位:
  ## 1. Cache-Controlのmax-age
  ## 2. Expiresヘッダー
  ## 3. Last-Modifiedに基づくヒューリスティック
  
  # 1. Cache-Controlのmax-age
  if maxAge >= 0:
    return maxAge
  
  # 2. Expiresヘッダーがある場合
  if expires.isSome:
    let expiresTime = expires.get()
    # レスポンス時間より過去の場合は期限切れ
    if expiresTime <= responseTime:
      return 0
    else:
      return (expiresTime - responseTime).inSeconds.int
  
  # 3. Last-Modifiedに基づくヒューリスティック
  if lastModified.isSome:
    let lastModifiedTime = lastModified.get()
    if lastModifiedTime < responseTime:
      # Last-Modifiedからの経過時間の10%をフレッシュネス寿命とする
      let delta = (responseTime - lastModifiedTime).inSeconds
      return (delta * 0.1).int
  
  # デフォルト値（保守的に0を返す）
  return 0

proc isFresh*(
  entryAge: int,
  freshnessLifetime: int,
  minFresh: int = 0
): bool =
  ## キャッシュエントリが新鮮かどうかを判断する
  if freshnessLifetime <= 0:
    return false
  
  # 残りのフレッシュネス寿命
  let remainingFreshness = freshnessLifetime - entryAge
  
  # minFreshを考慮
  return remainingFreshness >= minFresh

proc canServeStale*(
  entryAge: int,
  freshnessLifetime: int,
  maxStale: int = 0,
  staleWhileRevalidate: int = 0,
  staleIfError: bool = false,
  staleIfErrorSec: int = 0
): bool =
  ## 古いエントリを提供できるかどうかを判断する
  if freshnessLifetime <= 0:
    return false
  
  # エントリがどれだけ古くなっているか（秒）
  let stalenessSec = entryAge - freshnessLifetime
  if stalenessSec <= 0:
    # エントリは古くなっていない
    return true
  
  # maxStaleを確認（無制限の場合もある）
  if maxStale > 0 and stalenessSec <= maxStale:
    return true
  
  # stale-while-revalidateを確認
  if staleWhileRevalidate > 0 and stalenessSec <= staleWhileRevalidate:
    return true
  
  # stale-if-errorを確認
  if staleIfError and staleIfErrorSec > 0 and stalenessSec <= staleIfErrorSec:
    return true
  
  return false

proc evaluateCachePolicy*(
  requestPolicy: CachePolicy,
  responsePolicy: CachePolicy,
  responseTime: Time,
  currentTime: Time,
  expires: Option[Time] = none(Time),
  lastModified: Option[Time] = none(Time)
): CachePolicyResult =
  ## キャッシュポリシーを評価し、アクションを決定する
  
  # no-storeが設定されている場合は必ずフェッチ
  if ccfNoStore in requestPolicy.flags or ccfNoStore in responsePolicy.flags:
    return cprMustFetch
  
  # only-if-cachedが設定されている場合はストアドレスポンスのみ
  if ccfOnlyIfCached in requestPolicy.flags:
    return cprCanUseStored
  
  # エントリの経過時間を計算
  let entryAge = (currentTime - responseTime).inSeconds.int
  
  # フレッシュネス寿命を計算
  let maxAge = if responsePolicy.maxAgeSec >= 0: responsePolicy.maxAgeSec else: -1
  let freshnessLifetime = calculateFreshnessLifetime(responseTime, maxAge, expires, lastModified)
  
  # no-cacheの場合は再検証が必要
  if ccfNoCache in requestPolicy.flags or ccfNoCache in responsePolicy.flags:
    return cprMustRevalidate
  
  # must-revalidateの場合、期限切れなら再検証
  if ccfMustRevalidate in responsePolicy.flags:
    if not isFresh(entryAge, freshnessLifetime):
      return cprMustRevalidate
  
  # フレッシュかどうか確認（min-freshを考慮）
  if isFresh(entryAge, freshnessLifetime, requestPolicy.minFreshSec):
    # フレッシュならストアドレスポンスを使用
    return cprCanUseStored
  
  # 古いレスポンスを使用できるか確認
  let staleIfError = false  # エラー状態かどうかは外部から渡す必要がある
  if canServeStale(
    entryAge,
    freshnessLifetime,
    requestPolicy.maxStaleSec,
    responsePolicy.staleWhileRevalidateSec,
    staleIfError,
    responsePolicy.staleIfErrorSec
  ):
    return cprCanUseStored
  
  # immutableフラグがある場合、再検証は不要
  if ccfImmutable in responsePolicy.flags:
    return cprCanUseStored
  
  # それ以外の場合は再検証
  return cprMustRevalidate

proc evaluateCacheResponse*(
  meta: CacheEntryMetadata,
  requestHeaders: Table[string, string] = initTable[string, string](),
  currentTime: Time = getTime()
): CachePolicyResult =
  ## キャッシュされたレスポンスを評価し、使用可能かどうかを判断する
  var requestPolicy = newCachePolicy()
  
  # リクエストヘッダーからキャッシュポリシーを解析
  if requestHeaders.hasKey("Cache-Control"):
    requestPolicy = parseCacheControl(requestHeaders["Cache-Control"])
  elif requestHeaders.hasKey("Pragma"):
    requestPolicy = parsePragma(requestHeaders["Pragma"])
  
  # レスポンスポリシーを作成
  var responsePolicy = newCachePolicy()
  if meta.headers.hasKey("Cache-Control"):
    responsePolicy = parseCacheControl(meta.headers["Cache-Control"])
  elif meta.headers.hasKey("Pragma"):
    # Pragmaヘッダーも考慮する
    responsePolicy = parsePragma(meta.headers["Pragma"])
  
  # Expiresヘッダーを解析
  var expires: Option[Time] = none(Time)
  if meta.expires != Time():
    expires = some(meta.expires)
  elif meta.headers.hasKey("Expires"):
    try:
      let parsedTime = parseHttpDate(meta.headers["Expires"])
      expires = some(parsedTime)
    except:
      # 解析エラーの場合は無視
      discard
  
  # Last-Modifiedヘッダーを解析
  var lastModified: Option[Time] = none(Time)
  if meta.lastModified != Time():
    lastModified = some(meta.lastModified)
  elif meta.headers.hasKey("Last-Modified"):
    try:
      let parsedTime = parseHttpDate(meta.headers["Last-Modified"])
      lastModified = some(parsedTime)
    except:
      # 解析エラーの場合は無視
      discard
  
  # レスポンス時間（メタデータに保存されていなければ現在時刻を使用）
  let responseTime = if meta.responseTime != Time():
    meta.responseTime
  elif meta.headers.hasKey("Date"):
    try:
      parseHttpDate(meta.headers["Date"])
    except:
      # 日付解析に失敗した場合はキャッシュ作成時間を使用
      meta.creationTime
  else:
    meta.creationTime
  
  # ETagとIf-None-Matchの処理
  let hasValidator = meta.headers.hasKey("ETag") or lastModified.isSome
  
  # Varyヘッダーの検証
  if meta.headers.hasKey("Vary"):
    let varyFields = meta.headers["Vary"].split(',').mapIt(it.strip().toLowerAscii())
    if "*" in varyFields:
      # Vary: * の場合は常に再検証が必要
      return cprMustRevalidate
    
    # Varyフィールドの値が一致するか確認
    for field in varyFields:
      if field.len > 0:
        let storedValue = if meta.varyValues.hasKey(field): meta.varyValues[field] else: ""
        let currentValue = if requestHeaders.hasKey(field): requestHeaders[field] else: ""
        
        if storedValue != currentValue:
          # Varyフィールドの値が一致しない場合は再取得が必要
          return cprMustFetch
  
  # ポリシーを評価
  let result = evaluateCachePolicy(
    requestPolicy,
    responsePolicy,
    responseTime,
    currentTime,
    expires,
    lastModified
  )
  
  # 条件付きリクエストの最適化
  if result == cprMustRevalidate and hasValidator:
    return cprMustRevalidateWithValidator
  
  return result

proc shouldCacheResponse*(
  statusCode: int,
  method: string,
  responseHeaders: Table[string, string] = initTable[string, string](),
  requestHeaders: Table[string, string] = initTable[string, string]()
): bool =
  ## レスポンスをキャッシュすべきかどうかを判断する
  ## RFC 7234に準拠したキャッシュ可否判定ロジック
  
  # 1. メソッドによる判定（RFC 7231 Section 4.2.3）
  # GETメソッドのみキャッシュ可能（HEADとPOSTは条件付きでキャッシュ可能だが現在は未サポート）
  if method != "GET":
    return false
  
  # 2. ステータスコードによる判定（RFC 7231 Section 6.1）
  let cacheableStatusCodes = [200, 203, 204, 206, 300, 301, 304, 404, 405, 410, 414, 501]
  if statusCode notin cacheableStatusCodes:
    return false
  
  # 3. Cache-Controlディレクティブの解析と評価（RFC 7234 Section 5.2）
  if responseHeaders.hasKey("Cache-Control"):
    let policy = parseCacheControl(responseHeaders["Cache-Control"])
    
    # no-store: 絶対にキャッシュしない
    if ccfNoStore in policy.flags:
      return false
    
    # no-cache: 再検証なしでは使用不可だがキャッシュは可能
    
    # private: ブラウザのプライベートキャッシュには保存可能
    # (共有キャッシュの場合は別処理が必要)
    
    # max-age=0: 実質的に再検証が必要だがキャッシュ自体は可能
    # ただし、実用的には0秒でキャッシュする意味がないためfalseを返す
    if policy.maxAgeSec == 0 and ccfMustRevalidate in policy.flags:
      return false
  
  # 4. Pragma: no-cacheの確認（HTTP/1.0後方互換性、RFC 7234 Section 5.4）
  if responseHeaders.hasKey("Pragma") and 
     "no-cache" in responseHeaders["Pragma"].toLowerAscii():
    # HTTP/1.0との互換性のためにチェック
    # 厳密にはCache-Control: no-cacheと同等（保存可能だが再検証が必要）
    # しかし多くの実装ではno-storeと同様に扱われるため、保守的にfalseを返す
    return false
  # 5. Authorization要求の処理（RFC 7234 Section 3.2）
  if requestHeaders.hasKey("Authorization"):
    # Authorizationヘッダーを含むリクエストは特別な条件下でのみキャッシュ可能
    if responseHeaders.hasKey("Cache-Control"):
      let policy = parseCacheControl(responseHeaders["Cache-Control"])
      # 明示的にキャッシュを許可する指示がある場合のみキャッシュ可能
      if not (ccfPublic in policy.flags or 
              ccfMustRevalidate in policy.flags or 
              policy.maxAgeSec > 0 or 
              policy.sharedMaxAgeSec > 0):
        return false
    else:
      # Cache-Controlがない場合はキャッシュ不可
      return false
  
  # 6. Expiresヘッダーの確認（RFC 7234 Section 5.3）
  # Cache-Controlが優先されるため、Cache-Controlがない場合のみ確認
  if not responseHeaders.hasKey("Cache-Control") and responseHeaders.hasKey("Expires"):
    try:
      let expiresTime = parseHttpDate(responseHeaders["Expires"])
      let currentTime = getTime()
      # 過去の日付や不正な日付の場合はキャッシュ不可
      if expiresTime <= currentTime:
        return false
    except:
      # 日付解析に失敗した場合は保守的にキャッシュ不可
      return false
  
  # 7. ヒューリスティックキャッシュの条件確認
  # Last-Modifiedがあり、Cache-ControlもExpiresもない場合
  if not responseHeaders.hasKey("Cache-Control") and 
     not responseHeaders.hasKey("Expires") and
     responseHeaders.hasKey("Last-Modified"):
    # ヒューリスティックキャッシュが可能
    discard
  
  # 8. Varyヘッダーの特殊処理
  if responseHeaders.hasKey("Vary") and "*" in parseVaryHeader(responseHeaders["Vary"]):
    # Vary: * は全リクエストヘッダーが一致する必要があり、実質的にキャッシュ不可
    return false
  
  # 上記の条件すべてをパスしたらキャッシュ可能
  return true

proc generateCacheKey*(
  url: string,
  method: string = "GET",
  varyHeaders: Table[string, string] = initTable[string, string](),
  isHttps: bool = false
): string =
  ## キャッシュキーを生成する
  ## Varyヘッダーに応じてキーを変化させる
  result = method & ":" & url
  
  # HTTPSとHTTPで区別（必要に応じて）
  if isHttps:
    result &= ":https"
  
  # Varyヘッダーに応じてキーを変化させる
  if varyHeaders.len > 0:
    var varyParts: seq[string] = @[]
    for k, v in varyHeaders:
      varyParts.add(k & "=" & v)
    
    # ソートして順序を一定に
    varyParts.sort()
    result &= ":" & varyParts.join("|")

proc parseVaryHeader*(varyHeader: string): seq[string] =
  ## Varyヘッダーをパースする
  result = @[]
  if varyHeader.len == 0:
    return
  
  let fields = varyHeader.split(',')
  for field in fields:
    let trimmed = field.strip()
    if trimmed.len > 0:
      result.add(trimmed)

proc extractVaryHeadersFromRequest*(
  requestHeaders: Table[string, string],
  varyFields: seq[string]
): Table[string, string] =
  ## リクエストヘッダーからVaryフィールドを抽出する
  result = initTable[string, string]()
  
  for field in varyFields:
    if requestHeaders.hasKey(field):
      result[field] = requestHeaders[field]
    else:
      # ヘッダーが存在しない場合は空の値を設定
      result[field] = ""

when isMainModule:
  # テスト用のメイン関数
  proc testCachePolicy() =
    echo "キャッシュポリシーのテスト"
    
    # Cache-Controlヘッダーのパース
    let header1 = "max-age=3600, must-revalidate"
    let policy1 = parseCacheControl(header1)
    echo "Max-Age: ", policy1.maxAgeSec
    echo "Must-Revalidate: ", ccfMustRevalidate in policy1.flags
    
    let header2 = "no-store, no-cache"
    let policy2 = parseCacheControl(header2)
    echo "No-Store: ", ccfNoStore in policy2.flags
    echo "No-Cache: ", ccfNoCache in policy2.flags
    
    # フレッシュネスの計算
    let now = getTime()
    let responseTime = now - initDuration(minutes = 30)
    let lastModified = some(now - initDuration(days = 2))
    let expires = some(now + initDuration(hours = 1))
    
    let freshness1 = calculateFreshnessLifetime(responseTime, 3600, none(Time), none(Time))
    echo "フレッシュネス（max-age=3600）: ", freshness1, "秒"
    
    let freshness2 = calculateFreshnessLifetime(responseTime, -1, expires, none(Time))
    echo "フレッシュネス（expires=1時間後）: ", freshness2, "秒"
    
    let freshness3 = calculateFreshnessLifetime(responseTime, -1, none(Time), lastModified)
    echo "フレッシュネス（ヒューリスティック）: ", freshness3, "秒"
    
    # フレッシュかどうかのチェック
    let age1 = 1800  # 30分経過
    let age2 = 7200  # 2時間経過
    echo "エントリ1はフレッシュ？: ", isFresh(age1, 3600)  # true
    echo "エントリ2はフレッシュ？: ", isFresh(age2, 3600)  # false
    
    # ポリシー評価
    var reqPolicy = newCachePolicy()
    reqPolicy.maxStaleSec = 600  # 最大10分の古さを許容
    
    var respPolicy = newCachePolicy()
    respPolicy.maxAgeSec = 3600  # 1時間のフレッシュネス
    
    let result1 = evaluateCachePolicy(
      reqPolicy, respPolicy, responseTime, now, none(Time), none(Time)
    )
    echo "評価結果1: ", result1  # cprCanUseStored
    
    respPolicy.flags.incl(ccfNoCache)
    let result2 = evaluateCachePolicy(
      reqPolicy, respPolicy, responseTime, now, none(Time), none(Time)
    )
    echo "評価結果2（no-cache）: ", result2  # cprMustRevalidate
    
    respPolicy.flags.excl(ccfNoCache)
    respPolicy.flags.incl(ccfNoStore)
    let result3 = evaluateCachePolicy(
      reqPolicy, respPolicy, responseTime, now, none(Time), none(Time)
    )
    echo "評価結果3（no-store）: ", result3  # cprMustFetch
    
    # キャッシュキーの生成
    var varyHeaders = {"Accept-Encoding": "gzip", "User-Agent": "TestBrowser"}.toTable
    let key1 = generateCacheKey("https://example.com/", "GET", varyHeaders, true)
    echo "キャッシュキー1: ", key1
    
    let key2 = generateCacheKey("https://example.com/", "GET", initTable[string, string](), true)
    echo "キャッシュキー2: ", key2
    
    # Varyヘッダーのパース
    let varyHeader = "Accept-Encoding, User-Agent, Accept-Language"
    let varyFields = parseVaryHeader(varyHeader)
    echo "Varyフィールド: ", varyFields
    
    # レスポンスをキャッシュすべきか
    let headers = {"Cache-Control": "max-age=3600"}.toTable
    echo "200 OKはキャッシュ可能？: ", shouldCacheResponse(200, "GET", headers)
    echo "404 Not Foundはキャッシュ可能？: ", shouldCacheResponse(404, "GET", headers)
    echo "500 Server Errorはキャッシュ可能？: ", shouldCacheResponse(500, "GET", headers)
    echo "POSTはキャッシュ可能？: ", shouldCacheResponse(200, "POST", headers)
  
  # テスト実行
  testCachePolicy() 