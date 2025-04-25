// src/zig/dom/node_type.zig
// DOM ノードの種類を表す列挙型を定義します。
// https://dom.spec.whatwg.org/#node

const std = @import("std");

// DOM Node の種類を表す列挙型。
// W3C DOM Standard で定義されている NodeType 定数に対応します。
// https://dom.spec.whatwg.org/#interface-node
pub const NodeType = enum(u8) {
    // Core Types
    element_node = 1,
    attribute_node = 2, // Note: Attributes are no longer Nodes in modern DOM, but used historically.
    text_node = 3,
    cdata_section_node = 4,
    entity_reference_node = 5, // Deprecated
    entity_node = 6,           // Deprecated
    processing_instruction_node = 7,
    comment_node = 8,
    document_node = 9,
    document_type_node = 10,
    document_fragment_node = 11,
    notation_node = 12,        // Deprecated

    // Convenience methods
    pub fn toString(self: NodeType) []const u8 {
        return switch (self) {
            .element_node => "Element",
            .attribute_node => "Attribute",
            .text_node => "Text",
            .cdata_section_node => "CDATASection",
            .entity_reference_node => "EntityReference",
            .entity_node => "Entity",
            .processing_instruction_node => "ProcessingInstruction",
            .comment_node => "Comment",
            .document_node => "Document",
            .document_type_node => "DocumentType",
            .document_fragment_node => "DocumentFragment",
            .notation_node => "Notation",
        };
    }

    // 他のノードを子として持つことができるか
    pub fn canHaveChildren(self: NodeType) bool {
        return switch (self) {
            .element_node,
            .document_node,
            .document_fragment_node => true,
            else => false,
        };
    }
};

// Basic validation tests
test "NodeType toString" {
    try std.testing.expectEqualStrings("Element", NodeType.element_node.toString());
    try std.testing.expectEqualStrings("Text", NodeType.text_node.toString());
    try std.testing.expectEqualStrings("Document", NodeType.document_node.toString());
}

test "NodeType canHaveChildren" {
    try std.testing.expect(NodeType.element_node.canHaveChildren());
    try std.testing.expect(NodeType.document_node.canHaveChildren());
    try std.testing.expect(NodeType.document_fragment_node.canHaveChildren());
    try std.testing.expect(!NodeType.text_node.canHaveChildren());
    try std.testing.expect(!NodeType.comment_node.canHaveChildren());
    try std.testing.expect(!NodeType.attribute_node.canHaveChildren());
}
