# 証明書の透明性（Certificate Transparency）モジュール
#
# このモジュールはCertificate Transparency（CT）の検証機能を提供します。
# CTは公開証明書が不正に発行されることを防ぐための仕組みであり、
# 全ての証明書が公開されたログに記録されていることを確認します。

import std/[tables, sets, options, sequtils, strutils, strformat, times, uri, json, hashes, os, httpclient, base64, times, asyncdispatch]
import openssl
import ../../../logging
import ../../../utils/file_utils
import ../../../threading/thread_pool
import ../../../utils/crypto_utils
import ./certificate_store

# SCTのソース
type
  SctSource* = enum
    sctEmbedded = "embedded"        # 証明書に埋め込まれたSCT
    sctTlsExtension = "tls"         # TLS拡張として提供されたSCT
    sctOcspStapling = "ocsp"        # OCSPレスポンスに含まれるSCT

  CtLogOperator* = object
    name*: string                   # ログオペレーター名
    website*: string                # ウェブサイト
    email*: string                  # 連絡先メール

  CtLogStatus* = enum
    ctLogPending = "pending"        # 承認待ち
    ctLogQualified = "qualified"    # 承認済み
    ctLogDisqualified = "disqualified" # 失格
    ctLogReadOnly = "readonly"      # 読み取り専用

  CtLog* = object 
    id*: string                     # ログID
    key*: string                    # 公開鍵（Base64）
    url*: string                    # ログURL
    mmd*: int                       # 最大マージ遅延（秒）
    operator*: CtLogOperator        # オペレーター情報
    status*: CtLogStatus            # ログのステータス
    startTime*: Option[DateTime]    # 開始時間
    endTime*: Option[DateTime]      # 終了時間

  SignedCertificateTimestamp* = object
    logId*: string                  # ログID
    timestamp*: int64               # タイムスタンプ（ミリ秒）
    signature*: string              # 署名
    hashAlgorithm*: int             # ハッシュアルゴリズム
    signatureAlgorithm*: int        # 署名アルゴリズム
    version*: int                   # SCTバージョン
    extensions*: string             # 拡張データ
    source*: SctSource              # SCTのソース

  CtInfo* = object
    scts*: seq[SignedCertificateTimestamp] # SCTリスト
    hasEmbeddedSct*: bool                 # 埋め込みSCTがあるか
    hasOcspSct*: bool                     # OCSPレスポンスにSCTがあるか
    hasTlsExtensionSct*: bool             # TLS拡張にSCTがあるか
    compliantSctCount*: int               # 準拠SCT数

  CtVerificationResult* = enum
    ctVerificationSuccess = "success"           # 検証成功
    ctVerificationFailure = "failure"           # 検証失敗
    ctVerificationInsufficientScts = "insufficient" # SCT不足
    ctVerificationInvalidSignature = "invalid"  # 無効な署名
    ctVerificationUnknownLog = "unknown_log"    # 不明なログ
    ctVerificationExpiredLog = "expired_log"    # 期限切れログ

  CtVerificationRequirement* = enum
    ctRequirementNone = "none"                # 要件なし
    ctRequirementBestEffort = "best_effort"   # ベストエフォート
    ctRequirementEnforced = "enforced"        # 強制

  CtConfig* = ref object
    knownLogsPath*: string                    # 既知ログリストのパス
    minSctCount*: int                         # 最小SCT数
    enforceSctVerification*: bool             # SCT検証を強制するか
    verificationRequirement*: CtVerificationRequirement # 検証要件
    enforcedDomains*: HashSet[string]         # 強制ドメイン
    exemptedDomains*: HashSet[string]         # 免除ドメイン
    allowUnknownLogs*: bool                   # 不明なログを許可するか

  CtManager* = ref object
    config*: CtConfig                         # 設定
    knownLogs*: Table[string, CtLog]          # 既知のログ（IDをキーにする）
    qualifiedLogs*: HashSet[string]           # 承認されたログのID
    client*: HttpClient                       # HTTPクライアント

# デフォルト設定
const DefaultKnownLogsPath* = "data/security/ct_known_logs.json"
const DefaultMinSctCount* = 2
const DefaultEnforceSctVerification* = true
const DefaultVerificationRequirement* = ctRequirementBestEffort
const DefaultAllowUnknownLogs* = false

# 主要なCTログオペレーター
const
  GoogleCTOperator* = CtLogOperator(
    name: "Google",
    website: "https://www.google.com/",
    email: "google-ct-logs@googlegroups.com"
  )
  
  DigiCertCTOperator* = CtLogOperator(
    name: "DigiCert",
    website: "https://www.digicert.com/",
    email: "ctops@digicert.com"
  )
  
  CloudflareCTOperator* = CtLogOperator(
    name: "Cloudflare",
    website: "https://www.cloudflare.com/",
    email: "ct-logs@cloudflare.com"
  )

# 新しいCT設定を作成
proc newCtConfig*(
  knownLogsPath: string = DefaultKnownLogsPath,
  minSctCount: int = DefaultMinSctCount,
  enforceSctVerification: bool = DefaultEnforceSctVerification,
  verificationRequirement: CtVerificationRequirement = DefaultVerificationRequirement,
  enforcedDomains: HashSet[string] = initHashSet[string](),
  exemptedDomains: HashSet[string] = initHashSet[string](),
  allowUnknownLogs: bool = DefaultAllowUnknownLogs
): CtConfig =
  result = CtConfig(
    knownLogsPath: knownLogsPath,
    minSctCount: minSctCount,
    enforceSctVerification: enforceSctVerification,
    verificationRequirement: verificationRequirement,
    enforcedDomains: enforcedDomains,
    exemptedDomains: exemptedDomains,
    allowUnknownLogs: allowUnknownLogs
  )

# 新しいCTマネージャーを作成
proc newCtManager*(config: CtConfig = nil): CtManager =
  let actualConfig = if config.isNil: newCtConfig() else: config
  
  result = CtManager(
    config: actualConfig,
    knownLogs: initTable[string, CtLog](),
    qualifiedLogs: initHashSet[string](),
    client: newHttpClient()
  )

# CTマネージャーを初期化
proc init*(manager: CtManager) =
  # 既知のログを読み込む
  try:
    manager.loadKnownLogs()
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"CT 既知ログの読み込みに失敗しました: {msg}")

# ログを書式化
proc `$`*(log: CtLog): string =
  result = fmt"CtLog(id: {log.id}, operator: {log.operator.name}, status: {log.status}, url: {log.url})"

# 既知のログを読み込む
proc loadKnownLogs*(manager: CtManager) =
  if not fileExists(manager.config.knownLogsPath):
    log(lvlWarn, fmt"CT 既知ログファイルが見つかりません: {manager.config.knownLogsPath}")
    return
  
  try:
    let jsonContent = readFile(manager.config.knownLogsPath)
    let jsonNode = parseJson(jsonContent)
    
    if jsonNode.kind != JArray:
      log(lvlError, "無効なCT既知ログファイル形式: 配列が予期されました")
      return
    
    for item in jsonNode:
      if item.kind != JObject:
        continue
      
      # 必須フィールドのチェック
      if not (item.hasKey("id") and item.hasKey("key") and item.hasKey("url")):
        continue
      
      let id = item["id"].getStr()
      let key = item["key"].getStr()
      let url = item["url"].getStr()
      
      # オペレーター情報
      var operator = CtLogOperator()
      if item.hasKey("operator") and item["operator"].kind == JObject:
        let opNode = item["operator"]
        operator.name = if opNode.hasKey("name"): opNode["name"].getStr() else: "Unknown"
        operator.website = if opNode.hasKey("website"): opNode["website"].getStr() else: ""
        operator.email = if opNode.hasKey("email"): opNode["email"].getStr() else: ""
      else:
        operator.name = "Unknown"
      
      # ステータス
      var status = ctLogQualified
      if item.hasKey("status"):
        try:
          status = parseEnum[CtLogStatus](item["status"].getStr())
        except:
          # 無効なステータスの場合はデフォルト使用
          discard
      
      # MMD (Maximum Merge Delay)
      var mmd = 86400 # デフォルト: 1日
      if item.hasKey("mmd"):
        try:
          mmd = item["mmd"].getInt()
        except:
          # 無効なMMDの場合はデフォルト使用
          discard
      
      # 開始時間と終了時間
      var startTime: Option[DateTime]
      var endTime: Option[DateTime]
      
      if item.hasKey("start_time"):
        try:
          startTime = some(parse(item["start_time"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'"))
        except:
          # 無効な日付形式の場合はnone
          startTime = none(DateTime)
      
      if item.hasKey("end_time"):
        try:
          endTime = some(parse(item["end_time"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'"))
        except:
          # 無効な日付形式の場合はnone
          endTime = none(DateTime)
      
      # ログオブジェクトを作成
      let ctLog = CtLog(
        id: id,
        key: key,
        url: url,
        mmd: mmd,
        operator: operator,
        status: status,
        startTime: startTime,
        endTime: endTime
      )
      
      # ログをテーブルに追加
      manager.knownLogs[id] = ctLog
      
      # 承認されたログの場合はセットに追加
      if status == ctLogQualified:
        manager.qualifiedLogs.incl(id)
    
    log(lvlInfo, fmt"CT既知ログを読み込みました: {manager.knownLogs.len} ログ, うち {manager.qualifiedLogs.len} が承認済み")
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"CT既知ログの読み込みに失敗しました: {msg}")

# 期限切れログかどうかをチェック
proc isExpired*(log: CtLog): bool =
  if log.endTime.isNone:
    return false
  
  return now() > log.endTime.get()

# ログがアクティブかどうかをチェック
proc isActive*(log: CtLog): bool =
  # ステータスがqualifiedのみアクティブとみなす
  if log.status != ctLogQualified:
    return false
  
  # 開始時間があり、現在時刻が開始時間より前の場合はアクティブでない
  if log.startTime.isSome and now() < log.startTime.get():
    return false
  
  # 終了時間があり、現在時刻が終了時間より後の場合はアクティブでない
  if log.endTime.isSome and now() > log.endTime.get():
    return false
  
  return true

# 証明書からSCTを抽出する
proc extractSctFromCertificate*(cert: X509): seq[SignedCertificateTimestamp] =
  result = @[]
  
  if cert.isNil:
    log(lvlError, "証明書からSCTを抽出できません: 証明書がnilです")
    return result
  
  # 証明書透明性拡張のOID: 1.3.6.1.4.1.11129.2.4.2
  const SCT_LIST_OID = "1.3.6.1.4.1.11129.2.4.2"
  
  # 証明書からSCT拡張を検索
  let extIndex = X509_get_ext_by_OBJ(cert, OBJ_txt2obj(SCT_LIST_OID, 1), -1)
  if extIndex < 0:
    log(lvlDebug, "証明書にSCT拡張が見つかりませんでした")
    return result
  
  # 拡張を取得
  let ext = X509_get_ext(cert, extIndex)
  if ext.isNil:
    log(lvlError, "SCT拡張の取得に失敗しました")
    return result
  
  # 拡張データを取得
  let extData = X509_EXTENSION_get_data(ext)
  if extData.isNil:
    log(lvlError, "SCT拡張データの取得に失敗しました")
    return result
  
  # ASN.1データを取得
  let dataLen = ASN1_STRING_length(extData)
  let dataPtr = ASN1_STRING_get0_data(extData)
  if dataPtr.isNil or dataLen <= 0:
    log(lvlError, "SCT拡張データの内容が無効です")
    return result
  
  # バイナリデータをシーケンスに変換
  var rawData = newSeq[byte](dataLen)
  copyMem(addr rawData[0], dataPtr, dataLen)
  
  # SCTリストの解析
  try:
    # SCTリストのフォーマット:
    # struct {
    #   SerializedSCT sct_list<1..2^16-1>;
    # } SignedCertificateTimestampList;
    
    var pos = 0
    
    # ASN.1 OCTETSTRINGのタグとサイズをスキップ
    # RFC 5280に準拠したASN.1 DER形式の完全な解析を実装
    if pos < rawData.len:
      # タグの確認 (OCTETSTRING = 0x04)
      if rawData[pos] != 0x04:
        raise newException(ValueError, fmt"予期しないASN.1タグ: 0x{rawData[pos]:02x}, OCTETSTRING(0x04)を期待")
      pos.inc
      
      # 長さフィールドの解析
      var length = 0
      if pos >= rawData.len:
        raise newException(ValueError, "ASN.1データが切れています: 長さフィールドがありません")
        
      if (rawData[pos] and 0x80) != 0:
        # 長形式の長さエンコーディング
        let lenBytes = rawData[pos] and 0x7F
        if lenBytes == 0 or lenBytes > 4:  # 4バイト以上は扱わない（現実的な制限）
          raise newException(ValueError, fmt"サポートされていないASN.1長さエンコーディング: {lenBytes}バイト")
        pos.inc
        
        for i in 0..<lenBytes:
          if pos >= rawData.len:
            raise newException(ValueError, "ASN.1データが切れています: 長さバイトが不足")
          length = (length shl 8) or rawData[pos].int
          pos.inc
      else:
        # 短形式の長さエンコーディング
        length = rawData[pos].int
        pos.inc
      
      if pos + length > rawData.len:
        raise newException(ValueError, fmt"ASN.1データ長が不正です: 要求={length}, 残り={rawData.len - pos}")
    
    # SCTリストの全体長を取得
    if pos + 2 > rawData.len:
      raise newException(ValueError, "SCTリスト長を読み取れません: データが不足しています")
    
    let listLength = (rawData[pos].int shl 8) or rawData[pos+1].int
    pos += 2
    
    if pos + listLength > rawData.len:
      raise newException(ValueError, fmt"SCTリスト長が不正です: 要求={listLength}, 残り={rawData.len - pos}")
    
    # 個々のSCTを解析
    let endPos = pos + listLength
    while pos < endPos:
      # 各SCTの長さを取得
      if pos + 2 > rawData.len:
        raise newException(ValueError, "SCT長を読み取れません")
      
      let sctLength = (rawData[pos].int shl 8) or rawData[pos+1].int
      pos += 2
      
      if pos + sctLength > rawData.len:
        raise newException(ValueError, "SCT長が不正です")
      
      # SCTデータを解析
      let sctData = rawData[pos..<pos+sctLength]
      pos += sctLength
      
      # SCTバージョンを取得
      if sctData.len < 1:
        continue
      
      let version = sctData[0].int
      
      # バージョン1のSCTのみサポート
      if version != 0: # バージョン値は0から始まる (v1 = 0)
        log(lvlWarn, fmt"未サポートのSCTバージョン: {version+1}")
        continue
      
      # ログIDを取得 (32バイト)
      if sctData.len < 33: # 1(バージョン) + 32(ログID)
        continue
      
      var logId = ""
      for i in 1..32:
        logId.add(fmt"{sctData[i]:02x}")
      
      # タイムスタンプを取得 (8バイト)
      if sctData.len < 41: # 33 + 8(タイムスタンプ)
        continue
      
      var timestamp: int64 = 0
      for i in 33..<41:
        timestamp = (timestamp shl 8) or sctData[i].int64
      
      # 拡張フィールド長を取得
      if sctData.len < 43: # 41 + 2(拡張長)
        continue
      
      let extLen = (sctData[41].int shl 8) or sctData[42].int
      
      # 拡張フィールドをスキップ
      if sctData.len < 43 + extLen:
        continue
      
      let extensionsData = if extLen > 0: sctData[43..<43+extLen] else: @[]
      let extensionsHex = extensionsData.mapIt(fmt"{it:02x}").join("")
      
      # ハッシュアルゴリズムとシグネチャアルゴリズムを取得
      if sctData.len < 45 + extLen: # 43 + extLen + 2(アルゴリズム)
        continue
      
      let hashAlgo = sctData[43 + extLen].int
      let sigAlgo = sctData[44 + extLen].int
      
      # 署名長を取得
      if sctData.len < 47 + extLen: # 45 + extLen + 2(署名長)
        continue
      
      let sigLen = (sctData[45 + extLen].int shl 8) or sctData[46 + extLen].int
      
      # 署名データを取得
      if sctData.len < 47 + extLen + sigLen:
        continue
      
      var signature = ""
      for i in 0..<sigLen:
        signature.add(fmt"{sctData[47 + extLen + i]:02x}")
      
      # SCTオブジェクトを作成
      let sct = SignedCertificateTimestamp(
        version: version + 1, # 内部表現は0ベース、外部表現は1ベース
        logId: logId,
        timestamp: timestamp,
        extensions: extensionsHex,
        hashAlgorithm: hashAlgo,
        signatureAlgorithm: sigAlgo,
        signature: signature,
        source: sctEmbedded
      )
      
      result.add(sct)
    
    log(lvlInfo, fmt"証明書から{result.len}個のSCTを抽出しました")
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"SCTの解析中にエラーが発生しました: {msg}")
  
  return result

# TLS拡張からSCTを抽出する
proc extractSctFromTlsExtension*(extensionData: openArray[byte]): seq[SignedCertificateTimestamp] =
  result = @[]
  
  try:
    # TLS拡張データが空の場合は早期リターン
    if extensionData.len == 0:
      log(lvlWarn, "TLS拡張データが空です")
      return result
    
    # TLS拡張データの形式: 
    # - 2バイト: SCTリストの長さ
    # - SCTリスト
    if extensionData.len < 2:
      log(lvlError, "TLS拡張データが短すぎます")
      return result
    
    let sctListLen = (extensionData[0].int shl 8) or extensionData[1].int
    if extensionData.len < 2 + sctListLen:
      log(lvlError, fmt"TLS拡張データの長さが不正です: 期待={2 + sctListLen}, 実際={extensionData.len}")
      return result
    
    var offset = 2
    while offset < 2 + sctListLen:
      # 各SCTエントリの形式:
      # - 2バイト: SCTの長さ
      # - SCTデータ
      if offset + 2 > extensionData.len:
        log(lvlError, "SCTエントリの長さフィールドが不完全です")
        break
      
      let sctLen = (extensionData[offset].int shl 8) or extensionData[offset + 1].int
      offset += 2
      
      if offset + sctLen > extensionData.len:
        log(lvlError, fmt"SCTデータが不完全です: 期待={sctLen}, 残り={extensionData.len - offset}")
        break
      
      # SCTデータを解析
      let sctData = extensionData[offset..<offset + sctLen]
      
      # バージョンチェック
      if sctData.len < 1:
        offset += sctLen
        continue
      
      let version = sctData[0].int
      if version != 0:  # v1は内部的に0
        log(lvlWarn, fmt"未対応のSCTバージョン: {version + 1}")
        offset += sctLen
        continue
      
      # ログIDを取得
      if sctData.len < 33:  # 1(バージョン) + 32(ログID)
        offset += sctLen
        continue
      
      var logId = ""
      for i in 1..32:
        logId.add(fmt"{sctData[i]:02x}")
      
      # タイムスタンプを取得
      if sctData.len < 41:  # 33 + 8(タイムスタンプ)
        offset += sctLen
        continue
      
      var timestamp: uint64 = 0
      for i in 0..7:
        timestamp = (timestamp shl 8) or sctData[33 + i].uint64
      
      # 拡張フィールド長を取得
      if sctData.len < 43:  # 41 + 2(拡張長)
        offset += sctLen
        continue
      
      let extLen = (sctData[41].int shl 8) or sctData[42].int
      
      # 拡張フィールドをスキップ
      if sctData.len < 43 + extLen:
        offset += sctLen
        continue
      
      let extensionsData = if extLen > 0: sctData[43..<43+extLen] else: @[]
      let extensionsHex = extensionsData.mapIt(fmt"{it:02x}").join("")
      
      # ハッシュアルゴリズムとシグネチャアルゴリズムを取得
      if sctData.len < 45 + extLen:  # 43 + extLen + 2(アルゴリズム)
        offset += sctLen
        continue
      
      let hashAlgo = sctData[43 + extLen].int
      let sigAlgo = sctData[44 + extLen].int
      
      # 署名長を取得
      if sctData.len < 47 + extLen:  # 45 + extLen + 2(署名長)
        offset += sctLen
        continue
      
      let sigLen = (sctData[45 + extLen].int shl 8) or sctData[46 + extLen].int
      
      # 署名データを取得
      if sctData.len < 47 + extLen + sigLen:
        offset += sctLen
        continue
      
      var signature = ""
      for i in 0..<sigLen:
        signature.add(fmt"{sctData[47 + extLen + i]:02x}")
      
      # SCTオブジェクトを作成
      let sct = SignedCertificateTimestamp(
        version: version + 1,  # 内部表現は0ベース、外部表現は1ベース
        logId: logId,
        timestamp: timestamp,
        extensions: extensionsHex,
        hashAlgorithm: hashAlgo,
        signatureAlgorithm: sigAlgo,
        signature: signature,
        source: sctTlsExtension
      )
      
      result.add(sct)
      offset += sctLen
    
    log(lvlInfo, fmt"TLS拡張から{result.len}個のSCTを抽出しました")
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"TLS拡張からのSCT抽出中にエラーが発生しました: {msg}")
  
  return result

# OCSPレスポンスからSCTを抽出する
proc extractSctFromOcspResponse*(ocspData: openArray[byte]): seq[SignedCertificateTimestamp] =
  result = @[]
  
  try:
    # OCSPレスポンスが空の場合は早期リターン
    if ocspData.len == 0:
      log(lvlWarn, "OCSPレスポンスデータが空です")
      return result
    
    # OCSPレスポンスをASN.1としてパース
    var parser = newAsn1Parser(ocspData)
    if not parser.isValid():
      log(lvlError, "無効なOCSPレスポンス形式です")
      return result
    
    # OCSPレスポンスの構造:
    # OCSPResponse ::= SEQUENCE {
    #   responseStatus         OCSPResponseStatus,
    #   responseBytes          [0] EXPLICIT ResponseBytes OPTIONAL }
    if not parser.enterSequence():
      log(lvlError, "OCSPレスポンスのSEQUENCEが見つかりません")
      return result
    
    # responseStatusをチェック (ENUMERATED)
    if not parser.isEnumerated():
      log(lvlError, "OCSPレスポンスのstatusが見つかりません")
      return result
    
    let responseStatus = parser.readEnumerated()
    if responseStatus != 0:  # 0 = successful
      log(lvlWarn, fmt"OCSPレスポンスのステータスが成功ではありません: {responseStatus}")
      return result
    
    # responseBytesを探す ([0] EXPLICIT ResponseBytes)
    if not parser.enterConstructed(0):
      log(lvlError, "OCSPレスポンスのresponseBytesが見つかりません")
      return result
    
    # ResponseBytes ::= SEQUENCE {
    #   responseType   OBJECT IDENTIFIER,
    #   response       OCTET STRING }
    if not parser.enterSequence():
      log(lvlError, "ResponseBytesのSEQUENCEが見つかりません")
      return result
    
    # responseTypeをチェック (OID)
    if not parser.isOid():
      log(lvlError, "responseTypeが見つかりません")
      return result
    
    let responseType = parser.readOid()
    if responseType != "1.3.6.1.5.5.7.48.1.1":  # id-pkix-ocsp-basic
      log(lvlWarn, fmt"未対応のOCSPレスポンスタイプ: {responseType}")
      return result
    
    # responseを取得 (OCTET STRING)
    if not parser.isOctetString():
      log(lvlError, "responseデータが見つかりません")
      return result
    
    let basicResponse = parser.readOctetString()
    
    # BasicOCSPResponse内のSCT拡張を探す
    var basicParser = newAsn1Parser(basicResponse)
    if not basicParser.isValid():
      log(lvlError, "無効なBasicOCSPResponse形式です")
      return result
    
    # BasicOCSPResponse ::= SEQUENCE { ... }
    if not basicParser.enterSequence():
      log(lvlError, "BasicOCSPResponseのSEQUENCEが見つかりません")
      return result
    
    # tbsResponseData, signatureAlgorithm, signatureをスキップして拡張に進む
    if not basicParser.skipToSingleExtensions():
      log(lvlWarn, "OCSPレスポンスに拡張フィールドが見つかりません")
      return result
    
    # 拡張フィールドを探索
    while basicParser.hasMoreExtensions():
      let extOid = basicParser.readExtensionOid()
      let critical = basicParser.readExtensionCritical()
      let extValue = basicParser.readExtensionValue()
      
      # SCT拡張のOID: 1.3.6.1.4.1.11129.2.4.5
      if extOid == "1.3.6.1.4.1.11129.2.4.5":
        log(lvlInfo, "OCSPレスポンスでSCT拡張を発見しました")
        
        # SCT拡張の値をパース
        var sctParser = newAsn1Parser(extValue)
        if not sctParser.enterOctetString():
          log(lvlError, "SCT拡張の値が不正です")
          continue
        
        let sctListData = sctParser.readCurrentValue()
        
        # SCTリストの形式:
        # - 2バイト: SCTリストの長さ
        # - SCTリスト
        if sctListData.len < 2:
          log(lvlError, "SCTリストデータが短すぎます")
          continue
        
        let sctListLen = (sctListData[0].int shl 8) or sctListData[1].int
        if sctListData.len < 2 + sctListLen:
          log(lvlError, fmt"SCTリストの長さが不正です: 期待={2 + sctListLen}, 実際={sctListData.len}")
          continue
        
        var offset = 2
        while offset < 2 + sctListLen:
          # 各SCTエントリの形式:
          # - 2バイト: SCTの長さ
          # - SCTデータ
          if offset + 2 > sctListData.len:
            log(lvlError, "SCTエントリの長さフィールドが不完全です")
            break
          
          let sctLen = (sctListData[offset].int shl 8) or sctListData[offset + 1].int
          offset += 2
          
          if offset + sctLen > sctListData.len:
            log(lvlError, fmt"SCTデータが不完全です: 期待={sctLen}, 残り={sctListData.len - offset}")
            break
          
          # SCTデータを解析
          let sctData = sctListData[offset..<offset + sctLen]
          
          # バージョンチェック
          if sctData.len < 1:
            offset += sctLen
            continue
          
          let version = sctData[0].int
          if version != 0:  # v1は内部的に0
            log(lvlWarn, fmt"未対応のSCTバージョン: {version + 1}")
            offset += sctLen
            continue
          
          # ログIDを取得
          if sctData.len < 33:  # 1(バージョン) + 32(ログID)
            offset += sctLen
            continue
          
          var logId = ""
          for i in 1..32:
            logId.add(fmt"{sctData[i]:02x}")
          
          # タイムスタンプを取得
          if sctData.len < 41:  # 33 + 8(タイムスタンプ)
            offset += sctLen
            continue
          
          var timestamp: uint64 = 0
          for i in 0..7:
            timestamp = (timestamp shl 8) or sctData[33 + i].uint64
          
          # 拡張フィールド長を取得
          if sctData.len < 43:  # 41 + 2(拡張長)
            offset += sctLen
            continue
          
          let extLen = (sctData[41].int shl 8) or sctData[42].int
          
          # 拡張フィールドをスキップ
          if sctData.len < 43 + extLen:
            offset += sctLen
            continue
          
          let extensionsData = if extLen > 0: sctData[43..<43+extLen] else: @[]
          let extensionsHex = extensionsData.mapIt(fmt"{it:02x}").join("")
          
          # ハッシュアルゴリズムとシグネチャアルゴリズムを取得
          if sctData.len < 45 + extLen:  # 43 + extLen + 2(アルゴリズム)
            offset += sctLen
            continue
          
          let hashAlgo = sctData[43 + extLen].int
          let sigAlgo = sctData[44 + extLen].int
          
          # 署名長を取得
          if sctData.len < 47 + extLen:  # 45 + extLen + 2(署名長)
            offset += sctLen
            continue
          
          let sigLen = (sctData[45 + extLen].int shl 8) or sctData[46 + extLen].int
          
          # 署名データを取得
          if sctData.len < 47 + extLen + sigLen:
            offset += sctLen
            continue
          
          var signature = ""
          for i in 0..<sigLen:
            signature.add(fmt"{sctData[47 + extLen + i]:02x}")
          
          # SCTオブジェクトを作成
          let sct = SignedCertificateTimestamp(
            version: version + 1,  # 内部表現は0ベース、外部表現は1ベース
            logId: logId,
            timestamp: timestamp,
            extensions: extensionsHex,
            hashAlgorithm: hashAlgo,
            signatureAlgorithm: sigAlgo,
            signature: signature,
            source: sctOcspResponse
          )
          
          result.add(sct)
          offset += sctLen
    
    log(lvlInfo, fmt"OCSPレスポンスから{result.len}個のSCTを抽出しました")
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"OCSPレスポンスからのSCT抽出中にエラーが発生しました: {msg}")
  
  return result

# SCT署名を検証する
proc verifySctSignature*(manager: CtManager, sct: SignedCertificateTimestamp, cert: X509): bool =
  # SCTの署名を検証する処理
  try:
    # ログIDに対応するログが存在するか確認
    if sct.logId notin manager.knownLogs:
      log(lvlWarn, fmt"未知のログID: {sct.logId}")
      return manager.config.allowUnknownLogs
    
    # ログの状態を確認
    let ctLog = manager.knownLogs[sct.logId]
    if not ctLog.isActive():
      log(lvlWarn, fmt"非アクティブなログ: {ctLog.name}")
      return false
    
    # 署名アルゴリズムの確認
    if sct.hashAlgorithm != hashAlgorithmSHA256 or 
       (sct.signatureAlgorithm != signatureAlgorithmECDSA and 
        sct.signatureAlgorithm != signatureAlgorithmRSA):
      log(lvlError, fmt"未対応の署名アルゴリズム: hash={sct.hashAlgorithm}, sig={sct.signatureAlgorithm}")
      return false
    
    # 1. 証明書からプリサートデータを構築
    var preSignedData = newStringOfCap(1024)
    
    # SCTバージョン (v1 = 0)
    preSignedData.add(char(sct.version - 1))
    
    # 署名タイプ (0 = 証明書, 1 = プリサート)
    preSignedData.add(char(0))
    
    # タイムスタンプ (8バイト)
    let timestampBytes = sct.timestamp.toBigEndian64
    for i in 0..<8:
      preSignedData.add(char((timestampBytes shr (8 * (7 - i))) and 0xFF))
    
    # X.509エントリタイプ (0 = ASN.1Cert)
    preSignedData.add(char(0))
    
    # 証明書データ
    let certDer = cert.toDer()
    let certLen = certDer.len
    preSignedData.add(char((certLen shr 16) and 0xFF))
    preSignedData.add(char((certLen shr 8) and 0xFF))
    preSignedData.add(char(certLen and 0xFF))
    preSignedData.add(certDer)
    
    # 拡張データ
    let extBytes = parseHexStr(sct.extensions)
    let extLen = extBytes.len
    preSignedData.add(char((extLen shr 8) and 0xFF))
    preSignedData.add(char(extLen and 0xFF))
    if extLen > 0:
      preSignedData.add(extBytes)
    
    # 2. 署名対象データのハッシュを計算
    let dataToVerify = sha256.digest(preSignedData)
    
    # 3. ログの公開鍵で署名を検証
    let signatureBytes = parseHexStr(sct.signature)
    
    case sct.signatureAlgorithm:
      of signatureAlgorithmECDSA:
        # ECDSA署名検証
        let ecKey = ctLog.publicKey.getEcKey()
        if ecKey == nil:
          log(lvlError, "ECDSAキーの取得に失敗しました")
          return false
        
        # DER形式のECDSA署名をr, sコンポーネントに分解
        var r, s: BIGNUM
        if not parseEcdsaSignature(signatureBytes, r, s):
          log(lvlError, "ECDSA署名の解析に失敗しました")
          return false
        
        # ECDSA_do_verify関数で検証
        let verifyResult = ECDSA_do_verify(
          cast[ptr cuchar](dataToVerify.cstring),
          dataToVerify.len.cint,
          ECDSA_SIG_new_from_rs(r, s),
          ecKey
        )
        
        BN_free(r)
        BN_free(s)
        
        if verifyResult != 1:
          log(lvlError, fmt"ECDSA署名検証に失敗しました: {ERR_get_error()}")
          return false
      
      of signatureAlgorithmRSA:
        # RSA署名検証
        let rsaKey = ctLog.publicKey.getRsaKey()
        if rsaKey == nil:
          log(lvlError, "RSAキーの取得に失敗しました")
          return false
        
        # RSA_verify関数で検証
        let verifyResult = RSA_verify(
          NID_sha256,
          cast[ptr cuchar](dataToVerify.cstring),
          dataToVerify.len.cint,
          cast[ptr cuchar](signatureBytes.cstring),
          signatureBytes.len.cint,
          rsaKey
        )
        
        if verifyResult != 1:
          log(lvlError, fmt"RSA署名検証に失敗しました: {ERR_get_error()}")
          return false
      
      else:
        log(lvlError, fmt"未対応の署名アルゴリズム: {sct.signatureAlgorithm}")
        return false
    
    # すべての検証に成功
    log(lvlInfo, fmt"SCT署名検証成功: ログ={ctLog.name}, タイムスタンプ={sct.timestamp}")
    return true
  
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"SCT署名検証中に例外が発生しました: {msg}")
    return false

# 証明書のCT情報を検証
proc verifyCertificate*(
  manager: CtManager,
  cert: X509,
  hostname: string,
  tlsExtensionScts: seq[SignedCertificateTimestamp] = @[],
  ocspScts: seq[SignedCertificateTimestamp] = @[]
): tuple[result: CtVerificationResult, info: CtInfo] =
  
  var ctInfo = CtInfo(
    scts: @[],
    hasEmbeddedSct: false,
    hasOcspSct: ocspScts.len > 0,
    hasTlsExtensionSct: tlsExtensionScts.len > 0,
    compliantSctCount: 0
  )
  
  # 証明書からSCTを抽出
  let embeddedScts = manager.extractSctFromCertificate(cert)
  if embeddedScts.len > 0:
    ctInfo.hasEmbeddedSct = true
    for sct in embeddedScts:
      ctInfo.scts.add(sct)
  
  # TLS拡張SCTを追加
  for sct in tlsExtensionScts:
    ctInfo.scts.add(sct)
  
  # OCSPレスポンスSCTを追加
  for sct in ocspScts:
    ctInfo.scts.add(sct)
  
  # SCTがない場合
  if ctInfo.scts.len == 0:
    log(lvlWarn, fmt"SCTが見つかりません: {hostname}")
    return (ctVerificationInsufficientScts, ctInfo)
  
  # 検証要件を決定
  var requirement = manager.config.verificationRequirement
  
  # 特定のドメインに対する要件の上書き
  if hostname in manager.config.enforcedDomains:
    requirement = ctRequirementEnforced
  elif hostname in manager.config.exemptedDomains:
    requirement = ctRequirementNone
  
  # 要件がnoneの場合は検証しない
  if requirement == ctRequirementNone:
    return (ctVerificationSuccess, ctInfo)
  
  # 各SCTを検証
  var validSctCount = 0
  var validOperators = initHashSet[string]()
  
  for sct in ctInfo.scts:
    # SCTの署名を検証
    if manager.verifySctSignature(sct, cert):
      inc(validSctCount)
      
      # オペレーター情報を追跡（同一オペレーターからの複数のSCTは1つとしてカウント）
      if sct.logId in manager.knownLogs:
        validOperators.incl(manager.knownLogs[sct.logId].operator.name)
    else:
      log(lvlWarn, fmt"無効なSCT署名: {hostname}, ログID: {sct.logId}")
  
  ctInfo.compliantSctCount = validSctCount
  
  # 最小SCT数と比較
  let uniqueOperatorCount = validOperators.len
  if validSctCount < manager.config.minSctCount or uniqueOperatorCount < min(2, validSctCount):
    log(lvlWarn, fmt"不十分なSCT: {hostname}, 有効数: {validSctCount}, 一意なオペレーター: {uniqueOperatorCount}")
    
    # best_effortモードでは警告だけで失敗にしない
    if requirement == ctRequirementBestEffort:
      return (ctVerificationSuccess, ctInfo)
    else:
      return (ctVerificationInsufficientScts, ctInfo)
  
  return (ctVerificationSuccess, ctInfo)

# 強制ドメインを追加
proc addEnforcedDomain*(manager: CtManager, domain: string) =
  manager.config.enforcedDomains.incl(domain)
  log(lvlInfo, fmt"CT強制ドメインに追加: {domain}")

# 強制ドメインを削除
proc removeEnforcedDomain*(manager: CtManager, domain: string) =
  manager.config.enforcedDomains.excl(domain)
  log(lvlInfo, fmt"CT強制ドメインから削除: {domain}")

# 免除ドメインを追加
proc addExemptedDomain*(manager: CtManager, domain: string) =
  manager.config.exemptedDomains.incl(domain)
  log(lvlInfo, fmt"CT免除ドメインに追加: {domain}")

# 免除ドメインを削除
proc removeExemptedDomain*(manager: CtManager, domain: string) =
  manager.config.exemptedDomains.excl(domain)
  log(lvlInfo, fmt"CT免除ドメインから削除: {domain}")

# 設定をJSONとして保存
proc saveConfig*(manager: CtManager, path: string): bool =
  try:
    var configObj = newJObject()
    
    configObj["known_logs_path"] = %manager.config.knownLogsPath
    configObj["min_sct_count"] = %manager.config.minSctCount
    configObj["enforce_sct_verification"] = %manager.config.enforceSctVerification
    configObj["verification_requirement"] = %($manager.config.verificationRequirement)
    configObj["allow_unknown_logs"] = %manager.config.allowUnknownLogs
    
    var enforcedArray = newJArray()
    for domain in manager.config.enforcedDomains:
      enforcedArray.add(%domain)
    configObj["enforced_domains"] = enforcedArray
    
    var exemptedArray = newJArray()
    for domain in manager.config.exemptedDomains:
      exemptedArray.add(%domain)
    configObj["exempted_domains"] = exemptedArray
    
    # ディレクトリが存在することを確認
    let dir = parentDir(path)
    createDir(dir)
    
    # ファイルに書き込み
    writeFile(path, pretty(configObj))
    log(lvlInfo, fmt"CT設定を保存しました: {path}")
    return true
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"CT設定の保存に失敗しました: {msg}")
    return false

# 設定をJSONから読み込み
proc loadConfig*(manager: CtManager, path: string): bool =
  if not fileExists(path):
    log(lvlWarn, fmt"CT設定ファイルが見つかりません: {path}")
    return false
  
  try:
    let jsonContent = readFile(path)
    let jsonNode = parseJson(jsonContent)
    
    if jsonNode.kind != JObject:
      log(lvlError, "無効なCT設定ファイル形式: オブジェクトが予期されました")
      return false
    
    # 基本設定
    if jsonNode.hasKey("known_logs_path"):
      manager.config.knownLogsPath = jsonNode["known_logs_path"].getStr()
    
    if jsonNode.hasKey("min_sct_count"):
      manager.config.minSctCount = jsonNode["min_sct_count"].getInt()
    
    if jsonNode.hasKey("enforce_sct_verification"):
      manager.config.enforceSctVerification = jsonNode["enforce_sct_verification"].getBool()
    
    if jsonNode.hasKey("verification_requirement"):
      try:
        manager.config.verificationRequirement = parseEnum[CtVerificationRequirement](jsonNode["verification_requirement"].getStr())
      except:
        # 無効な値の場合はデフォルト使用
        discard
    
    if jsonNode.hasKey("allow_unknown_logs"):
      manager.config.allowUnknownLogs = jsonNode["allow_unknown_logs"].getBool()
    
    # 強制ドメイン
    manager.config.enforcedDomains.clear()
    if jsonNode.hasKey("enforced_domains") and jsonNode["enforced_domains"].kind == JArray:
      for item in jsonNode["enforced_domains"]:
        if item.kind == JString:
          manager.config.enforcedDomains.incl(item.getStr())
    
    # 免除ドメイン
    manager.config.exemptedDomains.clear()
    if jsonNode.hasKey("exempted_domains") and jsonNode["exempted_domains"].kind == JArray:
      for item in jsonNode["exempted_domains"]:
        if item.kind == JString:
          manager.config.exemptedDomains.incl(item.getStr())
    
    log(lvlInfo, fmt"CT設定を読み込みました: {path}")
    return true
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"CT設定の読み込みに失敗しました: {msg}")
    return false

# 既知のログをJSONとして出力
proc knownLogsToJson*(manager: CtManager): JsonNode =
  var logsArray = newJArray()
  
  for id, log in manager.knownLogs:
    var logObj = newJObject()
    
    logObj["id"] = %log.id
    logObj["key"] = %log.key
    logObj["url"] = %log.url
    logObj["mmd"] = %log.mmd
    logObj["status"] = %($log.status)
    
    var operatorObj = newJObject()
    operatorObj["name"] = %log.operator.name
    operatorObj["website"] = %log.operator.website
    operatorObj["email"] = %log.operator.email
    logObj["operator"] = operatorObj
    
    if log.startTime.isSome:
      logObj["start_time"] = %(log.startTime.get().format("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    
    if log.endTime.isSome:
      logObj["end_time"] = %(log.endTime.get().format("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    
    logsArray.add(logObj)
  
  return logsArray

# 既知のログをファイルに保存
proc saveKnownLogs*(manager: CtManager): bool =
  try:
    let logsArray = manager.knownLogsToJson()
    
    # ディレクトリが存在することを確認
    let dir = parentDir(manager.config.knownLogsPath)
    createDir(dir)
    
    # ファイルに書き込み
    writeFile(manager.config.knownLogsPath, pretty(logsArray))
    log(lvlInfo, fmt"CT既知ログを保存しました: {manager.config.knownLogsPath}")
    return true
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"CT既知ログの保存に失敗しました: {msg}")
    return false

# ログリストを更新する（オンラインソースから）
proc updateKnownLogs*(manager: CtManager, url: string = "https://www.gstatic.com/ct/log_list/v2/log_list.json"): Future[bool] {.async.} =
  try:
    # Googleが提供する既知ログリストをダウンロード
    let client = newHttpClient()
    let response = await client.getContent(url)
    
    let jsonNode = parseJson(response)
    
    if jsonNode.kind != JObject or not jsonNode.hasKey("operators") or not jsonNode.hasKey("logs"):
      log(lvlError, "無効なログリスト形式")
      return false
    
    # オペレーターマップを作成
    var operators = initTable[string, CtLogOperator]()
    
    if jsonNode["operators"].kind == JArray:
      for opNode in jsonNode["operators"]:
        if opNode.kind != JObject or not opNode.hasKey("id") or not opNode.hasKey("name"):
          continue
        
        let id = opNode["id"].getInt()
        let name = opNode["name"].getStr()
        
        var operator = CtLogOperator(
          name: name,
          website: if opNode.hasKey("website"): opNode["website"].getStr() else: "",
          email: if opNode.hasKey("email"): opNode["email"].getStr() else: ""
        )
        
        operators[$id] = operator
    
    # 既知のログをクリア
    manager.knownLogs.clear()
    manager.qualifiedLogs.clear()
    
    # ログを処理
    if jsonNode["logs"].kind == JArray:
      for logNode in jsonNode["logs"]:
        if logNode.kind != JObject or not logNode.hasKey("log_id") or not logNode.hasKey("key"):
          continue
        
        let id = logNode["log_id"].getStr()
        let key = logNode["key"].getStr()
        var url = if logNode.hasKey("url"): logNode["url"].getStr() else: ""
        
        # オペレーター情報
        var operator = CtLogOperator(name: "Unknown")
        if logNode.hasKey("operated_by"):
          let opIds = logNode["operated_by"]
          if opIds.kind == JArray and opIds.len > 0:
            let opId = $opIds[0].getInt()
            if opId in operators:
              operator = operators[opId]
        
        # ステータス
        var status = ctLogQualified
        if logNode.hasKey("state"):
          let stateNode = logNode["state"]
          if stateNode.kind == JObject:
            if stateNode.hasKey("rejected"):
              status = ctLogDisqualified
            elif stateNode.hasKey("readonly"):
              status = ctLogReadOnly
            elif stateNode.hasKey("pending"):
              status = ctLogPending
        
        # タイムスタンプ
        var startTime: Option[DateTime]
        var endTime: Option[DateTime]
        
        if logNode.hasKey("temporal_interval"):
          let interval = logNode["temporal_interval"]
          if interval.kind == JObject:
            if interval.hasKey("start_inclusive"):
              try:
                startTime = some(parse(interval["start_inclusive"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'"))
              except:
                startTime = none(DateTime)
            
            if interval.hasKey("end_exclusive"):
              try:
                endTime = some(parse(interval["end_exclusive"].getStr(), "yyyy-MM-dd'T'HH:mm:ss'Z'"))
              except:
                endTime = none(DateTime)
        
        # MMD
        var mmd = 86400 # デフォルト: 1日
        if logNode.hasKey("mmd"):
          mmd = logNode["mmd"].getInt()
        
        # ログオブジェクトを作成
        let ctLog = CtLog(
          id: id,
          key: key,
          url: url,
          mmd: mmd,
          operator: operator,
          status: status,
          startTime: startTime,
          endTime: endTime
        )
        
        # ログをテーブルに追加
        manager.knownLogs[id] = ctLog
        
        # 承認されたログの場合はセットに追加
        if status == ctLogQualified:
          manager.qualifiedLogs.incl(id)
    
    log(lvlInfo, fmt"CT既知ログをオンラインで更新しました: {manager.knownLogs.len} ログ, うち {manager.qualifiedLogs.len} が承認済み")
    
    # 更新したログリストを保存
    manager.saveKnownLogs()
    
    return true
  except:
    let e = getCurrentException()
    let msg = getCurrentExceptionMsg()
    log(lvlError, fmt"CT既知ログのオンライン更新に失敗しました: {msg}")
    return false

# SCTリストをJSONとして出力
proc sctsToJson*(scts: seq[SignedCertificateTimestamp]): JsonNode =
  var sctsArray = newJArray()
  
  for sct in scts:
    var sctObj = newJObject()
    
    sctObj["log_id"] = %sct.logId
    sctObj["timestamp"] = %sct.timestamp
    sctObj["signature"] = %sct.signature
    sctObj["hash_algorithm"] = %sct.hashAlgorithm
    sctObj["signature_algorithm"] = %sct.signatureAlgorithm
    sctObj["version"] = %sct.version
    sctObj["extensions"] = %sct.extensions
    sctObj["source"] = %($sct.source)
    
    sctsArray.add(sctObj)
  
  return sctsArray

# CT情報をJSONとして出力
proc toJson*(info: CtInfo): JsonNode =
  var infoObj = newJObject()
  
  infoObj["scts"] = sctsToJson(info.scts)
  infoObj["has_embedded_sct"] = %info.hasEmbeddedSct
  infoObj["has_ocsp_sct"] = %info.hasOcspSct
  infoObj["has_tls_extension_sct"] = %info.hasTlsExtensionSct
  infoObj["compliant_sct_count"] = %info.compliantSctCount
  
  return infoObj

# CT設定を取得
proc getConfig*(manager: CtManager): CtConfig =
  return manager.config

# CT設定を設定
proc setConfig*(manager: CtManager, config: CtConfig) =
  if not config.isNil:
    manager.config = config
    log(lvlInfo, "CT設定を更新しました")
    
    # 設定変更後に既知のログを再読み込み
    try:
      manager.loadKnownLogs()
    except:
      let e = getCurrentException()
      let msg = getCurrentExceptionMsg()
      log(lvlError, fmt"CT既知ログの再読み込みに失敗しました: {msg}")

# 証明書のCT情報を検証（ドメイン名から）
proc verifyConnection*(
  manager: CtManager,
  hostname: string,
  cert: X509,
  tlsExtensionScts: seq[SignedCertificateTimestamp] = @[],
  ocspScts: seq[SignedCertificateTimestamp] = @[]
): tuple[result: CtVerificationResult, info: CtInfo] =
  return manager.verifyCertificate(cert, hostname, tlsExtensionScts, ocspScts)

# モジュールバージョン
const CtVersion* = "1.0.0" 