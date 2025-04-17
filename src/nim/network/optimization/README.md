# ネットワーク最適化モジュール

このモジュールは、ブラウザのネットワークパフォーマンスを最適化するための機能を提供します。主に以下の3つの最適化技術を実装しています：

1. **事前接続 (Preconnect)**
2. **事前取得 (Prefetch)**
3. **リソース優先順位付け (Resource Prioritization)**

## 機能概要

### 事前接続 (Preconnect)

`preconnect`モジュールは、ユーザーがリンクをクリックする前にドメインへの接続を事前に確立するための機能を提供します。これにより、DNSルックアップ、TCPハンドシェイク、TLS交渉にかかる時間を削減し、ページの読み込み時間を短縮します。

主な機能：
- DNS解決の事前実行
- TCP接続の事前確立
- TLSハンドシェイクの事前実行
- 接続プールの管理
- 接続の再利用と追い出し
- 状態監視とメトリクス収集

### 事前取得 (Prefetch)

`prefetch`モジュールは、ユーザーが近い将来必要とする可能性が高いリソースを事前にダウンロードするための機能を提供します。これにより、ユーザーが実際にリソースを要求したときに、キャッシュから即座に提供できます。

主な機能：
- リソースの事前取得と優先順位付け
- キャッシュへの自動保存
- 帯域幅使用量の制限
- エラー処理と再試行
- ホバーベースの事前取得
- メトリクス収集と分析

### リソース優先順位付け (Resource Prioritization)

`prioritization`モジュールは、リソースの読み込み順序を最適化するための機能を提供します。重要なリソース（HTML、CSS、クリティカルなJavaScriptなど）を優先的に読み込むことで、ページのレンダリング速度を向上させます。

主な機能：
- リソースタイプに基づく優先順位付け
- 依存関係グラフの構築と分析
- クリティカルパスの特定
- ビューポート認識の優先順位付け
- 適応型リソース読み込み

## 使い方

### 最適化マネージャーの初期化

```nim
import std/[tables, asyncdispatch]
import network/optimization/optimization_manager
import network/cache/http_cache_manager

# HTTPキャッシュマネージャーを初期化
let cacheConfig = newCacheConfig()
var cacheManager = newHttpCacheManager(cacheConfig)

# 最適化設定を作成（積極的、バランス型、控えめから選択）
let settings = defaultOptimizationSettings(osBalanced)

# 最適化マネージャーを初期化
var manager = newOptimizationManager(
  cacheManager = cacheManager,
  settings = settings
)
```

### 事前接続の使用

```nim
# 単一のURLに事前接続
asyncCheck manager.preconnectUrl("https://example.com")

# 複数のオリジンに事前接続
manager.preconnectOrigins(@["api.example.com", "cdn.example.com", "fonts.example.com"])
```

### 事前取得の使用

```nim
# 単一のURLを事前取得
asyncCheck manager.prefetchUrl("https://example.com/next-page.html", ppHigh)

# ユーザーのホバーを検知して事前取得を開始
manager.onHover("https://example.com/product-details.html")

# ユーザーのクリックを検知して優先度の高い事前取得を開始
manager.onLinkClick("https://example.com/checkout.html")
```

### リソース優先順位付けの使用

```nim
# リソース優先順位を作成
var resources: seq[ResourcePriority] = @[]

# HTMLリソースを追加
resources.add(createResourcePriority(
  url = "https://example.com/",
  resourceType = rtHTML,
  isInViewport = true,
  renderBlocking = true
))

# CSSリソースを追加
resources.add(createResourcePriority(
  url = "https://example.com/styles.css",
  resourceType = rtCSS,
  isInViewport = true,
  renderBlocking = true,
  dependsOn = @["https://example.com/"]
))

# 優先順位付けを実行
manager.prioritizeResources(resources)

# プリロードヒントを生成
let preloadHints = manager.generatePreloadHints()
```

## 設定オプション

最適化マネージャーは、以下の3つの戦略から選択できます：

1. **積極的 (Aggressive)** - 帯域幅よりも速度を優先します。
2. **バランス型 (Balanced)** - 速度と帯域幅のバランスを取ります。
3. **控えめ (Conservative)** - 帯域幅を優先し、最小限の最適化を行います。

さらに、以下のようなさまざまな設定パラメータをカスタマイズできます：

- `maxConcurrentConnections` - 最大同時接続数
- `maxConcurrentFetches` - 最大同時フェッチ数
- `enablePreconnect` - 事前接続の有効/無効
- `enablePrefetch` - 事前取得の有効/無効
- `enablePrioritization` - 優先順位付けの有効/無効
- `prefetchHoverDelay` - ホバー時の事前フェッチ遅延
- `disableOnMeteredConnection` - 従量制接続での無効化
- `disableOnSaveData` - データセーブモードでの無効化

## 適応型最適化

このモジュールは、ネットワーク状況に基づいて最適化戦略を自動調整する適応型最適化をサポートしています。例えば、低速な接続では事前取得の数を減らし、高速な接続では増やすことができます。

```nim
# ネットワーク情報を更新（例：ネットワーク状態の変化を検出したとき）
manager.updateNetworkInfo(
  connectionType = "cellular",
  effectiveType = "3g",
  downlinkSpeed = 1.5,
  rtt = 300,
  saveDataMode = false
)
```

## パフォーマンスメトリクス

最適化マネージャーは、以下のようなパフォーマンスメトリクスを収集します：

- 事前接続の成功率と失敗率
- 事前取得の成功率と帯域幅使用量
- リソース読み込み時間と優先順位の相関関係
- ネットワーク条件とページロードパフォーマンスの関係

これらのメトリクスを使用して、最適化戦略の効果を分析し、さらなる改善に役立てることができます。

```nim
# 最適化ステータスを取得
let status = manager.getOptimizationStatus()
echo status
```

## 高度な機能

### クリティカルパスの分析

リソース優先順位付けモジュールは、ウェブページのクリティカルレンダリングパスを分析し、レンダリングブロッキングリソースを特定します。これにより、ページの初期表示に必要な重要なリソースを最適化できます。

```nim
# クリティカルパスを特定
prioritizer.findCriticalPath()

# クリティカルリソースを取得
let criticalResources = prioritizer.getCriticalResources()
```

### 依存関係グラフの構築

リソース間の依存関係を分析し、最適なロード順序を決定します。

```nim
# 依存関係の指定
resources.add(createResourcePriority(
  url = "https://example.com/main.js",
  resourceType = rtJavaScript,
  dependsOn = @["https://example.com/", "https://example.com/styles.css"]
))

# 依存関係に基づいて順序を調整
prioritizer.adjustOrderByDependencies()
```

### プリロードヒントの生成

クリティカルリソースに対して最適なプリロードヒントを生成します。これらのヒントはHTML文書のHEADセクションに追加することで、ブラウザに早期リソース取得を指示できます。

```nim
# プリロードヒントを生成
let preloadHints = manager.generatePreloadHints()

# HTMLに追加するプリロードタグを生成
for hint in preloadHints:
  echo "<link rel=\"preload\" href=\"" & hint.url & "\" as=\"" & hint.`as` & "\" crossorigin>"
```

### ネットワークパフォーマンス予測

接続速度と過去のメトリクスに基づいて、リソースのダウンロード時間を予測します。

```nim
# リソースのネットワーク時間を推定
let estimatedTimeMs = prioritizer.estimateNetworkTime(
  url = "https://example.com/large-image.jpg",
  connectionSpeed = 5.0  # 5Mbps
)
```

## トラブルシューティング

- **事前接続が機能しない**: 最大同時接続数の上限に達しているか、ネットワークエラーが発生している可能性があります。
- **事前取得が機能しない**: 設定で無効になっているか、帯域幅制限に達している可能性があります。
- **リソース優先順位付けが効果を発揮しない**: 依存関係グラフが不完全か、クリティカルリソースが正しく特定されていない可能性があります。

## ベストプラクティス

1. ナビゲーション後にすぐ必要になる可能性の高いドメインにのみ事前接続する
2. クリティカルなリソースにのみ事前取得を使用する
3. リソース優先順位付けを使用して、ページのクリティカルレンダリングパスを最適化する
4. データセーブモードが有効な場合は、事前取得を無効にするか制限する
5. メトリクスを監視して、最適化戦略を継続的に調整する

## 実装の詳細

### PreconnectManager

`PreconnectManager`は、DNSルックアップ、TCP接続、TLSハンドシェイクを事前に実行し、後続のHTTPリクエストで再利用できるようにします。接続プールを管理し、優先度に基づいて接続を追い出すことで、限られたリソースを効率的に使用します。

- DNSキャッシュの活用
- 接続の再利用と寿命管理
- 接続失敗時の再試行ロジック
- 接続統計の収集

### PrefetchManager

`PrefetchManager`は、予測されるナビゲーションやユーザーホバーに基づいてリソースを事前にフェッチします。フェッチしたリソースはHTTPキャッシュに保存され、後続のリクエストで使用されます。

- 優先度ベースのキュー管理
- スロットリングとレート制限
- 条件付きリクエストによるキャッシュ検証
- メモリとディスクキャッシュの統合

### ResourcePrioritizer

`ResourcePrioritizer`は、ページのリソースを分析し、最適な読み込み順序を決定します。レンダリングブロッキングリソース、ビューポート内のリソース、依存関係を考慮して優先順位を計算します。

- 複数要素に基づく重み付け
- トポロジカルソートによる依存関係の解決
- クリティカルレンダリングパスの分析
- リソースタイプごとの特性に基づく最適化

### OptimizationManager

`OptimizationManager`は、上記の3つのコンポーネントを統合し、一貫したAPIを提供します。ユーザーの操作（ホバー、クリックなど）に応じて最適な最適化戦略を適用します。

- ネットワーク状態に基づく適応型最適化
- ユーザー行動に基づく予測
- パフォーマンスメトリクスの収集と分析
- データセーブモードとメータード接続の考慮

## 完全な例

```nim
import std/[tables, asyncdispatch, json]
import network/optimization/optimization_manager
import network/cache/http_cache_manager

# HTTPキャッシュマネージャーを初期化
let cacheConfig = newCacheConfig()
var cacheManager = newHttpCacheManager(cacheConfig)

# 最適化設定を作成（バランス型）
let settings = defaultOptimizationSettings(osBalanced)

# 最適化マネージャーを初期化
var manager = newOptimizationManager(
  cacheManager = cacheManager,
  settings = settings
)

# ナビゲーションを開始
manager.startNavigation("https://example.com")

# 主要なドメインに事前接続
manager.preconnectOrigins(@["api.example.com", "cdn.example.com", "fonts.example.com"])

# リソース優先順位を設定
var resources: seq[ResourcePriority] = @[]
resources.add(createResourcePriority(url = "https://example.com/", resourceType = rtHTML))
resources.add(createResourcePriority(url = "https://cdn.example.com/styles.css", resourceType = rtCSS))
resources.add(createResourcePriority(url = "https://cdn.example.com/main.js", resourceType = rtJavaScript))
manager.prioritizeResources(resources)

# プリロードヒントを生成
let preloadHints = manager.generatePreloadHints()
for hint in preloadHints:
  echo "Preload: ", hint.url, " as ", hint.`as`

# 最適化ステータスを表示
let status = manager.getOptimizationStatus()
echo pretty(status)

# マネージャーを閉じる
manager.close()
``` 