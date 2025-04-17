import std/[strutils, tables, sets, options]

type
  HttpMethod* = distinct string
  HttpMethodSet* = HashSet[HttpMethod]

proc `==`*(a, b: HttpMethod): bool {.inline.} = string(a) == string(b)
proc `$`*(m: HttpMethod): string {.inline.} = string(m)
proc hash*(m: HttpMethod): Hash {.inline.} = hash(string(m))

# 標準HTTPメソッド定数
const
  GET* = HttpMethod("GET")
  HEAD* = HttpMethod("HEAD")
  POST* = HttpMethod("POST")
  PUT* = HttpMethod("PUT")
  DELETE* = HttpMethod("DELETE")
  CONNECT* = HttpMethod("CONNECT")
  OPTIONS* = HttpMethod("OPTIONS")
  TRACE* = HttpMethod("TRACE")
  PATCH* = HttpMethod("PATCH")

# 特殊・拡張HTTPメソッド定数
const
  PROPFIND* = HttpMethod("PROPFIND")       # WebDAV
  PROPPATCH* = HttpMethod("PROPPATCH")     # WebDAV
  MKCOL* = HttpMethod("MKCOL")             # WebDAV
  COPY* = HttpMethod("COPY")               # WebDAV
  MOVE* = HttpMethod("MOVE")               # WebDAV
  LOCK* = HttpMethod("LOCK")               # WebDAV
  UNLOCK* = HttpMethod("UNLOCK")           # WebDAV
  REPORT* = HttpMethod("REPORT")           # CalDAV
  SEARCH* = HttpMethod("SEARCH")           # ElasticSearch
  MERGE* = HttpMethod("MERGE")             # Git/SVN
  PURGE* = HttpMethod("PURGE")             # CDN (Fastly/Cloudflare)
  LINK* = HttpMethod("LINK")               # Linked Data Platform
  UNLINK* = HttpMethod("UNLINK")           # Linked Data Platform
  CHECKOUT* = HttpMethod("CHECKOUT")       # WebDAV/SVN
  MKACTIVITY* = HttpMethod("MKACTIVITY")   # SVN
  NOTIFY* = HttpMethod("NOTIFY")           # WebSub
  SUBSCRIBE* = HttpMethod("SUBSCRIBE")     # WebSub
  UNSUBSCRIBE* = HttpMethod("UNSUBSCRIBE") # WebSub
  SOURCE* = HttpMethod("SOURCE")           # RTSP
  BREW* = HttpMethod("BREW")               # HTCPCP (joke RFC)

# メソッドセット
const
  SafeMethods* = toHashSet([GET, HEAD, OPTIONS, TRACE])
  IdempotentMethods* = toHashSet([GET, HEAD, PUT, DELETE, OPTIONS, TRACE])
  CachableMethods* = toHashSet([GET, HEAD])
  BodyAllowedMethods* = toHashSet([POST, PUT, PATCH, PROPFIND, PROPPATCH, REPORT, SEARCH, MERGE, 
                                 NOTIFY, SUBSCRIBE, UNSUBSCRIBE, SOURCE])
  StandardMethods* = toHashSet([GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, TRACE, PATCH])

# HTTPメソッドプロパティのデータベース
type
  MethodProperty* = enum
    Safe              # 副作用がない
    Idempotent        # 複数回実行しても同じ結果
    Cachable          # キャッシュ可能
    BodyAllowed       # リクエストボディを許可
    Standard          # HTTP標準メソッド
    WebDAV            # WebDAV関連メソッド
    ResponseRequired  # レスポンス本文をとする

  MethodInfo* = object
    method*: HttpMethod
    properties*: set[MethodProperty]
    description*: string
    rfc*: string

# メソッド情報のテーブル
let HttpMethodInfoTable* = {
  GET: MethodInfo(
    method: GET,
    properties: {Safe, Idempotent, Cachable, Standard, ResponseRequired},
    description: "リソースの表現を取得する",
    rfc: "RFC7231"
  ),
  HEAD: MethodInfo(
    method: HEAD,
    properties: {Safe, Idempotent, Cachable, Standard},
    description: "リソースのメタ情報のみを取得する",
    rfc: "RFC7231"
  ),
  POST: MethodInfo(
    method: POST,
    properties: {BodyAllowed, Standard, ResponseRequired},
    description: "指定されたリソースに対してエンティティを投稿する",
    rfc: "RFC7231"
  ),
  PUT: MethodInfo(
    method: PUT,
    properties: {Idempotent, BodyAllowed, Standard},
    description: "ターゲットリソースを置き換える",
    rfc: "RFC7231"
  ),
  DELETE: MethodInfo(
    method: DELETE,
    properties: {Idempotent, Standard},
    description: "指定されたリソースを削除する",
    rfc: "RFC7231"
  ),
  CONNECT: MethodInfo(
    method: CONNECT,
    properties: {Standard},
    description: "プロキシを介してサーバーへのトンネルを確立する",
    rfc: "RFC7231"
  ),
  OPTIONS: MethodInfo(
    method: OPTIONS,
    properties: {Safe, Idempotent, Standard, ResponseRequired},
    description: "ターゲットリソースの通信オプションを記述する",
    rfc: "RFC7231"
  ),
  TRACE: MethodInfo(
    method: TRACE,
    properties: {Safe, Idempotent, Standard},
    description: "メッセージのループバックテストを実行する",
    rfc: "RFC7231"
  ),
  PATCH: MethodInfo(
    method: PATCH,
    properties: {BodyAllowed, Standard, ResponseRequired},
    description: "リソースを部分的に変更する",
    rfc: "RFC5789"
  ),
  PROPFIND: MethodInfo(
    method: PROPFIND,
    properties: {Idempotent, BodyAllowed, WebDAV, ResponseRequired},
    description: "WebDAVプロパティを取得する",
    rfc: "RFC4918"
  ),
  PROPPATCH: MethodInfo(
    method: PROPPATCH,
    properties: {BodyAllowed, WebDAV},
    description: "WebDAVプロパティを更新または削除する",
    rfc: "RFC4918"
  ),
  MKCOL: MethodInfo(
    method: MKCOL,
    properties: {WebDAV},
    description: "WebDAVコレクションを作成する",
    rfc: "RFC4918"
  ),
  COPY: MethodInfo(
    method: COPY,
    properties: {Idempotent, WebDAV},
    description: "WebDAVリソースをコピーする",
    rfc: "RFC4918"
  ),
  MOVE: MethodInfo(
    method: MOVE,
    properties: {Idempotent, WebDAV},
    description: "WebDAVリソースを移動する",
    rfc: "RFC4918"
  ),
  LOCK: MethodInfo(
    method: LOCK,
    properties: {WebDAV, ResponseRequired},
    description: "WebDAVリソースをロックする",
    rfc: "RFC4918"
  ),
  UNLOCK: MethodInfo(
    method: UNLOCK,
    properties: {WebDAV},
    description: "WebDAVリソースのロックを解除する",
    rfc: "RFC4918"
  )
}.toTable

proc parseHttpMethod*(s: string): HttpMethod =
  ## 文字列からHTTPメソッドを解析する
  result = HttpMethod(s.toUpperAscii())

proc tryParseHttpMethod*(s: string): Option[HttpMethod] =
  ## 文字列からHTTPメソッドを解析し、Optionとして返す
  ## 標準メソッドでない場合もParseするが、空文字列や不正な値の場合はnoneを返す
  if s.len == 0 or s.contains({' ', '\t', '\n', '\r'}):
    return none(HttpMethod)
  return some(HttpMethod(s.toUpperAscii()))

proc isStandardMethod*(m: HttpMethod): bool =
  ## 標準HTTPメソッドかどうかをチェックする
  return m in StandardMethods

proc isValidMethod*(m: HttpMethod): bool =
  ## 有効なHTTPメソッドかどうかを確認する
  let method = $m
  # メソッド名に使用できない文字が含まれている場合は無効
  for c in method:
    if c < ' ' or c > '~':  # ASCII印字可能文字の範囲外
      return false
  return true

proc isSafeMethod*(m: HttpMethod): bool =
  ## 安全なHTTPメソッドかどうかを確認する
  ## 安全なメソッドは副作用を持たないメソッド
  return m in SafeMethods

proc isIdempotentMethod*(m: HttpMethod): bool =
  ## 冪等なHTTPメソッドかどうかを確認する
  ## 冪等なメソッドは同じリクエストを複数回送信しても結果が同じになるメソッド
  return m in IdempotentMethods

proc isCachableMethod*(m: HttpMethod): bool =
  ## キャッシュ可能なHTTPメソッドかどうかを確認する
  return m in CachableMethods

proc allowsRequestBody*(m: HttpMethod): bool =
  ## リクエストボディを許可するHTTPメソッドかどうかを確認する
  return m in BodyAllowedMethods

proc requiresResponseBody*(m: HttpMethod): bool =
  ## レスポンスボディをとするHTTPメソッドかどうかを確認する
  ## HEADはボディを返さない、GETは通常ボディを返すがある
  if m == HEAD or m == CONNECT:
    return false
  if m in HttpMethodInfoTable and ResponseRequired in HttpMethodInfoTable[m].properties:
    return true
  return false

proc getMethodInfo*(m: HttpMethod): Option[MethodInfo] =
  ## HTTPメソッドの詳細情報を取得する
  if m in HttpMethodInfoTable:
    return some(HttpMethodInfoTable[m])
  return none(MethodInfo)

proc getMethodDescription*(m: HttpMethod): string =
  ## HTTPメソッドの説明を取得する
  if m in HttpMethodInfoTable:
    return HttpMethodInfoTable[m].description
  return "未知のHTTPメソッド"

proc getMethodRfc*(m: HttpMethod): string =
  ## HTTPメソッドが定義されているRFCを取得する
  if m in HttpMethodInfoTable:
    return HttpMethodInfoTable[m].rfc
  return ""

proc isWebDavMethod*(m: HttpMethod): bool =
  ## WebDAV関連のHTTPメソッドかどうかを確認する
  if m in HttpMethodInfoTable:
    return WebDAV in HttpMethodInfoTable[m].properties
  return false

proc compareHttpMethods*(a, b: HttpMethod): int =
  ## HTTPメソッドを比較する（文字列として比較）
  ## 戻り値: a < b の場合は負の値、a == b の場合は0、a > b の場合は正の値
  cmp(string(a), string(b))

proc hasProperties*(m: HttpMethod, props: set[MethodProperty]): bool =
  ## HTTPメソッドが指定されたプロパティを持っているかを確認する
  if m in HttpMethodInfoTable:
    let methodProps = HttpMethodInfoTable[m].properties
    for p in props:
      if p notin methodProps:
        return false
    return true
  return false 