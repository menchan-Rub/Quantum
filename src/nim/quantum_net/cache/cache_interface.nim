## quantum_net/cache/cache_interface.nim
## 
## HTTP/3キャッシュインターフェース
## 高性能でスケーラブルなキャッシュシステムの基礎を定義

import std/[
  times,
  options,
  tables,
  hashes,
  strutils,
  uri,
  asyncdispatch
]

type
  CacheEntryStatus* = enum
    ## キャッシュエントリのステータス
    cesValid,        ## 有効
    cesStale,        ## 古い (期限切れだが条件付きで使用可能)
    cesExpired,      ## 期限切れ
    cesInvalid,      ## 無効
    cesError         ## エラー

  CachePolicy* = enum
    ## キャッシュポリシー
    cpNoStore,       ## キャッシュしない
    cpNoCache,       ## 毎回再検証が必要
    cpPublic,        ## 共有キャッシュにキャッシュ可能
    cpPrivate,       ## プライベートキャッシュにのみキャッシュ可能
    cpImmutable      ## 不変（将来変更されない）

  CachePriority* = enum
    ## キャッシュの優先度
    cpLowest = 0,    ## 最低優先度
    cpLow = 25,      ## 低優先度
    cpNormal = 50,   ## 通常優先度
    cpHigh = 75,     ## 高優先度
    cpHighest = 100  ## 最高優先度

  CacheEntryType* = enum
    ## キャッシュエントリのタイプ
    cetResource,     ## リソース (HTML, CSS, JS, 画像など)
    cetResponse,     ## HTTPレスポンス
    cetHeader,       ## HTTPヘッダー
    cetPushPromise,  ## HTTPプッシュプロミス
    cetWebTransport  ## WebTransportデータ

  CacheDirective* = object
    ## キャッシュ指示
    name*: string
    value*: string

  CacheValidator* = object
    ## キャッシュ検証情報
    etag*: string                ## Entity Tag
    lastModified*: Option[Time]  ## 最終更新時間

  CacheEntry* = ref object of RootObj
    ## キャッシュエントリ基底クラス
    url*: string                 ## URL
    entryType*: CacheEntryType   ## エントリタイプ
    created*: Time               ## 作成時間
    lastAccessed*: Time          ## 最終アクセス時間
    expiresAt*: Time             ## 有効期限
    size*: int                   ## サイズ (バイト)
    accessCount*: int            ## アクセス回数
    policy*: CachePolicy         ## キャッシュポリシー
    priority*: CachePriority     ## 優先度
    validator*: CacheValidator   ## 検証情報
    isCompressed*: bool          ## 圧縮されているか
    variantId*: string           ## バリアントID (コンテンツネゴシエーション用)
    directives*: seq[CacheDirective] ## キャッシュ指示

  ResourceCacheEntry* = ref object of CacheEntry
    ## リソースキャッシュエントリ
    data*: seq[byte]             ## リソースデータ
    contentType*: string         ## コンテンツタイプ
    contentEncoding*: string     ## コンテンツエンコーディング

  ResponseCacheEntry* = ref object of CacheEntry
    ## HTTPレスポンスキャッシュエントリ
    statusCode*: int             ## ステータスコード
    headers*: seq[tuple[name: string, value: string]] ## レスポンスヘッダー
    body*: seq[byte]             ## レスポンスボディ

  HeaderCacheEntry* = ref object of CacheEntry
    ## HTTPヘッダーキャッシュエントリ
    headers*: seq[tuple[name: string, value: string]] ## HTTPヘッダー

  PushPromiseCacheEntry* = ref object of CacheEntry
    ## HTTPプッシュプロミスキャッシュエントリ
    headers*: seq[tuple[name: string, value: string]] ## プロミスヘッダー
    referrerUrl*: string         ## 参照元URL

  WebTransportCacheEntry* = ref object of CacheEntry
    ## WebTransportキャッシュエントリ
    sessionId*: string           ## セッションID
    data*: seq[byte]             ## セッションデータ

  CacheStorageType* = enum
    ## キャッシュストレージタイプ
    cstMemory,                   ## メモリキャッシュ
    cstDisk,                     ## ディスクキャッシュ
    cstHybrid                    ## ハイブリッドキャッシュ

  CacheEvictionPolicy* = enum
    ## キャッシュ削除ポリシー
    cepLRU,                      ## Least Recently Used (最近最も使われていないものを削除)
    cepLFU,                      ## Least Frequently Used (最も使用頻度が低いものを削除)
    cepFIFO,                     ## First In First Out (最初に入ったものを最初に削除)
    cepWeight                    ## 重み付け (サイズ、優先度、有効期限などの複合要素)

  CacheStats* = object
    ## キャッシュ統計情報
    hits*: int                   ## ヒット数
    misses*: int                 ## ミス数
    entries*: int                ## エントリ数
    size*: int                   ## 使用サイズ (バイト)
    maxSize*: int                ## 最大サイズ (バイト)
    insertions*: int             ## 挿入数
    evictions*: int              ## 削除数
    invalidations*: int          ## 無効化数
    hitRatio*: float             ## ヒット率

  CacheOptions* = object
    ## キャッシュオプション
    maxSize*: int                ## 最大サイズ (バイト)
    maxEntries*: int             ## 最大エントリ数
    defaultTtl*: int             ## デフォルトのTTL (秒)
    storageType*: CacheStorageType ## ストレージタイプ
    evictionPolicy*: CacheEvictionPolicy ## 削除ポリシー
    compressionEnabled*: bool    ## 圧縮が有効か
    persistenceEnabled*: bool    ## 永続化が有効か
    persistencePath*: string     ## 永続化パス

  CacheInterface* = ref object of RootObj
    ## キャッシュインターフェース
    options*: CacheOptions       ## キャッシュオプション
    stats*: CacheStats           ## 統計情報

# キャッシュインターフェースのメソッド（抽象メソッド）

method get*(cache: CacheInterface, url: string): Future[Option[CacheEntry]] {.base, async.} =
  ## URL指定でキャッシュエントリを取得
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

method put*(cache: CacheInterface, entry: CacheEntry): Future[bool] {.base, async.} =
  ## キャッシュエントリを保存
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

method delete*(cache: CacheInterface, url: string): Future[bool] {.base, async.} =
  ## URL指定でキャッシュエントリを削除
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

method clear*(cache: CacheInterface): Future[void] {.base, async.} =
  ## キャッシュをクリア
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

method contains*(cache: CacheInterface, url: string): Future[bool] {.base, async.} =
  ## URL指定でキャッシュエントリが存在するか確認
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

method refresh*(cache: CacheInterface, url: string, newData: CacheEntry): Future[bool] {.base, async.} =
  ## キャッシュエントリを更新
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

method getStats*(cache: CacheInterface): CacheStats {.base.} =
  ## キャッシュの統計情報を取得
  return cache.stats

method getStatus*(cache: CacheInterface, url: string): Future[CacheEntryStatus] {.base, async.} =
  ## URL指定でキャッシュエントリのステータスを取得
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

method purgeExpired*(cache: CacheInterface): Future[int] {.base, async.} =
  ## 期限切れのキャッシュエントリを削除
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

method persist*(cache: CacheInterface): Future[bool] {.base, async.} =
  ## キャッシュを永続化
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

method restore*(cache: CacheInterface): Future[bool] {.base, async.} =
  ## キャッシュを復元
  ## 抽象メソッド：サブクラスで実装する必要がある
  raise newException(NotImplementedError, "Method not implemented")

# ユーティリティ関数

proc isExpired*(entry: CacheEntry): bool =
  ## キャッシュエントリが期限切れかどうかを確認
  return getTime() > entry.expiresAt

proc isStale*(entry: CacheEntry): bool =
  ## キャッシュエントリが古いかどうかを確認
  # 期限切れだが、再検証すれば使用可能な状態
  return isExpired(entry) and entry.validator != CacheValidator()

proc getEntryStatus*(entry: CacheEntry): CacheEntryStatus =
  ## キャッシュエントリのステータスを取得
  if entry.isNil:
    return cesInvalid
  
  if entry.policy == cpNoStore or entry.policy == cpNoCache:
    return cesStale  # 常に再検証が必要
  
  if isExpired(entry):
    if isStale(entry):
      return cesStale
    else:
      return cesExpired
  
  return cesValid

proc updateLastAccessed*(entry: CacheEntry) =
  ## 最終アクセス時間を更新
  entry.lastAccessed = getTime()
  entry.accessCount += 1

proc calculateExpiryTime*(maxAge: int): Time =
  ## 有効期限を計算
  result = getTime() + initDuration(seconds = maxAge)

proc createCacheValidator*(etag: string = "", lastModified: Time = Time()): CacheValidator =
  ## キャッシュ検証情報を作成
  result.etag = etag
  if lastModified != Time():
    result.lastModified = some(lastModified)

proc createResourceEntry*(url: string, data: seq[byte], contentType: string, 
                        maxAge: int = 3600, 
                        policy: CachePolicy = cpPublic): ResourceCacheEntry =
  ## リソースキャッシュエントリを作成
  let now = getTime()
  result = ResourceCacheEntry(
    url: url,
    entryType: cetResource,
    created: now,
    lastAccessed: now,
    expiresAt: calculateExpiryTime(maxAge),
    size: data.len,
    accessCount: 0,
    policy: policy,
    priority: cpNormal,
    validator: createCacheValidator(),
    isCompressed: false,
    data: data,
    contentType: contentType,
    contentEncoding: ""
  )

proc createResponseEntry*(url: string, statusCode: int, headers: seq[tuple[name: string, value: string]], 
                         body: seq[byte], maxAge: int = 3600): ResponseCacheEntry =
  ## HTTPレスポンスキャッシュエントリを作成
  let now = getTime()
  
  # キャッシュポリシーを決定
  var policy = cpPublic
  var directives: seq[CacheDirective] = @[]
  var validator = createCacheValidator()
  
  # ヘッダーからキャッシュ関連情報を抽出
  for header in headers:
    case header.name.toLowerAscii()
    of "cache-control":
      let parts = header.value.split(",")
      for part in parts:
        let trimmed = part.strip()
        if trimmed == "no-store":
          policy = cpNoStore
        elif trimmed == "no-cache":
          policy = cpNoCache
        elif trimmed == "private":
          policy = cpPrivate
        elif trimmed == "public":
          policy = cpPublic
        elif trimmed == "immutable":
          policy = cpImmutable
        
        if "=" in trimmed:
          let keyValue = trimmed.split("=", 1)
          directives.add(CacheDirective(name: keyValue[0].strip(), value: keyValue[1].strip()))
        else:
          directives.add(CacheDirective(name: trimmed, value: ""))
    
    of "etag":
      validator.etag = header.value
    
    of "last-modified":
      try:
        # HTTP日付形式のパース
        # ここではシンプル化のため未実装
        discard
      except:
        discard
  
  result = ResponseCacheEntry(
    url: url,
    entryType: cetResponse,
    created: now,
    lastAccessed: now,
    expiresAt: calculateExpiryTime(maxAge),
    size: body.len + headers.len * 64, # 概算
    accessCount: 0,
    policy: policy,
    priority: cpNormal,
    validator: validator,
    isCompressed: false,
    directives: directives,
    statusCode: statusCode,
    headers: headers,
    body: body
  )

proc defaultCacheOptions*(): CacheOptions =
  ## デフォルトのキャッシュオプションを取得
  result = CacheOptions(
    maxSize: 100 * 1024 * 1024, # 100MB
    maxEntries: 10000,
    defaultTtl: 3600, # 1時間
    storageType: cstMemory,
    evictionPolicy: cepLRU,
    compressionEnabled: true,
    persistenceEnabled: false,
    persistencePath: ""
  ) 