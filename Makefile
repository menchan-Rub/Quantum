# 次世代ブラウザ Makefile

# 変数定義 (将来的に詳細化)
CRYSTAL_SOURCES := $(shell find src/crystal -name '*.cr')
NIM_SOURCES     := $(shell find src/nim -name '*.nim')
ZIG_SOURCES     := $(shell find src/zig -name '*.zig')

OUTPUT_DIR := build
BINARY_NAME := next_browser

VERSION := $(shell cat VERSION)

# デフォルトターゲット
all: build

# ビルドターゲット
build: $(OUTPUT_DIR)/$(BINARY_NAME)

$(OUTPUT_DIR)/$(BINARY_NAME):
	@echo "ブラウザ実行ファイルをビルドしています..."
	# ここにCrystal, Nim, Zigのコードを統合してビルドするコマンドを記述
	# (例: 各言語のビルド成果物をリンクするなど)
	@mkdir -p $(OUTPUT_DIR)
	@touch $(OUTPUT_DIR)/$(BINARY_NAME) # 仮の実行ファイル作成
	@echo "ビルド完了 (仮). バージョン: $(VERSION)"

# クリーンターゲット
clean:
	@echo "ビルド成果物をクリーンしています..."
	@rm -rf $(OUTPUT_DIR)
	@rm -f src/crystal/app/main # 仮
	@rm -rf nimcache
	@rm -rf zig-cache zig-out
	@echo "クリーン完了."

# テストターゲット
test:
	@echo "テストを実行しています..."
	# ここに各言語のテストを実行するコマンドを記述
	# crystal spec
	# nim test
	# zig test
	@echo "テスト完了 (仮)."

# フォーマットターゲット
format:
	@echo "コードをフォーマットしています..."
	# crystal tool format
	# nimpretty src
	# zig fmt
	@echo "フォーマット完了 (仮)."

# ドキュメント生成ターゲット
docs:
	@echo "ドキュメントを生成しています..."
	# crystal docs
	# nim doc
	# zig build-exe src/main.zig --name docs --library c
	@echo "ドキュメント生成完了 (仮)."

# ヘルプターゲット
help:
	@echo "利用可能なターゲット:"
	@echo "  all       ブラウザをビルド (デフォルト)"
	@echo "  build     メイン実行ファイルをビルド"
	@echo "  clean     ビルド成果物を削除"
	@echo "  test      全てのテストを実行"
	@echo "  format    ソースコードをフォーマット"
	@echo "  docs      ドキュメントを生成"
	@echo "  help      ヘルプを表示"

.PHONY: all build clean test format docs help
