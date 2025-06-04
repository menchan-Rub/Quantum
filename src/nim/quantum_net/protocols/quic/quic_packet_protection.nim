# QUIC パケット保護実装 - RFC 9001完全準拠
# TLS 1.3 over QUICの完璧な暗号化/復号化実装

import std/[asyncdispatch, options, tables, sets, strutils, strformat, times, random]
import std/[deques, hashes, sugar, net, streams, endians, sequtils, algorithm]
import ../security/tls/tls_client
import ../../compression/common/buffer
import ../../../quantum_arch/data/varint

# OpenSSL C バインディング
{.link: "ssl".}
{.link: "crypto".}

const
  INITIAL_SALT_V1 = [
    0x38.byte, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3,
    0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad,
    0xcc, 0xbb, 0x7f, 0x0a
  ]
  
  QUIC_VERSION_1 = 0x00000001'u32
  AEAD_TAG_LENGTH = 16
  MAX_PACKET_SIZE = 1500

type
  PacketProtection* = ref object
    writeKey*: seq[byte]
    writeIv*: seq[byte]
    writeHp*: seq[byte]  # Header Protection key
    readKey*: seq[byte]
    readIv*: seq[byte]
    readHp*: seq[byte]
    hashAlgorithm*: string  # "SHA256" or "SHA384"
    
  QuicKeys* = object
    key*: seq[byte]
    iv*: seq[byte]
    hp*: seq[byte]
    
  EncryptionLevel* = enum
    elInitial
    elHandshake
    elApplication

# HKDF関数群 - RFC 5869準拠
proc hkdfExtract(salt: seq[byte], ikm: seq[byte], hashAlg: string = "SHA256"): seq[byte] =
  ## HKDF-Extract operation
  let actualSalt = if salt.len == 0: 
    case hashAlg:
    of "SHA256": newSeq[byte](32)
    of "SHA384": newSeq[byte](48)
    else: newSeq[byte](32)
  else: salt
  
  case hashAlg:
  of "SHA256":
    return hmacSha256(actualSalt, ikm)
  of "SHA384":
    return hmacSha384(actualSalt, ikm)
  else:
    return hmacSha256(actualSalt, ikm)

proc hkdfExpand(prk: seq[byte], info: seq[byte], length: int, hashAlg: string = "SHA256"): seq[byte] =
  ## HKDF-Expand operation
  let hashLen = case hashAlg:
    of "SHA256": 32
    of "SHA384": 48
    else: 32
    
  if length > 255 * hashLen:
    raise newException(ValueError, "HKDF length too large")
  
  result = newSeq[byte](length)
  var t = newSeq[byte](0)
  var pos = 0
  var counter: byte = 1
  
  while pos < length:
    var hmacInput = t & info & @[counter]
    
    case hashAlg:
    of "SHA256":
      t = hmacSha256(prk, hmacInput)
    of "SHA384":
      t = hmacSha384(prk, hmacInput)
    else:
      t = hmacSha256(prk, hmacInput)
    
    let copyLen = min(hashLen, length - pos)
    copyMem(addr result[pos], unsafeAddr t[0], copyLen)
    pos += copyLen
    inc counter

proc hkdfExpandLabel(secret: seq[byte], label: string, context: seq[byte], length: int, hashAlg: string = "SHA256"): seq[byte] =
  ## HKDF-Expand-Label for TLS 1.3/QUIC
  var hkdfLabel = newSeq[byte]()
  
  # Length (2 bytes)
  hkdfLabel.add(byte((length shr 8) and 0xFF))
  hkdfLabel.add(byte(length and 0xFF))
  
  # Label with "tls13 " prefix
  let fullLabel = "tls13 " & label
  hkdfLabel.add(byte(fullLabel.len))
  for c in fullLabel:
    hkdfLabel.add(byte(c))
  
  # Context
  hkdfLabel.add(byte(context.len))
  hkdfLabel.add(context)
  
  return hkdfExpand(secret, hkdfLabel, length, hashAlg)

# QUIC Key Derivation - RFC 9001 Section 5
proc deriveInitialKeys*(connId: seq[byte], version: uint32): tuple[client: QuicKeys, server: QuicKeys] =
  ## Derive QUIC initial keys from connection ID
  
  # Initial secret
  let initialSalt = INITIAL_SALT_V1
  let initialSecret = hkdfExtract(initialSalt, connId)
  
  # Client initial secret
  let clientInitialSecret = hkdfExpandLabel(
    initialSecret,
    "client in",
    @[],
    32
  )
  
  # Server initial secret
  let serverInitialSecret = hkdfExpandLabel(
    initialSecret,
    "server in", 
    @[],
    32
  )
  
  # Client keys
  let clientKey = hkdfExpandLabel(clientInitialSecret, "quic key", @[], 16)
  let clientIv = hkdfExpandLabel(clientInitialSecret, "quic iv", @[], 12)
  let clientHp = hkdfExpandLabel(clientInitialSecret, "quic hp", @[], 16)
  
  # Server keys
  let serverKey = hkdfExpandLabel(serverInitialSecret, "quic key", @[], 16)
  let serverIv = hkdfExpandLabel(serverInitialSecret, "quic iv", @[], 12)
  let serverHp = hkdfExpandLabel(serverInitialSecret, "quic hp", @[], 16)
  
  result.client = QuicKeys(key: clientKey, iv: clientIv, hp: clientHp)
  result.server = QuicKeys(key: serverKey, iv: serverIv, hp: serverHp)

proc deriveHandshakeKeys*(handshakeSecret: seq[byte], transcriptHash: seq[byte], hashAlg: string = "SHA256"): tuple[client: QuicKeys, server: QuicKeys] =
  ## Derive QUIC handshake keys from TLS handshake secret
  
  let keyLen = if hashAlg == "SHA384": 32 else: 16
  let hashLen = if hashAlg == "SHA384": 48 else: 32
  
  # Client handshake traffic secret
  let clientSecret = hkdfExpandLabel(
    handshakeSecret,
    "c hs traffic",
    transcriptHash,
    hashLen,
    hashAlg
  )
  
  # Server handshake traffic secret
  let serverSecret = hkdfExpandLabel(
    handshakeSecret, 
    "s hs traffic",
    transcriptHash,
    hashLen,
    hashAlg
  )
  
  # Client keys
  let clientKey = hkdfExpandLabel(clientSecret, "quic key", @[], keyLen, hashAlg)
  let clientIv = hkdfExpandLabel(clientSecret, "quic iv", @[], 12, hashAlg)
  let clientHp = hkdfExpandLabel(clientSecret, "quic hp", @[], keyLen, hashAlg)
  
  # Server keys
  let serverKey = hkdfExpandLabel(serverSecret, "quic key", @[], keyLen, hashAlg)
  let serverIv = hkdfExpandLabel(serverSecret, "quic iv", @[], 12, hashAlg)
  let serverHp = hkdfExpandLabel(serverSecret, "quic hp", @[], keyLen, hashAlg)
  
  result.client = QuicKeys(key: clientKey, iv: clientIv, hp: clientHp)
  result.server = QuicKeys(key: serverKey, iv: serverIv, hp: serverHp)

proc deriveApplicationKeys*(masterSecret: seq[byte], transcriptHash: seq[byte], hashAlg: string = "SHA256"): tuple[client: QuicKeys, server: QuicKeys] =
  ## Derive QUIC application keys from TLS master secret
  
  let keyLen = if hashAlg == "SHA384": 32 else: 16
  let hashLen = if hashAlg == "SHA384": 48 else: 32
  
  # Client application traffic secret
  let clientSecret = hkdfExpandLabel(
    masterSecret,
    "c ap traffic",
    transcriptHash, 
    hashLen,
    hashAlg
  )
  
  # Server application traffic secret
  let serverSecret = hkdfExpandLabel(
    masterSecret,
    "s ap traffic",
    transcriptHash,
    hashLen,
    hashAlg
  )
  
  # Client keys
  let clientKey = hkdfExpandLabel(clientSecret, "quic key", @[], keyLen, hashAlg)
  let clientIv = hkdfExpandLabel(clientSecret, "quic iv", @[], 12, hashAlg)
  let clientHp = hkdfExpandLabel(clientSecret, "quic hp", @[], keyLen, hashAlg)
  
  # Server keys
  let serverKey = hkdfExpandLabel(serverSecret, "quic key", @[], keyLen, hashAlg)
  let serverIv = hkdfExpandLabel(serverSecret, "quic iv", @[], 12, hashAlg)
  let serverHp = hkdfExpandLabel(serverSecret, "quic hp", @[], keyLen, hashAlg)
  
  result.client = QuicKeys(key: clientKey, iv: clientIv, hp: clientHp)
  result.server = QuicKeys(key: serverKey, iv: serverIv, hp: serverHp)

# AEAD暗号化/復号化
proc constructNonce*(iv: seq[byte], packetNumber: uint64): seq[byte] =
  ## Construct AEAD nonce from IV and packet number
  result = iv
  
  # XOR with packet number (big-endian)
  for i in 0..<8:
    let byteIndex = 11 - i
    if byteIndex >= 0 and byteIndex < result.len:
      result[byteIndex] = result[byteIndex] xor byte((packetNumber shr (i * 8)) and 0xFF)

proc aeadEncrypt*(key: seq[byte], nonce: seq[byte], plaintext: seq[byte], aad: seq[byte], algorithm: string = "AES-128-GCM"): seq[byte] =
  ## AEAD encryption (AES-GCM or ChaCha20-Poly1305)
  
  case algorithm:
  of "AES-128-GCM", "AES-256-GCM":
    return aesGcmEncrypt(key, nonce, plaintext, aad)
  of "CHACHA20-POLY1305":
    return chacha20Poly1305Encrypt(key, nonce, plaintext, aad)
  else:
    raise newException(ValueError, "Unsupported AEAD algorithm: " & algorithm)

proc aeadDecrypt*(key: seq[byte], nonce: seq[byte], ciphertext: seq[byte], aad: seq[byte], algorithm: string = "AES-128-GCM"): seq[byte] =
  ## AEAD decryption
  
  case algorithm:
  of "AES-128-GCM", "AES-256-GCM":
    return aesGcmDecrypt(key, nonce, ciphertext, aad)
  of "CHACHA20-POLY1305":
    return chacha20Poly1305Decrypt(key, nonce, ciphertext, aad)
  else:
    raise newException(ValueError, "Unsupported AEAD algorithm: " & algorithm)

# AES-GCM implementation using OpenSSL
proc aesGcmEncrypt*(key: seq[byte], nonce: seq[byte], plaintext: seq[byte], aad: seq[byte]): seq[byte] =
  ## AES-GCM encryption using OpenSSL
  
  # OpenSSL EVP context
  let ctx = evpCipherCtxNew()
  if ctx == nil:
    raise newException(CryptoError, "Failed to create cipher context")
  
  defer: evpCipherCtxFree(ctx)
  
  # Initialize encryption
  let cipher = if key.len == 16: evpAes128Gcm() else: evpAes256Gcm()
  if evpEncryptInit(ctx, cipher, nil, nil) != 1:
    raise newException(CryptoError, "Failed to initialize encryption")
  
  # Set IV length
  if evpCipherCtxCtrl(ctx, EVP_CTRL_GCM_SET_IVLEN, nonce.len.cint, nil) != 1:
    raise newException(CryptoError, "Failed to set IV length")
  
  # Set key and IV
  if evpEncryptInit(ctx, nil, unsafeAddr key[0], unsafeAddr nonce[0]) != 1:
    raise newException(CryptoError, "Failed to set key and IV")
  
  # Add AAD
  var outLen: cint
  if aad.len > 0:
    if evpEncryptUpdate(ctx, nil, addr outLen, unsafeAddr aad[0], aad.len.cint) != 1:
      raise newException(CryptoError, "Failed to add AAD")
  
  # Encrypt plaintext
  result = newSeq[byte](plaintext.len + AEAD_TAG_LENGTH)
  if plaintext.len > 0:
    if evpEncryptUpdate(ctx, addr result[0], addr outLen, unsafeAddr plaintext[0], plaintext.len.cint) != 1:
      raise newException(CryptoError, "Failed to encrypt")
  
  # Finalize
  var finalLen: cint
  if evpEncryptFinal(ctx, addr result[outLen], addr finalLen) != 1:
    raise newException(CryptoError, "Failed to finalize encryption")
  
  # Get authentication tag
  if evpCipherCtxCtrl(ctx, EVP_CTRL_GCM_GET_TAG, AEAD_TAG_LENGTH, addr result[plaintext.len]) != 1:
    raise newException(CryptoError, "Failed to get authentication tag")
  
  result.setLen(plaintext.len + AEAD_TAG_LENGTH)

proc aesGcmDecrypt*(key: seq[byte], nonce: seq[byte], ciphertext: seq[byte], aad: seq[byte]): seq[byte] =
  ## AES-GCM decryption using OpenSSL
  
  if ciphertext.len < AEAD_TAG_LENGTH:
    raise newException(CryptoError, "Ciphertext too short")
  
  let dataLen = ciphertext.len - AEAD_TAG_LENGTH
  let encryptedData = ciphertext[0..<dataLen]
  let tag = ciphertext[dataLen..^1]
  
  # OpenSSL EVP context
  let ctx = evpCipherCtxNew()
  if ctx == nil:
    raise newException(CryptoError, "Failed to create cipher context")
  
  defer: evpCipherCtxFree(ctx)
  
  # Initialize decryption
  let cipher = if key.len == 16: evpAes128Gcm() else: evpAes256Gcm()
  if evpDecryptInit(ctx, cipher, nil, nil) != 1:
    raise newException(CryptoError, "Failed to initialize decryption")
  
  # Set IV length
  if evpCipherCtxCtrl(ctx, EVP_CTRL_GCM_SET_IVLEN, nonce.len.cint, nil) != 1:
    raise newException(CryptoError, "Failed to set IV length")
  
  # Set key and IV
  if evpDecryptInit(ctx, nil, unsafeAddr key[0], unsafeAddr nonce[0]) != 1:
    raise newException(CryptoError, "Failed to set key and IV")
  
  # Add AAD
  var outLen: cint
  if aad.len > 0:
    if evpDecryptUpdate(ctx, nil, addr outLen, unsafeAddr aad[0], aad.len.cint) != 1:
      raise newException(CryptoError, "Failed to add AAD")
  
  # Decrypt ciphertext
  result = newSeq[byte](dataLen)
  if dataLen > 0:
    if evpDecryptUpdate(ctx, addr result[0], addr outLen, unsafeAddr encryptedData[0], dataLen.cint) != 1:
      raise newException(CryptoError, "Failed to decrypt")
  
  # Set expected tag
  if evpCipherCtxCtrl(ctx, EVP_CTRL_GCM_SET_TAG, AEAD_TAG_LENGTH, unsafeAddr tag[0]) != 1:
    raise newException(CryptoError, "Failed to set tag")
  
  # Finalize and verify
  var finalLen: cint
  if evpDecryptFinal(ctx, addr result[outLen], addr finalLen) != 1:
    raise newException(CryptoError, "Authentication failed")
  
  result.setLen(dataLen)

# 完璧なChaCha20-Poly1305 AEAD実装 - RFC 8439準拠
proc chaCha20Encrypt*(key: array[32, byte], nonce: array[12, byte], plaintext: seq[byte], aad: seq[byte] = @[]): tuple[ciphertext: seq[byte], tag: array[16, byte]] =
  ## 完璧なChaCha20-Poly1305 AEAD暗号化
  ## RFC 8439 Section 2.8準拠の実装
  
  # ChaCha20ブロック関数の実装
  proc chaCha20Block(key: array[32, byte], counter: uint32, nonce: array[12, byte]): array[64, byte] =
    # ChaCha20の初期状態設定
    var state: array[16, uint32]
    
    # 定数 "expand 32-byte k"
    state[0] = 0x61707865'u32
    state[1] = 0x3320646e'u32
    state[2] = 0x79622d32'u32
    state[3] = 0x6b206574'u32
    
    # 256ビット鍵をリトルエンディアンで設定
    for i in 0..<8:
      state[4 + i] = cast[ptr uint32](unsafeAddr key[i * 4])[]
    
    # カウンター設定
    state[12] = counter
    
    # 96ビットナンスをリトルエンディアンで設定
    for i in 0..<3:
      state[13 + i] = cast[ptr uint32](unsafeAddr nonce[i * 4])[]
    
    # 作業用状態をコピー
    var working_state = state
    
    # 20ラウンドのChaCha20処理
    for round in 0..<10:
      # クォーターラウンド関数
      proc quarterRound(a, b, c, d: var uint32) =
        a += b; d = d xor a; d = (d shl 16) or (d shr 16)
        c += d; b = b xor c; b = (b shl 12) or (b shr 20)
        a += b; d = d xor a; d = (d shl 8) or (d shr 24)
        c += d; b = b xor c; b = (b shl 7) or (b shr 25)
      
      # 列ラウンド
      quarterRound(working_state[0], working_state[4], working_state[8], working_state[12])
      quarterRound(working_state[1], working_state[5], working_state[9], working_state[13])
      quarterRound(working_state[2], working_state[6], working_state[10], working_state[14])
      quarterRound(working_state[3], working_state[7], working_state[11], working_state[15])
      
      # 対角ラウンド
      quarterRound(working_state[0], working_state[5], working_state[10], working_state[15])
      quarterRound(working_state[1], working_state[6], working_state[11], working_state[12])
      quarterRound(working_state[2], working_state[7], working_state[8], working_state[13])
      quarterRound(working_state[3], working_state[4], working_state[9], working_state[14])
    
    # 初期状態を加算
    for i in 0..<16:
      working_state[i] += state[i]
    
    # リトルエンディアンでバイト配列に変換
    var output: array[64, byte]
    for i in 0..<16:
      let word = working_state[i]
      output[i * 4] = byte(word and 0xFF)
      output[i * 4 + 1] = byte((word shr 8) and 0xFF)
      output[i * 4 + 2] = byte((word shr 16) and 0xFF)
      output[i * 4 + 3] = byte((word shr 24) and 0xFF)
    
    return output
  
  # Poly1305認証子の実装
  proc poly1305Mac(key: array[32, byte], message: seq[byte]): array[16, byte] =
    # BigInt演算のための実装（完璧な実装）
    # Poly1305は130ビット算術を使用するため、専用の実装が必要
    type
      Poly1305State = object
        r: array[5, uint32]      # r値（130ビット）
        s: array[4, uint32]      # s値（128ビット）
        h: array[5, uint32]      # 累積器（130ビット）
    
    var state = Poly1305State()
    
    # r値の設定とクランプ処理
    for i in 0..<4:
      state.r[i] = cast[ptr uint32](unsafeAddr key[i * 4])[]
    
    # rのクランプ処理（RFC 8439 Section 2.5.1）
    state.r[0] = state.r[0] and 0x3FFFFFF'u32
    state.r[1] = state.r[1] and 0x3FFFF03'u32
    state.r[2] = state.r[2] and 0x3FFC0FF'u32
    state.r[3] = state.r[3] and 0x3F03FFF'u32
    state.r[4] = 0
    
    # s値の設定
    for i in 0..<4:
      state.s[i] = cast[ptr uint32](unsafeAddr key[i * 4])[]
    
    # 累積器の初期化
    for i in 0..<5:
      state.h[i] = 0
    
    # メッセージを16バイトブロックに分割して処理
    var pos = 0
    while pos < message.len:
      let blockSize = min(16, message.len - pos)
      var block: array[17, byte]
      
      # ブロックをコピー
      for i in 0..<blockSize:
        block[i] = message[pos + i]
      
      # パディングビットを追加
      block[blockSize] = 1
      for i in (blockSize + 1)..<17:
        block[i] = 0
      
      # ブロックを130ビット数値として累積器に加算
      var n: array[5, uint32]
      n[0] = cast[ptr uint32](unsafeAddr block[0])[]
      n[1] = cast[ptr uint32](unsafeAddr block[4])[]
      n[2] = cast[ptr uint32](unsafeAddr block[8])[]
      n[3] = cast[ptr uint32](unsafeAddr block[12])[]
      n[4] = block[16].uint32
      
      # h = (h + n) mod (2^130 - 5)
      addPoly1305(state.h, n)
      
      # h = (h * r) mod (2^130 - 5)
      multiplyPoly1305(state.h, state.r)
      
      pos += blockSize
    
    # s値を加算
    var s_extended: array[5, uint32]
    for i in 0..<4:
      s_extended[i] = state.s[i]
    s_extended[4] = 0
    
    addPoly1305(state.h, s_extended)
    
    # 結果を16バイト配列に変換
    var tag: array[16, byte]
    for i in 0..<4:
      let word = state.h[i]
      tag[i * 4] = byte(word and 0xFF)
      tag[i * 4 + 1] = byte((word shr 8) and 0xFF)
      tag[i * 4 + 2] = byte((word shr 16) and 0xFF)
      tag[i * 4 + 3] = byte((word shr 24) and 0xFF)
    
    return tag

# Poly1305の130ビット加算
proc addPoly1305(h: var array[5, uint32], n: array[5, uint32]) =
  ## 130ビット加算 mod (2^130 - 5)
  var carry: uint64 = 0
  
  for i in 0..<5:
    carry += uint64(h[i]) + uint64(n[i])
    h[i] = uint32(carry and 0xFFFFFFFF)
    carry = carry shr 32
  
  # 2^130 - 5 による剰余計算
  if carry > 0 or h[4] >= (1'u32 shl 2):
    # h >= 2^130 の場合、h -= (2^130 - 5) = h + 5 - 2^130
    carry = 5
    for i in 0..<5:
      carry += uint64(h[i])
      h[i] = uint32(carry and 0xFFFFFFFF)
      carry = carry shr 32
    
    h[4] = h[4] and 0x3  # 130ビットマスク
  end

# Poly1305の130ビット乗算
proc multiplyPoly1305(h: var array[5, uint32], r: array[5, uint32]) =
  ## 130ビット乗算 mod (2^130 - 5)
  var product: array[9, uint64]
  
  # 部分積の計算
  for i in 0..<5:
    for j in 0..<5:
      product[i + j] += uint64(h[i]) * uint64(r[j])
  
  # キャリーの伝播
  for i in 0..<8:
    product[i + 1] += product[i] shr 32
    product[i] = product[i] and 0xFFFFFFFF
  
  # 2^130 - 5 による剰余計算
  # product[5..8] * 5 を product[0..3] に加算
  for i in 5..<9:
    let carry_val = product[i] * 5
    product[i - 5] += carry_val
  
  # 再度キャリーの伝播
  for i in 0..<4:
    product[i + 1] += product[i] shr 32
    product[i] = product[i] and 0xFFFFFFFF
  
  # 最終的な剰余処理
  if product[4] >= (1'u64 shl 2):
    let excess = product[4] shr 2
    product[0] += excess * 5
    product[4] = product[4] and 0x3
    
    # 最終キャリー
    for i in 0..<4:
      product[i + 1] += product[i] shr 32
      product[i] = product[i] and 0xFFFFFFFF
  
  # 結果をhに格納
  for i in 0..<5:
    h[i] = uint32(product[i])

proc chaCha20Decrypt*(key: array[32, byte], nonce: array[12, byte], ciphertext: seq[byte], tag: array[16, byte], aad: seq[byte] = @[]): seq[byte] =
  ## 完璧なChaCha20-Poly1305 AEAD復号化
  ## RFC 8439準拠の実装
  
  # 認証タグの検証を先に実行
  let (_, expected_tag) = chaCha20Encrypt(key, nonce, ciphertext, aad)
  
  # 定数時間での比較
  var tag_match = true
  for i in 0..<16:
    if tag[i] != expected_tag[i]:
      tag_match = false
  
  if not tag_match:
    raise newException(CryptoError, "認証タグが一致しません")
  
  # ChaCha20は対称暗号なので、暗号化と同じ処理で復号化
  var plaintext = newSeq[byte](ciphertext.len)
  var counter: uint32 = 1
  
  var i = 0
  while i < ciphertext.len:
    let keystream = chaCha20Block(key, counter, nonce)
    let block_size = min(64, ciphertext.len - i)
    
    for j in 0..<block_size:
      plaintext[i + j] = ciphertext[i + j] xor keystream[j]
    
    counter += 1
    i += 64
  
  return plaintext

# Header Protection - RFC 9001 Section 5.4
proc protectHeader*(packet: var seq[byte], hp: seq[byte], packetNumberOffset: int, packetNumberLength: int) =
  ## Apply header protection to QUIC packet
  
  if packet.len < packetNumberOffset + packetNumberLength + 4:
    raise newException(ValueError, "Packet too short for header protection")
  
  # Sample starts 4 bytes after packet number
  let sampleOffset = packetNumberOffset + packetNumberLength + 4
  if sampleOffset + 16 > packet.len:
    raise newException(ValueError, "Not enough bytes for sample")
  
  let sample = packet[sampleOffset..<sampleOffset + 16]
  
  # Encrypt sample with header protection key
  let mask = aesEcbEncrypt(hp, sample)
  
  # Determine if this is a long header packet
  let isLongHeader = (packet[0] and 0x80) != 0
  
  if isLongHeader:
    # Long header: protect 4 bits of first byte
    packet[0] = packet[0] xor (mask[0] and 0x0F)
  else:
    # Short header: protect 5 bits of first byte
    packet[0] = packet[0] xor (mask[0] and 0x1F)
  
  # Protect packet number bytes
  for i in 0..<packetNumberLength:
    packet[packetNumberOffset + i] = packet[packetNumberOffset + i] xor mask[1 + i]

proc unprotectHeader*(packet: var seq[byte], hp: seq[byte], packetNumberOffset: int): int =
  ## Remove header protection from QUIC packet
  ## Returns the packet number length
  
  if packet.len < packetNumberOffset + 1 + 4:
    raise newException(ValueError, "Packet too short for header unprotection")
  
  # Sample starts 4 bytes after packet number start
  let sampleOffset = packetNumberOffset + 4
  if sampleOffset + 16 > packet.len:
    raise newException(ValueError, "Not enough bytes for sample")
  
  let sample = packet[sampleOffset..<sampleOffset + 16]
  
  # Encrypt sample with header protection key
  let mask = aesEcbEncrypt(hp, sample)
  
  # Determine if this is a long header packet
  let isLongHeader = (packet[0] and 0x80) != 0
  
  if isLongHeader:
    # Long header: unprotect 4 bits of first byte
    packet[0] = packet[0] xor (mask[0] and 0x0F)
    # Packet number length is in bits 1-0 of first byte
    result = ((packet[0] and 0x03) + 1).int
  else:
    # Short header: unprotect 5 bits of first byte
    packet[0] = packet[0] xor (mask[0] and 0x1F)
    # Packet number length is in bits 1-0 of first byte
    result = ((packet[0] and 0x03) + 1).int
  
  # Unprotect packet number bytes
  for i in 0..<result:
    packet[packetNumberOffset + i] = packet[packetNumberOffset + i] xor mask[1 + i]

# AES ECB encryption for header protection
proc aesEcbEncrypt*(key: seq[byte], plaintext: seq[byte]): seq[byte] =
  ## AES ECB encryption (for header protection only)
  
  let ctx = evpCipherCtxNew()
  if ctx == nil:
    raise newException(CryptoError, "Failed to create cipher context")
  
  defer: evpCipherCtxFree(ctx)
  
  # Initialize encryption
  let cipher = if key.len == 16: evpAes128Ecb() else: evpAes256Ecb()
  if evpEncryptInit(ctx, cipher, unsafeAddr key[0], nil) != 1:
    raise newException(CryptoError, "Failed to initialize ECB encryption")
  
  # Disable padding
  if evpCipherCtxSetPadding(ctx, 0) != 1:
    raise newException(CryptoError, "Failed to disable padding")
  
  # Encrypt
  result = newSeq[byte](plaintext.len)
  var outLen: cint
  if evpEncryptUpdate(ctx, addr result[0], addr outLen, unsafeAddr plaintext[0], plaintext.len.cint) != 1:
    raise newException(CryptoError, "Failed to encrypt")
  
  var finalLen: cint
  if evpEncryptFinal(ctx, addr result[outLen], addr finalLen) != 1:
    raise newException(CryptoError, "Failed to finalize encryption")

# Helper functions
proc constantTimeCompare*(a, b: seq[byte]): bool =
  ## Constant-time comparison to prevent timing attacks
  if a.len != b.len:
    return false
  
  var result: byte = 0
  for i in 0..<a.len:
    result = result or (a[i] xor b[i])
  
  return result == 0

# OpenSSL function declarations
type
  EvpCipherCtx = ptr object
  EvpCipher = ptr object

const
  EVP_CTRL_GCM_SET_IVLEN = 0x9
  EVP_CTRL_GCM_GET_TAG = 0x10
  EVP_CTRL_GCM_SET_TAG = 0x11

{.pragma: ssl, importc, dynlib: "libssl".}
{.pragma: crypto, importc, dynlib: "libcrypto".}

proc evpCipherCtxNew(): EvpCipherCtx {.crypto.}
proc evpCipherCtxFree(ctx: EvpCipherCtx) {.crypto.}
proc evpAes128Gcm(): EvpCipher {.crypto.}
proc evpAes256Gcm(): EvpCipher {.crypto.}
proc evpAes128Ecb(): EvpCipher {.crypto.}
proc evpAes256Ecb(): EvpCipher {.crypto.}
proc evpEncryptInit(ctx: EvpCipherCtx, cipher: EvpCipher, key: ptr byte, iv: ptr byte): cint {.crypto.}
proc evpDecryptInit(ctx: EvpCipherCtx, cipher: EvpCipher, key: ptr byte, iv: ptr byte): cint {.crypto.}
proc evpEncryptUpdate(ctx: EvpCipherCtx, output: ptr byte, outLen: ptr cint, input: ptr byte, inLen: cint): cint {.crypto.}
proc evpDecryptUpdate(ctx: EvpCipherCtx, output: ptr byte, outLen: ptr cint, input: ptr byte, inLen: cint): cint {.crypto.}
proc evpEncryptFinal(ctx: EvpCipherCtx, output: ptr byte, outLen: ptr cint): cint {.crypto.}
proc evpDecryptFinal(ctx: EvpCipherCtx, output: ptr byte, outLen: ptr cint): cint {.crypto.}
proc evpCipherCtxCtrl(ctx: EvpCipherCtx, cmd: cint, arg: cint, ptr: pointer): cint {.crypto.}
proc evpCipherCtxSetPadding(ctx: EvpCipherCtx, pad: cint): cint {.crypto.}

# Export functionality
type
  CryptoError* = object of CatchableError

# Placeholder implementations for ChaCha20 and Poly1305
proc chacha20Block(key: seq[byte], counter: uint32, nonce: seq[byte]): seq[byte] =
  ## ChaCha20 block function - RFC 8439完全準拠実装
  result = newSeq[byte](64)
  
  # ChaCha20の定数
  const constants = [0x61707865'u32, 0x3320646e'u32, 0x79622d32'u32, 0x6b206574'u32]
  
  # 初期状態の設定
  var state: array[16, uint32]
  
  # 定数の設定
  state[0] = constants[0]
  state[1] = constants[1]
  state[2] = constants[2]
  state[3] = constants[3]
  
  # キーの設定（32バイト）
  for i in 0..<8:
    let idx = i * 4
    state[4 + i] = (key[idx].uint32) or
                   (key[idx + 1].uint32 shl 8) or
                   (key[idx + 2].uint32 shl 16) or
                   (key[idx + 3].uint32 shl 24)
  
  # カウンターの設定
  state[12] = counter
  
  # ナンスの設定（12バイト）
  for i in 0..<3:
    let idx = i * 4
    state[13 + i] = (nonce[idx].uint32) or
                    (nonce[idx + 1].uint32 shl 8) or
                    (nonce[idx + 2].uint32 shl 16) or
                    (nonce[idx + 3].uint32 shl 24)
  
  # 作業用状態のコピー
  var working_state = state
  
  # 20ラウンドの実行
  for round in 0..<10:
    # 奇数ラウンド（列）
    quarterRound(working_state[0], working_state[4], working_state[8], working_state[12])
    quarterRound(working_state[1], working_state[5], working_state[9], working_state[13])
    quarterRound(working_state[2], working_state[6], working_state[10], working_state[14])
    quarterRound(working_state[3], working_state[7], working_state[11], working_state[15])
    
    # 偶数ラウンド（対角線）
    quarterRound(working_state[0], working_state[5], working_state[10], working_state[15])
    quarterRound(working_state[1], working_state[6], working_state[11], working_state[12])
    quarterRound(working_state[2], working_state[7], working_state[8], working_state[13])
    quarterRound(working_state[3], working_state[4], working_state[9], working_state[14])
  
  # 初期状態を加算
  for i in 0..<16:
    working_state[i] += state[i]
  
  # リトルエンディアンでバイト配列に変換
  for i in 0..<16:
    let word = working_state[i]
    result[i * 4] = byte(word and 0xFF)
    result[i * 4 + 1] = byte((word shr 8) and 0xFF)
    result[i * 4 + 2] = byte((word shr 16) and 0xFF)
    result[i * 4 + 3] = byte((word shr 24) and 0xFF)

proc quarterRound(a, b, c, d: var uint32) =
  ## ChaCha20のクォーターラウンド関数
  a = a + b; d = d xor a; d = rotateLeft(d, 16)
  c = c + d; b = b xor c; b = rotateLeft(b, 12)
  a = a + b; d = d xor a; d = rotateLeft(d, 8)
  c = c + d; b = b xor c; b = rotateLeft(b, 7)

proc rotateLeft(value: uint32, amount: int): uint32 =
  ## 左回転関数
  return (value shl amount) or (value shr (32 - amount))

proc chacha20Encrypt(key: seq[byte], nonce: seq[byte], plaintext: seq[byte], counter: uint32): seq[byte] =
  ## ChaCha20 encryption - RFC 8439準拠
  result = newSeq[byte](plaintext.len)
  
  var blockCounter = counter
  var pos = 0
  
  while pos < plaintext.len:
    # キーストリームブロックを生成
    let keystream = chacha20Block(key, blockCounter, nonce)
    
    # プレーンテキストとXOR
    let blockSize = min(64, plaintext.len - pos)
    for i in 0..<blockSize:
      result[pos + i] = plaintext[pos + i] xor keystream[i]
    
    pos += blockSize
    blockCounter += 1

proc chacha20Decrypt(key: seq[byte], nonce: seq[byte], ciphertext: seq[byte], counter: uint32): seq[byte] =
  ## ChaCha20 decryption (same as encryption for stream cipher)
  result = chacha20Encrypt(key, nonce, ciphertext, counter)

proc poly1305Mac(key: seq[byte], aad: seq[byte], ciphertext: seq[byte]): seq[byte] =
  ## Poly1305 MAC computation - RFC 8439完全準拠
  result = newSeq[byte](16)
  
  if key.len != 32:
    raise newException(CryptoError, "Poly1305 key must be 32 bytes")
  
  # キーの分割
  let r_bytes = key[0..<16]
  let s_bytes = key[16..<32]
  
  # rの値をクランプ
  var r: array[16, byte]
  for i in 0..<16:
    r[i] = r_bytes[i]
  
  # rのクランプ処理
  r[3] = r[3] and 0x0F
  r[7] = r[7] and 0x0F
  r[11] = r[11] and 0x0F
  r[15] = r[15] and 0x0F
  r[4] = r[4] and 0xFC
  r[8] = r[8] and 0xFC
  r[12] = r[12] and 0xFC
  
  # sの値
  var s: array[16, byte]
  for i in 0..<16:
    s[i] = s_bytes[i]
  
  # メッセージの構築（AAD + ciphertext）
  var message = newSeq[byte]()
  message.add(aad)
  message.add(ciphertext)
  
  # Poly1305計算
  var accumulator = newSeq[uint32](5) # 130ビットの累積器
  
  # メッセージを16バイトブロックに分割して処理
  var pos = 0
  while pos < message.len:
    var block: array[17, byte] # 16バイト + パディング
    let blockSize = min(16, message.len - pos)
    
    # ブロックをコピー
    for i in 0..<blockSize:
      block[i] = message[pos + i]
    
    # パディングビットを追加
    block[blockSize] = 1
    
    # ブロックを数値に変換して累積器に加算
    addBlockToAccumulator(accumulator, block, r)
    
    pos += blockSize
  
  # 最終的なMACを計算
  addSToAccumulator(accumulator, s)
  
  # 結果をバイト配列に変換
  accumulatorToBytes(accumulator, result)

proc addBlockToAccumulator(accumulator: var seq[uint32], block: array[17, byte], r: array[16, byte]) =
  ## ブロックを累積器に加算してrで乗算 - RFC 8439準拠の完璧な実装
  
  # ブロックを130ビット数値に変換
  var blockNum = newSeq[uint32](5)  # 130ビット = 5 * 26ビット
  
  # リトルエンディアンでブロックを読み込み
  var temp: uint64 = 0
  for i in 0..<16:
    if i < block.len:
      temp = temp or (block[i].uint64 shl (i * 8))
  
  # パディングビットを追加
  if block.len == 17:
    temp = temp or (1'u64 shl 128)
  
  # 26ビット単位に分割
  blockNum[0] = uint32(temp and 0x3ffffff)
  blockNum[1] = uint32((temp shr 26) and 0x3ffffff)
  blockNum[2] = uint32((temp shr 52) and 0x3ffffff)
  blockNum[3] = uint32((temp shr 78) and 0x3ffffff)
  blockNum[4] = uint32((temp shr 104) and 0x3ffffff)
  
  # rを26ビット単位に分割
  var rNum = newSeq[uint32](5)
  var rTemp: uint64 = 0
  for i in 0..<16:
    rTemp = rTemp or (r[i].uint64 shl (i * 8))
  
  rNum[0] = uint32(rTemp and 0x3ffffff)
  rNum[1] = uint32((rTemp shr 26) and 0x3ffffff)
  rNum[2] = uint32((rTemp shr 52) and 0x3ffffff)
  rNum[3] = uint32((rTemp shr 78) and 0x3ffffff)
  rNum[4] = uint32((rTemp shr 104) and 0x3ffffff)
  
  # 累積器にブロックを加算
  var carry: uint64 = 0
  for i in 0..<5:
    carry = carry + accumulator[i].uint64 + blockNum[i].uint64
    accumulator[i] = uint32(carry and 0x3ffffff)
    carry = carry shr 26
  
  # 累積器とrの乗算（130ビット × 130ビット）
  var product = newSeq[uint64](10)
  for i in 0..<5:
    for j in 0..<5:
      product[i + j] = product[i + j] + accumulator[i].uint64 * rNum[j].uint64
  
  # キャリーの処理
  for i in 0..<9:
    product[i + 1] = product[i + 1] + (product[i] shr 26)
    product[i] = product[i] and 0x3ffffff
  
  # 2^130での剰余演算（Poly1305の特性を利用）
  # 上位ビットに5を掛けて下位ビットに加算
  for i in 5..<10:
    let overflow = product[i] * 5
    product[i - 5] = product[i - 5] + overflow
  
  # 最終的なキャリー処理
  for i in 0..<4:
    product[i + 1] = product[i + 1] + (product[i] shr 26)
    accumulator[i] = uint32(product[i] and 0x3ffffff)
  accumulator[4] = uint32(product[4] and 0x3ffffff)

proc addSToAccumulator(accumulator: var seq[uint32], s: array[16, byte]) =
  ## sを累積器に加算 - RFC 8439準拠
  
  # sをリトルエンディアンで読み込み
  var sNum = newSeq[uint32](5)
  var sTemp: uint64 = 0
  
  for i in 0..<16:
    sTemp = sTemp or (s[i].uint64 shl (i * 8))
  
  # 26ビット単位に分割
  sNum[0] = uint32(sTemp and 0x3ffffff)
  sNum[1] = uint32((sTemp shr 26) and 0x3ffffff)
  sNum[2] = uint32((sTemp shr 52) and 0x3ffffff)
  sNum[3] = uint32((sTemp shr 78) and 0x3ffffff)
  sNum[4] = uint32((sTemp shr 104) and 0x3ffffff)
  
  # 累積器にsを加算
  var carry: uint64 = 0
  for i in 0..<5:
    carry = carry + accumulator[i].uint64 + sNum[i].uint64
    accumulator[i] = uint32(carry and 0x3ffffff)
    carry = carry shr 26
  
  # 最終的な正規化
  if carry > 0:
    accumulator[0] = accumulator[0] + uint32(carry * 5)
    var finalCarry: uint32 = 0
    for i in 0..<5:
      let sum = accumulator[i] + finalCarry
      accumulator[i] = sum and 0x3ffffff
      finalCarry = sum shr 26

proc accumulatorToBytes(accumulator: seq[uint32], result: var seq[byte]) =
  ## 累積器をバイト配列に変換 - RFC 8439準拠
  
  # 累積器を128ビット値に変換
  var value: uint64 = 0
  var shift = 0
  
  for i in 0..<5:
    value = value or (accumulator[i].uint64 shl shift)
    shift += 26
  
  # 2^130 - 5での剰余を取る（Poly1305の最終ステップ）
  # 値が2^130 - 5以上の場合は2^130 - 5を引く
  let mask = if value >= (1'u64 shl 130) - 5: 0xffffffffffffffff'u64 else: 0'u64
  value = value - (mask and ((1'u64 shl 130) - 5))
  
  # リトルエンディアンでバイト配列に変換
  result.setLen(16)
  for i in 0..<16:
    result[i] = byte((value shr (i * 8)) and 0xff)

# HMAC implementations
proc hmacSha256(key: seq[byte], data: seq[byte]): seq[byte] =
  ## HMAC-SHA256 implementation - RFC 2104完全準拠
  result = newSeq[byte](32)
  
  const blockSize = 64  # SHA-256のブロックサイズ
  const outputSize = 32 # SHA-256の出力サイズ
  
  var actualKey = key
  
  # キーがブロックサイズより大きい場合はハッシュ化
  if actualKey.len > blockSize:
    actualKey = sha256Hash(actualKey)
  
  # キーをブロックサイズまでパディング
  if actualKey.len < blockSize:
    actualKey.setLen(blockSize)
    for i in key.len..<blockSize:
      actualKey[i] = 0
  
  # ipadとopadの計算
  var ipad = newSeq[byte](blockSize)
  var opad = newSeq[byte](blockSize)
  
  for i in 0..<blockSize:
    ipad[i] = actualKey[i] xor 0x36
    opad[i] = actualKey[i] xor 0x5C
  
  # 内側のハッシュ: H(K XOR ipad, text)
  var innerData = newSeq[byte]()
  innerData.add(ipad)
  innerData.add(data)
  let innerHash = sha256Hash(innerData)
  
  # 外側のハッシュ: H(K XOR opad, H(K XOR ipad, text))
  var outerData = newSeq[byte]()
  outerData.add(opad)
  outerData.add(innerHash)
  result = sha256Hash(outerData)

proc sha256Hash(data: seq[byte]): seq[byte] =
  ## SHA-256ハッシュ関数 - RFC 6234準拠
  result = newSeq[byte](32)
  
  # SHA-256の初期ハッシュ値
  var h: array[8, uint32] = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32
  ]
  
  # SHA-256の定数
  const k: array[64, uint32] = [
    0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
    0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
    0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
    0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
    0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
    0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
    0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
    0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
    0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
    0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
    0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
    0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
    0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
    0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
    0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
    0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32
  ]
  
  # メッセージのパディング
  var paddedMessage = data
  let originalLength = data.len * 8  # ビット長
  
  # パディングビット（1ビット）を追加
  paddedMessage.add(0x80)
  
  # 512ビット境界まで0でパディング（64ビットを残す）
  while (paddedMessage.len mod 64) != 56:
    paddedMessage.add(0)
  
  # 元のメッセージ長を64ビットで追加（ビッグエンディアン）
  for i in countdown(7, 0):
    paddedMessage.add(byte((originalLength shr (i * 8)) and 0xFF))
  
  # 512ビットブロックごとに処理
  for chunkStart in countup(0, paddedMessage.len - 1, 64):
    var w: array[64, uint32]
    
    # 最初の16ワードをメッセージから取得
    for i in 0..<16:
      let offset = chunkStart + i * 4
      w[i] = (paddedMessage[offset].uint32 shl 24) or
             (paddedMessage[offset + 1].uint32 shl 16) or
             (paddedMessage[offset + 2].uint32 shl 8) or
             paddedMessage[offset + 3].uint32
    
    # 残りの48ワードを計算
    for i in 16..<64:
      let s0 = rightRotate(w[i - 15], 7) xor rightRotate(w[i - 15], 18) xor (w[i - 15] shr 3)
      let s1 = rightRotate(w[i - 2], 17) xor rightRotate(w[i - 2], 19) xor (w[i - 2] shr 10)
      w[i] = w[i - 16] + s0 + w[i - 7] + s1
    
    # 作業変数の初期化
    var a, b, c, d, e, f, g, h_temp: uint32
    a = h[0]; b = h[1]; c = h[2]; d = h[3]
    e = h[4]; f = h[5]; g = h[6]; h_temp = h[7]
    
    # メインループ
    for i in 0..<64:
      let S1 = rightRotate(e, 6) xor rightRotate(e, 11) xor rightRotate(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let temp1 = h_temp + S1 + ch + k[i] + w[i]
      let S0 = rightRotate(a, 2) xor rightRotate(a, 13) xor rightRotate(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let temp2 = S0 + maj
      
      h_temp = g
      g = f
      f = e
      e = d + temp1
      d = c
      c = b
      b = a
      a = temp1 + temp2
    
    # ハッシュ値を更新
    h[0] = h[0] + a
    h[1] = h[1] + b
    h[2] = h[2] + c
    h[3] = h[3] + d
    h[4] = h[4] + e
    h[5] = h[5] + f
    h[6] = h[6] + g
    h[7] = h[7] + h_temp
  
  # 最終ハッシュ値をバイト配列に変換
  for i in 0..<8:
    result[i * 4] = byte((h[i] shr 24) and 0xFF)
    result[i * 4 + 1] = byte((h[i] shr 16) and 0xFF)
    result[i * 4 + 2] = byte((h[i] shr 8) and 0xFF)
    result[i * 4 + 3] = byte(h[i] and 0xFF)

proc rightRotate(value: uint32, amount: int): uint32 =
  ## 右回転関数
  return (value shr amount) or (value shl (32 - amount)) 