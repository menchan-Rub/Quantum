// src/zig/dom/document.zig
// DOM (Document Object Model) の Document インターフェースに対応する構造体を定義します。
// この Document は、DOM ツリー全体のルート（根）となり、
// ツリーを構成するノード（要素、テキストなど）を作成するためのファクトリメソッド群を提供します。
// また、DOM の変更を監視する MutationObserver の管理も行います。

const std = @import("std");
const mem = @import("../memory/allocator.zig"); // グローバルアロケータへの参照
const errors = @import("../util/error.zig"); // 共通エラー定義
const Node = @import("./node.zig").Node;
const NodeType = @import("./node_type.zig").NodeType;
const EventTarget = @import("../events/event_target.zig").EventTarget;
const validation = @import("../util/validation.zig"); // XML 名や名前空間の検証ユーティリティ
const traversal = @import("./traversal.zig"); // DOM ツリー探索ユーティリティ

// --- DOM ノード型のインポート ---
// Document が生成する必要のある具体的なノード型をインポートします。
const Element = @import("./element.zig").Element;
const Text = @import("./text.zig").Text;
const Comment = @import("./comment.zig").Comment; // コメントノード
const DocumentFragment = @import("./document_fragment.zig").DocumentFragment; // ドキュメントフラグメント
const Attr = @import("./attribute.zig").Attr; // 属性ノード (注意: DOM Core では Node だが、WHATWG DOM では異なる扱い)
// const DocumentType = @import("./document_type.zig").DocumentType; // 必要に応じて DocumentType もインポート

// --- MutationObserver 関連の型をインポートします ---
const MutationObserver = @import("./mutations/mutation_observer.zig").MutationObserver;
const MutationRecord = @import("./mutations/mutation_record.zig").MutationRecord;
const MutationObserverInit = @import("./mutations/mutation_observer.zig").MutationObserverInit;
// const MutationType = @import("./mutations/mutation_record.zig").MutationType; // 必要であれば MutationType も

// --- マイクロタスクスケジューラのインターフェース（仮） ---
// 本来はイベントループと連携するが、ここではインターフェースのみ定義。
const MicrotaskScheduler = struct {
    // タスク（コールバック関数）をキューに追加する関数ポインタ
    queueTaskFn: *const fn (task: *const fn (*anyopaque.Context) void, context: *anyopaque.Context) void,
    // スケジューラ固有のコンテキスト（必要であれば）
    scheduler_context: *anyopaque.Context = undefined,

    pub fn queueTask(self: MicrotaskScheduler, task: *const fn (*anyopaque.Context) void, context: *anyopaque.Context) void {
        self.queueTaskFn(task, context);
    }
};

// HTML 名前空間の URI 定数
pub const html_ns = "http://www.w3.org/1999/xhtml";
// XML 名前空間の URI 定数
pub const xml_ns = "http://www.w3.org/XML/1998/namespace";
// XMLNS 名前空間の URI 定数
pub const xmlns_ns = "http://www.w3.org/2000/xmlns/";

// Document インターフェース、すなわちウェブページのコンテンツ全体を表現する中心的なオブジェクトです。
// DOMツリーのルート（根）として機能し、様々なノード（要素、テキスト、コメントなど）を
// 生成するためのファクトリメソッド群を提供します。
// また、Node インターフェースの基本的な機能も内包しています。
pub const Document = struct {
    // --- 基本ノード情報 ---
    // Node インターフェースの機能をコンポジション（包含）によって実現します。
    // これにより、Document も DOM ツリーの一部として扱えます。
    // Document 自身の node_type は常に .document_node です。
    base_node: Node,

    // --- ドキュメント固有のメタデータ ---
    // ドキュメントがどこから来たのか、どのような種類なのかを示す情報です。
    url: ?[]const u8 = null, // ドキュメントがロードされた元のURL。ローカルファイルやメモリから生成された場合は null になることもあります。
    content_type: []const u8 = "application/xml", // ドキュメントのMIMEタイプ。HTMLパーサーによって "text/html" に設定されることが一般的です。XMLパーサーの場合は "application/xml" や "application/xhtml+xml" などになります。
    doctype: ?*Node = null, // ドキュメントタイプ宣言 (<!DOCTYPE ...>) を表す DocumentType ノードへのポインタ。存在しない場合は null です。
    documentElement: ?*Element = null, // ドキュメントのルート要素。HTML文書であれば <html> 要素、XML文書であればそのルート要素を指します。

    // --- メモリ管理 ---
    // この Document インスタンスおよび、それが所有する全てのノードや
    // 内部データ構造（リスト、マップなど）の生成・破棄に使用されるアロケータです。
    // アプリケーション全体で共有されるグローバルアロケータを使用することも、
    // この Document 専用のアロケータを割り当てることも可能です。
    allocator: std.mem.Allocator,

    // --- DOM変更監視 (MutationObserver) ---
    // ドキュメント内の変更を監視するための仕組みに関連するフィールド群です。
    /// この Document に現在登録されているアクティブな MutationObserver インスタンスのリスト。
    /// これらのオブザーバーは、指定された条件に合致するDOM変更が発生した際に通知を受け取ります。
    activeObservers: std.ArrayList(*MutationObserver),
    /// 発生したものの、まだオブザーバーに通知されていない MutationRecord のキュー。
    /// DOM操作が行われるたびに、関連するレコードがここに追加される可能性があります。
    /// このキューは Document ごとに一つ存在します。
    pendingRecords: std.ArrayList(*MutationRecord),
    /// `pendingRecords` に溜まった変更通知をオブザーバーに配信する処理 (`notifyObservers`) が、
    /// マイクロタスクとしてイベントループにスケジュール済みかどうかを示すフラグ。
    /// 不要な重複スケジュールを防ぐために使用されます。
    notification_scheduled: bool = false,

    // --- マイクロタスクスケジューラ連携 ---
    // MutationObserver の通知など、DOM仕様でマイクロタスクとして実行されるべき処理を
    // スケジュールするためのインターフェースへの参照です。
    // 通常、ブラウザのイベントループシステムと統合され、その一部として提供されます。
    // ここではインターフェースのみを定義し、実際のスケジューラは外部から設定されることを想定しています。
    microtask_scheduler: ?MicrotaskScheduler = null,

    // --- 高速要素アクセス (IDキャッシュ) ---
    // `getElementById` メソッドによる要素検索を高速化するためのキャッシュ機構です。
    // キーには要素のID文字列、値にはそのIDを持つ Element ノードへのポインタを格納します。
    // このマップは、要素の追加・削除、または要素の `id` 属性が変更された際に、
    // 適切に更新されなければなりません。更新ロジックは関連するDOM操作メソッド内に実装されます。
    id_element_map: std.HashMap([]const u8, *Element, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    // Document インスタンスを生成し、初期化します。
    // 新しい、空の Document オブジェクトを作成するためのコンストラクタです。
    // `content_type_param` はコンパイル時に決定される文字列リテラルである必要があります。
    // これは、Document の基本的な性質（HTMLかXMLかなど）を早期に確定させるためです。
    //
    // 引数:
    //   allocator: この Document 及びその内部構造で使用されるアロケータ。
    //   content_type_param: ドキュメントのコンテントタイプ（例: "text/html", "application/xml"）。
    //
    // 戻り値:
    //   成功した場合: 初期化された Document へのポインタ。
    //   失敗した場合: メモリ割り当てエラーなどのエラーコード。
    pub fn create(allocator: std.mem.Allocator, comptime content_type_param: []const u8) !*Document {
        // まず、Document 構造体自身のメモリをアロケータから確保します。
        const doc = try allocator.create(Document);
        // この関数内で後続の初期化処理（リストやマップの初期化、EventTargetの生成など）が失敗した場合に備え、
        // 既に確保した `doc` のメモリがリークしないように `errdefer` を設定します。
        // これにより、エラー発生時には自動的に `allocator.destroy(doc)` が呼び出され、メモリが解放されます。
        errdefer allocator.destroy(doc);

        // --- 内部データ構造の初期化 ---
        // Document が内部で使用する動的データ構造を初期化します。
        // これらの初期化が失敗した場合も、上記 `errdefer` によって `doc` 全体が解放されるため、
        // 個別の解放処理をここに記述する必要はありません。

        // MutationObserver を管理するためのリストを初期化します。初期容量はデフォルト（通常は小さい値）です。
        const observers = try std.ArrayList(*MutationObserver).initCapacity(allocator, 0);
        errdefer observers.deinit(); // observers の初期化成功後、後続でエラーが起きた場合に備える

        // 保留中の MutationRecord を格納するリストを初期化します。こちらも初期容量はデフォルトです。
        const records = try std.ArrayList(*MutationRecord).initCapacity(allocator, 0);
        errdefer records.deinit(); // records の初期化成功後、後続でエラーが起きた場合に備える

        // ID による要素検索を高速化するためのハッシュマップを初期化します。
        // キーは文字列 (要素の ID) なので `std.hash_map.StringContext` を使用します。
        // `std.hash_map.default_max_load_percentage` は、ハッシュマップがリハッシュ（内部ストレージの拡張）を
        // 行うタイミングを決定する負荷率のデフォルト値です。
        const id_map = try std.HashMap([]const u8, *Element, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
        // HashMap の初期化成功後、後続でエラーが起きた場合に備える (EventTarget.create など)
        // HashMap の deinit はキーと値の解放を行わないため、Document.destroy で適切に処理する必要がありますが、
        // create 中のエラーパスでは、まだ要素は追加されていないため、単純な deinit で問題ありません。
        errdefer id_map.deinit();

        // Document 構造体の各フィールドを初期値で設定します。
        doc.* = Document{
            .base_node = Node{
                .node_type = .document_node,
                .owner_document = doc, // owner_document は Document 自身を指します。
                .parent_node = null, // Document ノードは親を持ちません。
                .first_child = null, // 初期状態では子ノードはありません。ルート要素や Doctype が後で追加されます。
                .last_child = null,
                .previous_sibling = null,
                .next_sibling = null,
                .specific_data = null, // Node としての固有データは Document 構造体自身が持ちます。
                // Node の基本機能である EventTarget を初期化します。
                // EventTarget の初期化失敗時も上位の errdefer で doc が解放されます。
                .event_target = try EventTarget.create(allocator),
            },
            .content_type = content_type_param,
            .allocator = allocator,
            // 先ほど初期化したリストとマップを設定します。
            .activeObservers = observers,
            .pendingRecords = records,
            .id_element_map = id_map,
            // notification_scheduled はデフォルトで false
            // microtask_scheduler はデフォルトで null
        };

        std.log.debug("新しい Document を生成しました (コンテントタイプ: {s})", .{content_type_param});
        return doc;
    }

    // Document インスタンスと、それが管理する全てのノード、および関連リソースを解放します。
    pub fn destroy(doc: *Document) void {
        std.log.debug("Document ({*}) とそのノード群の破棄を開始します...", .{doc});

        // 1. Document が直接持つ子ノード（通常は Doctype やルート要素）を再帰的に破棄します。
        // Node の destroyRecursive メソッドを利用して、ツリー全体を安全に解放します。
        // これにより、documentElement や doctype ポインタが指すノードも解放されます。
        var child = doc.base_node.first_child;
        while (child) |c| {
            const next = c.next_sibling;
            // destroyRecursive は子ノード自身と、その子孫、関連リソース（EventTargetなど）を解放します。
            c.destroyRecursive(doc.allocator);
            child = next;
        }
        doc.base_node.first_child = null;
        doc.base_node.last_child = null;
        doc.documentElement = null; // ポインタをクリア
        doc.doctype = null; // ポインタをクリア
        
        // Node.destroyRecursive が EventTarget の解放も担当するため、ここでの明示的な呼び出しは不要です。
        // doc.base_node.event_target.destroy();

        // 2. まだ処理されていない MutationRecord がキューに残っていれば、それらを全て破棄します。
        std.log.debug("ペンディング中の MutationRecord ({d} 件) を破棄します...", .{doc.pendingRecords.items.len});
        for (doc.pendingRecords.items) |record| {
            // 各 MutationRecord の destroy メソッドを呼び出します。
            record.destroy();
        }
        doc.pendingRecords.deinit(); // リスト自体のメモリを解放

        // 3. アクティブな MutationObserver を追跡していたリスト自体のメモリを解放します。
        // オブザーバーインスタンス自体のライフサイクルは管理しません（他の場所で管理される）。
        std.log.debug("アクティブな MutationObserver リストを解放します ({d} 件)...", .{doc.activeObservers.items.len});
        doc.activeObservers.deinit();

        // 4. ID 要素マップを破棄します。
        // マップが保持しているキー（文字列スライス）や値（要素ポインタ）は、
        // ノード破棄時に解放されているか、Document の管理外であるため、ここではマップ自体の解放のみ行います。
        std.log.debug("ID 要素マップを破棄します...", .{});
        doc.id_element_map.deinit();

        // 5. Document 構造体自身のメモリを解放します。
        std.log.debug("Document 構造体 ({*}) 自体を解放します...", .{doc});
        doc.allocator.destroy(doc);
        std.log.info("Document の破棄が完了しました。", .{});
    }

    // --- MutationObserver 関連のメソッド群 ---
    
    /// MutationObserver をこの Document の監視対象として登録（アクティブ化）します。
    /// 既に登録済みのオブザーバーであれば、何もせず正常終了します。
    pub fn registerObserver(self: *Document, observer: *MutationObserver) !void {
        // 登録しようとしているオブザーバーが既にリスト内に存在するかどうかを確認します。
        for (self.activeObservers.items) |existing_observer| {
            if (existing_observer == observer) {
                std.log.debug("MutationObserver ({*}) は既に登録されています。", .{observer});
                return; // 既に存在するため、追加処理は行いません。
            }
        }
        // 新しいオブザーバーをアクティブリストの末尾に追加します。
        // append が失敗した場合（メモリ不足など）、エラーが呼び出し元に伝播します。
        try self.activeObservers.append(observer);
        std.log.debug("MutationObserver ({*}) を Document ({*}) に登録しました。", .{ observer, self });
    }
    
    /// 指定された MutationObserver を Document の監視対象から解除します。
    /// 指定されたオブザーバーが登録されていなかった場合は、警告ログを出力して終了します。
    pub fn unregisterObserver(self: *Document, observer: *MutationObserver) void {
        for (self.activeObservers.items, 0..) |existing_observer, i| {
            if (existing_observer == observer) {
                // リスト内の順序は重要ではないため、効率的な swapRemove を使用して削除します。
                _ = self.activeObservers.swapRemove(i);
                std.log.debug("MutationObserver ({*}) を Document ({*}) から登録解除しました。", .{ observer, self });
                return;
            }
        }
        // ループを抜けてきた = 見つからなかった
        std.log.warn("登録解除しようとした MutationObserver ({*}) は Document ({*}) に登録されていませんでした。", .{ observer, self });
    }
    
    /// 生成された MutationRecord を処理待ちキューに追加し、オブザーバーへの通知処理をスケジュールします。
    /// この関数は通常、DOM の変更操作（appendChild, setAttribute など）の内部から呼び出されます。
    pub fn queueMutationRecord(self: *Document, record: *MutationRecord) !void {
        // レコードをペンディングキューに追加します。
        // append が失敗した場合（メモリ不足など）、エラーが呼び出し元に伝播します。
        try self.pendingRecords.append(record);
        std.log.debug("MutationRecord (type: {s}, target: {*}) をキューに追加しました。", .{ @tagName(record.type), record.target });

        // まだ通知がスケジュールされていない場合のみ、新たにスケジュールを行います。
        if (!self.notification_scheduled) {
            self.scheduleNotification();
        }
    }

    /// マイクロタスクによる遅延実行を模倣し、オブザーバーへの通知をスケジュールします。
    /// 本来はイベントループのマイクロタスクキューに notifyObservers の実行を登録します。
    fn scheduleNotification(self: *Document) void {
        // スケジューラが設定されていれば、それを使用してタスクをキューイングします。
        if (self.microtask_scheduler) |scheduler| {
            std.log.info("MutationObserver 通知をマイクロタスクとしてスケジュールします (Document: {*})", .{self});
            // notifyObservers を呼び出すラッパー関数を渡します。
            // コンテキストとして Document 自身を渡します。
            scheduler.queueTask(notifyObserversMicrotaskRunner, @ptrCast(self));
            self.notification_scheduled = true;
        } else {
            // スケジューラがない場合（テスト環境など）、警告を出力します。
            // デバッグ目的で即時実行することも考えられますが、本番動作とは異なります。
            std.log.warn("マイクロタスクスケジューラが設定されていないため、MutationObserver 通知をスケジュールできません (Document: {*})。", .{self});
            // 開発中の代替として即時実行する場合:
            // std.log.warn("代替として即時通知を実行します。", .{});
            // self.notifyObservers();
            // ただし、即時実行はマイクロタスクの挙動とは異なるため注意が必要です。
            // ここではスケジュールフラグのみ立てておきます（手動で notifyObservers を呼ぶ想定）。
        self.notification_scheduled = true;
        }
    }

    // notifyObservers をマイクロタスクとして実行するためのラッパー関数
    fn notifyObserversMicrotaskRunner(context: *anyopaque.Context) void {
        const doc: *Document = @ptrCast(@alignCast(context));
        doc.notifyObservers();
    }

    /// 処理待ちキュー内の MutationRecord を処理し、関心を持つアクティブなオブザーバーに通知します。
    /// このメソッドは、通常イベントループのマイクロタスク処理フェーズで呼び出されることを想定しています。
    /// (scheduleNotification によってスケジュールされます)
    pub fn notifyObservers(self: *Document) void {
        // 通知がスケジュールされていなければ、実行する必要はありません。
        if (!self.notification_scheduled) {
            std.log.debug("notifyObservers が呼び出されましたが、通知はスケジュールされていません (Document: {*})。", .{self});
            return;
        }
        // 通知処理を開始するため、スケジュール済みフラグをリセットします。
        // これにより、この処理中にキューイングされたレコードは次回のマイクロタスクで処理されます。
        self.notification_scheduled = false;

        std.log.debug("ペンディング中の MutationRecord ({d} 件) の処理を開始します (Document: {*})", .{ self.pendingRecords.items.len, self });
        // 処理すべきレコードがなければ、ここで終了します。
        if (self.pendingRecords.items.len == 0) {
            std.log.debug("処理対象の MutationRecord がないため、通知処理を終了します。", .{});
            return;
        }

        // 現在キューにあるレコードのスナップショットを取得します。これは、通知処理中に新たなレコードがキューイングされる可能性があるためです。
        // より効率的な方法として、現在のキューを新しい空のキューと入れ替えます。
        var recordsToProcess = self.pendingRecords; // 古いキューを退避
        // 新しい空のキューを用意し、Document のペンディングキューとして設定します。
        // これ以降 queueMutationRecord で追加されるレコードは新しいキューに入ります。
        // ArrayList の初期化は通常失敗しませんが、万が一に備え、エラーハンドリングを追加することも検討できます。
        self.pendingRecords = std.ArrayList(*MutationRecord).init(self.allocator);
        // 処理後に古いキュー（処理対象レコードを含む）のリソースを解放します。
        defer recordsToProcess.deinit();

        // 各オブザーバーにどのレコードを通知するかを整理するための一時的なデータ構造です。
        // オブザーバーのコールバックには、そのオブザーバーが関心を持つレコードのみを渡す必要があります。
        var observerCallbacks = std.ArrayList(ObserverCallbackInfo).init(self.allocator);
        // 処理完了後、またはエラー発生時に確保したメモリを確実に解放します。
        defer {
            std.log.debug("オブザーバーコールバック情報 ({d} 件) を解放します...", .{observerCallbacks.items.len});
            for (observerCallbacks.items) |*info| {
                // 各オブザーバーに渡すレコードリスト用に確保したメモリを解放します。
                info.records.deinit();
            }
            // オブザーバーとレコードリストのマッピング情報全体を解放します。
            observerCallbacks.deinit();
        }

        // --- ステップ 1: 各レコードを処理し、関心のあるオブザーバーに割り当てる ---
        std.log.debug("各レコード ({d} 件) を処理し、関心のあるオブザーバーに割り当てます...", .{recordsToProcess.items.len});
        for (recordsToProcess.items) |record| {
            // 現在アクティブな全ての MutationObserver について、このレコードに関心があるかを確認します。
            for (self.activeObservers.items) |observer| {
                // observerIsInterested ヘルパー関数を使って、オブザーバーのオプションとレコード内容を照合します。
                if (self.observerIsInterested(observer, record)) {
                    // 関心があると判断された場合、対応するオブザーバーの通知リストにこのレコードを追加します。
                    var found_observer = false;
                    var append_error: ?error = null; // append のエラーを補足するため

                    // 既存のオブザーバー情報があるか探す
                    for (observerCallbacks.items) |*info| {
                        if (info.observer == observer) {
                            // 既存のオブザーバー情報が見つかったので、そのレコードリストに追加します。
                            info.records.append(record) catch |err| {
                                // レコードリストへの追加に失敗した場合の処理。メモリ不足などが考えられますが、基本的には発生しない想定です。ログ出力に留めます。
                                std.log.err("オブザーバー ({*}) の一時レコードリストへの追加に失敗しました: {}", .{ observer, err });
                                append_error = err; // エラーを記録
                            };
                            found_observer = true;
                            break; // このオブザーバーの処理は完了
                        }
                    }

                    // エラーが発生していなければ、次のステップへ
                    if (append_error != null) continue; // エラーがあればこのレコードの処理を中断（次のオブザーバーへ）

                    // このオブザーバーがまだ通知対象リストになければ、新しいエントリを作成します。
                    if (!found_observer) {
                        var new_list = std.ArrayList(*MutationRecord).init(self.allocator);
                        // 新しいレコードリストのメモリ確保に失敗した場合の処理。
                        // ここでエラーが発生すると致命的な可能性があるため、ログを出力し、処理を続行します。
                        errdefer {
                            std.log.err("オブザーバー ({*}) 用の新しいレコードリストの初期化に失敗しました。このオブザーバーへの通知はスキップされます。", .{observer});
                            new_list.deinit(); // 念のため解放
                        }

                        // 新しく作成したリストに、現在のレコードを追加します。
                        try new_list.append(record);

                        // 新しいオブザーバー情報を作成
                        const info = ObserverCallbackInfo{
                           .observer = observer,
                           .records = new_list, 
                        };

                        // オブザーバー情報を全体のリストに追加します。
                        observerCallbacks.append(info) catch |err| {
                            // オブザーバー情報の追加に失敗した場合、関連して確保したリストも解放します。
                            std.log.err("オブザーバーコールバック情報リストへの追加に失敗しました: {}", .{err});
                            new_list.deinit(); // エラー時は確保したリストも解放
                            // このレコードに対するこのオブザーバーの処理は失敗として扱います。
                        }; 
                    }
                } else {
                    // このオブザーバーは現在のレコードの変更に関心がないため、スキップします。
                    // std.log.debug("Observer {any} is not interested in record for target {any}", .{observer, record.target});
                }
            } // activeObservers ループ終了
            // レコードの所有権はまだ移動せず、後でまとめて破棄します。
            // recordsToProcess はループ終了後に破棄されます。
        } // recordsToProcess ループ終了

        // --- ステップ 2: 各オブザーバーのコールバックを呼び出す ---
        std.log.debug("通知対象のオブザーバー ({d} 件) のコールバックを呼び出します...", .{observerCallbacks.items.len});
        for (observerCallbacks.items) |*info| {
            // 渡すべきレコードがリストに存在する場合のみコールバックを呼び出します。
            if (info.records.items.len > 0) {
                // MutationObserver API の takeRecords とは異なり、ここでは処理のために一時的に作成したレコードリストを渡します。
                std.log.debug("オブザーバー ({*}) のコールバックを {d} 件のレコードで呼び出します...", .{ info.observer, info.records.items.len });
                // オブザーバーに登録されたコールバック関数を実行します。
                // コールバック関数内でのエラーはここでは捕捉しません（コールバック側の責務）。
                info.observer.callback(info.records.items, info.observer);
                // コールバック関数がレコードの所有権を持つわけではないため、ここでレコードを破棄するのは安全ではありません。
                // 全てのコールバック呼び出しが終わった後、処理対象だったレコード群 (recordsToProcess) を破棄します。
            } else {
                // 渡すべきレコードがない場合は、コールバックを呼び出す必要はありません。
                std.log.debug("オブザーバー ({*}) に渡すレコードがないため、コールバックは呼び出しません。", .{info.observer});
            }
        } // observerCallbacks ループ終了

        // --- ステップ 3: 処理済みのレコードを破棄 ---
        std.log.debug("処理が完了した MutationRecord ({d} 件) を破棄します...", .{recordsToProcess.items.len});
        for (recordsToProcess.items) |record| {
            record.destroy();
        }
        // recordsToProcess リスト自体の解放は defer 文により保証されています。
        std.log.debug("MutationObserver 通知処理が完了しました (Document: {*})", .{self});
    }

    /// 指定された MutationObserver が、特定の MutationRecord が示す変更に関心があるかどうかを判断します。
    /// オブザーバーの登録オプション（監視範囲、変更の種類）と、発生したミューテーションの詳細（レコードの内容）を比較します。
    fn observerIsInterested(self: *Document, observer: *MutationObserver, record: *MutationRecord) bool {
        // 'self' は現在未使用ですが、将来的な拡張やより複雑なチェックのために残しています。
        _ = self;
        const options = observer.options;
        const target_node = record.target; // 実際に変更が発生したノード
        const observer_target = observer.target; // オブザーバーが登録されているノード

        // 1. ターゲットノードのチェック: 変更されたノードはオブザーバーの監視範囲内か？
        //    監視範囲には、オブザーバーのターゲットノード自体と、'subtree' が true の場合は
        //    そのすべての子孫ノードが含まれます。
        if (target_node != observer_target) {
            // 変更が監視対象ノードで直接発生したわけではない場合。
            // これは、'subtree' オプションが有効であり、かつ変更されたノードが
            // 実際に監視対象ノードの子孫である場合にのみ関連があります。
            if (!options.subtree or !target_node.isDescendantOf(observer_target)) {
                // いいえ、この変更はオブザーバーの指定された領域外です。
                return false;
            }
        }
        // ここに到達した場合、変更されたノードは間違いなく監視範囲内です。

        // 2. 変更タイプのチェック: オブザーバーはこの *種類の* 変更に関心があるか？
        //    レコードのタイプをオブザーバーのオプションと照合します。
        switch (record.type) {
            .attributes => {
                // 属性が変更されました。
                // まず、オブザーバーは属性の変更自体に関心があるか？
                if (!options.attributes) return false;
                
                // はいの場合、attributeFilter は存在するか？
                if (options.attributeFilter) |filter| {
                    // フィルターが存在します。変更された属性の名前は、フィルターリストに *含まれている* 必要があります。
                    if (record.attributeName) |attr_name| {
                        var found_in_filter = false;
                        for (filter) |filter_item| {
                            if (std.mem.eql(u8, attr_name, filter_item)) {
                                found_in_filter = true;
                                break; // 見つかりました！これ以上チェックする必要はありません。
                            }
                        }
                        if (!found_in_filter) return false; // 属性名がフィルターに含まれていませんでした。
                    } else {
                        // これは発生しないはずです: 属性 MutationRecord に attributeName がありません。
                        // 安全のため、関心がないものとして扱います。
                        std.log.warn("属性 MutationRecord に attributeName がありません (ターゲット: {*})", .{record.target});
                        return false; 
                    }
                }
                // `options.attributes` チェックを通過し、フィルターがないか、または属性がフィルターに含まれていた場合、
                // オブザーバーは関心があります。
                // 注: `options.attributeOldValue` は、記録される *内容* (古い値) にのみ影響し、
                // 変更自体にオブザーバーが関心があるか *どうか* には影響しません。
            },
            .characterData => {
                // Text, Comment, または CDataSection ノード内のテキストコンテンツが変更されました。
                if (!options.characterData) return false; // テキストの変更には関心がありません。
                // 注: `options.characterDataOldValue` は、古い値が記録されるかどうかにのみ影響します。
            },
            .childList => {
                // ターゲットノードの子ノードが追加または削除されました。
                if (!options.childList) return false; // 子ノードリストの変更には関心がありません。
            },
        }

        // レコードタイプに関するすべての関連チェックを通過した場合、オブザーバーは関心があります。
        return true;
    }

    // --- DOM ファクトリメソッド --- https://dom.spec.whatwg.org/#dom-document-createelement

    /// 指定されたタグ名を持つ Element ノードを作成します。
    /// HTML ドキュメントの場合、タグ名は自動的に小文字に変換されます。
    pub fn createElement(self: *Document, tag_name: []const u8) !*Node {
        // HTML ドキュメントの場合は HTML 名前空間を使用し、それ以外の場合は名前空間なし (null) とします。
        const ns = if (std.mem.eql(u8, self.content_type, "text/html")) html_ns else null;
        // Element.create は HTML タグ名のための小文字化を内部で処理します。
        return Element.create(self.allocator, self, tag_name, ns, null);
    }

    /// 指定された名前空間 URI と修飾名（例: "prefix:localName"）を持つ Element ノードを作成します。
    /// XML ルールに従って修飾名と名前空間を検証します。
    pub fn createElementNS(self: *Document, namespace_uri: ?[]const u8, qualified_name: []const u8) !*Node {
        // 修飾名を接頭辞とローカル名に解析しようとします。
        // 参照: https://www.w3.org/TR/xml-names/#ns-qualnames
        var prefix: ?[]const u8 = null;
        var local_name: []const u8 = qualified_name;
        if (std.mem.indexOfScalar(u8, qualified_name, ':')) |colon_index| {
            // コロンが見つかりました。接頭辞とローカル名に分割します。
            // 基本的な分割は単一のコロンを想定しています。エッジケースにはより堅牢な解析が必要かもしれません。
            prefix = qualified_name[0..colon_index];
            local_name = qualified_name[colon_index + 1 ..];
            // 抽出された接頭辞が有効な NCName (Non-Colon Name) であることを確認します。
            try validation.validateNCName(prefix.?);
        }

        // ローカル名の部分も有効な NCName である必要があります。
        try validation.validateNCName(local_name);
        // 名前空間制約違反（例: "xml" 接頭辞と間違った名前空間）をチェックします。
        try validation.validateNamespaceAndPrefix(namespace_uri, prefix, local_name);

        // 解析/検証されたコンポーネントで要素を作成します。
        return Element.create(self.allocator, self, local_name, namespace_uri, prefix);
    }

    /// 指定された文字列を含む Text ノードを作成します。
    pub fn createTextNode(self: *Document, data: []const u8) !*Node {
        return Text.create(self.allocator, self, data);
    }

    /// 指定された文字列を含む Comment ノードを作成します。
    /// コメントのデータは "--" を含んではならず、"-" で始まってはなりません。
    /// 参照: https://dom.spec.whatwg.org/#dom-document-createcomment
    pub fn createComment(self: *Document, data: []const u8) !*Node {
        // コメントデータの制約を検証します。
        // DOM 仕様: データは "--" を含んではならず、"-" で始まってはなりません。
        if (data.len > 0 and data[0] == '-') {
            return errors.DomError.SyntaxError; // "-" で始まるのは無効
        }
        if (std.mem.indexOf(u8, data, "--")) |_| {
            return errors.DomError.SyntaxError; // "--" を含むのは無効
        }

        return Comment.create(self.allocator, self, data);
    }

    /// 空の DocumentFragment ノードを作成します。
    /// DocumentFragment はノードの一時的なコンテナとして便利です。
    pub fn createDocumentFragment(self: *Document) !*Node {
        return DocumentFragment.create(self.allocator, self);
    }

    /// 指定されたローカル名を持つ Attr (属性) ノードを作成します。
    /// 注: この方法で作成された属性は、最初はどの要素にも関連付けられていません。
    /// 要素に関連付けるには Element.setAttributeNode または Element.setAttribute を使用してください。
    pub fn createAttribute(self: *Document, local_name: []const u8) !*Node {
        // 属性名を検証します。
        try validation.validateName(local_name); // 属性名には validateName を使用
        // このメソッドで作成された属性は、デフォルトで名前空間や接頭辞を持ちません。
        return Attr.create(self.allocator, self, null, null, local_name, "");
    }

    /// 指定された名前空間 URI と修飾名を持つ Attr (属性) ノードを作成します。
    /// XML ルールに従って修飾名と名前空間を検証します。
    /// 参照: https://dom.spec.whatwg.org/#dom-document-createattributens
    pub fn createAttributeNS(self: *Document, namespace_uri: ?[]const u8, qualified_name: []const u8) !*Node {
        // 修飾名を接頭辞とローカル名に解析しようとします。
        // 参照: https://www.w3.org/TR/xml-names/#ns-qualnames
        var prefix: ?[]const u8 = null;
        var local_name: []const u8 = qualified_name;
        if (std.mem.indexOfScalar(u8, qualified_name, ':')) |colon_index| {
            // コロンが見つかりました。接頭辞とローカル名に分割します。
            prefix = qualified_name[0..colon_index];
            local_name = qualified_name[colon_index + 1 ..];
            // 抽出された接頭辞が有効な NCName であることを確認します。
            try validation.validateNCName(prefix.?);
        }

        // ローカル名の部分も有効な NCName である必要があります。
        try validation.validateNCName(local_name);
        // 名前空間制約違反（例: "xml" 接頭辞と間違った名前空間）をチェックします。
        try validation.validateNamespaceAndPrefix(namespace_uri, prefix, local_name);

        // 解析/検証されたコンポーネントで属性を作成します。初期値は空文字列です。
        return Attr.create(self.allocator, self, namespace_uri, prefix, local_name, "");
    }

    /// 指定された文字列を含む CDATA セクションノードを作成します。
    /// CDATA セクションは XML 文書内でのみ有効です。
    pub fn createCDATASection(self: *Document, data: []const u8) !*Node {
        // HTML 文書では CDATA セクションを作成できません
        if (std.mem.eql(u8, self.content_type, "text/html")) {
            return errors.DomError.NotSupportedError;
        }
        
        // CDATA セクション内では "]]>" を含めることができないため、検証します
        if (std.mem.indexOf(u8, data, "]]>")) |_| {
            return errors.DomError.InvalidCharacterError;
        }
        
        return CDATASection.create(self.allocator, self, data);
    }

    /// 指定されたターゲットと文字列データを持つ ProcessingInstruction ノードを作成します。
    pub fn createProcessingInstruction(self: *Document, target: []const u8, data: []const u8) !*Node {
        // ターゲット名が有効な XML 名前であることを確認します
        try validation.validateName(target);
        
        // HTML 文書では xml で始まるターゲットは許可されていません
        if (std.mem.eql(u8, self.content_type, "text/html") and 
            (std.ascii.eqlIgnoreCase(target, "xml") or 
             (target.len >= 3 and std.ascii.eqlIgnoreCase(target[0..3], "xml")))) {
            return errors.DomError.InvalidCharacterError;
        }
        
        // データ内に "?>" を含めることはできません
        if (std.mem.indexOf(u8, data, "?>")) |_| {
            return errors.DomError.InvalidCharacterError;
        }
        
        return ProcessingInstruction.create(self.allocator, self, target, data);
    }

    /// 新しい Range オブジェクトを作成します。
    pub fn createRange(self: *Document) !*Range {
        var range = try self.allocator.create(Range);
        range.* = Range.init(self);
        return range;
    }

    // --- DOM API (部分的な実装) ---

    /// このドキュメントの最後の子としてノードを追加します。
    /// 注: 特定のノードタイプ（1つの Element、1つの DocumentType、Comment、PI など）のみが
    /// Document の直接の子になることができます。この検証は Node.appendChild 内で行われます。
    pub fn appendChild(self: *Document, node: *Node) !void {
        // ノードを追加するためのコアロジックと検証（Document 固有のルールを含む）は、
        // 汎用的な Node.appendChild メソッドによって処理されます。
        // 参照: https://dom.spec.whatwg.org/#concept-node-append
        try self.base_node.appendChild(node);
    }

    /// 指定された ID を持つドキュメント内の Element ノードを返します。
    /// その ID を持つ要素が見つからない場合は null を返します。
    /// 注: これには、要素に 'id' 属性が登録されている必要があります。
    pub fn getElementById(self: *Document, element_id: []const u8) ?*Node {
        // ID マップが存在する場合は、そこから直接検索します
        if (self.id_map) |map| {
            return map.get(element_id);
        }
        
        // ID マップがない場合は、ドキュメント全体を走査します
        if (self.documentElement) |doc_elem| {
            return findElementById(doc_elem, element_id);
        }
        
        return null;
    }

    // getElementById のヘルパー関数
    fn findElementById(node: *Node, id: []const u8) ?*Node {
        // 現在のノードが要素で、id 属性を持っているか確認
        if (node.node_type == .element_node) {
            const element: *Element = @ptrCast(@alignCast(node.specific_data.?));
            if (element.getAttribute("id")) |attr_value| {
                if (std.mem.eql(u8, attr_value, id)) {
                    return node;
                }
            }
        }
        
        // 子ノードを再帰的に検索
        var child = node.first_child;
        while (child != null) : (child = child.?.next_sibling) {
            if (findElementById(child.?, id)) |found| {
                return found;
            }
        }
        
        return null;
    }

    /// 指定されたタグ名を持つドキュメント内のすべての Element ノードのリストを返します。
    /// 検索は HTML ドキュメントでは大文字小文字を区別せず、それ以外では区別します。
    /// 特殊なタグ名 "*" はすべての要素ノードに一致します。
    pub fn getElementsByTagName(self: *Document, tag_name: []const u8) !std.ArrayList(*Node) {
        var result_list = std.ArrayList(*Node).init(self.allocator);
        errdefer result_list.deinit();
        
        // ドキュメントが空の場合は空のリストを返します
        if (self.documentElement == null) {
            return result_list;
        }
        
        // 特殊なワイルドカード "*" の場合は、すべての要素を収集します
        const is_wildcard = std.mem.eql(u8, tag_name, "*");
        // HTML ドキュメントでは大文字小文字を区別しない比較を使用します
        const is_html = std.mem.eql(u8, self.content_type, "text/html");
        
        try collectElementsByTagName(self.documentElement.?, &result_list, tag_name, is_wildcard, is_html);
        
        return result_list;
    }

    // getElementsByTagName のヘルパー関数
    fn collectElementsByTagName(
        node: *Node, 
        result: *std.ArrayList(*Node), 
        tag_name: []const u8, 
        is_wildcard: bool, 
        is_html: bool
    ) !void {
        if (node.node_type == .element_node) {
            const element: *Element = @ptrCast(@alignCast(node.specific_data.?));
            
            // タグ名が一致するか確認
            var matches = is_wildcard;
            if (!is_wildcard) {
                if (is_html) {
                    // HTML では大文字小文字を区別しない比較
                    matches = std.ascii.eqlIgnoreCase(element.data.tag_name, tag_name);
                } else {
                    // XML では大文字小文字を区別する比較
                    matches = std.mem.eql(u8, element.data.tag_name, tag_name);
                }
            }
            
            if (matches) {
                try result.append(node);
            }
        }
        
        // 子ノードを再帰的に処理
        var child = node.first_child;
        while (child != null) : (child = child.?.next_sibling) {
            try collectElementsByTagName(child.?, result, tag_name, is_wildcard, is_html);
        }
    }

    /// 指定された名前空間 URI とローカル名を持つドキュメント内のすべての Element ノードのリストを返します。
    /// 特殊な値 "*" は、名前空間 URI またはローカル名のワイルドカードとして機能します。
    pub fn getElementsByTagNameNS(self: *Document, namespace_uri: ?[]const u8, local_name: []const u8) !std.ArrayList(*Node) {
        var result_list = std.ArrayList(*Node).init(self.allocator);
        errdefer result_list.deinit();
        
        // ドキュメントが空の場合は空のリストを返します
        if (self.documentElement == null) {
            return result_list;
        }
        
        // 特殊なワイルドカード "*" の処理
        const is_ns_wildcard = namespace_uri != null and std.mem.eql(u8, namespace_uri.?, "*");
        const is_name_wildcard = std.mem.eql(u8, local_name, "*");
        
        try collectElementsByTagNameNS(
            self.documentElement.?, 
            &result_list, 
            namespace_uri, 
            local_name, 
            is_ns_wildcard, 
            is_name_wildcard
        );
        
        return result_list;
    }

    // getElementsByTagNameNS のヘルパー関数
    fn collectElementsByTagNameNS(
        node: *Node, 
        result: *std.ArrayList(*Node), 
        namespace_uri: ?[]const u8, 
        local_name: []const u8,
        is_ns_wildcard: bool,
        is_name_wildcard: bool
    ) !void {
        if (node.node_type == .element_node) {
            const element: *Element = @ptrCast(@alignCast(node.specific_data.?));
            
            // 名前空間とローカル名が一致するか確認
            var ns_matches = is_ns_wildcard;
            if (!is_ns_wildcard) {
                // null と null の比較、または文字列の比較
                if (namespace_uri == null and element.data.namespace_uri == null) {
                    ns_matches = true;
                } else if (namespace_uri != null and element.data.namespace_uri != null) {
                    ns_matches = std.mem.eql(u8, namespace_uri.?, element.data.namespace_uri.?);
                }
            }
            
            var name_matches = is_name_wildcard;
            if (!is_name_wildcard) {
                name_matches = std.mem.eql(u8, local_name, element.data.tag_name);
            }
            
            if (ns_matches and name_matches) {
                try result.append(node);
            }
        }
        
        // 子ノードを再帰的に処理
        var child = node.first_child;
        while (child != null) : (child = child.?.next_sibling) {
            try collectElementsByTagNameNS(
                child.?, 
                result, 
                namespace_uri, 
                local_name, 
                is_ns_wildcard, 
                is_name_wildcard
            );
        }
    }

    /// 指定されたクラス名を持つドキュメント内のすべての Element ノードのリストを返します。
    /// 複数のクラス名はスペースで区切られます。
    pub fn getElementsByClassName(self: *Document, class_names: []const u8) !std.ArrayList(*Node) {
        var result_list = std.ArrayList(*Node).init(self.allocator);
        errdefer result_list.deinit();
        
        // ドキュメントが空の場合は空のリストを返します
        if (self.documentElement == null) {
            return result_list;
        }
        
        // クラス名をトリミングしてスペースで分割
        var class_list = std.ArrayList([]const u8).init(self.allocator);
        defer class_list.deinit();
        
        var it = std.mem.tokenize(u8, class_names, " \t\n\r\f");
        while (it.next()) |class| {
            if (class.len > 0) {
                try class_list.append(class);
            }
        }
        
        // クラス名が指定されていない場合は空のリストを返します
        if (class_list.items.len == 0) {
            return result_list;
        }
        
        try collectElementsByClassName(self.documentElement.?, &result_list, class_list.items);
        
        return result_list;
    }

    // getElementsByClassName のヘルパー関数
    fn collectElementsByClassName(
        node: *Node, 
        result: *std.ArrayList(*Node), 
        class_names: []const []const u8
    ) !void {
        if (node.node_type == .element_node) {
            const element: *Element = @ptrCast(@alignCast(node.specific_data.?));
            
            // class 属性を取得
            if (element.getAttribute("class")) |class_attr| {
                var all_classes_match = true;
                
                // 各クラス名について、要素のクラス属性に含まれているか確認
                for (class_names) |class_name| {
                    var found = false;
                    var class_it = std.mem.tokenize(u8, class_attr, " \t\n\r\f");
                    
                    while (class_it.next()) |elem_class| {
                        if (std.mem.eql(u8, elem_class, class_name)) {
                            found = true;
                            break;
                        }
                    }
                    
                    if (!found) {
                        all_classes_match = false;
                        break;
                    }
                }
                
                if (all_classes_match) {
                    try result.append(node);
                }
            }
        }
        
        // 子ノードを再帰的に処理
        var child = node.first_child;
        while (child != null) : (child = child.?.next_sibling) {
            try collectElementsByClassName(child.?, result, class_names);
        }
    }

    /// 指定されたセレクタに一致する最初の Element を返します。
    /// 一致する要素がない場合は null を返します。
    pub fn querySelector(self: *Document, selectors: []const u8) !?*Node {
        // セレクタパーサーとマッチャーを初期化
        var parser = try SelectorParser.init(self.allocator, selectors);
        defer parser.deinit();
        
        var selector_list = try parser.parse();
        defer selector_list.deinit();
        
        // ドキュメントが空の場合は null を返します
        if (self.documentElement == null) {
            return null;
        }
        
        // ドキュメント要素から始めて、最初に一致する要素を検索
        return findFirstMatchingElement(self.documentElement.?, selector_list);
    }

    // querySelector のヘルパー関数
    fn findFirstMatchingElement(node: *Node, selector_list: SelectorList) ?*Node {
        if (node.node_type == .element_node) {
            // 現在の要素がセレクタに一致するか確認
            if (selector_list.matches(node)) {
                return node;
            }
        }
        
        // 子ノードを再帰的に処理
        var child = node.first_child;
        while (child != null) : (child = child.?.next_sibling) {
            if (findFirstMatchingElement(child.?, selector_list)) |found| {
                return found;
            }
        }
        
        return null;
    }

    /// 指定されたセレクタに一致するすべての Element のリストを返します。
    pub fn querySelectorAll(self: *Document, selectors: []const u8) !std.ArrayList(*Node) {
        var result_list = std.ArrayList(*Node).init(self.allocator);
        errdefer result_list.deinit();
        
        // セレクタパーサーとマッチャーを初期化
        var parser = try SelectorParser.init(self.allocator, selectors);
        defer parser.deinit();
        
        var selector_list = try parser.parse();
        defer selector_list.deinit();
        
        // ドキュメントが空の場合は空のリストを返します
        if (self.documentElement == null) {
            return result_list;
        }
        
        // ドキュメント要素から始めて、一致するすべての要素を収集
        try collectMatchingElements(self.documentElement.?, &result_list, selector_list);
        
        return result_list;
    }

    // querySelectorAll のヘルパー関数
    fn collectMatchingElements(
        node: *Node, 
        result: *std.ArrayList(*Node), 
        selector_list: SelectorList
    ) !void {
        if (node.node_type == .element_node) {
            // 現在の要素がセレクタに一致するか確認
            if (selector_list.matches(node)) {
                try result.append(node);
            }
        }
        
        // 子ノードを再帰的に処理
        var child = node.first_child;
        while (child != null) : (child = child.?.next_sibling) {
            try collectMatchingElements(child.?, result, selector_list);
        }
    }
};

// notifyObservers で内部的に使用されるヘルパー構造体
const ObserverCallbackInfo = struct {
    observer: *MutationObserver,
    records: std.ArrayList(*MutationRecord), // 現在の通知サイクルでこの特定のオブザーバーに関連するレコードのリスト
};

// Document の作成と基本プロパティの基本的なテスト
test "Document creation and basic properties" {
    const allocator = std.testing.allocator;
    var doc = try Document.create(allocator, "text/html");
    defer doc.destroy();

    try std.testing.expect(doc.base_node.node_type == .document_node);
    try std.testing.expect(doc.base_node.owner_document == doc);
    try std.testing.expectEqualStrings("text/html", doc.content_type);
    try std.testing.expect(doc.documentElement == null); // ドキュメントは最初は空
    try std.testing.expect(doc.doctype == null); // ドキュメントは最初は doctype なし
    try std.testing.expect(doc.base_node.parent_node == null); // Document ノード自体は親を持たない

    // MutationObserver フィールドの初期状態をチェック
    try std.testing.expect(doc.activeObservers.items.len == 0);
    try std.testing.expect(doc.pendingRecords.items.len == 0);
    try std.testing.expect(doc.notification_scheduled == false);
}

// Document への子ノード追加の基本的なテスト
test "Document appendChild basic" {
    const allocator = std.testing.allocator;
    // 最初はより厳格なノード階層ルールを持つ XML コンテンツタイプを使用
    var doc = try Document.create(allocator, "application/xml");
    defer doc.destroy();

    // ドキュメントのファクトリメソッドを使用して Element を作成
    const element_node = try doc.createElement("root");
    // element_node の defer destroy は不要です。doc.destroy() が子ノードを処理します。

    // 最初の要素を追加するのは成功するはずです
    try doc.appendChild(element_node);
    try std.testing.expect(doc.base_node.first_child == element_node);
    try std.testing.expect(doc.base_node.last_child == element_node);
    try std.testing.expect(element_node.parent_node == &doc.base_node);
    try std.testing.expect(doc.documentElement == element_node); // documentElement になるはずです

    // *2番目の* Element を追加しようとすると失敗するはずです（ルート要素は1つだけ許可）
    const element_node2 = try doc.createElement("anotherRoot");
    const append_result = doc.appendChild(element_node2);
    if (append_result) |_| {
        std.debug.panic("2番目の要素を追加する際に HierarchyRequestError が期待されましたが、成功しました。", .{});
    } else |err| {
        // 正しいエラーが返されたことを確認
        try std.testing.expect(err == errors.DomError.HierarchyRequestError);
        // 追加に失敗したノードはドキュメントツリーの一部ではないため、クリーンアップします。
        element_node2.destroyRecursive(allocator);
    }

    // Text ノードを Document に直接追加しようとするのも失敗するはずです
    const text_node = try doc.createTextNode("Invalid text directly under document");
    const append_text_result = doc.appendChild(text_node);
    if (append_text_result) |_| {
        std.debug.panic("Text ノードをドキュメントに追加する際に HierarchyRequestError が期待されましたが、成功しました。", .{});
    } else |err| {
        // 正しいエラーを確認
        try std.testing.expect(err == errors.DomError.HierarchyRequestError);
        // 追加されなかったノードをクリーンアップします。
        text_node.destroyRecursive(allocator);
    }

    // Document appendChild の詳細なノードタイプテストに関する以前の TODO は削除されました。
    // これらのテストが主な制約（要素は1つ、テキストなし）をカバーしているためです。
    // さらに、DocumentType、Comment、ProcessingInstruction を含むテストを追加できます。
}

// --- ファクトリメソッドのテスト ---
test "Document factory methods" {
    const allocator = std.testing.allocator;
    var html_doc = try Document.create(allocator, "text/html");
    defer html_doc.destroy();
    var xml_doc = try Document.create(allocator, "application/xml");
    defer xml_doc.destroy();

    // createElement のテスト (HTML ドキュメント)
    const div_node = try html_doc.createElement("DIV"); // 大文字入力
    // defer は不要です。html_doc.destroy() が、デタッチされていないファクトリで作成されたノードをクリーンアップします。
    // 特定の Element データを取得してプロパティをチェック
    const div_elem: *Element = @ptrCast(@alignCast(div_node.specific_data.?));
    try std.testing.expectEqualStrings("div", div_elem.data.tag_name); // 小文字化されているはず
    try std.testing.expectEqualStrings(html_ns, div_elem.data.namespace_uri.?); // HTML 名前空間を持つはず
    try std.testing.expect(div_node.owner_document == html_doc); // Node の ownerDocument をチェック

    // createElement のテスト (XML ドキュメント)
    const xml_node = try xml_doc.createElement("Book"); // 大文字小文字は保持されるはず
    const xml_elem: *Element = @ptrCast(@alignCast(xml_node.specific_data.?));
    try std.testing.expectEqualStrings("Book", xml_elem.data.tag_name); // 大文字小文字保持
    try std.testing.expect(xml_elem.data.namespace_uri == null); // createElement 経由の XML にはデフォルトの名前空間なし
    try std.testing.expect(xml_node.owner_document == xml_doc); // Node の ownerDocument をチェック

    // createTextNode のテスト
    const text_data = "Some sample text";
    const text_node = try html_doc.createTextNode(text_data);
    try std.testing.expect(text_node.node_type == .text_node);
    const text: *Text = @ptrCast(@alignCast(text_node.specific_data.?));
    try std.testing.expectEqualStrings(text_data, text.data);
    try std.testing.expect(text_node.owner_document == html_doc); // Node の ownerDocument をチェック

    // createElementNS のテスト (HTML ドキュメントで SVG 要素を作成)
    const svg_ns = "http://www.w3.org/2000/svg";
    const svg_node = try html_doc.createElementNS(svg_ns, "svg"); // タグ名はここで小文字
    const svg_elem: *Element = @ptrCast(@alignCast(svg_node.specific_data.?));
    try std.testing.expectEqualStrings("svg", svg_elem.data.tag_name); // ローカル名 "svg" であるはず
    try std.testing.expectEqualStrings(svg_ns, svg_elem.data.namespace_uri.?); // 名前空間が正しく設定されているはず

    // createElementNS のテスト (XML ドキュメントで接頭辞付き)
    const xlink_ns = "http://www.w3.org/1999/xlink";
    const xlink_node = try xml_doc.createElementNS(xlink_ns, "xlink:href");
    const xlink_elem: *Element = @ptrCast(@alignCast(xlink_node.specific_data.?));
    // 現在の Element.create に基づき、tag_name はローカル名を格納します。
    try std.testing.expectEqualStrings("href", xlink_elem.data.tag_name); // ローカル名
    try std.testing.expectEqualStrings("xlink", xlink_elem.data.prefix.?); // 接頭辞が格納されていることを確認
    try std.testing.expectEqualStrings(xlink_ns, xlink_elem.data.namespace_uri.?); // 名前空間が格納されていることを確認

    // createComment のテスト
    const comment_node = try xml_doc.createComment(" This is a comment ");
    try std.testing.expect(comment_node.node_type == .comment_node);
    const comment: *Comment = @ptrCast(@alignCast(comment_node.specific_data.?));
    try std.testing.expectEqualStrings(" This is a comment ", comment.data);
    try std.testing.expect(comment_node.owner_document == xml_doc);

    // createDocumentFragment のテスト
    const frag_node = try xml_doc.createDocumentFragment();
    try std.testing.expect(frag_node.node_type == .document_fragment_node);
    try std.testing.expect(frag_node.owner_document == xml_doc);
    // DocumentFragment はこのモデルでは特定のデータ構造を持たず、子ノードが最初は null であることを確認
    try std.testing.expect(frag_node.first_child == null);
    try std.testing.expect(frag_node.last_child == null);

    // createAttribute のテスト
    const attr_node = try xml_doc.createAttribute("id");
    try std.testing.expect(attr_node.node_type == .attribute_node);
    const attr: *Attr = @ptrCast(@alignCast(attr_node.specific_data.?));
    try std.testing.expectEqualStrings("id", attr.data.local_name);
    try std.testing.expect(attr.data.namespace_uri == null);
    try std.testing.expect(attr.data.prefix == null);
    try std.testing.expectEqualStrings("", attr.data.value); // 初期値は空文字列
    try std.testing.expect(attr_node.owner_document == xml_doc);
    // 注: 作成された属性はまだどの要素にもアタッチされていません。

    // createAttributeNS のテスト
    const ns_attr_node = try xml_doc.createAttributeNS(xlink_ns, "xlink:href");
    try std.testing.expect(ns_attr_node.node_type == .attribute_node);
    const ns_attr: *Attr = @ptrCast(@alignCast(ns_attr_node.specific_data.?));
    try std.testing.expectEqualStrings("href", ns_attr.data.local_name);
    try std.testing.expectEqualStrings("xlink", ns_attr.data.prefix.?);
    try std.testing.expectEqualStrings(xlink_ns, ns_attr.data.namespace_uri.?);
    try std.testing.expectEqualStrings("", ns_attr.data.value); // 初期値は空文字列
    try std.testing.expect(ns_attr_node.owner_document == xml_doc);

    // createComment の無効な入力のテスト
    const invalid_comment_start = xml_doc.createComment("-invalid");
    if (invalid_comment_start) |_| {
        std.debug.panic("'-' で始まるコメントで SyntaxError が期待されましたが、成功しました。", .{});
    } else |err| {
        try std.testing.expect(err == errors.DomError.SyntaxError);
    }

    const invalid_comment_double_dash = xml_doc.createComment("valid -- invalid");
    if (invalid_comment_double_dash) |_| {
        std.debug.panic("'--' を含むコメントで SyntaxError が期待されましたが、成功しました。", .{});
    } else |err| {
        try std.testing.expect(err == errors.DomError.SyntaxError);
    }
} 