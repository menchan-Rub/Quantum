import unittest
import asyncdispatch
import net
import options
import strutils
import os
import ../resolver
import ../records

suite "DNSリゾルバーテスト":
  # テスト用のリゾルバーを設定
  setup:
    let config = newDefaultDnsResolverConfig()
    config.preferredBackends = @[SystemResolver]  # システムリゾルバーのみを使用
    # キャッシュを有効にし、サイズを小さくする
    config.enableCache = true
    config.cacheMaxSize = 20
    
    let resolver = newDnsResolver(config)

  test "シンプルなホスト名解決":
    proc testSimpleResolution() {.async.} =
      # ローカルホストのIPアドレスは常に解決可能なはず
      let result = await resolver.resolveHostname("localhost")
      check:
        result.len > 0
        (result[0] == parseIpAddress("127.0.0.1") or 
         result[0] == parseIpAddress("::1"))
    
    waitFor testSimpleResolution()

  test "存在しないドメインは例外をスローすること":
    proc testNonExistentDomain() {.async.} =
      try:
        # この非常に長いランダムなドメインは存在しないはず
        discard await resolver.resolveHostname("nonexistent-domain-12345.local")
        check(false)  # ここに到達するべきではない
      except DnsResolutionError:
        check(true)  # 例外がスローされることを期待
      except:
        check(false)  # 他の例外は期待していない
    
    waitFor testNonExistentDomain()

  test "キャッシュが適切に動作すること":
    proc testCaching() {.async.} =
      # 最初のルックアップ（キャッシュミス）
      let firstLookup = await resolver.resolveHostname("example.com")
      check(firstLookup.len > 0)
      
      # 2回目のルックアップ（キャッシュヒット）
      let secondLookup = await resolver.resolveHostname("example.com")
      check(secondLookup.len > 0)
      
      # 両方のルックアップは同じ結果を返すべき
      check(firstLookup == secondLookup)
      
      # キャッシュ統計を確認
      let stats = resolver.getCacheStats()
      check:
        stats.size > 0  # キャッシュに少なくとも1つのエントリがある
    
    waitFor testCaching()

  test "複数のIPアドレスを持つドメインを解決できること":
    proc testMultipleAddresses() {.async.} =
      # Google DNSは通常複数のIPアドレスを持っている
      let result = await resolver.resolveHostname("dns.google.com")
      check:
        result.len > 0  # 少なくとも1つのIPアドレスがある
    
    waitFor testMultipleAddresses()

  test "キャッシュをクリアできること":
    proc testCacheClear() {.async.} =
      # まず何かを解決してキャッシュを埋める
      discard await resolver.resolveHostname("example.com")
      
      # キャッシュに何かあることを確認
      var statsBefore = resolver.getCacheStats()
      check(statsBefore.size > 0)
      
      # キャッシュをクリア
      resolver.clearCache()
      
      # キャッシュが空になったことを確認
      var statsAfter = resolver.getCacheStats()
      check(statsAfter.size == 0)
    
    waitFor testCacheClear()

  test "TXTレコードを解決できること":
    proc testTxtResolution() {.async.} =
      try:
        let records = await resolver.resolveTxt("google.com")
        # 少なくとも1つのTXTレコードがあるはず
        check(records.len > 0)
        # TXTレコードは通常文字列
        check(records[0].len > 0)
      except DnsResolutionError:
        # 一部のDNSサーバーではTXTクエリをブロックしている可能性があるため、
        # このテストは失敗しても許容される
        echo "注: TXTレコード解決テストはスキップされました（DNS制限の可能性あり）"
    
    waitFor testTxtResolution()

  test "逆引きルックアップが動作すること":
    proc testReverseLookup() {.async.} =
      try:
        # Googleのパブリックネームサーバーの一つ
        let hostname = await resolver.reverseLookup(parseIpAddress("8.8.8.8"))
        check:
          hostname.len > 0
          hostname.contains("google")  # Google DNSなので、ホスト名にgoogleが含まれるはず
      except DnsResolutionError:
        # 逆引き失敗は許容される
        echo "注: 逆引きルックアップテストはスキップされました（DNS制限の可能性あり）"
    
    waitFor testReverseLookup()

  test "MXレコードを解決できること":
    proc testMxResolution() {.async.} =
      try:
        let records = await resolver.resolveMx("gmail.com")
        check:
          records.len > 0
          records[0].hostname.len > 0
          records[0].preference >= 0
      except DnsResolutionError:
        # MXクエリが制限されている場合もある
        echo "注: MXレコード解決テストはスキップされました（DNS制限の可能性あり）"
    
    waitFor testMxResolution()

  test "並列解決が正常に動作すること":
    proc testParallelResolution() {.async.} =
      let domains = @["example.com", "google.com", "github.com", "nim-lang.org"]
      let futures = domains.mapIt(resolver.resolveHostname(it))
      
      let results = await all(futures)
      
      # すべてのドメインが解決されたことを確認
      for i, ips in results:
        check:
          ips.len > 0  # 各ドメインに少なくとも1つのIPアドレスがある
    
    waitFor testParallelResolution()

when isMainModule:
  # テストの実行
  echo "DNSリゾルバーテストを実行中..."
  unittest.run()
  echo "テスト完了" 