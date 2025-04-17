# 拡張クッキー管理システム

## 概要

この拡張クッキー管理システムは、ウェブブラウザ向けの高度なクッキー処理機能を提供します。プライバシー保護、セキュリティ強化、ポリシー適用、同意管理などの機能を統合し、現代のウェブブラウジングに必要な要件を満たします。

## 主な機能

- **複数の動作モード**: 基本、標準、プライベート、厳格の4つのモードをサポート
- **高度なポリシー管理**: ドメインごとのカスタムポリシールールを適用
- **クッキー分析と分類**: クッキーをその目的と機能に基づいて分類
- **トラッカー検出**: 既知のトラッキングドメインとパターンに基づくトラッカー検出
- **同意管理**: GDPR準拠のためのクッキー同意管理
- **セキュリティ機能**: CSRF保護、クッキー暗号化、署名検証
- **拡張統計**: クッキー使用状況と処理に関する詳細な統計
- **プライバシーレポート**: ユーザーのプライバシー保護状況を示すレポート

## アーキテクチャ

システムは以下のモジュールで構成されています:

```
src/nim/cookies/
├── main.nim              # 基本クッキーマネージャー
├── main_extended.nim     # 拡張クッキーマネージャー (統合モジュール)
├── cookie_types.nim      # 基本データ型の定義
├── store/                # クッキーストレージ
│   └── cookie_store.nim  # クッキーの永続化と読み込み
├── security/             # セキュリティ機能
│   ├── cookie_security.nim    # 暗号化と署名
│   └── secure_cookie_jar.nim  # セキュアなクッキー管理
├── policy/               # ポリシー管理
│   ├── cookie_policy.nim      # ポリシールール処理
│   └── policy_loader.nim      # 事前定義されたポリシーのロード
└── extensions/           # 拡張機能
    ├── cookie_extensions.nim  # クッキー分析と分類
    └── cookie_manager_ext.nim # 拡張クッキーマネージャー
```

## 使用方法

### 基本的な使用例

```nim
# ライブラリをインポート
import cookies/main_extended

# 標準モードでクッキーマネージャーを作成
let manager = newBrowserCookieManager(
  mode = bcmStandard,
  userDataDir = "/path/to/user/data",
  profileName = "default"
)

# クッキーを設定
let success = manager.setCookie(
  name = "session",
  value = "abc123",
  domain = "example.com",
  path = "/",
  maxAge = some(3600),
  secure = true,
  httpOnly = true
)

# クッキーを取得
let url = parseUri("https://example.com/")
let cookies = manager.getCookies(url)

# クッキーヘッダーを取得
let cookieHeader = manager.getCookieHeader(url)

# クッキーを削除
discard manager.deleteCookie("session", "example.com")

# 変更を保存
discard manager.saveCookies()
```

### ポリシー管理

```nim
# ドメインにポリシールールを追加
manager.addPolicyRule("tracker.com", prBlock)

# コンテキスト依存のクッキー取得
let documentUrl = some(parseUri("https://example.org/"))
let cookies = manager.getCookies(parseUri("https://api.example.org/"), documentUrl)
```

### 同意管理

```nim
# ドメインの同意設定を更新
manager.setConsentForDomain("example.com", @[cgNecessary, cgFunctional, cgPreferences])

# デフォルト同意設定を更新
manager.setDefaultConsent(@[cgNecessary, cgFunctional])
```

### 動作モードの変更

```nim
# 厳格モードに変更
manager.changeMode(bcmStrict)

# プライベートモードに変更
manager.changeMode(bcmPrivate)
```

### 統計とレポート

```nim
# 統計情報を取得
let stats = manager.getStats()
echo stats.pretty()

# プライバシーレポートを取得
let report = manager.getPrivacyReport()
echo report.pretty()
```

## 動作モード詳細

### bcmBasic (基本モード)
- 基本的なクッキー管理のみを提供
- サードパーティクッキーを許可
- 暗号化や高度なセキュリティ機能は無効

### bcmStandard (標準モード)
- バランスの取れたプライバシーとセキュリティ設定
- 機密クッキーの暗号化を有効
- スマートなサードパーティクッキーブロック
- サードパーティコンテキストでのクッキー分離

### bcmPrivate (プライベートモード)
- 強化されたプライバシー保護
- セッションクッキーの永続化なし
- すべてのサードパーティクッキーをブロック
- すべてのコンテキストでクッキー分離を強制

### bcmStrict (厳格モード)
- 最高レベルのセキュリティとプライバシー保護
- セキュアクッキーのみを許可
- すべてのサードパーティクッキーをブロック
- すべてのコンテキストでクッキー分離を強制

## ライセンス

Copyright © 2023-2024

このソフトウェアは、特に記載がない限り、独自のライセンス条件の下で提供されています。 