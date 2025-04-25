// src/zig/dom/traversal/node_filter.zig
// DOM Traversal 仕様 (https://dom.spec.whatwg.org/#traversal)
// における NodeFilter インターフェースに関連する定数とヘルパーを定義します。
// NodeFilter は、NodeIterator および TreeWalker が DOM ツリーを走査する際に、
// どのノードを考慮するかを決定するために使用されます。

const std = @import("std");
const Node = @import("../node.zig").Node;
const NodeType = @import("../node_type.zig").NodeType;
// Text ノードの型をインポート (テスト用)
const Text = @import("../text.zig").Text;

/// NodeIterator や TreeWalker がノードを受け入れるかどうかを決定するための
/// フィルターメソッドと定数を定義します。
pub const NodeFilter = struct {
    // --- Filter Constants ---
    // NodeFilter の acceptNode メソッド (またはそれに相当するコールバック) の戻り値です。

    /// ノードを受け入れます。
    /// NodeIterator: このノードを返します。
    /// TreeWalker: このノードを返します。
    pub const FILTER_ACCEPT: i32 = 1;

    /// ノードを拒否します。
    /// NodeIterator: このノードとその子孫を無視し、次の兄弟ノードへ進みます。
    /// TreeWalker: このノードとその子孫を無視し、次の兄弟ノードへ進みます。
    pub const FILTER_REJECT: i32 = 2;

    /// ノードをスキップします。
    /// NodeIterator: FILTER_REJECT と同じ動作をします。
    /// TreeWalker: このノード自体は無視しますが、その子ノードは引き続き走査対象となります。
    ///             その後、次の兄弟ノードへ進みます。
    pub const FILTER_SKIP: i32 = 3;

    // --- Show Constants ---
    // NodeIterator や TreeWalker の whatToShow パラメータで使用されるビットマスク値です。
    // 表示したいノードタイプに対応するビットを立てます。

    pub const SHOW_ALL: u32 = 0xFFFFFFFF;
    pub const SHOW_ELEMENT: u32 = 0x00000001;
    pub const SHOW_ATTRIBUTE: u32 = 0x00000002; // Attr ノード用 (Attr が Node を継承する場合)
    pub const SHOW_TEXT: u32 = 0x00000004;
    pub const SHOW_CDATA_SECTION: u32 = 0x00000008; // 多くの場合 SHOW_TEXT に包含される
    pub const SHOW_ENTITY_REFERENCE: u32 = 0x00000010; // レガシー
    pub const SHOW_ENTITY: u32 = 0x00000020; // レガシー
    pub const SHOW_PROCESSING_INSTRUCTION: u32 = 0x00000040;
    pub const SHOW_COMMENT: u32 = 0x00000080;
    pub const SHOW_DOCUMENT: u32 = 0x00000100;
    pub const SHOW_DOCUMENT_TYPE: u32 = 0x00000200;
    pub const SHOW_DOCUMENT_FRAGMENT: u32 = 0x00000400;
    pub const SHOW_NOTATION: u32 = 0x00000800; // レガシー

    // --- NodeFilter Interface (Conceptual) ---
    // DOM 仕様における NodeFilter は、acceptNode メソッドを持つインターフェースです。
    // Zig でこれを表現する方法はいくつかありますが、ここでは関数ポインタを用いた
    // CallbackFilter を提供します。

    /// NodeFilter として機能するコールバック関数のシグネチャ。
    /// acceptNode メソッドに相当します。
    /// @param context オプショナルなコンテキストポインタ。フィルターが状態を持つ場合に利用できます。
    /// @param node フィルタリング対象のノード。
    /// @return FILTER_ACCEPT, FILTER_REJECT, または FILTER_SKIP。
    pub const AcceptNodeFn = *const fn (context: ?*anyopaque, node: *Node) i32;

    /// 関数ポインタベースの NodeFilter 実装を提供します。
    /// NodeIterator や TreeWalker にフィルターとして渡すことができます。
    pub const CallbackFilter = struct {
        context: ?*anyopaque,
        accept_node_fn: AcceptNodeFn,

        /// 内部の関数ポインタを呼び出してノードをフィルタリングします。
        pub fn acceptNode(self: CallbackFilter, node: *Node) i32 {
            return self.accept_node_fn(self.context, node);
        }

        /// acceptNode 関数ポインタとオプションのコンテキストから CallbackFilter を作成します。
        pub fn init(func: AcceptNodeFn, ctx: ?*anyopaque) CallbackFilter {
            return .{
                .context = ctx,
                .accept_node_fn = func,
            };
        }
    };

    // `whatToShow` ビットマスクに基づいてノードを素早くフィルタリングするヘルパー関数。
    // これは NodeIterator/TreeWalker がカスタムフィルター (acceptNode) を呼び出す *前* に
    // 行うチェックに相当します。
    // この関数が FILTER_REJECT を返した場合、カスタムフィルターは呼び出されません。
    pub fn acceptNodeToShow(what_to_show: u32, node: *Node) i32 {
        if (what_to_show == SHOW_ALL) {
            return FILTER_ACCEPT; // SHOW_ALL は常に通過
        }

        // Node 型に対応する SHOW_* フラグを取得
        const node_type_flag = nodeTypeToShowFlag(node.node_type);

        if (node_type_flag != 0 and (what_to_show & node_type_flag) != 0) {
            return FILTER_ACCEPT; // whatToShow で指定された型なら ACCEPT
        } else {
            // whatToShow で指定されていない型は REJECT
            // (NodeIterator/TreeWalker はこのノードを無視する)
            return FILTER_REJECT;
        }
    }

    // Node.NodeType を対応する SHOW_* フラグに変換するプライベートヘルパー
    fn nodeTypeToShowFlag(node_type: NodeType) u32 {
        return switch (node_type) {
            .element_node => SHOW_ELEMENT,
            .attribute_node => SHOW_ATTRIBUTE,
            .text_node => SHOW_TEXT,
            .cdata_section_node => SHOW_CDATA_SECTION,
            .entity_reference_node => SHOW_ENTITY_REFERENCE,
            .entity_node => SHOW_ENTITY,
            .processing_instruction_node => SHOW_PROCESSING_INSTRUCTION,
            .comment_node => SHOW_COMMENT,
            .document_node => SHOW_DOCUMENT,
            .document_type_node => SHOW_DOCUMENT_TYPE,
            .document_fragment_node => SHOW_DOCUMENT_FRAGMENT,
            .notation_node => SHOW_NOTATION,
            else => 0, // 不明な型、またはフィルタ対象外の型
        };
    }
};

// --- テスト ---
test "NodeFilter constants" {
    try std.testing.expectEqual(@as(i32, 1), NodeFilter.FILTER_ACCEPT);
    try std.testing.expectEqual(@as(i32, 2), NodeFilter.FILTER_REJECT);
    try std.testing.expectEqual(@as(i32, 3), NodeFilter.FILTER_SKIP);
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), NodeFilter.SHOW_ALL);
    try std.testing.expectEqual(@as(u32, 1), NodeFilter.SHOW_ELEMENT);
    try std.testing.expectEqual(@as(u32, 4), NodeFilter.SHOW_TEXT);
    try std.testing.expectEqual(@as(u32, 128), NodeFilter.SHOW_COMMENT);
}

test "NodeFilter.acceptNodeToShow helper" {
    const allocator = std.testing.allocator; // ★ アロケータを使用
    // テスト用の Document と Node を作成
    // Document は ownerDocument として必要。EventTarget も初期化。
    var doc_node = Node{.node_type = .document_node, .owner_document = null, .parent_node=null, .first_child=null, .last_child=null, .previous_sibling=null, .next_sibling=null, .specific_data=null, .event_target = try @import("../events/event_target.zig").EventTarget.create(allocator)};
    doc_node.owner_document = &doc_node; // Document は自身を指す
    defer doc_node.event_target.destroy(allocator);

    var elem_node = Node{.node_type = .element_node, .owner_document = &doc_node, .parent_node=null, .first_child=null, .last_child=null, .previous_sibling=null, .next_sibling=null, .specific_data=null, .event_target = try @import("../events/event_target.zig").EventTarget.create(allocator)};
    defer elem_node.event_target.destroy(allocator);
    var text_node = Node{.node_type = .text_node, .owner_document = &doc_node, .parent_node=null, .first_child=null, .last_child=null, .previous_sibling=null, .next_sibling=null, .specific_data=null, .event_target = try @import("../events/event_target.zig").EventTarget.create(allocator)};
    defer text_node.event_target.destroy(allocator);
    var comm_node = Node{.node_type = .comment_node, .owner_document = &doc_node, .parent_node=null, .first_child=null, .last_child=null, .previous_sibling=null, .next_sibling=null, .specific_data=null, .event_target = try @import("../events/event_target.zig").EventTarget.create(allocator)};
    defer comm_node.event_target.destroy(allocator);
    var pi_node = Node{.node_type = .processing_instruction_node, .owner_document = &doc_node, .parent_node=null, .first_child=null, .last_child=null, .previous_sibling=null, .next_sibling=null, .specific_data=null, .event_target = try @import("../events/event_target.zig").EventTarget.create(allocator)};
    defer pi_node.event_target.destroy(allocator);

    // SHOW_ALL
    try std.testing.expectEqual(NodeFilter.FILTER_ACCEPT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_ALL, &elem_node));
    try std.testing.expectEqual(NodeFilter.FILTER_ACCEPT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_ALL, &text_node));

    // SHOW_ELEMENT
    try std.testing.expectEqual(NodeFilter.FILTER_ACCEPT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_ELEMENT, &elem_node));
    try std.testing.expectEqual(NodeFilter.FILTER_REJECT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_ELEMENT, &text_node));
    try std.testing.expectEqual(NodeFilter.FILTER_REJECT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_ELEMENT, &comm_node));

    // SHOW_TEXT
    try std.testing.expectEqual(NodeFilter.FILTER_REJECT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_TEXT, &elem_node));
    try std.testing.expectEqual(NodeFilter.FILTER_ACCEPT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_TEXT, &text_node));
    try std.testing.expectEqual(NodeFilter.FILTER_REJECT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_TEXT, &comm_node));

    // SHOW_COMMENT
    try std.testing.expectEqual(NodeFilter.FILTER_REJECT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_COMMENT, &elem_node));
    try std.testing.expectEqual(NodeFilter.FILTER_REJECT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_COMMENT, &text_node));
    try std.testing.expectEqual(NodeFilter.FILTER_ACCEPT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_COMMENT, &comm_node));

    // SHOW_PROCESSING_INSTRUCTION
    try std.testing.expectEqual(NodeFilter.FILTER_REJECT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_PROCESSING_INSTRUCTION, &elem_node));
    try std.testing.expectEqual(NodeFilter.FILTER_ACCEPT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_PROCESSING_INSTRUCTION, &pi_node));

    // SHOW_ELEMENT | SHOW_COMMENT
    const show_elem_comm = NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_COMMENT;
    try std.testing.expectEqual(NodeFilter.FILTER_ACCEPT, NodeFilter.acceptNodeToShow(show_elem_comm, &elem_node));
    try std.testing.expectEqual(NodeFilter.FILTER_REJECT, NodeFilter.acceptNodeToShow(show_elem_comm, &text_node));
    try std.testing.expectEqual(NodeFilter.FILTER_ACCEPT, NodeFilter.acceptNodeToShow(show_elem_comm, &comm_node));
    try std.testing.expectEqual(NodeFilter.FILTER_REJECT, NodeFilter.acceptNodeToShow(show_elem_comm, &pi_node));

    // SHOW_DOCUMENT
    try std.testing.expectEqual(NodeFilter.FILTER_ACCEPT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_DOCUMENT, &doc_node));
    try std.testing.expectEqual(NodeFilter.FILTER_REJECT, NodeFilter.acceptNodeToShow(NodeFilter.SHOW_DOCUMENT, &elem_node));
}

// CallbackFilter のテスト用 acceptNode 関数 (より具体的)
// Text ノードで、かつその内容がコンテキストで指定された文字列と一致する場合のみ ACCEPT する例
fn testAcceptTextNodeWithContent(context: ?*anyopaque, node: *Node) i32 {
    // コンテキストが指定されていない、またはノードが Text ノードでない場合は SKIP
    if (context == null or node.node_type != .text_node) {
        return NodeFilter.FILTER_SKIP;
    }

    // コンテキストを期待される文字列ポインタにキャスト
    const expected_content: [:0]const u8 = @ptrCast(@alignCast(context.?));

    // Text ノードのデータを取得 (specific_data を Text にキャスト)
    // 実際のアプリケーションでは、キャストが安全か確認することが推奨される
    if (node.specific_data) |data_ptr| {
        const text_data: *const Text = @ptrCast(@alignCast(data_ptr));
        if (std.mem.eql(u8, text_data.data, expected_content)) {
            return NodeFilter.FILTER_ACCEPT; // 内容が一致すれば ACCEPT
        } else {
            return NodeFilter.FILTER_REJECT; // 内容が異なれば REJECT
        }
    } else {
        // Text ノードなのにデータがないのは異常だが、ここでは REJECT 扱い
        return NodeFilter.FILTER_REJECT;
    }
}

test "NodeFilter.CallbackFilter" {
    const allocator = std.testing.allocator;
    // テスト用ノードを作成 (Document と EventTarget も初期化)
    const doc_node_storage = Node{.node_type = .document_node, .owner_document = null, .parent_node=null, .first_child=null, .last_child=null, .previous_sibling=null, .next_sibling=null, .specific_data=null, .event_target = try @import("../events/event_target.zig").EventTarget.create(allocator)};
    var doc_node_mut = doc_node_storage; // Mutable copy to set owner_document
    doc_node_mut.owner_document = &doc_node_mut;
    const doc_node = &doc_node_mut; // Use const pointer for testing
    defer doc_node.event_target.destroy(allocator);

    const elem_node = Node{.node_type = .element_node, .owner_document = doc_node, .parent_node=null, .first_child=null, .last_child=null, .previous_sibling=null, .next_sibling=null, .specific_data=null, .event_target = try @import("../events/event_target.zig").EventTarget.create(allocator)};
    defer elem_node.event_target.destroy(allocator);

    // Text ノードを作成し、内容を設定 (Text.create を使うのが理想的)
    const text_content_match = "find me";
    const text_content_nomatch = "not me";
    const text_node_data_match = try allocator.create(Text.SpecificData);
    text_node_data_match.* = .{ .data = try allocator.dupeZ(u8, text_content_match) };
    defer allocator.free(text_node_data_match.data);
    defer allocator.destroy(text_node_data_match);
    const text_node_match = Node{.node_type = .text_node, .owner_document = doc_node, .parent_node=null, .first_child=null, .last_child=null, .previous_sibling=null, .next_sibling=null, .specific_data = text_node_data_match, .event_target = try @import("../events/event_target.zig").EventTarget.create(allocator)};
    defer text_node_match.event_target.destroy(allocator);

    const text_node_data_nomatch = try allocator.create(Text.SpecificData);
    text_node_data_nomatch.* = .{ .data = try allocator.dupeZ(u8, text_content_nomatch) };
    defer allocator.free(text_node_data_nomatch.data);
    defer allocator.destroy(text_node_data_nomatch);
    const text_node_nomatch = Node{.node_type = .text_node, .owner_document = doc_node, .parent_node=null, .first_child=null, .last_child=null, .previous_sibling=null, .next_sibling=null, .specific_data = text_node_data_nomatch, .event_target = try @import("../events/event_target.zig").EventTarget.create(allocator)};
    defer text_node_nomatch.event_target.destroy(allocator);

    // フィルターを作成 (探したいテキストをコンテキストとして渡す)
    const target_text = "find me";
    const filter = NodeFilter.CallbackFilter.init(testAcceptTextNodeWithContent, @ptrCast(&target_text));

    // テスト実行
    // Element ノードは SKIP されるはず (Text ではないため)
    try std.testing.expectEqual(NodeFilter.FILTER_SKIP, filter.acceptNode(&elem_node));
    // 内容が一致する Text ノードは ACCEPT されるはず
    try std.testing.expectEqual(NodeFilter.FILTER_ACCEPT, filter.acceptNode(&text_node_match));
    // 内容が一致しない Text ノードは REJECT されるはず
    try std.testing.expectEqual(NodeFilter.FILTER_REJECT, filter.acceptNode(&text_node_nomatch));

    // コンテキストなしの場合 (常に SKIP する)
    const filter_no_context = NodeFilter.CallbackFilter.init(testAcceptTextNodeWithContent, null);
    try std.testing.expectEqual(NodeFilter.FILTER_SKIP, filter_no_context.acceptNode(&elem_node));
    try std.testing.expectEqual(NodeFilter.FILTER_SKIP, filter_no_context.acceptNode(&text_node_match));
} 