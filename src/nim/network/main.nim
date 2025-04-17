import std/[asyncdispatch, httpclient, uri, strutils, tables]
import cache/memory
import dns/resolver
import http/client

type
  NetworkManager* = ref object
    client: AsyncHttpClient
    dns_resolver: DnsResolver
    memory_cache: MemoryCache
    active_requests: Table[string, Future[AsyncResponse]]

proc newNetworkManager*(): NetworkManager =
  ## ネットワークマネージャーを初期化
  result = NetworkManager(
    client: newAsyncHttpClient(),
    dns_resolver: newDnsResolver(),
    memory_cache: newMemoryCache(),
    active_requests: initTable[string, Future[AsyncResponse]]()
  )

proc fetchUrl*(self: NetworkManager, url: string): Future[string] {.async.} =
  ## URLからコンテンツを取得する
  echo "URLをフェッチ中: ", url
  
  # キャッシュをチェック
  if self.memory_cache.has(url):
    echo "キャッシュからコンテンツを取得: ", url
    return self.memory_cache.get(url)
  
  # DNSを解決
  let hostname = parseUri(url).hostname
  discard await self.dns_resolver.resolve(hostname)
  
  # HTTPリクエストを作成
  try:
    let response = await self.client.get(url)
    let content = await response.body
    
    # キャッシュに保存
    self.memory_cache.set(url, content)
    
    return content
  except Exception as e:
    echo "エラー: ", e.msg
    return ""

proc fetchWithHeaders*(self: NetworkManager, url: string, headers: HttpHeaders): Future[string] {.async.} =
  ## ヘッダー付きでURLからコンテンツを取得する
  let client = newAsyncHttpClient()
  for key, val in headers.table.pairs:
    client.headers[key] = val.join(", ")
  
  try:
    let response = await client.get(url)
    return await response.body
  except Exception as e:
    echo "エラー: ", e.msg
    return ""

proc prefetch*(self: NetworkManager, urls: seq[string]) {.async.} =
  ## 複数のURLを先読みしてキャッシュに保存
  var futures: seq[Future[void]]
  
  for url in urls:
    futures.add(
      (proc () {.async.} =
        discard await self.fetchUrl(url)
      )()
    )
  
  await all(futures)

when isMainModule:
  proc main() {.async.} =
    let nm = newNetworkManager()
    let content = await nm.fetchUrl("https://example.com")
    echo "取得したコンテンツの長さ: ", content.len
  
  waitFor main() 