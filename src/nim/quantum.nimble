# Package
version       = "0.1.0"
author        = "Quantum Browser Team"
description   = "超軽量・超高速ブラウザエンジン「QuantumCore」のNim実装部分"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["quantum_browser"]

# Dependencies
requires "nim >= 1.6.10"
requires "karax >= 1.2.2"  # UI フレームワーク
requires "chronos >= 3.0.0"  # 非同期処理
requires "zippy >= 0.10.0"  # 圧縮/解凍
requires "weave >= 0.4.0"  # 並列処理

task test, "Run the test suite":
  exec "nim c -r tests/all_tests"

task bench, "Run benchmarks":
  exec "nim c -d:release --opt:speed -r benchmarks/all_benchmarks"

task docs, "Generate documentation":
  exec "nim doc --project --index:on --git.url:https://github.com/menchan-Rub/Quantum src/quantum_browser.nim" 