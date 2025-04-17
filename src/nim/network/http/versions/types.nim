import std/[strutils, strformat]

type
  # HTTP バージョンの列挙型
  HttpVersion* = enum
    Http09 = "HTTP/0.9"  # 初期バージョン、非常に限定的な機能
    Http10 = "HTTP/1.0"  # 基本的な機能セット
    Http11 = "HTTP/1.1"  # 持続的接続などの改良
    Http20 = "HTTP/2.0"  # 多重化、サーバープッシュなど
    Http30 = "HTTP/3.0"  # QUICベースの実装
    HttpUnknown = "UNKNOWN" # 未知のバージョン

  # HTTP バージョンの詳細情報
  HttpVersionInfo* = object
    major*: int          # メジャーバージョン番号
    minor*: int          # マイナーバージョン番号
    persistent*: bool    # 持続的接続をサポートするか
    pipelining*: bool    # パイプライン処理をサポートするか
    multiplexing*: bool  # 多重化をサポートするか
    headerCompression*: bool # ヘッダー圧縮をサポートするか
    serverPush*: bool    # サーバープッシュをサポートするか
    
  # HTTP バージョンをラップする型（カスタムバージョンのサポート用）
  HttpVersionWrapper* = object
    case kind*: HttpVersion
    of HttpUnknown:
      customVersion*: string
      customMajor*: int
      customMinor*: int
    else:
      discard

# 文字列からHttpVersionWrapperを作成
proc parseHttpVersion*(versionStr: string): HttpVersionWrapper =
  let normalizedStr = versionStr.strip().toUpperAscii()
  
  # 標準バージョンをチェック
  case normalizedStr
  of $Http09:
    result = HttpVersionWrapper(kind: Http09)
  of $Http10:
    result = HttpVersionWrapper(kind: Http10)
  of $Http11:
    result = HttpVersionWrapper(kind: Http11)
  of $Http20, "HTTP/2":
    result = HttpVersionWrapper(kind: Http20)
  of $Http30, "HTTP/3":
    result = HttpVersionWrapper(kind: Http30)
  else:
    # カスタムバージョンまたは未知のバージョンの解析を試みる
    try:
      if normalizedStr.startsWith("HTTP/"):
        let parts = normalizedStr[5..^1].split('.')
        if parts.len >= 2:
          let 
            major = parseInt(parts[0])
            minor = parseInt(parts[1])
          result = HttpVersionWrapper(
            kind: HttpUnknown, 
            customVersion: normalizedStr,
            customMajor: major,
            customMinor: minor
          )
        else:
          result = HttpVersionWrapper(
            kind: HttpUnknown, 
            customVersion: normalizedStr,
            customMajor: 0,
            customMinor: 0
          )
      else:
        result = HttpVersionWrapper(
          kind: HttpUnknown, 
          customVersion: normalizedStr,
          customMajor: 0,
          customMinor: 0
        )
    except:
      result = HttpVersionWrapper(
        kind: HttpUnknown, 
        customVersion: normalizedStr,
        customMajor: 0,
        customMinor: 0
      )

# HttpVersionWrapperを文字列に変換
proc `$`*(version: HttpVersionWrapper): string =
  case version.kind
  of HttpUnknown:
    return version.customVersion
  else:
    return $version.kind

# バージョン情報の取得
proc getVersionInfo*(version: HttpVersionWrapper): HttpVersionInfo =
  case version.kind
  of Http09:
    result = HttpVersionInfo(
      major: 0,
      minor: 9,
      persistent: false,
      pipelining: false,
      multiplexing: false,
      headerCompression: false,
      serverPush: false
    )
  of Http10:
    result = HttpVersionInfo(
      major: 1,
      minor: 0,
      persistent: false, # デフォルトでは永続的接続なしだが、Keepaliveヘッダで有効化可能
      pipelining: false,
      multiplexing: false,
      headerCompression: false,
      serverPush: false
    )
  of Http11:
    result = HttpVersionInfo(
      major: 1,
      minor: 1,
      persistent: true,  # デフォルトで永続的接続
      pipelining: true,  # HTTP/1.1はパイプライン処理をサポート
      multiplexing: false,
      headerCompression: false,
      serverPush: false
    )
  of Http20:
    result = HttpVersionInfo(
      major: 2,
      minor: 0,
      persistent: true,
      pipelining: true,
      multiplexing: true, # HTTP/2の主要な特徴
      headerCompression: true, # HPACKによるヘッダー圧縮
      serverPush: true # サーバープッシュをサポート
    )
  of Http30:
    result = HttpVersionInfo(
      major: 3,
      minor: 0,
      persistent: true,
      pipelining: true,
      multiplexing: true,
      headerCompression: true, # QPACKによるヘッダー圧縮
      serverPush: true 
    )
  of HttpUnknown:
    # カスタムバージョンの情報を設定
    result = HttpVersionInfo(
      major: version.customMajor,
      minor: version.customMinor,
      persistent: version.customMajor >= 1 and version.customMinor >= 1, # HTTP/1.1以上は永続的接続
      pipelining: version.customMajor >= 1 and version.customMinor >= 1,
      multiplexing: version.customMajor >= 2,
      headerCompression: version.customMajor >= 2,
      serverPush: version.customMajor >= 2
    )

# メジャーバージョン番号の取得
proc getMajorVersion*(version: HttpVersionWrapper): int =
  return getVersionInfo(version).major

# マイナーバージョン番号の取得
proc getMinorVersion*(version: HttpVersionWrapper): int =
  return getVersionInfo(version).minor

# バージョン文字列の整形（HTTP/X.Y形式）
proc formatVersion*(version: HttpVersionWrapper): string =
  let info = getVersionInfo(version)
  return fmt"HTTP/{info.major}.{info.minor}"

# バージョンの比較（v1 > v2）
proc `>`*(v1, v2: HttpVersionWrapper): bool =
  let 
    info1 = getVersionInfo(v1)
    info2 = getVersionInfo(v2)
  
  if info1.major > info2.major:
    return true
  elif info1.major == info2.major:
    return info1.minor > info2.minor
  else:
    return false

# バージョンの比較（v1 < v2）
proc `<`*(v1, v2: HttpVersionWrapper): bool =
  let 
    info1 = getVersionInfo(v1)
    info2 = getVersionInfo(v2)
  
  if info1.major < info2.major:
    return true
  elif info1.major == info2.major:
    return info1.minor < info2.minor
  else:
    return false

# バージョンの比較（v1 == v2）
proc `==`*(v1, v2: HttpVersionWrapper): bool =
  let 
    info1 = getVersionInfo(v1)
    info2 = getVersionInfo(v2)
  
  return info1.major == info2.major and info1.minor == info2.minor

# HTTP/2以上かどうかをチェック
proc isHttp2OrHigher*(version: HttpVersionWrapper): bool =
  return getVersionInfo(version).major >= 2

# 持続的接続をサポートしているかをチェック
proc supportsPersistentConnections*(version: HttpVersionWrapper): bool =
  return getVersionInfo(version).persistent

# パイプライン処理をサポートしているかをチェック
proc supportsPipelining*(version: HttpVersionWrapper): bool =
  return getVersionInfo(version).pipelining

# 多重化をサポートしているかをチェック
proc supportsMultiplexing*(version: HttpVersionWrapper): bool =
  return getVersionInfo(version).multiplexing

# ヘッダー圧縮をサポートしているかをチェック
proc supportsHeaderCompression*(version: HttpVersionWrapper): bool =
  return getVersionInfo(version).headerCompression

# サーバープッシュをサポートしているかをチェック
proc supportsServerPush*(version: HttpVersionWrapper): bool =
  return getVersionInfo(version).serverPush 