# ネットワークプロトコルモジュール

このモジュールは、ブラウザで使用される様々なネットワークプロトコルの実装を提供します。すべてのプロトコル実装はNim言語で記述され、非同期処理と高性能を重視しています。

## プロトコル一覧

このモジュールでは以下のプロトコルをサポートしています：

1. **WebSocket** - 双方向リアルタイム通信
2. **WebRTC** - ピアツーピアのリアルタイム通信
3. **Server-Sent Events (SSE)** - サーバーからクライアントへの単方向通信
4. **FTP** - ファイル転送プロトコル

## 共通の設計原則

すべてのプロトコル実装は、以下の設計原則に従っています：

- **非同期処理** - すべての通信はasync/awaitパターンを使用
- **厳格なエラー処理** - すべての例外的状況を適切に処理
- **セキュリティ重視** - セキュリティ脆弱性を防止する実装
- **メモリ効率** - 効率的なメモリ使用とリソース管理
- **拡張性** - 将来の拡張に対応できる柔軟な設計
- **ロギング** - 包括的なロギングによるデバッグ支援
- **再接続機能** - ネットワーク中断に対する堅牢性

## WebSocket プロトコル

WebSocketプロトコル（RFC 6455）実装は、HTTPベースの全二重通信チャネルを提供します。

### 主な機能

- HTTP/HTTPSからWebSocketへのアップグレード
- テキスト/バイナリメッセージの送受信
- Ping/Pongによる接続維持
- 自動再接続メカニズム
- メッセージフラグメンテーション処理
- サブプロトコルのサポート

### 使用例

```nim
import std/[asyncdispatch]
import network/protocols/websocket/websocket_client
import network/protocols/websocket/websocket_types

proc main() {.async.} =
  # WebSocketクライアントを作成
  var client = newWebSocketClient("wss://echo.websocket.org")
  
  # イベントハンドラを設定
  client.onOpen = proc(ws: WebSocketClient) =
    echo "接続が確立されました"
    asyncCheck ws.sendText("Hello, WebSocket!")
  
  client.onMessage = proc(ws: WebSocketClient, opCode: WebSocketOpCode, data: string) =
    echo "メッセージを受信: ", data
    if data == "Hello, WebSocket!":
      asyncCheck ws.close()
  
  client.onClose = proc(ws: WebSocketClient, code: uint16, reason: string) =
    echo "接続が閉じられました: ", reason
  
  # 接続を開始
  if await client.connect():
    # イベントストリームの受信を開始
    await client.listen()
  else:
    echo "接続に失敗しました"

# メインループを実行
waitFor main()
```

## WebRTC プロトコル

WebRTC（Web Real-Time Communication）は、ブラウザ間やアプリケーション間でピアツーピア通信を可能にするプロトコルです。

### 主な機能

- シグナリングによるピア発見
- ICE（Interactive Connectivity Establishment）による接続確立
- データチャネルによるメッセージング
- DTLS（Datagram Transport Layer Security）による暗号化
- STUN/TURNサーバー対応
- 接続状態の監視と管理

### 使用例

```nim
import std/[asyncdispatch]
import network/protocols/webrtc/webrtc_client
import network/protocols/webrtc/webrtc_types

proc main() {.async.} =
  # WebRTCクライアントを作成（イニシエーターとして）
  var client = newWebRtcClient(isInitiator = true)
  
  # イベントハンドラを設定
  client.onConnectionStateChange = proc(c: WebRtcClient, state: WebRtcConnectionState) =
    echo "接続状態が変化しました: ", state
  
  client.onDataChannel = proc(c: WebRtcClient, channel: DataChannel) =
    echo "新しいデータチャネルが開かれました: ", channel.label
  
  # データチャネルを作成
  let channel = await client.createDataChannel("chat")
  
  # メッセージ受信ハンドラを設定
  channel.onMessage = proc(c: DataChannel, data: string) =
    echo "メッセージを受信: ", data
  
  # 接続の確立
  await client.connect()
  
  # メッセージの送信（接続確立後）
  await channel.send("Hello, WebRTC!")
  
  # 接続を閉じる
  await client.close()

# メインループを実行
waitFor main()
```

## Server-Sent Events (SSE) プロトコル

Server-Sent Events（SSE）は、サーバーからクライアントへの単方向のリアルタイム更新を提供するHTTPベースのプロトコルです。

### 主な機能

- 軽量な単方向ストリーミング
- 自動再接続メカニズム
- イベントID、タイプによるメッセージの分類
- 標準的なHTTP/HTTPSを使用した通信
- 再接続時の最終イベントID保持
- カスタムイベントタイプのサポート

### 使用例

```nim
import std/[asyncdispatch]
import network/protocols/sse/sse_client
import network/protocols/sse/sse_types

proc main() {.async.} =
  # SSEクライアントを作成
  var client = newSseClient("https://example.com/events")
  
  # イベントハンドラを設定
  client.onOpen = proc(sse: SseClient) =
    echo "SSE接続が確立されました"
  
  client.onMessage = proc(sse: SseClient, event: SseEvent) =
    echo "イベント受信: ", event.event
    echo "データ: ", event.data
  
  client.onClose = proc(sse: SseClient) =
    echo "SSE接続が閉じられました"
  
  # 接続の確立
  if await client.connect():
    # イベントストリームの受信を開始
    await client.listen()
  else:
    echo "接続に失敗しました"
  
  # 接続を閉じる
  client.close()

# メインループを実行
waitFor main()
```

## FTP プロトコル

File Transfer Protocol（FTP、RFC 959）は、ホスト間でのファイル転送を可能にする標準的なネットワークプロトコルです。

### 主な機能

- 認証と接続管理
- アクティブモードとパッシブモード
- ファイルのアップロード/ダウンロード
- ディレクトリリスティング
- ASCII/バイナリ転送モード
- FTPSによるセキュア接続
- ファイル操作（名前変更、削除、ディレクトリ作成など）

### 使用例

```nim
import std/[asyncdispatch]
import network/protocols/ftp/ftp_client
import network/protocols/ftp/ftp_types

proc main() {.async.} =
  # FTPクライアントを作成
  var client = newFtpClient(
    host = "ftp.example.com",
    username = "user",
    password = "password",
    passive = true  # パッシブモードを使用
  )
  
  # 接続とログイン
  if await client.login():
    echo "ログイン成功"
    
    # 現在のディレクトリの内容を一覧表示
    let listing = await client.listDir(".")
    for file in listing:
      echo file.name, " (", file.size, " bytes)"
    
    # ファイルのダウンロード
    if await client.downloadFile("remote.txt", "local.txt"):
      echo "ファイルのダウンロードに成功しました"
    
    # ファイルのアップロード
    if await client.uploadFile("upload.txt", "remote_upload.txt"):
      echo "ファイルのアップロードに成功しました"
    
    # 接続を閉じる
    await client.quit()
  else:
    echo "ログインに失敗しました"

# メインループを実行
waitFor main()
```

## セキュリティ対策

すべてのプロトコル実装では、以下のセキュリティ対策を講じています：

1. **入力検証** - すべての外部入力を厳格に検証
2. **バッファサイズ制限** - バッファオーバーフローを防止
3. **タイムアウト処理** - 無限待機状態を防止
4. **TLS/SSL対応** - 安全な通信チャネルの確保
5. **メモリリーク防止** - 適切なリソース解放
6. **認証情報の保護** - パスワードなどの機密情報を適切に処理
7. **エラーメッセージの制限** - 詳細なエラー情報の漏洩を防止

## パフォーマンス最適化

1. **非ブロッキング処理** - すべての通信は非同期I/Oを使用
2. **適切なバッファサイズ** - メモリ使用を最適化
3. **コネクションプーリング** - 可能な場合は接続を再利用
4. **レート制限** - サーバー負荷を考慮した制御
5. **ストリーム処理** - 大きなデータを効率的に処理

## 実装上の注意点

1. 各プロトコルは関連する RFC 仕様に厳密に準拠しています
2. エラーハンドリングは包括的に実装されています
3. 複雑なネットワーク状況（NAT越え、ファイアウォールなど）を考慮しています
4. リソースリークを防ぐために適切なクリーンアップ処理を実装しています
5. すべての実装は拡張可能で、将来の要件変更に対応できます

## 拡張計画

1. **HTTP/3サポート** - 将来的にQUICベースのプロトコルに対応予定
2. **WebTransportサポート** - 新しいWeb標準の追加
3. **プロトコルの最適化** - パフォーマンスとメモリ使用量の継続的な改善
4. **MQTT、GRPCなどのサポート** - 追加プロトコルへの対応 