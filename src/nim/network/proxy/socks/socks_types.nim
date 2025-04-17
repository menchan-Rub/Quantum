## SOCKS プロキシ型定義
##
## SOCKSプロキシプロトコルで使用される型定義と関連するユーティリティ関数を提供します。
## SOCKS4/4a および SOCKS5（RFC 1928）プロトコルをサポートしています。

type
  SocksVersion* = enum
    ## SOCKSプロトコルバージョン
    svSocks4,        # SOCKS4プロトコル
    svSocks5         # SOCKS5プロトコル

  SocksCommand* = enum
    ## SOCKSコマンドタイプ
    scConnect = 1,     # CONNECT：TCP接続を確立
    scBind = 2,        # BIND：サーバーからの接続を待機
    scUdpAssociate = 3 # UDP ASSOCIATE：UDPリレーを確立

  SocksAddressType* = enum
    ## SOCKSアドレスタイプ（SOCKS5のみ）
    satIpv4 = 1,      # IPv4アドレス
    satDomainName = 3, # ドメイン名
    satIpv6 = 4        # IPv6アドレス

  SocksAuthMethod* = enum
    ## SOCKS5認証方式
    samNoAuth = 0,          # 認証なし
    samGssApi = 1,          # GSSAPI
    samUsernamePassword = 2 # ユーザー名/パスワード

  SocksReply* = enum
    ## SOCKS5応答コード
    srSucceeded = 0,           # 成功
    srGeneralFailure = 1,      # 一般的な失敗
    srNotAllowed = 2,          # 接続が許可されていない
    srNetworkUnreachable = 3,  # ネットワーク到達不能
    srHostUnreachable = 4,     # ホスト到達不能
    srConnectionRefused = 5,   # 接続拒否
    srTtlExpired = 6,          # TTL期限切れ
    srCommandNotSupported = 7, # コマンド未サポート
    srAddressTypeNotSupported = 8 # アドレスタイプ未サポート

  Socks4Reply* = enum
    ## SOCKS4応答コード
    s4rRequestGranted = 90,    # リクエスト許可
    s4rRequestRejected = 91,   # リクエスト拒否
    s4rIdentdFailed = 92,      # IDENTDに接続できない
    s4rIdentdMismatch = 93     # ユーザーIDが異なる

  SocksError* = object of CatchableError
    ## SOCKSプロキシ関連のエラー

  SocksAddress* = object
    ## SOCKSアドレス情報
    case addressType*: SocksAddressType
    of satIpv4:
      ipv4*: array[4, uint8]      # IPv4アドレス（4バイト）
    of satDomainName:
      domainName*: string         # ドメイン名
    of satIpv6:
      ipv6*: array[16, uint8]     # IPv6アドレス（16バイト）

  SocksSettings* = object
    ## SOCKSプロキシ設定
    enabled*: bool                 # プロキシ有効フラグ
    host*: string                  # プロキシホスト
    port*: int                     # プロキシポート
    version*: SocksVersion         # SOCKSバージョン
    username*: string              # ユーザー名（SOCKS5のみ）
    password*: string              # パスワード（SOCKS5のみ）
    resolveHostnamesLocally*: bool # ホスト名をローカルで解決するかどうか

  SocksRequest* = object
    ## SOCKSリクエスト情報
    version*: SocksVersion         # SOCKSバージョン
    command*: SocksCommand         # コマンドタイプ
    address*: SocksAddress         # 宛先アドレス
    port*: uint16                  # 宛先ポート

proc newSocksSettings*(): SocksSettings =
  ## デフォルトのSOCKSプロキシ設定を作成
  result = SocksSettings(
    enabled: false,
    host: "",
    port: 1080,
    version: svSocks5,
    username: "",
    password: "",
    resolveHostnamesLocally: true
  )

proc newSocksRequest*(version: SocksVersion, 
                    command: SocksCommand, 
                    host: string, 
                    port: uint16): SocksRequest =
  ## SOCKSリクエストを作成する
  ##
  ## 引数:
  ##   version: SOCKSプロトコルバージョン
  ##   command: SOCKSコマンド
  ##   host: 接続先ホスト（IPアドレスまたはドメイン名）
  ##   port: 接続先ポート
  ##
  ## 戻り値:
  ##   SocksRequestオブジェクト
  
  result = SocksRequest(
    version: version,
    command: command,
    port: port
  )
  
  # ホストがIPv4アドレスかどうかをチェック
  try:
    var ipv4Octets: array[4, uint8]
    let parts = host.split('.')
    
    if parts.len == 4:
      var allNumbers = true
      for i in 0..<4:
        try:
          let octet = parseInt(parts[i])
          if octet >= 0 and octet <= 255:
            ipv4Octets[i] = uint8(octet)
          else:
            allNumbers = false
            break
        except ValueError:
          allNumbers = false
          break
      
      if allNumbers:
        result.address = SocksAddress(addressType: satIpv4, ipv4: ipv4Octets)
        return
  except Exception:
    discard
  
  # ホストがIPv6アドレスかどうかをチェック
  if host.contains(':'):
    try:
      var ipv6Octets: array[16, uint8]
      
      # IPv6アドレスの正規化
      var normalizedHost = host
      if normalizedHost.startsWith('[') and normalizedHost.endsWith(']'):
        normalizedHost = normalizedHost[1..^2]
      
      # IPv6アドレスの解析
      let groups = normalizedHost.split(':')
      
      if normalizedHost.contains("::"):
        var expandedGroups: seq[string] = @[]
        var doubleColonPos = -1
        
        for i, group in groups:
          if group == "":
            if doubleColonPos == -1:
              doubleColonPos = i
            elif i != groups.len - 1:  # 末尾の空グループは許容
              continue
          else:
            expandedGroups.add(group)
        
        let missingGroups = 8 - expandedGroups.len
        var fullGroups: seq[string] = @[]
        
        for i in 0..<groups.len:
          if i == doubleColonPos:
            for _ in 0..<missingGroups:
              fullGroups.add("0")
          elif i < groups.len - 1 and groups[i] == "" and groups[i+1] == "":
            continue
          elif groups[i] != "" or i == groups.len - 1:
            fullGroups.add(if groups[i] == "" : "0" else: groups[i])
        
        var octetIndex = 0
        for group in fullGroups:
          let value = parseHexInt("0x" & group)
          ipv6Octets[octetIndex] = uint8((value shr 8) and 0xFF)
          ipv6Octets[octetIndex + 1] = uint8(value and 0xFF)
          octetIndex += 2
      else:
        # 標準形式のIPv6アドレス
        if groups.len == 8:
          var octetIndex = 0
          for group in groups:
            let value = parseHexInt("0x" & group)
            ipv6Octets[octetIndex] = uint8((value shr 8) and 0xFF)
            ipv6Octets[octetIndex + 1] = uint8(value and 0xFF)
            octetIndex += 2
        else:
          raise newException(ValueError, "Invalid IPv6 address format")
      
      result.address = SocksAddress(addressType: satIpv6, ipv6: ipv6Octets)
      return
    except Exception:
      discard
  
  # それ以外はドメイン名として扱う
  if host.len > 255:
    raise newException(ValueError, "Domain name too long (max 255 characters)")
  
  result.address = SocksAddress(addressType: satDomainName, domainName: host)

proc getSocksProxyUrlFromSettings*(settings: SocksSettings): string =
  ## プロキシ設定からSOCKSプロキシURLを取得
  ##
  ## 引数:
  ##   settings: SOCKSプロキシ設定
  ##
  ## 戻り値:
  ##   SOCKSプロキシURL文字列
  
  if not settings.enabled:
    return ""
  
  let scheme = if settings.version == svSocks5: "socks5" else: "socks4"
  
  if settings.username.len > 0 and settings.version == svSocks5:
    # RFC 3986に準拠したエンコード
    proc encodeUrlComponent(s: string): string =
      result = ""
      for c in s:
        if c.isAlphaNumeric() or c in {'-', '.', '_', '~'}:
          result.add(c)
        else:
          result.add("%" & toHex(ord(c), 2))
    
    let encodedUsername = encodeUrlComponent(settings.username)
    let encodedPassword = encodeUrlComponent(settings.password)
    
    result = fmt"{scheme}://{encodedUsername}:{encodedPassword}@{settings.host}:{settings.port}"
  else:
    result = fmt"{scheme}://{settings.host}:{settings.port}"

proc formatSocksReplyCode*(code: SocksReply): string =
  ## SOCKS5応答コードをわかりやすい文字列に変換
  case code:
  of srSucceeded:
    return "成功"
  of srGeneralFailure:
    return "一般的な失敗"
  of srNotAllowed:
    return "接続が許可されていない"
  of srNetworkUnreachable:
    return "ネットワーク到達不能"
  of srHostUnreachable:
    return "ホスト到達不能"
  of srConnectionRefused:
    return "接続拒否"
  of srTtlExpired:
    return "TTL期限切れ"
  of srCommandNotSupported:
    return "コマンド未サポート"
  of srAddressTypeNotSupported:
    return "アドレスタイプ未サポート"

proc formatSocks4ReplyCode*(code: Socks4Reply): string =
  ## SOCKS4応答コードをわかりやすい文字列に変換
  case code:
  of s4rRequestGranted:
    return "リクエスト許可"
  of s4rRequestRejected:
    return "リクエスト拒否"
  of s4rIdentdFailed:
    return "IDENTDに接続できない"
  of s4rIdentdMismatch:
    return "ユーザーIDが異なる"