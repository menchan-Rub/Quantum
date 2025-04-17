import std/[strutils, tables, sets, options, sequtils, strformat]
import ./constants

type
  HttpMethodMatcher* = object
    ## HTTPメソッドのマッチングを行うオブジェクト
    allowedMethods*: HttpMethodSet
    preferredOrder*: seq[HttpMethod]
    caseSensitive*: bool

  MethodMatchResult* = enum
    Match,    # 完全一致
    NoMatch,  # 一致なし
    AnyMatch  # ワイルドカード一致

# HTTPメソッド間の互換性マトリックス
# 第一キーはクライアント側のメソッド、第二キーはサーバー側のメソッド
let MethodCompatibilityMatrix* = {
  GET: {
    GET: true,
    HEAD: false,  # GETはHEADを代替できない
    POST: false,
    PUT: false,
    DELETE: false,
    CONNECT: false,
    OPTIONS: false,
    TRACE: false,
    PATCH: false,
  }.toTable,
  HEAD: {
    GET: true,   # HEADはGETで代替可能
    HEAD: true,
    POST: false,
    PUT: false,
    DELETE: false,
    CONNECT: false,
    OPTIONS: false,
    TRACE: false,
    PATCH: false,
  }.toTable,
  # 他のメソッドはデフォルトで互換性なし（自身とのみ互換性あり）
}.toTable

proc newHttpMethodMatcher*(): HttpMethodMatcher =
  ## 新しいHTTPメソッドマッチャーを作成する
  ## デフォルトではすべての標準メソッドを許可し、RFC7231の推奨順に従う
  result.allowedMethods = StandardMethods
  result.preferredOrder = @[GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, TRACE, PATCH]
  result.caseSensitive = false

proc newHttpMethodMatcher*(methods: openArray[HttpMethod]): HttpMethodMatcher =
  ## 指定されたメソッドのみを許可するHTTPメソッドマッチャーを作成する
  result = newHttpMethodMatcher()
  result.allowedMethods = toHashSet(methods)
  result.preferredOrder = @methods

proc addAllowedMethod*(matcher: var HttpMethodMatcher, method: HttpMethod) =
  ## 許可メソッドを追加する
  matcher.allowedMethods.incl(method)
  if method notin matcher.preferredOrder:
    matcher.preferredOrder.add(method)

proc removeAllowedMethod*(matcher: var HttpMethodMatcher, method: HttpMethod) =
  ## 許可メソッドを削除する
  matcher.allowedMethods.excl(method)
  matcher.preferredOrder.keepItIf(it != method)

proc setAllowedMethods*(matcher: var HttpMethodMatcher, methods: openArray[HttpMethod]) =
  ## 許可メソッドを設定する
  matcher.allowedMethods = toHashSet(methods)
  # 優先順序は既存の順序を保持しつつ、許可されないメソッドを削除
  matcher.preferredOrder = matcher.preferredOrder.filterIt(it in matcher.allowedMethods)
  # 新しく追加されたメソッドを優先順序の末尾に追加
  for m in methods:
    if m notin matcher.preferredOrder:
      matcher.preferredOrder.add(m)

proc setPreferredOrder*(matcher: var HttpMethodMatcher, methods: openArray[HttpMethod]) =
  ## 優先順序を設定する
  ## 許可されていないメソッドは優先順序に含まれない
  var newOrder: seq[HttpMethod] = @[]
  for m in methods:
    if m in matcher.allowedMethods and m notin newOrder:
      newOrder.add(m)
  
  # 優先順序に含まれていない許可メソッドを追加
  for m in matcher.allowedMethods:
    if m notin newOrder:
      newOrder.add(m)
  
  matcher.preferredOrder = newOrder

proc isMethodAllowed*(matcher: HttpMethodMatcher, method: HttpMethod): bool =
  ## メソッドが許可されているかどうかを確認する
  if not matcher.caseSensitive:
    let upperMethod = parseHttpMethod($method)
    return upperMethod in matcher.allowedMethods
  
  return method in matcher.allowedMethods

proc matchMethod*(matcher: HttpMethodMatcher, method: HttpMethod): MethodMatchResult =
  ## 指定されたメソッドが許可されているかどうかをチェックする
  if method == HttpMethod("*"):
    return AnyMatch
  
  if matcher.isMethodAllowed(method):
    return Match
  
  return NoMatch

proc getAllowedMethodsString*(matcher: HttpMethodMatcher): string =
  ## 許可メソッドをカンマ区切りの文字列として取得する
  ## 優先順序に従って並べられる
  result = ""
  for i, m in matcher.preferredOrder:
    if i > 0: result.add(", ")
    result.add($m)

proc isMethodCompatible*(clientMethod, serverMethod: HttpMethod): bool =
  ## クライアントメソッドがサーバーメソッドと互換性があるかどうかを確認する
  ## 例: HEADリクエストはGETハンドラーで処理できる
  if clientMethod == serverMethod:
    return true
  
  if clientMethod in MethodCompatibilityMatrix and 
     serverMethod in MethodCompatibilityMatrix[clientMethod]:
    return MethodCompatibilityMatrix[clientMethod][serverMethod]
  
  return false

proc findCompatibleMethod*(clientMethod: HttpMethod, serverMethods: HttpMethodSet): Option[HttpMethod] =
  ## クライアントメソッドと互換性のあるサーバーメソッドを探す
  if clientMethod in serverMethods:
    return some(clientMethod)
  
  if clientMethod in MethodCompatibilityMatrix:
    for serverMethod in serverMethods:
      if serverMethod in MethodCompatibilityMatrix[clientMethod] and 
         MethodCompatibilityMatrix[clientMethod][serverMethod]:
        return some(serverMethod)
  
  return none(HttpMethod)

proc selectPreferredMethod*(availableMethods: HttpMethodSet, preferredOrder: openArray[HttpMethod]): Option[HttpMethod] =
  ## 利用可能なメソッドから優先順位に基づいて最適なメソッドを選択する
  for m in preferredOrder:
    if m in availableMethods:
      return some(m)
  
  return none(HttpMethod)

proc generateAllowHeader*(methods: HttpMethodSet): string =
  ## Allowヘッダーの値を生成する
  var methodStrings: seq[string] = @[]
  for m in methods:
    methodStrings.add($m)
  
  # アルファベット順にソート
  methodStrings.sort()
  return methodStrings.join(", ")

proc parseAllowHeader*(headerValue: string): HttpMethodSet =
  ## Allowヘッダーの値からHTTPメソッドセットを解析する
  result = initHashSet[HttpMethod]()
  for methodStr in headerValue.split({','}):
    let trimmed = methodStr.strip()
    if trimmed.len > 0:
      result.incl(parseHttpMethod(trimmed))

proc methodToString*(m: HttpMethod): string =
  ## HTTPメソッドを文字列に変換する
  result = $m

proc isWildcardMethod*(m: HttpMethod): bool =
  ## ワイルドカードメソッド ("*") かどうかを確認する
  return $m == "*"

proc getMethodsRequiringRequestBody*(): HttpMethodSet =
  ## リクエストボディを必須とするHTTPメソッドセットを取得する
  ## POSTとPATCHはリクエストボディを必須とする
  result = toHashSet([POST, PATCH])

proc getMethodsAllowingEmptyRequestBody*(): HttpMethodSet =
  ## 空のリクエストボディを許可するHTTPメソッドセットを取得する
  ## リクエストボディを許可するが、必須ではないメソッド
  result = BodyAllowedMethods - getMethodsRequiringRequestBody()

proc validateMethodAgainstResource*(m: HttpMethod, isResourceExists: bool): bool =
  ## リソースの存在状態に対してHTTPメソッドが適切かどうかを確認する
  ## 例: PUTはリソースが存在しなくてもOK、DELETEはリソースが存在する必要がある
  case $m
  of $POST:
    # POSTはリソースコレクションが存在する場合に有効
    return true
  of $PUT:
    # PUTはリソースが存在しなくてもOK
    return true
  of $DELETE:
    # DELETEはリソースが存在する必要がある
    return isResourceExists
  of $GET, $HEAD:
    # GETとHEADはリソースが存在する必要がある
    return isResourceExists
  of $OPTIONS:
    # OPTIONSはリソースの存在に関わらず有効
    return true
  of $PATCH:
    # PATCHはリソースが存在する必要がある
    return isResourceExists
  else:
    # 他のメソッドはケースバイケース
    return true

proc getMethodFailureStatus*(m: HttpMethod, isResourceExists: bool): int =
  ## メソッドが失敗した場合の適切なHTTPステータスコードを返す
  if not validateMethodAgainstResource(m, isResourceExists):
    case $m
    of $GET, $HEAD, $DELETE, $PATCH:
      if not isResourceExists:
        return 404  # Not Found
    of $POST:
      if not isResourceExists:
        return 404  # Not Found (コレクションが存在しない)
  
  return 405  # Method Not Allowed

proc getMethodAliases*(m: HttpMethod): seq[HttpMethod] =
  ## メソッドの代替／エイリアスメソッドを取得する
  ## 例: HEADはGETの軽量版
  case $m
  of $GET:
    result = @[HEAD]
  else:
    result = @[]

proc getMethodGroup*(m: HttpMethod): string =
  ## メソッドの機能グループを取得する
  ## RESTfulなセマンティクスに基づいたグループ分け
  case $m
  of $GET, $HEAD:
    return "Read"
  of $POST:
    return "Create"
  of $PUT, $PATCH:
    return "Update"
  of $DELETE:
    return "Delete"
  of $OPTIONS, $TRACE:
    return "Metadata"
  of $CONNECT:
    return "Connection"
  else:
    if isWebDavMethod(m):
      return "WebDAV"
    return "Other"

proc formatMethod*(m: HttpMethod, format: string = "default"): string =
  ## HTTPメソッドを指定されたフォーマットで整形する
  case format.toLowerAscii()
  of "default", "standard":
    return $m
  of "lowercase":
    return ($m).toLowerAscii()
  of "verbose":
    let info = getMethodInfo(m)
    if info.isSome:
      return fmt"{$m} ({info.get.description})"
    return $m
  of "rfc":
    let rfc = getMethodRfc(m)
    if rfc.len > 0:
      return fmt"{$m} ({rfc})"
    return $m
  else:
    return $m 