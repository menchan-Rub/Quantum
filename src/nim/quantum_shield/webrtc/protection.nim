# protection.nim
## 高度なWebRTC保護機能モジュール
## WebRTCによるIPアドレス漏洩を防止する機能を提供します

import std/[
  options,
  tables,
  sets,
  hashes,
  strutils,
  strformat,
  sequtils,
  algorithm,
  times,
  uri,
  re,
  os,
  json,
  logging,
  asyncdispatch
]

import ../../privacy/privacy_types
import ../../privacy/blockers/tracker_blocker as tb
import ../../network/http/client/http_client_types
import ../../utils/[logging, errors]

type
  WebRtcProtectionLevel* = enum
    ## WebRTC保護レベル
    wrpDisabled,      ## 保護無効
    wrpPublicOnly,    ## 公開IPアドレスのみ許可
    wrpFullProtection,## プライベートIPも保護
    wrpDisableWebRtc  ## WebRTC完全無効化

  CandidateType* = enum
    ## ICE候補タイプ
    ctHost,              ## ホスト候補（ローカルIPアドレス）
    ctSrflx,             ## Server Reflexive候補（STUNサーバー経由）
    ctPrflx,             ## Peer Reflexive候補（P2P経由）
    ctRelay,             ## リレー候補（TURNサーバー経由）
    ctUnknown            ## 不明な候補タイプ

  IceServerPolicy* = enum
    ispAllowAll,      ## すべてのICEサーバーを許可
    ispTrustedOnly,   ## 信頼済みサーバーのみ許可
    ispBlockAll       ## すべてのICEサーバーをブロック

  IceCandidate* = object
    ## ICE候補オブジェクト
    foundation*: string         ## 候補の基盤ID
    component*: int             ## コンポーネントID
    transport*: string          ## トランスポートプロトコル
    priority*: int              ## 優先度
    ip*: string                 ## IPアドレス
    port*: int                  ## ポート番号
    candidateType*: CandidateType ## 候補タイプ
    relatedAddress*: string     ## 関連アドレス
    relatedPort*: int           ## 関連ポート
    generation*: int            ## 生成番号
    ufrag*: string              ## ICE ufrag
    networkId*: int             ## ネットワークID
    networkCost*: int           ## ネットワークコスト
    raw*: string                ## 元の候補文字列
    isPrivate*: bool            ## プライベートアドレスかどうか

  IpAddressType* = enum
    ## IPアドレスタイプ
    ipPublic,            ## パブリックIPアドレス
    ipPrivate,           ## プライベートIPアドレス
    ipLoopback,          ## ループバックアドレス
    ipLink,              ## リンクローカルアドレス
    ipMdns,              ## mDNSアドレス
    ipUnknown            ## 不明なアドレスタイプ

  WebRtcProtector* = ref object
    ## WebRTC保護機能
    enabled*: bool
    protectionLevel*: WebRtcProtectionLevel
    iceServerPolicy*: IceServerPolicy
    logger: Logger
    trustedIceServers*: HashSet[string]
    blockedIceServers*: HashSet[string]
    exceptionDomains*: HashSet[string]
    ipMaskingEnabled*: bool
    lastPolicyUpdate*: Time
    connectionStats*: Table[string, ConnectionStats]

  ConnectionStats* = object
    domain*: string
    startTime*: Time
    endTime*: Option[Time]
    iceServersUsed*: seq[string]
    localCandidates*: seq[IceCandidate]
    remoteCandidates*: seq[IceCandidate]
    connectionType*: string
    isP2P*: bool
    isEncrypted*: bool

  ProtectionRuleSet* = ref object
    ## 保護ルールセット
    rules*: seq[ProtectionRule]       ## 保護ルール
    defaultAction*: ProtectionAction  ## デフォルトアクション

  ProtectionRule* = object
    ## 保護ルール
    domain*: string                   ## 対象ドメイン
    action*: ProtectionAction         ## アクション
    level*: WebRtcProtectionLevel     ## 保護レベル
    priority*: int                    ## 優先度

  ProtectionAction* = enum
    ## 保護アクション
    paAllow,     ## 許可
    paBlock,     ## ブロック
    paReplace,   ## 置換
    paModify     ## 修正

  FingerprintInfo* = object
    ## フィンガープリント情報
    lastSeen*: Time                  ## 最終検出時間
    domains*: HashSet[string]        ## 検出ドメイン
    count*: int                      ## 検出回数

const
  PRIVATE_IPV4_PATTERNS = [
    "^10\\.",                 # 10.0.0.0/8
    "^172\\.(1[6-9]|2[0-9]|3[0-1])\\.", # 172.16.0.0/12
    "^192\\.168\\.",          # 192.168.0.0/16
    "^127\\.",                # 127.0.0.0/8
    "^169\\.254\\."           # 169.254.0.0/16 (リンクローカル)
  ]
  
  PRIVATE_IPV6_PATTERNS = [
    "^::1$",                  # ループバック
    "^fe80:",                 # リンクローカル
    "^fc00:",                 # ユニークローカル
    "^fd00:"                  # ユニークローカル
  ]

  # mDNSアドレスパターン（.localドメイン）
  MDNS_PATTERN = "\\.local$"

  # ICE候補パターン
  ICE_CANDIDATE_PATTERN = r"candidate:(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(\d+)\s+typ\s+(\S+)(?:\s+raddr\s+(\S+)\s+rport\s+(\d+))?(?:\s+generation\s+(\d+))?(?:\s+ufrag\s+(\S+))?(?:\s+network-id\s+(\d+))?(?:\s+network-cost\s+(\d+))?"

  DefaultTrustedStunServers = [
    "stun:stun.l.google.com:19302",
    "stun:stun1.l.google.com:19302",
    "stun:stun2.l.google.com:19302",
    "stun:stun3.l.google.com:19302",
    "stun:stun4.l.google.com:19302"
  ]

  DefaultTrustedTurnServers = [
    "turn:turn.webrtc.org"
  ]

#----------------------------------------
# ユーティリティ関数
#----------------------------------------

proc parseIceCandidate*(candidateStr: string): Option[IceCandidate] =
  ## ICE候補文字列をパース
  var matches: array[13, string]
  let pattern = re(ICE_CANDIDATE_PATTERN)
  
  if match(candidateStr, pattern, matches):
    var candidate = IceCandidate(
      foundation: matches[0],
      component: parseInt(matches[1]),
      transport: matches[2],
      priority: parseInt(matches[3]),
      ip: matches[4],
      port: parseInt(matches[5]),
      candidateType: 
        case matches[6]
        of "host": ctHost
        of "srflx": ctSrflx
        of "prflx": ctPrflx
        of "relay": ctRelay
        else: ctUnknown,
      raw: candidateStr
    )
    
    # オプションフィールド
    if matches[7].len > 0 and matches[8].len > 0:
      candidate.relatedAddress = matches[7]
      candidate.relatedPort = parseInt(matches[8])
    
    if matches[9].len > 0:
      candidate.generation = parseInt(matches[9])
    
    if matches[10].len > 0:
      candidate.ufrag = matches[10]
    
    if matches[11].len > 0:
      candidate.networkId = parseInt(matches[11])
    
    if matches[12].len > 0:
      candidate.networkCost = parseInt(matches[12])
    
    return some(candidate)
  
  return none(IceCandidate)

proc detectIpAddressType*(ip: string): IpAddressType =
  ## IPアドレスタイプを検出
  # mDNSチェック
  if ip.match(re(MDNS_PATTERN)):
    return ipMdns
  
  # IPv4プライベートアドレスチェック
  for pattern in PRIVATE_IPV4_PATTERNS:
    if ip.match(re(pattern)):
      if pattern == "^127\\.":
        return ipLoopback
      elif pattern == "^169\\.254\\.":
        return ipLink
      else:
        return ipPrivate
  
  # IPv6プライベートアドレスチェック
  for pattern in PRIVATE_IPV6_PATTERNS:
    if ip.match(re(pattern)):
      if pattern == "^::1$":
        return ipLoopback
      elif pattern == "^fe80:":
        return ipLink
      else:
        return ipPrivate
  
  # 上記に当てはまらない場合はパブリックIPと判断
  return ipPublic

proc createMdnsAddress*(): string =
  ## ランダムなmDNSアドレスを生成
  const CHARS = "abcdefghijklmnopqrstuvwxyz0123456789"
  var mdns = ""
  
  # ランダムな16文字の文字列を生成
  for i in 0..<16:
    mdns.add(CHARS[rand(CHARS.len-1)])
  
  # ハイフン区切りの形式にフォーマット
  result = mdns[0..7] & "-" & mdns[8..11] & "-" & mdns[12..15] & ".local"

proc generateReplacementCandidate*(original: IceCandidate): string =
  ## 代替ICE候補を生成
  var replacement = original
  
  # mDNSアドレスを生成して置き換え
  if replacement.candidateType == ctHost:
    let mdnsAddress = createMdnsAddress()
    replacement.ip = mdnsAddress
    replacement.isPrivate = false
  
  # IPアドレスの種類を判定
  let ipType = detectIpAddressType(original.ip)
  replacement.isPrivate = ipType in [ipPrivate, ipLoopback, ipLink]
  
  # 生成された候補から文字列を再構築
  var candidateStr = "candidate:" & replacement.foundation & " " & $replacement.component & " " &
                     replacement.transport & " " & $replacement.priority & " " &
                     replacement.ip & " " & $replacement.port & " typ " & 
                     (case replacement.candidateType
                      of ctHost: "host"
                      of ctSrflx: "srflx"
                      of ctPrflx: "prflx"
                      of ctRelay: "relay"
                      else: "unknown")
  
  # 関連アドレス情報があれば追加
  if replacement.relatedAddress.len > 0:
    candidateStr &= " raddr " & replacement.relatedAddress & " rport " & $replacement.relatedPort
  
  # その他のオプションフィールドを追加
  if replacement.generation >= 0:
    candidateStr &= " generation " & $replacement.generation
  
  if replacement.ufrag.len > 0:
    candidateStr &= " ufrag " & replacement.ufrag
  
  if replacement.networkId >= 0:
    candidateStr &= " network-id " & $replacement.networkId
  
  if replacement.networkCost >= 0:
    candidateStr &= " network-cost " & $replacement.networkCost
  
  return candidateStr

proc filterIceServers*(protector: WebRtcProtector, iceServers: seq[string], domain: string): seq[string] =
  ## ICEサーバーをフィルタリング
  result = @[]
  if not protector.enabled:
    return iceServers
  
  # ドメインが例外リストにある場合はフィルタリングしない
  if domain in protector.exceptionDomains:
    return iceServers
  
  # ポリシーに応じたフィルタリング
  case protector.iceServerPolicy
  of ispAllowAll:
    # すべてのサーバーを許可（ブロックリストは除く）
    for server in iceServers:
      if server notin protector.blockedIceServers:
        result.add(server)
  
  of ispTrustedOnly:
    # 信頼済みサーバーのみ許可
    for server in iceServers:
      if server in protector.trustedIceServers:
        result.add(server)
  
  of ispBlockAll:
    # すべてブロック（例外ドメインでない場合）
    discard
  
  # フィルタリング結果をログに記録
  protector.logger.debug("ICEサーバーフィルタリング: " & $iceServers.len & "個中" & $result.len & "個許可")
  
  return result

#----------------------------------------
# WebRTC保護の実装
#----------------------------------------

proc newWebRtcProtector*(): WebRtcProtector =
  ## 新しいWebRTC保護機能を作成
  new(result)
  result.enabled = true
  result.protectionLevel = wrpPublicOnly
  result.iceServerPolicy = ispAllowAll
  result.logger = newLogger("WebRtcProtector")
  result.trustedIceServers = toHashSet(DefaultTrustedStunServers & DefaultTrustedTurnServers)
  result.blockedIceServers = initHashSet[string]()
  result.exceptionDomains = initHashSet[string]()
  result.ipMaskingEnabled = true
  result.lastPolicyUpdate = getTime()
  result.connectionStats = initTable[string, ConnectionStats]()

proc setProtectionLevel*(protector: WebRtcProtector, level: WebRtcProtectionLevel) =
  ## 保護レベルを設定
  protector.protectionLevel = level
  
  case level
  of wrpDisabled:
    protector.enabled = false
    protector.ipMaskingEnabled = false
  
  of wrpPublicOnly:
    protector.enabled = true
    protector.ipMaskingEnabled = true
    # 公開IPだけを保護
  
  of wrpFullProtection:
    protector.enabled = true
    protector.ipMaskingEnabled = true
    # プライベートIPも保護
  
  of wrpDisableWebRtc:
    protector.enabled = true
    protector.ipMaskingEnabled = true
    # WebRTC自体を無効化する設定
  
  protector.lastPolicyUpdate = getTime()
  protector.logger.info("WebRTC保護レベルを変更: " & $level)

proc setIceServerPolicy*(protector: WebRtcProtector, policy: IceServerPolicy) =
  ## ICEサーバーポリシーを設定
  protector.iceServerPolicy = policy
  protector.lastPolicyUpdate = getTime()
  protector.logger.info("ICEサーバーポリシーを変更: " & $policy)

proc addTrustedIceServer*(protector: WebRtcProtector, server: string) =
  ## 信頼済みICEサーバーを追加
  protector.trustedIceServers.incl(server)
  protector.logger.info("信頼済みICEサーバーを追加: " & server)

proc removeTrustedIceServer*(protector: WebRtcProtector, server: string) =
  ## 信頼済みICEサーバーを削除
  protector.trustedIceServers.excl(server)
  protector.logger.info("信頼済みICEサーバーを削除: " & server)

proc addBlockedIceServer*(protector: WebRtcProtector, server: string) =
  ## ブロック対象のICEサーバーを追加
  protector.blockedIceServers.incl(server)
  protector.logger.info("ブロック対象ICEサーバーを追加: " & server)

proc removeBlockedIceServer*(protector: WebRtcProtector, server: string) =
  ## ブロック対象のICEサーバーを削除
  protector.blockedIceServers.excl(server)
  protector.logger.info("ブロック対象ICEサーバーを削除: " & server)

proc addExceptionDomain*(protector: WebRtcProtector, domain: string) =
  ## 例外ドメインを追加
  protector.exceptionDomains.incl(domain)
  protector.logger.info("WebRTC保護の例外ドメインを追加: " & domain)

proc removeExceptionDomain*(protector: WebRtcProtector, domain: string) =
  ## 例外ドメインを削除
  protector.exceptionDomains.excl(domain)
  protector.logger.info("WebRTC保護の例外ドメインを削除: " & domain)

proc isExceptionDomain*(protector: WebRtcProtector, domain: string): bool =
  ## 例外ドメインかどうかをチェック
  if domain in protector.exceptionDomains:
    return true
  
  # サブドメインのチェック
  for d in protector.exceptionDomains:
    if domain.endsWith("." & d):
      return true
  
  return false

proc processIceCandidate*(protector: WebRtcProtector, candidateStr: string, domain: string): string =
  ## ICE候補を処理して必要に応じて修正
  if not protector.enabled or protector.isExceptionDomain(domain):
    return candidateStr
  
  # WebRTC完全無効化の場合は空文字列を返す
  if protector.protectionLevel == wrpDisableWebRtc:
    protector.logger.debug("WebRTC無効化のため候補を遮断: " & candidateStr)
    return ""
  
  # ICE候補をパース
  let candidateOpt = parseIceCandidate(candidateStr)
  if candidateOpt.isNone:
    protector.logger.warn("不正なICE候補形式: " & candidateStr)
    return candidateStr
  
  let candidate = candidateOpt.get()
  
  # IPアドレスの種類を判定
  let ipType = detectIpAddressType(candidate.ip)
  
  # 保護レベルに応じた処理
  case protector.protectionLevel
  of wrpPublicOnly:
    # パブリックIPのみを保護
    if ipType == ipPublic:
      # パブリックIPは置き換える
      protector.logger.debug("パブリックIPを置換: " & candidate.ip)
      return generateReplacementCandidate(candidate)
    else:
      # プライベートIPはそのまま
      return candidateStr
  
  of wrpFullProtection:
    # パブリックIPもプライベートIPも保護
    if ipType in [ipPublic, ipPrivate]:
      protector.logger.debug("IPアドレスを置換: " & candidate.ip)
      return generateReplacementCandidate(candidate)
    else:
      return candidateStr
  
  of wrpDisableWebRtc:
    # すでにチェック済み
    return ""
  
  of wrpDisabled:
    # 保護無効
    return candidateStr

proc processRtcConfiguration*(protector: WebRtcProtector, config: JsonNode, domain: string): JsonNode =
  ## RTCConfiguration オブジェクトを処理
  if not protector.enabled or protector.isExceptionDomain(domain):
    return config
  
  # WebRTC完全無効化の場合
  if protector.protectionLevel == wrpDisableWebRtc:
    var disabledConfig = newJObject()
    disabledConfig["iceServers"] = newJArray()
    return disabledConfig
  
  var modifiedConfig = config
  
  # ICE serversの処理
  if config.hasKey("iceServers") and config["iceServers"].kind == JArray:
    var iceServers = newJArray()
    
    for server in config["iceServers"]:
      # 信頼済みサーバーかどうかを確認
      if server.hasKey("urls"):
        var urls: seq[string]
        
        if server["urls"].kind == JString:
          urls = @[server["urls"].getStr()]
        elif server["urls"].kind == JArray:
          for url in server["urls"]:
            urls.add(url.getStr())
        
        # フィルタリング
        let filteredUrls = filterIceServers(protector, urls, domain)
        
        if filteredUrls.len > 0:
          var newServer = server.copy()
          if filteredUrls.len == 1:
            newServer["urls"] = %filteredUrls[0]
          else:
            newServer["urls"] = %filteredUrls
          
          iceServers.add(newServer)
    
    modifiedConfig["iceServers"] = iceServers
  
  # iceCandidatePoolSizeの制限（リソース節約のため）
  if protector.protectionLevel in [wrpFullProtection, wrpPublicOnly] and config.hasKey("iceCandidatePoolSize"):
    let poolSize = min(config["iceCandidatePoolSize"].getInt(), 5)
    modifiedConfig["iceCandidatePoolSize"] = %poolSize
  
  return modifiedConfig

proc startTrackingConnection*(protector: WebRtcProtector, domain: string, iceServers: seq[string]) =
  ## 接続の追跡を開始
  var stats = ConnectionStats(
    domain: domain,
    startTime: getTime(),
    endTime: none(Time),
    iceServersUsed: iceServers,
    localCandidates: @[],
    remoteCandidates: @[],
    isP2P: false,
    isEncrypted: true
  )
  
  let connId = domain & "_" & $stats.startTime.toUnix()
  protector.connectionStats[connId] = stats
  protector.logger.debug("WebRTC接続の追跡開始: " & domain)

proc endTrackingConnection*(protector: WebRtcProtector, connId: string) =
  ## 接続の追跡を終了
  if connId in protector.connectionStats:
    protector.connectionStats[connId].endTime = some(getTime())
    protector.logger.debug("WebRTC接続の追跡終了: " & connId)

proc addCandidate*(protector: WebRtcProtector, connId: string, candidate: IceCandidate, isLocal: bool) =
  ## 候補を追跡に追加
  if connId in protector.connectionStats:
    if isLocal:
      protector.connectionStats[connId].localCandidates.add(candidate)
    else:
      protector.connectionStats[connId].remoteCandidates.add(candidate)

proc getReportData*(protector: WebRtcProtector): JsonNode =
  ## レポートデータを取得
  result = newJObject()
  
  var connections = newJArray()
  for id, stats in protector.connectionStats:
    var connObj = newJObject()
    connObj["domain"] = %stats.domain
    connObj["startTime"] = %($stats.startTime)
    
    if stats.endTime.isSome:
      connObj["endTime"] = %($stats.endTime.get())
      let duration = stats.endTime.get() - stats.startTime
      connObj["durationSeconds"] = %(duration.inSeconds.int)
    
    connObj["iceServersCount"] = %(stats.iceServersUsed.len)
    connObj["localCandidatesCount"] = %(stats.localCandidates.len)
    connObj["remoteCandidatesCount"] = %(stats.remoteCandidates.len)
    connObj["isP2P"] = %stats.isP2P
    connObj["isEncrypted"] = %stats.isEncrypted
    
    connections.add(connObj)
  
  result["connections"] = connections
  result["protectionLevel"] = %($protector.protectionLevel)
  result["iceServerPolicy"] = %($protector.iceServerPolicy)
  result["exceptionsCount"] = %(protector.exceptionDomains.len)
  result["enabled"] = %protector.enabled

proc toJson*(protector: WebRtcProtector): JsonNode =
  ## JSONシリアライズ
  result = newJObject()
  result["enabled"] = %protector.enabled
  result["protectionLevel"] = %($protector.protectionLevel)
  result["iceServerPolicy"] = %($protector.iceServerPolicy)
  result["ipMaskingEnabled"] = %protector.ipMaskingEnabled
  
  var trusted = newJArray()
  for server in protector.trustedIceServers:
    trusted.add(%server)
  result["trustedIceServers"] = trusted
  
  var blocked = newJArray()
  for server in protector.blockedIceServers:
    blocked.add(%server)
  result["blockedIceServers"] = blocked
  
  var exceptions = newJArray()
  for domain in protector.exceptionDomains:
    exceptions.add(%domain)
  result["exceptionDomains"] = exceptions
  
  result["lastPolicyUpdate"] = %($protector.lastPolicyUpdate)

#----------------------------------------
# 統合テスト
#----------------------------------------

when isMainModule:
  # テスト用コード
  echo "WebRTC保護機能のテスト"
  
  # 保護機能初期化
  let protector = newWebRtcProtector()
  echo "保護レベル: ", protector.protectionLevel
  
  # 各種ICE候補のテスト
  let candidates = [
    "candidate:1 1 udp 2122260223 192.168.1.100 56789 typ host generation 0",
    "candidate:1 1 udp 1686052607 203.0.113.5 56789 typ srflx raddr 10.0.0.1 rport 56789 generation 0",
    "candidate:1 1 udp 41819902 198.51.100.5 56789 typ relay raddr 203.0.113.5 rport 56789 generation 0",
    "candidate:1 1 udp 2122260223 abcd1234-5678-abcd.local 56789 typ host generation 0"
  ]
  
  let origins = ["https://example.com", "https://webrtc-test.com"]
  
  echo "デフォルト設定テスト:"
  for candidate in candidates:
    let candOpt = parseIceCandidate(candidate)
    if candOpt.isSome:
      let cand = candOpt.get()
      echo "  候補タイプ: ", cand.candidateType, ", IP: ", cand.ip, 
           ", IPタイプ: ", detectIpAddressType(cand.ip)
    
    let result = protector.processCandidate(candidate, origins[0])
    echo "  ", candidate
    echo "  アクション: ", result.action, if result.replacement.len > 0: ", 置換: " & result.replacement else: ""
    echo ""
  
  # 保護レベル変更テスト
  echo "\n保護レベル変更テスト:"
  for level in [wrpDisabled, wrpPublicOnly, wrpFullProtection, wrpDisableWebRtc]:
    protector.setProtectionLevel(level)
    echo "レベル: ", level
    
    let testCandidate = candidates[1]  # パブリックIP候補
    let result = protector.processCandidate(testCandidate, origins[0])
    echo "  ", testCandidate
    echo "  アクション: ", result.action, if result.replacement.len > 0: ", 置換: " & result.replacement else: ""
    echo ""
  
  # ICEサーバーサニタイズテスト
  echo "\nICEサーバーサニタイズテスト:"
  let servers = [
    "stun:stun.l.google.com:19302",
    "turn:turn.example.com:3478",
    "turn:turn.example.com:3478?transport=tcp",
    "turns:turn.example.com:5349"
  ]
  
  protector.setProtectionLevel(wrpFullProtection)
  for server in servers:
    let result = protector.sanitizeIceServer(server)
    echo "  ", server, " -> ", if result.allow: "許可" else: "ブロック", 
         if result.modified != server and result.allow: " (修正: " & result.modified & ")" else: ""
  
  # 統計情報テスト
  echo "\n統計情報テスト:"
  echo pretty(protector.getStats()) 