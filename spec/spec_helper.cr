# spec/spec_helper.cr
# テスト共通設定とコード読み込み
require "spec"

# srcをテスト時に読み込む
require "../src/crystal/quantum_core/page"
require "../src/crystal/quantum_core/engine"
require "../src/crystal/quantum_core/resource_scheduler"
require "../src/crystal/quantum_core/security_context"
require "../src/crystal/browser/app/quantum_browser" 