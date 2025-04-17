import std/[os, strutils, strformat, times]
import ./tests/test_cache
import ./tests/cache_integration_test

proc printHeader(text: string) =
  echo "=" * 80
  echo text
  echo "=" * 80

proc runCompilationTests() =
  printHeader("キャッシュモジュールのコンパイルテスト")
  
  let modules = [
    "memory/memory_cache.nim",
    "disk/disk_cache.nim",
    "compression/compression.nim",
    "policy/cache_policy.nim",
    "http_cache_manager.nim"
  ]
  
  var failed = false
  for module in modules:
    let path = getCurrentDir() / module
    let cmd = fmt"nim c -r {path}"
    echo fmt"コンパイル: {module}"
    let exitCode = execShellCmd(cmd)
    if exitCode != 0:
      echo fmt"エラー: {module}のコンパイルに失敗しました（終了コード: {exitCode}）"
      failed = true
    else:
      echo fmt"成功: {module}のコンパイルが完了しました"
  
  if failed:
    echo "警告: 一部のモジュールのコンパイルに失敗しました"
  else:
    echo "すべてのモジュールが正常にコンパイルされました"

proc runUnitTests() =
  printHeader("ユニットテストの実行")
  echo "ユニットテストを開始します..."
  
  # テスト関数を実行
  testMemoryCache()
  testDiskCache()
  testHttpCacheManager()
  testCachePolicy()
  
  echo "ユニットテストが完了しました。"

proc runIntegrationTests() =
  printHeader("統合テストの実行")
  echo "統合テストを開始します..."
  
  # 統合テストを実行
  runTests()
  
  echo "統合テストが完了しました。"

proc cleanupTestDirectories() =
  printHeader("テストディレクトリのクリーンアップ")
  
  let testDirs = [
    "test_cache",
    "eviction_test_cache"
  ]
  
  for dir in testDirs:
    if dirExists(dir):
      try:
        removeDir(dir)
        echo fmt"{dir}ディレクトリを削除しました"
      except:
        echo fmt"警告: {dir}ディレクトリの削除に失敗しました"

proc main() =
  let startTime = epochTime()
  
  printHeader("キャッシュシステムのテストスイート")
  echo "開始時刻: ", format(now(), "yyyy-MM-dd HH:mm:ss")
  
  # テストディレクトリをクリーンアップ
  cleanupTestDirectories()
  
  # コンパイルテスト
  runCompilationTests()
  
  # ユニットテスト
  runUnitTests()
  
  # 統合テスト
  runIntegrationTests()
  
  # テスト完了後のクリーンアップ
  cleanupTestDirectories()
  
  let endTime = epochTime()
  let duration = endTime - startTime
  
  printHeader("テスト完了")
  echo "終了時刻: ", format(now(), "yyyy-MM-dd HH:mm:ss")
  echo fmt"実行時間: {duration:.2f}秒"

when isMainModule:
  main() 