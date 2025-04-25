// src/zig/dom/elements/html_heading_element.zig
// HTMLHeadingElement インターフェース (`<h1>`-`<h6>`)
// https://html.spec.whatwg.org/multipage/sections.html#the-heading-element

const std = @import("std");
const HTMLElement = @import("./html_element.zig").HTMLElement;

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

    // TODO: level, innerText などのプロパティを実装
}; 