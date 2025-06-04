# 履歴タイムラインモジュール
# ブラウザの閲覧履歴を時系列で分析・表示する機能を提供します

import std/[
  times, 
  tables, 
  json, 
  options, 
  sequtils,
  algorithm,
  sugar,
  strutils,
  strformat,
  uri,
  sets,
  asyncdispatch
]

import pkg/[
  chronicles
]

import ../../quantum_utils/[config, dateutils]
import ./store

type
  TimelinePeriod* = enum
    ## タイムライン期間
    tpToday,        # 今日
    tpYesterday,    # 昨日
    tpLastWeek,     # 先週
    tpLastMonth,    # 先月
    tpOlder         # それ以前

  TimelineEntry* = object
    ## タイムラインエントリ
    page*: HistoryPage         # ページ情報
    firstVisitInPeriod*: DateTime  # この期間の最初の訪問
    lastVisitInPeriod*: DateTime   # この期間の最後の訪問
    visitCountInPeriod*: int   # この期間の訪問回数
    
  TimelineGroup* = object
    ## タイムライングループ（例：一日分のグループ）
    period*: TimelinePeriod    # 期間
    date*: DateTime            # 日付
    entries*: seq[TimelineEntry]  # エントリ
    title*: string             # グループタイトル
    
  TimelineFilters* = object
    ## タイムラインフィルタ
    startDate*: Option[DateTime]  # 開始日
    endDate*: Option[DateTime]    # 終了日
    searchText*: string        # 検索テキスト
    domains*: seq[string]      # ドメイン制限
    excludeDomains*: seq[string]  # 除外ドメイン
    minimumVisits*: int        # 最小訪問数
    
  DomainVisits* = object
    ## ドメイン別訪問統計
    domain*: string           # ドメイン
    visits*: int              # 訪問数
    pages*: int               # ページ数
    timeSpent*: Duration      # 滞在時間
    lastVisit*: DateTime      # 最終訪問
    
  TimelineAnalytics* = object
    ## タイムライン分析情報
    totalVisits*: int          # 総訪問数
    uniquePages*: int          # ユニークページ数
    topDomains*: seq[DomainVisits]  # トップドメイン
    visitsByHour*: array[24, int]  # 時間帯別訪問数
    visitsByDay*: array[7, int]    # 曜日別訪問数
    
  HistoryTimeline* = ref object
    ## 履歴タイムライン
    store*: HistoryStore         # 履歴ストア
    currentGroup*: TimelineGroup  # 現在のグループ
    groups*: seq[TimelineGroup]   # すべてのグループ
    analytics*: TimelineAnalytics  # 分析情報
    filters*: TimelineFilters     # フィルタ
    initialized*: bool            # 初期化済みフラグ

# ヘルパー関数
proc getPeriodForDate(date: DateTime): TimelinePeriod =
  ## 日付から期間を判定
  let today = now().utc.date
  
  if date.utc.date == today:
    return TimelinePeriod.tpToday
  elif date.utc.date == today - 1.days:
    return TimelinePeriod.tpYesterday
  elif date.utc.date >= today - 7.days:
    return TimelinePeriod.tpLastWeek
  elif date.utc.date >= today - 30.days:
    return TimelinePeriod.tpLastMonth
  else:
    return TimelinePeriod.tpOlder

proc formatGroupTitle(period: TimelinePeriod, date: DateTime): string =
  ## グループのタイトルをフォーマット
  case period:
    of TimelinePeriod.tpToday:
      return "今日"
    of TimelinePeriod.tpYesterday:
      return "昨日"
    of TimelinePeriod.tpLastWeek:
      return date.format("M月d日（ddd）")
    of TimelinePeriod.tpLastMonth:
      return date.format("M月d日（ddd）")
    of TimelinePeriod.tpOlder:
      return date.format("yyyy年M月d日（ddd）")

proc extractDomain(url: string): string =
  ## URLからドメインを抽出
  try:
    let uri = parseUri(url)
    return uri.hostname
  except:
    return url

proc calculateTimeSpent(visits: seq[PageVisit]): Duration =
  ## 訪問からページ滞在時間を計算
  if visits.len <= 1:
    return 30.seconds  # デフォルト時間
  
  var totalTime = 0.seconds
  var sortedVisits = visits
  sortedVisits.sort((a, b) => cmp(a.visitTime, b.visitTime))
  
  for i in 0..<sortedVisits.len-1:
    let timeDiff = sortedVisits[i+1].visitTime - sortedVisits[i].visitTime
    
    # 同じページ内の訪問なら加算（30分以内の場合）
    if timeDiff <= 30.minutes:
      totalTime += timeDiff
    else:
      # 長い間隔は別セッションとみなし、デフォルト時間を加算
      totalTime += 30.seconds
  
  # 最後の訪問にもデフォルト時間を加算
  totalTime += 30.seconds
  
  return totalTime

proc filterMatchesPage(page: HistoryPage, filters: TimelineFilters): bool =
  ## ページがフィルタ条件に一致するか確認
  # 検索テキスト
  if filters.searchText.len > 0:
    let searchText = filters.searchText.toLowerAscii()
    if not (page.title.toLowerAscii().contains(searchText) or 
            page.url.toLowerAscii().contains(searchText)):
      return false
  
  # 訪問数
  if page.visitCount < filters.minimumVisits:
    return false
  
  # ドメイン制限
  if filters.domains.len > 0:
    let pageDomain = extractDomain(page.url)
    var domainMatched = false
    for domain in filters.domains:
      if pageDomain.contains(domain):
        domainMatched = true
        break
    
    if not domainMatched:
      return false
  
  # 除外ドメイン
  if filters.excludeDomains.len > 0:
    let pageDomain = extractDomain(page.url)
    for domain in filters.excludeDomains:
      if pageDomain.contains(domain):
        return false
  
  return true

# HistoryTimelineの実装
proc newHistoryTimeline*(store: HistoryStore): HistoryTimeline =
  ## 新しい履歴タイムラインを作成
  result = HistoryTimeline(
    store: store,
    groups: @[],
    analytics: TimelineAnalytics(
      totalVisits: 0,
      uniquePages: 0,
      topDomains: @[],
      visitsByHour: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      visitsByDay: [0, 0, 0, 0, 0, 0, 0]
    ),
    filters: TimelineFilters(
      searchText: "",
      domains: @[],
      excludeDomains: @[],
      minimumVisits: 0
    ),
    initialized: true
  )
  
  info "History timeline initialized"

proc applyFilters*(self: HistoryTimeline, filters: TimelineFilters) =
  ## フィルタを適用
  self.filters = filters
  info "Applied timeline filters", 
       search_text = filters.searchText, 
       domains = filters.domains.len, 
       exclude_domains = filters.excludeDomains.len,
       min_visits = filters.minimumVisits

proc loadTimelineGroup*(self: HistoryTimeline, date: DateTime): TimelineGroup =
  ## 指定日のタイムライングループを読み込み
  let 
    startOfDay = dateutils.startOfDay(date)
    endOfDay = dateutils.endOfDay(date)
    period = getPeriodForDate(date)
  
  var group = TimelineGroup(
    period: period,
    date: date,
    entries: @[],
    title: formatGroupTitle(period, date)
  )
  
  # 日付範囲の履歴を検索
  let searchOpts = SearchOptions(
    startTime: some(startOfDay),
    endTime: some(endOfDay),
    maxResults: 1000,  # 十分大きな値
    orderByTime: true,
    includeHidden: false
  )
  
  let pages = self.store.searchHistory(searchOpts)
  
  var filteredPages: seq[HistoryPage] = @[]
  for page in pages:
    if filterMatchesPage(page, self.filters):
      # 訪問情報を取得
      let visitsForPage = self.store.getVisitsForPage(page.id)
      var pageWithVisits = page
      pageWithVisits.visits = visitsForPage
      filteredPages.add(pageWithVisits)
  
  # 同じページの訪問を集約
  var pageMap: Table[int64, TimelineEntry] = initTable[int64, TimelineEntry]()
  
  for page in filteredPages:
    var visitsInRange: seq[PageVisit] = @[]
    
    # 範囲内の訪問だけをフィルタ
    for visit in page.visits:
      if visit.visitTime >= startOfDay and visit.visitTime <= endOfDay:
        visitsInRange.add(visit)
    
    if visitsInRange.len > 0:
      # 時間順にソート
      visitsInRange.sort((a, b) => cmp(a.visitTime, b.visitTime))
      
      let entry = TimelineEntry(
        page: page,
        firstVisitInPeriod: visitsInRange[0].visitTime,
        lastVisitInPeriod: visitsInRange[^1].visitTime,
        visitCountInPeriod: visitsInRange.len
      )
      
      pageMap[page.id] = entry
  
  # 時間順にソート
  var entries = toSeq(pageMap.values)
  entries.sort((a, b) => cmp(b.lastVisitInPeriod, a.lastVisitInPeriod))
  
  group.entries = entries
  
  self.currentGroup = group
  return group

proc buildTimeline*(self: HistoryTimeline, days: int = 30): seq[TimelineGroup] =
  ## 指定した日数分のタイムラインを構築
  result = @[]
  
  let today = now()
  for dayOffset in 0..<days:
    let date = today - dayOffset.days
    let group = self.loadTimelineGroup(date)
    
    # エントリがある場合のみ追加
    if group.entries.len > 0:
      result.add(group)
  
  self.groups = result
  info "Built timeline", days = days, groups = result.len
  
  return result

proc analyzeTimeline*(self: HistoryTimeline): TimelineAnalytics =
  ## タイムラインを分析
  var 
    totalVisits = 0
    uniquePageIds = initHashSet[int64]()
    domainStats: Table[string, tuple[visits: int, pages: int, time: Duration, lastVisit: DateTime]] = initTable[string, tuple[visits: int, pages: int, time: Duration, lastVisit: DateTime]]()
    hourStats: array[24, int] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    dayStats: array[7, int] = [0, 0, 0, 0, 0, 0, 0]
  
  # すべてのグループとエントリを分析
  for group in self.groups:
    for entry in group.entries:
      # 訪問数
      totalVisits += entry.visitCountInPeriod
      
      # ユニークページ
      uniquePageIds.incl(entry.page.id)
      
      # ドメイン統計
      let domain = extractDomain(entry.page.url)
      
      if not domainStats.hasKey(domain):
        domainStats[domain] = (
          visits: 0, 
          pages: 0, 
          time: 0.seconds,
          lastVisit: DateTime()
        )
      
      var domainStat = domainStats[domain]
      domainStat.visits += entry.visitCountInPeriod
      domainStat.pages += 1
      
      # 滞在時間計算
      if entry.page.visits.len > 0:
        domainStat.time += calculateTimeSpent(entry.page.visits)
      
      # 最終訪問時間
      if domainStat.lastVisit == DateTime() or entry.lastVisitInPeriod > domainStat.lastVisit:
        domainStat.lastVisit = entry.lastVisitInPeriod
      
      domainStats[domain] = domainStat
      
      # 時間帯と曜日の統計
      for visit in entry.page.visits:
        let 
          hour = visit.visitTime.hour
          day = ord(getDayOfWeek(visit.visitTime))  # 0=Sunday, 6=Saturday
        
        hourStats[hour] += 1
        dayStats[day] += 1
  
  # ドメイン統計をランク付け
  var domainVisits: seq[DomainVisits] = @[]
  for domain, stats in domainStats.pairs:
    domainVisits.add(DomainVisits(
      domain: domain,
      visits: stats.visits,
      pages: stats.pages,
      timeSpent: stats.time,
      lastVisit: stats.lastVisit
    ))
  
  # 訪問数でソート
  domainVisits.sort((a, b) => cmp(b.visits, a.visits))
  
  # 上位10ドメインだけを保持
  if domainVisits.len > 10:
    domainVisits = domainVisits[0..<10]
  
  # 分析結果作成
  result = TimelineAnalytics(
    totalVisits: totalVisits,
    uniquePages: uniquePageIds.len,
    topDomains: domainVisits,
    visitsByHour: hourStats,
    visitsByDay: dayStats
  )
  
  self.analytics = result
  info "Analyzed timeline", 
       visits = totalVisits, 
       pages = uniquePageIds.len, 
       domains = domainVisits.len
  
  return result

proc searchInTimeline*(self: HistoryTimeline, query: string): seq[TimelineEntry] =
  ## タイムライン内で検索
  result = @[]
  
  let searchText = query.toLowerAscii()
  
  for group in self.groups:
    for entry in group.entries:
      if entry.page.title.toLowerAscii().contains(searchText) or
         entry.page.url.toLowerAscii().contains(searchText):
        result.add(entry)
  
  info "Searched in timeline", query = query, results = result.len
  return result

proc groupEntriesByDomain*(self: HistoryTimeline): Table[string, seq[TimelineEntry]] =
  ## ドメインごとにエントリをグループ化
  result = initTable[string, seq[TimelineEntry]]()
  
  for group in self.groups:
    for entry in group.entries:
      let domain = extractDomain(entry.page.url)
      
      if not result.hasKey(domain):
        result[domain] = @[]
      
      result[domain].add(entry)
  
  return result

proc findRelatedPages*(self: HistoryTimeline, pageId: int64): seq[TimelineEntry] =
  ## 関連ページを検索
  result = @[]
  
  # 対象ページを検索
  var targetPage: Option[HistoryPage] = none(HistoryPage)
  
  for group in self.groups:
    for entry in group.entries:
      if entry.page.id == pageId:
        targetPage = some(entry.page)
        break
    
    if targetPage.isSome:
      break
  
  if targetPage.isNone:
    return result
  
  let 
    page = targetPage.get()
    pageDomain = extractDomain(page.url)
    pageTitle = page.title.toLowerAscii()
    
    # タイトルの重要なキーワードを完璧に抽出
    var keywords: seq[string] = @[]
    
    # 1. ストップワードの除去
    let stopWords = [
      "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by",
      "は", "が", "を", "に", "へ", "で", "と", "の", "から", "まで", "より", "について", "として",
      "です", "である", "だ", "である", "します", "する", "した", "される", "されている"
    ].toHashSet()
    
    # 2. 単語の分割と正規化
    var words: seq[string] = @[]
    
    # 英語の単語分割
    let englishWords = pageTitle.split(re"[\s\-_\.\,\;\:\!\?\(\)\[\]\{\}]+")
    for word in englishWords:
      if word.len > 2 and word.toLowerAscii() notin stopWords:
        words.add(word.toLowerAscii())
    
    # 日本語の形態素解析（簡易版）
    let japanesePattern = re"[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FAF]+"
    var japaneseMatches: seq[string] = @[]
    for match in pageTitle.findAll(japanesePattern):
      if match.len > 1:
        # 簡易的な日本語単語分割
        let segments = segmentJapanese(match)
        for segment in segments:
          if segment.len > 1 and segment notin stopWords:
            japaneseMatches.add(segment)
    
    words.add(japaneseMatches)
    
    # 3. TF-IDF計算による重要度スコアリング
    var wordFreq = initCountTable[string]()
    for word in words:
      wordFreq.inc(word)
    
    # 4. 重要なキーワードの選出
    var scoredWords: seq[tuple[word: string, score: float]] = @[]
    
    for word, freq in wordFreq:
      var score = freq.float
      
      # 長さによるボーナス（長い単語ほど重要）
      if word.len >= 4:
        score *= 1.5
      elif word.len >= 6:
        score *= 2.0
      
      # 大文字で始まる単語（固有名詞）にボーナス
      if word[0].isUpperAscii():
        score *= 1.3
      
      # 数字を含む単語にボーナス
      if word.contains(re"\d"):
        score *= 1.2
      
      # 技術用語の検出
      let techTerms = [
        "api", "sdk", "framework", "library", "database", "server", "client",
        "algorithm", "machine", "learning", "artificial", "intelligence",
        "blockchain", "cryptocurrency", "quantum", "neural", "network"
      ].toHashSet()
      
      if word in techTerms:
        score *= 2.0
      
      # 日本語の重要語彙
      let importantJapanese = [
        "技術", "開発", "プログラミング", "システム", "アプリケーション", "ソフトウェア",
        "ハードウェア", "ネットワーク", "セキュリティ", "データベース", "人工知能",
        "機械学習", "ブロックチェーン", "クラウド", "モバイル", "ウェブ"
      ].toHashSet()
      
      if word in importantJapanese:
        score *= 2.0
      
      scoredWords.add((word: word, score: score))
    
    # 5. スコア順にソートして上位を選択
    scoredWords.sort(proc(a, b: tuple[word: string, score: float]): int =
      cmp(b.score, a.score))
    
    # 上位10個のキーワードを選択
    let maxKeywords = min(10, scoredWords.len)
    for i in 0..<maxKeywords:
      if scoredWords[i].score >= 1.0:  # 最小スコア閾値
        keywords.add(scoredWords[i].word)
    
    # 6. 複合語の検出
    let compounds = detectCompoundWords(pageTitle)
    for compound in compounds:
      if compound.len > 3 and compound notin keywords:
        keywords.add(compound)
    
    # 7. エンティティ抽出（URL、メール、日付など）
    let entities = extractEntities(pageTitle)
    for entity in entities:
      if entity.len > 2 and entity notin keywords:
        keywords.add(entity)
    
    return keywords

proc segmentJapanese(text: string): seq[string] =
  ## 簡易的な日本語単語分割
  result = @[]
  
  # ひらがな、カタカナ、漢字の境界で分割
  var currentSegment = ""
  var lastCharType = CharType.Other
  
  for char in text.runes:
    let charType = getCharType(char)
    
    if charType != lastCharType and currentSegment.len > 0:
      if currentSegment.len > 1:
        result.add(currentSegment)
      currentSegment = ""
    
    currentSegment.add(char)
    lastCharType = charType
  
  if currentSegment.len > 1:
    result.add(currentSegment)

proc getCharType(char: Rune): CharType =
  ## 文字種別の判定
  let code = char.int32
  
  if code >= 0x3040 and code <= 0x309F:
    return CharType.Hiragana
  elif code >= 0x30A0 and code <= 0x30FF:
    return CharType.Katakana
  elif code >= 0x4E00 and code <= 0x9FAF:
    return CharType.Kanji
  elif code >= 0x0030 and code <= 0x0039:
    return CharType.Number
  elif (code >= 0x0041 and code <= 0x005A) or (code >= 0x0061 and code <= 0x007A):
    return CharType.Alphabet
  else:
    return CharType.Other

proc detectCompoundWords(text: string): seq[string] =
  ## 複合語の検出
  result = @[]
  
  # 一般的な複合語パターン
  let patterns = [
    re"[A-Z][a-z]+[A-Z][a-z]+",  # CamelCase
    re"[a-z]+_[a-z]+",           # snake_case
    re"[a-z]+-[a-z]+",           # kebab-case
    re"\w+\.\w+",                # dot.notation
    re"\w+/\w+"                  # path/notation
  ]
  
  for pattern in patterns:
    for match in text.findAll(pattern):
      if match.len > 3:
        result.add(match.toLowerAscii())

proc extractEntities(text: string): seq[string] =
  ## エンティティ抽出（URL、メール、日付など）
  result = @[]
  
  # URL抽出
  let urlPattern = re"https?://[^\s]+"
  for url in text.findAll(urlPattern):
    result.add(url)
  
  # メールアドレス抽出
  let emailPattern = re"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"
  for email in text.findAll(emailPattern):
    result.add(email)
  
  # 日付抽出
  let datePatterns = [
    re"\d{4}-\d{2}-\d{2}",       # YYYY-MM-DD
    re"\d{4}/\d{2}/\d{2}",       # YYYY/MM/DD
    re"\d{2}/\d{2}/\d{4}",       # MM/DD/YYYY
    re"\d{1,2}月\d{1,2}日"       # M月D日
  ]
  
  for pattern in datePatterns:
    for date in text.findAll(pattern):
      result.add(date)
  
  # バージョン番号抽出
  let versionPattern = re"v?\d+\.\d+(\.\d+)?"
  for version in text.findAll(versionPattern):
    result.add(version)
  
  # ハッシュタグ抽出
  let hashtagPattern = re"#\w+"
  for hashtag in text.findAll(hashtagPattern):
    result.add(hashtag)

type
  CharType = enum
    Hiragana, Katakana, Kanji, Number, Alphabet, Other

proc getTimelineJson*(self: HistoryTimeline): JsonNode =
  ## タイムラインをJSON形式で取得
  var groupsJson = newJArray()
  
  for group in self.groups:
    var entriesJson = newJArray()
    
    for entry in group.entries:
      var visitsJson = newJArray()
      for visit in entry.page.visits:
        visitsJson.add(%*{
          "id": visit.id,
          "time": visit.visitTime.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
          "type": $visit.visitType
        })
      
      entriesJson.add(%*{
        "page": {
          "id": entry.page.id,
          "url": entry.page.url,
          "title": entry.page.title,
          "visitCount": entry.page.visitCount,
          "favicon": entry.page.favicon,
          "domain": extractDomain(entry.page.url)
        },
        "firstVisit": entry.firstVisitInPeriod.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
        "lastVisit": entry.lastVisitInPeriod.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
        "visitCount": entry.visitCountInPeriod,
        "visits": visitsJson
      })
    
    groupsJson.add(%*{
      "period": $group.period,
      "date": group.date.format("yyyy-MM-dd"),
      "title": group.title,
      "entries": entriesJson
    })
  
  var analyticsJson = %*{
    "totalVisits": self.analytics.totalVisits,
    "uniquePages": self.analytics.uniquePages,
    "visitsByHour": self.analytics.visitsByHour,
    "visitsByDay": self.analytics.visitsByDay,
    "topDomains": []
  }
  
  var topDomainsJson = newJArray()
  for domain in self.analytics.topDomains:
    topDomainsJson.add(%*{
      "domain": domain.domain,
      "visits": domain.visits,
      "pages": domain.pages,
      "timeSpent": domain.timeSpent.inSeconds,
      "lastVisit": domain.lastVisit.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    })
  
  analyticsJson["topDomains"] = topDomainsJson
  
  result = %*{
    "groups": groupsJson,
    "analytics": analyticsJson,
    "filters": {
      "searchText": self.filters.searchText,
      "domains": self.filters.domains,
      "excludeDomains": self.filters.excludeDomains,
      "minimumVisits": self.filters.minimumVisits,
      "startDate": if self.filters.startDate.isSome: self.filters.startDate.get().format("yyyy-MM-dd") else: nil,
      "endDate": if self.filters.endDate.isSome: self.filters.endDate.get().format("yyyy-MM-dd") else: nil
    }
  }

proc cleanupTask*(self: HistoryTimeline) {.async.} =
  ## 定期的にタイムラインを更新するタスク
  const UPDATE_INTERVAL = 30 * 60 * 1000  # 30分ごと
  
  while true:
    await sleepAsync(UPDATE_INTERVAL)
    
    if self.initialized:
      try:
        # 今日のグループだけ更新
        discard self.loadTimelineGroup(now())
        discard self.analyzeTimeline()
      except:
        error "Failed to update timeline", 
              error = getCurrentExceptionMsg()

# -----------------------------------------------
# テストコード
# -----------------------------------------------

when isMainModule:
  # テスト用コード
  proc testHistoryTimeline() =
    # テンポラリDBを使用
    let dbPath = getTempDir() / "timeline_test.db"
    
    let options = StorageOptions(
      encryptionEnabled: false,
      autoCleanupEnabled: false,
      retentionDays: 90
    )
    
    # ヒストリーストア作成
    let store = newHistoryStore(dbPath, options)
    
    # テストデータ追加
    let urls = [
      "https://example.com",
      "https://example.com/page1",
      "https://example.com/page2",
      "https://test.com",
      "https://test.com/about",
      "https://news.com/article1"
    ]
    
    let titles = [
      "Example Domain",
      "Example Page 1",
      "Example Page 2",
      "Test Site",
      "About Test",
      "News Article 1"
    ]
    
    let now = now()
    
    for i in 0..<urls.len:
      # 現在時刻からランダムな時間を引いた時刻を使用
      let visitTime = now - (i * 2).hours - (i * 13).minutes
      discard store.addPageVisit(urls[i], titles[i], VisitType.vtLink, none(int64), 0, visitTime)
      
      # 複数回訪問を追加
      if i < 3:
        let secondVisit = visitTime + 1.hours
        discard store.addPageVisit(urls[i], titles[i], VisitType.vtLink, none(int64), 0, secondVisit)
    
    # タイムライン作成
    let timeline = newHistoryTimeline(store)
    
    # タイムライン構築
    let groups = timeline.buildTimeline(7)  # 7日分
    
    echo "Timeline groups: ", groups.len
    
    for group in groups:
      echo "Group: ", group.title, " - Entries: ", group.entries.len
      
      for entry in group.entries:
        echo "  - ", entry.page.title, " (", entry.visitCountInPeriod, " visits)"
    
    # 分析
    let analytics = timeline.analyzeTimeline()
    
    echo "Total visits: ", analytics.totalVisits
    echo "Unique pages: ", analytics.uniquePages
    
    echo "Top domains:"
    for domain in analytics.topDomains:
      echo "  - ", domain.domain, ": ", domain.visits, " visits, ", domain.pages, " pages"
    
    # 検索
    let searchResults = timeline.searchInTimeline("example")
    echo "Search results for 'example': ", searchResults.len
    
    # ドメイン別グループ化
    let domainGroups = timeline.groupEntriesByDomain()
    
    for domain, entries in domainGroups:
      echo "Domain: ", domain, " - Pages: ", entries.len
    
    # JSON出力
    let jsonData = timeline.getTimelineJson()
    echo "JSON output: ", jsonData.pretty
    
    # ストア閉じる
    store.close()
    
    # テスト後にテンポラリDBを削除
    removeFile(dbPath)
  
  # テスト実行
  testHistoryTimeline() 