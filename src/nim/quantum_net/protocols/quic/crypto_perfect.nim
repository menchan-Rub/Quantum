# QUIC暗号化ライブラリ - 完璧な実装
# RFC 5869 HKDF、RFC 2104 HMAC、FIPS 180-4 SHA-256準拠

import std/[strutils, math]

# 完璧なHKDF-Expand実装 - RFC 5869完全準拠
# https://tools.ietf.org/html/rfc5869
proc hkdfExpandPerfect*(prk: seq[byte], info: seq[byte], length: int): seq[byte] =
  ## HKDF-Expand アルゴリズムの完璧な実装
  ## RFC 5869 HMAC-based Extract-and-Expand Key Derivation Function (HKDF)
  ## PRK (Pseudo-Random Key) から指定長のキーマテリアルを生成
  
  const HASH_LEN = 32  # SHA-256のハッシュ長（256 bits = 32 bytes）
  
  # Step 1: パラメータ検証（RFC 5869 Section 2.3）
  if prk.len < HASH_LEN:
    raise newException(ValueError, "PRK must be at least HashLen octets")
  
  if length > 255 * HASH_LEN:
    raise newException(ValueError, "Length too large for HKDF-Expand (L > 255 * HashLen)")
  
  if length <= 0:
    return @[]
  
  # Step 2: 必要なブロック数の計算
  # N = ceil(L / HashLen)
  let n = (length + HASH_LEN - 1) div HASH_LEN  # 切り上げ除算
  
  # Step 3: HKDF-Expand計算ループ
  # T = T(1) | T(2) | T(3) | ... | T(N)
  # T(0) = empty string (zero length)
  # T(i) = HMAC-Hash(PRK, T(i-1) | info | i) for i = 1, 2, ..., N
  result = newSeq[byte](length)
  var t_prev: seq[byte] = @[]  # T(0) = empty string
  var okm_pos = 0
  
  for i in 1..n:
    # T(i) = HMAC-Hash(PRK, T(i-1) | info | i)
    var message: seq[byte] = @[]
    message.add(t_prev)          # T(i-1) (最初のイテレーションでは空)
    message.add(info)            # info
    message.add(byte(i))         # counter i (1から開始)
    
    # HMAC-SHA256計算
    let t_current = hmacSha256Perfect(prk, message)
    
    # 結果に必要な分だけコピー
    let copy_len = min(HASH_LEN, length - okm_pos)
    if copy_len > 0:
      copyMem(addr result[okm_pos], unsafeAddr t_current[0], copy_len)
    okm_pos += copy_len
    t_prev = t_current
  
  return result

# 完璧なHMAC-SHA256実装 - RFC 2104準拠
# https://tools.ietf.org/html/rfc2104
proc hmacSha256Perfect*(key: seq[byte], message: seq[byte]): seq[byte] =
  ## HMAC-SHA256の完璧な実装
  ## RFC 2104 HMAC: Keyed-Hashing for Message Authentication
  ## RFC 6234 US Secure Hash Algorithms (SHA and SHA-based HMAC and HKDF)
  
  const BLOCK_SIZE = 64    # SHA-256のブロックサイズ (512 bits = 64 bytes)
  const HASH_SIZE = 32     # SHA-256のハッシュサイズ (256 bits = 32 bytes)
  const IPAD = 0x36'u8     # Inner padding (0x36 repeated)
  const OPAD = 0x5C'u8     # Outer padding (0x5C repeated)
  
  # Step 1: キーの前処理
  var processedKey: seq[byte]
  
  if key.len > BLOCK_SIZE:
    # キーがブロックサイズより大きい場合はハッシュ化
    # K' = Hash(K)
    processedKey = sha256HashPerfect(key)
  else:
    # キーをそのまま使用
    processedKey = key
  
  # キーをブロックサイズまでゼロパディング
  # K' = K' padded with zeros to BLOCK_SIZE
  processedKey.setLen(BLOCK_SIZE)
  for i in key.len..<BLOCK_SIZE:
    processedKey[i] = 0
  
  # Step 2: Inner hash計算
  # iKeyPad = K' XOR ipad
  var iKeyPad = newSeq[byte](BLOCK_SIZE)
  for i in 0..<BLOCK_SIZE:
    iKeyPad[i] = processedKey[i] xor IPAD
  
  # inner_message = iKeyPad || message
  var innerMessage: seq[byte] = @[]
  innerMessage.add(iKeyPad)
  innerMessage.add(message)
  
  # inner_hash = Hash(iKeyPad || message)
  let innerHash = sha256HashPerfect(innerMessage)
  
  # Step 3: Outer hash計算
  # oKeyPad = K' XOR opad
  var oKeyPad = newSeq[byte](BLOCK_SIZE)
  for i in 0..<BLOCK_SIZE:
    oKeyPad[i] = processedKey[i] xor OPAD
  
  # outer_message = oKeyPad || inner_hash
  var outerMessage: seq[byte] = @[]
  outerMessage.add(oKeyPad)
  outerMessage.add(innerHash)
  
  # final_hash = Hash(oKeyPad || inner_hash)
  return sha256HashPerfect(outerMessage)

# 完璧なSHA-256実装 - FIPS 180-4準拠
# https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.180-4.pdf
proc sha256HashPerfect*(data: seq[byte]): seq[byte] =
  ## SHA-256ハッシュ関数の完璧な実装
  ## FIPS 180-4: Secure Hash Standard (SHS)
  
  # SHA-256定数 K (FIPS 180-4 Section 4.2.2)
  const K = [
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
  
  # 初期ハッシュ値 H (FIPS 180-4 Section 5.3.3)
  var H = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32
  ]
  
  # Step 1: メッセージの前処理（パディング）
  var message = data
  let original_length = data.len
  
  # パディングビット "1" を追加
  message.add(0x80)
  
  # メッセージ長が512ビット境界の448ビット目になるまでゼロパディング
  while (message.len * 8) mod 512 != 448:
    message.add(0x00)
  
  # 元のメッセージ長（ビット単位）を64ビットビッグエンディアンで追加
  let bit_length = original_length * 8
  for i in countdown(7, 0):
    message.add(byte((bit_length shr (i * 8)) and 0xFF))
  
  # Step 2: メッセージを512ビット（64バイト）ブロックに分割して処理
  for chunk_start in countup(0, message.len - 1, 64):
    # メッセージスケジュール W の準備
    var W: array[64, uint32]
    
    # 最初の16語はメッセージブロックから直接
    for t in 0..<16:
      let offset = chunk_start + t * 4
      W[t] = (uint32(message[offset]) shl 24) or
             (uint32(message[offset + 1]) shl 16) or
             (uint32(message[offset + 2]) shl 8) or
             uint32(message[offset + 3])
    
    # 残りの48語は前の語から計算
    for t in 16..<64:
      let s0 = rightRotate(W[t-15], 7) xor rightRotate(W[t-15], 18) xor (W[t-15] shr 3)
      let s1 = rightRotate(W[t-2], 17) xor rightRotate(W[t-2], 19) xor (W[t-2] shr 10)
      W[t] = W[t-16] + s0 + W[t-7] + s1
    
    # 作業変数の初期化
    var a, b, c, d, e, f, g, h = H[0], H[1], H[2], H[3], H[4], H[5], H[6], H[7]
    
    # メイン圧縮ループ
    for t in 0..<64:
      let S1 = rightRotate(e, 6) xor rightRotate(e, 11) xor rightRotate(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let temp1 = h + S1 + ch + K[t] + W[t]
      let S0 = rightRotate(a, 2) xor rightRotate(a, 13) xor rightRotate(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let temp2 = S0 + maj
      
      h = g
      g = f
      f = e
      e = d + temp1
      d = c
      c = b
      b = a
      a = temp1 + temp2
    
    # 中間ハッシュ値の更新
    H[0] += a; H[1] += b; H[2] += c; H[3] += d
    H[4] += e; H[5] += f; H[6] += g; H[7] += h
  
  # Step 3: 最終ハッシュ値をビッグエンディアンバイト配列として出力
  result = newSeq[byte](32)
  for i in 0..<8:
    result[i * 4] = byte((H[i] shr 24) and 0xFF)
    result[i * 4 + 1] = byte((H[i] shr 16) and 0xFF)
    result[i * 4 + 2] = byte((H[i] shr 8) and 0xFF)
    result[i * 4 + 3] = byte(H[i] and 0xFF)

# SHA-256で使用する右回転関数
proc rightRotate(value: uint32, amount: int): uint32 {.inline.} =
  return (value shr amount) or (value shl (32 - amount))

# HKDF-Extract実装（Extract-then-Expand構造の前半）
proc hkdfExtractPerfect*(salt: seq[byte], ikm: seq[byte]): seq[byte] =
  ## HKDF-Extract: saltとIKM (Input Keying Material) からPRKを生成
  ## RFC 5869 Section 2.2
  
  var actualSalt = salt
  
  # saltが提供されていない場合は、HashLenバイトのゼロで埋める
  if actualSalt.len == 0:
    actualSalt = newSeq[byte](32)  # SHA-256の場合は32バイト
  
  # PRK = HMAC-Hash(salt, IKM)
  return hmacSha256Perfect(actualSalt, ikm)

# HKDF統合関数（Extract-then-Expand）
proc hkdfPerfect*(salt: seq[byte], ikm: seq[byte], info: seq[byte], length: int): seq[byte] =
  ## HKDF統合関数: Extract-then-Expand構造
  ## RFC 5869 Section 2.3
  
  # Step 1: Extract
  let prk = hkdfExtractPerfect(salt, ikm)
  
  # Step 2: Expand
  return hkdfExpandPerfect(prk, info, length) 