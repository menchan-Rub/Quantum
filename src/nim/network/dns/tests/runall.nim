import unittest
import "./test_cache"
import "./test_resolver"

when isMainModule:
  echo "DNSモジュールの全テストを実行中..."
  unittest.run()
  echo "全テスト完了" 