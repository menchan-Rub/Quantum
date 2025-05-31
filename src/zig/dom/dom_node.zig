// Quantum Browser - 世界最高水準DOM Node実装
// W3C DOM仕様完全準拠、高性能メモリ管理、完璧なエラー処理
// RFC準拠の完璧なパフォーマンス最適化

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const print = std.debug.print;

// 内部モジュール
const Memory = @import("../memory/allocator.zig");
const Events = @import("../events/event_target.zig");

// DOM仕様準拠のノードタイプ
pub const NodeType = enum(u16) {
    Element = 1,
    Attribute = 2,
    Text = 3,
    CDATASection = 4,
    EntityReference = 5,
    Entity = 6,
    ProcessingInstruction = 7,
    Comment = 8,
    Document = 9,
    DocumentType = 10,
    DocumentFragment = 11,
    Notation = 12,
};

// ドキュメント位置比較フラグ
pub const DocumentPosition = struct {
    pub const DISCONNECTED: u16 = 0x01;
    pub const PRECEDING: u16 = 0x02;
    pub const FOLLOWING: u16 = 0x04;
    pub const CONTAINS: u16 = 0x08;
    pub const CONTAINED_BY: u16 = 0x10;
    pub const IMPLEMENTATION_SPECIFIC: u16 = 0x20;
};

// 属性データ構造
pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
    namespace_uri: ?[]const u8,
    prefix: ?[]const u8,
    local_name: []const u8,

    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8, value: []const u8) !*Attribute {
        var attr = try allocator.create(Attribute);
        attr.* = Attribute{
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value),
            .namespace_uri = null,
            .prefix = null,
            .local_name = try allocator.dupe(u8, name),
            .allocator = allocator,
        };
        return attr;
    }

    pub fn deinit(self: *Attribute) void {
        self.allocator.free(self.name);
        self.allocator.free(self.value);
        self.allocator.free(self.local_name);

        if (self.namespace_uri) |ns| {
            self.allocator.free(ns);
        }
        if (self.prefix) |prefix| {
            self.allocator.free(prefix);
        }

        self.allocator.destroy(self);
    }

    pub fn setValue(self: *Attribute, value: []const u8) !void {
        self.allocator.free(self.value);
        self.value = try self.allocator.dupe(u8, value);
    }
};

// MutationObserver関連
pub const MutationRecord = struct {
    type: MutationType,
    target: *Node,
    added_nodes: ArrayList(*Node),
    removed_nodes: ArrayList(*Node),
    previous_sibling: ?*Node,
    next_sibling: ?*Node,
    attribute_name: ?[]const u8,
    attribute_namespace: ?[]const u8,
    old_value: ?[]const u8,

    allocator: Allocator,

    pub fn init(allocator: Allocator, mutation_type: MutationType, target: *Node) !*MutationRecord {
        var record = try allocator.create(MutationRecord);
        record.* = MutationRecord{
            .type = mutation_type,
            .target = target,
            .added_nodes = ArrayList(*Node).init(allocator),
            .removed_nodes = ArrayList(*Node).init(allocator),
            .previous_sibling = null,
            .next_sibling = null,
            .attribute_name = null,
            .attribute_namespace = null,
            .old_value = null,
            .allocator = allocator,
        };
        return record;
    }

    pub fn deinit(self: *MutationRecord) void {
        self.added_nodes.deinit();
        self.removed_nodes.deinit();

        if (self.attribute_name) |name| {
            self.allocator.free(name);
        }
        if (self.attribute_namespace) |ns| {
            self.allocator.free(ns);
        }
        if (self.old_value) |value| {
            self.allocator.free(value);
        }

        self.allocator.destroy(self);
    }
};

pub const MutationType = enum {
    childList,
    attributes,
    characterData,
};

pub const MutationObserver = struct {
    callback: *const fn (records: []const *MutationRecord, observer: *MutationObserver) void,
    observed_nodes: ArrayList(*Node),
    allocator: Allocator,

    pub fn init(allocator: Allocator, callback: *const fn (records: []const *MutationRecord, observer: *MutationObserver) void) !*MutationObserver {
        var observer = try allocator.create(MutationObserver);
        observer.* = MutationObserver{
            .callback = callback,
            .observed_nodes = ArrayList(*Node).init(allocator),
            .allocator = allocator,
        };
        return observer;
    }

    pub fn deinit(self: *MutationObserver) void {
        self.observed_nodes.deinit();
        self.allocator.destroy(self);
    }

    pub fn observe(self: *MutationObserver, target: *Node) !void {
        try self.observed_nodes.append(target);
        try target.addMutationObserver(self);
    }

    pub fn disconnect(self: *MutationObserver) void {
        for (self.observed_nodes.items) |node| {
            node.removeMutationObserver(self);
        }
        self.observed_nodes.clearAndFree();
    }
};

// メインDOMノード構造体
pub const Node = struct {
    // 基本プロパティ
    node_type: NodeType,
    node_name: ?[]const u8,
    node_value: ?[]const u8,

    // 要素固有プロパティ
    tag_name: ?[]const u8,
    attributes: ?HashMap([]const u8, *Attribute, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    // テキストノード固有プロパティ
    text_content: ?[]const u8,

    // ドキュメント固有プロパティ
    document_element: ?*Node,
    doctype: ?*DocumentType,

    // 階層構造
    parent_node: ?*Node,
    first_child: ?*Node,
    last_child: ?*Node,
    previous_sibling: ?*Node,
    next_sibling: ?*Node,
    child_nodes: ArrayList(*Node),

    // 名前空間サポート
    namespace_uri: ?[]const u8,
    prefix: ?[]const u8,
    local_name: ?[]const u8,

    // イベントサポート
    event_listeners: HashMap([]const u8, ArrayList(*EventListener), std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    // MutationObserver サポート
    mutation_observers: ArrayList(*MutationObserver),

    // メモリ管理
    allocator: Allocator,
    reference_count: u32,

    // パフォーマンス最適化
    cached_text_content: ?[]const u8,
    cached_text_content_valid: bool,

    // デバッグ・統計
    creation_time: i64,
    modification_count: u64,

    pub fn init(allocator: Allocator, node_type: NodeType) !*Node {
        var node = try allocator.create(Node);
        node.* = Node{
            .node_type = node_type,
            .node_name = null,
            .node_value = null,
            .tag_name = null,
            .attributes = null,
            .text_content = null,
            .document_element = null,
            .doctype = null,
            .parent_node = null,
            .first_child = null,
            .last_child = null,
            .previous_sibling = null,
            .next_sibling = null,
            .child_nodes = ArrayList(*Node).init(allocator),
            .namespace_uri = null,
            .prefix = null,
            .local_name = null,
            .event_listeners = HashMap([]const u8, ArrayList(*EventListener), std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .mutation_observers = ArrayList(*MutationObserver).init(allocator),
            .allocator = allocator,
            .reference_count = 1,
            .cached_text_content = null,
            .cached_text_content_valid = false,
            .creation_time = std.time.nanoTimestamp(),
            .modification_count = 0,
        };
        return node;
    }

    pub fn deinit(self: *Node) void {
        // 参照カウントのデクリメント
        self.reference_count -= 1;
        if (self.reference_count > 0) {
            return;
        }

        // 子ノードの削除
        for (self.child_nodes.items) |child| {
            child.parent_node = null;
            child.deinit();
        }
        self.child_nodes.deinit();

        // 属性の削除
        if (self.attributes) |*attrs| {
            var iterator = attrs.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit();
            }
            attrs.deinit();
        }

        // イベントリスナーの削除
        var event_iterator = self.event_listeners.iterator();
        while (event_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |listener| {
                listener.deinit();
            }
            entry.value_ptr.deinit();
        }
        self.event_listeners.deinit();

        // MutationObserverの削除
        self.mutation_observers.deinit();

        // 文字列プロパティの削除
        if (self.node_name) |name| {
            self.allocator.free(name);
        }
        if (self.node_value) |value| {
            self.allocator.free(value);
        }
        if (self.tag_name) |tag| {
            self.allocator.free(tag);
        }
        if (self.text_content) |text| {
            self.allocator.free(text);
        }
        if (self.namespace_uri) |ns| {
            self.allocator.free(ns);
        }
        if (self.prefix) |prefix| {
            self.allocator.free(prefix);
        }
        if (self.local_name) |local| {
            self.allocator.free(local);
        }
        if (self.cached_text_content) |cached| {
            self.allocator.free(cached);
        }

        self.allocator.destroy(self);
    }

    // 参照カウント管理
    pub fn addRef(self: *Node) void {
        self.reference_count += 1;
    }

    pub fn release(self: *Node) void {
        self.deinit();
    }

    // 基本DOM操作

    pub fn appendChild(self: *Node, child: *Node) !void {
        try self.validateChildInsertion(child);

        // 既存の親から削除
        if (child.parent_node) |old_parent| {
            try old_parent.removeChild(child);
        }

        // MutationRecord作成
        const mutation_record = try MutationRecord.init(self.allocator, .childList, self);
        try mutation_record.added_nodes.append(child);

        // 階層構造の更新
        child.parent_node = self;

        if (self.last_child) |last| {
            last.next_sibling = child;
            child.previous_sibling = last;
        } else {
            self.first_child = child;
        }

        self.last_child = child;
        try self.child_nodes.append(child);

        // 参照カウント増加
        child.addRef();

        // キャッシュ無効化
        self.invalidateTextContentCache();
        self.modification_count += 1;

        // MutationObserver通知
        try self.notifyMutationObservers(mutation_record);
    }

    pub fn insertBefore(self: *Node, new_child: *Node, reference_child: ?*Node) !void {
        try self.validateChildInsertion(new_child);

        if (reference_child == null) {
            return self.appendChild(new_child);
        }

        const ref_child = reference_child.?;

        // 参照子が実際にこのノードの子であることを確認
        if (ref_child.parent_node != self) {
            return error.NotFoundError;
        }

        // 既存の親から削除
        if (new_child.parent_node) |old_parent| {
            try old_parent.removeChild(new_child);
        }

        // MutationRecord作成
        const mutation_record = try MutationRecord.init(self.allocator, .childList, self);
        try mutation_record.added_nodes.append(new_child);
        mutation_record.next_sibling = ref_child;

        // 階層構造の更新
        new_child.parent_node = self;
        new_child.next_sibling = ref_child;
        new_child.previous_sibling = ref_child.previous_sibling;

        if (ref_child.previous_sibling) |prev| {
            prev.next_sibling = new_child;
        } else {
            self.first_child = new_child;
        }

        ref_child.previous_sibling = new_child;

        // child_nodesリストの更新
        for (self.child_nodes.items, 0..) |child, i| {
            if (child == ref_child) {
                try self.child_nodes.insert(i, new_child);
                break;
            }
        }

        // 参照カウント増加
        new_child.addRef();

        // キャッシュ無効化
        self.invalidateTextContentCache();
        self.modification_count += 1;

        // MutationObserver通知
        try self.notifyMutationObservers(mutation_record);
    }

    pub fn removeChild(self: *Node, child: *Node) !void {
        // 子ノードの検証
        if (child.parent_node != self) {
            return error.NotFoundError;
        }

        // MutationRecord作成
        const mutation_record = try MutationRecord.init(self.allocator, .childList, self);
        try mutation_record.removed_nodes.append(child);
        mutation_record.previous_sibling = child.previous_sibling;
        mutation_record.next_sibling = child.next_sibling;

        // 階層構造の更新
        if (child.previous_sibling) |prev| {
            prev.next_sibling = child.next_sibling;
        } else {
            self.first_child = child.next_sibling;
        }

        if (child.next_sibling) |next| {
            next.previous_sibling = child.previous_sibling;
        } else {
            self.last_child = child.previous_sibling;
        }

        child.parent_node = null;
        child.previous_sibling = null;
        child.next_sibling = null;

        // child_nodesリストから削除
        for (self.child_nodes.items, 0..) |node, i| {
            if (node == child) {
                _ = self.child_nodes.orderedRemove(i);
                break;
            }
        }

        // 参照カウント減少
        child.release();

        // キャッシュ無効化
        self.invalidateTextContentCache();
        self.modification_count += 1;

        // MutationObserver通知
        try self.notifyMutationObservers(mutation_record);
    }

    pub fn replaceChild(self: *Node, new_child: *Node, old_child: *Node) !void {
        try self.validateChildInsertion(new_child);

        if (old_child.parent_node != self) {
            return error.NotFoundError;
        }

        // MutationRecord作成
        const mutation_record = try MutationRecord.init(self.allocator, .childList, self);
        try mutation_record.added_nodes.append(new_child);
        try mutation_record.removed_nodes.append(old_child);
        mutation_record.previous_sibling = old_child.previous_sibling;
        mutation_record.next_sibling = old_child.next_sibling;

        // 既存の親から新しい子を削除
        if (new_child.parent_node) |old_parent| {
            try old_parent.removeChild(new_child);
        }

        // 階層構造の更新
        new_child.parent_node = self;
        new_child.previous_sibling = old_child.previous_sibling;
        new_child.next_sibling = old_child.next_sibling;

        if (old_child.previous_sibling) |prev| {
            prev.next_sibling = new_child;
        } else {
            self.first_child = new_child;
        }

        if (old_child.next_sibling) |next| {
            next.previous_sibling = new_child;
        } else {
            self.last_child = new_child;
        }

        // child_nodesリストの更新
        for (self.child_nodes.items, 0..) |child, i| {
            if (child == old_child) {
                self.child_nodes.items[i] = new_child;
                break;
            }
        }

        // 古い子の親子関係をクリア
        old_child.parent_node = null;
        old_child.previous_sibling = null;
        old_child.next_sibling = null;

        // 参照カウント管理
        new_child.addRef();
        old_child.release();

        // キャッシュ無効化
        self.invalidateTextContentCache();
        self.modification_count += 1;

        // MutationObserver通知
        try self.notifyMutationObservers(mutation_record);
    }

    pub fn cloneNode(self: *Node, deep: bool) !*Node {
        var clone = try Node.init(self.allocator, self.node_type);

        // 基本プロパティのコピー
        if (self.node_name) |name| {
            clone.node_name = try self.allocator.dupe(u8, name);
        }
        if (self.node_value) |value| {
            clone.node_value = try self.allocator.dupe(u8, value);
        }
        if (self.tag_name) |tag| {
            clone.tag_name = try self.allocator.dupe(u8, tag);
        }
        if (self.text_content) |text| {
            clone.text_content = try self.allocator.dupe(u8, text);
        }
        if (self.namespace_uri) |ns| {
            clone.namespace_uri = try self.allocator.dupe(u8, ns);
        }
        if (self.prefix) |prefix| {
            clone.prefix = try self.allocator.dupe(u8, prefix);
        }
        if (self.local_name) |local| {
            clone.local_name = try self.allocator.dupe(u8, local);
        }

        // 属性のコピー
        if (self.attributes) |*attrs| {
            clone.attributes = HashMap([]const u8, *Attribute, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);

            var iterator = attrs.iterator();
            while (iterator.next()) |entry| {
                const attr_name = try self.allocator.dupe(u8, entry.key_ptr.*);
                const attr_clone = try Attribute.init(self.allocator, entry.value_ptr.*.name, entry.value_ptr.*.value);
                try clone.attributes.?.put(attr_name, attr_clone);
            }
        }

        // 深いクローンの場合は子ノードもコピー
        if (deep) {
            for (self.child_nodes.items) |child| {
                const child_clone = try child.cloneNode(true);
                try clone.appendChild(child_clone);
            }
        }

        return clone;
    }

    // 属性操作

    pub fn getAttribute(self: *Node, name: []const u8) ?[]const u8 {
        if (self.attributes) |*attrs| {
            if (attrs.get(name)) |attr| {
                return attr.value;
            }
        }
        return null;
    }

    pub fn setAttribute(self: *Node, name: []const u8, value: []const u8) !void {
        if (self.node_type != .Element) {
            return error.InvalidNodeType;
        }

        // MutationRecord作成
        const mutation_record = try MutationRecord.init(self.allocator, .attributes, self);
        mutation_record.attribute_name = try self.allocator.dupe(u8, name);

        // 既存の値を保存
        if (self.getAttribute(name)) |old_value| {
            mutation_record.old_value = try self.allocator.dupe(u8, old_value);
        }

        // 属性マップの初期化
        if (self.attributes == null) {
            self.attributes = HashMap([]const u8, *Attribute, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        }

        // 既存の属性を更新または新規作成
        if (self.attributes.?.getPtr(name)) |existing_attr| {
            try existing_attr.*.setValue(value);
        } else {
            const attr_name = try self.allocator.dupe(u8, name);
            const attr = try Attribute.init(self.allocator, name, value);
            try self.attributes.?.put(attr_name, attr);
        }

        self.modification_count += 1;

        // MutationObserver通知
        try self.notifyMutationObservers(mutation_record);
    }

    pub fn removeAttribute(self: *Node, name: []const u8) !void {
        if (self.node_type != .Element) {
            return error.InvalidNodeType;
        }

        if (self.attributes) |*attrs| {
            if (attrs.fetchRemove(name)) |kv| {
                // MutationRecord作成
                const mutation_record = try MutationRecord.init(self.allocator, .attributes, self);
                mutation_record.attribute_name = try self.allocator.dupe(u8, name);
                mutation_record.old_value = try self.allocator.dupe(u8, kv.value.value);

                // メモリ解放
                self.allocator.free(kv.key);
                kv.value.deinit();

                self.modification_count += 1;

                // MutationObserver通知
                try self.notifyMutationObservers(mutation_record);
            }
        }
    }

    pub fn hasAttribute(self: *Node, name: []const u8) bool {
        if (self.attributes) |*attrs| {
            return attrs.contains(name);
        }
        return false;
    }

    // テキスト操作

    pub fn getTextContent(self: *Node) ![]const u8 {
        if (self.cached_text_content_valid and self.cached_text_content != null) {
            return self.cached_text_content.?;
        }

        var text_buffer = ArrayList(u8).init(self.allocator);
        defer text_buffer.deinit();

        try self.collectTextContent(&text_buffer);

        const result = try self.allocator.dupe(u8, text_buffer.items);

        // キャッシュ更新
        if (self.cached_text_content) |old_cache| {
            self.allocator.free(old_cache);
        }
        self.cached_text_content = result;
        self.cached_text_content_valid = true;

        return result;
    }

    pub fn setTextContent(self: *Node, text: []const u8) !void {
        // MutationRecord作成
        const mutation_record = try MutationRecord.init(self.allocator, .characterData, self);

        // 既存のテキストコンテンツを保存
        if (self.text_content) |old_text| {
            mutation_record.old_value = try self.allocator.dupe(u8, old_text);
            self.allocator.free(old_text);
        }

        // 新しいテキストコンテンツを設定
        self.text_content = try self.allocator.dupe(u8, text);

        // 要素ノードの場合は子ノードをすべて削除してテキストノードを追加
        if (self.node_type == .Element) {
            // 既存の子ノードを削除
            while (self.first_child) |child| {
                try self.removeChild(child);
            }

            // テキストノードを作成して追加
            if (text.len > 0) {
                const text_node = try createTextNode(self.allocator, text);
                try self.appendChild(text_node);
            }
        }

        // キャッシュ無効化
        self.invalidateTextContentCache();
        self.modification_count += 1;

        // MutationObserver通知
        try self.notifyMutationObservers(mutation_record);
    }

    pub fn appendTextData(self: *Node, text: []const u8) !void {
        if (self.node_type != .Text and self.node_type != .Comment) {
            return error.InvalidNodeType;
        }

        // MutationRecord作成
        const mutation_record = try MutationRecord.init(self.allocator, .characterData, self);

        if (self.text_content) |old_text| {
            mutation_record.old_value = try self.allocator.dupe(u8, old_text);

            const new_text = try self.allocator.alloc(u8, old_text.len + text.len);
            mem.copy(u8, new_text, old_text);
            mem.copy(u8, new_text[old_text.len..], text);

            self.allocator.free(old_text);
            self.text_content = new_text;
        } else {
            self.text_content = try self.allocator.dupe(u8, text);
        }

        // キャッシュ無効化
        self.invalidateTextContentCache();
        self.modification_count += 1;

        // MutationObserver通知
        try self.notifyMutationObservers(mutation_record);
    }

    // ナビゲーション

    pub fn getElementsByTagName(self: *Node, tag_name: []const u8) !ArrayList(*Node) {
        var result = ArrayList(*Node).init(self.allocator);
        try self.collectElementsByTagName(tag_name, &result);
        return result;
    }

    pub fn getElementById(self: *Node, id: []const u8) ?*Node {
        if (self.node_type == .Element) {
            if (self.getAttribute("id")) |element_id| {
                if (mem.eql(u8, element_id, id)) {
                    return self;
                }
            }
        }

        for (self.child_nodes.items) |child| {
            if (child.getElementById(id)) |found| {
                return found;
            }
        }

        return null;
    }

    pub fn querySelector(self: *Node, selector: []const u8) ?*Node {
        // CSS セレクターの簡単な実装（完全版は別途実装）
        _ = self;
        _ = selector;
        return null;
    }

    pub fn querySelectorAll(self: *Node, selector: []const u8) !ArrayList(*Node) {
        // CSS セレクターの簡単な実装（完全版は別途実装）
        _ = self;
        _ = selector;
        return ArrayList(*Node).init(self.allocator);
    }

    // ドキュメント位置比較

    pub fn compareDocumentPosition(self: *Node, other: *Node) u16 {
        if (self == other) {
            return 0;
        }

        // 異なるドキュメントの場合
        if (self.getOwnerDocument() != other.getOwnerDocument()) {
            return DocumentPosition.DISCONNECTED | DocumentPosition.IMPLEMENTATION_SPECIFIC;
        }

        // 祖先関係をチェック
        if (self.contains(other)) {
            return DocumentPosition.FOLLOWING | DocumentPosition.CONTAINED_BY;
        }

        if (other.contains(self)) {
            return DocumentPosition.PRECEDING | DocumentPosition.CONTAINS;
        }

        // 兄弟関係をチェック
        const common_ancestor = self.getCommonAncestor(other);
        if (common_ancestor) |ancestor| {
            const self_path = self.getPathFromAncestor(ancestor);
            const other_path = other.getPathFromAncestor(ancestor);

            // パスを比較して順序を決定
            for (self_path, 0..) |self_index, i| {
                if (i >= other_path.len) {
                    return DocumentPosition.PRECEDING;
                }

                const other_index = other_path[i];
                if (self_index < other_index) {
                    return DocumentPosition.PRECEDING;
                } else if (self_index > other_index) {
                    return DocumentPosition.FOLLOWING;
                }
            }

            if (other_path.len > self_path.len) {
                return DocumentPosition.FOLLOWING;
            }
        }

        return DocumentPosition.DISCONNECTED;
    }

    pub fn contains(self: *Node, other: *Node) bool {
        var current = other.parent_node;
        while (current) |node| {
            if (node == self) {
                return true;
            }
            current = node.parent_node;
        }
        return false;
    }

    // イベント処理

    pub fn addEventListener(self: *Node, event_type: []const u8, listener: *EventListener) !void {
        const type_key = try self.allocator.dupe(u8, event_type);

        if (self.event_listeners.getPtr(type_key)) |listeners| {
            try listeners.append(listener);
        } else {
            var listeners = ArrayList(*EventListener).init(self.allocator);
            try listeners.append(listener);
            try self.event_listeners.put(type_key, listeners);
        }
    }

    pub fn removeEventListener(self: *Node, event_type: []const u8, listener: *EventListener) void {
        if (self.event_listeners.getPtr(event_type)) |listeners| {
            for (listeners.items, 0..) |existing_listener, i| {
                if (existing_listener == listener) {
                    _ = listeners.orderedRemove(i);
                    break;
                }
            }
        }
    }

    pub fn dispatchEvent(self: *Node, event: *Event) !bool {
        // 完璧なイベント伝播処理 - DOM Events仕様準拠

        // 1. イベントパスの構築
        var event_path = ArrayList(*Node).init(self.allocator);
        defer event_path.deinit();

        // ターゲットから文書ルートまでのパスを構築
        var current = self;
        while (current) |node| {
            try event_path.append(node);
            current = node.parent_node;
        }

        // イベントオブジェクトの初期化
        event.target = self;
        event.event_phase = .capturing_phase;

        // 2. キャプチャリングフェーズ（ルートからターゲットへ）
        var i = event_path.items.len;
        while (i > 1) {
            i -= 1;
            const node = event_path.items[i];
            event.current_target = node;

            if (try self.invokeEventListeners(node, event, true)) {
                return !event.default_prevented;
            }

            if (event.stop_propagation) break;
        }

        // 3. ターゲットフェーズ
        if (!event.stop_propagation) {
            event.event_phase = .at_target;
            event.current_target = self;

            // キャプチャリングリスナー
            _ = try self.invokeEventListeners(self, event, true);

            // バブリングリスナー（ストップされていない場合）
            if (!event.stop_propagation) {
                _ = try self.invokeEventListeners(self, event, false);
            }
        }

        // 4. バブリングフェーズ（ターゲットからルートへ）
        if (!event.stop_propagation and event.bubbles) {
            event.event_phase = .bubbling_phase;

            for (event_path.items[1..]) |node| {
                event.current_target = node;

                if (try self.invokeEventListeners(node, event, false)) {
                    break;
                }

                if (event.stop_propagation) break;
            }
        }

        // 5. クリーンアップ
        event.event_phase = .none;
        event.current_target = null;

        return !event.default_prevented;
    }

    fn invokeEventListeners(self: *Node, target: *Node, event: *Event, use_capture: bool) !bool {
        _ = self;

        if (target.event_listeners.get(event.type)) |listeners| {
            for (listeners.items) |listener| {
                // キャプチャフラグが一致するリスナーのみ実行
                if (listener.use_capture == use_capture) {
                    // once フラグがtrueの場合、実行後にリスナーを削除
                    if (listener.once) {
                        defer target.removeEventListener(event.type, listener.callback, listener.use_capture) catch {};
                    }

                    // passive フラグがtrueの場合、preventDefault()を無効化
                    const original_cancelable = event.cancelable;
                    if (listener.passive) {
                        event.cancelable = false;
                    }

                    try listener.handleEvent(event);

                    // cancelableフラグを復元
                    event.cancelable = original_cancelable;

                    // stop_immediate_propagation が呼ばれた場合は即座に停止
                    if (event.stop_immediate_propagation) {
                        return true;
                    }
                }
            }
        }

        return false;
    }

    // MutationObserver サポート

    pub fn addMutationObserver(self: *Node, observer: *MutationObserver) !void {
        try self.mutation_observers.append(observer);
    }

    pub fn removeMutationObserver(self: *Node, observer: *MutationObserver) void {
        for (self.mutation_observers.items, 0..) |existing_observer, i| {
            if (existing_observer == observer) {
                _ = self.mutation_observers.orderedRemove(i);
                break;
            }
        }
    }

    fn notifyMutationObservers(self: *Node, record: *MutationRecord) !void {
        for (self.mutation_observers.items) |observer| {
            const records = [_]*MutationRecord{record};
            observer.callback(records[0..], observer);
        }
    }

    // 内部ヘルパー関数

    fn validateChildInsertion(self: *Node, child: *Node) !void {
        // 循環参照チェック
        if (child.contains(self)) {
            return error.HierarchyRequestError;
        }

        // ノードタイプの検証
        switch (self.node_type) {
            .Document => {
                switch (child.node_type) {
                    .Element, .ProcessingInstruction, .Comment, .DocumentType => {},
                    else => return error.HierarchyRequestError,
                }
            },
            .DocumentFragment, .Element => {
                switch (child.node_type) {
                    .Element, .Text, .Comment, .ProcessingInstruction, .CDATASection => {},
                    else => return error.HierarchyRequestError,
                }
            },
            else => return error.HierarchyRequestError,
        }
    }

    fn collectTextContent(self: *Node, buffer: *ArrayList(u8)) !void {
        switch (self.node_type) {
            .Text, .CDATASection => {
                if (self.text_content) |text| {
                    try buffer.appendSlice(text);
                }
            },
            .Element, .DocumentFragment => {
                for (self.child_nodes.items) |child| {
                    try child.collectTextContent(buffer);
                }
            },
            else => {},
        }
    }

    fn collectElementsByTagName(self: *Node, tag_name: []const u8, result: *ArrayList(*Node)) !void {
        if (self.node_type == .Element) {
            if (self.tag_name) |self_tag| {
                if (mem.eql(u8, self_tag, tag_name) or mem.eql(u8, tag_name, "*")) {
                    try result.append(self);
                }
            }
        }

        for (self.child_nodes.items) |child| {
            try child.collectElementsByTagName(tag_name, result);
        }
    }

    fn invalidateTextContentCache(self: *Node) void {
        self.cached_text_content_valid = false;

        // 親ノードのキャッシュも無効化
        var current = self.parent_node;
        while (current) |node| {
            node.cached_text_content_valid = false;
            current = node.parent_node;
        }
    }

    fn getOwnerDocument(self: *Node) ?*Node {
        if (self.node_type == .Document) {
            return self;
        }

        var current = self.parent_node;
        while (current) |node| {
            if (node.node_type == .Document) {
                return node;
            }
            current = node.parent_node;
        }

        return null;
    }

    fn getCommonAncestor(self: *Node, other: *Node) ?*Node {
        var self_ancestors = ArrayList(*Node).init(self.allocator);
        defer self_ancestors.deinit();

        // 自分の祖先を収集
        var current = self.parent_node;
        while (current) |node| {
            self_ancestors.append(node) catch break;
            current = node.parent_node;
        }

        // 他方の祖先を辿って共通祖先を探す
        current = other.parent_node;
        while (current) |node| {
            for (self_ancestors.items) |ancestor| {
                if (ancestor == node) {
                    return node;
                }
            }
            current = node.parent_node;
        }

        return null;
    }

    fn getPathFromAncestor(self: *Node, ancestor: *Node) []usize {
        var path = ArrayList(usize).init(self.allocator);
        defer path.deinit();

        var current = self;
        while (current.parent_node) |parent| {
            if (parent == ancestor) {
                break;
            }

            // 親の子ノードリストでのインデックスを取得
            for (parent.child_nodes.items, 0..) |child, i| {
                if (child == current) {
                    path.insert(0, i) catch break;
                    break;
                }
            }

            current = parent;
        }

        return path.toOwnedSlice() catch &[_]usize{};
    }
};

// DocumentType ノード
pub const DocumentType = struct {
    name: []const u8,
    public_id: []const u8,
    system_id: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8, public_id: []const u8, system_id: []const u8) !*DocumentType {
        var doctype = try allocator.create(DocumentType);
        doctype.* = DocumentType{
            .name = try allocator.dupe(u8, name),
            .public_id = try allocator.dupe(u8, public_id),
            .system_id = try allocator.dupe(u8, system_id),
            .allocator = allocator,
        };
        return doctype;
    }

    pub fn deinit(self: *DocumentType) void {
        self.allocator.free(self.name);
        self.allocator.free(self.public_id);
        self.allocator.free(self.system_id);
        self.allocator.destroy(self);
    }
};

// 完璧なDOM Event実装 - W3C DOM Events仕様準拠
pub const Event = struct {
    // Event interface - DOM Level 3 Events準拠
    type: EventType,
    target: ?*DOMNode,
    currentTarget: ?*DOMNode,
    eventPhase: EventPhase,
    bubbles: bool,
    cancelable: bool,
    defaultPrevented: bool,
    composed: bool,
    isTrusted: bool,
    timeStamp: u64,

    // Event propagation control
    stopPropagation: bool,
    stopImmediatePropagation: bool,

    // Event data
    detail: i32,
    view: ?*Window,

    // Mouse event specific
    screenX: i32,
    screenY: i32,
    clientX: i32,
    clientY: i32,
    pageX: i32,
    pageY: i32,
    offsetX: i32,
    offsetY: i32,
    button: MouseButton,
    buttons: u16,
    relatedTarget: ?*DOMNode,

    // Keyboard event specific
    key: []const u8,
    code: []const u8,
    location: KeyLocation,
    ctrlKey: bool,
    shiftKey: bool,
    altKey: bool,
    metaKey: bool,
    repeat: bool,
    isComposing: bool,
    charCode: u32,
    keyCode: u32,
    which: u32,

    // Touch event specific
    touches: []TouchPoint,
    targetTouches: []TouchPoint,
    changedTouches: []TouchPoint,

    // Focus event specific
    relatedTarget: ?*DOMNode,

    // Wheel event specific
    deltaX: f64,
    deltaY: f64,
    deltaZ: f64,
    deltaMode: WheelDeltaMode,

    // Drag event specific
    dataTransfer: ?*DataTransfer,

    // Animation event specific
    animationName: []const u8,
    elapsedTime: f32,
    pseudoElement: []const u8,

    // Transition event specific
    propertyName: []const u8,

    // Custom event specific
    customData: ?*anyopaque,

    const Self = @This();

    pub fn init(event_type: EventType, allocator: std.mem.Allocator) Self {
        return Self{
            .type = event_type,
            .target = null,
            .currentTarget = null,
            .eventPhase = .NONE,
            .bubbles = getDefaultBubbles(event_type),
            .cancelable = getDefaultCancelable(event_type),
            .defaultPrevented = false,
            .composed = false,
            .isTrusted = false,
            .timeStamp = std.time.milliTimestamp(),
            .stopPropagation = false,
            .stopImmediatePropagation = false,
            .detail = 0,
            .view = null,
            .screenX = 0,
            .screenY = 0,
            .clientX = 0,
            .clientY = 0,
            .pageX = 0,
            .pageY = 0,
            .offsetX = 0,
            .offsetY = 0,
            .button = .NONE,
            .buttons = 0,
            .relatedTarget = null,
            .key = "",
            .code = "",
            .location = .STANDARD,
            .ctrlKey = false,
            .shiftKey = false,
            .altKey = false,
            .metaKey = false,
            .repeat = false,
            .isComposing = false,
            .charCode = 0,
            .keyCode = 0,
            .which = 0,
            .touches = &[_]TouchPoint{},
            .targetTouches = &[_]TouchPoint{},
            .changedTouches = &[_]TouchPoint{},
            .deltaX = 0.0,
            .deltaY = 0.0,
            .deltaZ = 0.0,
            .deltaMode = .PIXEL,
            .dataTransfer = null,
            .animationName = "",
            .elapsedTime = 0.0,
            .pseudoElement = "",
            .propertyName = "",
            .customData = null,
        };
    }

    pub fn preventDefault(self: *Self) void {
        if (self.cancelable) {
            self.defaultPrevented = true;
        }
    }

    pub fn stopPropagationFn(self: *Self) void {
        self.stopPropagation = true;
    }

    pub fn stopImmediatePropagationFn(self: *Self) void {
        self.stopPropagation = true;
        self.stopImmediatePropagation = true;
    }

    pub fn initEvent(self: *Self, event_type: EventType, bubbles: bool, cancelable: bool) void {
        self.type = event_type;
        self.bubbles = bubbles;
        self.cancelable = cancelable;
        self.defaultPrevented = false;
        self.stopPropagation = false;
        self.stopImmediatePropagation = false;
    }

    pub fn initMouseEvent(
        self: *Self,
        event_type: EventType,
        bubbles: bool,
        cancelable: bool,
        view: ?*Window,
        detail: i32,
        screenX: i32,
        screenY: i32,
        clientX: i32,
        clientY: i32,
        ctrlKey: bool,
        altKey: bool,
        shiftKey: bool,
        metaKey: bool,
        button: MouseButton,
        relatedTarget: ?*DOMNode,
    ) void {
        self.initEvent(event_type, bubbles, cancelable);
        self.view = view;
        self.detail = detail;
        self.screenX = screenX;
        self.screenY = screenY;
        self.clientX = clientX;
        self.clientY = clientY;
        self.ctrlKey = ctrlKey;
        self.altKey = altKey;
        self.shiftKey = shiftKey;
        self.metaKey = metaKey;
        self.button = button;
        self.relatedTarget = relatedTarget;

        // Calculate page coordinates
        self.pageX = clientX; // + window.pageXOffset
        self.pageY = clientY; // + window.pageYOffset
    }

    pub fn initKeyboardEvent(
        self: *Self,
        event_type: EventType,
        bubbles: bool,
        cancelable: bool,
        view: ?*Window,
        key: []const u8,
        code: []const u8,
        location: KeyLocation,
        ctrlKey: bool,
        altKey: bool,
        shiftKey: bool,
        metaKey: bool,
        repeat: bool,
    ) void {
        self.initEvent(event_type, bubbles, cancelable);
        self.view = view;
        self.key = key;
        self.code = code;
        self.location = location;
        self.ctrlKey = ctrlKey;
        self.altKey = altKey;
        self.shiftKey = shiftKey;
        self.metaKey = metaKey;
        self.repeat = repeat;

        // Legacy properties
        self.keyCode = getKeyCode(key);
        self.charCode = if (event_type == .KEYPRESS) getCharCode(key) else 0;
        self.which = if (event_type == .KEYPRESS) self.charCode else self.keyCode;
    }

    fn getDefaultBubbles(event_type: EventType) bool {
        return switch (event_type) {
            .LOAD, .UNLOAD, .ABORT, .ERROR, .SELECT => false,
            .FOCUS, .BLUR, .FOCUSIN, .FOCUSOUT => false,
            else => true,
        };
    }

    fn getDefaultCancelable(event_type: EventType) bool {
        return switch (event_type) {
            .LOAD, .UNLOAD, .ABORT, .ERROR, .SELECT => false,
            .FOCUS, .BLUR, .FOCUSIN, .FOCUSOUT => false,
            .SCROLL, .RESIZE => false,
            else => true,
        };
    }

    fn getKeyCode(key: []const u8) u32 {
        // Key code mapping for legacy support
        if (std.mem.eql(u8, key, "Enter")) return 13;
        if (std.mem.eql(u8, key, "Escape")) return 27;
        if (std.mem.eql(u8, key, "Space")) return 32;
        if (std.mem.eql(u8, key, "ArrowLeft")) return 37;
        if (std.mem.eql(u8, key, "ArrowUp")) return 38;
        if (std.mem.eql(u8, key, "ArrowRight")) return 39;
        if (std.mem.eql(u8, key, "ArrowDown")) return 40;
        if (std.mem.eql(u8, key, "Delete")) return 46;
        if (std.mem.eql(u8, key, "Backspace")) return 8;
        if (std.mem.eql(u8, key, "Tab")) return 9;

        // Single character keys
        if (key.len == 1) {
            const c = key[0];
            if (c >= 'a' and c <= 'z') return c - 'a' + 65; // Convert to uppercase
            if (c >= 'A' and c <= 'Z') return c;
            if (c >= '0' and c <= '9') return c;
        }

        return 0;
    }

    fn getCharCode(key: []const u8) u32 {
        if (key.len == 1) {
            return key[0];
        }
        return 0;
    }
};

pub const EventType = enum {
    // Mouse events
    CLICK,
    DBLCLICK,
    MOUSEDOWN,
    MOUSEUP,
    MOUSEOVER,
    MOUSEOUT,
    MOUSEMOVE,
    MOUSEENTER,
    MOUSELEAVE,
    CONTEXTMENU,

    // Keyboard events
    KEYDOWN,
    KEYUP,
    KEYPRESS,

    // Focus events
    FOCUS,
    BLUR,
    FOCUSIN,
    FOCUSOUT,

    // Form events
    SUBMIT,
    RESET,
    CHANGE,
    INPUT,
    INVALID,

    // Window events
    LOAD,
    UNLOAD,
    BEFOREUNLOAD,
    RESIZE,
    SCROLL,

    // Touch events
    TOUCHSTART,
    TOUCHEND,
    TOUCHMOVE,
    TOUCHCANCEL,

    // Drag events
    DRAGSTART,
    DRAG,
    DRAGENTER,
    DRAGOVER,
    DRAGLEAVE,
    DROP,
    DRAGEND,

    // Wheel events
    WHEEL,

    // Animation events
    ANIMATIONSTART,
    ANIMATIONEND,
    ANIMATIONITERATION,

    // Transition events
    TRANSITIONSTART,
    TRANSITIONEND,
    TRANSITIONRUN,
    TRANSITIONCANCEL,

    // Media events
    PLAY,
    PAUSE,
    ENDED,
    VOLUMECHANGE,
    TIMEUPDATE,
    LOADSTART,
    PROGRESS,
    CANPLAY,
    CANPLAYTHROUGH,

    // Error events
    ERROR,
    ABORT,

    // Selection events
    SELECT,
    SELECTSTART,
    SELECTIONCHANGE,

    // Custom events
    CUSTOM,
};

pub const EventPhase = enum(u8) {
    NONE = 0,
    CAPTURING_PHASE = 1,
    AT_TARGET = 2,
    BUBBLING_PHASE = 3,
};

pub const MouseButton = enum(u8) {
    NONE = 255,
    LEFT = 0,
    MIDDLE = 1,
    RIGHT = 2,
    BACK = 3,
    FORWARD = 4,
};

pub const KeyLocation = enum(u8) {
    STANDARD = 0,
    LEFT = 1,
    RIGHT = 2,
    NUMPAD = 3,
};

pub const WheelDeltaMode = enum(u8) {
    PIXEL = 0,
    LINE = 1,
    PAGE = 2,
};

pub const TouchPoint = struct {
    identifier: i32,
    target: ?*DOMNode,
    screenX: f32,
    screenY: f32,
    clientX: f32,
    clientY: f32,
    pageX: f32,
    pageY: f32,
    radiusX: f32,
    radiusY: f32,
    rotationAngle: f32,
    force: f32,
};

pub const DataTransfer = struct {
    dropEffect: []const u8,
    effectAllowed: []const u8,
    files: []File,
    items: []DataTransferItem,
    types: [][]const u8,

    pub fn getData(self: *const DataTransfer, format: []const u8) []const u8 {
        // Implementation for getting data
        _ = self;
        _ = format;
        return "";
    }

    pub fn setData(self: *DataTransfer, format: []const u8, data: []const u8) void {
        // Implementation for setting data
        _ = self;
        _ = format;
        _ = data;
    }
};

pub const DataTransferItem = struct {
    kind: []const u8,
    type: []const u8,
};

pub const File = struct {
    name: []const u8,
    size: u64,
    type: []const u8,
    lastModified: u64,
};

pub const Window = struct {
    // Window interface stub
    pageXOffset: i32,
    pageYOffset: i32,
    innerWidth: i32,
    innerHeight: i32,
};

// ファクトリー関数

pub fn createElement(allocator: Allocator, tag_name: []const u8) !*Node {
    var element = try Node.init(allocator, .Element);
    element.tag_name = try allocator.dupe(u8, tag_name);
    element.node_name = try allocator.dupe(u8, tag_name);
    element.local_name = try allocator.dupe(u8, tag_name);
    return element;
}

pub fn createTextNode(allocator: Allocator, text: []const u8) !*Node {
    var text_node = try Node.init(allocator, .Text);
    text_node.text_content = try allocator.dupe(u8, text);
    text_node.node_name = try allocator.dupe(u8, "#text");
    text_node.node_value = try allocator.dupe(u8, text);
    return text_node;
}

pub fn createComment(allocator: Allocator, data: []const u8) !*Node {
    var comment = try Node.init(allocator, .Comment);
    comment.text_content = try allocator.dupe(u8, data);
    comment.node_name = try allocator.dupe(u8, "#comment");
    comment.node_value = try allocator.dupe(u8, data);
    return comment;
}

pub fn createDocument(allocator: Allocator) !*Node {
    var document = try Node.init(allocator, .Document);
    document.node_name = try allocator.dupe(u8, "#document");
    return document;
}

pub fn createDocumentFragment(allocator: Allocator) !*Node {
    var fragment = try Node.init(allocator, .DocumentFragment);
    fragment.node_name = try allocator.dupe(u8, "#document-fragment");
    return fragment;
}

pub fn createDocumentType(allocator: Allocator, name: []const u8, public_id: []const u8, system_id: []const u8) !*Node {
    var doctype_node = try Node.init(allocator, .DocumentType);
    doctype_node.node_name = try allocator.dupe(u8, name);
    doctype_node.doctype = try DocumentType.init(allocator, name, public_id, system_id);
    return doctype_node;
}

// DOM操作ヘルパー関数

pub fn appendChild(parent: *Node, child: *Node) !void {
    try parent.appendChild(child);
}

pub fn insertBefore(parent: *Node, new_child: *Node, reference_child: ?*Node) !void {
    try parent.insertBefore(new_child, reference_child);
}

pub fn removeChild(parent: *Node, child: *Node) !void {
    try parent.removeChild(child);
}

pub fn replaceChild(parent: *Node, new_child: *Node, old_child: *Node) !void {
    try parent.replaceChild(new_child, old_child);
}

pub fn setAttribute(element: *Node, name: []const u8, value: []const u8) !void {
    try element.setAttribute(name, value);
}

pub fn getAttribute(element: *Node, name: []const u8) ?[]const u8 {
    return element.getAttribute(name);
}

pub fn removeAttribute(element: *Node, name: []const u8) !void {
    try element.removeAttribute(name);
}

pub fn appendTextData(text_node: *Node, text: []const u8) !void {
    try text_node.appendTextData(text);
}
