import std/[strutils]

type
  # HTTP メソッドの列挙型
  HttpMethod* = enum
    HttpGet     = "GET"
    HttpPost    = "POST"
    HttpPut     = "PUT"
    HttpDelete  = "DELETE"
    HttpHead    = "HEAD"
    HttpOptions = "OPTIONS"
    HttpPatch   = "PATCH"
    HttpTrace   = "TRACE"
    HttpConnect = "CONNECT"
    HttpCustom  = "CUSTOM"  # カスタムメソッド用

  # HTTPメソッドのプロパティを表す型
  # メソッドの性質や特徴を定義するためのフラグのセット
  HttpMethodProperties* = object
    idempotent*: bool     # 同じリクエストを複数回実行しても同じ結果になるか
    safe*: bool           # リソースの状態を変更しないか
    cacheable*: bool      # レスポンスがキャッシュ可能か
    allowBody*: bool      # リクエストにボディを含めることができるか
    responseBody*: bool   # レスポンスにボディを含めることが標準か
    allowedInForms*: bool # HTMLフォームで使用可能か

  # HTTPメソッドをラップする型（カスタムメソッドのサポート用）
  HttpMethodWrapper* = object
    case kind*: HttpMethod
    of HttpCustom:
      customName*: string
    else:
      discard

# HttpMethodWrapperを文字列から作成
proc newHttpMethod*(methodName: string): HttpMethodWrapper =
  let upperMethod = methodName.toUpperAscii()
  
  # 標準メソッドをチェック
  case upperMethod
  of $HttpGet:
    result = HttpMethodWrapper(kind: HttpGet)
  of $HttpPost:
    result = HttpMethodWrapper(kind: HttpPost)
  of $HttpPut:
    result = HttpMethodWrapper(kind: HttpPut)
  of $HttpDelete:
    result = HttpMethodWrapper(kind: HttpDelete)
  of $HttpHead:
    result = HttpMethodWrapper(kind: HttpHead)
  of $HttpOptions:
    result = HttpMethodWrapper(kind: HttpOptions)
  of $HttpPatch:
    result = HttpMethodWrapper(kind: HttpPatch)
  of $HttpTrace:
    result = HttpMethodWrapper(kind: HttpTrace)
  of $HttpConnect:
    result = HttpMethodWrapper(kind: HttpConnect)
  else:
    # カスタムメソッド
    result = HttpMethodWrapper(kind: HttpCustom, customName: upperMethod)

# HttpMethodWrapperを文字列に変換
proc `$`*(method: HttpMethodWrapper): string =
  case method.kind
  of HttpCustom:
    return method.customName
  else:
    return $method.kind

# メソッドのプロパティを取得
proc getMethodProperties*(method: HttpMethodWrapper): HttpMethodProperties =
  case method.kind
  of HttpGet:
    result = HttpMethodProperties(
      idempotent: true,
      safe: true,
      cacheable: true,
      allowBody: false,
      responseBody: true,
      allowedInForms: true
    )
  of HttpHead:
    result = HttpMethodProperties(
      idempotent: true,
      safe: true,
      cacheable: true,
      allowBody: false,
      responseBody: false,
      allowedInForms: false
    )
  of HttpPost:
    result = HttpMethodProperties(
      idempotent: false,
      safe: false,
      cacheable: true, # POSTはある条件下ではキャッシュ可能
      allowBody: true,
      responseBody: true,
      allowedInForms: true
    )
  of HttpPut:
    result = HttpMethodProperties(
      idempotent: true,
      safe: false,
      cacheable: false,
      allowBody: true,
      responseBody: true,
      allowedInForms: false
    )
  of HttpDelete:
    result = HttpMethodProperties(
      idempotent: true,
      safe: false,
      cacheable: false,
      allowBody: true,
      responseBody: true,
      allowedInForms: false
    )
  of HttpOptions:
    result = HttpMethodProperties(
      idempotent: true,
      safe: true,
      cacheable: false,
      allowBody: true,
      responseBody: true,
      allowedInForms: false
    )
  of HttpPatch:
    result = HttpMethodProperties(
      idempotent: false,
      safe: false,
      cacheable: false,
      allowBody: true,
      responseBody: true,
      allowedInForms: false
    )
  of HttpTrace:
    result = HttpMethodProperties(
      idempotent: true,
      safe: true,
      cacheable: false,
      allowBody: false,
      responseBody: true,
      allowedInForms: false
    )
  of HttpConnect:
    result = HttpMethodProperties(
      idempotent: false,
      safe: false,
      cacheable: false,
      allowBody: true,
      responseBody: true,
      allowedInForms: false
    )
  of HttpCustom:
    # カスタムメソッドはデフォルト値を設定
    result = HttpMethodProperties(
      idempotent: false,
      safe: false,
      cacheable: false,
      allowBody: true,
      responseBody: true,
      allowedInForms: false
    )

# メソッドがべき等かどうかをチェック
proc isIdempotent*(method: HttpMethodWrapper): bool =
  return getMethodProperties(method).idempotent

# メソッドが安全かどうかをチェック
proc isSafe*(method: HttpMethodWrapper): bool =
  return getMethodProperties(method).safe

# メソッドがキャッシュ可能かどうかをチェック
proc isCacheable*(method: HttpMethodWrapper): bool =
  return getMethodProperties(method).cacheable

# メソッドがリクエストボディを許容するかどうかをチェック
proc allowsRequestBody*(method: HttpMethodWrapper): bool =
  return getMethodProperties(method).allowBody

# メソッドがレスポンスボディを返すかどうかをチェック
proc hasResponseBody*(method: HttpMethodWrapper): bool =
  return getMethodProperties(method).responseBody

# メソッドがHTMLフォームで使用可能かどうかをチェック
proc isAllowedInForms*(method: HttpMethodWrapper): bool =
  return getMethodProperties(method).allowedInForms 