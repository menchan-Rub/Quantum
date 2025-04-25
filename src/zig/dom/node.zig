// src/zig/dom/node.zig
// DOM ツリーの基本となる Node 構造体を定義します。
// 全てのノードタイプはこの Node 構造体の特性を継承（または内包）します。

const std = @import("std");
const mem = @import("../memory/allocator.zig"); // Global allocator
const errors = @import("../util/error.zig"); // Use 'errors' as the module alias
const NodeType = @import("./node_type.zig").NodeType;
const Document = @import("./document.zig").Document;
const Text = @import("./text.zig").Text; // Import Text type
const EventTarget = @import("../events/event_target.zig").EventTarget;
const Event = @import("../events/event.zig").Event;
const EventListener = @import("../events/event_listener.zig").EventListener;
const AddEventListenerOptions = @import("../events/event_listener.zig").AddEventListenerOptions;
const EventListenerOptions = @import("../events/event_listener.zig").EventListenerOptions;
const Element = @import("./element.zig").Element; // Node.destroy から参照するため追加
const MutationRecord = @import("./mutations/mutation_record.zig").MutationRecord;
const MutationType = @import("./mutations/mutation_record.zig").MutationType;

// Forward declaration for Document is no longer needed if Document is imported directly
// const Document = @import("./document.zig").Document; // Import Document
// const Document = @import("./document.zig").Document; // Import Document fully

// Node 構造体。
// DOM の基本的な構成要素。
pub const Node = struct {
    // このノードの種類
    node_type: NodeType,
    // ノードの所有者であるドキュメントへのポインタ (null の場合もある、例: DocumentFragment)
    // ポインタにすることで、ノード自体が Document を所有しないようにする。
    owner_document: ?*Document, // Now uses the imported Document type

    // ツリー構造のためのポインタ
    parent_node: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    previous_sibling: ?*Node = null,
    next_sibling: ?*Node = null,

    // このノードに固有のデータへのポインタ (具象ノードへのポインタ)
    // tagged union の代わり。これにより Node* を介して操作できる。
    // ポインタの型は node_type に依存する。
    // 例: node_type が .element_node ならば *Element
    //     node_type が .text_node ならば *Text
    // メモリ管理の複雑さを避けるため、当面は void ポインタを使用する。
    // 型安全性を高めるには、tagged union や他の設計を検討する。
    specific_data: ?*anyopaque = null,

    // イベントリスナーを管理するための EventTarget
    // Node は EventTarget インターフェースを実装する
    event_target: EventTarget,

    // Node インスタンスを作成する関数 (内部用)
    // allocator: アロケータ
    // node_type: 作成するノードのタイプ
    // owner_document: 所有者ドキュメント
    // specific_data: このノード固有のデータへのポインタ
    pub fn create(allocator: std.mem.Allocator, node_type: NodeType, owner_document: ?*Document, specific_data: ?*anyopaque) !*Node {
        const node = try allocator.create(Node);
        errdefer allocator.destroy(node);

        // EventTarget を初期化
        const et = try EventTarget.create(allocator);
        // Node 初期化失敗時に EventTarget を破棄する errdefer は不要
        // (Node が破棄されれば、それに含まれる EventTarget もスコープ外になるか、
        // Node.destroy で明示的に破棄されるため)

        node.* = Node{
            .node_type = node_type,
            .owner_document = owner_document,
            .specific_data = specific_data,
            .event_target = et,
            // 他のポインタは null で初期化される
        };
        return node;
    }

    // Node インスタンスと、その子ノード、具象データを再帰的に破棄する関数。
    pub fn destroyRecursive(self: *Node, allocator: std.mem.Allocator) void {
        std.log.debug("Recursively destroying Node (type: {s}) starting...", .{self.node_type.toString()});

        // 1. 子ノードを再帰的に破棄
        var child = self.first_child;
        while (child) |c| {
            const next = c.next_sibling;
            // 子ノードに対して再帰的に destroyRecursive を呼び出す
            c.destroyRecursive(allocator);
            child = next;
        }
        self.first_child = null; // リンクをクリア
        self.last_child = null;

        // 2. 具象ノードデータ (specific_data) を破棄
        //    型ごとに適切な destroy 関数を呼び出す
        if (self.specific_data) |data_ptr| {
            switch (self.node_type) {
                .element_node => {
                    const element: *Element = @ptrCast(@alignCast(data_ptr));
                    // html_data (Union) の destroy ヘルパーを呼び出す
                    element.html_data.destroy(allocator);
                    element.html_data = .none; // クリア

                    // 次に Element 自身と ElementData を破棄
                    element.destroy(allocator);
                },
                .text_node => {
                    const text: *Text = @ptrCast(@alignCast(data_ptr));
                    // Text.destroy が data と Text 自身を解放する
                    text.destroy(allocator);
                },
                .document_node => {
                    // Document.destroy が起点となり、子を destroyRecursive で破棄するため、
                    // Document 自身が Node を内包 or specific_data が Document* を指す。
                    // Document.destroy で処理されるため、ここでは何もしない (二重解放防止)。
                    // Document* をキャストして使う場合:
                    // const doc: *Document = @ptrCast(@alignCast(data_ptr));
                    // doc.destroy(); // これは Document 破棄の起点で呼ばれるはず
                },
                // TODO: 他のノードタイプ (Comment, DocumentType など) の破棄処理
                else => {
                    std.log.warn("destroyRecursive: Unhandled node type {s} for specific_data destruction.", .{self.node_type.toString()});
                    // 不明なデータ型の場合、リークする可能性がある
                },
            }
            self.specific_data = null; // ポインタをクリア
        }

        // 3. イベントリスナーを破棄
        self.event_target.destroy();

        // 4. Node 構造体自体を破棄
        std.log.debug("Destroying Node struct itself (type: {s})", .{self.node_type.toString()});
        allocator.destroy(self);
    }

    // Node インスタンスを破棄する関数 (互換性のため残すが、Recursive を推奨)
    // この関数は Node 構造体自体のメモリのみを解放する。
    // specific_data や子ノードの解放は呼び出し元の責任。
    pub fn destroy(self: *Node, allocator: std.mem.Allocator) void {
        std.log.warn("Node.destroy called (non-recursive). Potential memory leak for children and specific_data.", .{});
        // EventTarget を破棄
        self.event_target.destroy();

        std.log.debug("Destroying Node (type: {s})", .{self.node_type.toString()});
        allocator.destroy(self);
    }

    // --- EventTarget API Delegation ---
    // Node は EventTarget のメソッドを自身のメソッドとして公開

    pub fn addEventListener(
        self: *Node,
        event_type: []const u8,
        listener: EventListener,
        options: AddEventListenerOptions,
    ) !void {
        // allocator は event_target が保持しているものを使う
        try self.event_target.addEventListener(event_type, listener, options);
    }

    pub fn addEventListenerBool(
        self: *Node,
        event_type: []const u8,
        listener: EventListener,
        use_capture: bool,
    ) !void {
        try self.event_target.addEventListenerBool(event_type, listener, use_capture);
    }

    pub fn removeEventListener(
        self: *Node,
        event_type: []const u8,
        listener: EventListener,
        options: EventListenerOptions,
    ) void {
        self.event_target.removeEventListener(event_type, listener, options);
    }

    pub fn removeEventListenerBool(
        self: *Node,
        event_type: []const u8,
        listener: EventListener,
        use_capture: bool,
    ) void {
        self.event_target.removeEventListenerBool(event_type, listener, use_capture);
    }

    // dispatchEvent は Node 自身を EventTarget として渡す必要があるため、
    // そのまま委譲するのではなく、Node 固有の処理を追加する可能性がある。
    // ここでは簡略化のため、EventTarget の dispatchEvent を呼び出す。
    // 実際の DOM イベント伝播はより複雑。
    pub fn dispatchEvent(self: *Node, event: *Event) !bool {
        // イベントのターゲットをこのノードに設定 (初回のみ)
        if (event.target == null) {
            // Event.target は anyopaque なので、Node* を直接代入可能
            event.target = self;
        }

        // EventTarget.dispatchEvent を呼び出し、ターゲットとして Node 自身 (anyopaque) を渡す。
        // これにより、コールバック内で event.target や event.currentTarget を Node* にキャストできる。
        // 注: ここではターゲットフェーズのリスナーのみが実行される。
        //     実際の伝播 (キャプチャ/バブリング) は未実装。
        if (!event.initialized) {
            // イベントはディスパッチ前に初期化されている必要がある
            // (通常、Event.create の後に呼び出し元が設定)
            return errors.DomError.InvalidStateError;
        }
        return try self.event_target.dispatchEvent(self, event);
    }

    // --- DOM 標準 API (抜粋) ---
    // https://dom.spec.whatwg.org/#interface-node

    // nodeName の取得 (NodeType に基づく)
    pub fn nodeName(self: *const Node) []const u8 {
        return self.node_type.toString();
    }

    // baseURI の取得 (未実装)
    pub fn baseURI(self: *const Node) ?[]const u8 {
        // TODO: ドキュメントや <base> 要素から解決する
        _ = self;
        return null;
    }

    // isConnected の取得 (未実装)
    pub fn isConnected(self: *const Node) bool {
        // ルートノード (Document) まで辿れるかチェック
        var current = self;
        while (current.parent_node) |p| {
            current = p;
        }
        // ルートが Document ノードであれば接続されているとみなす
        // (DocumentFragment などに接続されている場合は false とする DOM 仕様に合わせる)
        return current.node_type == .document_node;
    }

    // parentElement の取得 (修正)
    pub fn parentElement(self: *const Node) ?*Element {
        if (self.parent_node) |p| {
            if (p.node_type == .element_node) {
                // 親が Element ならば Element* にキャストして返す
                // Node.specific_data が Element* を指していると仮定
                return @ptrCast(@alignCast(p.specific_data.?));
            }
        }
        return null;
    }

    // ownerDocument の取得 (create 時に設定される)
    pub fn ownerDocument(self: *const Node) ?*Document {
        return self.owner_document;
    }

    /// このノードとその子孫に含まれる Text ノードの内容を連結して取得します。
    /// Comment ノードと ProcessingInstruction ノードは無視されます。
    pub fn textContent(self: *const Node, allocator: std.mem.Allocator) !?[]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        try appendTextContentRecursive(self, &result);

        // 結果が空でなければスライスを返す (所有権は呼び出し元へ)
        if (result.items.len > 0) {
            return result.toOwnedSlice();
        } else {
            result.deinit(); // 不要になった ArrayList を解放
            return null;
        }
    }

    // textContent の再帰ヘルパー
    fn appendTextContentRecursive(node: *const Node, list: *std.ArrayList(u8)) !void {
        switch (node.node_type) {
            .text_node, .cdata_section_node => {
                // Text または CDATASection の内容を追加
                // TODO: Text/CDATASection 構造体からデータを取得する getter が必要
                if (node.specific_data) |data_ptr| {
                    // 現状 Text* を想定
                    const text_node: *const Text = @ptrCast(@alignCast(data_ptr));
                    try list.appendSlice(text_node.data);
                } else {
                    // 本来は specific_data が null になることはないはず
                    std.log.warn("Text/CDATA node has null specific_data in appendTextContentRecursive", .{});
                }
            },
            .element_node, .document_node, .document_fragment_node => {
                // Element や Document系は子ノードを再帰的に処理
                var current = node.first_child;
                while (current) |child| {
                    try appendTextContentRecursive(child, list);
                    current = child.next_sibling;
                }
            },
            // Comment, ProcessingInstruction などは無視
            else => {},
        }
    }

    /// このノードの textContent を設定します。
    /// 全ての子ノードが削除され、指定されたテキストを持つ単一の Text ノードに置き換えられます。
    /// new_content が null または空文字列の場合、子は空になります。
    pub fn setTextContent(self: *Node, allocator: std.mem.Allocator, new_content: ?[]const u8) !void {
        // 1. 全ての子ノードを削除
        try self.removeAllChildren(allocator);

        // 2. 新しい Text ノードを追加 (null や空文字列でない場合)
        if (new_content) |content| {
            if (content.len > 0) {
                // Document.createTextNode を使いたいが、Node から Document を取得する必要がある。
                // owner_document を使う。
                if (self.owner_document) |doc| {
                    // Text ノードを作成 (本来は doc.createTextNode を使う)
                    // Text.create は *Node を返すようになった
                    const text_node = try Text.create(allocator, doc, content);
                    // キャスト不要に
                    try self.appendChild(text_node);
                } else {
                    // Document がない場合 (例: DocumentFragment) は追加できない？
                    // -> DOM 仕様確認。通常 DocumentFragment に Text を追加することは可能。
                    //    DocumentFragment が自身のアロケータ/ファクトリメソッドを持つべきか？
                    std.log.err("Cannot create Text node for setTextContent without owner document.", .{});
                    return error.DomError.HierarchyRequestError; // 適切なエラー？
                }
            }
        }
    }

    // --- 子ノード操作 (removeChild, removeAllChildren 追加) ---

    /// 子ノードを削除します。
    /// child がこのノードの子でない場合は NotFoundError を返します。
    pub fn removeChild(self: *Node, child: *Node) !*Node {
        // child が本当にこのノードの子か検証
        var current = self.first_child;
        var found = false;
        while (current) |c| {
            if (c == child) {
                found = true;
                break;
            }
            current = c.next_sibling;
        }
        if (!found) {
            return error.DomError.NotFoundError;
        }

        // リンクを解除
        const prev = child.previous_sibling;
        const next = child.next_sibling;

        if (prev) |p| {
            p.next_sibling = next;
        } else {
            // child が最初の子だった
            self.first_child = next;
        }

        if (next) |n| {
            n.previous_sibling = prev;
        } else {
            // child が最後の子だった
            self.last_child = prev;
        }

        // child のリンクをクリア
        child.parent_node = null;
        child.previous_sibling = null;
        child.next_sibling = null;

        // --- MutationObserver 通知 --- 
        if (self.owner_document) |doc| {
            const allocator = doc.allocator;
            // レコードを作成
            var record = try MutationRecord.create(allocator, .childList, self);
            errdefer record.destroy(); // キューイング失敗時に解放

            // removedNodes に追加
            try record.removedNodes.append(child);
            record.previousSibling = prev; // 削除されたノードの前の兄弟
            record.nextSibling = next;     // 削除されたノードの次の兄弟

            // Document のキューに追加
            try doc.queueMutationRecord(record);
        } else {
            // ownerDocument がない場合
        }

        return child;
    }

    /// 全ての子ノードを効率的に削除します。
    pub fn removeAllChildren(self: *Node, allocator: std.mem.Allocator) !void {
        var current = self.first_child;
        while (current) |child| {
            const next = child.next_sibling;
            // removeChild を呼ぶと効率が悪いので、直接破棄する。
            // 修正: destroyRecursive を使用する
            child.destroyRecursive(allocator);
            current = next;
        }
        self.first_child = null;
        self.last_child = null;
    }
    /// 指定されたノードをこのノードの子リストの末尾に追加します。
    /// new_child が既にツリーに含まれている場合、まず削除されます。
    pub fn appendChild(self: *Node, new_child: *Node) !*Node {
        // 検証処理
        try self.ensurePreInsertionValidity(new_child, null);

        // 循環参照チェック
        if (new_child == self or self.isDescendantOf(new_child)) {
            return error.DomError.HierarchyRequestError;
        }

        // DocumentFragment の場合の処理
        if (new_child.node_type == .document_fragment_node) {
            // DocumentFragment の子ノードを全て移動する
            var current = new_child.first_child;
            while (current) |child| {
                const next = child.next_sibling;
                // 子ノードを親から切り離して追加
                child.parent_node = null;
                child.previous_sibling = null;
                child.next_sibling = null;
                _ = try self.appendChild(child);
                current = next;
            }
            // DocumentFragment の子リストをクリア
            new_child.first_child = null;
            new_child.last_child = null;
            return new_child;
        }

        // 既に親を持っている場合は削除
        if (new_child.parent_node) |parent| {
            _ = try parent.removeChild(new_child);
        }

        // 新しい子ノードをリストの末尾に追加
        const old_last_child = self.last_child;
        if (old_last_child) |last| {
            last.next_sibling = new_child;
            new_child.previous_sibling = last;
        } else {
            // 最初の子として追加
            self.first_child = new_child;
        }
        self.last_child = new_child;
        new_child.parent_node = self;
        new_child.next_sibling = null;

        // MutationObserver 通知
        if (self.owner_document) |doc| {
            const allocator = doc.allocator;
            var record = try MutationRecord.create(allocator, .childList, self);
            errdefer record.destroy();
            
            try record.addedNodes.append(new_child);
            record.previousSibling = old_last_child;
            record.nextSibling = null;

            try doc.queueMutationRecord(record);
        }

        return new_child;
    }

    /// 新しい子ノードを、指定された既存の子ノードの前に追加します。
    /// reference_node が null の場合、new_child は子リストの末尾に追加されます (appendChild と同じ)。
    /// reference_node がこのノードの子でない場合は NotFoundError を返します。
    pub fn insertBefore(self: *Node, new_child: *Node, reference_node: ?*Node) !*Node {
        // 検証処理
        try self.ensurePreInsertionValidity(new_child, reference_node);

        // reference_node が null なら appendChild と同じ
        if (reference_node == null) {
            return try self.appendChildInternal(new_child);
        }
        const ref_node = reference_node.?;

        // reference_node がこのノードの子か再確認
        if (ref_node.parent_node != self) {
            return error.DomError.NotFoundError;
        }

        // 循環参照チェック
        if (new_child == self or self.isDescendantOf(new_child)) {
            return error.DomError.HierarchyRequestError;
        }

        // DocumentFragment の場合の処理
        if (new_child.node_type == .document_fragment_node) {
            // DocumentFragment の子ノードを全て移動する
            var current = new_child.first_child;
            var last_inserted: ?*Node = null;
            
            while (current) |child| {
                const next = child.next_sibling;
                // 子ノードを親から切り離して挿入
                child.parent_node = null;
                child.previous_sibling = null;
                child.next_sibling = null;
                last_inserted = try self.insertBefore(child, ref_node);
                current = next;
            }
            
            // DocumentFragment の子リストをクリア
            new_child.first_child = null;
            new_child.last_child = null;
            return new_child;
        }

        // 既に親を持っている場合は削除
        if (new_child.parent_node) |parent| {
            _ = try parent.removeChild(new_child);
        }

        // 挿入処理
        const prev = ref_node.previous_sibling;

        // new_child のリンク設定
        new_child.parent_node = self;
        new_child.previous_sibling = prev;
        new_child.next_sibling = ref_node;

        // 周辺ノードのリンク更新
        if (prev) |p| {
            p.next_sibling = new_child;
        } else {
            self.first_child = new_child;
        }
        ref_node.previous_sibling = new_child;

        // MutationObserver 通知
        if (self.owner_document) |doc| {
            const allocator = doc.allocator;
            var record = try MutationRecord.create(allocator, .childList, self);
            errdefer record.destroy();

            try record.addedNodes.append(new_child);
            record.previousSibling = prev;
            record.nextSibling = ref_node;

            try doc.queueMutationRecord(record);
        }

        return new_child;
    }

    /// 指定された子ノード `old_child` を `new_child` に置き換えます。
    /// `old_child` がこのノードの子でない場合は NotFoundError を返します。
    /// `new_child` が DocumentFragment の場合、その子が代わりに挿入されます。
    pub fn replaceChild(self: *Node, new_child: *Node, old_child: *Node) !*Node {
        // old_child が self の子であることを検証
        if (old_child.parent_node != self) {
            return error.DomError.NotFoundError;
        }

        // new_child の検証
        try self.ensurePreInsertionValidity(new_child, old_child.next_sibling);

        // 循環参照チェック
        if (new_child == self or self.isDescendantOf(new_child)) {
            return error.DomError.HierarchyRequestError;
        }

        // DocumentFragment の場合の処理
        if (new_child.node_type == .document_fragment_node) {
            // 最初に old_child の前に全ての子を挿入し、その後 old_child を削除
            const next_sibling = old_child.next_sibling;
            
            // DocumentFragment の子ノードを全て移動する
            var current = new_child.first_child;
            while (current) |child| {
                const next = child.next_sibling;
                // 子ノードを親から切り離して挿入
                child.parent_node = null;
                child.previous_sibling = null;
                child.next_sibling = null;
                _ = try self.insertBefore(child, old_child);
                current = next;
            }
            
            // DocumentFragment の子リストをクリア
            new_child.first_child = null;
            new_child.last_child = null;
            
            // old_child を削除
            _ = try self.removeChild(old_child);
            
            return old_child;
        }

        // new_child が既に親を持っている場合は削除
        if (new_child.parent_node) |parent| {
            _ = try parent.removeChild(new_child);
        }

        // リンクの更新
        const prev = old_child.previous_sibling;
        const next = old_child.next_sibling;

        // new_child のリンクを設定
        new_child.parent_node = self;
        new_child.previous_sibling = prev;
        new_child.next_sibling = next;

        // 前のノードまたは親の first_child を更新
        if (prev) |p| {
            p.next_sibling = new_child;
        } else {
            self.first_child = new_child;
        }

        // 次のノードまたは親の last_child を更新
        if (next) |n| {
            n.previous_sibling = new_child;
        } else {
            self.last_child = new_child;
        }

        // old_child のリンクをクリア
        old_child.parent_node = null;
        old_child.previous_sibling = null;
        old_child.next_sibling = null;

        // MutationObserver 通知
        if (self.owner_document) |doc| {
            const allocator = doc.allocator;
            var record = try MutationRecord.create(allocator, .childList, self);
            errdefer record.destroy();

            try record.removedNodes.append(old_child);
            try record.addedNodes.append(new_child);
            record.previousSibling = prev;
            record.nextSibling = next;

            try doc.queueMutationRecord(record);
        }

        return old_child;
    }

    /// このノードが指定された `ancestor` ノードの子孫であるかどうかを返します。
    /// 自分自身は子孫とはみなされません。
    pub fn isDescendantOf(self: *const Node, ancestor: *const Node) bool {
        var current_parent = self.parent_node;
        while (current_parent) |p| {
            if (p == ancestor) {
                return true;
            }
            current_parent = p.parent_node;
        }
        return false;
    }

    // 挿入前検証ヘルパー
    fn ensurePreInsertionValidity(self: *const Node, node: *Node, child: ?*Node) !void {
        // 親ノードの型チェック (Document, DocumentFragment, Element のみ子を持てる)
        if (self.node_type != .document_node and
            self.node_type != .document_fragment_node and
            self.node_type != .element_node) {
            return error.DomError.HierarchyRequestError;
        }

        // 追加するノードの型チェック
        if (node.node_type == .document_type_node or
            node.node_type == .document_node) {
            return error.DomError.HierarchyRequestError;
        }

        // child が指定されている場合、それが self の子であることを確認
        if (child) |c| {
            if (c.parent_node != self) {
                return error.DomError.NotFoundError;
            }
        }

        // Document ノードへの追加制限
        if (self.node_type == .document_node) {
            var element_child_exists = false;
            var doctype_child_exists = false;
            const node_to_insert_is_element = node.node_type == .element_node;
            const node_to_insert_is_doctype = node.node_type == .document_type_node;

            // 既存の子をチェック
            var current = self.first_child;
            while (current) |existing_child| {
                if (existing_child.node_type == .element_node) {
                    element_child_exists = true;
                }
                if (existing_child.node_type == .document_type_node) {
                    doctype_child_exists = true;
                }
                current = existing_child.next_sibling;
            }

            // Element を Document に追加する場合
            if (node_to_insert_is_element) {
                if (element_child_exists) {
                    return error.DomError.HierarchyRequestError;
                }
                
                // 挿入位置の後に Element がないかチェック
                if (child) |c| {
                    var check = c;
                    while (check) |sibling| {
                        if (sibling.node_type == .element_node) {
                            return error.DomError.HierarchyRequestError;
                        }
                        check = sibling.next_sibling;
                    }
                }
            }

            // DocumentType を Document に追加する場合
            if (node_to_insert_is_doctype) {
                if (doctype_child_exists) {
                    return error.DomError.HierarchyRequestError;
                }
                
                // DocumentType は Element の前に配置する必要がある
                if (child) |c| {
                    if (c.node_type != .element_node) {
                        var check = c;
                        while (check) |sibling| {
                            if (sibling.node_type == .element_node) {
                                return error.DomError.HierarchyRequestError;
                            }
                            check = sibling.next_sibling;
                        }
                    }
                }
            }

            // Text ノードを Document に直接追加する場合 (許可されない)
            if (node.node_type == .text_node) {
                return error.DomError.HierarchyRequestError;
            }
        }

        // DocumentFragment の場合の検証
        if (node.node_type == .document_fragment_node) {
            var element_count: u32 = 0;
            
            // Fragment 内の Element ノードをカウント
            var current = node.first_child;
            while (current) |fragment_child| {
                if (fragment_child.node_type == .element_node) {
                    element_count += 1;
                }
                
                // Text ノードを Document に直接追加しようとしている場合
                if (self.node_type == .document_node and fragment_child.node_type == .text_node) {
                    return error.DomError.HierarchyRequestError;
                }
                
                current = fragment_child.next_sibling;
            }
            
            // Document に追加する場合、Element は最大1つまで
            if (self.node_type == .document_node and element_count > 1) {
                return error.DomError.HierarchyRequestError;
            }
            
            // Document に Element を追加する場合の追加チェック
            if (self.node_type == .document_node and element_count == 1) {
                var element_exists = false;
                
                // 既存の Element をチェック
                current = self.first_child;
                while (current) |existing_child| {
                    if (existing_child.node_type == .element_node) {
                        element_exists = true;
                        break;
                    }
                    current = existing_child.next_sibling;
                }
                
                if (element_exists) {
                    return error.DomError.HierarchyRequestError;
                }
                
                // 挿入位置の後に Element がないかチェック
                if (child) |c| {
                    current = c;
                    while (current) |sibling| {
                        if (sibling.node_type == .element_node) {
                            return error.DomError.HierarchyRequestError;
                        }
                        current = sibling.next_sibling;
                    }
                }
            }
        }
    }

    // appendChild の内部実装 (検証後)
    fn appendChildInternal(self: *Node, new_child: *Node) !*Node {
         // new_child が既に親を持っている場合は削除する (検証済みのはずだが念のため)
        if (new_child.parent_node) |parent| {
            _ = try parent.removeChild(new_child);
        }

        // 新しい子ノードをリストの末尾に追加
        const old_last_child = self.last_child;
        if (old_last_child) |last| {
            last.next_sibling = new_child;
            new_child.previous_sibling = last;
        } else {
            // このノードに最初の子として追加
            self.first_child = new_child;
        }
        self.last_child = new_child;
        new_child.parent_node = self;
        new_child.next_sibling = null; // 末尾なので next は null

        // --- MutationObserver 通知 --- 
        if (self.owner_document) |doc| {
            const allocator = doc.allocator;
            // レコードを作成
            var record = try MutationRecord.create(allocator, .childList, self);
            errdefer record.destroy(); // キューイング失敗時に解放
            
            // addedNodes に追加 (参照のリストなのでノード自体の所有権は移らない)
            try record.addedNodes.append(new_child);
            record.previousSibling = old_last_child; // 追加前の最後の子が previousSibling
            record.nextSibling = null; // 末尾に追加したので nextSibling は null

            // Document のキューに追加
            try doc.queueMutationRecord(record);
        } else {
            // ownerDocument がない場合 (DocumentFragmentなど) は通知しない？
            // 仕様確認が必要だが、一旦何もしない。
        }

        return new_child;
    }
};

// Node 構造体のテスト
test "Node creation and basic properties" {
    const allocator = std.testing.allocator;

    // Document のスタブ (Actual Document instance)
    // const DummyDocument = struct {};
    // var dummy_doc: DummyDocument = .{};
    var doc = try Document.create(allocator, "text/html");
    defer doc.destroy();

    // Node を直接作成 (通常は具象型から呼ばれる)
    // var node = try Node.create(allocator, .element_node, @ptrCast(&dummy_doc), null);
    var node = try Node.create(allocator, .element_node, doc, null);
    defer node.destroy(allocator); // Node 自体の解放は依然として必要

    try std.testing.expect(node.node_type == .element_node);
    // try std.testing.expect(node.owner_document == @ptrCast(&dummy_doc));
    try std.testing.expect(node.owner_document == doc);
    try std.testing.expect(node.parent_node == null);
    try std.testing.expect(node.first_child == null);
    try std.testing.expect(node.last_child == null);
    try std.testing.expect(node.previous_sibling == null);
    try std.testing.expect(node.next_sibling == null);
    try std.testing.expectEqualStrings("Element", node.nodeName());
}

test "Node appendChild basic" {
    const allocator = std.testing.allocator;
    // const DummyDocument = struct {};
    // var dummy_doc: DummyDocument = .{};
    var doc = try Document.create(allocator, "text/html");
    defer doc.destroy();

    // var parent = try Node.create(allocator, .element_node, @ptrCast(&dummy_doc), null);
    // Use Document as the initial parent-like structure for testing appendChild
    var parent = &doc.base_node; // Document's base node can act as a parent

    // var child1 = try Node.create(allocator, .text_node, @ptrCast(&dummy_doc), null);
    var child1 = try Node.create(allocator, .text_node, doc, null);
    defer child1.destroy(allocator);
    // var child2 = try Node.create(allocator, .comment_node, @ptrCast(&dummy_doc), null);
    var child2 = try Node.create(allocator, .comment_node, doc, null);
    defer child2.destroy(allocator);

    try parent.appendChild(child1);
    try std.testing.expect(parent.first_child == child1);
    try std.testing.expect(parent.last_child == child1);
    try std.testing.expect(child1.parent_node == parent);
    try std.testing.expect(child1.previous_sibling == null);
    try std.testing.expect(child1.next_sibling == null);

    try parent.appendChild(child2);
    try std.testing.expect(parent.first_child == child1);
    try std.testing.expect(parent.last_child == child2);
    try std.testing.expect(child1.next_sibling == child2);
    try std.testing.expect(child2.previous_sibling == child1);
    try std.testing.expect(child2.next_sibling == null);
    try std.testing.expect(child2.parent_node == parent);

    // Text ノードは子を持てないことを確認 (try...catch を使用)
    const result = child1.appendChild(parent); // Try appending parent to child1
    if (result) |_| {
        std.debug.panic("Expected an error but got success", .{});
    } else |err| {
        try std.testing.expect(err == errors.DomError.HierarchyRequestError);
    }
}

test "Node appendChild wrong document" {
    const allocator = std.testing.allocator;
    var doc1 = try Document.create(allocator, "text/html");
    defer doc1.destroy();
    var doc2 = try Document.create(allocator, "text/html");
    defer doc2.destroy();

    var parent = try Node.create(allocator, .element_node, doc1, null);
    defer parent.destroy(allocator);
    var child = try Node.create(allocator, .text_node, doc2, null);
    defer child.destroy(allocator);

    // 異なるドキュメントのノードを追加しようとするとエラーになるはず
    const result = parent.appendChild(child);
    if (result) |_| {
        std.debug.panic("Expected a WrongDocumentError but got success", .{});
    } else |err| {
        try std.testing.expect(err == errors.DomError.WrongDocumentError);
    }
}

// --- Node EventTarget テスト ---

// テスト用コールバック (event_target.zig から流用)
var node_callback_counter: u32 = 0;
fn nodeTestCallback(event: *Event, data: ?*anyopaque) callconv(.C) void {
    _ = event;
    _ = data;
    node_callback_counter += 1;
    std.log.debug("nodeTestCallback executed", .{});
}
fn resetNodeTestCounter() void {
    node_callback_counter = 0;
}

test "Node addEventListener and removeEventListener" {
    const allocator = std.testing.allocator;
    var doc = try Document.create(allocator, "text/html");
    defer doc.destroy();
    var node = try Node.create(allocator, .element_node, doc, null);
    defer node.destroy(allocator);

    const listener1 = EventListener{ .callback = nodeTestCallback };

    // リスナー追加
    try node.addEventListenerBool("test", listener1, false);
    try std.testing.expect(node.event_target.listener_map.count() == 1);
    const listeners = node.event_target.listener_map.get("test").?;
    try std.testing.expect(listeners.items.len == 1);

    // 重複追加は無視
    try node.addEventListenerBool("test", listener1, false);
    try std.testing.expect(listeners.items.len == 1);

    // リスナー削除
    node.removeEventListenerBool("test", listener1, false);
    try std.testing.expect(node.event_target.listener_map.get("test") == null);
    try std.testing.expect(node.event_target.listener_map.count() == 0);
}

// dispatchEvent のテストのコメントアウトを解除
test "Node dispatchEvent" {
    const allocator = std.testing.allocator;
    var doc = try Document.create(allocator, "text/html");
    defer doc.destroy();
    var node = try Node.create(allocator, .element_node, doc, null);
    defer node.destroy(allocator);

    resetNodeTestCounter();
    const listener = EventListener{ .callback = nodeTestCallback };
    try node.addEventListenerBool("myevent", listener, false);

    var event = try Event.create(allocator, "myevent", .{});
    defer event.destroy(allocator);
    event.initialized = true; // dispatchEvent の前に初期化フラグを立てる
    // event.target は dispatchEvent 内で設定される

    const result = try node.dispatchEvent(event);
    try std.testing.expect(result == true);
    try std.testing.expect(node_callback_counter == 1);
    // イベントのターゲットが正しく設定されたか確認
    try std.testing.expect(event.target == node);
    // currentTarget は dispatchEvent 完了時には null になっているはず
    try std.testing.expect(event.currentTarget == null);
}

// --- textContent テスト ---
test "Node textContent getter" {
    const allocator = std.testing.allocator;
    var doc = try Document.create(allocator, "text/html");
    defer doc.destroy();
    // var parent = try Element.create(allocator, doc, "div", html_ns, null);
    // Element.create はまだ未実装か、別の場所にある可能性。
    // Document.createElement を使う。
    var parent = try doc.createElement("div");
    defer parent.destroy(allocator);

    var text1 = try doc.createTextNode("Hello ");
    var text2 = try doc.createTextNode("world!");
    var comment = try Node.create(allocator, .comment_node, doc, null); // Assume createComment exists or use basic node
    defer comment.destroy(allocator);
    var span = try doc.createElement("span");
    defer span.destroy(allocator);
    var text3 = try doc.createTextNode(" How are you?");

    try parent.appendChild(&text1.base_node);
    try parent.appendChild(&comment.base_node);
    try parent.appendChild(&span.base_node);
    try span.appendChild(&text2.base_node);
    try span.appendChild(&text3.base_node);

    // parent の textContent を取得: "Hello world! How are you?"
    const content = try parent.textContent(allocator);
    defer if (content) |c| allocator.free(c);
    try std.testing.expect(content != null);
    try std.testing.expectEqualStrings("Hello world! How are you?", content.?);

    // span の textContent を取得: "world! How are you?"
    const span_content = try span.textContent(allocator);
    defer if (span_content) |sc| allocator.free(sc);
    try std.testing.expect(span_content != null);
    try std.testing.expectEqualStrings("world! How are you?", span_content.?);

    // text1 の textContent を取得: "Hello "
    const text1_content = try text1.textContent(allocator);
    defer if (text1_content) |t1c| allocator.free(t1c);
    try std.testing.expect(text1_content != null);
    try std.testing.expectEqualStrings("Hello ", text1_content.?);

    // comment の textContent を取得: null
    const comment_content = try comment.textContent(allocator);
    try std.testing.expect(comment_content == null);
}

test "Node textContent setter" {
    const allocator = std.testing.allocator;
    var doc = try Document.create(allocator, "text/html");
    defer doc.destroy();
    var parent = try doc.createElement("div");
    defer parent.destroy(allocator);

    var text1 = try doc.createTextNode("Initial");
    var span = try doc.createElement("span");

    try parent.appendChild(&text1.base_node);
    try parent.appendChild(&span.base_node);

    // textContent を設定
    const new_text = "New content";
    try parent.setTextContent(allocator, new_text);

    // 子が Text ノード1つになっているか確認
    try std.testing.expect(parent.first_child != null);
    try std.testing.expect(parent.first_child == parent.last_child);
    const child = parent.first_child.?;
    try std.testing.expect(child.node_type == .text_node);
    // Text ノードの内容を確認
    const child_text_node: *Text = @ptrCast(@alignCast(child.specific_data.?));
    try std.testing.expectEqualStrings(new_text, child_text_node.data);

    // textContent に空文字列を設定
    try parent.setTextContent(allocator, "");
    try std.testing.expect(parent.first_child == null);
    try std.testing.expect(parent.last_child == null);

    // textContent に null を設定
    // まず子を追加しておく
    var temp_text = try doc.createTextNode("temp");
    try parent.appendChild(&temp_text.base_node);
    try parent.setTextContent(allocator, null);
    try std.testing.expect(parent.first_child == null);
} 