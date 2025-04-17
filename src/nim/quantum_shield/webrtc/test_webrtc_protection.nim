# test_webrtc_protection.nim
## WebRTC保護機能のテストコード
## 異なる設定で保護機能をテストします

import std/[times, json, strutils, tables, sets, options, unittest]
import protection

proc testBasicProtection() =
  echo "基本的なWebRTC保護機能テスト"
  echo "=========================="
  
  # 保護機能初期化
  let protector = newWebRtcProtector()
  echo "保護レベル: ", protector.level
  
  # ICE候補のパース機能テスト
  let candidateStr = "candidate:1 1 udp 2122260223 192.168.1.100 56789 typ host generation 0 ufrag XXXX network-id 1"
  let candOpt = parseIceCandidate(candidateStr)
  
  if candOpt.isSome:
    let cand = candOpt.get()
    echo "ICE候補パース結果:"
    echo "  タイプ: ", cand.candidateType
    echo "  IP: ", cand.ip
    echo "  ポート: ", cand.port
    echo "  優先度: ", cand.priority
    echo "  生成: ", cand.generation
  else:
    echo "ICE候補のパースに失敗"
  
  # IPアドレスタイプ検出テスト
  let ipAddresses = [
    "192.168.1.1",     # プライベート
    "10.0.0.1",        # プライベート
    "172.16.0.1",      # プライベート
    "127.0.0.1",       # ループバック
    "203.0.113.1",     # パブリック（例示用）
    "::1",             # IPv6ループバック 
    "fe80::1",         # IPv6リンクローカル
    "2001:db8::1",     # IPv6パブリック（例示用）
    "host123.local"    # mDNS
  ]
  
  echo "\nIPアドレスタイプ検出テスト:"
  for ip in ipAddresses:
    let ipType = detectIpAddressType(ip)
    echo "  ", ip, " -> ", ipType
  
  # mDNSアドレス生成テスト
  echo "\nmDNSアドレス生成テスト:"
  for i in 1..3:
    let mdnsAddress = createMdnsAddress()
    echo "  生成アドレス ", i, ": ", mdnsAddress

proc testProtectionLevels() =
  echo "\n保護レベル別テスト"
  echo "================="
  
  # テスト用候補
  let candidates = [
    "candidate:1 1 udp 2122260223 192.168.1.100 56789 typ host generation 0",              # ローカルIP
    "candidate:1 1 udp 1686052607 203.0.113.5 56789 typ srflx raddr 10.0.0.1 rport 56789 generation 0",  # パブリックIP
    "candidate:1 1 udp 41819902 198.51.100.5 56789 typ relay raddr 203.0.113.5 rport 56789 generation 0", # リレー候補
    "candidate:1 1 udp 2122260223 abcd1234-5678-abcd.local 56789 typ host generation 0"    # mDNS
  ]
  
  let origin = "https://webrtc-test.example.com"
  
  # 各保護レベルでテスト
  for level in [wrpNone, wrpDefault, wrpPublicOnly, wrpFullProtection, wrpDisableWebRtc]:
    let protector = newWebRtcProtector()
    protector.setProtectionLevel(level)
    
    echo "\n保護レベル: ", level
    
    # 各候補タイプでテスト
    for i, candidate in candidates:
      var candidateType = "不明"
      let candOpt = parseIceCandidate(candidate)
      if candOpt.isSome:
        case candOpt.get().candidateType:
        of ctHost: candidateType = "ホスト"
        of ctSrflx: candidateType = "STUN"
        of ctRelay: candidateType = "TURN"
        of ctPrflx: candidateType = "Peer Reflexive"
        else: candidateType = "不明"
      
      let result = protector.processCandidate(candidate, origin)
      echo "  候補 ", i+1, " (", candidateType, "): ", candidate
      echo "  処理結果: ", result.action
      if result.replacement.len > 0:
        echo "  置換後: ", result.replacement
      echo ""

proc testIceServerSanitization() =
  echo "\nICEサーバーサニタイズテスト"
  echo "======================="
  
  # テスト用ICEサーバー
  let servers = [
    "stun:stun.l.google.com:19302",
    "stun:stun.example.com:3478",
    "turn:turn.example.com:3478",
    "turn:turn.example.com:3478?transport=tcp",
    "turns:turn.example.com:5349",
    "turn:user:pass@turn.example.com:3478",
    "stun:malicious-stun.example.com:3478"
  ]
  
  # 各保護レベルでテスト
  for level in [wrpNone, wrpDefault, wrpPublicOnly, wrpFullProtection, wrpDisableWebRtc]:
    let protector = newWebRtcProtector()
    protector.setProtectionLevel(level)
    
    echo "\n保護レベル: ", level
    
    # ブロックリストとホワイトリストの設定
    if level != wrpNone:
      protector.blockedIceServers.incl("stun:malicious-stun.example.com:3478")
    
    for server in servers:
      let result = protector.sanitizeIceServer(server)
      echo "  ", server, " -> ", 
           if result.allow: "許可" else: "ブロック",
           if result.modified != server and result.allow: " (修正: " & result.modified & ")" else: ""
  
  # UDP無効モードの特別テスト
  let protector = newWebRtcProtector()
  protector.disableNonProxiedUdp = true
  
  echo "\n特別テスト: UDP無効モード"
  for server in servers:
    let result = protector.sanitizeIceServer(server)
    echo "  ", server, " -> ", 
         if result.allow: "許可" else: "ブロック",
         if result.modified != server and result.allow: " (修正: " & result.modified & ")" else: ""

proc testScriptGeneration() =
  echo "\nJavaScriptコード生成テスト"
  echo "======================"
  
  # 各保護レベルでテスト
  for level in [wrpNone, wrpDefault, wrpPublicOnly, wrpFullProtection, wrpDisableWebRtc]:
    let protector = newWebRtcProtector()
    protector.setProtectionLevel(level)
    
    echo "\n保護レベル: ", level
    
    let script = protector.generateWebRtcPreventionScript()
    if script.len > 0:
      echo "  スクリプト生成: ", script.len, " バイト"
      # スクリプトの先頭と末尾を表示
      if script.len > 100:
        echo "  先頭: ", script[0..min(99, script.len-1)]
        echo "  末尾: ", script[max(0, script.len-100)..script.len-1]
      else:
        echo "  スクリプト: ", script
    else:
      echo "  スクリプトは生成されませんでした（保護無効）"

proc testStatistics() =
  echo "\n統計情報テスト"
  echo "=============="
  
  let protector = newWebRtcProtector()
  protector.setProtectionLevel(wrpFullProtection)
  
  let candidates = [
    "candidate:1 1 udp 2122260223 192.168.1.100 56789 typ host generation 0",
    "candidate:2 1 udp 1686052607 203.0.113.5 56789 typ srflx raddr 10.0.0.1 rport 56789 generation 0",
    "candidate:3 1 udp 41819902 198.51.100.5 56789 typ relay raddr 203.0.113.5 rport 56789 generation 0",
    "candidate:4 1 udp 2122260223 abcd1234-5678-abcd.local 56789 typ host generation 0"
  ]
  
  let origins = [
    "https://webrtc-test.example.com",
    "https://video-call.example.org",
    "https://conference.example.net"
  ]
  
  # 複数のICE候補を処理して統計を蓄積
  echo "ICE候補を処理中..."
  for i in 0..<20:
    let candidate = candidates[i mod candidates.len]
    let origin = origins[i mod origins.len]
    discard protector.processCandidate(candidate, origin)
  
  # 統計情報を取得して表示
  let stats = protector.getStats()
  echo "統計情報:"
  echo pretty(stats)
  
  # 統計リセットのテスト
  echo "\n統計情報リセット..."
  protector.resetStats()
  
  let statsAfterReset = protector.getStats()
  echo "リセット後の統計情報:"
  echo pretty(statsAfterReset)

proc testExceptionDomains() =
  echo "\nドメイン例外テスト"
  echo "================="
  
  let protector = newWebRtcProtector()
  protector.setProtectionLevel(wrpFullProtection)
  
  let candidates = [
    "candidate:1 1 udp 2122260223 192.168.1.100 56789 typ host generation 0",
    "candidate:2 1 udp 1686052607 203.0.113.5 56789 typ srflx raddr 10.0.0.1 rport 56789 generation 0"
  ]
  
  let domains = [
    "https://trusted-webrtc.example.com",
    "https://subservice.trusted-webrtc.example.com",
    "https://untrusted-webrtc.example.org"
  ]
  
  # 例外ドメインを追加
  protector.addExceptionDomain("trusted-webrtc.example.com")
  
  echo "例外ドメイン: ", protector.domainExceptions
  
  # 各ドメインでテスト
  for domain in domains:
    echo "\nドメイン: ", domain
    for candidate in candidates:
      # 処理すべきか判断
      let shouldProcess = protector.shouldProcessCandidate(candidate, domain)
      echo "  候補: ", candidate.substr(0, min(30, candidate.len-1)), "..."
      echo "  処理するべきか: ", shouldProcess
      
      # 実際の処理結果
      let result = protector.processCandidate(candidate, domain)
      echo "  処理結果: ", result.action
      if result.replacement.len > 0:
        echo "  置換後: ", result.replacement.substr(0, min(30, result.replacement.len-1)), "..."

proc runUnitTests() =
  echo "\n単体テスト"
  echo "========="
  
  suite "WebRTC保護機能":
    test "ICE候補パース":
      let candidateStr = "candidate:1 1 udp 2122260223 192.168.1.100 56789 typ host generation 0"
      let candOpt = parseIceCandidate(candidateStr)
      check candOpt.isSome
      let cand = candOpt.get()
      check cand.candidateType == ctHost
      check cand.ip == "192.168.1.100"
      check cand.port == 56789
    
    test "IPアドレスタイプ検出":
      check detectIpAddressType("192.168.1.1") == ipPrivate
      check detectIpAddressType("127.0.0.1") == ipLoopback
      check detectIpAddressType("8.8.8.8") == ipPublic
      check detectIpAddressType("example.local") == ipMdns
    
    test "各保護レベルの動作":
      let candidate = "candidate:1 1 udp 2122260223 192.168.1.100 56789 typ host generation 0"
      let origin = "https://example.com"
      
      block:
        let protector = newWebRtcProtector()
        protector.setProtectionLevel(wrpNone)
        let result = protector.processCandidate(candidate, origin)
        check result.action == paAllow
      
      block:
        let protector = newWebRtcProtector()
        protector.setProtectionLevel(wrpDisableWebRtc)
        let result = protector.processCandidate(candidate, origin)
        check result.action == paBlock
      
      block:
        let protector = newWebRtcProtector()
        protector.setProtectionLevel(wrpFullProtection)
        let result = protector.processCandidate(candidate, origin)
        check result.action in {paBlock, paReplace}
    
    test "例外ドメイン":
      let candidate = "candidate:1 1 udp 2122260223 192.168.1.100 56789 typ host generation 0"
      let protector = newWebRtcProtector()
      protector.setProtectionLevel(wrpFullProtection)
      
      let untrustedDomain = "https://example.com"
      let trustedDomain = "https://trusted.example.org"
      let subTrustedDomain = "https://sub.trusted.example.org"
      
      protector.addExceptionDomain("trusted.example.org")
      
      # 未信頼ドメインはブロック/置換される
      check protector.shouldProcessCandidate(candidate, untrustedDomain) == true
      
      # 信頼済みドメインは処理されない
      check protector.shouldProcessCandidate(candidate, trustedDomain) == false
      
      # サブドメインも処理されない
      check protector.shouldProcessCandidate(candidate, subTrustedDomain) == false
    
    test "ICEサーバーサニタイズ":
      let protector = newWebRtcProtector()
      protector.setProtectionLevel(wrpPublicOnly)
      
      # 通常のサーバーは許可される
      let stun = "stun:stun.example.com:3478"
      let stunResult = protector.sanitizeIceServer(stun)
      check stunResult.allow == true
      check stunResult.modified == stun
      
      # ブロックリストに追加されたサーバーはブロックされる
      protector.blockedIceServers.incl("stun:blocked.example.com:3478")
      let blocked = "stun:blocked.example.com:3478"
      let blockedResult = protector.sanitizeIceServer(blocked)
      check blockedResult.allow == false
    
    test "スクリプト生成":
      let protector = newWebRtcProtector()
      
      # 保護無効
      protector.setProtectionLevel(wrpNone)
      check protector.generateWebRtcPreventionScript().len == 0
      
      # 保護有効
      protector.setProtectionLevel(wrpPublicOnly)
      check protector.generateWebRtcPreventionScript().len > 0
      
      # WebRTC無効
      protector.setProtectionLevel(wrpDisableWebRtc)
      check protector.generateWebRtcPreventionScript().len > 0
      check protector.generateWebRtcPreventionScript().contains("無効化")

when isMainModule:
  # 基本的な保護機能テスト
  testBasicProtection()
  
  # 各保護レベルでのテスト
  testProtectionLevels()
  
  # ICEサーバーサニタイズのテスト
  testIceServerSanitization()
  
  # JavaScriptコード生成テスト
  testScriptGeneration()
  
  # 統計情報テスト
  testStatistics()
  
  # 例外ドメインテスト
  testExceptionDomains()
  
  # 単体テスト
  runUnitTests() 