import std/[strutils, options, tables]

type
  HttpMethodInfo* = object
    name*: string
    description*: string
    hasBody*: bool
    isSafe*: bool
    isIdempotent*: bool
    isCacheable*: bool
    standard*: bool
    supportedSince*: string
    statusCodes*: seq[int]

const
  # HTTP メソッド情報のレジストリ
  HttpMethodRegistry* = {
    "GET": HttpMethodInfo(
      name: "GET",
      description: "リソースの取得",
      hasBody: false,
      isSafe: true,
      isIdempotent: true,
      isCacheable: true,
      standard: true,
      supportedSince: "HTTP/0.9",
      statusCodes: @[200, 304, 404, 500]
    ),
    "HEAD": HttpMethodInfo(
      name: "HEAD",
      description: "GET と同じだがボディなしでヘッダーのみ取得",
      hasBody: false,
      isSafe: true,
      isIdempotent: true,
      isCacheable: true,
      standard: true,
      supportedSince: "HTTP/1.0",
      statusCodes: @[200, 304, 404, 500]
    ),
    "POST": HttpMethodInfo(
      name: "POST",
      description: "新しいリソースの作成・追加",
      hasBody: true,
      isSafe: false,
      isIdempotent: false,
      isCacheable: false,
      standard: true,
      supportedSince: "HTTP/1.0",
      statusCodes: @[200, 201, 204, 400, 404, 409, 500]
    ),
    "PUT": HttpMethodInfo(
      name: "PUT",
      description: "リソースの作成または更新",
      hasBody: true,
      isSafe: false,
      isIdempotent: true,
      isCacheable: false,
      standard: true,
      supportedSince: "HTTP/1.1",
      statusCodes: @[200, 201, 204, 400, 404, 409, 500]
    ),
    "DELETE": HttpMethodInfo(
      name: "DELETE",
      description: "リソースの削除",
      hasBody: false,
      isSafe: false,
      isIdempotent: true,
      isCacheable: false,
      standard: true,
      supportedSince: "HTTP/1.1",
      statusCodes: @[200, 202, 204, 400, 404, 500]
    ),
    "CONNECT": HttpMethodInfo(
      name: "CONNECT",
      description: "プロキシとしてのトンネルを確立",
      hasBody: false,
      isSafe: false,
      isIdempotent: false,
      isCacheable: false,
      standard: true,
      supportedSince: "HTTP/1.1",
      statusCodes: @[200, 400, 403, 405, 500]
    ),
    "OPTIONS": HttpMethodInfo(
      name: "OPTIONS",
      description: "リソースがサポートする通信オプション",
      hasBody: false,
      isSafe: true,
      isIdempotent: true,
      isCacheable: false,
      standard: true,
      supportedSince: "HTTP/1.1",
      statusCodes: @[200, 204, 400, 500]
    ),
    "TRACE": HttpMethodInfo(
      name: "TRACE",
      description: "サーバーへのパスに沿ったメッセージのループバックテスト",
      hasBody: false,
      isSafe: true,
      isIdempotent: true,
      isCacheable: false,
      standard: true,
      supportedSince: "HTTP/1.1",
      statusCodes: @[200, 400, 500]
    ),
    "PATCH": HttpMethodInfo(
      name: "PATCH",
      description: "リソースの部分更新",
      hasBody: true,
      isSafe: false,
      isIdempotent: false,
      isCacheable: false,
      standard: true,
      supportedSince: "RFC 5789",
      statusCodes: @[200, 204, 400, 404, 409, 422, 500]
    ),
    # 以下はWebDAVメソッド
    "PROPFIND": HttpMethodInfo(
      name: "PROPFIND",
      description: "リソースのプロパティを取得",
      hasBody: true,
      isSafe: true,
      isIdempotent: true,
      isCacheable: false,
      standard: true,
      supportedSince: "RFC 4918 (WebDAV)",
      statusCodes: @[207, 400, 404, 500]
    ),
    "PROPPATCH": HttpMethodInfo(
      name: "PROPPATCH",
      description: "リソースのプロパティを変更",
      hasBody: true,
      isSafe: false,
      isIdempotent: true,
      isCacheable: false,
      standard: true,
      supportedSince: "RFC 4918 (WebDAV)",
      statusCodes: @[207, 400, 404, 500]
    ),
    "MKCOL": HttpMethodInfo(
      name: "MKCOL",
      description: "コレクション（ディレクトリ）の作成",
      hasBody: true,
      isSafe: false,
      isIdempotent: true,
      isCacheable: false,
      standard: true,
      supportedSince: "RFC 4918 (WebDAV)",
      statusCodes: @[201, 400, 409, 415, 500]
    ),
    "COPY": HttpMethodInfo(
      name: "COPY",
      description: "リソースのコピー",
      hasBody: false,
      isSafe: false,
      isIdempotent: true,
      isCacheable: false,
      standard: true,
      supportedSince: "RFC 4918 (WebDAV)",
      statusCodes: @[201, 204, 400, 404, 409, 500]
    ),
    "MOVE": HttpMethodInfo(
      name: "MOVE",
      description: "リソースの移動",
      hasBody: false,
      isSafe: false,
      isIdempotent: true,
      isCacheable: false,
      standard: true,
      supportedSince: "RFC 4918 (WebDAV)",
      statusCodes: @[201, 204, 400, 404, 409, 500]
    ),
    "LOCK": HttpMethodInfo(
      name: "LOCK",
      description: "リソースのロック",
      hasBody: true,
      isSafe: false,
      isIdempotent: false,
      isCacheable: false,
      standard: true,
      supportedSince: "RFC 4918 (WebDAV)",
      statusCodes: @[200, 400, 404, 409, 423, 500]
    ),
    "UNLOCK": HttpMethodInfo(
      name: "UNLOCK",
      description: "リソースのロック解除",
      hasBody: false,
      isSafe: false,
      isIdempotent: true,
      isCacheable: false,
      standard: true,
      supportedSince: "RFC 4918 (WebDAV)",
      statusCodes: @[204, 400, 404, 500]
    ),
    # 以下は非標準だが一般的に使用されるメソッド
    "PURGE": HttpMethodInfo(
      name: "PURGE",
      description: "キャッシュからリソースを削除",
      hasBody: false,
      isSafe: false,
      isIdempotent: true,
      isCacheable: false,
      standard: false,
      supportedSince: "非標準（Varnishなど）",
      statusCodes: @[200, 404, 500]
    ),
    "LINK": HttpMethodInfo(
      name: "LINK",
      description: "リソース間のリンクを確立",
      hasBody: false,
      isSafe: false,
      isIdempotent: true,
      isCacheable: false,
      standard: false,
      supportedSince: "RFC 2068（廃止）",
      statusCodes: @[200, 404, 500]
    ),
    "UNLINK": HttpMethodInfo(
      name: "UNLINK",
      description: "リソース間のリンクを解除",
      hasBody: false,
      isSafe: false,
      isIdempotent: true,
      isCacheable: false,
      standard: false,
      supportedSince: "RFC 2068（廃止）",
      statusCodes: @[200, 404, 500]
    ),
    "VIEW": HttpMethodInfo(
      name: "VIEW",
      description: "リソースの特定ビューを取得",
      hasBody: false,
      isSafe: true,
      isIdempotent: true,
      isCacheable: true,
      standard: false,
      supportedSince: "非標準",
      statusCodes: @[200, 404, 500]
    )
  }.toTable

# 一般的なHTTPステータスコードとその説明
const
  HttpStatusCodes* = {
    # 1xx - 情報
    100: "Continue",
    101: "Switching Protocols",
    102: "Processing",
    103: "Early Hints",
    
    # 2xx - 成功
    200: "OK",
    201: "Created",
    202: "Accepted",
    203: "Non-Authoritative Information",
    204: "No Content",
    205: "Reset Content",
    206: "Partial Content",
    207: "Multi-Status",
    208: "Already Reported",
    226: "IM Used",
    
    # 3xx - リダイレクション
    300: "Multiple Choices",
    301: "Moved Permanently",
    302: "Found",
    303: "See Other",
    304: "Not Modified",
    305: "Use Proxy",
    306: "Switch Proxy",
    307: "Temporary Redirect",
    308: "Permanent Redirect",
    
    # 4xx - クライアントエラー
    400: "Bad Request",
    401: "Unauthorized",
    402: "Payment Required",
    403: "Forbidden",
    404: "Not Found",
    405: "Method Not Allowed",
    406: "Not Acceptable",
    407: "Proxy Authentication Required",
    408: "Request Timeout",
    409: "Conflict",
    410: "Gone",
    411: "Length Required",
    412: "Precondition Failed",
    413: "Payload Too Large",
    414: "URI Too Long",
    415: "Unsupported Media Type",
    416: "Range Not Satisfiable",
    417: "Expectation Failed",
    418: "I'm a teapot",
    421: "Misdirected Request",
    422: "Unprocessable Entity",
    423: "Locked",
    424: "Failed Dependency",
    425: "Too Early",
    426: "Upgrade Required",
    428: "Precondition Required",
    429: "Too Many Requests",
    431: "Request Header Fields Too Large",
    451: "Unavailable For Legal Reasons",
    
    # 5xx - サーバーエラー
    500: "Internal Server Error",
    501: "Not Implemented",
    502: "Bad Gateway",
    503: "Service Unavailable",
    504: "Gateway Timeout",
    505: "HTTP Version Not Supported",
    506: "Variant Also Negotiates",
    507: "Insufficient Storage",
    508: "Loop Detected",
    510: "Not Extended",
    511: "Network Authentication Required"
  }.toTable

proc getMethodInfo*(methodName: string): Option[HttpMethodInfo] =
  ## HTTP メソッド名からその情報を取得
  let normalizedMethod = methodName.toUpperAscii()
  if normalizedMethod in HttpMethodRegistry:
    return some(HttpMethodRegistry[normalizedMethod])
  return none(HttpMethodInfo)

proc isMethodSafe*(methodName: string): bool =
  ## 指定されたHTTPメソッドが安全かどうかを判定
  ## 「安全」は、リソースの状態を変更しないこと（副作用がない）を意味する
  let methodInfo = getMethodInfo(methodName)
  if methodInfo.isSome:
    return methodInfo.get().isSafe
  return false

proc isMethodIdempotent*(methodName: string): bool =
  ## 指定されたHTTPメソッドが冪等かどうかを判定
  ## 「冪等」とは、同じリクエストを複数回実行しても結果が変わらないことを意味する
  let methodInfo = getMethodInfo(methodName)
  if methodInfo.isSome:
    return methodInfo.get().isIdempotent
  return false

proc isMethodCacheable*(methodName: string): bool =
  ## 指定されたHTTPメソッドがキャッシュ可能かどうかを判定
  let methodInfo = getMethodInfo(methodName)
  if methodInfo.isSome:
    return methodInfo.get().isCacheable
  return false

proc doesMethodHaveBody*(methodName: string): bool =
  ## 指定されたHTTPメソッドがボディを持つかどうかを判定
  let methodInfo = getMethodInfo(methodName)
  if methodInfo.isSome:
    return methodInfo.get().hasBody
  return false

proc isStandardMethod*(methodName: string): bool =
  ## 指定されたHTTPメソッドが標準メソッド（RFC定義）かどうかを判定
  let methodInfo = getMethodInfo(methodName)
  if methodInfo.isSome:
    return methodInfo.get().standard
  return false

proc getExpectedStatusCodes*(methodName: string): seq[int] =
  ## 指定されたHTTPメソッドで期待されるステータスコードのリストを取得
  let methodInfo = getMethodInfo(methodName)
  if methodInfo.isSome:
    return methodInfo.get().statusCodes
  return @[]

proc getStatusCodeDescription*(statusCode: int): string =
  ## HTTPステータスコードの説明を取得
  if statusCode in HttpStatusCodes:
    return HttpStatusCodes[statusCode]
  return "Unknown Status Code"

proc isSuccessStatusCode*(statusCode: int): bool =
  ## 成功を示すステータスコード（2xx）かどうかを判定
  return statusCode >= 200 and statusCode < 300

proc isRedirectStatusCode*(statusCode: int): bool =
  ## リダイレクトを示すステータスコード（3xx）かどうかを判定
  return statusCode >= 300 and statusCode < 400

proc isClientErrorStatusCode*(statusCode: int): bool =
  ## クライアントエラーを示すステータスコード（4xx）かどうかを判定
  return statusCode >= 400 and statusCode < 500

proc isServerErrorStatusCode*(statusCode: int): bool =
  ## サーバーエラーを示すステータスコード（5xx）かどうかを判定
  return statusCode >= 500 and statusCode < 600

proc isErrorStatusCode*(statusCode: int): bool =
  ## エラーを示すステータスコード（4xx, 5xx）かどうかを判定
  return statusCode >= 400 and statusCode < 600

proc isPermanentRedirect*(statusCode: int): bool =
  ## 永続的リダイレクトを示すステータスコードかどうかを判定
  return statusCode in [301, 308]

proc isTemporaryRedirect*(statusCode: int): bool =
  ## 一時的リダイレクトを示すステータスコードかどうかを判定
  return statusCode in [302, 303, 307]

proc getStatusCodeCategory*(statusCode: int): string =
  ## ステータスコードのカテゴリを取得
  if statusCode >= 100 and statusCode < 200:
    return "情報"
  elif statusCode >= 200 and statusCode < 300:
    return "成功"
  elif statusCode >= 300 and statusCode < 400:
    return "リダイレクション"
  elif statusCode >= 400 and statusCode < 500:
    return "クライアントエラー"
  elif statusCode >= 500 and statusCode < 600:
    return "サーバーエラー"
  else:
    return "不明"

proc shouldMethodPreserveBody*(fromMethod, toMethod: string): bool =
  ## リダイレクトでメソッドを変更する際にボディを維持すべきかどうかを判定
  ## 例えば、307, 308ではボディを維持すべきで、302, 303では通常GETに変換してボディは破棄
  let fromMet = fromMethod.toUpperAscii()
  let toMet = toMethod.toUpperAscii()
  
  # 302, 303リダイレクトの場合、通常GETに変換（ボディなし）
  if fromMet in ["POST", "PUT", "PATCH", "DELETE"] and toMet == "GET":
    return false
  
  # 同じメソッドのままか、類似のメソッドの場合はボディを維持
  return true

proc getStatusCodeForMethod*(methodName: string, success: bool = true): int =
  ## 特定のHTTPメソッドに対する典型的な成功/失敗のステータスコードを取得
  let methodUpper = methodName.toUpperAscii()
  
  if success:
    case methodUpper
    of "POST": return 201  # Created
    of "PUT": return 200   # OK または 204 No Content
    of "DELETE": return 204  # No Content
    of "PATCH": return 200  # OK
    of "HEAD", "GET", "OPTIONS": return 200  # OK
    else: return 200
  else:
    case methodUpper
    of "POST", "PUT", "PATCH": return 400  # Bad Request
    of "DELETE": return 404  # Not Found
    of "GET": return 404  # Not Found
    of "OPTIONS": return 405  # Method Not Allowed
    else: return 400 