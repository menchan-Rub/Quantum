import unittest
import times
import net
import asyncdispatch
import sequtils
import strutils
import ../cache/cache
import ../records

suite "DNSキャッシュテスト":
  setup:
    let cache = newDnsCache(maxSize = 100)

  test "新しいレコードを追加して取得できること":
    let record = DnsRecord(
      domain: "example.com", 
      typ: A, 
      ttl: 3600, 
      class: IN,
      data: DnsRecordData(a: parseIpAddress("192.168.1.1"))
    )
    
    cache.put(record)
    let retrieved = cache.get("example.com", A)
    
    check:
      retrieved.isSome
      retrieved.get().domain == "example.com"
      retrieved.get().typ == A
      retrieved.get().data.a == parseIpAddress("192.168.1.1")

  test "存在しないレコードを取得した場合はnoneを返すこと":
    let retrieved = cache.get("nonexistent.com", A)
    check:
      retrieved.isNone

  test "有効期限切れのレコードは取得されないこと":
    # TTLが1秒の短命レコードを追加
    let record = DnsRecord(
      domain: "shortlived.com", 
      typ: A, 
      ttl: 1, 
      class: IN,
      data: DnsRecordData(a: parseIpAddress("192.168.1.2"))
    )
    
    cache.put(record)
    
    # 2秒待つ
    sleep(2000)
    
    let retrieved = cache.get("shortlived.com", A)
    check:
      retrieved.isNone

  test "同じドメインで異なるレコードタイプを追加・取得できること":
    let recordA = DnsRecord(
      domain: "multi.com", 
      typ: A, 
      ttl: 3600, 
      class: IN,
      data: DnsRecordData(a: parseIpAddress("192.168.1.3"))
    )
    
    let recordAAAA = DnsRecord(
      domain: "multi.com", 
      typ: AAAA, 
      ttl: 3600, 
      class: IN,
      data: DnsRecordData(aaaa: parseIpAddress("2001:db8::1"))
    )
    
    cache.put(recordA)
    cache.put(recordAAAA)
    
    let retrievedA = cache.get("multi.com", A)
    let retrievedAAAA = cache.get("multi.com", AAAA)
    
    check:
      retrievedA.isSome
      retrievedA.get().typ == A
      retrievedA.get().data.a == parseIpAddress("192.168.1.3")
      
      retrievedAAAA.isSome
      retrievedAAAA.get().typ == AAAA
      retrievedAAAA.get().data.aaaa == parseIpAddress("2001:db8::1")

  test "キャッシュがサイズ制限を守ること":
    # 小さいキャッシュを作成
    let smallCache = newDnsCache(maxSize = 2)
    
    # 3つのレコードを追加
    for i in 1..3:
      let record = DnsRecord(
        domain: "domain" & $i & ".com", 
        typ: A, 
        ttl: 3600, 
        class: IN,
        data: DnsRecordData(a: parseIpAddress("192.168.1." & $i))
      )
      smallCache.put(record)
    
    # 最初のレコードは削除されているはず
    let first = smallCache.get("domain1.com", A)
    let second = smallCache.get("domain2.com", A)
    let third = smallCache.get("domain3.com", A)
    
    check:
      first.isNone  # 最も古いエントリーは削除されている
      second.isSome
      third.isSome

  test "キャッシュのクリア機能が正常に動作すること":
    # いくつかのレコードを追加
    for i in 1..5:
      let record = DnsRecord(
        domain: "domain" & $i & ".com", 
        typ: A, 
        ttl: 3600, 
        class: IN,
        data: DnsRecordData(a: parseIpAddress("192.168.1." & $i))
      )
      cache.put(record)
    
    # キャッシュをクリア
    cache.clear()
    
    # すべてのレコードが削除されていることを確認
    for i in 1..5:
      let retrieved = cache.get("domain" & $i & ".com", A)
      check:
        retrieved.isNone

  test "contains関数が正常に動作すること":
    let record = DnsRecord(
      domain: "exists.com", 
      typ: A, 
      ttl: 3600, 
      class: IN,
      data: DnsRecordData(a: parseIpAddress("192.168.1.10"))
    )
    
    cache.put(record)
    
    check:
      cache.contains("exists.com", A)
      not cache.contains("notexists.com", A)
      not cache.contains("exists.com", AAAA)  # 同じドメインでも異なるタイプ

  test "期限切れのレコードが正常にプルーニングされること":
    # TTLが1秒の短命レコードを複数追加
    for i in 1..5:
      let record = DnsRecord(
        domain: "prune" & $i & ".com", 
        typ: A, 
        ttl: 1, 
        class: IN,
        data: DnsRecordData(a: parseIpAddress("192.168.1." & $i))
      )
      cache.put(record)
    
    # 2秒待つ
    sleep(2000)
    
    # 手動でプルーニングを実行
    cache.pruneExpiredRecords()
    
    # すべてのレコードが削除されていることを確認
    for i in 1..5:
      let retrieved = cache.get("prune" & $i & ".com", A)
      check:
        retrieved.isNone

when isMainModule:
  # テストの実行
  echo "DNSキャッシュテストを実行中..."
  unittest.run()
  echo "テスト完了" 