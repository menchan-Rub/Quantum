// src/zig/dom/elements/html_anchor_element.zig
// HTMLAnchorElement インターフェース (`<a>`)
// https://html.spec.whatwg.org/multipage/text-level-semantics.html#the-a-element

const std = @import("std");
const allocator_module = @import("../../memory/allocator.zig");
const errors = @import("../../util/error.zig");
const HTMLElement = @import("./html_element.zig").HTMLElement;
const Element = @import("../element.zig").Element; // Element にアクセスするため必要
const Document = @import("../document.zig").Document; // テスト用にインポート

pub const HTMLAnchorElement = struct {
    base: HTMLElement,
    // Anchor 固有のプロパティは属性として ElementData に格納されるため、
    // ここにフィールドは不要。アクセサメソッドを提供する。

    pub fn create(allocator: std.mem.Allocator, html_element: HTMLElement) !*HTMLAnchorElement {
        const anchor = try allocator.create(HTMLAnchorElement);
        anchor.* = HTMLAnchorElement{
            .base = html_element,
        };
        return anchor;
    }

    pub fn destroy(self: *HTMLAnchorElement, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying HTMLAnchorElement specific data (if any) for <{s}>", .{self.base.element.data.tag_name});
        // まずベース HTMLElement を破棄
        self.base.destroy(allocator);
        // 次に自身の構造体を破棄
        allocator.destroy(self);
    }

    // --- Anchor Element Properties ---

    pub fn href(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("href");
    }

    pub fn setHref(self: *HTMLAnchorElement, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.base.element.setAttribute("href", value);
        _ = allocator;
    }

    pub fn target(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("target");
    }

    pub fn setTarget(self: *HTMLAnchorElement, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.base.element.setAttribute("target", value);
        _ = allocator;
    }

    pub fn download(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("download");
    }

    pub fn setDownload(self: *HTMLAnchorElement, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.base.element.setAttribute("download", value);
        _ = allocator;
    }

    pub fn rel(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("rel");
    }

    pub fn setRel(self: *HTMLAnchorElement, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.base.element.setAttribute("rel", value);
        _ = allocator;
    }

    // hreflang
    pub fn hreflang(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("hreflang");
    }
    pub fn setHreflang(self: *HTMLAnchorElement, value: []const u8) !void {
        try self.base.element.setAttribute("hreflang", value);
    }

    // type (名前衝突のため getType/setType に変更)
    pub fn getType(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("type");
    }
    pub fn setType(self: *HTMLAnchorElement, value: []const u8) !void {
        try self.base.element.setAttribute("type", value);
    }

    // referrerPolicy
    // Note: attribute is referrerpolicy, property is referrerPolicy
    pub fn referrerPolicy(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("referrerpolicy");
    }
    pub fn setReferrerPolicy(self: *HTMLAnchorElement, value: []const u8) !void {
        // TODO: 値の検証 (enum?)
        try self.base.element.setAttribute("referrerpolicy", value);
    }

    // ping
    pub fn ping(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("ping");
    }
    pub fn setPing(self: *HTMLAnchorElement, value: []const u8) !void {
        try self.base.element.setAttribute("ping", value);
    }

    // TODO: relList (DOMTokenList)

    // text property (Node.textContent を利用)
    pub fn text(self: *const HTMLAnchorElement, allocator: std.mem.Allocator) !?[]const u8 {
        return self.base.element.node_ptr.textContent(allocator);
    }

    // TODO: origin, protocol, username, password, host, hostname, port, pathname, search, hash
    //       これらは href 属性を解析して取得する必要がある (URL パーサーが必要)
};

// HTMLAnchorElement のテスト
test "HTMLAnchorElement properties" {
    const allocator = std.testing.allocator;
    var doc = try std.testing.allocator.create(Document);
    doc.* = Document.create(allocator, "text/html") catch @panic("Failed to create doc");
    defer doc.destroy();

    var node = try doc.createElement("a");
    defer node.destroyRecursive(allocator);
    const element: *Element = @ptrCast(@alignCast(node.specific_data.?));
    const html_element = element.html_data.?;

    // AnchorElement を作成 (本来は Element.create 内で)
    var anchor = try HTMLAnchorElement.create(allocator, html_element.*);
    defer anchor.destroy(allocator);

    // プロパティを設定・取得
    try anchor.setHref(allocator, "https://example.com/path");
    try std.testing.expectEqualStrings("https://example.com/path", anchor.href().?);

    try anchor.setTarget(allocator, "_blank");
    try std.testing.expectEqualStrings("_blank", anchor.target().?);

    try anchor.setDownload(allocator, "filename.zip");
    try std.testing.expectEqualStrings("filename.zip", anchor.download().?);

    try anchor.setRel(allocator, "noopener noreferrer");
    try std.testing.expectEqualStrings("noopener noreferrer", anchor.rel().?);

    // textContent を設定して text プロパティを確認
    const text_node = try doc.createTextNode("Click Me");
    try node.appendChild(text_node);
    const text_content = try anchor.text(allocator);
    defer if(text_content) |t| allocator.free(t);
    try std.testing.expectEqualStrings("Click Me", text_content.?);
} 