import std/[times, json]

type
  DnsCacheStatistics* = ref object
    hits*: int           # キャッシュヒット数
    misses*: int         # キャッシュミス数
    adds*: int           # キャッシュに追加されたエントリ数
    negativeAdds*: int   # ネガティブキャッシュに追加されたエントリ数
    lastResetTime*: Time # 最後の統計リセット時間

proc newDnsCacheStatistics*(): DnsCacheStatistics =
  ## 新しいDNSキャッシュ統計情報オブジェクトを作成
  result = DnsCacheStatistics()
  result.hits = 0
  result.misses = 0
  result.adds = 0
  result.negativeAdds = 0
  result.lastResetTime = getTime()

proc hitRate*(self: DnsCacheStatistics): float =
  ## キャッシュヒット率を計算（0〜1の範囲）
  let total = self.hits + self.misses
  if total == 0:
    return 0.0
  return self.hits.float / total.float

proc reset*(self: DnsCacheStatistics) =
  ## 統計情報をリセット
  self.hits = 0
  self.misses = 0
  self.adds = 0
  self.negativeAdds = 0
  self.lastResetTime = getTime()

proc toJson*(self: DnsCacheStatistics): JsonNode =
  ## 統計情報をJSON形式に変換
  result = newJObject()
  result["hits"] = %self.hits
  result["misses"] = %self.misses
  result["adds"] = %self.adds
  result["negativeAdds"] = %self.negativeAdds
  result["hitRate"] = %self.hitRate()
  result["lastResetTime"] = %self.lastResetTime.toUnix()

proc `$`*(self: DnsCacheStatistics): string =
  ## 統計情報を文字列形式で出力
  result = "DNSキャッシュ統計:\n"
  result &= "  ヒット数: " & $self.hits & "\n"
  result &= "  ミス数: " & $self.misses & "\n"
  result &= "  追加数: " & $self.adds & "\n"
  result &= "  ネガティブキャッシュ追加数: " & $self.negativeAdds & "\n"
  result &= "  ヒット率: " & $(self.hitRate() * 100.0) & "%\n"
  result &= "  最終リセット: " & $self.lastResetTime 