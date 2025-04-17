## WebRTC型定義
##
## Web Real-Time Communication (WebRTC) で使用される基本的な型定義を提供します。

type
  # セッション記述
  SessionDescription* = object
    ## SDP（Session Description Protocol）による通信パラメータの記述
    type*: string   # offer, answer, prAnswerなど
    sdp*: string    # SDPフォーマットによる記述

  # ICE (Interactive Connectivity Establishment) 関連
  IceServer* = object
    ## STUN/TURNサーバー情報
    urls*: seq[string]   # サーバーURL
    username*: string    # 認証ユーザー名
    credential*: string  # 認証情報
  
  IceCandidate* = object
    ## ICE接続候補
    candidate*: string   # 候補文字列
    sdpMid*: string      # メディアストリームの識別子
    sdpMLineIndex*: int  # SDPにおけるメディア行インデックス
    usernameFragment*: string  # ICE username fragment

  IceConnectionState* = enum
    ## ICE接続状態
    icsNew,         # 未接続
    icsChecking,    # 接続確認中
    icsConnected,   # 接続済み
    icsCompleted,   # 接続完了
    icsFailed,      # 接続失敗
    icsClosed,      # 接続終了
    icsDisconnected # 一時的な切断

  # データチャネル関連
  DataChannelState* = enum
    ## データチャネル状態
    dsConnecting,  # 接続中
    dsOpen,        # 開通
    dsClosing,     # クローズ中
    dsClosed       # クローズ済み

  DataChannel* = object
    ## WebRTCデータチャネル
    id*: int                     # チャネル識別子
    label*: string               # チャネルラベル
    ordered*: bool               # 順序保証フラグ
    maxPacketLifeTime*: int      # 最大パケット寿命（ミリ秒）
    maxRetransmits*: int         # 最大再送回数
    protocol*: string            # アプリケーションプロトコル
    negotiated*: bool            # ネゴシエーションフラグ
    state*: DataChannelState     # チャネル状態

  DataChannelOptions* = ref object
    ## データチャネル作成オプション
    ordered*: bool               # 順序保証（デフォルト: true）
    maxPacketLifeTime*: int      # 最大パケット寿命（ミリ秒）
    maxRetransmits*: int         # 最大再送回数
    protocol*: string            # アプリケーションプロトコル
    negotiated*: bool            # ネゴシエーションフラグ

  # WebRTC設定
  WebRtcConfiguration* = ref object
    ## WebRTC接続設定
    iceServers*: seq[IceServer]       # ICEサーバーリスト
    iceTransportPolicy*: string       # ICEトランスポートポリシー
    bundlePolicy*: string             # バンドルポリシー
    rtcpMuxPolicy*: string            # RTCPマルチプレクスポリシー
    iceRestartEnabled*: bool          # ICE再起動有効フラグ
    sdpSemantics*: string             # SDP解釈方法

  # シグナリング関連
  SignalingMessageType* = enum
    ## シグナリングメッセージタイプ
    smtOffer,        # オファー
    smtAnswer,       # 応答
    smtIceCandidate, # ICE候補
    smtIceRestart    # ICE再起動

  SignalingMessage* = object
    ## シグナリングメッセージ
    type*: SignalingMessageType  # メッセージタイプ
    sdp*: string                 # SDP（オファー/応答用）
    candidate*: string           # ICE候補
    sourceId*: string            # 送信元ID
    targetId*: string            # 送信先ID
    iceRestart*: bool            # ICE再起動フラグ

  # エラー型
  WebRtcError* = object of CatchableError
    ## WebRTC関連エラー

proc newWebRtcConfiguration*(): WebRtcConfiguration =
  ## 新しいWebRTC設定を作成する
  ##
  ## 戻り値:
  ##   デフォルト設定のWebRtcConfiguration
  
  result = WebRtcConfiguration(
    iceServers: @[
      IceServer(urls: @["stun:stun.l.google.com:19302"])
    ],
    iceTransportPolicy: "all",
    bundlePolicy: "balanced",
    rtcpMuxPolicy: "require",
    iceRestartEnabled: true,
    sdpSemantics: "unified-plan"
  )

proc newDataChannelOptions*(): DataChannelOptions =
  ## 新しいデータチャネルオプションを作成する
  ##
  ## 戻り値:
  ##   デフォルト設定のDataChannelOptions
  
  result = DataChannelOptions(
    ordered: true,
    maxPacketLifeTime: -1,   # 制限なし
    maxRetransmits: -1,      # 制限なし
    protocol: "",
    negotiated: false
  ) 