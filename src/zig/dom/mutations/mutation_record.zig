// src/zig/dom/mutations/mutation_record.zig
// MutationRecord インターフェース
// https://dom.spec.whatwg.org/#interface-mutationrecord

const std = @import("std");
const Node = @import("../node.zig").Node; // Use forward declaration? No, need Node pointer.
const NodeList = std.ArrayList(*Node); // Use ArrayList for added/removed nodes

pub const MutationType = enum {
    attributes,
    characterData,
    childList,
};

pub const MutationRecord = struct {
    type: MutationType,
    target: *Node,
    addedNodes: NodeList, // Owned list
    removedNodes: NodeList, // Owned list
    previousSibling: ?*Node = null,
    nextSibling: ?*Node = null,
    attributeName: ?[]const u8 = null, // Owned string if not null
    attributeNamespace: ?[]const u8 = null, // Owned string if not null
    oldValue: ?[]const u8 = null, // Owned string if not null

    // allocator を保持して destroy で使えるようにする
    allocator: std.mem.Allocator,

    // MutationRecord を作成 (内部用)
    // 文字列は必要に応じて dupe される想定 (呼び出し元 or ここで)
    // NodeList は空で初期化される
    pub fn create(
        allocator: std.mem.Allocator,
        mutation_type: MutationType,
        target_node: *Node,
    ) !*MutationRecord {
        const record = try allocator.create(MutationRecord);
        errdefer allocator.destroy(record);

        record.* = MutationRecord{
            .allocator = allocator,
            .type = mutation_type,
            .target = target_node,
            .addedNodes = NodeList.init(allocator), // Initialize lists
            .removedNodes = NodeList.init(allocator),
            // other fields default to null
        };

        return record;
    }

    // MutationRecord を破棄
    pub fn destroy(self: *MutationRecord) void {
        // 所有している文字列を解放
        if (self.attributeName) |s| self.allocator.free(s);
        if (self.attributeNamespace) |s| self.allocator.free(s);
        if (self.oldValue) |s| self.allocator.free(s);

        // NodeList を解放 (中の Node* は参照なので解放しない)
        self.addedNodes.deinit();
        self.removedNodes.deinit();

        // 構造体自体を解放
        self.allocator.destroy(self);
    }

    // Helper to add owned attribute name
    pub fn setOwnedAttributeName(self: *MutationRecord, name: []const u8) !void {
        if (self.attributeName) |old| self.allocator.free(old);
        self.attributeName = try self.allocator.dupe(u8, name);
    }
    // Helper to add owned attribute namespace
    pub fn setOwnedAttributeNamespace(self: *MutationRecord, ns: []const u8) !void {
        if (self.attributeNamespace) |old| self.allocator.free(old);
        self.attributeNamespace = try self.allocator.dupe(u8, ns);
    }
    // Helper to add owned old value
    pub fn setOwnedOldValue(self: *MutationRecord, value: []const u8) !void {
        if (self.oldValue) |old| self.allocator.free(old);
        self.oldValue = try self.allocator.dupe(u8, value);
    }
};

// テスト
test "MutationRecord creation and destruction" {
    const allocator = std.testing.allocator;
    var dummy_doc_node = try Node.create(allocator, .document_node, null, null);
    defer dummy_doc_node.destroy(allocator);
    var target_node = try Node.create(allocator, .element_node, dummy_doc_node, null);
    // Note: destroyRecursive should be used if children were added
    defer target_node.destroy(allocator); 

    // childList record
    var record1 = try MutationRecord.create(allocator, .childList, target_node);
    defer record1.destroy();
    try std.testing.expect(record1.type == .childList);
    try std.testing.expect(record1.target == target_node);
    try std.testing.expect(record1.addedNodes.items.len == 0);
    try std.testing.expect(record1.removedNodes.items.len == 0);

    // attributes record
    var record2 = try MutationRecord.create(allocator, .attributes, target_node);
    defer record2.destroy();
    try record2.setOwnedAttributeName("class");
    try record2.setOwnedOldValue("old-class");
    try std.testing.expect(record2.type == .attributes);
    try std.testing.expectEqualStrings(record2.attributeName.?, "class");
    try std.testing.expectEqualStrings(record2.oldValue.?, "old-class");
    try std.testing.expect(record2.attributeNamespace == null);

     // characterData record
    var text_node = try Node.create(allocator, .text_node, dummy_doc_node, null);
    defer text_node.destroy(allocator); 
    var record3 = try MutationRecord.create(allocator, .characterData, text_node);
    defer record3.destroy();
    try record3.setOwnedOldValue("old text");
    try std.testing.expect(record3.type == .characterData);
    try std.testing.expectEqualStrings(record3.oldValue.?, "old text");
} 