// src/zig/dom/a11y.zig
// アクセシビリティツリー生成API
// WAI-ARIA/HTML仕様準拠

const std = @import("std");
const Node = @import("./node.zig").Node;
const Element = @import("./element.zig").Element;

pub const A11yNode = struct {
    role: ?[]const u8,
    label: ?[]const u8,
    aria: ?std.StringHashMap([]const u8),
    children: std.ArrayList(*A11yNode),

    pub fn init(allocator: std.mem.Allocator) A11yNode {
        return A11yNode{
            .role = null,
            .label = null,
            .aria = null,
            .children = std.ArrayList(*A11yNode).init(allocator),
        };
    }
    pub fn deinit(self: *A11yNode) void {
        if (self.aria) |*map| map.deinit();
        for (self.children.items) |child| child.deinit();
        self.children.deinit();
    }
};

/// DOMツリーからA11yツリーを構築
pub fn buildA11yTree(node: *Node, allocator: std.mem.Allocator) !*A11yNode {
    const a11y_node = try allocator.create(A11yNode);
    a11y_node.* = A11yNode.init(allocator);

    if (node.specific_data) |spec| {
        const elem: *Element = @ptrCast(@alignCast(spec));
        a11y_node.role = elem.getRole();
        // aria属性をコピー
        if (elem.aria_attributes) |*map| {
            var aria_map = std.StringHashMap([]const u8).init(allocator);
            var it = map.iterator();
            while (it.next()) |entry| {
                try aria_map.put(entry.key, entry.value_ptr.*);
            }
            a11y_node.aria = aria_map;
        }
        // label推論: aria-label優先、なければlabel属性やtextContent
        if (elem.getAria("label")) |lbl| {
            a11y_node.label = lbl;
        } else if (elem.getAttribute("label")) |lbl| {
            a11y_node.label = lbl;
        } else if (node.getTextContent()) |txt| {
            a11y_node.label = txt;
        }
    }
    // 子ノードを再帰的に処理
    var child = node.first_child;
    while (child != null) : (child = child.?.next_sibling) {
        const child_a11y = try buildA11yTree(child.?, allocator);
        try a11y_node.children.append(child_a11y);
    }
    return a11y_node;
}
