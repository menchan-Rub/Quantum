// src/zig/dom/traversal/node_iterator.zig
// DOM Traversal 仕様の NodeIterator インターフェースを実装します。
// https://dom.spec.whatwg.org/#nodeiterator

const std = @import("std");
const dom = @import("../../dom/elements/node.zig");
const NodeType = @import("../../dom/elements/node_types.zig").NodeType;
const NodeFilter = @import("./node_filter.zig").NodeFilter;
const NodeFilterResult = @import("./node_filter.zig").NodeFilterResult;

/// NodeFilter の定数
pub const NodeFilterConstants = struct {
    pub const FILTER_ACCEPT: u16 = 1;
    pub const FILTER_REJECT: u16 = 2;
    pub const FILTER_SKIP: u16 = 3;

    // nodeType フィルタリング用の定数
    pub const SHOW_ALL: u32 = 0xFFFFFFFF;
    pub const SHOW_ELEMENT: u32 = 0x1;
    pub const SHOW_ATTRIBUTE: u32 = 0x2;
    pub const SHOW_TEXT: u32 = 0x4;
    pub const SHOW_CDATA_SECTION: u32 = 0x8;
    pub const SHOW_ENTITY_REFERENCE: u32 = 0x10;
    pub const SHOW_ENTITY: u32 = 0x20;
    pub const SHOW_PROCESSING_INSTRUCTION: u32 = 0x40;
    pub const SHOW_COMMENT: u32 = 0x80;
    pub const SHOW_DOCUMENT: u32 = 0x100;
    pub const SHOW_DOCUMENT_TYPE: u32 = 0x200;
    pub const SHOW_DOCUMENT_FRAGMENT: u32 = 0x400;
    pub const SHOW_NOTATION: u32 = 0x800;
};

/// NodeFilter インターフェース定義
pub const CustomNodeFilter = struct {
    acceptNode: *const fn (node: *dom.Node) u16,

    pub fn init(callback: *const fn (node: *dom.Node) u16) CustomNodeFilter {
        return CustomNodeFilter{ .acceptNode = callback };
    }
};

/// NodeIterator インターフェースは、DOM ノードのシーケンスを通じて反復処理する機能を表します。
/// 開始ノードから開始し、ドキュメントツリー内の順序に従ってノードを走査します。
pub const NodeIterator = struct {
    /// イテレータの開始ノード。
    root: *dom.Node,

    /// 現在の参照ノード。
    referenceNode: *dom.Node,

    /// イテレータが現在参照ノードを指す前であるかどうか。
    pointerBeforeReferenceNode: bool,

    /// ノードをフィルタリングするために使用される NodeFilter。
    filter: ?*NodeFilter,

    /// フィルタリングするノードタイプを指定するビットマスク。
    whatToShow: u32,

    /// 新しい NodeIterator を作成します。
    pub fn init(root: *dom.Node, whatToShow: u32, filter: ?*NodeFilter) NodeIterator {
        return NodeIterator{
            .root = root,
            .referenceNode = root,
            .pointerBeforeReferenceNode = true,
            .filter = filter,
            .whatToShow = whatToShow,
        };
    }

    /// 現在の参照ノードを取得します。
    pub fn getRoot(self: *NodeIterator) *dom.Node {
        return self.root;
    }

    /// 現在の参照ノードを取得します。
    pub fn getReferenceNode(self: *NodeIterator) *dom.Node {
        return self.referenceNode;
    }

    /// イテレータが現在参照ノードを指す前であるかどうかを確認します。
    pub fn getPointerBeforeReferenceNode(self: *NodeIterator) bool {
        return self.pointerBeforeReferenceNode;
    }

    /// フィルタリングするノードタイプを指定するビットマスクを取得します。
    pub fn getWhatToShow(self: *NodeIterator) u32 {
        return self.whatToShow;
    }

    /// ノードをフィルタリングするために使用される NodeFilter を取得します。
    pub fn getFilter(self: *NodeIterator) ?*NodeFilter {
        return self.filter;
    }

    /// 次のノードに移動します。
    pub fn nextNode(self: *NodeIterator) ?*dom.Node {
        var result: ?*dom.Node = null;
        var node = self.referenceNode;
        var beforeNode = self.pointerBeforeReferenceNode;

        while (true) {
            if (beforeNode) {
                beforeNode = false;
            } else {
                // 次のノードを探す
                var next = self.getNextNode(node);
                if (next) |nextNode| {
                    node = nextNode;
                } else {
                    return null;
                }
            }

            // ノードをフィルタリングする
            var filterResult = self.acceptNode(node);
            if (filterResult == NodeFilterResult.FILTER_ACCEPT) {
                result = node;
                break;
            }
        }

        self.referenceNode = result orelse self.referenceNode;
        self.pointerBeforeReferenceNode = false;
        return result;
    }

    /// 前のノードに移動します。
    pub fn previousNode(self: *NodeIterator) ?*dom.Node {
        var result: ?*dom.Node = null;
        var node = self.referenceNode;
        var beforeNode = self.pointerBeforeReferenceNode;

        while (true) {
            if (!beforeNode) {
                beforeNode = true;
            } else {
                // 前のノードを探す
                var prev = self.getPreviousNode(node);
                if (prev) |prevNode| {
                    node = prevNode;
                } else {
                    return null;
                }
            }

            // ノードをフィルタリングする
            var filterResult = self.acceptNode(node);
            if (filterResult == NodeFilterResult.FILTER_ACCEPT) {
                result = node;
                break;
            }
        }

        self.referenceNode = result orelse self.referenceNode;
        self.pointerBeforeReferenceNode = true;
        return result;
    }

    /// TreeWalker や NodeIterator を廃止します。
    pub fn detach(self: *NodeIterator) void {
        // DOM4では廃止されたが、互換性のために残している
        // 何もしない
        _ = self;
    }

    /// 指定されたノードをフィルターで受け入れるかどうかを判断します。
    fn acceptNode(self: *NodeIterator, node: *dom.Node) NodeFilterResult {
        // whatToShowビットマスクをチェックする
        if ((self.whatToShow & (@as(u32, 1) << @intCast(node.nodeType - 1))) == 0) {
            return NodeFilterResult.FILTER_SKIP;
        }

        // カスタムフィルタが設定されている場合は呼び出す
        if (self.filter) |filter| {
            return filter.acceptNode(node);
        }

        return NodeFilterResult.FILTER_ACCEPT;
    }

    /// 現在のノードの次のノードを取得します。
    fn getNextNode(self: *NodeIterator, node: *dom.Node) ?*dom.Node {
        // 子ノードがある場合は最初の子を返す
        if (node.firstChild) |child| {
            return child;
        }

        // 子がない場合は兄弟または祖先の兄弟を探す
        var current = node;
        while (true) {
            // ルートに到達した場合は終了
            if (std.meta.eql(current, self.root)) {
                return null;
            }

            // 次の兄弟がある場合はそれを返す
            if (current.nextSibling) |sibling| {
                return sibling;
            }

            // 親ノードに移動
            if (current.parentNode) |parent| {
                current = parent;
            } else {
                return null;
            }
        }

        return null;
    }

    /// 現在のノードの前のノードを取得します。
    fn getPreviousNode(self: *NodeIterator, node: *dom.Node) ?*dom.Node {
        // ルートに到達した場合は終了
        if (std.meta.eql(node, self.root)) {
            return null;
        }

        // 前の兄弟がある場合、その最も深い最後の子孫を返す
        if (node.previousSibling) |sibling| {
            var current = sibling;
            // 最も深い最後の子孫を探す
            while (current.lastChild) |child| {
                current = child;
            }
            return current;
        }

        // 親ノードを返す
        if (node.parentNode) |parent| {
            // ルートの親には戻らない
            if (std.meta.eql(parent, self.root)) {
                return null;
            }
            return parent;
        }

        return null;
    }
};

// ノードAがノードBの祖先かどうかをチェック
fn isAncestorOf(node_a: *dom.Node, node_b: *dom.Node) bool {
    var current = node_b;
    while (current.parentNode != null) {
        if (current.parentNode.? == node_a) {
            return true;
        }
        current = current.parentNode.?;
    }
    return false;
}

// テスト用のNodeFilterCallback
fn testFilterCallback(node: *dom.Node) u16 {
    // テキストノードのみ受け入れる
    if (node.nodeType == .text_node) {
        return NodeFilterConstants.FILTER_ACCEPT;
    }
    return NodeFilterConstants.FILTER_REJECT;
}

test "NodeIterator basic functionality" {
    const allocator = std.testing.allocator;

    // テスト用のDOM構造を作成
    var document = try dom.Document.create(allocator);
    defer document.destroy();

    var root_elem = try document.createElement("div");
    try document.appendChild(root_elem);

    var child1 = try document.createElement("p");
    try root_elem.appendChild(child1);

    var text1 = try document.createTextNode("Hello");
    try child1.appendChild(text1);

    var child2 = try document.createElement("span");
    try root_elem.appendChild(child2);

    var text2 = try document.createTextNode("World");
    try child2.appendChild(text2);

    // NodeIteratorを作成（すべてのノードを表示）
    var iterator = try NodeIterator.init(root_elem, NodeFilterConstants.SHOW_ALL, null);

    // 前進イテレーション
    const node1 = iterator.nextNode();
    try std.testing.expectEqual(child1, @ptrCast(*dom.Element, node1.?));

    const node2 = iterator.nextNode();
    try std.testing.expectEqual(text1, @ptrCast(*dom.Text, node2.?));

    const node3 = iterator.nextNode();
    try std.testing.expectEqual(child2, @ptrCast(*dom.Element, node3.?));

    const node4 = iterator.nextNode();
    try std.testing.expectEqual(text2, @ptrCast(*dom.Text, node4.?));

    const node5 = iterator.nextNode();
    try std.testing.expect(node5 == null); // これ以上ノードはない

    // 後方イテレーション
    const prev1 = iterator.previousNode();
    try std.testing.expectEqual(text2, @ptrCast(*dom.Text, prev1.?));

    const prev2 = iterator.previousNode();
    try std.testing.expectEqual(child2, @ptrCast(*dom.Element, prev2.?));

    const prev3 = iterator.previousNode();
    try std.testing.expectEqual(text1, @ptrCast(*dom.Text, prev3.?));

    const prev4 = iterator.previousNode();
    try std.testing.expectEqual(child1, @ptrCast(*dom.Element, prev4.?));

    const prev5 = iterator.previousNode();
    try std.testing.expect(prev5 == null); // これ以上前のノードはない
}

test "NodeIterator with filter" {
    const allocator = std.testing.allocator;

    // テスト用のDOM構造を作成
    var document = try dom.Document.create(allocator);
    defer document.destroy();

    var root_elem = try document.createElement("div");
    try document.appendChild(root_elem);

    var child1 = try document.createElement("p");
    try root_elem.appendChild(child1);

    var text1 = try document.createTextNode("Hello");
    try child1.appendChild(text1);

    var child2 = try document.createElement("span");
    try root_elem.appendChild(child2);

    var text2 = try document.createTextNode("World");
    try child2.appendChild(text2);

    // テキストノードだけを表示するフィルタを作成
    const filter = CustomNodeFilter.init(testFilterCallback);

    // NodeIteratorをフィルタ付きで作成
    var iterator = try NodeIterator.init(root_elem, NodeFilterConstants.SHOW_ALL, filter);

    // テキストノードだけが返されることを確認
    const node1 = iterator.nextNode();
    try std.testing.expectEqual(text1, @ptrCast(*dom.Text, node1.?));

    const node2 = iterator.nextNode();
    try std.testing.expectEqual(text2, @ptrCast(*dom.Text, node2.?));

    const node3 = iterator.nextNode();
    try std.testing.expect(node3 == null); // これ以上テキストノードはない
}

test "NodeIterator node removal handling" {
    const allocator = std.testing.allocator;

    // テスト用のDOM構造を作成
    var document = try dom.Document.create(allocator);
    defer document.destroy();

    var root_elem = try document.createElement("div");
    try document.appendChild(root_elem);

    var child1 = try document.createElement("p");
    try root_elem.appendChild(child1);

    var text1 = try document.createTextNode("Hello");
    try child1.appendChild(text1);

    var child2 = try document.createElement("span");
    try root_elem.appendChild(child2);

    var text2 = try document.createTextNode("World");
    try child2.appendChild(text2);

    // NodeIteratorを作成
    var iterator = try NodeIterator.init(root_elem, NodeFilterConstants.SHOW_ALL, null);

    // イテレーターを進める
    _ = iterator.nextNode(); // child1
    _ = iterator.nextNode(); // text1

    // 現在の参照ノードはtext1
    try std.testing.expectEqual(text1, iterator.referenceNode);

    // text1の親（child1）を削除
    try child1.remove();

    // イテレーターの状態が適切に更新されていることを確認
    try iterator.handleNodeRemoval(@ptrCast(*dom.Node, child1));

    // 次のノードはchild2になるはず
    const next = iterator.nextNode();
    try std.testing.expectEqual(child2, @ptrCast(*dom.Element, next.?));
}
