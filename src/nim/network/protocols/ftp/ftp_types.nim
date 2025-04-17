## FTP型定義とユーティリティ
##
## File Transfer Protocol（RFC 959）で使用される型定義と
## レスポンス解析などのユーティリティ関数を提供します。

import std/[strutils, times, tables, parseutils, re]

type
  FtpFileType* = enum
    ## FTPファイルタイプ
    ftUnknown,       # 不明
    ftFile,          # 通常ファイル
    ftDirectory,     # ディレクトリ
    ftSymlink,       # シンボリックリンク
    ftCharDevice,    # キャラクタデバイス
    ftBlockDevice,   # ブロックデバイス
    ftFifo,          # FIFO（名前付きパイプ）
    ftSocket         # ソケット
  
  FtpPermissions* = object
    ## FTPファイルパーミッション
    read*: bool        # 読み取り権限
    write*: bool       # 書き込み権限
    execute*: bool     # 実行権限
  
  FtpFileInfo* = object
    ## FTPファイル情報
    name*: string               # ファイル名
    path*: string               # パス
    size*: int64                # サイズ（バイト）
    modificationTime*: Time     # 最終更新時刻
    fileType*: FtpFileType      # ファイルタイプ
    ownerPermissions*: FtpPermissions  # 所有者権限
    groupPermissions*: FtpPermissions  # グループ権限
    otherPermissions*: FtpPermissions  # その他の権限
    owner*: string              # 所有者
    group*: string              # グループ
    linkTarget*: string         # リンク先（シンボリックリンクの場合）
    isHidden*: bool             # 隠しファイルかどうか
  
  FtpResponse* = object
    ## FTPコマンドレスポンス
    code*: int         # レスポンスコード
    message*: string   # レスポンスメッセージ
  
# 正規表現パターン
let
  unixListingPattern = re(r"^([a-z\-]+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(\d+)\s+(\w+\s+\d+\s+(?:\d+|\d+:\d+))\s+(.+?)$", {reIgnoreCase})
  windowsListingPattern = re(r"^(\d{2}-\d{2}-\d{2}\s+\d{2}:\d{2}(?:AM|PM))\s+(<DIR>|\d+)\s+(.+?)$", {reIgnoreCase})

proc parseFtpResponse*(responseStr: string): FtpResponse =
  ## FTPサーバーからのレスポンスを解析する
  ##
  ## 引数:
  ##   responseStr: FTPサーバーからのレスポンス文字列
  ##
  ## 戻り値:
  ##   FtpResponse構造体
  
  let lines = responseStr.splitLines()
  if lines.len == 0:
    return FtpResponse(code: 0, message: "")
  
  var code = 0
  var message = ""
  
  # 最後の有効な行からコードを抽出
  var lastValidLine = ""
  for line in lines:
    if line.len >= 3 and line[0..2].allCharsInSet({'0'..'9'}):
      lastValidLine = line
  
  if lastValidLine.len >= 3:
    try:
      code = parseInt(lastValidLine[0..2])
    except ValueError:
      code = 0
    
    # メッセージを抽出
    if lastValidLine.len >= 4:
      if lastValidLine[3] == ' ' or lastValidLine[3] == '-':
        message = lastValidLine[4..^1]
  
  # マルチライン応答の場合、関連するすべての行を含める
  if lines.len > 1:
    # コード部分を除いた完全なレスポンスを取得
    message = ""
    for line in lines:
      if line.len >= 4:
        message &= line[4..^1] & "\n"
      else:
        message &= line & "\n"
    message = message.strip()
  
  return FtpResponse(code: code, message: message)

proc parseFtpFeatures*(featResponse: string): Table[string, string] =
  ## FTPサーバーの機能リストを解析する
  ##
  ## 引数:
  ##   featResponse: FEATコマンドに対するレスポンス
  ##
  ## 戻り値:
  ##   機能名と値のテーブル
  
  result = initTable[string, string]()
  
  let lines = featResponse.splitLines()
  for line in lines:
    let trimmedLine = line.strip()
    if trimmedLine.len == 0 or trimmedLine[0] == '2':
      continue
    
    # 機能を解析
    let parts = trimmedLine.split(" ", 1)
    if parts.len > 0:
      let feature = parts[0].strip()
      let value = if parts.len > 1: parts[1].strip() else: ""
      result[feature] = value
  
  return result

proc extractHostPortFromPasv*(pasvResponse: string): tuple[host: string, port: int] =
  ## PASVレスポンスからホストとポートを抽出する
  ##
  ## 引数:
  ##   pasvResponse: PASVコマンドに対するレスポンス
  ##
  ## 戻り値:
  ##   (ホスト, ポート)のタプル
  
  # 正規表現でIPアドレスとポートを抽出
  let pattern = re(r"(?:\d{1,3},){4}(\d{1,3}),(\d{1,3})")
  var matches: array[2, string]
  
  if pasvResponse.find(pattern, matches) >= 0:
    try:
      let portHigh = parseInt(matches[0])
      let portLow = parseInt(matches[1])
      let port = (portHigh * 256) + portLow
      
      # IPアドレスを抽出
      let ipPattern = re(r"(\d{1,3}),(\d{1,3}),(\d{1,3}),(\d{1,3})")
      var ipMatches: array[4, string]
      
      if pasvResponse.find(ipPattern, ipMatches) >= 0:
        let host = ipMatches[0] & "." & ipMatches[1] & "." & ipMatches[2] & "." & ipMatches[3]
        return (host, port)
    except:
      discard
  
  return ("", 0)

proc extractPathFromPwd*(pwdResponse: string): string =
  ## PWDレスポンスからパスを抽出する
  ##
  ## 引数:
  ##   pwdResponse: PWDコマンドに対するレスポンス
  ##
  ## 戻り値:
  ##   カレントディレクトリのパス
  
  # 引用符で囲まれたパスを抽出
  let quotePattern = re(r"\"([^\"]+)\"")
  var matches: array[1, string]
  
  if pwdResponse.find(quotePattern, matches) >= 0:
    return matches[0]
  else:
    # 引用符がない場合は空白で分割して最後の部分を使用
    let parts = pwdResponse.split(" ")
    if parts.len > 0:
      return parts[^1]
  
  return "/"

proc parseUnixPermissions(permStr: string): tuple[fileType: FtpFileType, 
                                                  owner: FtpPermissions, 
                                                  group: FtpPermissions, 
                                                  other: FtpPermissions] =
  ## UNIXスタイルのパーミッション文字列を解析する
  ##
  ## 引数:
  ##   permStr: パーミッション文字列（例: "drwxr-xr--"）
  ##
  ## 戻り値:
  ##   (ファイルタイプ, 所有者権限, グループ権限, その他の権限)のタプル
  
  var fileType = ftUnknown
  
  # ファイルタイプを判定
  if permStr.len > 0:
    case permStr[0]
    of '-': fileType = ftFile
    of 'd': fileType = ftDirectory
    of 'l': fileType = ftSymlink
    of 'c': fileType = ftCharDevice
    of 'b': fileType = ftBlockDevice
    of 'p': fileType = ftFifo
    of 's': fileType = ftSocket
    else: fileType = ftUnknown
  
  # 権限を解析
  var owner = FtpPermissions(read: false, write: false, execute: false)
  var group = FtpPermissions(read: false, write: false, execute: false)
  var other = FtpPermissions(read: false, write: false, execute: false)
  
  if permStr.len >= 4:
    owner.read = permStr[1] == 'r'
    owner.write = permStr[2] == 'w'
    owner.execute = permStr[3] == 'x' or permStr[3] == 's' or permStr[3] == 'S'
  
  if permStr.len >= 7:
    group.read = permStr[4] == 'r'
    group.write = permStr[5] == 'w'
    group.execute = permStr[6] == 'x' or permStr[6] == 's' or permStr[6] == 'S'
  
  if permStr.len >= 10:
    other.read = permStr[7] == 'r'
    other.write = permStr[8] == 'w'
    other.execute = permStr[9] == 'x' or permStr[9] == 't' or permStr[9] == 'T'
  
  return (fileType, owner, group, other)

proc parseUnixTimeStamp(timeStr: string): Time =
  ## UNIXスタイルの時刻文字列を解析する
  ##
  ## 引数:
  ##   timeStr: 時刻文字列（例: "Jan 1 2021" or "Jan 1 13:45"）
  ##
  ## 戻り値:
  ##   Time値
  
  # 現在の年を取得
  let currentTime = getTime()
  let currentYear = currentTime.local().year
  
  # 時刻文字列をトークンに分割
  let tokens = timeStr.split()
  if tokens.len < 3:
    return currentTime
  
  # 月を解析
  let monthStr = tokens[0].toLowerAscii()
  let month = case monthStr
    of "jan": 1
    of "feb": 2
    of "mar": 3
    of "apr": 4
    of "may": 5
    of "jun": 6
    of "jul": 7
    of "aug": 8
    of "sep": 9
    of "oct": 10
    of "nov": 11
    of "dec": 12
    else: 1
  
  # 日を解析
  var day: int
  try:
    day = parseInt(tokens[1])
  except:
    day = 1
  
  # 年または時刻を解析
  var year = currentYear
  var hour = 0
  var minute = 0
  
  let timeOrYear = tokens[2]
  if timeOrYear.contains(":"):
    # 時刻の形式
    let timeParts = timeOrYear.split(":")
    try:
      hour = parseInt(timeParts[0])
      if timeParts.len > 1:
        minute = parseInt(timeParts[1])
    except:
      hour = 0
      minute = 0
  else:
    # 年の形式
    try:
      year = parseInt(timeOrYear)
    except:
      year = currentYear
  
  # Time値を作成
  return initDateTime(day = day, month = month, year = year, hour = hour, minute = minute, second = 0, zone = utc()).toTime()

proc parseFtpTimeStamp*(timestamp: string): Time =
  ## FTPサーバーからのタイムスタンプを解析する
  ##
  ## 引数:
  ##   timestamp: MDTMコマンドからのタイムスタンプ（例: "20210101123456"）
  ##
  ## 戻り値:
  ##   Time値
  
  if timestamp.len >= 14:
    try:
      let year = parseInt(timestamp[0..3])
      let month = parseInt(timestamp[4..5])
      let day = parseInt(timestamp[6..7])
      let hour = parseInt(timestamp[8..9])
      let minute = parseInt(timestamp[10..11])
      let second = parseInt(timestamp[12..13])
      
      return initDateTime(day = day, month = Month(month), year = year, hour = hour, minute = minute, second = second, zone = utc()).toTime()
    except:
      return getTime()
  else:
    return getTime()

proc detectListFormat*(listingData: string): FtpListFormat =
  ## リスト形式を検出する
  ##
  ## 引数:
  ##   listingData: LIST/NLST コマンドからのレスポンスデータ
  ##
  ## 戻り値:
  ##   検出されたリスト形式
  
  let lines = listingData.splitLines()
  for line in lines:
    if line.len == 0:
      continue
    
    # UNIXフォーマットをチェック
    if line.match(unixListingPattern):
      return flfUnix
    
    # Windowsフォーマットをチェック
    if line.match(windowsListingPattern):
      return flfWindows
  
  # デフォルトはUNIX
  return flfUnix

proc parseUnixListing(line: string): FtpFileInfo =
  ## UNIXスタイルのリスト行を解析する
  ##
  ## 引数:
  ##   line: リスト行
  ##
  ## 戻り値:
  ##   FtpFileInfo構造体
  
  var matches: array[7, string]
  if not line.match(unixListingPattern, matches):
    return FtpFileInfo()
  
  let permStr = matches[0]
  let linksStr = matches[1]
  let owner = matches[2]
  let group = matches[3]
  let sizeStr = matches[4]
  let dateStr = matches[5]
  let nameStr = matches[6]
  
  # パーミッションを解析
  let (fileType, ownerPerms, groupPerms, otherPerms) = parseUnixPermissions(permStr)
  
  # サイズを解析
  var size: int64 = 0
  try:
    size = parseBiggestInt(sizeStr)
  except:
    size = 0
  
  # 時刻を解析
  let modTime = parseUnixTimeStamp(dateStr)
  
  # ファイル名とリンク先を解析
  var name = nameStr
  var linkTarget = ""
  
  if fileType == ftSymlink and nameStr.contains(" -> "):
    let parts = nameStr.split(" -> ", 1)
    name = parts[0]
    if parts.len > 1:
      linkTarget = parts[1]
  
  # 隠しファイルかどうかをチェック
  let isHidden = name.len > 0 and name[0] == '.'
  
  return FtpFileInfo(
    name: name,
    path: name,
    size: size,
    modificationTime: modTime,
    fileType: fileType,
    ownerPermissions: ownerPerms,
    groupPermissions: groupPerms,
    otherPermissions: otherPerms,
    owner: owner,
    group: group,
    linkTarget: linkTarget,
    isHidden: isHidden
  )

proc parseWindowsListing(line: string): FtpFileInfo =
  ## Windowsスタイルのリスト行を解析する
  ##
  ## 引数:
  ##   line: リスト行
  ##
  ## 戻り値:
  ##   FtpFileInfo構造体
  
  var matches: array[3, string]
  if not line.match(windowsListingPattern, matches):
    return FtpFileInfo()
  
  let dateStr = matches[0]
  let sizeOrDir = matches[1]
  let name = matches[2]
  
  # ファイルタイプを判定
  let fileType = if sizeOrDir == "<DIR>": ftDirectory else: ftFile
  
  # サイズを解析
  var size: int64 = 0
  if fileType == ftFile:
    try:
      size = parseBiggestInt(sizeOrDir)
    except:
      size = 0
  
  # 時刻を解析
  var modTime = getTime()
  try:
    # MM-DD-YY HH:MM{AM|PM} 形式
    let dateParts = dateStr.split("-")
    let timeParts = dateParts[2].split(":")
    
    let yearStr = timeParts[0].split(" ")[0]
    let timeStr = timeParts[0].split(" ")[1]
    let minuteStr = timeParts[1]
    
    var month = parseInt(dateParts[0])
    var day = parseInt(dateParts[1])
    var year = 2000 + parseInt(yearStr)
    var hour = parseInt(timeStr)
    var minute = parseInt(minuteStr.split(/(?:AM|PM)/)[0])
    
    # 12時間制を24時間制に変換
    if minuteStr.contains("PM") and hour < 12:
      hour += 12
    elif minuteStr.contains("AM") and hour == 12:
      hour = 0
    
    modTime = initDateTime(day = day, month = Month(month), year = year, hour = hour, minute = minute, second = 0, zone = utc()).toTime()
  except:
    modTime = getTime()
  
  # 隠しファイルかどうかをチェック
  let isHidden = name.len > 0 and name[0] == '.'
  
  # デフォルトの権限（Windowsリストには権限情報がない）
  let defaultPerms = FtpPermissions(read: true, write: true, execute: fileType == ftDirectory)
  
  return FtpFileInfo(
    name: name,
    path: name,
    size: size,
    modificationTime: modTime,
    fileType: fileType,
    ownerPermissions: defaultPerms,
    groupPermissions: defaultPerms,
    otherPermissions: defaultPerms,
    owner: "",
    group: "",
    linkTarget: "",
    isHidden: isHidden
  )

proc parseFtpListing*(listingData: string, format: FtpListFormat): seq[FtpFileInfo] =
  ## FTPリスティングを解析する
  ##
  ## 引数:
  ##   listingData: LIST/NLST コマンドからのレスポンスデータ
  ##   format: リスト形式
  ##
  ## 戻り値:
  ##   FtpFileInfo構造体のシーケンス
  
  result = @[]
  
  let lines = listingData.splitLines()
  for line in lines:
    if line.len == 0:
      continue
    
    var fileInfo: FtpFileInfo
    
    case format
    of flfUnix:
      fileInfo = parseUnixListing(line)
    of flfWindows:
      fileInfo = parseWindowsListing(line)
    of flfUnknown:
      # 行の形式を自動検出
      if line.match(unixListingPattern):
        fileInfo = parseUnixListing(line)
      elif line.match(windowsListingPattern):
        fileInfo = parseWindowsListing(line)
      else:
        continue
    
    # 有効なエントリーのみを追加
    if fileInfo.name.len > 0:
      result.add(fileInfo)
  
  return result 