// src/zig/dom/elements/html_paragraph_element.zig
// HTMLParagraphElement インターフェース (`<p>`)
// https://html.spec.whatwg.org/multipage/text-level-semantics.html#the-p-element

const std = @import("std");
const HTMLElement = @import("./html_element.zig").HTMLElement;
const Node = @import("../node.zig").Node;
const Text = @import("../text.zig").Text;
const Element = @import("../element.zig").Element;

pub const HTMLParagraphElement = struct {
    base: HTMLElement,

    pub fn create(allocator: std.mem.Allocator, html_element: HTMLElement) !*HTMLParagraphElement {
        const el = try allocator.create(HTMLParagraphElement);
        el.* = HTMLParagraphElement{ .base = html_element };
        return el;
    }

    pub fn destroy(self: *HTMLParagraphElement, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying HTMLParagraphElement specific data for <{s}>", .{self.base.element.data.tag_name});
        self.base.destroy(allocator);
        allocator.destroy(self);
    }

    // textContent - このparagraphの中のテキストを取得
    pub fn textContent(self: *const HTMLParagraphElement, allocator: std.mem.Allocator) !?[]const u8 {
        return try self.base.element.node.textContent(allocator);
    }

    // textContentの設定 - 既存の子を削除してテキストノードを作成
    pub fn setTextContent(self: *HTMLParagraphElement, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.base.element.node.setTextContent(allocator, text);
    }

    // innerHTML - このparagraphの内部HTMLを取得
    pub fn innerHTML(self: *const HTMLParagraphElement, allocator: std.mem.Allocator) ![]const u8 {
        return try self.base.element.innerHTML(allocator);
    }

    // innerHTML設定 - 既存の子を削除して新しいHTMLをパース
    pub fn setInnerHTML(self: *HTMLParagraphElement, allocator: std.mem.Allocator, html: []const u8) !void {
        try self.base.element.setInnerHTML(allocator, html);
    }

    // 段落揃え位置の取得
    pub fn getAlignment(self: *const HTMLParagraphElement) ?[]const u8 {
        return self.base.element.getAttribute("align");
    }

    // 段落揃え位置の設定
    pub fn setAlign(self: *HTMLParagraphElement, value: []const u8) !void {
        // 有効な値チェック
        if (!std.mem.eql(u8, value, "left") and
            !std.mem.eql(u8, value, "right") and
            !std.mem.eql(u8, value, "center") and
            !std.mem.eql(u8, value, "justify"))
        {
            return error.InvalidAlignValue;
        }
        try self.base.element.setAttribute("align", value);
    }

    // テキストを追加するヘルパーメソッド
    pub fn appendText(self: *HTMLParagraphElement, allocator: std.mem.Allocator, text: []const u8) !void {
        const text_node = try Text.createTextNode(allocator, self.base.element.node.owner_document, text);
        _ = try self.base.element.node.appendChild(allocator, &text_node.node);
    }

    // 段落をクリアするヘルパーメソッド
    pub fn clear(self: *HTMLParagraphElement, allocator: std.mem.Allocator) !void {
        try self.base.element.node.setTextContent(allocator, "");
    }
};
