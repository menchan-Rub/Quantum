## SSE（Server-Sent Events）型定義
##
## Server-Sent Events（SSE）プロトコルで使用される基本的な型定義を提供します。

type
  SseEvent* = object
    ## SSEイベント
    id*: string        # イベントID
    event*: string     # イベント名（指定がない場合は"message"）
    data*: string      # イベントデータ
    retry*: string     # 再接続時間（ミリ秒）
  
  SseEventBuffer* = object
    ## SSEイベントバッファ（ストリームから受信したイベントを構築するため）
    id*: string
    event*: string
    data*: string
    retry*: string

# 一定の文字列チェック
proc hasData*(buffer: SseEventBuffer): bool =
  ## イベントバッファにデータが含まれているかどうかをチェックする
  result = buffer.data.len > 0 or buffer.id.len > 0 or 
           buffer.event.len > 0 or buffer.retry.len > 0

proc buildEvent*(buffer: SseEventBuffer): SseEvent =
  ## バッファからSSEイベントを構築する
  result = SseEvent(
    id: buffer.id,
    event: if buffer.event.len > 0: buffer.event else: "message",
    data: buffer.data,
    retry: buffer.retry
  )

proc reset*(buffer: var SseEventBuffer) =
  ## イベントバッファをリセットする
  buffer.id = ""
  buffer.event = ""
  buffer.data = ""
  buffer.retry = ""

proc newSseEventBuffer*(): SseEventBuffer =
  ## 新しいSSEイベントバッファを作成する
  result = SseEventBuffer(
    id: "",
    event: "",
    data: "",
    retry: ""
  )

proc `$`*(event: SseEvent): string =
  ## SSEイベントを文字列に変換する
  result = "SseEvent(id: '"
  result.add(event.id)
  result.add("', event: '")
  result.add(event.event)
  result.add("', data: '")
  result.add(event.data)
  result.add("', retry: '")
  result.add(event.retry)
  result.add("')")

proc newSseEvent*(id = "", event = "message", data = "", retry = ""): SseEvent =
  ## 新しいSSEイベントを作成する
  result = SseEvent(
    id: id,
    event: event,
    data: data,
    retry: retry
  ) 