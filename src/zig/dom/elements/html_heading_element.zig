// src/zig/dom/elements/html_heading_element.zig
// HTMLHeadingElement インターフェース (`<h1>`-`<h6>`)
// https://html.spec.whatwg.org/multipage/sections.html#the-heading-element

const std = @import("std");
const HTMLElement = @import("./html_element.zig").HTMLElement;
const Node = @import("../node.zig").Node;
const Text = @import("../text.zig").Text;

pub const HTMLHeadingElement = struct {
    base: HTMLElement,

    /// インスタンスを生成
    pub fn create(allocator: std.mem.Allocator, html_element: HTMLElement) !*HTMLHeadingElement {
        const el = try allocator.create(HTMLHeadingElement);
        el.* = HTMLHeadingElement{ .base = html_element };
        return el;
    }

    /// 特殊な破棄処理
    pub fn destroy(self: *HTMLHeadingElement, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying HTMLHeadingElement specific data for <{s}>", .{self.base.element.data.tag_name});
        self.base.destroy(allocator);
        allocator.destroy(self);
    }

    /// 見出しレベルを取得 (1-6)
    pub fn level(self: *const HTMLHeadingElement) u8 {
        const tag_name = self.base.element.data.tag_name;
        if (tag_name.len >= 2) {
            // 例: "h1" -> '1' -> 1
            const level_char = tag_name[1];
            if (level_char >= '1' and level_char <= '6') {
                return level_char - '0';
            }
        }
        return 0; // 不明/無効な場合
    }

    /// 見出しのテキスト内容を取得
    pub fn innerText(self: *const HTMLHeadingElement, allocator: std.mem.Allocator) !?[]const u8 {
        return try self.base.element.node.textContent(allocator);
    }

    /// 見出しのテキスト内容を設定
    pub fn setInnerText(self: *HTMLHeadingElement, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.base.element.node.setTextContent(allocator, text);
    }

    /// 見出しの整列方法を取得
    pub fn getAlignment(self: *const HTMLHeadingElement) ?[]const u8 {
        return self.base.element.getAttribute("align");
    }

    /// 見出しの整列方法を設定
    pub fn setAlignment(self: *HTMLHeadingElement, value: []const u8) !void {
        // 有効な値チェック
        if (!std.mem.eql(u8, value, "left") and
            !std.mem.eql(u8, value, "right") and
            !std.mem.eql(u8, value, "center"))
        {
            return error.InvalidAlignValue;
        }
        try self.base.element.setAttribute("align", value);
    }

    /// テキストを追加するヘルパーメソッド
    pub fn appendText(self: *HTMLHeadingElement, allocator: std.mem.Allocator, text: []const u8) !void {
        const text_node = try Text.createTextNode(allocator, self.base.element.node.owner_document, text);
        _ = try self.base.element.node.appendChild(allocator, &text_node.node);
    }

    /// 見出しをクリアするヘルパーメソッド
    pub fn clear(self: *HTMLHeadingElement, allocator: std.mem.Allocator) !void {
        try self.base.element.node.setTextContent(allocator, "");
    }
};
