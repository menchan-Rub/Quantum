// src/zig/dom/traversal/node_iterator.zig
// DOM Traversal 仕様の NodeIterator インターフェースを実装します。
// https://dom.spec.whatwg.org/#nodeiterator

const std = @import("std");
const Node = @import("../node.zig").Node;
const NodeFilter = @import("./node_filter.zig").NodeFilter;

/// NodeIterator は、特定の NodeFilter によって決定されるノードのセットを
/// 文書順 (document order) で反復処理するために使用されます。
pub const NodeIterator = struct {
    // --- Public Fields (Read-Only) --- https://dom.spec.whatwg.org/#dom-nodeiterator-root
    root: *Node, // 走査の起点となるノード
    whatToShow: u32, // NodeFilter.SHOW_* のビットマスク
    filter: ?NodeFilter.CallbackFilter, // オプションのカスタムフィルター

    // --- Internal State ---
    // 仕様上の "reference node" と "pointer before reference node" に相当
    reference_node: *Node, // 現在のイテレータの位置を示すノード
    pointer_before_reference_node: bool, // イテレータが参照ノードの前にあるか後にあるか
    
    // イテレータがアクティブかどうか (detach で false になる)
    // TODO: DOM の変更に対応するためのより高度なメカニズムが必要になる可能性がある
    is_active: bool,

    // アロケータ (現時点では不要かもしれないが保持)
    allocator: std.mem.Allocator,

    /// NodeIterator を作成します。
    /// 通常は Document.createNodeIterator 経由で呼び出されます。
    pub fn create(
        allocator: std.mem.Allocator,
        root_node: *Node,
        what_to_show: u32,
        node_filter: ?NodeFilter.CallbackFilter,
    ) !*NodeIterator {
        const iterator = try allocator.create(NodeIterator);
        iterator.* = .{
            .root = root_node,
            .whatToShow = what_to_show,
            .filter = node_filter,
            // 初期状態: root ノードの直前を指す
            .reference_node = root_node,
            .pointer_before_reference_node = true,
            .is_active = true,
            .allocator = allocator,
        };
        std.log.debug("Created NodeIterator with root {any}", .{root_node});
        return iterator;
    }

    /// NodeIterator を破棄します。
    /// (現時点では内部でメモリ確保していないため、デアロケートのみ)
    pub fn destroy(self: *NodeIterator) void {
        std.log.debug("Destroying NodeIterator for root {any}", .{self.root});
        self.allocator.destroy(self);
    }

    /// イテレータを非アクティブ化します。仕様上の detach() に相当します。
    /// これ以降、nextNode() や previousNode() は null を返します。
    pub fn detach(self: *NodeIterator) void {
        std.log.debug("Detaching NodeIterator for root {any}", .{self.root});
        self.is_active = false;
    }

    /// 次のノードを取得します。
    /// 仕様: https://dom.spec.whatwg.org/#dom-nodeiterator-nextnode
    pub fn nextNode(self: *NodeIterator) ?*Node {
        if (!self.is_active) return null;

        // TODO: 走査アルゴリズムとフィルタリングを実装
        std.log.warn("NodeIterator.nextNode() not fully implemented yet.", .{});
        return null;
    }

    /// 前のノードを取得します。
    /// 仕様: https://dom.spec.whatwg.org/#dom-nodeiterator-previousnode
    pub fn previousNode(self: *NodeIterator) ?*Node {
        if (!self.is_active) return null;

        // TODO: 逆方向の走査アルゴリズムとフィルタリングを実装
        std.log.warn("NodeIterator.previousNode() not fully implemented yet.", .{});
        return null;
    }

    // --- フィルター適用ヘルパー --- 
    fn filterNode(self: *const NodeIterator, node: *Node) i32 {
        // 1. whatToShow でフィルタリング
        const accept_show = NodeFilter.acceptNodeToShow(self.whatToShow, node);
        if (accept_show == NodeFilter.FILTER_REJECT) {
            return NodeFilter.FILTER_REJECT;
        }

        // 2. カスタムフィルターがあれば適用
        if (self.filter) |f| {
            const accept_custom = f.acceptNode(node);
            // NodeIterator では FILTER_SKIP は FILTER_REJECT として扱う
            if (accept_custom == NodeFilter.FILTER_SKIP) {
                return NodeFilter.FILTER_REJECT;
            }
            return accept_custom;
        } else {
            // カスタムフィルターがなければ、whatToShow の結果 (ACCEPT) を返す
            return NodeFilter.FILTER_ACCEPT;
        }
    }
};

// --- テスト (プレースホルダー) ---
test "NodeIterator creation and basic properties" {
    const allocator = std.testing.allocator;
    // テスト用の Document と Root Node を作成
    var doc_node_storage = Node{.node_type = .document_node, .owner_document = null, .parent_node=null, .first_child=null, .last_child=null, .previous_sibling=null, .next_sibling=null, .specific_data=null, .event_target = try @import("../events/event_target.zig").EventTarget.create(allocator)};
    var doc_node_mut = doc_node_storage;
    doc_node_mut.owner_document = &doc_node_mut;
    const doc_node = &doc_node_mut;
    defer doc_node.event_target.destroy(allocator);

    const root_elem_storage = Node{.node_type = .element_node, .owner_document = doc_node, .parent_node = doc_node, .first_child=null, .last_child=null, .previous_sibling=null, .next_sibling=null, .specific_data=null, .event_target = try @import("../events/event_target.zig").EventTarget.create(allocator)};
    // create に渡すために mutable なポインタが必要
    var root_elem_mut = root_elem_storage; 
    _ = &root_elem_mut; // Use the variable to silence the linter error
    defer root_elem_mut.event_target.destroy(allocator);

    const iterator = try NodeIterator.create(allocator, &root_elem_mut, NodeFilter.SHOW_ALL, null);
    defer iterator.destroy();

    try std.testing.expectEqual(&root_elem_mut, iterator.root);
    try std.testing.expectEqual(NodeFilter.SHOW_ALL, iterator.whatToShow);
    try std.testing.expectEqual(null, iterator.filter);
    try std.testing.expectEqual(&root_elem_mut, iterator.reference_node);
    try std.testing.expectEqual(true, iterator.pointer_before_reference_node);
    try std.testing.expectEqual(true, iterator.is_active);

    iterator.detach();
    try std.testing.expectEqual(false, iterator.is_active);
    try std.testing.expectEqual(null, iterator.nextNode()); // Detached
    try std.testing.expectEqual(null, iterator.previousNode()); // Detached
} 