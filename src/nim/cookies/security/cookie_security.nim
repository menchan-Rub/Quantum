# cookie_security.nim
## クッキーセキュリティ管理モジュール - 暗号化、署名、CSRF保護などを提供

import std/[
  base64, 
  random, 
  times, 
  options, 
  strutils, 
  sugar, 
  uri, 
  hashes, 
  sets, 
  tables, 
  sequtils,
  logging
]
import nimcrypto/[hmac, sha2, rijndael, bcmode, pbkdf2]
import ../cookie_types

const
  # セキュリティ関連の定数
  HMAC_KEY_SIZE = 32  # 256ビット
  AES_KEY_SIZE = 32   # 256ビット
  IV_SIZE = 16        # 128ビット
  SALT_SIZE = 16      # ソルトサイズ
  PBKDF2_ITERATIONS = 10000  # PBKDF2の反復回数
  CSRF_TOKEN_SIZE = 32  # CSRFトークンサイズ
  CSRF_TIMEOUT = 3600   # CSRFトークンのタイムアウト（秒）
  
  # クッキー暗号化バージョン
  COOKIE_ENCRYPTION_VERSION = 1

type 
  CookieSecurityManager* = ref object
    ## クッキーセキュリティを管理するオブジェクト
    encryptionKey: array[AES_KEY_SIZE, byte]  # 暗号化キー
    hmacKey: array[HMAC_KEY_SIZE, byte]       # HMAC署名キー
    csrfTokens: Table[string, tuple[token: string, expiry: Time]]  # CSRFトークン管理
    trustedOrigins: HashSet[string]  # 信頼済みオリジン
    logger: Logger                   # ロガー

  CookieEncryptionError* = enum
    ceNone,         ## エラーなし
    ceInvalidData,  ## 無効なデータ
    ceDecryptFailed, ## 復号化失敗
    ceHmacInvalid,   ## HMAC検証失敗
    ceVersionMismatch ## バージョン不一致

###################
# ユーティリティ関数
###################

proc randomBytes(size: int): seq[byte] =
  ## 指定サイズのランダムバイト列を生成
  result = newSeq[byte](size)
  for i in 0..<size:
    result[i] = byte(rand(255))

proc generateCsrfToken*(): string =
  ## CSRFトークンを生成
  let bytes = randomBytes(CSRF_TOKEN_SIZE)
  result = base64.encode(bytes)

###################
# セキュリティマネージャー
###################

proc newCookieSecurityManager*(masterKey: string = ""): CookieSecurityManager =
  ## 新しいクッキーセキュリティマネージャーを作成
  ## 指定がない場合はランダムキーを使用（アプリ再起動ごとに変わる）
  new(result)
  
  # キー導出
  let derivationKey = if masterKey.len > 0: masterKey else: $rand(high(int))
  let salt = randomBytes(SALT_SIZE)
  
  # PBKDF2を使用してキーを導出
  var ctx: PBKDF2State
  discard ctx.init(sha256, derivationKey, salt)
  
  # 暗号化キーと署名キーを導出
  var derivedKey: seq[byte] = newSeq[byte](AES_KEY_SIZE + HMAC_KEY_SIZE)
  discard ctx.derive(derivedKey, PBKDF2_ITERATIONS)
  
  # キー分割
  for i in 0..<AES_KEY_SIZE:
    result.encryptionKey[i] = derivedKey[i]
  
  for i in 0..<HMAC_KEY_SIZE:
    result.hmacKey[i] = derivedKey[i + AES_KEY_SIZE]
  
  # テーブル初期化
  result.csrfTokens = initTable[string, tuple[token: string, expiry: Time]]()
  result.trustedOrigins = initHashSet[string]()
  result.logger = newConsoleLogger()

###################
# 暗号化/復号化関数
###################

proc encryptValue*(manager: CookieSecurityManager, value: string): string =
  ## クッキー値を暗号化
  # IV生成
  let iv = randomBytes(IV_SIZE)
  
  # AES-256-CBC用のブロック暗号初期化
  var cipher: CBC[aes256]
  cipher.init(manager.encryptionKey, iv)
  
  # パディング（AESはブロックサイズが16バイト）
  let blockSize = 16
  let paddingSize = blockSize - (value.len mod blockSize)
  var paddedData = newSeq[byte](value.len + paddingSize)
  
  # 元データコピー
  for i in 0..<value.len:
    paddedData[i] = byte(value[i])
  
  # パディング追加 (PKCS#7)
  for i in value.len..<(value.len + paddingSize):
    paddedData[i] = byte(paddingSize)
  
  # 暗号化
  var encrypted = newSeq[byte](paddedData.len)
  cipher.encrypt(paddedData, encrypted)
  
  # HMAC計算
  var hmacCtx: HMAC[sha256]
  hmacCtx.init(manager.hmacKey)
  hmacCtx.update(iv)
  hmacCtx.update(encrypted)
  let hmacResult = hmacCtx.finish()
  
  # 形式: バージョン | IV | HMAC | 暗号文
  let formatted = @[byte(COOKIE_ENCRYPTION_VERSION)] & iv & hmacResult.data & encrypted
  
  # Base64エンコード
  result = base64.encode(formatted)

proc decryptValue*(manager: CookieSecurityManager, encryptedValue: string): tuple[value: string, error: CookieEncryptionError] =
  ## 暗号化されたクッキー値を復号
  try:
    # Base64デコード
    let decoded = base64.decode(encryptedValue)
    if decoded.len < 1 + IV_SIZE + 32: # バージョン + IV + HMAC最小サイズ
      return (value: "", error: ceInvalidData)
    
    # バージョン確認
    let version = int(decoded[0])
    if version != COOKIE_ENCRYPTION_VERSION:
      return (value: "", error: ceVersionMismatch)
    
    # 各部分を抽出
    let iv = decoded[1..<(1+IV_SIZE)]
    let hmac = decoded[(1+IV_SIZE)..<(1+IV_SIZE+32)]
    let encrypted = decoded[(1+IV_SIZE+32)..^1]
    
    # HMAC検証
    var hmacCtx: HMAC[sha256]
    hmacCtx.init(manager.hmacKey)
    hmacCtx.update(iv)
    hmacCtx.update(encrypted)
    let calculatedHmac = hmacCtx.finish()
    
    var hmacValid = true
    for i in 0..<32:
      if hmac[i] != calculatedHmac.data[i]:
        hmacValid = false
        break
    
    if not hmacValid:
      return (value: "", error: ceHmacInvalid)
    
    # 復号
    var cipher: CBC[aes256]
    var ivArray: array[IV_SIZE, byte]
    for i in 0..<IV_SIZE:
      ivArray[i] = iv[i]
    
    cipher.init(manager.encryptionKey, ivArray)
    
    var decrypted = newSeq[byte](encrypted.len)
    cipher.decrypt(encrypted, decrypted)
    
    # パディング除去 (PKCS#7)
    if decrypted.len > 0:
      let paddingSize = int(decrypted[^1])
      if paddingSize > 0 and paddingSize <= 16:
        # パディングバイトの検証
        var validPadding = true
        for i in 1..paddingSize:
          if decrypted[^i] != byte(paddingSize):
            validPadding = false
            break
        
        if validPadding:
          decrypted.setLen(decrypted.len - paddingSize)
      
    # バイト列を文字列に変換
    var resultStr = ""
    for b in decrypted:
      resultStr.add(char(b))
    
    return (value: resultStr, error: ceNone)
  except:
    return (value: "", error: ceDecryptFailed)

proc signCookie*(manager: CookieSecurityManager, cookie: Cookie): Cookie =
  ## クッキーに署名を追加
  result = cookie
  
  # 署名対象データ（name|domain|path|value）
  let dataToSign = cookie.name & "|" & cookie.domain & "|" & cookie.path & "|" & cookie.value
  
  # HMAC生成
  var hmacCtx: HMAC[sha256]
  hmacCtx.init(manager.hmacKey)
  hmacCtx.update(dataToSign)
  let signature = hmacCtx.finish()
  
  # 署名をBase64エンコード
  let encodedSignature = base64.encode(signature.data)
  
  # 値を「値.署名」形式に変更
  result.value = cookie.value & "." & encodedSignature

proc verifyCookie*(manager: CookieSecurityManager, cookie: Cookie): tuple[isValid: bool, originalValue: string] =
  ## クッキーの署名を検証
  let parts = cookie.value.split(".")
  if parts.len != 2:
    return (isValid: false, originalValue: cookie.value)
  
  let value = parts[0]
  let signature = parts[1]
  
  # 署名対象データを再構築
  let dataToSign = cookie.name & "|" & cookie.domain & "|" & cookie.path & "|" & value
  
  # HMAC生成
  var hmacCtx: HMAC[sha256]
  hmacCtx.init(manager.hmacKey)
  hmacCtx.update(dataToSign)
  let calculatedSignature = hmacCtx.finish()
  
  # 署名をBase64エンコード
  let encodedCalculatedSignature = base64.encode(calculatedSignature.data)
  
  # 署名を比較
  let isValid = signature == encodedCalculatedSignature
  return (isValid: isValid, originalValue: value)

##################
# セキュリティ強化
##################

proc generateCsrfTokenForOrigin*(manager: CookieSecurityManager, origin: string): string =
  ## 特定のオリジン用のCSRFトークンを生成
  let token = generateCsrfToken()
  let expiry = getTime() + initDuration(seconds = CSRF_TIMEOUT)
  manager.csrfTokens[origin] = (token: token, expiry: expiry)
  return token

proc validateCsrfToken*(manager: CookieSecurityManager, origin: string, token: string): bool =
  ## CSRFトークンの検証
  if not manager.csrfTokens.hasKey(origin):
    return false
  
  let storedData = manager.csrfTokens[origin]
  if getTime() > storedData.expiry:
    # 期限切れトークンを削除
    manager.csrfTokens.del(origin)
    return false
  
  return storedData.token == token

proc addTrustedOrigin*(manager: CookieSecurityManager, origin: string) =
  ## 信頼済みオリジンを追加
  manager.trustedOrigins.incl(origin)

proc isTrustedOrigin*(manager: CookieSecurityManager, origin: string): bool =
  ## オリジンが信頼済みかをチェック
  origin in manager.trustedOrigins

proc cleanExpiredCsrfTokens*(manager: CookieSecurityManager) =
  ## 期限切れのCSRFトークンをクリーンアップ
  let now = getTime()
  var expiredOrigins: seq[string] = @[]
  
  for origin, data in manager.csrfTokens:
    if now > data.expiry:
      expiredOrigins.add(origin)
  
  for origin in expiredOrigins:
    manager.csrfTokens.del(origin)

##################
# クッキーセキュリティチェック
##################

proc isSameSitePolicyAllowed*(cookie: Cookie, requestUrl: Uri, sourceUrl: Uri, requestMethod: string = "GET", isTopLevelNavigation: bool = true): bool =
  ## Same-Siteポリシーに基づいてクッキーが許可されるかを厳密に判定
  case cookie.sameSite
  of ssNone:
    return true
  of ssLax:
    if requestUrl.hostname == sourceUrl.hostname:
      return true
    # トップレベルGETナビゲーションのみ許可
    if isTopLevelNavigation and requestMethod.toUpperAscii() == "GET":
      return true
    return false
  of ssStrict:
    return requestUrl.hostname == sourceUrl.hostname

proc evaluateCookieRisk*(cookie: Cookie): int =
  ## クッキーのリスクスコアを評価（0-100、高いほどリスク大）
  var score = 0
  
  # セキュアフラグなし
  if not cookie.isSecure:
    score += 25
  
  # HttpOnlyフラグなし
  if not cookie.isHttpOnly:
    score += 20
  
  # SameSite制限なし
  if cookie.sameSite == ssNone:
    score += 15
  
  # パスが広すぎる
  if cookie.path == "/":
    score += 10
  
  # 長期間の有効期限
  if cookie.expirationTime.isSome:
    let expiry = cookie.expirationTime.get()
    let now = getTime()
    let days = (expiry - now).inDays
    
    if days > 365:  # 1年以上
      score += 15
    elif days > 30:  # 1ヶ月以上
      score += 5
  
  # 値のサイズが大きすぎる
  let valueSize = cookie.value.len
  if valueSize > 1024:  # 1KB超
    score += 10
  
  # スコア上限は100
  return min(score, 100)

proc sanitizeCookieValue*(value: string): string =
  ## クッキー値のサニタイズ処理
  # 制御文字と特殊文字を削除/エスケープ
  result = ""
  for c in value:
    let code = ord(c)
    # 制御文字を削除
    if code < 32 or code == 127:
      continue
    
    # クッキーデリミタをエスケープ
    if c in {';', ',', ' ', '=', '"'}:
      result.add('\\')
    
    result.add(c)

# 安全なクッキー生成
proc createSecureCookie*(
  name: string, 
  value: string, 
  domain: string, 
  path = "/",
  maxAge: Option[int] = none(int),
  isSecure = true,
  isHttpOnly = true,
  sameSite = ssLax
): Cookie =
  ## セキュリティを考慮したクッキーを生成
  
  let sanitizedValue = sanitizeCookieValue(value)
  var expirationTime: Option[Time] = none(Time)
  
  # 最大経過時間から有効期限を設定
  if maxAge.isSome:
    expirationTime = some(getTime() + initDuration(seconds = maxAge.get))
  
  result = newCookie(
    name = name,
    value = sanitizedValue,
    domain = domain,
    path = path,
    expirationTime = expirationTime,
    isSecure = isSecure,
    isHttpOnly = isHttpOnly,
    sameSite = sameSite,
    source = csServerSet
  )

proc enforceSecureAttributes*(cookie: Cookie, securityPolicy: CookieSecurePolicy): Cookie =
  ## セキュリティポリシーに基づいてクッキーの属性を強制
  result = cookie
  
  case securityPolicy
  of csPreferSecure:
    # セキュアな接続を推奨
    if not cookie.isSecure:
      result.isSecure = true
    
    # SameSiteがNoneの場合、Laxを推奨
    if cookie.sameSite == ssNone:
      result.sameSite = ssLax
  
  of csRequireSecure:
    # セキュア接続を必須に
    result.isSecure = true
    
    # HttpOnlyの強制
    result.isHttpOnly = true
    
    # SameSiteの強制（最低でもLax）
    if cookie.sameSite == ssNone:
      result.sameSite = ssLax
  
  of csBaseline:
    # 基本設定のみ適用、既存の設定を尊重
    discard 