## quantum_arch/data/sharding.nim
## 
## データシャーディングモジュール
## 複数のスレッドや処理間でのデータ分散を効率的に行います

import std/hashes
import std/tables
import std/locks
import std/options
import atomics
import times
import strformat

type
  ShardKey* = distinct string
  ShardId* = distinct int

  ShardingStrategy* = enum
    ## シャーディング戦略
    ssHash,        ## ハッシュベースのシャーディング
    ssRange,       ## 範囲ベースのシャーディング
    ssConsistent,  ## 一貫性ハッシュのシャーディング
    ssCustom       ## カスタムシャーディング

  ShardConfig* = object
    ## シャードの設定
    id*: ShardId        ## シャードID
    weight*: float      ## シャードの重み
    maxSize*: int       ## 最大サイズ
    isActive*: bool     ## アクティブかどうか

  ShardStats* = object
    ## シャードの統計情報
    itemCount*: int           ## アイテム数
    size*: int                ## 合計サイズ
    hitCount*: int            ## ヒット数
    missCount*: int           ## ミス数
    loadFactor*: float        ## 負荷係数
    avgAccessTime*: float     ## 平均アクセス時間（ミリ秒）

  ShardNode*[T] = ref object
    ## シャードノード
    config: ShardConfig         ## シャード設定
    data: Table[string, T]      ## データテーブル
    lock: Lock                  ## ロック
    stats: ShardStats           ## 統計情報
    lastRebalanceTime: Time     ## 最後の再バランス時間

  ShardingFunction* = proc(key: ShardKey, totalShards: int): ShardId {.nimcall.}
    ## シャーディング関数の型

  DataShard*[T] = ref object
    ## データシャードマネージャー
    shards: seq[ShardNode[T]]     ## シャードのリスト
    strategy: ShardingStrategy    ## シャーディング戦略
    totalShards: int              ## シャードの総数
    defaultShardSize: int         ## デフォルトのシャードサイズ
    rebalanceThreshold: float     ## 再バランス閾値
    customShardingFn: Option[ShardingFunction] ## カスタムシャーディング関数
    lock: Lock                    ## グローバルロック
    isRebalancing: Atomic[bool]   ## 再バランス中かどうか

# ヘルパー関数
proc hash*(key: ShardKey): Hash {.inline.} =
  ## ShardKeyのハッシュ関数
  hash(string(key))

proc `$`*(id: ShardId): string {.inline.} =
  ## ShardIdの文字列表現
  $int(id)

proc `$`*(key: ShardKey): string {.inline.} =
  ## ShardKeyの文字列表現
  string(key)

proc `==`*(a, b: ShardId): bool {.inline.} =
  ## ShardIdの等価演算子
  int(a) == int(b)

proc `==`*(a, b: ShardKey): bool {.inline.} =
  ## ShardKeyの等価演算子
  string(a) == string(b)

# シャーディング関数
proc hashSharding(key: ShardKey, totalShards: int): ShardId =
  ## ハッシュベースのシャーディング
  let h = hash(key)
  ShardId(h mod totalShards)

proc rangeSharding(key: ShardKey, totalShards: int): ShardId =
  ## 範囲ベースのシャーディング
  let strKey = $key
  if strKey.len == 0:
    return ShardId(0)
  
  # 最初の文字に基づいてシャードを決定
  let firstChar = strKey[0].int
  ShardId(firstChar mod totalShards)

proc fnvHash(s: string): uint64 =
  ## FNVハッシュ関数
  const
    prime = 1099511628211'u64
    offset = 14695981039346656037'u64
  
  result = offset
  for c in s:
    result = result xor uint64(c.uint8)
    result = result * prime

proc consistentSharding(key: ShardKey, totalShards: int): ShardId =
  ## 一貫性ハッシュのシャーディング
  const ringSize = 1024
  
  let keyHash = fnvHash($key)
  let position = keyHash mod ringSize
  
  # 擬似的な一貫性ハッシュリングの実装
  let shardPos = position mod uint64(totalShards)
  ShardId(int(shardPos))

# シャードノード関連
proc newShardNode[T](id: int, maxSize: int = 1000): ShardNode[T] =
  ## 新しいシャードノードを作成
  result = ShardNode[T](
    config: ShardConfig(
      id: ShardId(id),
      weight: 1.0,
      maxSize: maxSize,
      isActive: true
    ),
    lastRebalanceTime: getTime()
  )
  result.data = initTable[string, T]()
  initLock(result.lock)
  result.stats = ShardStats()

proc updateStats[T](node: ShardNode[T]) =
  ## シャード統計を更新
  node.stats.itemCount = node.data.len
  node.stats.loadFactor = float(node.stats.itemCount) / float(node.config.maxSize)

proc hit[T](node: ShardNode[T], accessTime: float) =
  ## ヒット情報を更新
  node.stats.hitCount.inc
  
  # 平均アクセス時間の更新
  let totalAccesses = node.stats.hitCount + node.stats.missCount
  if totalAccesses > 0:
    node.stats.avgAccessTime = (node.stats.avgAccessTime * float(totalAccesses - 1) + 
                               accessTime) / float(totalAccesses)

proc miss[T](node: ShardNode[T]) =
  ## ミス情報を更新
  node.stats.missCount.inc

# DataShard関連
proc newDataShard*[T](totalShards: int = 8, 
                     strategy: ShardingStrategy = ssHash,
                     defaultShardSize: int = 1000): DataShard[T] =
  ## 新しいデータシャードを作成
  result = DataShard[T](
    totalShards: totalShards,
    strategy: strategy,
    defaultShardSize: defaultShardSize,
    rebalanceThreshold: 0.7,
    customShardingFn: none(ShardingFunction)
  )
  
  initLock(result.lock)
  result.isRebalancing.store(false)
  
  # シャードを初期化
  result.shards = newSeq[ShardNode[T]](totalShards)
  for i in 0..<totalShards:
    result.shards[i] = newShardNode[T](i, defaultShardSize)

proc setCustomShardingFunction*[T](shard: DataShard[T], fn: ShardingFunction) =
  ## カスタムシャーディング関数を設定
  shard.customShardingFn = some(fn)
  shard.strategy = ssCustom

proc getShardForKey[T](shard: DataShard[T], key: ShardKey): ShardId =
  ## キーに対応するシャードIDを取得
  case shard.strategy
  of ssHash:
    hashSharding(key, shard.totalShards)
  of ssRange:
    rangeSharding(key, shard.totalShards)
  of ssConsistent:
    consistentSharding(key, shard.totalShards)
  of ssCustom:
    if shard.customShardingFn.isSome:
      shard.customShardingFn.get()(key, shard.totalShards)
    else:
      # カスタム関数が設定されていない場合はハッシュに戻る
      hashSharding(key, shard.totalShards)

proc getShardNode[T](shard: DataShard[T], id: ShardId): ShardNode[T] =
  ## シャードIDからノードを取得
  let idx = int(id)
  if idx < 0 or idx >= shard.shards.len:
    return nil
  
  result = shard.shards[idx]

proc get*[T](shard: DataShard[T], key: ShardKey): Option[T] =
  ## キーに対応する値を取得
  let shardId = shard.getShardForKey(key)
  let node = shard.getShardNode(shardId)
  
  if node == nil or not node.config.isActive:
    return none(T)
  
  let startTime = epochTime()
  
  withLock(node.lock):
    let keyStr = $key
    if node.data.hasKey(keyStr):
      let value = node.data[keyStr]
      # 統計情報を更新
      node.hit(epochTime() - startTime)
      return some(value)
    else:
      node.miss()
      return none(T)

proc put*[T](shard: DataShard[T], key: ShardKey, value: T): bool =
  ## 値をシャードに格納
  let shardId = shard.getShardForKey(key)
  let node = shard.getShardNode(shardId)
  
  if node == nil or not node.config.isActive:
    return false
  
  withLock(node.lock):
    let keyStr = $key
    node.data[keyStr] = value
    node.updateStats()
    
    # 負荷係数がしきい値を超えたら再バランスが必要かもしれない
    if node.stats.loadFactor > shard.rebalanceThreshold:
      # ここで再バランスの通知をするか、非同期で再バランスを実行
      discard
      
    return true

proc delete*[T](shard: DataShard[T], key: ShardKey): bool =
  ## キーをシャードから削除
  let shardId = shard.getShardForKey(key)
  let node = shard.getShardNode(shardId)
  
  if node == nil or not node.config.isActive:
    return false
  
  withLock(node.lock):
    let keyStr = $key
    if node.data.hasKey(keyStr):
      node.data.del(keyStr)
      node.updateStats()
      return true
    else:
      return false

proc contains*[T](shard: DataShard[T], key: ShardKey): bool =
  ## キーがシャードに存在するか確認
  let shardId = shard.getShardForKey(key)
  let node = shard.getShardNode(shardId)
  
  if node == nil or not node.config.isActive:
    return false
  
  let startTime = epochTime()
  
  withLock(node.lock):
    let keyStr = $key
    let exists = node.data.hasKey(keyStr)
    
    if exists:
      node.hit(epochTime() - startTime)
    else:
      node.miss()
      
    return exists

proc count*[T](shard: DataShard[T]): int =
  ## シャード内の総アイテム数を取得
  result = 0
  for node in shard.shards:
    withLock(node.lock):
      result += node.stats.itemCount

proc clear*[T](shard: DataShard[T]) =
  ## 全シャードをクリア
  for node in shard.shards:
    withLock(node.lock):
      node.data.clear()
      node.updateStats()

proc deactivateShard*[T](shard: DataShard[T], id: ShardId): bool =
  ## シャードを非アクティブ化
  let node = shard.getShardNode(id)
  if node == nil:
    return false
    
  withLock(node.lock):
    node.config.isActive = false
    return true

proc activateShard*[T](shard: DataShard[T], id: ShardId): bool =
  ## シャードをアクティブ化
  let node = shard.getShardNode(id)
  if node == nil:
    return false
    
  withLock(node.lock):
    node.config.isActive = true
    return true

proc getShardStats*[T](shard: DataShard[T], id: ShardId): Option[ShardStats] =
  ## シャードの統計情報を取得
  let node = shard.getShardNode(id)
  if node == nil:
    return none(ShardStats)
    
  withLock(node.lock):
    node.updateStats()
    return some(node.stats)

proc getAllStats*[T](shard: DataShard[T]): seq[tuple[id: ShardId, stats: ShardStats]] =
  ## 全シャードの統計情報を取得
  result = @[]
  for node in shard.shards:
    withLock(node.lock):
      node.updateStats()
      result.add((node.config.id, node.stats))

proc printStats*[T](shard: DataShard[T]) =
  ## シャードの統計情報を出力
  echo fmt"DataShard Statistics (Strategy: {shard.strategy}, TotalShards: {shard.totalShards})"
  
  let stats = shard.getAllStats()
  for (id, stat) in stats:
    echo fmt"  Shard {id}:"
    echo fmt"    Items: {stat.itemCount}"
    echo fmt"    Hit Rate: {float(stat.hitCount) / max(1, stat.hitCount + stat.missCount) * 100:.2f}%"
    echo fmt"    Avg Access Time: {stat.avgAccessTime:.6f}ms"
    echo fmt"    Load Factor: {stat.loadFactor:.4f}"

# 再バランス関連
proc needsRebalancing*[T](shard: DataShard[T]): bool =
  ## 再バランスが必要かどうかを確認
  var minLoad = float.high
  var maxLoad = 0.0
  
  for node in shard.shards:
    withLock(node.lock):
      node.updateStats()
      if node.stats.loadFactor < minLoad:
        minLoad = node.stats.loadFactor
      if node.stats.loadFactor > maxLoad:
        maxLoad = node.stats.loadFactor
  
  # 最大と最小の負荷の差が閾値を超えるかどうか
  return maxLoad - minLoad > 0.3

proc redistributeData[T](shard: DataShard[T], fromId, toId: ShardId): int =
  ## 一方のシャードから他方へデータを再分配
  let fromNode = shard.getShardNode(fromId)
  let toNode = shard.getShardNode(toId)
  
  if fromNode == nil or toNode == nil or 
     not fromNode.config.isActive or not toNode.config.isActive:
    return 0
    
  # データを一時的なテーブルにコピー
  var keysToMove: seq[string] = @[]
  
  withLock(fromNode.lock):
    # 負荷が高い方から30%のデータを移動
    let targetCount = int(fromNode.stats.itemCount.float * 0.3)
    var count = 0
    
    for k in fromNode.data.keys:
      keysToMove.add(k)
      count.inc
      if count >= targetCount:
        break
  
  # 移動対象のデータを処理
  var movedCount = 0
  
  for k in keysToMove:
    var value: T
    
    # 元のシャードからデータを取得して削除
    withLock(fromNode.lock):
      if not fromNode.data.hasKey(k):
        continue
        
      value = fromNode.data[k]
      fromNode.data.del(k)
      
    # 新しいシャードにデータを追加
    withLock(toNode.lock):
      toNode.data[k] = value
      movedCount.inc
      
  # 統計情報を更新
  withLock(fromNode.lock):
    fromNode.updateStats()
    
  withLock(toNode.lock):
    toNode.updateStats()
    
  return movedCount

proc rebalance*[T](shard: DataShard[T]): bool =
  ## シャード間のデータを再バランス
  # 既に再バランス中なら何もしない
  var expected = false
  if not shard.isRebalancing.compareExchange(expected, true):
    return false
    
  defer: shard.isRebalancing.store(false)
  
  var stats = shard.getAllStats()
  
  # 負荷順にソート
  stats.sort(proc(x, y: tuple[id: ShardId, stats: ShardStats]): int =
    if x.stats.loadFactor < y.stats.loadFactor: -1
    elif x.stats.loadFactor > y.stats.loadFactor: 1
    else: 0
  )
  
  if stats.len < 2:
    return false
    
  # 最も負荷の高いシャードから最も負荷の低いシャードへ再分配
  let fromId = stats[^1].id
  let toId = stats[0].id
  
  let movedCount = shard.redistributeData(fromId, toId)
  return movedCount > 0

# イテレータとユーティリティ
iterator pairs*[T](shard: DataShard[T]): tuple[key: string, value: T] =
  ## シャード内の全データを反復処理
  var buffer = newSeq[tuple[key: string, value: T]]()
  
  # 各シャードからデータを収集
  for node in shard.shards:
    withLock(node.lock):
      for k, v in node.data:
        buffer.add((k, v))
  
  # 収集したデータを反復処理
  for item in buffer:
    yield item

proc forEach*[T](shard: DataShard[T], fn: proc(key: string, value: T) {.closure.}) =
  ## シャード内の全データに関数を適用
  for node in shard.shards:
    var snapshot: seq[tuple[key: string, value: T]] = @[]
    
    # ロックを最小限に抑えるためにスナップショットを作成
    withLock(node.lock):
      for k, v in node.data:
        snapshot.add((k, v))
    
    # ロック外で関数を適用
    for (k, v) in snapshot:
      fn(k, v)

proc findAll*[T](shard: DataShard[T], predicate: proc(key: string, value: T): bool {.closure.}): seq[tuple[key: string, value: T]] =
  ## 条件に合致する全データを検索
  result = @[]
  
  for node in shard.shards:
    var matches: seq[tuple[key: string, value: T]] = @[]
    
    withLock(node.lock):
      for k, v in node.data:
        if predicate(k, v):
          matches.add((k, v))
    
    result.add(matches)

# バックアップと復元
proc exportData*[T](shard: DataShard[T]): Table[string, T] =
  ## シャードデータをエクスポート
  result = initTable[string, T]()
  
  for node in shard.shards:
    withLock(node.lock):
      for k, v in node.data:
        result[k] = v

proc importData*[T](shard: DataShard[T], data: Table[string, T]): int =
  ## データをシャードにインポート
  var importedCount = 0
  
  for k, v in data:
    let keyObj = ShardKey(k)
    if shard.put(keyObj, v):
      importedCount.inc
      
  return importedCount

# シャーディングパフォーマンスベンチマーク
proc benchmark*[T](shard: DataShard[T], 
                   keyCount: int, 
                   getToSetRatio: float = 0.8): tuple[opsPerSec: float, avgLatency: float] =
  ## シャーディングのパフォーマンスベンチマーク
  var totalOps = 0
  var totalTime = 0.0
  let getCount = int(float(keyCount) * getToSetRatio)
  let setCount = keyCount - getCount
  
  # キーを生成
  var keys = newSeq[string](keyCount)
  for i in 0..<keyCount:
    keys[i] = $i
  
  # setベンチマーク
  let startSet = epochTime()
  for i in 0..<setCount:
    let key = ShardKey(keys[i])
    var value: T
    discard shard.put(key, value)
    totalOps.inc
    
  let setTime = epochTime() - startSet
  totalTime += setTime
  
  # getベンチマーク
  let startGet = epochTime()
  for i in 0..<getCount:
    let idx = i mod setCount # setCountを超えないようにする
    let key = ShardKey(keys[idx])
    discard shard.get(key)
    totalOps.inc
    
  let getTime = epochTime() - startGet
  totalTime += getTime
  
  # 結果
  let opsPerSec = float(totalOps) / totalTime
  let avgLatency = totalTime / float(totalOps) * 1000.0 # ミリ秒単位
  
  return (opsPerSec, avgLatency) 