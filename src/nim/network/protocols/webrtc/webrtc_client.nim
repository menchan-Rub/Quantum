## WebRTCクライアント実装
##
## Web Real-Time Communication (WebRTC) プロトコルのクライアント実装を提供します。
## P2P通信、シグナリング、ICE接続確立、データチャネル、メディアストリームの処理を行います。

import std/[asyncdispatch, options, strformat, strutils, tables, json, random, times]
import ../../../core/logging/logger
import ../../security/tls/tls_client
import ./webrtc_types
import ./webrtc_signaling
import ./webrtc_ice
import ./webrtc_sdp

type
  WebRtcConnectionState* = enum
    ## WebRTC接続状態
    wcsNew,          # 新規接続
    wcsConnecting,   # 接続中
    wcsConnected,    # 接続済み
    wcsDisconnected, # 切断（再接続可能性あり）
    wcsFailed,       # 接続失敗
    wcsClosed        # 接続終了
  
  WebRtcGatheringState* = enum
    ## ICE候補収集状態
    wgsNew,          # 収集開始前
    wgsGathering,    # 候補収集中
    wgsComplete      # 候補収集完了
  
  WebRtcSignalingState* = enum
    ## シグナリング状態
    wssStable,                 # 安定状態
    wssHaveLocalOffer,         # ローカルオファーあり
    wssHaveRemoteOffer,        # リモートオファーあり
    wssHaveLocalPranswer,      # ローカル事前応答あり
    wssHaveRemotePranswer,     # リモート事前応答あり
    wssClosed                  # クローズ状態
  
  WebRtcClient* = ref object
    ## WebRTCクライアント
    id*: string                      # クライアントID
    connectionState*: WebRtcConnectionState  # 接続状態
    gatheringState*: WebRtcGatheringState    # ICE候補収集状態
    signalingState*: WebRtcSignalingState    # シグナリング状態
    localDescription*: Option[SessionDescription]  # ローカルSDP
    remoteDescription*: Option[SessionDescription]  # リモートSDP
    localCandidates*: seq[IceCandidate]      # ローカルICE候補
    remoteCandidates*: seq[IceCandidate]     # リモートICE候補
    iceServers*: seq[IceServer]               # ICEサーバー（STUN/TURN）
    dataChannels*: Table[string, DataChannel]  # データチャネル
    signalingClient*: SignalingClient         # シグナリングクライアント
    iceClient*: IceClient                     # ICEクライアント
    logger*: Logger                           # ロガー
    configuration*: WebRtcConfiguration       # WebRTC設定
    isInitiator*: bool                        # オファー側かどうか
    isPolite*: bool                           # 礼儀正しいピアかどうか
    dtlsFingerprint*: string                  # DTLSフィンガープリント
    lastActivity*: Time                       # 最後のアクティビティ時間
    
    # コールバック
    onConnectionStateChange*: proc(client: WebRtcClient, state: WebRtcConnectionState) {.closure, gcsafe.}
    onIceGatheringStateChange*: proc(client: WebRtcClient, state: WebRtcGatheringState) {.closure, gcsafe.}
    onSignalingStateChange*: proc(client: WebRtcClient, state: WebRtcSignalingState) {.closure, gcsafe.}
    onIceCandidate*: proc(client: WebRtcClient, candidate: IceCandidate) {.closure, gcsafe.}
    onDataChannel*: proc(client: WebRtcClient, channel: DataChannel) {.closure, gcsafe.}
    onNegotiationNeeded*: proc(client: WebRtcClient) {.closure, gcsafe.}
    onError*: proc(client: WebRtcClient, error: string) {.closure, gcsafe.}

proc newWebRtcClient*(
  id: string = "",
  configuration: WebRtcConfiguration = nil,
  signalingClient: SignalingClient = nil,
  iceClient: IceClient = nil,
  logger: Logger = nil,
  isInitiator: bool = false,
  isPolite: bool = true
): WebRtcClient =
  ## 新しいWebRTCクライアントを作成する
  ##
  ## 引数:
  ##   id: クライアントID（空の場合はランダムID）
  ##   configuration: WebRTC設定
  ##   signalingClient: シグナリングクライアント（nilの場合は作成）
  ##   iceClient: ICEクライアント（nilの場合は作成）
  ##   logger: ロガー
  ##   isInitiator: このクライアントがオファー側かどうか
  ##   isPolite: 礼儀正しいピア（衝突解決時に譲歩する側）かどうか
  ##
  ## 戻り値:
  ##   WebRtcClientオブジェクト
  
  randomize()
  
  # ID生成（空の場合）
  let clientId = if id.len > 0: id else: generateRandomId()
  
  # 設定の初期化
  let config = if configuration.isNil: newWebRtcConfiguration() else: configuration
  
  # ロガーの初期化
  let clientLogger = if logger.isNil: newLogger("WebRtcClient") else: logger
  
  # シグナリングクライアントの初期化
  let signaling = if signalingClient.isNil: newSignalingClient(clientId, clientLogger) else: signalingClient
  
  # ICEクライアントの初期化
  let ice = if iceClient.isNil: newIceClient(config.iceServers, clientLogger) else: iceClient
  
  # DTLSフィンガープリントの生成
  let fingerprint = generateDtlsFingerprint()
  
  result = WebRtcClient(
    id: clientId,
    connectionState: wcsNew,
    gatheringState: wgsNew,
    signalingState: wssStable,
    localDescription: none(SessionDescription),
    remoteDescription: none(SessionDescription),
    localCandidates: @[],
    remoteCandidates: @[],
    iceServers: config.iceServers,
    dataChannels: initTable[string, DataChannel](),
    signalingClient: signaling,
    iceClient: ice,
    logger: clientLogger,
    configuration: config,
    isInitiator: isInitiator,
    isPolite: isPolite,
    dtlsFingerprint: fingerprint,
    lastActivity: getTime()
  )
  
  # シグナリングクライアントのコールバックを設定
  signaling.onMessage = proc(message: SignalingMessage) {.async.} =
    await result.handleSignalingMessage(message)
  
  # ICEクライアントのコールバックを設定
  ice.onCandidate = proc(candidate: IceCandidate) {.async.} =
    await result.handleIceCandidate(candidate)
  
  ice.onConnectionStateChange = proc(state: IceConnectionState) {.async.} =
    await result.handleIceConnectionStateChange(state)

proc handleError(client: WebRtcClient, error: string) =
  ## エラー処理
  client.logger.error(fmt"WebRTC error: {error}")
  if not client.onError.isNil:
    try:
      client.onError(client, error)
    except:
      client.logger.error(fmt"Error in onError callback: {getCurrentExceptionMsg()}")

proc updateConnectionState(client: WebRtcClient, state: WebRtcConnectionState) =
  ## 接続状態を更新する
  if client.connectionState != state:
    client.connectionState = state
    client.lastActivity = getTime()
    
    client.logger.info(fmt"WebRTC connection state changed to: {state}")
    
    if not client.onConnectionStateChange.isNil:
      try:
        client.onConnectionStateChange(client, state)
      except:
        client.logger.error(fmt"Error in onConnectionStateChange callback: {getCurrentExceptionMsg()}")

proc updateGatheringState(client: WebRtcClient, state: WebRtcGatheringState) =
  ## ICE候補収集状態を更新する
  if client.gatheringState != state:
    client.gatheringState = state
    client.lastActivity = getTime()
    
    client.logger.info(fmt"WebRTC ICE gathering state changed to: {state}")
    
    if not client.onIceGatheringStateChange.isNil:
      try:
        client.onIceGatheringStateChange(client, state)
      except:
        client.logger.error(fmt"Error in onIceGatheringStateChange callback: {getCurrentExceptionMsg()}")

proc updateSignalingState(client: WebRtcClient, state: WebRtcSignalingState) =
  ## シグナリング状態を更新する
  if client.signalingState != state:
    client.signalingState = state
    client.lastActivity = getTime()
    
    client.logger.info(fmt"WebRTC signaling state changed to: {state}")
    
    if not client.onSignalingStateChange.isNil:
      try:
        client.onSignalingStateChange(client, state)
      except:
        client.logger.error(fmt"Error in onSignalingStateChange callback: {getCurrentExceptionMsg()}")

proc handleSignalingMessage(client: WebRtcClient, message: SignalingMessage) {.async.} =
  ## シグナリングメッセージを処理する
  client.lastActivity = getTime()
  
  case message.type
  of smtOffer:
    # オファーの処理
    try:
      let offerSdp = parseSessionDescription(message.sdp)
      
      # Glare状態（衝突）の処理
      if client.signalingState == wssHaveLocalOffer:
        if client.isPolite:
          # 礼儀正しいピアは自分のオファーを破棄して受信したオファーを処理
          client.logger.info("Glare detected: Polite peer rolling back")
          client.localDescription = none(SessionDescription)
          client.updateSignalingState(wssStable)
        else:
          # 非礼儀的なピアは受信したオファーを無視
          client.logger.info("Glare detected: Impolite peer ignoring offer")
          return
      
      # リモート説明を設定
      client.remoteDescription = some(offerSdp)
      client.updateSignalingState(wssHaveRemoteOffer)
      
      # ICEの再起動が必要な場合は処理
      if message.iceRestart:
        await client.iceClient.restartIce()
      
      # 応答を作成して送信
      let answer = await client.createAnswer()
      await client.setLocalDescription(answer)
      
      # シグナリングサーバーに応答を送信
      await client.signalingClient.sendMessage(SignalingMessage(
        type: smtAnswer,
        sdp: answer.sdp,
        targetId: message.sourceId,
        sourceId: client.id
      ))
    except:
      let errMsg = getCurrentExceptionMsg()
      client.handleError(fmt"Error processing offer: {errMsg}")
  
  of smtAnswer:
    # 応答の処理
    try:
      let answerSdp = parseSessionDescription(message.sdp)
      
      # リモート説明を設定
      client.remoteDescription = some(answerSdp)
      client.updateSignalingState(wssStable)
      
      # すべてのリモート候補を追加
      for candidate in client.remoteCandidates:
        await client.iceClient.addRemoteCandidate(candidate)
    except:
      let errMsg = getCurrentExceptionMsg()
      client.handleError(fmt"Error processing answer: {errMsg}")
  
  of smtIceCandidate:
    # ICE候補の処理
    try:
      let candidate = parseIceCandidate(message.candidate)
      client.remoteCandidates.add(candidate)
      
      # リモート説明が設定済みの場合は候補を追加
      if client.remoteDescription.isSome:
        await client.iceClient.addRemoteCandidate(candidate)
    except:
      let errMsg = getCurrentExceptionMsg()
      client.handleError(fmt"Error processing ICE candidate: {errMsg}")
  
  of smtIceRestart:
    # ICE再起動の処理
    await client.iceClient.restartIce()
    
    # 再ネゴシエーションが必要
    if not client.onNegotiationNeeded.isNil:
      try:
        client.onNegotiationNeeded(client)
      except:
        client.logger.error(fmt"Error in onNegotiationNeeded callback: {getCurrentExceptionMsg()}")

proc handleIceCandidate(client: WebRtcClient, candidate: IceCandidate) {.async.} =
  ## ICE候補を処理する
  client.localCandidates.add(candidate)
  client.lastActivity = getTime()
  
  # シグナリングサーバーに候補を送信
  if client.remoteDescription.isSome:
    let candidateStr = formatIceCandidate(candidate)
    
    await client.signalingClient.sendMessage(SignalingMessage(
      type: smtIceCandidate,
      candidate: candidateStr,
      sourceId: client.id,
      targetId: ""  # ピアIDが不明な場合はブロードキャスト
    ))
  
  # コールバックを呼び出す
  if not client.onIceCandidate.isNil:
    try:
      client.onIceCandidate(client, candidate)
    except:
      client.logger.error(fmt"Error in onIceCandidate callback: {getCurrentExceptionMsg()}")

proc handleIceConnectionStateChange(client: WebRtcClient, state: IceConnectionState) {.async.} =
  ## ICE接続状態変更を処理する
  client.lastActivity = getTime()
  
  # WebRTC接続状態に変換
  case state
  of icsNew, icsChecking:
    client.updateConnectionState(wcsConnecting)
  of icsConnected, icsCompleted:
    client.updateConnectionState(wcsConnected)
  of icsDisconnected:
    client.updateConnectionState(wcsDisconnected)
  of icsFailed:
    client.updateConnectionState(wcsFailed)
  of icsClosed:
    client.updateConnectionState(wcsClosed)

proc createOffer*(client: WebRtcClient): Future[SessionDescription] {.async.} =
  ## オファーを作成する
  ##
  ## 戻り値:
  ##   セッション説明（SDP）
  
  client.logger.info("Creating WebRTC offer")
  
  # ICE収集の開始
  client.updateGatheringState(wgsGathering)
  await client.iceClient.gatherCandidates()
  
  # SDPの作成
  var sdp = createBaseSdp(client.dtlsFingerprint)
  
  # データチャネル情報を追加
  for id, channel in client.dataChannels:
    sdp &= createDataChannelSdp(channel)
  
  # メディアトラック情報を追加
  for track in client.localTracks:
    sdp &= createMediaTrackSdp(track)
  
  # ICE候補を追加
  for candidate in client.localCandidates:
    sdp &= formatIceCandidateSdp(candidate)
  
  # セキュリティパラメータを追加
  sdp &= createSecuritySdp(client.dtlsParameters)
  
  # 帯域幅制限情報を追加
  if client.bandwidthConstraints.isSome:
    sdp &= createBandwidthSdp(client.bandwidthConstraints.get())
  
  # オファーの設定
  let offer = SessionDescription(
    type: "offer",
    sdp: sdp,
    timestamp: getTime()
  )
  
  client.logger.debug(fmt"Created offer: {sdp}")
  
  # 統計情報の更新
  client.stats.offersCreated += 1
  client.stats.lastOfferTime = getTime()
  
  return offer

proc createAnswer*(client: WebRtcClient): Future[SessionDescription] {.async.} =
  ## 応答を作成する
  ##
  ## 戻り値:
  ##   セッション説明（SDP）
  
  client.logger.info("Creating WebRTC answer")
  
  if client.remoteDescription.isNone:
    client.handleError("Cannot create answer: No remote description")
    raise newException(WebRtcError, "No remote description")
  
  # ICE収集の開始
  client.updateGatheringState(wgsGathering)
  await client.iceClient.gatherCandidates()
  
  # SDPの作成
  var sdp = createBaseSdp(client.dtlsFingerprint)
  
  # リモートSDPを解析
  let remoteSdp = client.remoteDescription.get().sdp
  let remoteOfferParams = parseSdp(remoteSdp)
  
  # データチャネル情報を追加（リモートオファーに基づく）
  for dcParam in remoteOfferParams.dataChannels:
    # 既存のチャネルがなければ作成
    if not client.dataChannels.hasKey(dcParam.id):
      let newChannel = createDataChannel(client, dcParam.label, dcParam.id, dcParam.options)
      client.dataChannels[dcParam.id] = newChannel
    
    # 応答SDPにデータチャネル情報を追加
    sdp &= createDataChannelSdp(client.dataChannels[dcParam.id])
  
  # メディアトラック情報を追加（リモートオファーに基づく）
  for trackParam in remoteOfferParams.mediaTracks:
    # 対応するローカルトラックを探す
    let localTrack = client.findMatchingLocalTrack(trackParam)
    if localTrack.isSome:
      sdp &= createMediaTrackSdp(localTrack.get())
    else:
      # 受信のみのトラックとして追加
      sdp &= createReceiveOnlyTrackSdp(trackParam)
  
  # ICE候補を追加
  for candidate in client.localCandidates:
    sdp &= formatIceCandidateSdp(candidate)
  
  # セキュリティパラメータを追加（リモートオファーと互換性のあるもの）
  sdp &= createCompatibleSecuritySdp(remoteOfferParams.security, client.dtlsParameters)
  
  # 帯域幅制限情報を追加（リモートオファーの制約を考慮）
  let bandwidthParams = calculateBandwidthParams(
    remoteOfferParams.bandwidth, 
    client.bandwidthConstraints
  )
  sdp &= createBandwidthSdp(bandwidthParams)
  
  # 応答の設定
  let answer = SessionDescription(
    type: "answer",
    sdp: sdp,
    timestamp: getTime()
  )
  
  client.logger.debug(fmt"Created answer: {sdp}")
  
  # 統計情報の更新
  client.stats.answersCreated += 1
  client.stats.lastAnswerTime = getTime()
  
  return answer

proc setLocalDescription*(client: WebRtcClient, description: SessionDescription) {.async.} =
  ## ローカル説明を設定する
  ##
  ## 引数:
  ##   description: セッション説明（SDP）
  
  client.logger.info(fmt"Setting local description: {description.type}")
  
  # 状態を更新
  case description.type.toLowerAscii()
  of "offer":
    client.updateSignalingState(wssHaveLocalOffer)
  of "answer":
    client.updateSignalingState(wssStable)
  of "pranswer":
    client.updateSignalingState(wssHaveLocalPranswer)
  else:
    client.handleError(fmt"Unknown description type: {description.type}")
    raise newException(WebRtcError, fmt"Unknown description type: {description.type}")
  
  # ローカル説明を保存
  client.localDescription = some(description)
  
  # ICEに情報を伝達
  await client.iceClient.setLocalDescription(description)
  
  # すべてのICE候補が集まったらギャザリング完了
  if client.iceClient.isCandidateGatheringComplete():
    client.updateGatheringState(wgsComplete)

proc setRemoteDescription*(client: WebRtcClient, description: SessionDescription) {.async.} =
  ## リモート説明を設定する
  ##
  ## 引数:
  ##   description: セッション説明（SDP）
  
  client.logger.info(fmt"Setting remote description: {description.type}")
  
  # 状態を更新
  case description.type.toLowerAscii()
  of "offer":
    if client.signalingState == wssHaveLocalOffer and not client.isPolite:
      # Glare状態で非礼儀的なピアは処理しない
      client.handleError("Cannot set remote offer while local offer exists")
      raise newException(WebRtcError, "Glare detected, ignoring remote offer")
    client.updateSignalingState(wssHaveRemoteOffer)
  of "answer":
    if client.signalingState != wssHaveLocalOffer:
      client.handleError("Cannot set remote answer in current state")
      raise newException(WebRtcError, "Invalid state for remote answer")
    client.updateSignalingState(wssStable)
  of "pranswer":
    client.updateSignalingState(wssHaveRemotePranswer)
  else:
    client.handleError(fmt"Unknown description type: {description.type}")
    raise newException(WebRtcError, fmt"Unknown description type: {description.type}")
  
  # リモート説明を保存
  client.remoteDescription = some(description)
  
  # ICEに情報を伝達
  await client.iceClient.setRemoteDescription(description)
  
  # リモートSDPからデータチャネルを設定
  await client.setupDataChannelsFromSdp(description.sdp)
  
  # 保留中のICE候補をすべて追加
  for candidate in client.remoteCandidates:
    await client.iceClient.addRemoteCandidate(candidate)

proc setupDataChannelsFromSdp(client: WebRtcClient, sdp: string) {.async.} =
  ## SDPからデータチャネル情報を抽出して設定する
  ##
  ## 引数:
  ##   sdp: セッション記述プロトコル文字列
  
  # SDPからデータチャネル情報を抽出
  let channels = extractDataChannelsFromSdp(sdp)
  
  for channel in channels:
    # 既存のチャネルは無視
    if client.dataChannels.hasKey(channel.label):
      continue
    
    # リモートから提供されたデータチャネルを作成
    let newChannel = DataChannel(
      id: channel.id,
      label: channel.label,
      ordered: channel.ordered,
      maxPacketLifeTime: channel.maxPacketLifeTime,
      maxRetransmits: channel.maxRetransmits,
      protocol: channel.protocol,
      negotiated: true,
      state: dsConnecting
    )
    
    # チャネルを登録
    client.dataChannels[channel.label] = newChannel
    
    # コールバックを呼び出す
    if not client.onDataChannel.isNil:
      try:
        client.onDataChannel(client, newChannel)
      except:
        client.logger.error(fmt"Error in onDataChannel callback: {getCurrentExceptionMsg()}")

proc connect*(client: WebRtcClient, peerId: string = ""): Future[bool] {.async.} =
  ## WebRTC接続を開始する
  ##
  ## 引数:
  ##   peerId: 接続先のピアID（空の場合はシグナリングサーバーに任せる）
  ##
  ## 戻り値:
  ##   接続初期化成功の場合はtrue、失敗の場合はfalse
  
  client.logger.info(fmt"Initiating WebRTC connection to peer: {if peerId.len > 0: peerId else: 'any'}")
  
  # シグナリングサーバーに接続
  let connected = await client.signalingClient.connect()
  if not connected:
    client.handleError("Failed to connect to signaling server")
    return false
  
  # イニシエーターの場合はオファーを作成して送信
  if client.isInitiator:
    try:
      let offer = await client.createOffer()
      await client.setLocalDescription(offer)
      
      # シグナリングサーバーにオファーを送信
      await client.signalingClient.sendMessage(SignalingMessage(
        type: smtOffer,
        sdp: offer.sdp,
        sourceId: client.id,
        targetId: peerId
      ))
      
      client.logger.info("Sent WebRTC offer")
      return true
    except:
      let errMsg = getCurrentExceptionMsg()
      client.handleError(fmt"Failed to create and send offer: {errMsg}")
      return false
  
  # リスポンダーの場合は相手からのオファーを待つ
  client.logger.info("Waiting for WebRTC offer")
  return true

proc createDataChannel*(client: WebRtcClient, label: string, 
                       options: DataChannelOptions = nil): Future[DataChannel] {.async.} =
  ## データチャネルを作成する
  ##
  ## 引数:
  ##   label: チャネルラベル
  ##   options: チャネルオプション
  ##
  ## 戻り値:
  ##   作成されたDataChannelオブジェクト
  
  if client.dataChannels.hasKey(label):
    client.handleError(fmt"Data channel with label '{label}' already exists")
    raise newException(WebRtcError, fmt"Data channel with label '{label}' already exists")
  
  # オプションの設定
  let channelOptions = if options.isNil: newDataChannelOptions() else: options
  
  # チャネルIDの生成（既存IDと衝突しないように）
  var channelId = rand(0..65535)
  while true:
    var idExists = false
    for _, channel in client.dataChannels:
      if channel.id == channelId:
        idExists = true
        break
    
    if not idExists:
      break
    
    channelId = rand(0..65535)
  
  # データチャネルの作成
  let channel = DataChannel(
    id: channelId,
    label: label,
    ordered: channelOptions.ordered,
    maxPacketLifeTime: channelOptions.maxPacketLifeTime,
    maxRetransmits: channelOptions.maxRetransmits,
    protocol: channelOptions.protocol,
    negotiated: channelOptions.negotiated,
    state: dsConnecting
  )
  
  # チャネルを登録
  client.dataChannels[label] = channel
  
  # ネゴシエーションが必要な場合はコールバックを呼び出す
  if not channelOptions.negotiated and not client.onNegotiationNeeded.isNil:
    try:
      client.onNegotiationNeeded(client)
    except:
      client.logger.error(fmt"Error in onNegotiationNeeded callback: {getCurrentExceptionMsg()}")
  
  client.logger.info(fmt"Created data channel: {label}")
  return channel

proc sendData*(client: WebRtcClient, channelLabel: string, data: string): Future[bool] {.async.} =
  ## データチャネルを通じてデータを送信する
  ##
  ## 引数:
  ##   channelLabel: チャネルラベル
  ##   data: 送信するデータ
  ##
  ## 戻り値:
  ##   送信成功の場合はtrue、失敗の場合はfalse
  
  if not client.dataChannels.hasKey(channelLabel):
    client.handleError(fmt"Data channel '{channelLabel}' not found")
    return false
  
  let channel = client.dataChannels[channelLabel]
  
  # チャネル状態のチェック
  if channel.state != dsOpen:
    client.handleError(fmt"Data channel '{channelLabel}' is not open")
    return false
  
  try:
    # SCTPを使用してデータを送信
    let dataBytes = cast[seq[byte]](data)
    let sctp = client.sctpTransport
    
    # 送信前にデータチャネルの状態を再確認
    if channel.state != dsOpen:
      client.logger.warn(fmt"Data channel '{channelLabel}' state changed to {channel.state} during send operation")
      return false
    
    # 輻輳制御のためのバッファサイズチェック
    if sctp.bufferedAmount > sctp.maxBufferedAmount:
      client.logger.warn(fmt"SCTP buffer overflow on channel '{channelLabel}': {sctp.bufferedAmount}/{sctp.maxBufferedAmount}")
      # バッファが空くまで待機
      let waitResult = await sctp.waitForBufferSpace(client.config.sendTimeout)
      if not waitResult:
        client.handleError(fmt"Send timeout on channel '{channelLabel}': buffer full")
        return false
    
    # 優先度に基づいて送信キューに追加
    let priority = if channel.priority == 0: dpNormal else: channel.priority
    let messageId = client.nextMessageId
    inc client.nextMessageId
    
    # メッセージの分割が必要かチェック
    if dataBytes.len > sctp.maxMessageSize:
      # 大きなメッセージを複数のチャンクに分割
      const chunkSize = 16384 # 16KB chunks
      var sentChunks = 0
      let totalChunks = (dataBytes.len + chunkSize - 1) div chunkSize
      
      for i in 0..<totalChunks:
        let startIdx = i * chunkSize
        let endIdx = min(startIdx + chunkSize, dataBytes.len)
        let chunk = dataBytes[startIdx..<endIdx]
        let isLast = i == totalChunks - 1
        
        # チャンクをSCTPで送信
        let sendResult = await sctp.sendMessage(
          channelId = channel.id,
          data = chunk,
          ppid = WEBRTC_PPID_STRING,
          ordered = channel.ordered,
          messageId = messageId,
          isFragment = totalChunks > 1,
          isLastFragment = isLast,
          priority = priority
        )
        
        if not sendResult:
          client.handleError(fmt"Failed to send chunk {i+1}/{totalChunks} on channel '{channelLabel}'")
          return false
        
        inc sentChunks
        
        # 送信レート制限（必要に応じて）
        if client.config.rateLimitEnabled and i < totalChunks - 1:
          await sleepAsync(client.config.chunkSendInterval)
      
      client.logger.debug(fmt"Sent fragmented data on channel '{channelLabel}': {data.len} bytes in {sentChunks} chunks")
    else:
      # 単一メッセージとして送信
      let sendResult = await sctp.sendMessage(
        channelId = channel.id,
        data = dataBytes,
        ppid = WEBRTC_PPID_STRING,
        ordered = channel.ordered,
        messageId = messageId,
        isFragment = false,
        isLastFragment = true,
        priority = priority
      )
      
      if not sendResult:
        client.handleError(fmt"Failed to send message on channel '{channelLabel}'")
        return false
      
      client.logger.debug(fmt"Sent data on channel '{channelLabel}': {data.len} bytes")
    
    # 統計情報の更新
    client.stats.bytesSent += data.len
    inc client.stats.messagesSent
    client.lastActivity = getTime()
    
    # 送信完了イベントの発火（非同期）
    if not client.onDataSent.isNil:
      try:
        asyncCheck client.onDataSent(client, channelLabel, data.len)
      except:
        client.logger.error(fmt"Error in onDataSent callback: {getCurrentExceptionMsg()}")
    
    return true
  except CatchableError as e:
    let errMsg = e.msg
    client.handleError(fmt"Failed to send data on channel '{channelLabel}': {errMsg}")
    
    # 接続状態の確認と必要に応じた再接続
    if client.connectionState == csConnected:
      client.checkConnectionHealth()
    
    return false
  except:
    let errMsg = getCurrentExceptionMsg()
    client.handleError(fmt"Unexpected error sending data on channel '{channelLabel}': {errMsg}")
    client.logger.error(getStackTrace(getCurrentException()))
    return false

proc closeDataChannel*(client: WebRtcClient, channelLabel: string): Future[bool] {.async.} =
  ## データチャネルを閉じる
  ##
  ## 引数:
  ##   channelLabel: チャネルラベル
  ##
  ## 戻り値:
  ##   成功の場合はtrue、失敗の場合はfalse
  
  if not client.dataChannels.hasKey(channelLabel):
    client.handleError(fmt"Data channel '{channelLabel}' not found")
    return false
  
  try:
    # チャネル状態を更新
    var channel = client.dataChannels[channelLabel]
    channel.state = dsClosed
    client.dataChannels[channelLabel] = channel
    
    client.logger.info(fmt"Closed data channel: {channelLabel}")
    return true
  except:
    let errMsg = getCurrentExceptionMsg()
    client.handleError(fmt"Failed to close data channel: {errMsg}")
    return false

proc restartIce*(client: WebRtcClient): Future[bool] {.async.} =
  ## ICE接続を再起動する
  ##
  ## 戻り値:
  ##   再起動開始成功の場合はtrue、失敗の場合はfalse
  
  try:
    # ICEクライアントを再起動
    await client.iceClient.restartIce()
    
    # 再ネゴシエーションが必要
    if not client.onNegotiationNeeded.isNil:
      try:
        client.onNegotiationNeeded(client)
      except:
        client.logger.error(fmt"Error in onNegotiationNeeded callback: {getCurrentExceptionMsg()}")
    
    client.logger.info("ICE restart initiated")
    return true
  except:
    let errMsg = getCurrentExceptionMsg()
    client.handleError(fmt"Failed to restart ICE: {errMsg}")
    return false
proc close*(client: WebRtcClient) {.async.} =
  ## WebRTC接続を閉じる
  ##
  ## WebRTCクライアントのすべてのリソースを解放し、接続を終了します。
  ## データチャネル、ICE接続、シグナリング接続をすべて適切に閉じます。
  
  try:
    client.logger.debug("WebRTC接続のクローズを開始します")
    
    # すべてのデータチャネルを閉じる
    var channelCloseErrors = 0
    for label in toSeq(client.dataChannels.keys):
      if not await client.closeDataChannel(label):
        channelCloseErrors.inc
        client.logger.warn(fmt"データチャネル '{label}' のクローズに失敗しました")
    
    if channelCloseErrors > 0:
      client.logger.warn(fmt"{channelCloseErrors}個のデータチャネルのクローズに問題が発生しました")
    
    # ICEクライアントを閉じる
    try:
      await client.iceClient.close()
      client.logger.debug("ICEクライアントを正常に閉じました")
    except CatchableError as e:
      client.logger.error(fmt"ICEクライアントのクローズ中にエラーが発生しました: {e.msg}")
    
    # シグナリングクライアントを閉じる
    try:
      await client.signalingClient.disconnect()
      client.logger.debug("シグナリングクライアントを正常に切断しました")
    except CatchableError as e:
      client.logger.error(fmt"シグナリングクライアントの切断中にエラーが発生しました: {e.msg}")
    
    # DTLS接続を閉じる（存在する場合）
    if not client.dtlsConnection.isNil:
      try:
        await client.dtlsConnection.close()
        client.logger.debug("DTLS接続を正常に閉じました")
      except CatchableError as e:
        client.logger.error(fmt"DTLS接続のクローズ中にエラーが発生しました: {e.msg}")
    
    # SCTP関連リソースを解放（存在する場合）
    if not client.sctpAssociation.isNil:
      try:
        await client.sctpAssociation.shutdown()
        client.logger.debug("SCTP関連リソースを正常に解放しました")
      except CatchableError as e:
        client.logger.error(fmt"SCTP関連リソースの解放中にエラーが発生しました: {e.msg}")
    
    # 状態を更新
    client.updateConnectionState(wcsClosed)
    client.updateSignalingState(wssClosed)
    client.updateIceConnectionState(icsDisconnected)
    client.updateIceGatheringState(igsComplete)
    
    # イベントリスナーをクリア
    client.onIceCandidate = nil
    client.onDataChannel = nil
    client.onConnectionStateChange = nil
    client.onSignalingStateChange = nil
    client.onNegotiationNeeded = nil
    
    client.logger.info("WebRTC接続を完全に閉じました")
  except CatchableError as e:
    let errMsg = e.msg
    client.logger.error(fmt"WebRTC接続のクローズ中に予期しないエラーが発生しました: {errMsg}")
    client.handleError(fmt"接続クローズ中のエラー: {errMsg}")
  finally:
    # 最終的に接続状態を閉じた状態に設定
    client.updateConnectionState(wcsClosed)

# ユーティリティ関数
proc generateRandomId*(): string =
  ## ランダムなクライアントIDを生成する
  ##
  ## 戻り値:
  ##   16文字のランダムID（暗号論的に安全なランダム値）
  
  const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  result = ""
  
  # 暗号論的に安全な乱数を使用
  var cryptoRand = getCryptoRandom()
  
  for i in 0..<16:
    let idx = cryptoRand.getRandomInt(0, chars.high)
    result.add(chars[idx])
  
  return result

proc generateDtlsFingerprint*(): string =
  ## DTLSフィンガープリントを生成する
  ##
  ## WebRTC接続のセキュリティを確保するためのDTLS証明書のSHA-256フィンガープリントを生成します。
  ## 証明書マネージャから取得した証明書を使用し、標準形式のフィンガープリントを返します。
  ##
  ## 戻り値:
  ##   SHA-256フィンガープリント文字列（例: "sha-256 12:34:AB:CD:..."）
  
  try:
    # 証明書マネージャからWebRTC用証明書を取得
    let certManager = getCertificateManager()
    let cert = certManager.getOrCreateWebRtcCertificate()
    
    # 証明書からSHA-256フィンガープリントを生成
    let rawFingerprint = cert.generateFingerprint("sha-256")
    
    # コロン区切りの16進数文字列に変換
    var formattedFingerprint = newStringOfCap(95)  # "sha-256 " + 32バイト(コロン区切り)
    for i, b in rawFingerprint:
      if i > 0:
        formattedFingerprint.add(":")
      formattedFingerprint.add(toHex(int(b), 2).toUpperAscii())
    
    let result = "sha-256 " & formattedFingerprint
    return result
  except CertificateError as e:
    # 証明書関連のエラー
    let logger = getLogger("WebRtcClient")
    logger.error(fmt"証明書からのフィンガープリント生成に失敗しました: {e.msg}")
    raise newException(WebRtcError, fmt"DTLSフィンガープリント生成エラー: {e.msg}")
  except CatchableError as e:
    # その他のエラー
    let logger = getLogger("WebRtcClient")
    logger.error(fmt"DTLSフィンガープリント生成中に予期しないエラーが発生しました: {e.msg}")
    raise newException(WebRtcError, fmt"DTLSフィンガープリント生成エラー: {e.msg}")