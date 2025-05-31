# ブックマーク同期機能
# 
# 特徴:
# - エンドツーエンド暗号化によるセキュアな同期
# - 効率的な差分同期アルゴリズム
# - 自動競合解決
# - オフライン対応と再同期
# - バッテリー効率を考慮した同期スケジューリング

import std/[asyncdispatch, options, tables, times, json, strutils, strformat, os, base64, sets, hashes]
import std/[algorithm, sequtils, sugar, random, math]
import ../../quantum_shield/certificates/store
import ../../quantum_net/security/tls/tls_config
import ../bookmarks/manager.nim/bookmarks_manager
import ../../quantum_arch/data/compression
import ../../quantum_arch/ipc/messaging
import ../../utils/crypto_utils
import ../../utils/diff_utils
import ../../utils/time_utils
import ../storage
import ../../logging/logger

type
  SyncDirection* = enum
    sdUpload,      # ローカルからリモートへ
    sdDownload,    # リモートからローカルへ
    sdBidirectional # 双方向同期

  SyncState* = enum
    ssIdle,        # アイドル状態
    ssPreparing,   # 同期準備中
    ssSyncing,     # 同期中
    ssConflictResolution, # 競合解決中
    ssError        # エラー状態

  SyncConfig* = object
    enabled*: bool                     # 同期が有効かどうか
    interval*: int                     # 同期間隔（分）
    serverUrl*: string                 # 同期サーバーURL
    authToken*: string                 # 認証トークン
    encryptionEnabled*: bool           # E2E暗号化の有効/無効
    encryptionKey*: string             # 暗号化キー（ユーザー提供のパスフレーズから生成）
    autoResolveConflicts*: bool        # 競合の自動解決
    syncOnlyOnWifi*: bool              # WiFi接続時のみ同期
    batteryOptimization*: bool         # バッテリー最適化（低バッテリー時は同期延期）
    maxRetries*: int                   # 同期失敗時の最大リトライ回数
    compressionEnabled*: bool          # データ圧縮の有効/無効
  
  BookmarkChangeType* = enum
    bctAdd,        # ブックマーク追加
    bctModify,     # ブックマーク更新
    bctDelete,     # ブックマーク削除
    bctMove        # ブックマーク移動
  
  BookmarkChange* = object
    id*: string                        # 変更ID (UUID)
    bookmarkId*: string                # 対象ブックマークID
    timestamp*: Time                   # 変更タイムスタンプ
    deviceId*: string                  # 変更を行ったデバイスのID
    case changeType*: BookmarkChangeType
    of bctAdd, bctModify:
      bookmark*: Bookmark              # 追加/更新後のブックマーク
    of bctDelete:
      discard                          # 削除の場合は追加情報不要
    of bctMove:
      parentId*: string                # 移動先の親フォルダID
      index*: int                      # 移動先のインデックス
  
  SyncResult* = object
    success*: bool                     # 同期成功したか
    timestamp*: Time                   # 同期完了時間
    uploadedChanges*: int              # アップロードされた変更数
    downloadedChanges*: int            # ダウンロードされた変更数
    conflicts*: int                    # 検出された競合数
    resolvedConflicts*: int            # 解決された競合数
    errorMessage*: string              # エラーメッセージ（失敗時）
  
  ConflictResolutionStrategy* = enum
    crsLocalWins,  # ローカルの変更を優先
    crsRemoteWins, # リモートの変更を優先
    crsNewerWins,  # 新しい方を優先
    crsManual      # 手動解決
  
  SyncConflict* = object
    bookmarkId*: string                # 競合するブックマークID
    localChange*: BookmarkChange       # ローカルの変更
    remoteChange*: BookmarkChange      # リモートの変更
    resolutionStrategy*: ConflictResolutionStrategy # 解決戦略
  
  BookmarkSyncManager* = ref object
    config*: SyncConfig                # 同期設定
    bookmarkManager*: BookmarkManager  # ブックマークマネージャー
    state*: SyncState                  # 現在の同期状態
    lastSync*: Option[Time]            # 最後の同期時間
    lastSyncResult*: Option[SyncResult] # 最後の同期結果
    deviceId*: string                  # このデバイスの一意のID
    pendingChanges*: seq[BookmarkChange] # 保留中の変更（オフライン時など）
    changeLog*: seq[BookmarkChange]    # 同期用変更ログ
    serverVersion*: int64              # サーバー側の最新バージョン番号
    localVersion*: int64               # ローカルの最新バージョン番号
    encryptionHandler*: EncryptionHandler # E2E暗号化ハンドラ
    syncLock*: AsyncLock               # 同期処理の排他制御用ロック
    syncTimer*: Option[AsyncTimer]     # 定期同期用タイマー

  EncryptionHandler* = ref object
    enabled*: bool                     # 暗号化の有効/無効
    keyData*: array[32, byte]          # 256-bit暗号化キー
    ivSize*: int                       # 初期化ベクトルサイズ
    algorithm*: string                 # 暗号化アルゴリズム (例: "AES-256-GCM")

# ハッシュ関数
proc hash*(change: BookmarkChange): Hash =
  var h: Hash = 0
  h = h !& hash(change.id)
  h = h !& hash(change.bookmarkId)
  h = h !& hash(change.timestamp.toUnix())
  h = h !& hash(change.deviceId)
  h = h !& hash(ord(change.changeType))
  return !$h

# 暗号化ハンドラーの作成
proc newEncryptionHandler*(key: string, enabled: bool = true): EncryptionHandler =
  result = EncryptionHandler(
    enabled: enabled,
    ivSize: 12,  # GCMモードに適した初期化ベクトル長
    algorithm: "AES-256-GCM"
  )
  
  if enabled:
    # パスフレーズからキーを導出（PBKDF2を想定）
    result.keyData = pbkdf2Sha256(key, "quantum_bookmark_sync_salt", 10000, 32)

# データの暗号化
proc encrypt*(handler: EncryptionHandler, data: string): string =
  if not handler.enabled:
    return data
  
  # ランダムなIVを生成
  var iv = newSeq[byte](handler.ivSize)
  for i in 0..<handler.ivSize:
    iv[i] = byte(rand(255))
  
  # データを暗号化
  let encrypted = aesGcmEncrypt(data, handler.keyData, iv)
  
  # IV + 暗号文を結合して返す
  result = base64.encode(iv & encrypted)

# データの復号化
proc decrypt*(handler: EncryptionHandler, encryptedData: string): string =
  if not handler.enabled:
    return encryptedData
  
  # Base64デコード
  let rawData = base64.decode(encryptedData)
  
  # IVと暗号文を分離
  let iv = rawData[0..<handler.ivSize]
  let ciphertext = rawData[handler.ivSize..^1]
  
  # 復号化
  result = aesGcmDecrypt(ciphertext, handler.keyData, iv)

# BookmarkSyncManagerの初期化
proc newBookmarkSyncManager*(bookmarkManager: BookmarkManager, config: SyncConfig): BookmarkSyncManager =
  result = BookmarkSyncManager(
    config: config,
    bookmarkManager: bookmarkManager,
    state: ssIdle,
    deviceId: getDeviceId(),  # デバイスID取得関数（実装が必要）
    pendingChanges: @[],
    changeLog: @[],
    serverVersion: 0,
    localVersion: 0,
    syncLock: newAsyncLock(),
    encryptionHandler: newEncryptionHandler(config.encryptionKey, config.encryptionEnabled)
  )
  
  # 前回の同期情報を読み込む
  try:
    result.loadSyncState()
  except:
    logError("前回の同期状態の読み込みに失敗しました: " & getCurrentExceptionMsg())
  
  # 定期同期タイマーのセットアップ
  if config.enabled and config.interval > 0:
    result.setupSyncTimer()

# デバイスIDの取得（ハードウェア固有のIDを使用）
proc getDeviceId*(): string =
  ## ハードウェア固有のIDを取得してデバイスIDを生成する
  ##
  ## 各プラットフォーム向けにネイティブ実装を提供
  ## Returns:
  ## - デバイスの一意識別子

  const storagePath = getAppDir() / "data" / "device_id.txt"
  
  # 既存のデバイスIDがあれば再利用
  if fileExists(storagePath):
    try:
      result = readFile(storagePath).strip()
      if result.len > 0:
        return result
    except:
      # ファイル読み込み失敗時は新規作成
      discard
  
  # 新しいデバイスIDの生成 - プラットフォーム別実装
  when defined(windows):
    # Windows向け実装
    import winim/lean
    
    proc getWindowsHardwareId(): string =
      const bufferSize = 256
      var volumeName = newString(bufferSize)
      var volumeSerial: DWORD
      var maxComponentLength: DWORD
      var fsFlags: DWORD
      var fsName = newString(bufferSize)
      
      # システムドライブ情報を取得
      if GetVolumeInformationA(
        "C:\\",
        cast[LPSTR](addr volumeName[0]), 
        DWORD(bufferSize),
        addr volumeSerial,
        addr maxComponentLength,
        addr fsFlags,
        cast[LPSTR](addr fsName[0]),
        DWORD(bufferSize)
      ) == 0:
        return ""
      
      # MACアドレス取得
      var buffer = newSeq[byte](6)
      var adapterInfo: IP_ADAPTER_INFO
      var adapterInfoSize: ULONG = sizeof(IP_ADAPTER_INFO).ULONG
      
      if GetAdaptersInfo(addr adapterInfo, addr adapterInfoSize) == ERROR_BUFFER_OVERFLOW:
        var pAdapterInfo = cast[PIP_ADAPTER_INFO](alloc(adapterInfoSize))
        defer: dealloc(pAdapterInfo)
        
        if GetAdaptersInfo(pAdapterInfo, addr adapterInfoSize) == NO_ERROR:
          var currentAdapter = pAdapterInfo
          for i in 0..<6:
            buffer[i] = currentAdapter.Address[i]
      
      # CPUID情報取得
      var cpuVendor = newString(13)
      var cpuInfo: array[4, int32]
      
      when defined(amd64) or defined(i386):
        {.emit: """
        __cpuid(cpuInfo, 0);
        *((int32_t*)cpuVendor) = cpuInfo[1];
        *((int32_t*)(cpuVendor+4)) = cpuInfo[3];
        *((int32_t*)(cpuVendor+8)) = cpuInfo[2];
        cpuVendor[12] = '\0';
        """.}
      
      # 収集したハードウェア情報を組み合わせて固有IDを生成
      let hwInfo = $volumeSerial & ":" & buffer.toHex() & ":" & cpuVendor
      return hmacSha256($hwInfo, "quantum_device_id_salt")
    
    result = getWindowsHardwareId()
  
  elif defined(macosx):
    # macOS向け実装
    import posix
    
    proc getMacOSHardwareId(): string =
      # IOKit呼び出しを行うためのFFI定義
      {.emit: """
      #include <CoreFoundation/CoreFoundation.h>
      #include <IOKit/IOKitLib.h>
      
      char* getMacSerialNumber() {
          io_service_t platformExpert = IOServiceGetMatchingService(
              kIOMasterPortDefault,
              IOServiceMatching("IOPlatformExpertDevice"));
          
          if (platformExpert) {
              CFTypeRef serialNumberAsCFString = IORegistryEntryCreateCFProperty(
                  platformExpert,
                  CFSTR("IOPlatformSerialNumber"),
                  kCFAllocatorDefault, 0);
              
              if (serialNumberAsCFString) {
                  char buffer[256];
                  CFStringGetCString(serialNumberAsCFString,
                                     buffer, sizeof(buffer),
                                     kCFStringEncodingUTF8);
                  CFRelease(serialNumberAsCFString);
                  IOObjectRelease(platformExpert);
                  
                  char* result = (char*)malloc(strlen(buffer) + 1);
                  strcpy(result, buffer);
                  return result;
              }
              
              IOObjectRelease(platformExpert);
          }
          
          return NULL;
      }
      """.}
      
      proc getMacSerialNumber(): cstring {.importc, nodecl.}
      
      # デバイス固有のハードウェアシリアル番号取得
      let serialNumber = $getMacSerialNumber()
      
      # ホスト名取得
      var hostname = newString(256)
      discard gethostname(cstring(hostname), 256)
      hostname.setLen(hostname.cstring.len)
      
      # システムUUID取得の呼び出し
      {.emit: """
      #include <IOKit/IOKitLib.h>
      
      char* getSystemUUID() {
          io_registry_entry_t ioRegistryRoot = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/");
          CFStringRef uuidCf = (CFStringRef)IORegistryEntryCreateCFProperty(
              ioRegistryRoot,
              CFSTR("IOPlatformUUID"),
              kCFAllocatorDefault, 0);
          
          IOObjectRelease(ioRegistryRoot);
          
          if (uuidCf) {
              char buffer[128];
              CFStringGetCString(uuidCf, buffer, sizeof(buffer), kCFStringEncodingUTF8);
              CFRelease(uuidCf);
              
              char* result = (char*)malloc(strlen(buffer) + 1);
              strcpy(result, buffer);
              return result;
          }
          
          return NULL;
      }
      """.}
      
      proc getSystemUUID(): cstring {.importc, nodecl.}
      let systemUUID = $getSystemUUID()
      
      # 収集したハードウェア情報を組み合わせて固有IDを生成
      let hwInfo = serialNumber & ":" & hostname & ":" & systemUUID
      return hmacSha256(hwInfo, "quantum_device_id_salt")
    
    result = getMacOSHardwareId()
  
  elif defined(linux):
    # Linux向け実装
    import posix
    
    proc getLinuxHardwareId(): string =
      # マシンIDの読み取り (/etc/machine-id または /var/lib/dbus/machine-id)
      var machineId = ""
      try:
        if fileExists("/etc/machine-id"):
          machineId = readFile("/etc/machine-id").strip()
        elif fileExists("/var/lib/dbus/machine-id"):
          machineId = readFile("/var/lib/dbus/machine-id").strip()
      except:
        # ファイル読み込み失敗時は他の情報で代替
        discard
      
      # DMIのシステム情報を取得
      var systemUUID = ""
      try:
        if fileExists("/sys/class/dmi/id/product_uuid"):
          systemUUID = readFile("/sys/class/dmi/id/product_uuid").strip()
      except:
        discard
      
      # ホスト名取得
      var hostname = newString(256)
      discard gethostname(cstring(hostname), 256)
      hostname.setLen(hostname.cstring.len)
      
      # CPUの情報を取得
      var cpuInfo = ""
      try:
        let cpuInfoFile = readFile("/proc/cpuinfo")
        let lines = cpuInfoFile.splitLines()
        for line in lines:
          if line.startsWith("processor") or line.startsWith("model name") or
             line.startsWith("physical id") or line.startsWith("core id"):
            cpuInfo.add(line)
      except:
        discard
      
      # 収集したハードウェア情報を組み合わせて固有IDを生成
      let hwInfo = machineId & ":" & systemUUID & ":" & hostname & ":" & cpuInfo
      return hmacSha256(hwInfo, "quantum_device_id_salt")
    
    result = getLinuxHardwareId()
  
  elif defined(android):
    # Android向け実装
    {.emit: """
    #include <jni.h>
    
    extern JavaVM* javaVM;
    
    char* getAndroidDeviceId() {
        JNIEnv* env;
        (*javaVM)->GetEnv(javaVM, (void**)&env, JNI_VERSION_1_6);
        
        jclass contextClass = (*env)->FindClass(env, "android/content/Context");
        jmethodID getSystemServiceMethod = (*env)->GetMethodID(
            env, contextClass, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
        
        jclass settings = (*env)->FindClass(env, "android/provider/Settings$Secure");
        jmethodID getString = (*env)->GetStaticMethodID(
            env, settings, "getString", 
            "(Landroid/content/ContentResolver;Ljava/lang/String;)Ljava/lang/String;");
        
        jobject activity = /* current activity pointer from app context */;
        jstring serviceType = (*env)->NewStringUTF(env, "content");
        jobject contentResolver = (*env)->CallObjectMethod(
            env, activity, getSystemServiceMethod, serviceType);
        
        jstring name = (*env)->NewStringUTF(env, "android_id");
        jstring id = (jstring)(*env)->CallStaticObjectMethod(
            env, settings, getString, contentResolver, name);
        
        const char* idChars = (*env)->GetStringUTFChars(env, id, NULL);
        char* result = strdup(idChars);
        
        (*env)->ReleaseStringUTFChars(env, id, idChars);
        (*env)->DeleteLocalRef(env, id);
        (*env)->DeleteLocalRef(env, name);
        (*env)->DeleteLocalRef(env, contentResolver);
        (*env)->DeleteLocalRef(env, serviceType);
        
        return result;
    }
    """.}
    
    proc getAndroidDeviceId(): cstring {.importc, nodecl.}
    result = $getAndroidDeviceId()
  
  else:
    # その他のプラットフォーム - フォールバック実装
    # 一意のID生成にいくつかの環境情報を使用
    var fallbackInfo = ""
    
    # ホスト名取得
    var hostname = newString(256)
    discard gethostname(cstring(hostname), 256)
    hostname.setLen(hostname.cstring.len)
    fallbackInfo.add(hostname)
    
    # 環境変数
    for envVar in ["USER", "HOME", "LANG", "SHELL", "TERM"]:
      try:
        let value = getEnv(envVar)
        if value.len > 0:
          fallbackInfo.add(":" & value)
      except:
        discard
    
    # カレントディレクトリ
    try:
      fallbackInfo.add(":" & getCurrentDir())
    except:
      discard
    
    # 実行ファイルのパス
    try:
      fallbackInfo.add(":" & getAppFilename())
    except:
      discard
    
    # タイムスタンプを追加（初回生成時にのみ影響）
    fallbackInfo.add(":" & $getTime().toUnix())
    
    # ランダム要素を追加（初回生成時にのみ影響）
    var r = initRand()
    fallbackInfo.add(":" & $r.rand(high(int)))
    
    # ハッシュ化して固有IDを生成
    result = hmacSha256(fallbackInfo, "quantum_device_id_salt")
  
  # 確実に値が得られなかった場合はUUIDフォールバック
  if result.len == 0:
    result = $genUUID()
  
  # ハッシュ結果をUUID形式で整形
  if result.len >= 32:
    result = result[0..7] & "-" & result[8..11] & "-" & 
             result[12..15] & "-" & result[16..19] & "-" & result[20..31]
  
  # 生成されたIDを保存
  try:
    createDir(getAppDir() / "data")
    writeFile(storagePath, result)
  except:
    logError("デバイスIDの保存に失敗しました: " & getCurrentExceptionMsg())
  
  return result

# 同期タイマーのセットアップ
proc setupSyncTimer*(manager: BookmarkSyncManager) =
  if manager.syncTimer.isSome:
    manager.syncTimer.get().cancel()
  
  let timer = newAsyncTimer(interval = manager.config.interval * 60 * 1000)
  manager.syncTimer = some(timer)
  
  asyncCheck (proc() {.async.} =
    while true:
      await timer.waitForNextTick()
      # システム状態チェック（バッテリー、ネットワークなど）
      if manager.shouldSync():
        try:
          await manager.synchronize()
        except:
          logError("自動同期中にエラーが発生しました: " & getCurrentExceptionMsg())
  )()

# 同期すべきかのチェック（バッテリーやネットワーク状態に基づく）
proc shouldSync*(manager: BookmarkSyncManager): bool =
  if not manager.config.enabled:
    return false
  
  let batteryLevel = getBatteryLevel()  # 実装が必要
  let isWifiConnected = isWifiConnected()  # 実装が必要
  
  # バッテリー最適化が有効で、バッテリーレベルが低い場合は同期しない
  if manager.config.batteryOptimization and batteryLevel < 0.15:
    return false
  
  # WiFi接続時のみ同期が有効で、WiFiに接続していない場合は同期しない
  if manager.config.syncOnlyOnWifi and not isWifiConnected:
    return false
  
  return true

# バッテリーレベルの取得
proc getBatteryLevel*(): float =
  # OSからバッテリーレベルを取得する実装
  # デモでは80%として返す
  return 0.8

# WiFi接続状態の確認
proc isWifiConnected*(): bool =
  # ネットワーク接続タイプの確認実装
  # デモでは接続されているとして返す
  return true

# 同期状態の保存
proc saveSyncState*(manager: BookmarkSyncManager) =
  let stateObj = %*{
    "lastSync": manager.lastSync.map(t => t.toIsoString()).get(""),
    "serverVersion": manager.serverVersion,
    "localVersion": manager.localVersion,
    "pendingChanges": manager.pendingChanges.map(c => c.toJson())
  }
  
  try:
    let stateFile = getStoragePath() / "bookmark_sync_state.json"
    writeFile(stateFile, $stateObj)
  except:
    logError("同期状態の保存に失敗しました: " & getCurrentExceptionMsg())

# 同期状態の読み込み
proc loadSyncState*(manager: BookmarkSyncManager) =
  let stateFile = getStoragePath() / "bookmark_sync_state.json"
  if not fileExists(stateFile):
    return
  
  try:
    let stateJson = parseJson(readFile(stateFile))
    
    let lastSyncStr = stateJson["lastSync"].getStr("")
    if lastSyncStr.len > 0:
      manager.lastSync = some(parseIsoString(lastSyncStr))
    
    manager.serverVersion = stateJson["serverVersion"].getInt(0)
    manager.localVersion = stateJson["localVersion"].getInt(0)
    
    manager.pendingChanges = @[]
    for change in stateJson["pendingChanges"]:
      manager.pendingChanges.add(parseBookmarkChange(change))
  except:
    logError("同期状態の読み込みに失敗しました: " & getCurrentExceptionMsg())

# 変更をJSONに変換
proc toJson*(change: BookmarkChange): JsonNode =
  result = %*{
    "id": change.id,
    "bookmarkId": change.bookmarkId,
    "timestamp": change.timestamp.toIsoString(),
    "deviceId": change.deviceId,
    "changeType": $change.changeType
  }
  
  case change.changeType
  of bctAdd, bctModify:
    result["bookmark"] = change.bookmark.toJson()
  of bctDelete:
    discard
  of bctMove:
    result["parentId"] = change.parentId
    result["index"] = %change.index

# JSONから変更を解析
proc parseBookmarkChange*(json: JsonNode): BookmarkChange =
  let changeType = parseEnum[BookmarkChangeType](json["changeType"].getStr())
  
  result = BookmarkChange(
    id: json["id"].getStr(),
    bookmarkId: json["bookmarkId"].getStr(),
    timestamp: parseIsoString(json["timestamp"].getStr()),
    deviceId: json["deviceId"].getStr(),
    changeType: changeType
  )
  
  case changeType
  of bctAdd, bctModify:
    result.bookmark = parseBookmark(json["bookmark"])
  of bctDelete:
    discard
  of bctMove:
    result.parentId = json["parentId"].getStr()
    result.index = json["index"].getInt()

# ISO 8601形式の文字列からTimeへの変換
proc parseIsoString*(isoStr: string): Time =
  # ISO 8601形式（例：2023-05-20T15:30:45Z）の文字列をパース
  try:
    result = parse(isoStr, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
  except:
    result = getTime()  # パース失敗時は現在時刻を返す

# TimeをISO 8601形式の文字列に変換
proc toIsoString*(t: Time): string =
  return t.utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")

# ブックマークの変更をログに記録
proc logChange*(manager: BookmarkSyncManager, change: BookmarkChange) =
  manager.changeLog.add(change)
  manager.localVersion += 1
  
  # 次回の同期のために変更を保存
  if manager.state != ssSyncing:
    manager.pendingChanges.add(change)
    manager.saveSyncState()

# 同期の実行
proc synchronize*(manager: BookmarkSyncManager, direction: SyncDirection = sdBidirectional): Future[SyncResult] {.async.} =
  # 同時に複数の同期が実行されないようにロック
  await manager.syncLock.acquire()
  defer: manager.syncLock.release()
  
  if manager.state == ssSyncing:
    return SyncResult(
      success: false,
      timestamp: getTime(),
      errorMessage: "同期は既に実行中です"
    )
  
  var result = SyncResult(
    success: false,
    timestamp: getTime(),
    uploadedChanges: 0,
    downloadedChanges: 0,
    conflicts: 0,
    resolvedConflicts: 0
  )
  
  manager.state = ssPreparing
  try:
    # サーバー接続確認
    if not await manager.checkServerConnection():
      result.errorMessage = "サーバーに接続できません"
      return result
    
    manager.state = ssSyncing
    
    # アップロード（ローカルからリモートへ）
    if direction in {sdUpload, sdBidirectional}:
      let uploadResult = await manager.uploadChanges()
      result.uploadedChanges = uploadResult.uploadedChanges
    
    # ダウンロード（リモートからローカルへ）
    if direction in {sdDownload, sdBidirectional}:
      let downloadResult = await manager.downloadChanges()
      result.downloadedChanges = downloadResult.downloadedChanges
      result.conflicts = downloadResult.conflicts
      result.resolvedConflicts = downloadResult.resolvedConflicts
    
    # 成功した場合、状態を更新
    result.success = true
    manager.lastSync = some(getTime())
    manager.lastSyncResult = some(result)
    manager.saveSyncState()
    
  except:
    result.errorMessage = getCurrentExceptionMsg()
  finally:
    manager.state = ssIdle
  
  return result

# サーバー接続のチェック
proc checkServerConnection*(manager: BookmarkSyncManager): Future[bool] {.async.} =
  try:
    let url = manager.config.serverUrl & "/api/v1/status"
    let response = await httpGet(url, {"Authorization": "Bearer " & manager.config.authToken})
    
    return response.code == 200
  except:
    logError("サーバー接続確認中にエラーが発生しました: " & getCurrentExceptionMsg())
    return false

# 変更のアップロード
proc uploadChanges*(manager: BookmarkSyncManager): Future[SyncResult] {.async.} =
  var result = SyncResult(
    success: false,
    timestamp: getTime(),
    uploadedChanges: 0
  )
  
  try:
    if manager.pendingChanges.len == 0:
      result.success = true
      return result
    
    # 変更をJSONに変換
    var changesArray = newJArray()
    for change in manager.pendingChanges:
      let changeJson = change.toJson()
      changesArray.add(changeJson)
    
    let payload = %*{
      "deviceId": manager.deviceId,
      "clientVersion": manager.localVersion,
      "serverVersion": manager.serverVersion,
      "changes": changesArray
    }
    
    # E2E暗号化が有効な場合はデータを暗号化
    var uploadData: string
    if manager.config.encryptionEnabled:
      uploadData = manager.encryptionHandler.encrypt($payload)
      uploadData = base64.encode(uploadData)
    else:
      uploadData = $payload
    
    # サーバーにアップロード
    let url = manager.config.serverUrl & "/api/v1/bookmarks/sync"
    let response = await httpPost(
      url, 
      {"Authorization": "Bearer " & manager.config.authToken,
       "Content-Type": "application/json",
       "X-Encrypted": if manager.config.encryptionEnabled: "true" else: "false"},
      uploadData
    )
    
    if response.code != 200:
      result.errorMessage = "サーバーからエラーが返されました: " & response.body
      return result
    
    # レスポンスを解析
    let respJson = parseJson(response.body)
    let serverVersion = respJson["serverVersion"].getInt(0)
    let accepted = respJson["accepted"].getInt(0)
    
    # アップロードが成功したら、保留中の変更をクリア
    manager.pendingChanges = @[]
    manager.serverVersion = serverVersion
    
    result.success = true
    result.uploadedChanges = accepted
    
  except:
    result.errorMessage = "変更のアップロード中にエラーが発生しました: " & getCurrentExceptionMsg()
  
  return result

# 変更のダウンロード
proc downloadChanges*(manager: BookmarkSyncManager): Future[SyncResult] {.async.} =
  var result = SyncResult(
    success: false,
    timestamp: getTime(),
    downloadedChanges: 0,
    conflicts: 0,
    resolvedConflicts: 0
  )
  
  try:
    # サーバーから変更を取得
    let url = manager.config.serverUrl & "/api/v1/bookmarks/changes?since=" & $manager.serverVersion
    let response = await httpGet(
      url, 
      {"Authorization": "Bearer " & manager.config.authToken}
    )
    
    if response.code != 200:
      result.errorMessage = "サーバーからエラーが返されました: " & response.body
      return result
    
    # レスポンスデータの解析
    var respData = response.body
    let isEncrypted = response.headers.getOrDefault("X-Encrypted", "false") == "true"
    
    # 暗号化されている場合は復号化
    if isEncrypted and manager.config.encryptionEnabled:
      let decodedData = base64.decode(respData)
      respData = manager.encryptionHandler.decrypt(decodedData)
    
    let respJson = parseJson(respData)
    let serverVersion = respJson["serverVersion"].getInt(0)
    let changes = respJson["changes"]
    
    # 変更の適用
    var remoteChanges: seq[BookmarkChange] = @[]
    for changeJson in changes:
      let change = parseBookmarkChange(changeJson)
      remoteChanges.add(change)
    
    # 競合検出と解決
    let conflicts = manager.detectConflicts(remoteChanges)
    if conflicts.len > 0:
      manager.state = ssConflictResolution
      let resolvedConflicts = manager.resolveConflicts(conflicts)
      result.conflicts = conflicts.len
      result.resolvedConflicts = resolvedConflicts.len
    
    # 競合のない変更を適用
    for change in remoteChanges:
      # 同じデバイスからの変更は無視
      if change.deviceId == manager.deviceId:
        continue
      
      # 競合チェック（既に解決済みの競合は適用）
      let isConflict = conflicts.anyIt(it.bookmarkId == change.bookmarkId)
      if isConflict:
        continue
      
      # 変更を適用
      manager.applyChange(change)
      result.downloadedChanges += 1
    
    manager.serverVersion = serverVersion
    result.success = true
    
  except:
    result.errorMessage = "変更のダウンロード中にエラーが発生しました: " & getCurrentExceptionMsg()
  
  return result

# 競合の検出
proc detectConflicts*(manager: BookmarkSyncManager, remoteChanges: seq[BookmarkChange]): seq[SyncConflict] =
  result = @[]
  
  # ローカルの変更ログからブックマークIDごとの最新の変更を取得
  var localChangesByBookmarkId = initTable[string, BookmarkChange]()
  for change in manager.changeLog:
    localChangesByBookmarkId[change.bookmarkId] = change
  
  # リモートの変更と競合するものを検出
  for remoteChange in remoteChanges:
    # 同じデバイスからの変更は競合しない
    if remoteChange.deviceId == manager.deviceId:
      continue
    
    if localChangesByBookmarkId.hasKey(remoteChange.bookmarkId):
      let localChange = localChangesByBookmarkId[remoteChange.bookmarkId]
      
      # 同じ変更タイプかつタイムスタンプが同じ場合は競合しない
      if localChange.changeType == remoteChange.changeType and 
         (localChange.timestamp - remoteChange.timestamp).inSeconds.abs < 1:
        continue
      
      # 競合を追加
      let conflictResolutionStrategy = 
        if manager.config.autoResolveConflicts: crsNewerWins
        else: crsManual
      
      result.add(SyncConflict(
        bookmarkId: remoteChange.bookmarkId,
        localChange: localChange,
        remoteChange: remoteChange,
        resolutionStrategy: conflictResolutionStrategy
      ))

# 競合の解決
proc resolveConflicts*(manager: BookmarkSyncManager, conflicts: seq[SyncConflict]): seq[SyncConflict] =
  result = @[]
  
  for conflict in conflicts:
    var resolvedConflict = conflict
    
    # 競合解決戦略に基づいて処理
    case conflict.resolutionStrategy
    of crsLocalWins:
      # ローカルの変更を優先
      resolvedConflict.resolutionStrategy = crsLocalWins
      result.add(resolvedConflict)
      
    of crsRemoteWins:
      # リモートの変更を優先
      manager.applyChange(conflict.remoteChange)
      resolvedConflict.resolutionStrategy = crsRemoteWins
      result.add(resolvedConflict)
      
    of crsNewerWins:
      # 新しい方の変更を優先
      if conflict.localChange.timestamp > conflict.remoteChange.timestamp:
        resolvedConflict.resolutionStrategy = crsLocalWins
      else:
        manager.applyChange(conflict.remoteChange)
        resolvedConflict.resolutionStrategy = crsRemoteWins
      result.add(resolvedConflict)
      
    of crsManual:
      # 手動解決が必要な場合は、結果に含めない（UIで解決を促す）
      discard

# 変更の適用
proc applyChange*(manager: BookmarkSyncManager, change: BookmarkChange) =
  case change.changeType
  of bctAdd:
    let bookmark = change.bookmark
    discard manager.bookmarkManager.addBookmark(
      bookmark.url,
      bookmark.title,
      bookmark.parentId,
      bookmark.tags,
      Some(bookmark.id),  # サーバーからのIDを保持
      Some(bookmark.lastModified)
    )
    
  of bctModify:
    let bookmark = change.bookmark
    discard manager.bookmarkManager.updateBookmark(
      bookmark.id,
      bookmark.title,
      bookmark.url,
      bookmark.tags
    )
    
  of bctDelete:
    discard manager.bookmarkManager.deleteBookmark(change.bookmarkId)
    
  of bctMove:
    discard manager.bookmarkManager.moveBookmark(
      change.bookmarkId,
      change.parentId,
      change.index
    )

# HTTPリクエストのラッパー（エラー処理を統一）
proc httpGet*(url: string, headers: openArray[(string, string)] = []): Future[tuple[code: int, body: string, headers: Table[string, string]]] {.async.} =
  let client = newAsyncHttpClient()
  try:
    for (key, value) in headers:
      client.headers[key] = value
    
    let response = await client.get(url)
    let body = await response.body
    
    var respHeaders = initTable[string, string]()
    for key, val in response.headers.pairs:
      respHeaders[key] = val
    
    return (code: response.code.int, body: body, headers: respHeaders)
  except:
    logError("HTTP GETリクエスト中にエラーが発生しました: " & getCurrentExceptionMsg())
    return (code: 500, body: getCurrentExceptionMsg(), headers: initTable[string, string]())
  finally:
    client.close()

proc httpPost*(url: string, headers: openArray[(string, string)] = [], body: string = ""): Future[tuple[code: int, body: string, headers: Table[string, string]]] {.async.} =
  let client = newAsyncHttpClient()
  try:
    for (key, value) in headers:
      client.headers[key] = value
    
    let response = await client.post(url, body)
    let respBody = await response.body
    
    var respHeaders = initTable[string, string]()
    for key, val in response.headers.pairs:
      respHeaders[key] = val
    
    return (code: response.code.int, body: respBody, headers: respHeaders)
  except:
    logError("HTTP POSTリクエスト中にエラーが発生しました: " & getCurrentExceptionMsg())
    return (code: 500, body: getCurrentExceptionMsg(), headers: initTable[string, string]())
  finally:
    client.close()

# テスト用関数
proc mockSyncProcess*(manager: BookmarkSyncManager): Future[void] {.async.} =
  # テスト用の同期プロセスシミュレーション
  logInfo("ブックマーク同期を開始します...")
  
  let result = await manager.synchronize()
  if result.success:
    logInfo(fmt"同期が成功しました: アップロード {result.uploadedChanges}件, ダウンロード {result.downloadedChanges}件, 競合 {result.conflicts}件 (解決済み {result.resolvedConflicts}件)")
  else:
    logError(fmt"同期に失敗しました: {result.errorMessage}") 