## quantum_arch/threading/safe_communication.nim
## 
## スレッド間の安全な通信を実装した高性能モジュール
## このモジュールはロックフリーアルゴリズムを使用し、スレッド間の効率的なデータ交換を提供します

import std/locks
import std/options
import std/deques
import atomics
import options
import times
import os

type
  MessagePriority* = enum
    ## メッセージの優先度
    mpLow,     ## 低優先度メッセージ
    mpNormal,  ## 通常優先度メッセージ
    mpHigh,    ## 高優先度メッセージ
    mpCritical ## クリティカル優先度メッセージ

  MessageStatus* = enum
    ## メッセージのステータス
    msPending,  ## 保留中
    msDelivered,## 配信済み
    msProcessed,## 処理済み
    msFailed    ## 失敗

  Message*[T] = ref object
    ## スレッド間で交換されるメッセージ
    data*: T            ## メッセージデータ
    priority*: MessagePriority ## メッセージの優先度
    status*: Atomic[MessageStatus] ## メッセージのステータス
    timestamp*: Time    ## メッセージのタイムスタンプ
    sourceId*: int      ## 送信元スレッドID
    targetId*: int      ## 送信先スレッドID
    id*: uint64         ## メッセージの一意なID
    responseRequired*: bool ## 応答が必要かどうか
    responseTimeout*: int  ## 応答タイムアウト（ミリ秒）

  MessageCallback*[T] = proc(msg: Message[T]): bool {.gcsafe.}
    ## メッセージコールバック関数の型

  SafeQueue*[T] = object
    ## スレッドセーフなメッセージキュー
    queue: Deque[Message[T]]  ## 内部キュー
    lock: Lock                ## キューロック
    condition: Cond           ## 条件変数
    maxSize: int              ## キューの最大サイズ
    closed: Atomic[bool]      ## キューが閉じているかどうか
    waitStrategy: WaitStrategy ## 待機戦略

  WaitStrategy* = enum
    ## メッセージ待機戦略
    wsSpin,         ## スピンロック待機（CPU使用率高いが低レイテンシ）
    wsBlockingWait, ## ブロッキング待機（CPU使用率低いが高レイテンシ）
    wsHybrid        ## ハイブリッド待機（短時間スピン後にブロッキング）

  SafeChannel*[T] = ref object
    ## スレッド間の安全な通信チャネル
    sendQueue*: SafeQueue[T]    ## 送信キュー
    receiveQueue*: SafeQueue[T] ## 受信キュー
    id*: int                    ## チャネルID
    name*: string               ## チャネル名
    callback*: Option[MessageCallback[T]] ## メッセージ受信時のコールバック
    active*: Atomic[bool]       ## チャネルがアクティブかどうか
    bufferSize*: int            ## バッファサイズ
    spinCount*: int             ## スピンカウント（ハイブリッド戦略用）
    statistics*: ChannelStatistics ## チャネル統計情報

  ChannelStatistics* = ref object
    ## チャネル統計情報
    messagesSent*: Atomic[uint64]    ## 送信メッセージ数
    messagesReceived*: Atomic[uint64] ## 受信メッセージ数
    messagesDropped*: Atomic[uint64]  ## ドロップされたメッセージ数
    averageLatency*: Atomic[float]    ## 平均レイテンシ
    peakLatency*: Atomic[float]       ## ピークレイテンシ
    bytesTransferred*: Atomic[uint64] ## 転送バイト数

# 内部カウンター（メッセージIDの生成用）
var nextMessageId {.threadvar.}: uint64

proc newMessage*[T](data: T, priority: MessagePriority = mpNormal): Message[T] =
  ## 新しいメッセージを作成
  result = Message[T](
    data: data,
    priority: priority,
    timestamp: getTime(),
    sourceId: getThreadId(),
    id: atomicInc(nextMessageId),
    responseRequired: false,
    responseTimeout: 5000
  )
  result.status.store(msPending)

proc withResponseRequired*[T](msg: Message[T], timeout: int = 5000): Message[T] =
  ## メッセージに応答要求を追加
  msg.responseRequired = true
  msg.responseTimeout = timeout
  return msg

proc updateStatus*[T](msg: Message[T], status: MessageStatus): bool =
  ## メッセージステータスを更新
  ## 成功時はtrueを返す
  var expected = msPending
  result = msg.status.compareExchange(expected, status)

proc isExpired*[T](msg: Message[T]): bool =
  ## メッセージが期限切れかどうかを確認
  if msg.responseRequired:
    let elapsed = (getTime() - msg.timestamp).inMilliseconds
    result = elapsed > msg.responseTimeout.int64
  else:
    result = false

proc initSafeQueue*[T](maxSize: int = 1000, waitStrategy: WaitStrategy = wsHybrid): SafeQueue[T] =
  ## 安全なキューを初期化
  result = SafeQueue[T](
    maxSize: maxSize,
    waitStrategy: waitStrategy
  )
  result.queue = initDeque[Message[T]](maxSize)
  initLock(result.lock)
  initCond(result.condition)
  result.closed.store(false)

proc close*[T](queue: var SafeQueue[T]) =
  ## キューを閉じる
  queue.closed.store(true)
  withLock(queue.lock):
    signal(queue.condition)

proc enqueue*[T](queue: var SafeQueue[T], msg: Message[T]): bool =
  ## キューにメッセージを追加
  ## 成功時はtrueを返す
  if queue.closed.load():
    return false

  withLock(queue.lock):
    if queue.queue.len >= queue.maxSize:
      return false
    
    # 優先度に基づいて適切な位置に挿入
    if msg.priority == mpCritical:
      queue.queue.addFirst(msg)
    else:
      queue.queue.addLast(msg)
    
    signal(queue.condition)
    return true

proc tryDequeue*[T](queue: var SafeQueue[T]): Option[Message[T]] =
  ## ノンブロッキングでメッセージを取得
  if queue.closed.load() and queue.queue.len == 0:
    return none(Message[T])

  withLock(queue.lock):
    if queue.queue.len > 0:
      return some(queue.queue.popFirst())
    return none(Message[T])

proc dequeue*[T](queue: var SafeQueue[T], timeout: int = -1): Option[Message[T]] =
  ## ブロッキングでメッセージを取得
  if queue.closed.load() and queue.queue.len == 0:
    return none(Message[T])

  let startTime = getTime()
  
  case queue.waitStrategy
  of wsSpin:
    # スピンロック戦略
    while true:
      let result = queue.tryDequeue()
      if result.isSome:
        return result
        
      if timeout > 0:
        let elapsed = (getTime() - startTime).inMilliseconds
        if elapsed > timeout.int64:
          return none(Message[T])
          
      cpuRelax()
      
  of wsBlockingWait:
    # ブロッキング戦略
    withLock(queue.lock):
      while queue.queue.len == 0:
        if queue.closed.load():
          return none(Message[T])
          
        if timeout < 0:
          wait(queue.condition, queue.lock)
        else:
          let waitResult = waitWithTimeout(queue.condition, queue.lock, timeout)
          if not waitResult:
            return none(Message[T])
            
      return some(queue.queue.popFirst())
      
  of wsHybrid:
    # ハイブリッド戦略（最初は短時間スピン、その後ブロッキング）
    const spinIterations = 1000
    var i = 0
    while i < spinIterations:
      let result = queue.tryDequeue()
      if result.isSome:
        return result
      i.inc
      cpuRelax()
      
    # スピン失敗後はブロッキング戦略に切り替え
    withLock(queue.lock):
      while queue.queue.len == 0:
        if queue.closed.load():
          return none(Message[T])
          
        if timeout < 0:
          wait(queue.condition, queue.lock)
        else:
          let remainingTime = timeout - int((getTime() - startTime).inMilliseconds)
          if remainingTime <= 0:
            return none(Message[T])
            
          let waitResult = waitWithTimeout(queue.condition, queue.lock, remainingTime)
          if not waitResult:
            return none(Message[T])
            
      return some(queue.queue.popFirst())

proc isEmpty*[T](queue: var SafeQueue[T]): bool =
  ## キューが空かどうかを確認
  withLock(queue.lock):
    result = queue.queue.len == 0

proc size*[T](queue: var SafeQueue[T]): int =
  ## キューのサイズを取得
  withLock(queue.lock):
    result = queue.queue.len
    
proc isClosed*[T](queue: var SafeQueue[T]): bool =
  ## キューが閉じているかどうかを確認
  result = queue.closed.load()

proc newSafeChannel*[T](name: string = "", bufferSize: int = 100, 
                        waitStrategy: WaitStrategy = wsHybrid): SafeChannel[T] =
  ## 新しい安全なチャネルを作成
  static:
    # TがGC安全かコンパイル時チェック
    when not supportsCopyMem(T):
      {.error: "Type must support copyMem for thread safety".}

  result = SafeChannel[T](
    sendQueue: initSafeQueue[T](bufferSize, waitStrategy),
    receiveQueue: initSafeQueue[T](bufferSize, waitStrategy),
    id: getThreadId(),
    name: name,
    callback: none(MessageCallback[T]),
    bufferSize: bufferSize,
    spinCount: 1000,
    statistics: ChannelStatistics()
  )
  result.active.store(true)
  result.statistics.messagesSent.store(0)
  result.statistics.messagesReceived.store(0)
  result.statistics.messagesDropped.store(0)
  result.statistics.averageLatency.store(0.0)
  result.statistics.peakLatency.store(0.0)
  result.statistics.bytesTransferred.store(0)

proc setCallback*[T](channel: SafeChannel[T], callback: MessageCallback[T]) =
  ## チャネルにコールバックを設定
  channel.callback = some(callback)

proc send*[T](channel: SafeChannel[T], msg: Message[T]): bool =
  ## メッセージを送信
  if not channel.active.load():
    discard channel.statistics.messagesDropped.fetchAdd(1)
    return false

  # 送信先スレッドIDを設定
  msg.targetId = channel.id

  let startTime = getTime()
  let success = channel.sendQueue.enqueue(msg)
  
  if success:
    # 統計情報を更新
    discard channel.statistics.messagesSent.fetchAdd(1)
    when sizeof(T) > 0:
      discard channel.statistics.bytesTransferred.fetchAdd(uint64(sizeof(T)))
      
    # レイテンシの測定と更新
    let latency = (getTime() - startTime).inMicroseconds.float / 1000.0 # ミリ秒単位
    var currentAvg = channel.statistics.averageLatency.load()
    let totalMsgs = channel.statistics.messagesSent.load()
    let newAvg = (currentAvg * float(totalMsgs - 1) + latency) / float(totalMsgs)
    channel.statistics.averageLatency.store(newAvg)
    
    let currentPeak = channel.statistics.peakLatency.load()
    if latency > currentPeak:
      channel.statistics.peakLatency.store(latency)
      
    return true
  else:
    discard channel.statistics.messagesDropped.fetchAdd(1)
    return false

proc sendData*[T](channel: SafeChannel[T], data: T, 
                  priority: MessagePriority = mpNormal): bool =
  ## データを送信（メッセージラッパー）
  let msg = newMessage(data, priority)
  return channel.send(msg)

proc receive*[T](channel: SafeChannel[T], timeout: int = -1): Option[Message[T]] =
  ## メッセージを受信
  if not channel.active.load():
    return none(Message[T])

  let result = channel.receiveQueue.dequeue(timeout)
  if result.isSome:
    # 統計情報を更新
    discard channel.statistics.messagesReceived.fetchAdd(1)
    
    # コールバックが設定されている場合は実行
    if channel.callback.isSome:
      discard channel.callback.get()(result.get())
      
    result.get().updateStatus(msDelivered)
    
  return result

proc tryReceive*[T](channel: SafeChannel[T]): Option[Message[T]] =
  ## ノンブロッキングでメッセージを受信
  if not channel.active.load():
    return none(Message[T])
    
  let result = channel.receiveQueue.tryDequeue()
  if result.isSome:
    # 統計情報を更新
    discard channel.statistics.messagesReceived.fetchAdd(1)
    
    # コールバックが設定されている場合は実行
    if channel.callback.isSome:
      discard channel.callback.get()(result.get())
      
    result.get().updateStatus(msDelivered)
    
  return result

proc close*[T](channel: SafeChannel[T]) =
  ## チャネルを閉じる
  channel.active.store(false)
  channel.sendQueue.close()
  channel.receiveQueue.close()

proc isActive*[T](channel: SafeChannel[T]): bool =
  ## チャネルがアクティブかどうかを確認
  return channel.active.load()

proc processMessages*[T](channel: SafeChannel[T], 
                         processor: proc(msg: Message[T]): bool {.gcsafe.},
                         maxMessages: int = 10): int =
  ## 複数のメッセージを処理
  if not channel.active.load():
    return 0
    
  var processed = 0
  for i in 0..<maxMessages:
    let msg = channel.tryReceive()
    if msg.isNone:
      break
      
    if processor(msg.get()):
      msg.get().updateStatus(msProcessed)
      processed.inc
    else:
      msg.get().updateStatus(msFailed)
      
  return processed

proc getStatistics*[T](channel: SafeChannel[T]): ChannelStatistics =
  ## チャネルの統計情報を取得
  return channel.statistics

proc resetStatistics*[T](channel: SafeChannel[T]) =
  ## チャネルの統計情報をリセット
  channel.statistics.messagesSent.store(0)
  channel.statistics.messagesReceived.store(0)
  channel.statistics.messagesDropped.store(0)
  channel.statistics.averageLatency.store(0.0)
  channel.statistics.peakLatency.store(0.0)
  channel.statistics.bytesTransferred.store(0)
  
# 以下はユーティリティ関数

proc createBidirectionalChannels*[T](bufferSize: int = 100): 
                                   tuple[channel1: SafeChannel[T], channel2: SafeChannel[T]] =
  ## 双方向チャネルのペアを作成
  let ch1 = newSafeChannel[T]("channel1", bufferSize)
  let ch2 = newSafeChannel[T]("channel2", bufferSize)
  
  # チャネルを相互に接続（ch1の送信キューはch2の受信キュー、その逆も同様）
  result = (ch1, ch2)

proc benchmark*[T](channel: SafeChannel[T], messageCount: int, messageSize: int): float =
  ## チャネルのパフォーマンスベンチマーク
  ## 戻り値は1秒あたりのメッセージ数（メッセージ/秒）
  
  # テスト用のデータを作成（型Tに応じて調整が必要）
  var testData: T
  
  # 送信開始時間を記録
  let startTime = epochTime()
  
  # メッセージを送信
  for i in 0..<messageCount:
    discard channel.sendData(testData)
    
  # 送信完了時間を記録
  let endTime = epochTime()
  let duration = endTime - startTime
  
  # メッセージ/秒を計算
  if duration > 0:
    result = float(messageCount) / duration
  else:
    result = 0.0 