// src/zig/dom/text.zig
// DOM の Text インターフェースに対応する構造体を定義します。
// https://dom.spec.whatwg.org/#interface-text

const std = @import("std");
const mem = @import("../memory/allocator.zig"); // Global allocator
const errors = @import("../util/error.zig");   // Common errors
const Node = @import("./node.zig").Node;
const NodeType = @import("./node_type.zig").NodeType;
const Document = @import("./document.zig").Document;
const MutationRecord = @import("./mutations/mutation_record.zig").MutationRecord;
const MutationType = @import("./mutations/mutation_record.zig").MutationType;

// Text 構造体。
// Node.specific_data からキャストして利用される。
// Node は含まず、Text 固有のデータのみを持つ。
pub const Text = struct {
    // この Text ノードが持つテキストデータ。
    data: []const u8,
    // この Text に関連付けられた Node へのポインタ (逆参照用)
    node_ptr: *Node,

    // Text インスタンスを作成する関数。
    // Node も同時に作成し、*Node を返す。
    pub fn create(
        allocator: std.mem.Allocator,
        owner_document: *Document,
        text_data: []const u8,
    ) !*Node { // 戻り値を *Node に変更
        // 1. TextData を複製して所有権を持つ
        const owned_data = try allocator.dupe(u8, text_data);
        errdefer allocator.free(owned_data);

        // 2. Text 構造体自体を確保
        const text = try allocator.create(Text);
        errdefer allocator.destroy(text);

        // 3. Node 部分を作成 (specific_data として Text* 自身を渡す)
        const node = try Node.create(allocator, .text_node, owner_document, @ptrCast(text));
        // Node 作成失敗時は Text も owned_data も破棄される (上記の errdefer)

        // 4. Text ノードを初期化し、Node へのポインタを設定
        text.* = Text{
            .data = owned_data,
            .node_ptr = node, // Node へのポインタを保存
        };

        std.log.debug("Created Text node with data: \"{s}\" and associated Node", .{text_data});
        return node; // Node へのポインタを返す
    }

    // Text インスタンスと関連データを破棄する関数。
    // Node.destroyRecursive から specific_data を介して呼ばれる想定。
    // この関数は Text 構造体自身と data 文字列のみを解放する。
    // Node 構造体自体の解放は Node.destroyRecursive が行う。
    pub fn destroy(text: *Text, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying Text node data: \"{s}\"", .{text.data});
        // 所有しているテキストデータを解放
        allocator.free(text.data);
        // Text 構造体自身を解放
        allocator.destroy(text);
    }

    // --- Text API (一部) --- Access Node via self.node_ptr

    /// テキストデータを取得します。
    pub fn getData(self: *const Text) []const u8 {
        return self.data;
    }

    /// テキストデータを設定します。
    pub fn setData(self: *Text, allocator: std.mem.Allocator, new_data: []const u8) !void {
        const old_data = self.data; // 古いデータを保持 (MutationRecord 用)
        
        // 新しいデータを複製して所有
        const owned_new_data = try allocator.dupe(u8, new_data);
        // エラーが発生した場合、古いデータはそのまま
        
        // 古いデータを解放
        allocator.free(old_data);
        // 新しいデータを設定
        self.data = owned_new_data;

        // --- MutationObserver 通知 --- 
        if (self.node_ptr.owner_document) |doc| {
            // レコードを作成
            var record = try MutationRecord.create(allocator, .characterData, self.node_ptr);
            errdefer record.destroy(); // キューイング失敗時に解放

            record.oldValue = try allocator.dupe(u8, old_data); // 古い値をコピーして設定
            errdefer allocator.free(record.oldValue.?);

            // Document のキューに追加
            try doc.queueMutationRecord(record);
        } else {
            // ownerDocument がない場合 (通常は発生しないはず)
        }
    }

    // length (読み取り専用プロパティ)
    pub fn length(self: *const Text) usize {
        return self.data.len;
    }

    // TODO: splitText, wholeText など
};

// Text ノードのテスト (修正が必要)
test "Text creation and properties" {
    const allocator = std.testing.allocator;
    var doc = try Document.create(allocator, "text/html");
    defer doc.destroy();

    const initial_data = "Hello, world!";
    // Text.create は *Node を返す
    var node = try Text.create(allocator, doc, initial_data);
    // Node を再帰的に破棄 (Text も解放される)
    defer node.destroyRecursive(allocator);

    // Node のプロパティを確認
    try std.testing.expect(node.node_type == .text_node);
    try std.testing.expect(node.owner_document == doc);

    // Text 固有のデータにアクセス (キャストが必要)
    const text: *Text = @ptrCast(@alignCast(node.specific_data.?));

    // Text のプロパティを確認
    try std.testing.expectEqualStrings(initial_data, text.data);
    try std.testing.expectEqualStrings(initial_data, text.getData());
    try std.testing.expect(text.length() == initial_data.len);
    try std.testing.expect(text.node_ptr == node); // node_ptr が正しいか確認
}

test "Text setData" {
    const allocator = std.testing.allocator;
    var doc = try Document.create(allocator, "text/html");
    defer doc.destroy();
    var node = try Text.create(allocator, doc, "Initial");
    defer node.destroyRecursive(allocator);

    const text: *Text = @ptrCast(@alignCast(node.specific_data.?));

    const new_data = "New data";
    try text.setData(allocator, new_data);

    try std.testing.expectEqualStrings(new_data, text.data);
    try std.testing.expect(text.length() == new_data.len);
} 