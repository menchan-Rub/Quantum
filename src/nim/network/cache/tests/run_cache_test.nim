import std/[times, tables, strutils, options, unittest]
import ./test_cache

when isMainModule:
  echo "キャッシュのテストを開始します..."
  
  # テストを実行
  testMemoryCache()
  testDiskCache()
  testHttpCacheManager()
  testCachePolicy()
  
  echo "キャッシュのテストが完了しました。" 