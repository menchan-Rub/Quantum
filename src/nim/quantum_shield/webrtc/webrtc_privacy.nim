# WebRTC Privacy Protection
# 
# WebRTCのプライバシー保護モジュール
# WebRTC接続を保護し、IPアドレス漏洩を防止します

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
  random,
  json,
  logging,
  asyncdispatch
]

import ../privacy/privacy_types

type
  WebRtcProtectionLevel* = enum
    ## WebRTC保護レベル
    wrpDisabled,      ## 保護無効
    wrpStandard,      ## 標準保護
    wrpStrict,        ## 厳格保護
    wrpMaximum        ## 最大保護

  IceCandidatePolicy* = enum
    ## ICE候補ポリシー
    icpAll,           ## すべての候補
    icpDefault,       ## デフォルト候補のみ
    icpMdnsOnly,      ## mDNS候補のみ
    icpRelay          ## リレー候補のみ

  WebRtcProtection* = object
    ## WebRTC保護設定
    enabled*: bool                    ## 有効フラグ
    level*: WebRtcProtectionLevel     ## 保護レベル
    iceCandidatePolicy*: IceCandidatePolicy ## ICE候補ポリシー
    enforceMdns*: bool                ## mDNS強制使用
    disableTcp*: bool                 ## TCP無効化
    disableUdp*: bool                 ## UDP無効化
    disableTurn*: bool                ## TURN無効化
    disableIpv6*: bool                ## IPv6無効化
    customIceServers*: seq[string]    ## カスタムICEサーバー
    exemptDomains*: HashSet[string]   ## 例外ドメイン
    loggingEnabled*: bool             ## ログ有効化
    logger: Logger                    ## ロガー

  WebRtcIceCandidate* = object
    ## WebRTC ICE候補
    sdpMid*: string                   ## SDP媒体識別子
    sdpMLineIndex*: int               ## SDP行インデックス
    candidate*: string                ## 候補文字列
    candidateType*: string            ## 候補タイプ
    address*: string                  ## アドレス
    port*: int                        ## ポート
    protocol*: string                 ## プロトコル
    relatedAddress*: string           ## 関連アドレス
    relatedPort*: int                 ## 関連ポート
    foundation*: string               ## 基盤識別子
    priority*: int                    ## 優先度
    isRemote*: bool                   ## リモートフラグ

  WebRtcDetection* = object
    ## WebRTC漏洩検出
    domain*: string                   ## 検出ドメイン
    timestamp*: Time                  ## 検出時刻
    candidateType*: string            ## 候補タイプ
    address*: string                  ## 漏洩アドレス
    blocked*: bool                    ## ブロックされたかどうか
    details*: string                  ## 詳細情報

#----------------------------------------
# 初期化と設定
#----------------------------------------

proc newWebRtcProtection*(): WebRtcProtection =
  ## 新しいWebRTC保護を作成
  result = WebRtcProtection(
    enabled: true,
    level: wrpStandard,
    iceCandidatePolicy: icpDefault,
    enforceMdns: true,
    disableTcp: false,
    disableUdp: false,
    disableTurn: false,
    disableIpv6: true,
    customIceServers: @[],
    exemptDomains: initHashSet[string](),
    loggingEnabled: true,
    logger: newLogger("WebRtcProtection")
  )

proc setProtectionLevel*(protection: var WebRtcProtection, level: WebRtcProtectionLevel) =
  ## 保護レベルを設定
  protection.level = level
  
  # レベルに応じた設定
  case level
  of wrpDisabled:
    protection.enabled = false
    protection.iceCandidatePolicy = icpAll
    protection.enforceMdns = false
    protection.disableTcp = false
    protection.disableUdp = false
    protection.disableTurn = false
    protection.disableIpv6 = false
    
  of wrpStandard:
    protection.enabled = true
    protection.iceCandidatePolicy = icpDefault
    protection.enforceMdns = true
    protection.disableTcp = false
    protection.disableUdp = false
    protection.disableTurn = false
    protection.disableIpv6 = true
    
  of wrpStrict:
    protection.enabled = true
    protection.iceCandidatePolicy = icpMdnsOnly
    protection.enforceMdns = true
    protection.disableTcp = false
    protection.disableUdp = false
    protection.disableTurn = false
    protection.disableIpv6 = true
    
  of wrpMaximum:
    protection.enabled = true
    protection.iceCandidatePolicy = icpRelay
    protection.enforceMdns = true
    protection.disableTcp = true
    protection.disableUdp = false
    protection.disableTurn = false
    protection.disableIpv6 = true
  
  protection.logger.info("WebRTC保護レベルを変更: " & $level)

proc exemptDomain*(protection: var WebRtcProtection, domain: string) =
  ## ドメインを例外に追加
  protection.exemptDomains.incl(domain)
  protection.logger.info("ドメインをWebRTC保護例外に追加: " & domain)

proc isExemptDomain*(protection: WebRtcProtection, domain: string): bool =
  ## ドメインが例外かどうかを確認
  result = domain in protection.exemptDomains

proc addCustomIceServer*(protection: var WebRtcProtection, server: string) =
  ## カスタムICEサーバーを追加
  protection.customIceServers.add(server)
  protection.logger.info("カスタムICEサーバーを追加: " & server)

proc clearCustomIceServers*(protection: var WebRtcProtection) =
  ## カスタムICEサーバーをクリア
  protection.customIceServers = @[]
  protection.logger.info("カスタムICEサーバーをクリア")

#----------------------------------------
# 保護機能
#----------------------------------------

proc parseIceCandidate*(candidateStr: string): WebRtcIceCandidate =
  ## ICE候補を解析
  result = WebRtcIceCandidate()
  
  # 候補文字列を解析
  result.candidate = candidateStr
  
  # 「candidate:」プレフィックスを確認
  var candidateContent = candidateStr
  if candidateContent.startsWith("candidate:"):
    candidateContent = candidateContent[10..^1]
  
  # スペースで分割
  let parts = candidateContent.split(' ')
  if parts.len < 8:
    return
  
  # 基本フィールドを解析
  result.foundation = parts[0]
  try:
    result.sdpMLineIndex = parseInt(parts[1])
  except:
    discard
  
  result.protocol = parts[2].toLowerAscii()
  
  try:
    result.priority = parseInt(parts[3])
  except:
    discard
  
  result.address = parts[4]
  
  try:
    result.port = parseInt(parts[5])
  except:
    discard
  
  # 候補タイプを確認
  for i in 6..<parts.len-1:
    if parts[i] == "typ":
      result.candidateType = parts[i+1]
      break
  
  # 関連アドレスを確認
  for i in 6..<parts.len-1:
    if parts[i] == "raddr":
      result.relatedAddress = parts[i+1]
    elif parts[i] == "rport" and i + 1 < parts.len:
      try:
        result.relatedPort = parseInt(parts[i+1])
      except:
        discard

proc sanitizeIceCandidate*(protection: WebRtcProtection, candidate: WebRtcIceCandidate): WebRtcIceCandidate =
  ## ICE候補を整形（プライバシー保護用）
  if not protection.enabled or candidate.candidateType == "relay":
    return candidate
  
  var sanitized = candidate
  
  # 保護ポリシーに基づいて処理
  case protection.iceCandidatePolicy
  of icpAll:
    # すべての候補をそのまま許可
    return candidate
    
  of icpDefault:
    # mDNSが強制されている場合、ローカルIPをmDNSに置き換え
    if protection.enforceMdns and candidate.candidateType == "host":
      if not candidate.address.endsWith(".local"):
        # IPアドレスをmDNS名に置き換え
        let mdnsName = generateMdnsName(candidate.address)
        sanitized.address = mdnsName
        sanitized.candidate = sanitized.candidate.replace(candidate.address, mdnsName)
        
        protection.logger.debug("IPアドレスをmDNSに置き換え: " & candidate.address & " → " & mdnsName)
    
    # IPv6が無効な場合、IPv6候補をドロップ
    if protection.disableIpv6 and ":" in candidate.address:
      return WebRtcIceCandidate() # 空の候補を返すことでドロップ
    
    # TCPが無効な場合、TCP候補をドロップ
    if protection.disableTcp and candidate.protocol == "tcp":
      return WebRtcIceCandidate() # 空の候補を返すことでドロップ
    
    # UDPが無効な場合、UDP候補をドロップ
    if protection.disableUdp and candidate.protocol == "udp":
      return WebRtcIceCandidate() # 空の候補を返すことでドロップ
    
  of icpMdnsOnly:
    # ホスト候補のみ許可し、すべてmDNSに変換
    if candidate.candidateType == "host":
      if not candidate.address.endsWith(".local"):
        # IPアドレスをmDNS名に置き換え
        let mdnsName = generateMdnsName(candidate.address)
        sanitized.address = mdnsName
        sanitized.candidate = sanitized.candidate.replace(candidate.address, mdnsName)
        
        protection.logger.debug("IPアドレスをmDNSに置き換え: " & candidate.address & " → " & mdnsName)
    else:
      # ホスト以外の候補はドロップ
      return WebRtcIceCandidate() # 空の候補を返すことでドロップ
    
  of icpRelay:
    # リレー候補のみ許可
    if candidate.candidateType != "relay":
      return WebRtcIceCandidate() # 空の候補を返すことでドロップ
    
    # リレーでも制約に合わない場合はドロップ
    if protection.disableIpv6 and ":" in candidate.address:
      return WebRtcIceCandidate() # 空の候補を返すことでドロップ
    
    if protection.disableTcp and candidate.protocol == "tcp":
      return WebRtcIceCandidate() # 空の候補を返すことでドロップ
    
    if protection.disableUdp and candidate.protocol == "udp":
      return WebRtcIceCandidate() # 空の候補を返すことでドロップ
  
  # TURNが無効な場合、TURN候補をドロップ
  if protection.disableTurn and "turn" in candidate.candidate.toLowerAscii():
    return WebRtcIceCandidate() # 空の候補を返すことでドロップ
  
  return sanitized

proc sanitizeSdp*(protection: WebRtcProtection, sdp: string): string =
  ## SDPを整形（プライバシー保護用）
  if not protection.enabled:
    return sdp
  
  var lines = sdp.splitLines()
  var sanitizedLines: seq[string] = @[]
  
  for line in lines:
    if line.startsWith("a=candidate:") or line.startsWith("candidate:"):
      # ICE候補行
      let candidate = parseIceCandidate(line)
      let sanitized = sanitizeIceCandidate(protection, candidate)
      
      # 空でなければ追加
      if sanitized.candidate.len > 0:
        sanitizedLines.add(sanitized.candidate)
    elif line.startsWith("c=IN IP"):
      # 接続アドレス行
      if protection.disableIpv6 and line.startsWith("c=IN IP6"):
        # IPv6アドレスを無効化
        continue
      sanitizedLines.add(line)
    else:
      # その他の行はそのまま
      sanitizedLines.add(line)
  
  return sanitizedLines.join("\r\n")

proc generateMdnsName*(ipAddress: string): string =
  ## IPアドレスからmDNS名を生成
  # ハッシュ関数を使用して一貫した名前を生成
  let hash = ipAddress.hash().abs()
  let mdnsName = $hash & ".local"
  return mdnsName

proc getWebRtcProtectionJavaScript*(protection: WebRtcProtection, domain: string): string =
  ## WebRTC保護用JavaScriptを生成
  if not protection.enabled or protection.isExemptDomain(domain):
    return ""
  
  var js = """
    // WebRTCプライバシー保護スクリプト
    (function() {
      // RTCPeerConnection APIをインターセプト
      const originalRTCPeerConnection = window.RTCPeerConnection;
      
      // プロキシRTCPeerConnection
      window.RTCPeerConnection = function(config) {
        // ICEサーバー設定を調整
        if (config) {
  """
  
  # ICEポリシーに基づく設定
  case protection.iceCandidatePolicy
  of icpAll:
    js &= """
          // すべての候補を許可
          config.iceTransportPolicy = 'all';
    """
    
  of icpDefault:
    js &= """
          // デフォルトの候補のみ
          // デフォルト設定のまま
    """
    
  of icpMdnsOnly:
    js &= """
          // mDNS候補のみ
          if (!config.iceServers) {
            config.iceServers = [{ urls: 'stun:stun.l.google.com:19302' }];
          }
    """
    
  of icpRelay:
    js &= """
          // リレー候補のみ
          config.iceTransportPolicy = 'relay';
    """
  
  # カスタムICEサーバーの設定
  if protection.customIceServers.len > 0:
    js &= """
          // カスタムICEサーバー設定
          config.iceServers = [
    """
    
    for i, server in protection.customIceServers:
      if i > 0:
        js &= ","
      js &= &"""{{ urls: '{server}' }}"""
    
    js &= """
          ];
    """
  
  js &= """
        }
        
        // 元のRTCPeerConnectionを作成
        const pc = new originalRTCPeerConnection(config);
        
        // createOfferとcreateAnswerをインターセプト
        const originalCreateOffer = pc.createOffer;
        const originalCreateAnswer = pc.createAnswer;
        const originalSetLocalDescription = pc.setLocalDescription;
        
        pc.createOffer = async function(options) {
          const offer = await originalCreateOffer.apply(this, arguments);
          
          // オファーSDPを保護
          if (offer && offer.sdp) {
            // mDNSを強制
  """
  
  if protection.enforceMdns:
    js &= """
            offer.sdp = offer.sdp.replace(
              /candidate:(\d+) \d+ (udp|tcp) \d+ ([0-9.]+) \d+ typ host/gi,
              function(match, foundation, protocol, ip) {
                // mDNS名はIPをハッシュ化して生成
                const hash = Array.from(ip).reduce((hash, char) => 
                  ((hash << 5) - hash) + char.charCodeAt(0), 0) & 0xFFFFFFFF;
                return `candidate:${foundation} 1 ${protocol} 2122260223 ${hash}.local 56789 typ host`;
              }
            );
    """
  
  # IPv6無効化
  if protection.disableIpv6:
    js &= """
            // IPv6候補を削除
            offer.sdp = offer.sdp.split('\\n').filter(line => {
              return !(line.includes('a=candidate:') && line.includes('IP6'));
            }).join('\\n');
    """
  
  # TCP無効化
  if protection.disableTcp:
    js &= """
            // TCP候補を削除
            offer.sdp = offer.sdp.split('\\n').filter(line => {
              return !(line.includes('a=candidate:') && line.includes(' tcp '));
            }).join('\\n');
    """
  
  # UDP無効化
  if protection.disableUdp:
    js &= """
            // UDP候補を削除
            offer.sdp = offer.sdp.split('\\n').filter(line => {
              return !(line.includes('a=candidate:') && line.includes(' udp '));
            }).join('\\n');
    """
  
  # TURN無効化
  if protection.disableTurn:
    js &= """
            // TURN候補を削除
            offer.sdp = offer.sdp.split('\\n').filter(line => {
              return !(line.includes('a=candidate:') && line.includes(' relay '));
            }).join('\\n');
    """
  
  js &= """
          }
          return offer;
        };
        
        pc.createAnswer = async function(options) {
          const answer = await originalCreateAnswer.apply(this, arguments);
          
          // アンサーSDPを保護
          if (answer && answer.sdp) {
            // mDNSを強制
  """
  
  if protection.enforceMdns:
    js &= """
            answer.sdp = answer.sdp.replace(
              /candidate:(\d+) \d+ (udp|tcp) \d+ ([0-9.]+) \d+ typ host/gi,
              function(match, foundation, protocol, ip) {
                // mDNS名はIPをハッシュ化して生成
                const hash = Array.from(ip).reduce((hash, char) => 
                  ((hash << 5) - hash) + char.charCodeAt(0), 0) & 0xFFFFFFFF;
                return `candidate:${foundation} 1 ${protocol} 2122260223 ${hash}.local 56789 typ host`;
              }
            );
    """
  
  # IPv6無効化
  if protection.disableIpv6:
    js &= """
            // IPv6候補を削除
            answer.sdp = answer.sdp.split('\\n').filter(line => {
              return !(line.includes('a=candidate:') && line.includes('IP6'));
            }).join('\\n');
    """
  
  # TCP無効化
  if protection.disableTcp:
    js &= """
            // TCP候補を削除
            answer.sdp = answer.sdp.split('\\n').filter(line => {
              return !(line.includes('a=candidate:') && line.includes(' tcp '));
            }).join('\\n');
    """
  
  # UDP無効化
  if protection.disableUdp:
    js &= """
            // UDP候補を削除
            answer.sdp = answer.sdp.split('\\n').filter(line => {
              return !(line.includes('a=candidate:') && line.includes(' udp '));
            }).join('\\n');
    """
  
  # TURN無効化
  if protection.disableTurn:
    js &= """
            // TURN候補を削除
            answer.sdp = answer.sdp.split('\\n').filter(line => {
              return !(line.includes('a=candidate:') && line.includes(' relay '));
            }).join('\\n');
    """
  
  js &= """
          }
          return answer;
        };
        
        // onicecandidate イベントをインターセプト
        const originalAddEventListener = pc.addEventListener;
        pc.addEventListener = function(type, listener, options) {
          if (type === 'icecandidate') {
            const wrappedListener = function(e) {
              if (e.candidate) {
                // ICE候補を保護
                const candidate = e.candidate;
                
                // ホスト候補でmDNSが強制されている場合、本来のIPアドレスを隠す
  """
  
  if protection.enforceMdns:
    js &= """
                if (candidate.candidate && 
                    candidate.candidate.indexOf('typ host') !== -1 && 
                    candidate.candidate.indexOf('.local') === -1) {
                  
                  // mDNS名に置き換え
                  const originalCandidate = candidate.candidate;
                  const ipMatch = originalCandidate.match(/([0-9.]+) \d+ typ host/);
                  
                  if (ipMatch && ipMatch[1]) {
                    const ip = ipMatch[1];
                    // IPをハッシュ化して一貫したmDNS名を生成
                    const hash = Array.from(ip).reduce((hash, char) => 
                      ((hash << 5) - hash) + char.charCodeAt(0), 0) & 0xFFFFFFFF;
                    const mdnsName = `${hash}.local`;
                    
                    // 候補を修正
                    candidate.candidate = originalCandidate.replace(
                      ip + ' \\d+ typ host',
                      mdnsName + ' 56789 typ host'
                    );
                  }
                }
    """
  
  # IPv6無効化
  if protection.disableIpv6:
    js &= """
                // IPv6候補をドロップ
                if (candidate.candidate && 
                    candidate.candidate.indexOf('IP6') !== -1) {
                  // 候補を無効化
                  e.candidate = null;
                  return listener.call(this, e);
                }
    """
  
  # TCP無効化
  if protection.disableTcp:
    js &= """
                // TCP候補をドロップ
                if (candidate.candidate && 
                    candidate.candidate.indexOf(' tcp ') !== -1) {
                  // 候補を無効化
                  e.candidate = null;
                  return listener.call(this, e);
                }
    """
  
  # UDP無効化
  if protection.disableUdp:
    js &= """
                // UDP候補をドロップ
                if (candidate.candidate && 
                    candidate.candidate.indexOf(' udp ') !== -1) {
                  // 候補を無効化
                  e.candidate = null;
                  return listener.call(this, e);
                }
    """
  
  # TURN無効化
  if protection.disableTurn:
    js &= """
                // TURN候補をドロップ
                if (candidate.candidate && 
                    candidate.candidate.indexOf(' relay ') !== -1) {
                  // 候補を無効化
                  e.candidate = null;
                  return listener.call(this, e);
                }
    """
  
  # ICEポリシーによるフィルタリング
  case protection.iceCandidatePolicy
  of icpAll:
    # すべての候補を許可
    discard
    
  of icpDefault:
    # デフォルト設定
    discard
    
  of icpMdnsOnly:
    js &= """
                // ホスト候補以外をドロップ
                if (candidate.candidate && 
                    candidate.candidate.indexOf('typ host') === -1) {
                  // 候補を無効化
                  e.candidate = null;
                  return listener.call(this, e);
                }
    """
    
  of icpRelay:
    js &= """
                // リレー候補以外をドロップ
                if (candidate.candidate && 
                    candidate.candidate.indexOf('typ relay') === -1) {
                  // 候補を無効化
                  e.candidate = null;
                  return listener.call(this, e);
                }
    """
  
  js &= """
              }
              
              // 修正された候補でリスナーを呼び出す
              return listener.call(this, e);
            };
            
            return originalAddEventListener.call(this, type, wrappedListener, options);
          }
          
          return originalAddEventListener.apply(this, arguments);
        };
        
        return pc;
      };
      
      // MediaDevices APIもインターセプト
      if (navigator.mediaDevices) {
        const originalGetUserMedia = navigator.mediaDevices.getUserMedia;
        navigator.mediaDevices.getUserMedia = function(constraints) {
          // ビデオとオーディオの権限要求をそのまま渡す
          return originalGetUserMedia.apply(this, arguments);
        };
        
        const originalEnumerateDevices = navigator.mediaDevices.enumerateDevices;
        navigator.mediaDevices.enumerateDevices = function() {
          return originalEnumerateDevices.apply(this, arguments)
            .then(devices => {
              // デバイス情報を抽象化して返す
              return devices.map(device => {
                return {
                  kind: device.kind,
                  deviceId: device.deviceId,
                  groupId: device.groupId,
                  label: device.label,
                  toJSON: function() {
                    return {
                      kind: this.kind,
                      deviceId: this.deviceId,
                      groupId: this.groupId,
                      label: this.label
                    };
                  }
                };
              });
            });
        };
      }
      
      console.debug('WebRTC Privacy Protection activated');
    })();
  """
  
  return js

proc toJson*(protection: WebRtcProtection): JsonNode =
  ## JSONシリアライズ
  result = newJObject()
  result["enabled"] = %protection.enabled
  result["level"] = %($protection.level)
  result["iceCandidatePolicy"] = %($protection.iceCandidatePolicy)
  result["enforceMdns"] = %protection.enforceMdns
  result["disableTcp"] = %protection.disableTcp
  result["disableUdp"] = %protection.disableUdp
  result["disableTurn"] = %protection.disableTurn
  result["disableIpv6"] = %protection.disableIpv6
  
  var servers = newJArray()
  for server in protection.customIceServers:
    servers.add(%server)
  result["customIceServers"] = servers
  
  var exemptDomains = newJArray()
  for domain in protection.exemptDomains:
    exemptDomains.add(%domain)
  result["exemptDomains"] = exemptDomains
  
  result["loggingEnabled"] = %protection.loggingEnabled 