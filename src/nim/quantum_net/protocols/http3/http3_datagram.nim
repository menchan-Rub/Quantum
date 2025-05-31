# HTTP/3 Datagram Extension（RFC9221対応と先進的な拡張）
# 低レイテンシーアプリケーション向けの最適化実装

import std/[
  options,
  sequtils,
  hashes,
  strutils,
  strformat,
  tables,
  times,
  asyncdispatch
]

import ../quic/quic_types
import ../quic/quic_client
import ../quic/datagram
import ./http3_types
import ./http3_stream
import ./http3_client
import ./http3_frame
import ../../optimizer_config

# 定数
const
  # データグラムのフレームタイプ
  H3_DATAGRAM_FRAME_TYPE = 0x30
  
  # データグラム識別子の最大値
  MAX_DATAGRAM_ID = 0x3FFF'u64
  
  # データグラムのフロー制御用ウィンドウサイズ（デフォルト）
  DEFAULT_DATAGRAM_FLOW_WINDOW = 65536
  
  # 最大データグラムサイズ（デフォルト）
  DEFAULT_MAX_DATAGRAM_SIZE = 1200
  
  # データグラムQoSレベル
  DATAGRAM_QOS_BEST_EFFORT = 0  # ベストエフォート
  DATAGRAM_QOS_RELIABLE = 1     # 信頼性（アプリケーションレベルでの再送）
  DATAGRAM_QOS_CRITICAL = 2     # クリティカル（優先送信）
  DATAGRAM_QOS_REALTIME = 3     # リアルタイム（最低レイテンシー）
  
  # 最大インフライトデータグラム数
  DEFAULT_MAX_INFLIGHT_DATAGRAMS = 1024

type
  # HTTP/3 データグラムの状態
  DatagramState = enum
    dsNone,        # 初期状態
    dsEnabled,     # 有効化済み
    dsNegotiated,  # ネゴシエーション完了
    dsDisabled     # 無効化

  # データグラム識別情報
  DatagramId* = object
    id*: uint64           # データグラムID
    qosLevel*: uint8      # QoSレベル
    flowId*: uint32       # フローID（複数フロー識別用）
    contextId*: uint32    # コンテキストID（アプリケーション用）

  # データグラム設定
  DatagramSettings* = object
    maxDatagramSize*: uint16            # 最大データグラムサイズ
    maxInflightDatagrams*: uint32       # 最大インフライトデータグラム数
    flowControlWindow*: uint32          # フロー制御ウィンドウ
    enableQos*: bool                    # QoS有効フラグ
    enableReliableMode*: bool           # 信頼性モード有効フラグ
    retransmitTimeout*: int             # 再送タイムアウト（ミリ秒）
    enablePrioritization*: bool         # 優先度付け有効フラグ
    enableBatching*: bool               # バッチ処理有効フラグ
    enableMultipath*: bool              # マルチパス有効フラグ
    batchingInterval*: int              # バッチング間隔（ミリ秒）
    adaptivePacing*: bool               # 適応型ペーシング有効フラグ
    enableCompression*: bool            # 圧縮有効フラグ
    compressionLevel*: int              # 圧縮レベル（0-9）

  # データグラム管理クラス
  Http3DatagramManager* = ref object
    client*: Http3Client              # 関連HTTP/3クライアント
    state*: DatagramState             # 状態
    settings*: DatagramSettings       # 設定
    nextId*: uint64                   # 次のデータグラムID
    inflightDatagrams*: int           # インフライトデータグラム数
    receivedDatagrams*: uint64        # 受信したデータグラム数
    sentDatagrams*: uint64            # 送信したデータグラム数
    lostDatagrams*: uint64            # 紛失したデータグラム数
    flowWindow*: uint32               # 現在のフロー制御ウィンドウ
    receivedCallbacks*: seq[DatagramReceivedCallback] # 受信コールバック
    pendingReliableDatagrams*: Table[uint64, PendingReliableDatagram] # 信頼性モード用保留データグラム
    activeFlows*: Table[uint32, DatagramFlowState] # アクティブフロー状態

  # データグラム受信コールバック型
  DatagramReceivedCallback* = proc(data: seq[byte], id: DatagramId): Future[void] {.async.}

  # 信頼性モード用の保留データグラム
  PendingReliableDatagram = object
    id: DatagramId
    data: seq[byte]
    sentTime: Time
    retries: int
    maxRetries: int
    expireTime: Time
    ackReceived: bool

  # フロー状態
  DatagramFlowState = object
    flowId: uint32
    priority: int
    createdTime: Time
    lastActivity: Time
    bytesSent: uint64
    bytesReceived: uint64
    datagramsSent: uint64
    datagramsReceived: uint64
    currentWindow: uint32
    isActive: bool

# データグラムID生成
proc createDatagramId*(dgram: Http3DatagramManager, 
                     qosLevel: uint8 = DATAGRAM_QOS_BEST_EFFORT,
                     flowId: uint32 = 0, 
                     contextId: uint32 = 0): DatagramId =
  result = DatagramId(
    id: dgram.nextId,
    qosLevel: qosLevel,
    flowId: flowId,
    contextId: contextId
  )
  # IDをインクリメント（最大値に達したらラップアラウンド）
  dgram.nextId = (dgram.nextId + 1) and MAX_DATAGRAM_ID

# データグラムID解析
proc parseDatagramId*(data: seq[byte]): DatagramId =
  if data.len < 8:
    return DatagramId(id: 0, qosLevel: 0, flowId: 0, contextId: 0)
  
  let id = (uint64(data[0]) shl 56) or
           (uint64(data[1]) shl 48) or
           (uint64(data[2]) shl 40) or
           (uint64(data[3]) shl 32) or
           (uint64(data[4]) shl 24) or
           (uint64(data[5]) shl 16) or
           (uint64(data[6]) shl 8) or
           uint64(data[7])
  
  let qosLevel = if data.len > 8: data[8] else: 0'u8
  let flowId = if data.len > 12:
                ((uint32(data[9]) shl 16) or
                 (uint32(data[10]) shl 8) or
                 uint32(data[11]))
               else: 0'u32
  let contextId = if data.len > 16:
                   ((uint32(data[12]) shl 24) or
                    (uint32(data[13]) shl 16) or
                    (uint32(data[14]) shl 8) or
                    uint32(data[15]))
                  else: 0'u32
  
  return DatagramId(
    id: id,
    qosLevel: qosLevel,
    flowId: flowId,
    contextId: contextId
  )

# データグラムID → バイト列
proc encodeDatagramId*(id: DatagramId): seq[byte] =
  result = newSeq[byte](16)
  result[0] = byte((id.id shr 56) and 0xFF)
  result[1] = byte((id.id shr 48) and 0xFF)
  result[2] = byte((id.id shr 40) and 0xFF)
  result[3] = byte((id.id shr 32) and 0xFF)
  result[4] = byte((id.id shr 24) and 0xFF)
  result[5] = byte((id.id shr 16) and 0xFF)
  result[6] = byte((id.id shr 8) and 0xFF)
  result[7] = byte(id.id and 0xFF)
  result[8] = id.qosLevel
  result[9] = byte((id.flowId shr 16) and 0xFF)
  result[10] = byte((id.flowId shr 8) and 0xFF)
  result[11] = byte(id.flowId and 0xFF)
  result[12] = byte((id.contextId shr 24) and 0xFF)
  result[13] = byte((id.contextId shr 16) and 0xFF)
  result[14] = byte((id.contextId shr 8) and 0xFF)
  result[15] = byte(id.contextId and 0xFF)

# HTTP/3 データグラムマネージャー作成
proc newHttp3DatagramManager*(client: Http3Client, settings: DatagramSettings = DatagramSettings()): Http3DatagramManager =
  result = Http3DatagramManager(
    client: client,
    state: dsNone,
    settings: settings,
    nextId: 0,
    inflightDatagrams: 0,
    receivedDatagrams: 0,
    sentDatagrams: 0,
    lostDatagrams: 0,
    flowWindow: DEFAULT_DATAGRAM_FLOW_WINDOW,
    receivedCallbacks: @[],
    pendingReliableDatagrams: initTable[uint64, PendingReliableDatagram](),
    activeFlows: initTable[uint32, DatagramFlowState]()
  )
  
  # デフォルト設定の初期化
  if result.settings.maxDatagramSize == 0:
    result.settings.maxDatagramSize = DEFAULT_MAX_DATAGRAM_SIZE
  
  if result.settings.maxInflightDatagrams == 0:
    result.settings.maxInflightDatagrams = DEFAULT_MAX_INFLIGHT_DATAGRAMS
  
  if result.settings.flowControlWindow == 0:
    result.settings.flowControlWindow = DEFAULT_DATAGRAM_FLOW_WINDOW
  
  result.flowWindow = result.settings.flowControlWindow

# HTTP/3 データグラム有効化
proc enableDatagrams*(dgram: Http3DatagramManager): Future[bool] {.async.} =
  if dgram.state == dsEnabled or dgram.state == dsNegotiated:
    return true
  
  if dgram.client == nil or dgram.client.quicClient == nil:
    return false
  
  # QUICデータグラムの有効化
  let enabled = await dgram.client.quicClient.enableDatagrams()
  if not enabled:
    return false
  
  # HTTP/3 データグラム設定設定
  dgram.state = dsEnabled
  
  # 必要なQuicクライアント設定も更新
  dgram.client.quicClient.setDatagramReceiveCallback(
    proc(data: seq[byte]): Future[void] {.async.} =
      await dgram.handleReceivedDatagram(data)
  )
  
  return true

# データグラム受信ハンドラ
proc handleReceivedDatagram*(dgram: Http3DatagramManager, data: seq[byte]): Future[void] {.async.} =
  if data.len < 1:
    return
  
  # データグラム数をインクリメント
  dgram.receivedDatagrams += 1
  
  # ヘッダー解析
  if data[0] != H3_DATAGRAM_FRAME_TYPE:
    return
  
  # ペイロード抽出
  if data.len <= 16:
    return
  
  let payload = data[1..^1]
  let datagramId = parseDatagramId(payload[0..15])
  let actualPayload = payload[16..^1]
  
  # フロー状態更新
  if datagramId.flowId != 0 and datagramId.flowId in dgram.activeFlows:
    var flow = dgram.activeFlows[datagramId.flowId]
    flow.lastActivity = getTime()
    flow.bytesReceived += uint64(actualPayload.len)
    flow.datagramsReceived += 1
    dgram.activeFlows[datagramId.flowId] = flow
  
  # 登録済みコールバックに通知
  for callback in dgram.receivedCallbacks:
    try:
      await callback(actualPayload, datagramId)
    except:
      discard

# データグラム送信
proc sendDatagram*(dgram: Http3DatagramManager, 
                 data: seq[byte], 
                 id: DatagramId = DatagramId()): Future[bool] {.async.} =
  # 準備チェック
  if dgram.state != dsEnabled and dgram.state != dsNegotiated:
    let enabled = await dgram.enableDatagrams()
    if not enabled:
      return false
  
  # インフライトデータグラムの制限チェック
  if dgram.inflightDatagrams >= int(dgram.settings.maxInflightDatagrams):
    return false
  
  # サイズチェック（ヘッダー + IDを含む）
  let totalSize = 1 + 16 + data.len
  if totalSize > dgram.settings.maxDatagramSize:
    return false
  
  # フロー制御チェック
  if dgram.flowWindow < uint32(totalSize):
    return false
  
  # データグラムIDを取得（指定がなければ新規作成）
  var datagramId = id
  if datagramId.id == 0:
    datagramId = dgram.createDatagramId()
  
  # データグラムIDのエンコード
  let encodedId = encodeDatagramId(datagramId)
  
  # HTTP/3 データグラムの構築
  var datagram = newSeq[byte](1 + encodedId.len + data.len)
  datagram[0] = H3_DATAGRAM_FRAME_TYPE
  for i, b in encodedId:
    datagram[1 + i] = b
  for i, b in data:
    datagram[1 + encodedId.len + i] = b
  
  # フロー状態更新
  if datagramId.flowId != 0:
    if datagramId.flowId in dgram.activeFlows:
      var flow = dgram.activeFlows[datagramId.flowId]
      flow.lastActivity = getTime()
      flow.bytesSent += uint64(data.len)
      flow.datagramsSent += 1
      dgram.activeFlows[datagramId.flowId] = flow
    else:
      # 新規フロー
      dgram.activeFlows[datagramId.flowId] = DatagramFlowState(
        flowId: datagramId.flowId,
        priority: 0,
        createdTime: getTime(),
        lastActivity: getTime(),
        bytesSent: uint64(data.len),
        bytesReceived: 0,
        datagramsSent: 1,
        datagramsReceived: 0,
        currentWindow: dgram.settings.flowControlWindow,
        isActive: true
      )
  
  # 信頼性モード
  if dgram.settings.enableReliableMode and datagramId.qosLevel >= DATAGRAM_QOS_RELIABLE:
    # 再送用に保存
    let pendingDatagram = PendingReliableDatagram(
      id: datagramId,
      data: data,
      sentTime: getTime(),
      retries: 0,
      maxRetries: 3,
      expireTime: getTime() + initDuration(milliseconds = dgram.settings.retransmitTimeout),
      ackReceived: false
    )
    dgram.pendingReliableDatagrams[datagramId.id] = pendingDatagram
  
  # QUICクライアントで送信
  let sent = await dgram.client.quicClient.sendDatagram(datagram)
  if sent:
    dgram.sentDatagrams += 1
    dgram.inflightDatagrams += 1
    dgram.flowWindow -= uint32(totalSize)
    return true
  else:
    return false

# 受信コールバック登録
proc registerDatagramReceiveCallback*(dgram: Http3DatagramManager, 
                                   callback: DatagramReceivedCallback) =
  dgram.receivedCallbacks.add(callback)

# 信頼性モードの保留データグラム確認
proc checkPendingReliableDatagrams*(dgram: Http3DatagramManager): Future[void] {.async.} =
  if not dgram.settings.enableReliableMode:
    return
  
  let now = getTime()
  var expiredIds: seq[uint64] = @[]
  var retriesNeeded: seq[uint64] = @[]
  
  # 期限切れと再送が必要なデータグラムをチェック
  for id, datagram in dgram.pendingReliableDatagrams:
    if datagram.ackReceived:
      expiredIds.add(id)
    elif now > datagram.expireTime:
      if datagram.retries >= datagram.maxRetries:
        # 最大再試行回数に達した
        expiredIds.add(id)
        dgram.lostDatagrams += 1
      else:
        # 再送が必要
        retriesNeeded.add(id)
  
  # 期限切れのデータグラムを削除
  for id in expiredIds:
    dgram.pendingReliableDatagrams.del(id)
  
  # 再送が必要なデータグラムを処理
  for id in retriesNeeded:
    if id in dgram.pendingReliableDatagrams:
      var datagram = dgram.pendingReliableDatagrams[id]
      datagram.retries += 1
      datagram.sentTime = now
      datagram.expireTime = now + initDuration(milliseconds = dgram.settings.retransmitTimeout)
      
      # 再送
      discard await dgram.sendDatagram(datagram.data, datagram.id)
      
      # 状態を更新
      dgram.pendingReliableDatagrams[id] = datagram

# フロー制御ウィンドウの更新
proc updateFlowControlWindow*(dgram: Http3DatagramManager, newWindow: uint32) =
  dgram.flowWindow = newWindow

# ACK受信時のコールバック
proc onDatagramAcked*(dgram: Http3DatagramManager, datagramId: uint64) =
  # インフライトカウントを減らす
  if dgram.inflightDatagrams > 0:
    dgram.inflightDatagrams -= 1
  
  # 信頼性モードの場合、ACK受信を記録
  if dgram.settings.enableReliableMode and datagramId in dgram.pendingReliableDatagrams:
    var datagram = dgram.pendingReliableDatagrams[datagramId]
    datagram.ackReceived = true
    dgram.pendingReliableDatagrams[datagramId] = datagram

# データグラム廃棄時のコールバック
proc onDatagramLost*(dgram: Http3DatagramManager, datagramId: uint64) =
  # 損失統計を更新
  dgram.lostDatagrams += 1
  
  # 再送処理（信頼性モードの場合）
  if dgram.settings.enableReliableMode and datagramId in dgram.pendingReliableDatagrams:
    var datagram = dgram.pendingReliableDatagrams[datagramId]
    if datagram.retries < datagram.maxRetries:
      # 非同期で再送処理をスケジュール
      asyncCheck dgram.sendDatagram(datagram.data, datagram.id)

# 新しいデータグラムフロー作成
proc createDatagramFlow*(dgram: Http3DatagramManager, priority: int = 0): uint32 =
  # 一意のフローID生成
  var flowId: uint32 = 0
  while true:
    flowId = uint32(rand(1'i32..0x7FFFFFFF'i32))
    if flowId != 0 and flowId notin dgram.activeFlows:
      break
  
  # フロー状態作成
  dgram.activeFlows[flowId] = DatagramFlowState(
    flowId: flowId,
    priority: priority,
    createdTime: getTime(),
    lastActivity: getTime(),
    bytesSent: 0,
    bytesReceived: 0,
    datagramsSent: 0,
    datagramsReceived: 0,
    currentWindow: dgram.settings.flowControlWindow,
    isActive: true
  )
  
  return flowId

# データグラムフロー終了
proc closeDatagramFlow*(dgram: Http3DatagramManager, flowId: uint32) =
  if flowId in dgram.activeFlows:
    var flow = dgram.activeFlows[flowId]
    flow.isActive = false
    dgram.activeFlows[flowId] = flow

# データグラム統計を取得
proc getDatagramStats*(dgram: Http3DatagramManager): tuple[
  sent: uint64, 
  received: uint64, 
  lost: uint64, 
  inflight: int, 
  flows: int, 
  window: uint32
] =
  return (
    sent: dgram.sentDatagrams,
    received: dgram.receivedDatagrams,
    lost: dgram.lostDatagrams,
    inflight: dgram.inflightDatagrams,
    flows: dgram.activeFlows.len,
    window: dgram.flowWindow
  )

# データグラム圧縮機能
when defined(enableDatagramCompression):
  import zip/zlib
  
  # データグラム圧縮
  proc compressDatagramPayload*(data: seq[byte], level: int = 6): seq[byte] =
    if data.len <= 20:  # 小さすぎるデータは圧縮しない
      return data
    
    try:
      result = compress(cast[string](data), level)
      if result.len >= data.len:  # 圧縮が効果的でない場合
        return data
      return cast[seq[byte]](result)
    except:
      return data
  
  # データグラム解凍
  proc decompressDatagramPayload*(data: seq[byte]): seq[byte] =
    try:
      let decompressed = uncompress(cast[string](data))
      return cast[seq[byte]](decompressed)
    except:
      return data

# WebTransport関連拡張
when defined(webTransportEnabled):
  # WebTransport用データグラムコンテキスト
  type WebTransportDatagramContext* = ref object
    baseFlowId*: uint32
    sessionId*: uint64
    isActive*: bool
    manager*: Http3DatagramManager
  
  # WebTransport用データグラム送信
  proc sendWebTransportDatagram*(ctx: WebTransportDatagramContext, 
                               data: seq[byte], 
                               priority: int = 0): Future[bool] {.async.} =
    if not ctx.isActive or ctx.manager == nil:
      return false
    
    let id = ctx.manager.createDatagramId(
      DATAGRAM_QOS_BEST_EFFORT,
      ctx.baseFlowId,
      uint32(ctx.sessionId and 0xFFFFFFFF)
    )
    
    return await ctx.manager.sendDatagram(data, id)
  
  # WebTransport用データグラムコンテキスト作成
  proc createWebTransportContext*(dgram: Http3DatagramManager, 
                                sessionId: uint64): WebTransportDatagramContext =
    result = WebTransportDatagramContext(
      baseFlowId: dgram.createDatagramFlow(),
      sessionId: sessionId,
      isActive: true,
      manager: dgram
    )

# HTTP/3クライアント拡張
proc setupDatagramManager*(client: Http3Client): Http3DatagramManager =
  # デフォルト設定
  let settings = DatagramSettings(
    maxDatagramSize: 1200,
    maxInflightDatagrams: 1024,
    flowControlWindow: 65536,
    enableQos: true,
    enableReliableMode: true,
    retransmitTimeout: 100,
    enablePrioritization: true,
    enableBatching: true,
    enableMultipath: false,
    batchingInterval: 5,
    adaptivePacing: true,
    enableCompression: false,
    compressionLevel: 6
  )
  
  # マネージャー作成
  result = newHttp3DatagramManager(client, settings)
  
  # クライアントにデータグラムマネージャーを設定
  # 本来はHttp3Client型に datagramManager フィールドを追加して設定すべき
  
  # 有効化を非同期で実行
  asyncCheck result.enableDatagrams()
  
  # バックグラウンドタスクとして信頼性モードのチェック処理を実行
  proc reliabilityChecker() {.async.} =
    while true:
      await sleepAsync(50)  # 50ms間隔でチェック
      await result.checkPendingReliableDatagrams()
  
  asyncCheck reliabilityChecker() 