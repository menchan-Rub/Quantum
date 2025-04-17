## WebSocket型定義
##
## WebSocketプロトコル（RFC 6455）で使用される基本的な型定義を提供します。

type
  WebSocketOpCode* = enum
    ## WebSocketの操作コード
    Continuation = 0x0,  # 継続フレーム
    Text = 0x1,          # テキストフレーム
    Binary = 0x2,        # バイナリフレーム
    # 0x3-0x7 予約済み（非制御フレーム）
    Close = 0x8,         # 接続終了フレーム
    Ping = 0x9,          # Pingフレーム
    Pong = 0xA           # Pongフレーム
    # 0xB-0xF 予約済み（制御フレーム）

  WebSocketFrame* = object
    ## WebSocketフレーム構造
    fin*: bool                  # 最終フレームかどうか
    rsv1*: bool                 # 予約ビット1
    rsv2*: bool                 # 予約ビット2
    rsv3*: bool                 # 予約ビット3
    opCode*: WebSocketOpCode    # 操作コード
    masked*: bool               # マスクされているかどうか
    maskKey*: array[4, char]    # マスクキー
    payload*: string            # ペイロードデータ

  ResourceHint* = object
    ## リソースヒント（プリロード、プリコネクト、プリフェッチなど）
    hintType*: string           # ヒントタイプ（preload, preconnect, prefetch, dns-prefetch）
    url*: string                # 対象URL
    attributes*: seq[tuple[name: string, value: string]]  # 追加属性

  ProtocolError* = object of CatchableError
    ## プロトコルエラー例外
  
  InsufficientData* = object of CatchableError
    ## データ不足例外
  
  WebSocketClosedError* = object of CatchableError
    ## WebSocket切断例外 