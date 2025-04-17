## quantum_arch/memory/memory_pool.nim
## 
## 高性能なメモリプール実装
## このモジュールは効率的なメモリ割り当てと解放を提供します

import std/locks
import atomics
import math
import os
import strformat

const
  # デフォルトのプールサイズと設定
  DefaultPoolSize = 1024 * 1024  # 1MB
  DefaultBlockSize = 4096        # 4KB
  DefaultAlignment = 16          # 16バイトアライメント
  SmallBlockThreshold = 256      # 小さいブロックの閾値
  MaximumPoolCount = 16          # プールの最大数

type
  MemoryBlockStatus = enum
    ## メモリブロックのステータス
    mbFree,     ## 空きブロック
    mbAllocated,## 割り当て済みブロック
    mbReserved  ## 予約済みブロック

  MemoryBlockHeader = object
    ## メモリブロックのヘッダー
    size: int                ## ブロックのサイズ（バイト）
    status: Atomic[MemoryBlockStatus] ## ブロックのステータス
    next: ptr MemoryBlockHeader ## 次のブロックへのポインタ
    prev: ptr MemoryBlockHeader ## 前のブロックへのポインタ
    poolId: uint8            ## 所属するプールのID
    padding: array[3, uint8] ## パディング（アライメント用）

  MemoryPoolStats* = object
    ## メモリプールの統計情報
    totalSize*: int          ## プールの合計サイズ
    usedSize*: int           ## 使用中のメモリサイズ
    freeSize*: int           ## 空きメモリサイズ
    allocationCount*: int    ## 割り当て回数
    freeCount*: int          ## 解放回数
    fragmentationRatio*: float ## フラグメンテーション率

  MemoryPool* = ref object
    ## メモリプール
    id*: int                 ## プールID
    name*: string            ## プールの名前
    memory: ptr UncheckedArray[byte] ## 実際のメモリ領域
    size: int                ## プールのサイズ
    blockSize: int           ## ブロックサイズ
    alignment: int           ## アライメント
    firstBlock: ptr MemoryBlockHeader ## 最初のブロックへのポインタ
    lock: Lock               ## プールロック
    smallBlockLists: array[SmallBlockThreshold, ptr MemoryBlockHeader] ## 小さいブロックリスト
    stats: MemoryPoolStats   ## 統計情報

  MemoryPoolManager* = ref object
    ## メモリプールマネージャー
    pools: array[MaximumPoolCount, MemoryPool] ## プールの配列
    poolCount: int           ## 使用中のプール数
    lock: Lock               ## マネージャーロック
    enableThreadLocalCaching: bool ## スレッドローカルキャッシュの有効化
    defaultPoolSize: int     ## デフォルトのプールサイズ
    defaultBlockSize: int    ## デフォルトのブロックサイズ

# グローバルインスタンス
var gMemoryPoolManager {.threadvar.}: MemoryPoolManager

# ヘルパー関数: ポインタ演算
proc offset(p: pointer, offset: int): pointer {.inline.} =
  result = cast[pointer](cast[int](p) + offset)

proc diff(p1, p2: pointer): int {.inline.} =
  result = cast[int](p1) - cast[int](p2)

proc round_up(n, align: int): int {.inline.} =
  ## アライメント用の丸め上げ
  result = (n + align - 1) and (not (align - 1))

# ブロック関連関数
proc initMemoryBlockHeader(header: ptr MemoryBlockHeader, size: int, poolId: uint8) =
  ## メモリブロックヘッダーを初期化
  header.size = size
  header.status.store(mbFree)
  header.next = nil
  header.prev = nil
  header.poolId = poolId
  header.padding = [0'u8, 0, 0]

proc getBlockSize(size: int): int {.inline.} =
  ## 要求サイズに適したブロックサイズを計算
  result = size + sizeof(MemoryBlockHeader)
  # アライメントを考慮
  result = round_up(result, DefaultAlignment)

proc getBlockFromPointer(p: pointer): ptr MemoryBlockHeader {.inline.} =
  ## ユーザポインタからブロックヘッダを取得
  result = cast[ptr MemoryBlockHeader](cast[int](p) - sizeof(MemoryBlockHeader))

proc getPointerFromBlock(block: ptr MemoryBlockHeader): pointer {.inline.} =
  ## ブロックヘッダからユーザポインタを取得
  result = cast[pointer](cast[int](block) + sizeof(MemoryBlockHeader))

proc splitBlock(block: ptr MemoryBlockHeader, size: int): ptr MemoryBlockHeader =
  ## ブロックを分割する
  let totalSize = block.size
  let remainingSize = totalSize - size
  
  if remainingSize <= sizeof(MemoryBlockHeader) + DefaultAlignment:
    # 残りが小さすぎる場合は分割しない
    return nil
    
  # 新しいブロックヘッダを初期化
  let newBlock = cast[ptr MemoryBlockHeader](cast[int](block) + size)
  initMemoryBlockHeader(newBlock, remainingSize, block.poolId)
  
  # 元のブロックのサイズを更新
  block.size = size
  
  # リンクを更新
  newBlock.next = block.next
  newBlock.prev = block
  
  if block.next != nil:
    block.next.prev = newBlock
    
  block.next = newBlock
  
  return newBlock

proc mergeBlockWithNext(block: ptr MemoryBlockHeader): bool =
  ## 隣接するブロックをマージする
  if block == nil or block.next == nil:
    return false
    
  if block.status.load() != mbFree or block.next.status.load() != mbFree:
    return false
    
  # 次のブロックのサイズを加算
  block.size += block.next.size
  
  # リンクを更新
  let nextNext = block.next.next
  block.next = nextNext
  
  if nextNext != nil:
    nextNext.prev = block
    
  return true

# プール関連関数
proc newMemoryPool*(id: int, name: string, size: int, blockSize: int = DefaultBlockSize,
                    alignment: int = DefaultAlignment): MemoryPool =
  ## 新しいメモリプールを作成
  result = MemoryPool(
    id: id,
    name: name,
    size: size,
    blockSize: blockSize,
    alignment: alignment
  )
  
  # メモリを割り当て
  let memory = alloc(size)
  if memory == nil:
    raise newException(OutOfMemError, "Failed to allocate memory for pool")
    
  result.memory = cast[ptr UncheckedArray[byte]](memory)
  
  # 最初のブロックを初期化
  let firstBlock = cast[ptr MemoryBlockHeader](memory)
  initMemoryBlockHeader(firstBlock, size, uint8(id))
  result.firstBlock = firstBlock
  
  # 小さいブロックリストを初期化
  for i in 0..<SmallBlockThreshold:
    result.smallBlockLists[i] = nil
    
  # ロックを初期化
  initLock(result.lock)
  
  # 統計情報を初期化
  result.stats = MemoryPoolStats(
    totalSize: size,
    usedSize: 0,
    freeSize: size,
    allocationCount: 0,
    freeCount: 0,
    fragmentationRatio: 0.0
  )

proc updateStats(pool: MemoryPool) =
  ## プールの統計情報を更新
  var usedSize = 0
  var freeSize = 0
  var fragmentCount = 0
  var blockCount = 0
  
  var block = pool.firstBlock
  while block != nil:
    blockCount.inc
    
    if block.status.load() == mbAllocated:
      usedSize += block.size
    else:
      freeSize += block.size
      fragmentCount.inc
      
    block = block.next
    
  pool.stats.usedSize = usedSize
  pool.stats.freeSize = freeSize
  
  if blockCount > 1:
    pool.stats.fragmentationRatio = float(fragmentCount) / float(blockCount)
  else:
    pool.stats.fragmentationRatio = 0.0

proc findSuitableBlock(pool: MemoryPool, size: int): ptr MemoryBlockHeader =
  ## 適切なサイズのブロックを検索
  if size < SmallBlockThreshold:
    # 小さいブロックリストから検索
    let sizeIndex = size div 8 # 8バイト単位でインデックス化
    
    for i in sizeIndex..<SmallBlockThreshold:
      if pool.smallBlockLists[i] != nil:
        return pool.smallBlockLists[i]
  
  # ファーストフィットアルゴリズムで検索
  var block = pool.firstBlock
  while block != nil:
    if block.status.load() == mbFree and block.size >= size:
      return block
    block = block.next
    
  return nil

proc addToSmallBlockList(pool: MemoryPool, block: ptr MemoryBlockHeader) =
  ## 小さいブロックリストに追加
  let size = block.size
  if size < SmallBlockThreshold:
    let sizeIndex = size div 8
    
    # 現在のリストの先頭をブロックのnextに設定
    block.next = pool.smallBlockLists[sizeIndex]
    
    if block.next != nil:
      block.next.prev = block
      
    # ブロックをリストの先頭に設定
    pool.smallBlockLists[sizeIndex] = block

proc removeFromSmallBlockList(pool: MemoryPool, block: ptr MemoryBlockHeader) =
  ## 小さいブロックリストから削除
  let size = block.size
  if size < SmallBlockThreshold:
    let sizeIndex = size div 8
    
    if pool.smallBlockLists[sizeIndex] == block:
      # ブロックがリストの先頭の場合
      pool.smallBlockLists[sizeIndex] = block.next
      
    if block.prev != nil:
      block.prev.next = block.next
      
    if block.next != nil:
      block.next.prev = block.prev

proc allocateMemory*(pool: MemoryPool, size: int): pointer =
  ## プールからメモリを割り当て
  if size <= 0:
    return nil
    
  let blockSize = getBlockSize(size)
  
  withLock(pool.lock):
    # 適切なブロックを検索
    var block = pool.findSuitableBlock(blockSize)
    if block == nil:
      # 適切なブロックが見つからない場合
      return nil
      
    # 小さいブロックリストから削除
    pool.removeFromSmallBlockList(block)
    
    # 必要に応じてブロックを分割
    let remainingBlock = splitBlock(block, blockSize)
    if remainingBlock != nil:
      # 分割した残りを小さいブロックリストに追加
      pool.addToSmallBlockList(remainingBlock)
      
    # ブロックを割り当て済みに設定
    block.status.store(mbAllocated)
    
    # 統計情報を更新
    pool.stats.allocationCount.inc
    pool.updateStats()
    
    # ユーザーポインタを返す
    return getPointerFromBlock(block)

proc freeMemory*(pool: MemoryPool, p: pointer): bool =
  ## プールのメモリを解放
  if p == nil:
    return false
    
  withLock(pool.lock):
    # ブロックヘッダを取得
    let block = getBlockFromPointer(p)
    
    # ブロックが対象のプールに属しているか確認
    if block.poolId != uint8(pool.id):
      return false
      
    # すでに解放済みかチェック
    if block.status.load() != mbAllocated:
      return false
      
    # ブロックを解放
    block.status.store(mbFree)
    
    # 可能であれば隣接するブロックをマージ
    discard mergeBlockWithNext(block)
    if block.prev != nil:
      discard mergeBlockWithNext(block.prev)
      
    # 小さいブロックリストに追加
    pool.addToSmallBlockList(block)
    
    # 統計情報を更新
    pool.stats.freeCount.inc
    pool.updateStats()
    
    return true

proc getStats*(pool: MemoryPool): MemoryPoolStats =
  ## プールの統計情報を取得
  withLock(pool.lock):
    pool.updateStats()
    result = pool.stats

proc destroy*(pool: MemoryPool) =
  ## プールを破棄
  if pool.memory != nil:
    dealloc(pool.memory)
    pool.memory = nil

# プールマネージャー関連関数
proc newMemoryPoolManager*(defaultPoolSize: int = DefaultPoolSize,
                          defaultBlockSize: int = DefaultBlockSize): MemoryPoolManager =
  ## 新しいメモリプールマネージャーを作成
  result = MemoryPoolManager(
    poolCount: 0,
    enableThreadLocalCaching: true,
    defaultPoolSize: defaultPoolSize,
    defaultBlockSize: defaultBlockSize
  )
  
  initLock(result.lock)

proc addPool*(manager: MemoryPoolManager, name: string, size: int = 0, 
             blockSize: int = 0): MemoryPool =
  ## マネージャーにプールを追加
  let actualSize = if size <= 0: manager.defaultPoolSize else: size
  let actualBlockSize = if blockSize <= 0: manager.defaultBlockSize else: blockSize
  
  withLock(manager.lock):
    if manager.poolCount >= MaximumPoolCount:
      raise newException(ResourceExhaustedError, "Maximum pool count reached")
      
    let id = manager.poolCount
    let pool = newMemoryPool(id, name, actualSize, actualBlockSize)
    
    manager.pools[id] = pool
    manager.poolCount.inc
    
    return pool

proc getPoolById*(manager: MemoryPoolManager, id: int): MemoryPool =
  ## IDでプールを検索
  if id < 0 or id >= manager.poolCount:
    return nil
    
  return manager.pools[id]

proc getPoolByName*(manager: MemoryPoolManager, name: string): MemoryPool =
  ## 名前でプールを検索
  for i in 0..<manager.poolCount:
    if manager.pools[i].name == name:
      return manager.pools[i]
      
  return nil

proc allocate*(manager: MemoryPoolManager, size: int, poolId: int = 0): pointer =
  ## マネージャーからメモリを割り当て
  if size <= 0:
    return nil
    
  if poolId < 0 or poolId >= manager.poolCount:
    return nil
    
  let pool = manager.pools[poolId]
  return pool.allocateMemory(size)

proc free*(manager: MemoryPoolManager, p: pointer): bool =
  ## マネージャーのメモリを解放
  if p == nil:
    return false
    
  # ブロックヘッダを取得してプールIDを確認
  let block = getBlockFromPointer(p)
  let poolId = int(block.poolId)
  
  if poolId < 0 or poolId >= manager.poolCount:
    return false
    
  let pool = manager.pools[poolId]
  return pool.freeMemory(p)

proc getGlobalManager*(): MemoryPoolManager =
  ## グローバルマネージャーのインスタンスを取得
  if gMemoryPoolManager == nil:
    gMemoryPoolManager = newMemoryPoolManager()
    
    # デフォルトプールを作成
    discard gMemoryPoolManager.addPool("default")
    
  return gMemoryPoolManager

proc allocateGlobal*(size: int): pointer =
  ## グローバルマネージャーからメモリを割り当て
  let manager = getGlobalManager()
  return manager.allocate(size)

proc freeGlobal*(p: pointer): bool =
  ## グローバルマネージャーのメモリを解放
  let manager = getGlobalManager()
  return manager.free(p)

proc destroyManager*(manager: MemoryPoolManager) =
  ## マネージャーを破棄
  for i in 0..<manager.poolCount:
    if manager.pools[i] != nil:
      manager.pools[i].destroy()
      
  manager.poolCount = 0

# ユーティリティ関数
proc printPoolInfo*(pool: MemoryPool) =
  ## プール情報を出力
  withLock(pool.lock):
    pool.updateStats()
    let stats = pool.stats
    
    echo fmt"Pool '{pool.name}' (ID: {pool.id}):"
    echo fmt"  Total Size: {stats.totalSize} bytes"
    echo fmt"  Used Size: {stats.usedSize} bytes ({float(stats.usedSize) / float(stats.totalSize) * 100:.2f}%)"
    echo fmt"  Free Size: {stats.freeSize} bytes ({float(stats.freeSize) / float(stats.totalSize) * 100:.2f}%)"
    echo fmt"  Allocations: {stats.allocationCount}"
    echo fmt"  Frees: {stats.freeCount}"
    echo fmt"  Fragmentation Ratio: {stats.fragmentationRatio:.4f}"

proc printManagerInfo*(manager: MemoryPoolManager) =
  ## マネージャー情報を出力
  echo fmt"Memory Pool Manager (Pools: {manager.poolCount}):"
  echo fmt"  Default Pool Size: {manager.defaultPoolSize} bytes"
  echo fmt"  Default Block Size: {manager.defaultBlockSize} bytes"
  echo fmt"  Thread Local Caching: {manager.enableThreadLocalCaching}"
  
  for i in 0..<manager.poolCount:
    printPoolInfo(manager.pools[i])

# カスタムアロケータの実装
type
  PoolAllocator* = object
    ## プールベースのメモリアロケータ
    poolId*: int
    manager*: MemoryPoolManager

proc allocate*(allocator: PoolAllocator, size: Natural): pointer =
  ## アロケータからメモリを割り当て
  if allocator.manager == nil:
    return nil
    
  return allocator.manager.allocate(size, allocator.poolId)

proc deallocate*(allocator: PoolAllocator, p: pointer) =
  ## アロケータのメモリを解放
  if allocator.manager == nil or p == nil:
    return
    
  discard allocator.manager.free(p)

proc reallocate*(allocator: PoolAllocator, p: pointer, newSize: Natural): pointer =
  ## アロケータのメモリをリサイズ
  if p == nil:
    return allocator.allocate(newSize)
    
  if newSize == 0:
    allocator.deallocate(p)
    return nil
    
  # 現在のブロックからサイズを取得
  let block = getBlockFromPointer(p)
  let currentSize = block.size - sizeof(MemoryBlockHeader)
  
  if currentSize >= newSize:
    # サイズが小さくなる場合はそのまま返す
    return p
    
  # 新しいメモリを割り当て、データをコピー
  let newMem = allocator.allocate(newSize)
  if newMem == nil:
    return nil
    
  copyMem(newMem, p, currentSize)
  allocator.deallocate(p)
  
  return newMem

proc newPoolAllocator*(poolId: int = 0, manager: MemoryPoolManager = nil): PoolAllocator =
  ## 新しいプールアロケータを作成
  let actualManager = if manager == nil: getGlobalManager() else: manager
  
  result = PoolAllocator(
    poolId: poolId,
    manager: actualManager
  ) 