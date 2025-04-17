# Nim DNS リゾルバライブラリ

このライブラリは、Nimプログラミング言語で書かれた非同期DNSリゾルバを提供します。ブラウザなどのアプリケーションでDNS解決を簡単に実装することができます。

## 特徴

- 非同期DNSルックアップ（`asyncdispatch`を使用）
- UDPとTCPプロトコルをサポート
- キャッシュ機能
- さまざまなDNSレコードタイプのサポート（A, AAAA, CNAME, MX, TXT, NS, SOA, PTR, SRV等）
- シンプルで使いやすいAPI
- カスタムネームサーバのサポート
- タイムアウトとリトライの設定
- バイナリDNSメッセージのエンコード/デコード

## 使用例

### 基本的な使用方法

```nim
import asyncdispatch
import network/dns/dns

proc main() {.async.} =
  # ホスト名をIPアドレスに解決する
  let ips = await lookupHostname("example.com")
  echo "IPアドレス: ", ips

  # 単一のIPv4アドレスを取得
  let ip = await lookupAddress("example.com")
  echo "IPv4アドレス: ", ip

  # 単一のIPv6アドレスを取得
  let ipv6 = await lookupAddress("example.com", ipv6 = true)
  echo "IPv6アドレス: ", ipv6

waitFor main()
```

### カスタムリゾルバの使用

```nim
import asyncdispatch
import network/dns/dns

proc main() {.async.} =
  # カスタムネームサーバを使用するUDPリゾルバを作成
  var resolver = newDnsResolver(
    resolverType = drtUdp,
    nameservers = @["8.8.8.8", "8.8.4.4"],
    timeout = 3000,  # 3秒
    retries = 2
  )

  # ホスト名を解決
  let ips = await resolver.resolve("example.com")
  echo "IPアドレス: ", ips

  # 特定のレコードタイプで解決
  let mxRecords = await resolver.resolveWithType("example.com", MX)
  echo "MXレコード: "
  for record in mxRecords:
    echo "  ", record.data

  # 直接DNSクエリを送信して生のレスポンスを取得
  let response = await resolver.queryDirect("example.com", A)
  echo "問い合わせID: ", response.header.id
  echo "回答セクションのレコード数: ", response.header.ancount

  # リソースを解放
  resolver.close()

waitFor main()
```

### 複数のホスト名の一括解決

```nim
import asyncdispatch
import network/dns/dns

proc main() {.async.} =
  let domains = @["example.com", "google.com", "github.com"]
  let results = await resolveMultiple(domains)
  
  for domain, ips in results:
    echo domain, ": ", ips

waitFor main()
```

## モジュール構成

- `dns.nim` - メインモジュール、簡単に使えるAPIを提供
- `records.nim` - DNSレコードタイプの定義
- `message.nim` - DNSメッセージフォーマットの実装
- `packet.nim` - DNSパケットの送受信
- `cache/cache.nim` - DNSキャッシュの実装
- `resolver/udp.nim` - UDP DNSリゾルバ
- `resolver/tcp.nim` - TCP DNSリゾルバ

## 将来の拡張予定

- DNS over HTTPS (DoH) サポート
- DNS over TLS (DoT) サポート
- DNSSECバリデーション
- IDNサポート
- マルチキャストDNS (mDNS) サポート

## ライセンス

このライブラリはオープンソースであり、[MITライセンス](LICENSE)の下で提供されています。 