import std/[times, hashes, tables]
import ../records

type
  DnsCacheEntry* = ref object
    ## DNSキャッシュエントリ
    domain*: string           # ドメイン名
    recordType*: DnsRecordType # レコードタイプ
    records*: seq[DnsRecord]  # DNSレコード
    createdAt*: Time         # 作成時間
    expiresAt*: Time         # 有効期限
    isNegative*: bool        # 否定的キャッシュエントリかどうか
    isTrusted*: bool         # 信頼されたエントリかどうか（ローカルホストファイルなど）

proc hash*(entry: DnsCacheEntry): Hash =
  ## キャッシュエントリのハッシュ関数
  var h: Hash = 0
  h = h !& hash(entry.domain)
  h = h !& hash(ord(entry.recordType))
  result = !$h

proc `==`*(a, b: DnsCacheEntry): bool =
  ## キャッシュエントリの等価性比較
  if a.isNil or b.isNil:
    return a.isNil and b.isNil

  return a.domain == b.domain and a.recordType == b.recordType

proc newDnsCacheEntry*(domain: string, recordType: DnsRecordType,
                      records: seq[DnsRecord], 
                      isNegative = false, isTrusted = false): DnsCacheEntry =
  ## 新しいDNSキャッシュエントリを作成
  var expiresAt = getTime()
  
  # レコードから最小TTLを取得して有効期限を設定
  if records.len > 0 and not isNegative:
    var minExpiry = records[0].expiresAt
    for record in records:
      if record.expiresAt < minExpiry:
        minExpiry = record.expiresAt
    expiresAt = minExpiry
  else:
    # 否定的エントリの場合、デフォルトで60秒のTTL
    expiresAt = getTime() + 60.seconds
  
  result = DnsCacheEntry(
    domain: domain,
    recordType: recordType,
    records: records,
    createdAt: getTime(),
    expiresAt: expiresAt,
    isNegative: isNegative,
    isTrusted: isTrusted
  )

proc isExpired*(entry: DnsCacheEntry): bool =
  ## キャッシュエントリが期限切れかどうかをチェック
  if entry.isTrusted:
    # 信頼されたエントリは期限切れにならない
    return false
  return getTime() > entry.expiresAt

proc remainingTtl*(entry: DnsCacheEntry): int =
  ## キャッシュエントリの残りTTLを秒単位で取得
  if entry.isTrusted:
    # 信頼されたエントリは無限のTTLを持つ
    return high(int)
  
  let remaining = entry.expiresAt - getTime()
  if remaining.inSeconds < 0:
    return 0
  return remaining.inSeconds.int

proc updateExpiresAt*(entry: DnsCacheEntry) =
  ## レコードの有効期限に基づいてキャッシュエントリの有効期限を更新
  if entry.isNegative or entry.records.len == 0:
    return
  
  var minExpiry = entry.records[0].expiresAt
  for record in entry.records:
    if record.expiresAt < minExpiry:
      minExpiry = record.expiresAt
  
  entry.expiresAt = minExpiry

proc addRecord*(entry: DnsCacheEntry, record: DnsRecord) =
  ## キャッシュエントリにレコードを追加
  entry.records.add(record)
  entry.updateExpiresAt()

proc removeExpiredRecords*(entry: DnsCacheEntry) =
  ## 期限切れのレコードを削除
  var validRecords: seq[DnsRecord] = @[]
  for record in entry.records:
    if not record.isExpired():
      validRecords.add(record)
  
  entry.records = validRecords
  entry.updateExpiresAt()

proc hasValidRecords*(entry: DnsCacheEntry): bool =
  ## 有効なレコードがあるかどうかをチェック
  if entry.isNegative:
    return not entry.isExpired()
  
  entry.removeExpiredRecords()
  return entry.records.len > 0

proc markAsTrusted*(entry: DnsCacheEntry) =
  ## エントリを信頼済みとしてマーク
  entry.isTrusted = true

proc `$`*(entry: DnsCacheEntry): string =
  ## キャッシュエントリの文字列表現
  result = entry.domain & " (" & $entry.recordType & ")"
  if entry.isNegative:
    result &= " [NEGATIVE]"
  if entry.isTrusted:
    result &= " [TRUSTED]"
  result &= " expires in " & $entry.remainingTtl() & "s"
  result &= " with " & $entry.records.len & " records" 