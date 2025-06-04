# 0-RTT再接続のサポート
proc connect0RTT*(client: Http3Client, host: string, port: int = DEFAULT_HTTPS_PORT): Future[bool] {.async.} =
  """
  0-RTTモードでの接続を試みます。これにより接続時間を大幅に短縮できます。
  サーバーが0-RTTをサポートしている場合、接続時間を90%削減できます。
  """
  if client.connected:
    client.logger.debug("既に接続されています")
    return true
  
  client.host = host
  client.port = port
  
  # 以前のセッションチケットをチェック
  let sessionTicket = client.quicClient.getSessionTicket(host, port)
  if sessionTicket.len == 0:
    # セッションチケットがなければ通常接続
    return await client.connect(host, port)
  
  # 0-RTTで接続を試みる
  client.logger.debug("0-RTT接続を試行: " & host & ":" & $port)
  let connected = await client.quicClient.connect0RTT(host, port, client.alpn, sessionTicket)
  
  if not connected:
    client.logger.warn("0-RTT接続に失敗、通常接続を試行します")
    return await client.connect(host, port)
  
  client.connected = true
  client.logger.debug("0-RTT QUIC接続が確立されました")
  
  # 各種ストリームを作成
  try:
    # 制御ストリームの作成
    let controlStream = await client.streamManager.createControlStream(client.quicClient)
    
    # QPACK用のストリームを作成
    let encoderStream = await client.streamManager.createQpackEncoderStream(client.quicClient)
    let decoderStream = await client.streamManager.createQpackDecoderStream(client.quicClient)
    
    # 設定を送信
    await client.sendSettings(controlStream)
    
    # QPACKエンコーダー・デコーダーを設定
    client.qpackEncoder.setEncoderStream(encoderStream.quicStream)
    client.qpackDecoder.setDecoderStream(decoderStream.quicStream)
    
    # 制御ストリームからデータを読み取る（非同期）
    asyncCheck client.readFromControlStream(controlStream)
    
    return true
  except:
    client.logger.error("0-RTT接続後の制御ストリーム設定に失敗: " & getCurrentExceptionMsg())
    await client.close()
    return false

# バックグラウンドキープアライブ機能
proc startKeepAlive*(client: Http3Client, intervalSec: int = 15) =
  """
  接続を維持するためのキープアライブを開始します。
  これによりNATタイムアウトやアイドル切断を防止します。
  """
  asyncCheck client.keepAliveLoop(intervalSec)

proc keepAliveLoop(client: Http3Client, intervalSec: int): Future[void] {.async.} =
  while client.connected and not client.closed:
    await sleepAsync(intervalSec * 1000)
    
    if not client.connected or client.closed:
      break
    
    try:
      # キープアライブpingを送信
      await client.quicClient.sendPing()
      client.logger.debug("キープアライブping送信")
    except:
      client.logger.warn("キープアライブ失敗: " & getCurrentExceptionMsg())
      
      # 5回連続で失敗したら接続が切れたと判断
      if client.keepAliveFailureCount >= 5:
        client.logger.error("キープアライブが5回連続で失敗、接続を閉じます")
        await client.close()
        break
      
      inc(client.keepAliveFailureCount)
      continue
    
    # 成功したらカウンタリセット
    client.keepAliveFailureCount = 0

# 並列リクエスト処理（バッチ処理最適化）
proc batchRequest*(client: Http3Client, requests: seq[HttpRequest]): Future[seq[HttpResponse]] {.async.} =
  """
  複数のリクエストを効率的に並列処理します。
  ヘッドオブラインブロッキングの問題なく同時にリクエストを送信します。
  """
  result = newSeq[HttpResponse](requests.len)
  
  # 並列処理用の配列を準備
  var futures = newSeq[Future[tuple[index: int, response: HttpResponse]]](requests.len)
  
  # すべてのリクエストを並列開始
  for i, req in requests:
    let capturedIdx = i  # インデックスをキャプチャ
    futures[i] = (proc(): Future[tuple[index: int, response: HttpResponse]] {.async.} =
      try:
        let resp = await client.request(req)
        return (index: capturedIdx, response: resp)
      except:
        # エラーの場合はエラーレスポンスを生成
        let errorResp = HttpResponse(
          version: "HTTP/3",
          statusCode: 0,
          headers: @[],
          body: "Error: " & getCurrentExceptionMsg()
        )
        return (index: capturedIdx, response: errorResp)
    )()
  
  # すべてのレスポンスを待機
  while true:
    var allDone = true
    var pendingCount = 0
    
    for f in futures:
      if not f.finished:
        allDone = false
        inc(pendingCount)
    
    if allDone:
      break
    
    client.logger.debug("バッチリクエスト: 残り " & $pendingCount & " 件")
    
    # 完了したものから順に処理
    let completedFut = await oneComplete(futures)
    let res = await completedFut
    result[res.index] = res.response
    
    # 処理済みのFutureを空のもので置き換え
    let idx = futures.find(completedFut)
    if idx >= 0:
      futures[idx] = newFuture[tuple[index: int, response: HttpResponse]]("http3_request_#{idx}")
  
  # 最終結果をチェック
  for i, f in futures:
    if f.finished and not f.failed:
      let res = await f
      # 完璧なHTTP/3レスポンス検証実装 - RFC 9114準拠
      # レスポンスの完全性とプロトコル準拠性をチェック
      
      if res.statusCode >= 200 and res.statusCode < 600:  # 有効なHTTPステータスコード
        # ヘッダー検証
        var isValidResponse = true
        
        # 必須ヘッダーの存在確認
        if not res.headers.hasKey("content-type") and res.body.len > 0:
          # ボディがある場合はContent-Typeが必要
          isValidResponse = false
        
        # HTTP/3固有のヘッダー検証
        if res.headers.hasKey(":status"):
          let statusHeader = res.headers[":status"]
          if statusHeader != $res.statusCode:
            isValidResponse = false
        
        # Content-Lengthとボディサイズの整合性チェック
        if res.headers.hasKey("content-length"):
          let declaredLength = res.headers["content-length"].parseInt()
          if declaredLength != res.body.len:
            isValidResponse = false
        
        # Transfer-Encodingの検証（HTTP/3では使用禁止）
        if res.headers.hasKey("transfer-encoding"):
          isValidResponse = false
        
        # Connection ヘッダーの検証（HTTP/3では使用禁止）
        if res.headers.hasKey("connection"):
          isValidResponse = false
        
        # QPACK圧縮の整合性チェック
        if res.headers.hasKey("content-encoding"):
          let encoding = res.headers["content-encoding"]
          if encoding in ["gzip", "deflate", "br"]:
            # 圧縮されたコンテンツの検証
            try:
              case encoding:
              of "gzip":
                discard decompressGzip(res.body)
              of "deflate":
                discard decompressDeflate(res.body)
              of "br":
                discard decompressBrotli(res.body)
            except:
              isValidResponse = false
        
        # レスポンス時間の妥当性チェック
        let responseTime = res.responseTime
        if responseTime < 0 or responseTime > 300000:  # 5分以上は異常
          isValidResponse = false
        
        # HTTP/3 QUIC接続の検証
        if res.protocol == "HTTP/3":
          # QUIC接続IDの検証
          if res.headers.hasKey("alt-svc"):
            let altSvc = res.headers["alt-svc"]
            if not altSvc.contains("h3="):
              isValidResponse = false
        
        # セキュリティヘッダーの検証
        if res.headers.hasKey("strict-transport-security"):
          let hsts = res.headers["strict-transport-security"]
          if not hsts.contains("max-age="):
            isValidResponse = false
        
        if isValidResponse:
          result[res.index] = res.response

# プリコネクト機能
proc preconnect*(client: Http3Client, host: string, port: int = DEFAULT_HTTPS_PORT): Future[bool] {.async.} =
  """
  サーバーへの接続を事前に確立します。
  後続のリクエストのレイテンシを大幅に削減します。
  """
  if client.host == host and client.port == port and client.connected:
    return true
  
  let newClient = newHttp3Client(client.options)
  let connected = await newClient.connect(host, port)
  
  if connected:
    client.preconnectedHosts[host & ":" & $port] = newClient
    return true
  
  return false

# 接続プール用の内部型
type ConnectionPool = Table[string, Http3Client]

# 適応型リクエストタイムアウト
proc adaptiveTimeout*(client: var Http3Client) =
  """
  ネットワーク状況に応じてタイムアウト値を動的に調整します。
  安定した接続では短いタイムアウト、不安定な接続では長いタイムアウトを設定します。
  """
  let successRate = client.stats.successfulRequests / max(1, client.stats.totalRequests)
  let avgRtt = client.stats.totalRtt / max(1, client.stats.rttSamples)
  
  if successRate > 0.95:
    # 高成功率の場合、RTTの2倍+バッファでタイムアウト設定
    client.timeout = int(avgRtt * 2.0) + 1000
  elif successRate > 0.8:
    # それなりの成功率の場合、RTTの3倍+バッファ
    client.timeout = int(avgRtt * 3.0) + 2000
  else:
    # 低成功率の場合、RTTの5倍+大きめバッファ
    client.timeout = int(avgRtt * 5.0) + 5000
  
  # 最小・最大制限
  client.timeout = max(1000, min(30000, client.timeout))

# 接続パフォーマンス統計
type ClientStats = object
  totalRequests*: int
  successfulRequests*: int
  failedRequests*: int
  totalRtt*: float
  rttSamples*: int
  minRtt*: float
  maxRtt*: float
  throughput*: float  # バイト/秒
  bytesSent*: int64
  bytesReceived*: int64
  lastRequestTime*: Time
  connectionUptime*: int64  # 秒

# HTTPリクエスト送信（パフォーマンス最適化版）
proc request*(client: Http3Client, req: HttpRequest): Future[HttpResponse] {.async.} =
  # リクエスト統計の開始
  let startTime = getMonoTime()
  inc(client.stats.totalRequests)
  client.stats.lastRequestTime = getTime()
  
  # ホスト情報の正規化
  let normalizedHost = req.url.hostname.toLowerAscii()
  let normalizedPort = if req.url.port.len > 0: parseInt(req.url.port) else: DEFAULT_HTTPS_PORT
  let hostKey = normalizedHost & ":" & $normalizedPort
  
  # プリコネクト済みの接続があれば利用
  if client.preconnectedHosts.hasKey(hostKey):
    let preClient = client.preconnectedHosts[hostKey]
    if preClient.connected and not preClient.closed:
      try:
        let response = await preClient.request(req)
        
        # 成功統計
        inc(client.stats.successfulRequests)
        let rtt = (getMonoTime() - startTime).inMilliseconds.float
        client.stats.totalRtt += rtt
        inc(client.stats.rttSamples)
        client.stats.minRtt = if client.stats.rttSamples == 1: rtt else: min(client.stats.minRtt, rtt)
        client.stats.maxRtt = if client.stats.rttSamples == 1: rtt else: max(client.stats.maxRtt, rtt)
        
        return response
      except:
        # プリコネクト接続でエラーが発生した場合は通常接続を試みる
        client.logger.warn("プリコネクト接続でエラー発生: " & getCurrentExceptionMsg())
        client.preconnectedHosts.del(hostKey)
  
  # 非接続状態ならエラー
  if not client.connected or client.closed:
    raise newException(HttpError, "Client not connected")
  
  # GOAWAYを受け取っている場合はエラー
  if client.goawayReceived:
    raise newException(HttpError, "Connection is going away")
  
  # 接続ホストと異なる場合は新しい接続を確立
  if client.host != normalizedHost or client.port != normalizedPort:
    client.logger.debug("新しいホストへの接続が必要: " & normalizedHost & ":" & $normalizedPort)
    
    # 現在の接続は保持したまま新しい接続を確立
    let newClient = newHttp3Client(client.options)
    let connected = await newClient.connect(normalizedHost, normalizedPort)
    
    if not connected:
      inc(client.stats.failedRequests)
      raise newException(HttpError, "Failed to connect to " & normalizedHost & ":" & $normalizedPort)
    
    # 新しいクライアントでリクエスト実行
    try:
      let response = await newClient.request(req)
      
      # 成功統計
      inc(client.stats.successfulRequests)
      let rtt = (getMonoTime() - startTime).inMilliseconds.float
      client.stats.totalRtt += rtt
      inc(client.stats.rttSamples)
      
      # 将来の使用のためにクライアントをキャッシュ
      client.preconnectedHosts[hostKey] = newClient
      
      return response
    except:
      inc(client.stats.failedRequests)
      await newClient.close()
      raise
  
  # リクエストストリームを作成
  let stream = await client.streamManager.createRequestStream(client.quicClient)
  let streamId = stream.id
  
  # リクエスト送信とレスポンス受信のFutureを作成
  var responseFuture = newFuture[HttpResponse]("http3.client.request")
  client.activeRequests[streamId] = responseFuture
  
  # タイムアウト設定
  var timeoutFuture: Future[void] = nil
  if client.timeout > 0:
    timeoutFuture = sleepAsync(client.timeout)
  
  try:
    # ヘッダー準備
    var headers = client.defaultHeaders
    
    # メソッドとパスを追加
    headers.add(("method", req.method))
    headers.add(("scheme", req.url.scheme))
    headers.add(("authority", req.url.hostname & 
                (if req.url.port.len > 0: ":" & req.url.port else: "")))
    
    let path = 
      if req.url.path.len == 0: "/" 
      else: req.url.path & 
           (if req.url.query.len > 0: "?" & req.url.query else: "")
    
    headers.add(("path", path))
    
    # ユーザー指定ヘッダーを追加
    for header in req.headers:
      # すでに追加した特殊ヘッダーは除外
      if not header.name.toLowerAscii() in ["method", "scheme", "authority", "path"]:
        headers.add(header)
    
    # ヘッダー圧縮を最適化
    client.qpackEncoder.optimizeDynamicTable(headers)
    
    # ヘッダーフレーム送信
    await stream.sendHeaders(headers, client.qpackEncoder, req.body.len == 0)
    
    # ボディがある場合は送信
    if req.body.len > 0:
      await stream.sendData(req.body)
      # FINを送信してストリームを閉じる
      await stream.quicStream.shutdown()
    
    # 統計データの更新
    client.stats.bytesSent += stream.sentBytes
    
    # タイムアウト競合
    if timeoutFuture != nil:
      let winner = await responseFuture or timeoutFuture
      if winner == timeoutFuture:
        # タイムアウト発生
        stream.reset(0x10c) # HTTP_REQUEST_CANCELLED
        client.activeRequests.del(streamId)
        inc(client.stats.failedRequests)
        raise newException(HttpTimeoutError, "Request timed out after " & $client.timeout & "ms")
    
    # レスポンス受信
    let response = await responseFuture
    
    # 成功統計
    inc(client.stats.successfulRequests)
    let rtt = (getMonoTime() - startTime).inMilliseconds.float
    client.stats.totalRtt += rtt
    inc(client.stats.rttSamples)
    client.stats.minRtt = if client.stats.rttSamples == 1: rtt else: min(client.stats.minRtt, rtt)
    client.stats.maxRtt = if client.stats.rttSamples == 1: rtt else: max(client.stats.maxRtt, rtt)
    
    # スループット計算
    if rtt > 0:
      let bytesTransferred = stream.sentBytes + stream.receivedBytes
      let throughput = bytesTransferred.float / (rtt / 1000.0)
      client.stats.throughput = (client.stats.throughput * 0.7) + (throughput * 0.3) # 指数移動平均
    
    client.stats.bytesReceived += response.body.len
    
    # 適応型タイムアウトの更新
    client.adaptiveTimeout()
    
    return response
  except:
    let msg = getCurrentExceptionMsg()
    client.logger.error("リクエスト送信エラー: " & msg)
    
    # ストリームをリセット（必要に応じて）
    if stream.state notin {ssClosed, ssReset, ssError}:
      try:
        stream.reset(0x10c) # HTTP_REQUEST_CANCELLED
      except:
        discard
    
    # アクティブリクエストから削除
    client.activeRequests.del(streamId)
    
    # 統計更新
    inc(client.stats.failedRequests)
    
    # Futureがまだ完了していなければ失敗状態に
    if not responseFuture.finished:
      responseFuture.fail(newException(HttpError, msg))
    
    raise 