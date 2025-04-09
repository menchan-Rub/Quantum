# ブラウザプロジェクトディレクトリ構造

## 概要
本ドキュメントでは、Crystal、Nim、Zigのトリプルハイブリッド構成による独自ブラウザの詳細なディレクトリ構造を定義します。各言語の役割分担とコンポーネントの配置を明確にし、開発の一貫性と効率性を確保します。

## ルートディレクトリ構造

```
browser/
├── .github/                   # GitHub関連ファイル
├── .vscode/                   # VSCode設定
├── assets/                    # 静的アセット
├── build/                     # ビルド出力ディレクトリ
├── docs/                      # ドキュメント
├── scripts/                   # ビルドスクリプトと開発ツール
├── src/                       # ソースコード
├── tests/                     # テストコード
├── third_party/               # サードパーティライブラリ
├── tools/                     # 開発支援ツール
├── .editorconfig              # エディタ設定
├── .gitignore                 # Git除外ファイル
├── LICENSE                    # ライセンス
├── Makefile                   # メインMakefile
├── README.md                  # プロジェクト概要
└── VERSION                    # バージョン情報
```

## ソースコードディレクトリ構造 (`src/`)

```
src/
├── core/                      # 共通コアライブラリ（言語間共有）
│   ├── api/                   # 言語間API定義
│   ├── constants/             # 共通定数
│   ├── ipc/                   # プロセス間通信
│   ├── logging/               # ログシステム
│   ├── memory/                # メモリ管理
│   ├── protocols/             # プロトコル定義
│   └── utils/                 # ユーティリティ
│
├── crystal/                   # Crystalで実装するコンポーネント
│   ├── browser/               # ブラウザのメインアプリケーション
│   │   ├── app/               # アプリケーションエントリポイント
│   │   ├── commands/          # コマンド処理
│   │   ├── config/            # 設定管理
│   │   └── session/           # セッション管理
│   │
│   ├── ui/                    # UIコンポーネント
│   │   ├── components/        # 再利用可能なUIコンポーネント
│   │   │   ├── address_bar/   # アドレスバー
│   │   │   ├── bookmarks/     # ブックマーク
│   │   │   ├── buttons/       # ボタン類
│   │   │   ├── context_menu/  # コンテキストメニュー
│   │   │   ├── dialogs/       # ダイアログ
│   │   │   ├── history/       # 履歴UI
│   │   │   ├── icons/         # アイコン
│   │   │   ├── navigation/    # ナビゲーションコントロール
│   │   │   ├── sidebar/       # サイドバー
│   │   │   ├── status_bar/    # ステータスバー
│   │   │   ├── tabs/          # タブ関連
│   │   │   └── toolbar/       # ツールバー
│   │   │
│   │   ├── layouts/           # レイアウト定義
│   │   ├── screens/           # 主要画面
│   │   │   ├── browser/       # メインブラウザ画面
│   │   │   ├── devtools/      # 開発者ツール
│   │   │   ├── settings/      # 設定画面
│   │   │   └── welcome/       # ウェルカム画面
│   │   │
│   │   ├── themes/            # テーマシステム
│   │   └── widgets/           # カスタムウィジェット
│   │
│   ├── events/                # イベント処理システム
│   │   ├── dispatcher/        # イベントディスパッチャ
│   │   ├── handlers/          # イベントハンドラ
│   │   └── types/             # イベント型定義
│   │
│   ├── storage/               # ローカルストレージ管理
│   │   ├── bookmarks/         # ブックマーク管理
│   │   ├── history/           # 履歴管理
│   │   ├── passwords/         # パスワード管理
│   │   ├── preferences/       # ユーザー設定
│   │   └── sync/              # 同期機能
│   │
│   ├── extensions/            # 拡張機能システム
│   │   ├── api/               # 拡張機能API
│   │   ├── loader/            # 拡張機能ローダー
│   │   ├── manager/           # 拡張機能マネージャ
│   │   └── sandbox/           # 拡張機能サンドボックス
│   │
│   ├── platform/              # プラットフォーム固有実装
│   │   ├── linux/             # Linux固有コード
│   │   ├── macos/             # macOS固有コード
│   │   └── windows/           # Windows固有コード
│   │
│   └── bindings/              # 他言語との連携
│       ├── nim/               # Nimとの連携
│       └── zig/               # Zigとの連携
│
├── nim/                       # Nimで実装するコンポーネント
│   ├── network/               # ネットワークスタック
│   │   ├── cache/             # キャッシュシステム
│   │   │   ├── disk/          # ディスクキャッシュ
│   │   │   ├── memory/        # メモリキャッシュ
│   │   │   └── policy/        # キャッシュポリシー
│   │   │
│   │   ├── dns/               # DNS解決
│   │   │   ├── resolver/      # DNSリゾルバ
│   │   │   ├── cache/         # DNSキャッシュ
│   │   │   └── secure/        # DoH/DoT実装
│   │   │
│   │   ├── http/              # HTTPクライアント
│   │   │   ├── client/        # HTTPクライアント実装
│   │   │   ├── headers/       # HTTPヘッダー処理
│   │   │   ├── methods/       # HTTPメソッド
│   │   │   └── versions/      # HTTP/1.1, HTTP/2, HTTP/3
│   │   │
│   │   ├── protocols/         # プロトコル実装
│   │   │   ├── ftp/           # FTPクライアント
│   │   │   ├── websocket/     # WebSocket実装
│   │   │   ├── webrtc/        # WebRTC実装
│   │   │   └── sse/           # Server-Sent Events
│   │   │
│   │   ├── security/          # ネットワークセキュリティ
│   │   │   ├── certificates/  # 証明書管理
│   │   │   ├── csp/           # Content Security Policy
│   │   │   ├── mixed_content/ # 混合コンテンツ対策
│   │   │   └── tls/           # TLS実装
│   │   │
│   │   ├── proxy/             # プロキシ対応
│   │   │   ├── auto_config/   # PAC処理
│   │   │   ├── http/          # HTTPプロキシ
│   │   │   └── socks/         # SOCKSプロキシ
│   │   │
│   │   └── optimization/      # ネットワーク最適化
│   │       ├── prefetch/      # プリフェッチ
│   │       ├── preconnect/    # プリコネクト
│   │       └── prioritization/ # リソース優先順位付け
│   │
│   ├── cookies/               # Cookie管理
│   │   ├── store/             # Cookieストア
│   │   ├── policy/            # Cookieポリシー
│   │   └── security/          # Cookie保護
│   │
│   ├── compression/           # 圧縮/解凍
│   │   ├── gzip/              # gzip実装
│   │   ├── brotli/            # brotli実装
│   │   └── zstd/              # zstd実装
│   │
│   ├── privacy/               # プライバシー保護機能
│   │   ├── blockers/          # トラッカーブロック
│   │   ├── fingerprinting/    # フィンガープリント防止
│   │   └── sanitization/      # データサニタイズ
│   │
│   └── bindings/              # 他言語との連携
│       ├── crystal/           # Crystalとの連携
│       └── zig/               # Zigとの連携
│
├── zig/                       # Zigで実装するコンポーネント
│   ├── engine/                # レンダリングエンジン
│   │   ├── html/              # HTMLパーサー
│   │   │   ├── parser/        # HTML解析
│   │   │   ├── tokenizer/     # HTMLトークナイザ
│   │   │   └── dom/           # DOM構築
│   │   │
│   │   ├── css/               # CSSエンジン
│   │   │   ├── parser/        # CSS解析
│   │   │   ├── selector/      # セレクタマッチング
│   │   │   ├── box/           # ボックスモデル
│   │   │   └── compute/       # スタイル計算
│   │   │
│   │   ├── layout/            # レイアウトエンジン
│   │   │   ├── box/           # ボックスレイアウト
│   │   │   ├── flex/          # フレックスボックス
│   │   │   ├── grid/          # グリッドレイアウト
│   │   │   ├── text/          # テキストレイアウト
│   │   │   └── viewport/      # ビューポート管理
│   │   │
│   │   ├── render/            # 描画エンジン
│   │   │   ├── canvas/        # キャンバス実装
│   │   │   ├── compositor/    # コンポジター
│   │   │   ├── gpu/           # GPU活用
│   │   │   ├── raster/        # ラスタライザー
│   │   │   └── webgl/         # WebGL実装
│   │   │
│   │   └── animation/         # アニメーション処理
│   │       ├── keyframe/      # キーフレーム
│   │       ├── timeline/      # タイムライン
│   │       └── transitions/   # トランジション
│   │
│   ├── javascript/            # JavaScriptエンジン
│   │   ├── parser/            # JS解析
│   │   ├── vm/                # 仮想マシン
│   │   ├── jit/               # JITコンパイラ
│   │   ├── gc/                # ガベージコレクション
│   │   ├── builtins/          # 組み込み関数
│   │   └── api/               # JS API実装
│   │
│   ├── dom/                   # DOM実装
│   │   ├── elements/          # DOM要素
│   │   ├── events/            # DOMイベント
│   │   ├── mutations/         # DOM変更監視
│   │   ├── traversal/         # DOMトラバーサル
│   │   └── window/            # Windowオブジェクト
│   │
│   ├── webapi/                # Web API実装
│   │   ├── fetch/             # Fetch API
│   │   ├── storage/           # Web Storage
│   │   ├── workers/           # Web Workers
│   │   ├── webassembly/       # WebAssembly
│   │   └── canvas/            # Canvas API
│   │
│   ├── media/                 # メディア処理
│   │   ├── images/            # 画像処理
│   │   │   ├── codecs/        # 画像コーデック
│   │   │   ├── optimization/  # 画像最適化
│   │   │   └── svg/           # SVG処理
│   │   │
│   │   ├── audio/             # 音声処理
│   │   │   ├── codecs/        # 音声コーデック
│   │   │   ├── playback/      # 再生エンジン
│   │   │   └── synthesis/     # 音声合成
│   │   │
│   │   └── video/             # 動画処理
│   │       ├── codecs/        # 動画コーデック
│   │       ├── player/        # 動画プレーヤー
│   │       └── streaming/     # ストリーミング
│   │
│   ├── fonts/                 # フォント処理
│   │   ├── loader/            # フォントローダー
│   │   ├── renderer/          # フォントレンダラー
│   │   ├── subsetting/        # サブセッティング
│   │   └── shaping/           # テキストシェーピング
│   │
│   ├── memory/                # メモリ管理
│   │   ├── allocator/         # メモリアロケータ
│   │   ├── pool/              # メモリプール
│   │   └── optimization/      # メモリ最適化
│   │
│   └── bindings/              # 他言語との連携
│       ├── crystal/           # Crystalとの連携
│       └── nim/               # Nimとの連携
│
├── shared/                    # 言語間共有コード
│   ├── config/                # 共通設定
│   ├── models/                # 共通データモデル
│   ├── protocols/             # 通信プロトコル定義
│   └── utils/                 # 共有ユーティリティ
│
└── platform/                  # プラットフォーム固有の共通コード
    ├── linux/                 # Linux固有の共通コード
    ├── macos/                 # macOS固有の共通コード
    └── windows/               # Windows固有の共通コード
```

## サポートディレクトリ構造

### ドキュメント (`docs/`)

```
docs/
├── architecture/             # アーキテクチャドキュメント
├── api/                      # API仕様
├── dev/                      # 開発者ガイド
│   ├── building/             # ビルド方法
│   ├── code_style/           # コーディング規約
│   ├── contributing/         # 貢献ガイド
│   └── testing/              # テスト方法
├── protocols/                # プロトコル仕様
├── user/                     # ユーザードキュメント
└── performance/              # パフォーマンス最適化ガイド
```

### テスト (`tests/`)

```
tests/
├── unit/                     # 単体テスト
│   ├── crystal/              # Crystal単体テスト
│   ├── nim/                  # Nim単体テスト
│   └── zig/                  # Zig単体テスト
├── integration/              # 統合テスト
├── performance/              # パフォーマンステスト
├── security/                 # セキュリティテスト
├── compatibility/            # 互換性テスト
└── e2e/                      # エンドツーエンドテスト
```

### ビルドスクリプトとツール (`scripts/`)

```
scripts/
├── build/                    # ビルドスクリプト
│   ├── crystal/              # Crystal用ビルドスクリプト
│   ├── nim/                  # Nim用ビルドスクリプト
│   ├── zig/                  # Zig用ビルドスクリプト
│   └── integrated/           # 統合ビルドスクリプト
├── ci/                       # CI/CD設定
├── dependencies/             # 依存関係管理
├── packaging/                # パッケージング
│   ├── linux/                # Linux用パッケージング
│   ├── macos/                # macOS用パッケージング
│   └── windows/              # Windows用パッケージング
├── lint/                     # リントツール
└── release/                  # リリース管理
```

### 開発支援ツール (`tools/`)

```
tools/
├── benchmarks/               # ベンチマークツール
├── code_generation/          # コード生成ツール
├── debugging/                # デバッグ支援ツール
├── analysis/                 # 静的解析ツール
├── profiling/                # プロファイリングツール
└── simulation/               # シミュレーションツール
```

### サードパーティライブラリ (`third_party/`)

```
third_party/
├── crystal/                  # Crystal用外部ライブラリ
├── nim/                      # Nim用外部ライブラリ
├── zig/                      # Zig用外部ライブラリ
└── common/                   # 共通外部ライブラリ
```

### アセット (`assets/`)

```
assets/
├── icons/                    # アイコン
│   ├── app/                  # アプリケーションアイコン
│   └── ui/                   # UI用アイコン
├── images/                   # 画像
├── fonts/                    # フォント
├── sounds/                   # サウンド
└── themes/                   # デフォルトテーマ
```

## 設定ファイル

### ビルド設定

```
browser/
├── build.toml                # 主要ビルド設定
├── crystal/                  # Crystal固有設定
│   ├── shard.yml             # Crystalパッケージ設定
│   └── crystal.build.toml    # Crystal詳細ビルド設定
├── nim/                      # Nim固有設定
│   ├── nim.cfg               # Nim設定
│   └── nim.build.toml        # Nim詳細ビルド設定
└── zig/                      # Zig固有設定
    ├── build.zig             # Zigビルドスクリプト
    └── zig.build.toml        # Zig詳細ビルド設定
```

### 開発環境設定

```
browser/
├── .vscode/                  # VSCode設定
│   ├── launch.json           # デバッグ設定
│   ├── tasks.json            # タスク設定
│   ├── settings.json         # エディタ設定
│   └── extensions.json       # 推奨拡張機能
├── .editorconfig             # エディタ共通設定
└── .clang-format             # コード整形設定
```

## リソースファイル

```
browser/
└── resources/
    ├── default_settings/     # デフォルト設定
    ├── locales/              # 翻訳リソース
    ├── certificates/         # 証明書バンドル
    └── default_bookmarks/    # デフォルトブックマーク
```

## ディストリビューション構造

```
dist/
├── linux/                    # Linux用ディストリビューション
│   ├── deb/                  # Debian/Ubuntuパッケージ
│   ├── rpm/                  # RHEL/Fedoraパッケージ
│   └── appimage/             # AppImage
├── macos/                    # macOS用ディストリビューション
│   └── app/                  # macOSアプリケーションバンドル
├── windows/                  # Windows用ディストリビューション
│   ├── installer/            # インストーラ
│   └── portable/             # ポータブル版
└── common/                   # 共通リソース
```

## 言語間データ交換

言語間のデータ交換は主に次の方法で行われます：

1. **共有メモリ領域**: 大量データや頻繁にアクセスされるデータ用
2. **シリアライズされたメッセージ**: 構造化データの交換用
3. **FFI (Foreign Function Interface)**: 直接的な関数呼び出し用

## ビルドフロー

1. **個別言語ビルド**: 各言語のコードをそれぞれのビルドシステムでビルド
   - Crystal: `shards build`
   - Nim: `nimble build`
   - Zig: `zig build`

2. **バインディング生成**: 言語間連携のためのバインディングを生成

3. **統合ビルド**: コンポーネントを統合し最終的な実行可能ファイルを生成

4. **パッケージング**: OSごとの配布形式にパッケージング

## 特別なディレクトリ要件

- **モジュラー設計**: 各ディレクトリは独立したモジュールとして機能する
- **クリーンアーキテクチャ**: 依存関係は内側から外側へ流れる
- **プラットフォーム分離**: プラットフォーム固有のコードは明確に分離
- **言語分離**: 各言語のコードは適切に分離されるが、明確なAPIで連携

## 拡張機能ディレクトリ構造

```
extensions/
├── api/                      # 拡張機能API定義
├── schemas/                  # 拡張機能マニフェストスキーマ
├── core/                     # コア拡張機能
│   ├── adblock/              # 広告ブロック
│   ├── password_manager/     # パスワード管理
│   └── developer_tools/      # 開発者ツール
└── third_party/              # サードパーティ拡張機能保存領域
```

## ユーザーデータディレクトリ構造

```
user_data/
├── profiles/                 # ユーザープロファイル
│   └── default/              # デフォルトプロファイル
│       ├── bookmarks/        # ブックマーク
│       ├── history/          # 履歴
│       ├── passwords/        # パスワード
│       ├── preferences/      # 設定
│       ├── extensions/       # インストール済み拡張機能
│       └── cache/            # キャッシュ
├── shared/                   # プロファイル間共有データ
└── logs/                     # ログファイル
```

## 開発ワークフロー統合

このディレクトリ構造は次の開発ワークフローをサポートします：

1. **コンポーネント開発**: 各言語チームが独立して開発
2. **統合テスト**: 定期的な統合によるコンポーネント間連携テスト
3. **継続的インテグレーション**: CI/CDパイプラインによる自動ビルドとテスト
4. **フィーチャーブランチ開発**: 機能ごとの分離開発とマージ

## セキュリティ考慮事項

- **サンドボックス分離**: プロセス間の安全な分離を確保
- **権限最小化**: 各コンポーネントは必要最小限の権限で動作
- **コード署名**: リリースバイナリの完全性を確保
- **セキュアコーディング**: 各言語のセキュアコーディングプラクティスに従う

## 将来の拡張性

このディレクトリ構造は以下の将来的な拡張に対応できます：

1. **新規言語サポート**: 追加言語のための明確な統合ポイント
2. **新プラットフォーム対応**: 明確に分離されたプラットフォーム固有コード
3. **モジュール追加**: プラグイン可能なアーキテクチャ
4. **スケーリング**: 大規模開発チームでの並行作業

## 結論

このディレクトリ構造は、Crystal、Nim、Zigのトリプルハイブリッド構成による革新的ブラウザの開発に最適化されています。言語間の明確な責任分担、効率的な開発ワークフロー、そして将来の拡張性を考慮した設計となっています。 