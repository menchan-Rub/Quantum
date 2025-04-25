# ブラウザプロジェクトディレクトリ構造

## 概要
- 本構造は @specifications.md のフェーズ4（エコシステム拡大）要件および @technical_requirements.md の性能・効率性・安全性要件を完全に満たすよう設計しています。  
- Crystal（UI／高レベルロジック）、Nim（ネットワーク／システム処理）、Zig（レンダリング／低レベル制御）の三層ハイブリッドモデルにより、**疎結合・高凝集**と**高いパフォーマンス**を両立。  
- モジュール性・拡張性を最優先し、新規言語・プラットフォーム・機能追加にも柔軟に対応可能なクリーンアーキテクチャを実現。

## ルートディレクトリ構造
```text
browser/
├── .github/                   # GitHub ワークフロー・テンプレート
├── .vscode/                   # VSCode 設定
├── assets/                    # 静的アセット
├── build/                     # ビルド出力
├── docs/                      # ドキュメント
├── scripts/                   # ビルド／開発ツール
├── src/                       # ソースコード
├── tests/                     # テストコード
├── third_party/               # サードパーティライブラリ
├── tools/                     # 開発支援ツール
├── .editorconfig              # エディタ共通設定
├── .gitignore                 # Git 除外設定
├── LICENSE                    # ライセンス
├── Makefile                   # メイン Makefile
├── README.md                  # プロジェクト概要
└── VERSION                    # バージョン情報
```

## ソースコードディレクトリ構造 (`src/`)
```text
src/
├── core/                      # 言語横断共通コア
│   ├── api/                   # API 定義
│   ├── constants/             # 定数定義
│   ├── ipc/                   # プロセス間通信
│   ├── logging/               # ログシステム
│   ├── memory/                # メモリ管理
│   ├── protocols/             # プロトコル定義
│   └── utils/                 # ユーティリティ
├── crystal/                   # Crystal 実装
│   ├── browser/               # メインアプリ
│   │   ├── app/               # エントリポイント
│   │   ├── commands/          # コマンド処理
│   │   ├── config/            # 設定管理
│   │   └── session/           # セッション管理
│   ├── ui/                    # UI コンポーネント
│   │   ├── components/        # 再利用可能コンポーネント
│   │   │   ├── address_bar/
│   │   │   ├── bookmarks/
│   │   │   ├── buttons/
│   │   │   ├── context_menu/
│   │   │   ├── dialogs/
│   │   │   ├── history/
│   │   │   ├── icons/
│   │   │   ├── navigation/
│   │   │   ├── sidebar/
│   │   │   ├── status_bar/
│   │   │   ├── tabs/
│   │   │   └── toolbar/
│   │   ├── layouts/           # レイアウト定義
│   │   ├── screens/           # 主要画面
│   │   │   ├── browser/
│   │   │   ├── devtools/
│   │   │   ├── settings/
│   │   │   └── welcome/
│   │   ├── themes/            # テーマシステム
│   │   └── widgets/           # カスタムウィジェット
│   ├── events/                # イベント処理
│   │   ├── dispatcher/
│   │   ├── handlers/
│   │   └── types/
│   ├── storage/               # 永続化管理
│   │   ├── bookmarks/
│   │   ├── history/
│   │   ├── passwords/
│   │   ├── preferences/
│   │   └── sync/
│   ├── extensions/            # 拡張機能
│   │   ├── api/
│   │   ├── loader/
│   │   ├── manager/
│   │   └── sandbox/
│   ├── platform/              # OS 固有実装
│   │   ├── linux/
│   │   ├── macos/
│   │   └── windows/
│   └── bindings/              # 他言語連携
│       ├── nim/
│       └── zig/
├── nim/                       # Nim 実装
│   ├── network/
│   │   ├── cache/
│   │   │   ├── disk/
│   │   │   ├── memory/
│   │   │   └── policy/
│   │   ├── dns/
│   │   │   ├── resolver/
│   │   │   ├── cache/
│   │   │   └── secure/
│   │   ├── http/
│   │   │   ├── client/
│   │   │   ├── headers/
│   │   │   ├── methods/
│   │   │   └── versions/
│   │   ├── protocols/
│   │   │   ├── ftp/
│   │   │   ├── websocket/
│   │   │   ├── webrtc/
│   │   │   └── sse/
│   │   ├── security/
│   │   │   ├── certificates/
│   │   │   ├── csp/
│   │   │   ├── mixed_content/
│   │   │   └── tls/
│   │   ├── proxy/
│   │   │   ├── auto_config/
│   │   │   ├── http/
│   │   │   └── socks/
│   │   └── optimization/
│   │       ├── prefetch/
│   │       ├── preconnect/
│   │       └── prioritization/
│   ├── cookies/
│   │   ├── store/
│   │   ├── policy/
│   │   └── security/
│   ├── compression/
│   │   ├── gzip/
│   │   ├── brotli/
│   │   └── zstd/
│   ├── privacy/
│   │   ├── blockers/
│   │   ├── fingerprinting/
│   │   └── sanitization/
│   └── bindings/
│       ├── crystal/
│       └── zig/
├── zig/                       # Zig 実装
│   ├── engine/
│   │   ├── html/
│   │   │   ├── parser/
│   │   │   ├── tokenizer/
│   │   │   └── dom/
│   │   ├── css/
│   │   │   ├── parser/
│   │   │   ├── selector/
│   │   │   ├── box/
│   │   │   └── compute/
│   │   ├── layout/
│   │   │   ├── box/
│   │   │   ├── flex/
│   │   │   ├── grid/
│   │   │   ├── text/
│   │   │   └── viewport/
│   │   ├── render/
│   │   │   ├── canvas/
│   │   │   ├── compositor/
│   │   │   ├── gpu/
│   │   │   ├── raster/
│   │   │   └── webgl/
│   │   └── animation/
│   │       ├── keyframe/
│   │       ├── timeline/
│   │       └── transitions/
│   ├── javascript/
│   │   ├── parser/
│   │   ├── vm/
│   │   ├── jit/
│   │   ├── gc/
│   │   ├── builtins/
│   │   └── api/
│   ├── dom/
│   │   ├── elements/
│   │   ├── events/
│   │   ├── mutations/
│   │   ├── traversal/
│   │   └── window/
│   ├── webapi/
│   │   ├── fetch/
│   │   ├── storage/
│   │   ├── workers/
│   │   ├── webassembly/
│   │   └── canvas/
│   ├── media/
│   │   ├── images/
│   │   │   ├── codecs/
│   │   │   ├── optimization/
│   │   │   └── svg/
│   │   ├── audio/
│   │   │   ├── codecs/
│   │   │   ├── playback/
│   │   │   └── synthesis/
│   │   └── video/
│   │       ├── codecs/
│   │       ├── player/
│   │       └── streaming/
│   ├── fonts/
│   │   ├── loader/
│   │   ├── renderer/
│   │   ├── subsetting/
│   │   └── shaping/
│   ├── memory/
│   │   ├── allocator/
│   │   ├── pool/
│   │   └── optimization/
│   └── bindings/
│       ├── crystal/
│       └── nim/
├── shared/                    # 言語間共通
│   ├── config/                # 共通設定
│   ├── models/                # 共通データモデル
│   ├── protocols/             # 通信プロトコル定義
│   └── utils/                 # 共有ユーティリティ
└── platform/                  # 共通プラットフォーム実装
    ├── linux/
    ├── macos/
    └── windows/
```

## サポートディレクトリ構造

### ドキュメント (`docs/`)
```text
docs/
├── architecture/             # アーキテクチャ文書
├── api/                      # API 仕様
├── dev/                      # 開発者ガイド
│   ├── building/             # ビルド方法
│   ├── code_style/           # コーディング規約
│   ├── contributing/         # 貢献ガイド
│   └── testing/              # テスト方法
├── protocols/                # プロトコル仕様
├── user/                     # ユーザードキュメント
└── performance/              # パフォーマンス最適化ガ이드
```

### テスト (`tests/`)
```text
tests/
├── unit/                     # 単体テスト
│   ├── crystal/
│   ├── nim/
│   └── zig/
├── integration/              # 統合テスト
├── performance/              # パフォーマンステスト
├── security/                 # セキュリティテスト
├── compatibility/            # 互換性テスト
└── e2e/                      # エンドツーエンドテスト
```

### ビルドスクリプトとツール (`scripts/`)
```text
scripts/
├── build/                    # ビルドスクリプト
│   ├── crystal/
│   ├── nim/
│   ├── zig/
│   └── integrated/
├── ci/                       # CI/CD 設定
├── dependencies/             # 依存管理
├── packaging/                # パッケージング
│   ├── linux/
│   ├── macos/
│   └── windows/
├── lint/                     # リント
└── release/                  # リリース管理
```

### 開発支援ツール (`tools/`)
```text
tools/
├── benchmarks/               # ベンチマークツール
├── code_generation/          # コード生成ツール
├── debugging/                # デバッグ支援
├── analysis/                 # 静的解析
├── profiling/                # プロファイリング
└── simulation/               # シミュレーション
```

### サードパーティライブラリ (`third_party/`)
```text
third_party/
├── crystal/                  # Crystal 外部ライブラリ
├── nim/                      # Nim 外部ライブラリ
├── zig/                      # Zig 外部ライブラリ
└── common/                   # 共通外部ライブラリ
```

### アセット (`assets/`)
```text
assets/
├── icons/                    # アイコン
│   ├── app/                  
│   └── ui/                   
├── images/                   # 画像
├── fonts/                    # フォント
├── sounds/                   # サウンド
└── themes/                   # デフォルトテーマ
```

## 設定ファイル

### ビルド設定
```text
browser/
├── build.toml                # 主要ビルド設定
├── crystal/
│   ├── shard.yml             # Crystal パッケージ設定
│   └── crystal.build.toml    # Crystal 詳細ビルド設定
├── nim/
│   ├── nim.cfg               # Nim 設定
│   └── nim.build.toml        # Nim 詳細ビルド設定
└── zig/
    ├── build.zig             # Zig ビルドスクリプト
    └── zig.build.toml        # Zig 詳細ビルド設定
```

### 開発環境設定
```text
browser/
├── .vscode/
│   ├── launch.json           # デバッグ設定
│   ├── tasks.json            # タスク設定
│   ├── settings.json         # エディタ設定
│   └── extensions.json       # 推奨拡張機能
├── .editorconfig             # エディタ共通設定
└── .clang-format             # コード整形設定
```

## リソースファイル
```text
browser/
└── resources/
    ├── default_settings/
    ├── locales/
    ├── certificates/
    └── default_bookmarks/
```

## ディストリビューション構造
```text
dist/
├── linux/
│   ├── deb/
│   ├── rpm/
│   └── appimage/
├── macos/
│   └── app/
├── windows/
│   ├── installer/
│   └── portable/
└── common/
```

## 言語間データ交換
1. 共有メモリ領域  
2. シリアライズされたメッセージ  
3. FFI (Foreign Function Interface)  

## ビルドフロー
1. 個別言語ビルド  
2. バインディング生成  
3. 統合ビルド  
4. パッケージング  

## 特別なディレクトリ要件
- モジュラー設計  
- クリーンアーキテクチャ  
- プラットフォーム分離  
- 言語分離  

## 拡張機能ディレクトリ構造
```text
extensions/
├── api/                      # 拡張機能 API 定義
├── schemas/                  # マニフェストスキーマ
├── core/                     # コア拡張機能
│   ├── adblock/
│   ├── password_manager/
│   └── developer_tools/
└── third_party/              # サードパーティ拡張機能
```

## ユーザーデータディレクトリ構造
```text
user_data/
├── profiles/
│   └── default/
│       ├── bookmarks/
│       ├── history/
│       ├── passwords/
│       ├── preferences/
│       ├── extensions/
│       └── cache/
├── shared/
└── logs/
```

## 開発ワークフロー統合
1. コンポーネント開発  
2. 統合テスト  
3. 継続的インテグレーション  
4. フィーチャーブランチ開発  

## セキュリティ考慮事項
- サンドボックス分離  
- 権限最小化  
- コード署名  
- セキュアコーディング  

## 将来の拡張性
1. 新規言語サポート  
2. 新プラットフォーム対応  
3. モジュール追加  
4. スケーリング  

## 結論
本ディレクトリ構造は、Crystal、Nim、Zig のトリプルハイブリッド構成による革新的ブラウザ開発に最適化され、性能・効率性・拡張性・セキュリティ要件を完璧に満たす堅牢な基盤を提供します。