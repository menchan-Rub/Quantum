# Package

version       = "0.1.0"
author        = "ブラウザプロジェクトチーム"
description   = "複数の圧縮アルゴリズム（gzip, brotli, zstd）をサポートする圧縮ライブラリ"
license       = "MIT"
srcDir        = "compression"

# Dependencies

requires "nim >= 1.6.0"

# Tasks

task test, "Run compression tests":
  exec "nim c -r compression/test_compression" 