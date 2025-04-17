import std/[strutils, options, tables]

type
  HttpVersion* = object
    major*: int
    minor*: int
    name*: string
    description*: string
    rfc*: string
  
  HttpVersionParsingError* = object of CatchableError

const
  # HTTPバージョン定義
  HttpVersions* = {
    "0.9": HttpVersion(
      major: 0,
      minor: 9,
      name: "HTTP/0.9",
      description: "初期のHTTPプロトコル。GETメソッドのみ。ヘッダー無し。",
      rfc: "非公式"
    ),
    "1.0": HttpVersion(
      major: 1,
      minor: 0,
      name: "HTTP/1.0",
      description: "基本的なHTTPプロトコル。接続ごとに新しいTCP接続。",
      rfc: "RFC 1945"
    ),
    "1.1": HttpVersion(
      major: 1,
      minor: 1,
      name: "HTTP/1.1",
      description: "持続的接続、チャンク転送エンコーディング、キャッシュなどをサポート。",
      rfc: "RFC 2616, RFC 7230-7235"
    ),
    "2.0": HttpVersion(
      major: 2,
      minor: 0,
      name: "HTTP/2",
      description: "多重化、サーバープッシュ、ヘッダー圧縮、バイナリプロトコル。",
      rfc: "RFC 7540"
    ),
    "3.0": HttpVersion(
      major: 3,
      minor: 0,
      name: "HTTP/3",
      description: "UDPベースのQUICプロトコル上でのHTTP。低レイテンシー、接続マイグレーション。",
      rfc: "RFC 9114"
    )
  }.toTable

proc parseHttpVersion*(versionStr: string): Option[HttpVersion] =
  ## HTTP バージョン文字列（例: "HTTP/1.1"）をパースして HttpVersion を返す
  ## 不明な形式の場合は None を返す
  try:
    let cleaned = versionStr.strip().toUpperAscii()
    
    # "HTTP/" プレフィックスを処理
    var versionPart = cleaned
    if cleaned.startsWith("HTTP/"):
      versionPart = cleaned.substr(5)
    
    # メジャー・マイナーバージョンを抽出
    let parts = versionPart.split('.')
    if parts.len >= 2:
      let majorVersion = parts[0].parseInt()
      let minorVersion = parts[1].parseInt()
      
      # 標準形式で検索
      let key = $majorVersion & "." & $minorVersion
      if key in HttpVersions:
        return some(HttpVersions[key])
    
    # HTTP/2 と HTTP/3 の特殊形式を処理
    if cleaned == "HTTP/2" or cleaned == "H2":
      return some(HttpVersions["2.0"])
    elif cleaned == "HTTP/3" or cleaned == "H3":
      return some(HttpVersions["3.0"])
    
    return none(HttpVersion)
  except:
    return none(HttpVersion)

proc versionToString*(version: HttpVersion): string =
  ## HttpVersion オブジェクトを文字列表現に変換
  return "HTTP/" & $version.major & "." & $version.minor

proc isHttp09*(version: HttpVersion): bool =
  ## HTTP/0.9 かどうかを判定
  return version.major == 0 and version.minor == 9

proc isHttp10*(version: HttpVersion): bool =
  ## HTTP/1.0 かどうかを判定
  return version.major == 1 and version.minor == 0

proc isHttp11*(version: HttpVersion): bool =
  ## HTTP/1.1 かどうかを判定
  return version.major == 1 and version.minor == 1

proc isHttp2*(version: HttpVersion): bool =
  ## HTTP/2 かどうかを判定
  return version.major == 2 and version.minor == 0

proc isHttp3*(version: HttpVersion): bool =
  ## HTTP/3 かどうかを判定
  return version.major == 3 and version.minor == 0

proc supportsKeepAlive*(version: HttpVersion): bool =
  ## Keep-Alive をサポートしているかどうかを判定
  return not isHttp09(version)

proc supportsChunkedTransfer*(version: HttpVersion): bool =
  ## チャンク転送エンコーディングをサポートしているかどうかを判定
  return isHttp11(version) or isHttp2(version) or isHttp3(version)

proc supportsMultiplexing*(version: HttpVersion): bool =
  ## 多重化をサポートしているかどうかを判定
  return isHttp2(version) or isHttp3(version)

proc supportsServerPush*(version: HttpVersion): bool =
  ## サーバープッシュをサポートしているかどうかを判定
  return isHttp2(version) or isHttp3(version)

proc supportsHeaderCompression*(version: HttpVersion): bool =
  ## ヘッダー圧縮をサポートしているかどうかを判定
  return isHttp2(version) or isHttp3(version)

proc isUdpBased*(version: HttpVersion): bool =
  ## UDP ベースかどうかを判定（HTTP/3 は QUIC を使用）
  return isHttp3(version)

proc isBinaryProtocol*(version: HttpVersion): bool =
  ## バイナリプロトコルかどうかを判定
  return isHttp2(version) or isHttp3(version)

proc getDefaultPort*(version: HttpVersion, secure: bool = false): int =
  ## 指定された HTTP バージョンのデフォルトポートを返す
  if secure:
    return 443  # HTTPS
  else:
    return 80   # HTTP

proc compareVersions*(a, b: HttpVersion): int =
  ## 2つの HTTP バージョンを比較
  ## 戻り値: a < b なら -1, a == b なら 0, a > b なら 1
  if a.major < b.major:
    return -1
  elif a.major > b.major:
    return 1
  else:
    # メジャーバージョンが同じ場合、マイナーバージョンを比較
    if a.minor < b.minor:
      return -1
    elif a.minor > b.minor:
      return 1
    else:
      return 0

proc isNewerThan*(a, b: HttpVersion): bool =
  ## a が b より新しいバージョンかどうかを判定
  return compareVersions(a, b) > 0

proc isOlderThan*(a, b: HttpVersion): bool =
  ## a が b より古いバージョンかどうかを判定
  return compareVersions(a, b) < 0

proc isSameVersion*(a, b: HttpVersion): bool =
  ## a と b が同じバージョンかどうかを判定
  return compareVersions(a, b) == 0

proc getLatestVersion*(): HttpVersion =
  ## 利用可能な最新の HTTP バージョンを返す
  return HttpVersions["3.0"]

proc getVersion*(majorVersion, minorVersion: int): Option[HttpVersion] =
  ## メジャーおよびマイナーバージョン番号から HttpVersion を取得
  let key = $majorVersion & "." & $minorVersion
  if key in HttpVersions:
    return some(HttpVersions[key])
  return none(HttpVersion)

proc requiresHostHeader*(version: HttpVersion): bool =
  ## Host ヘッダーが必須かどうかを判定
  return isHttp11(version) or isHttp2(version) or isHttp3(version)

proc getVersionName*(version: HttpVersion): string =
  ## バージョンの名前を取得
  return version.name

proc getVersionDescription*(version: HttpVersion): string =
  ## バージョンの説明を取得
  return version.description

proc getRfc*(version: HttpVersion): string =
  ## バージョンの RFC 番号を取得
  return version.rfc 