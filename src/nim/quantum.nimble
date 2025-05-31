# Package
version     = "1.1.0"
author      = "Quantum Browser Team"
description = "Quantum Browser Network Layer - World's Fastest HTTP/3 Implementation"
license     = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["quantum_browser"]

# Dependencies
requires "nim >= 1.6.10"
requires "https://github.com/status-im/nim-chronos >= 3.0.0"
requires "https://github.com/status-im/nim-bearssl >= 0.1.0"
requires "https://github.com/status-im/nim-stew >= 0.1.0"
requires "https://github.com/status-im/nim-metrics >= 0.1.0"
requires "zstd >= 0.5.0"
requires "brotli >= 0.3.0"
requires "lz4 >= 1.1.1"
requires "protobuf >= 1.0.0"
requires "flatbuffers >= 0.7.0"
requires "taskpools >= 0.0.3"
requires "cachetools >= 0.3.0"
requires "macrocache >= 0.1.0"

# 追加の依存関係
requires "https://github.com/treeform/zippy >= 0.10.4"  # 高性能圧縮ライブラリ
requires "https://github.com/disruptek/frosty >= 3.0.0" # 高速シリアライゼーション
requires "https://github.com/nim-lang/threading >= 0.1.0" # 並列処理強化
requires "https://github.com/cheatfate/nimcrypto >= 0.5.4" # 暗号化サポート
requires "https://github.com/yglukhov/async_http_request >= 0.2.0" # 非同期HTTP
requires "redis >= 0.3.0" # キャッシュ対応
requires "yaml >= 1.0.0" # 設定サポート
requires "jsony >= 1.1.3" # 高速JSONパーサー
requires "pixie >= 5.0.1" # 画像処理サポート
requires "weave >= 0.4.8" # タスク並列化

task test, "Run the test suite":
  exec "nim c -r tests/all_tests"

task bench, "Run benchmarks":
  exec "nim c -d:release --opt:speed -r benchmarks/all_benchmarks"

task benchmark, "Run HTTP/3 benchmarks":
  exec "nim c -d:release -d:danger --opt:speed -r tests/bench_http3.nim"

task profile, "Profile the HTTP/3 implementation":
  exec "nim c -d:release --profiler:on --stacktrace:on -r tests/profile_http3.nim"

# 強化されたプロトコル実装ビルドタスク
task protocols, "Build protocol implementations":
  exec "nim c -d:release -d:quantum -d:danger --opt:speed src/nim/quantum_net/protocols/quic/quic_client.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed src/nim/quantum_net/protocols/http3/http3_client.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed src/nim/quantum_net/protocols/quic/multipath_quic.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed src/nim/quantum_net/protocols/resource_predictor.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed src/nim/quantum_net/protocols/http3/early_data.nim"

# 圧縮実装ビルドタスク
task compression, "Build compression implementations":
  exec "nim c -d:release -d:quantum src/nim/compression/qpack/qpack_encoder.nim"
  exec "nim c -d:release -d:quantum src/nim/compression/qpack/qpack_decoder.nim"
  exec "nim c -d:release -d:quantum src/nim/compression/brotli/brotli_decoder.nim"
  exec "nim c -d:release -d:quantum src/nim/compression/zstd/zstd_decoder.nim"

# ドキュメント生成タスク
task docs, "Generate documentation":
  exec "nim doc --project --index:on --git.url:https://github.com/quantum-browser/quantum src/nim/quantum_net/protocols/http3/http3_client.nim"
  exec "nim doc --project --index:on --git.url:https://github.com/quantum-browser/quantum src/nim/quantum_net/protocols/quic/multipath_quic.nim"
  exec "nim doc --project --index:on --git.url:https://github.com/quantum-browser/quantum src/nim/quantum_net/protocols/http3/early_data.nim"

# HTTP/3スタックのベンチマーク
task benchmark_http3_stack, "Detailed benchmarking of HTTP/3 stack":
  exec "nim c -d:release -d:quantum -d:danger --opt:speed -r benchmarks/http3/bench_qpack.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed -r benchmarks/http3/bench_stream.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed -r benchmarks/http3/bench_framing.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed -r benchmarks/http3/bench_multipath.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed -r benchmarks/http3/bench_early_data.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed -r benchmarks/http3/bench_resource_prediction.nim"

# QUIC実装のベンチマーク
task benchmark_quic, "Detailed benchmarking of QUIC implementation":
  exec "nim c -d:release -d:quantum -d:danger --opt:speed -r benchmarks/quic/bench_packet.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed -r benchmarks/quic/bench_crypto.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed -r benchmarks/quic/bench_congestion.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed -r benchmarks/quic/bench_multipath.nim"

# パフォーマンステスト
task performance, "Run performance tests against other browsers":
  exec "nim c -d:release -d:quantum -d:danger --opt:speed -r tests/performance/compare_browsers.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed -r tests/performance/http3_vs_http2.nim"
  exec "nim c -d:release -d:quantum -d:danger --opt:speed -r tests/performance/multipath_benchmark.nim"

# コンプライアンステスト
task compliance, "Run RFC compliance tests":
  exec "nim c -d:release -d:quantum -r tests/compliance/rfc9000_tests.nim"
  exec "nim c -d:release -d:quantum -r tests/compliance/rfc9114_tests.nim"
  exec "nim c -d:release -d:quantum -r tests/compliance/rfc9204_tests.nim" # QPACK
  exec "nim c -d:release -d:quantum -r tests/compliance/draft_multipath_tests.nim"

# フルビルド
task full_build, "Build all components with maximum optimization":
  exec "nim c -d:release -d:quantum -d:danger --opt:speed --passC:-march=native src/nim/quantum_browser.nim"

# セキュリティテスト
task security, "Run security tests":
  exec "nim c -d:release -d:quantum -r tests/security/tls_tests.nim"
  exec "nim c -d:release -d:quantum -r tests/security/quantum_shield_tests.nim"
  exec "nim c -d:release -d:quantum -r tests/security/early_data_security.nim"

# Custom flags
when defined(quantum):
  # 量子モード最適化フラグ
  switch("opt", "speed")
  switch("passC", "-march=native")
  switch("passC", "-mtune=native")
  switch("d", "danger")
  switch("d", "lto")
  switch("threads", "on")
  switch("passC", "-ffast-math")
  switch("passC", "-funroll-loops")
  switch("passC", "-flto")
  switch("passL", "-flto")
  when not defined(windows):
    switch("passC", "-ftree-vectorize")
    switch("passC", "-fomit-frame-pointer")
  switch("d", "http3_advanced")
  switch("d", "quic_multipath")
  switch("d", "early_data_prediction")

when defined(optimization):
  switch("opt", "speed")
  switch("passC", "-march=native")
  switch("passC", "-mtune=native")
  switch("d", "danger")
  switch("d", "lto")

when defined(profile):
  switch("debugger", "native")
  switch("profiler", "on")
  switch("stacktrace", "on")

when defined(debug):
  switch("debugger", "native")
  switch("stacktrace", "on")
  switch("linetrace", "on")
  switch("d", "ssl_debug")
  switch("d", "http3_debug")
  switch("d", "quic_debug") 