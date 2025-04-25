// src/zig/dom/elements/html_paragraph_element.zig
// HTMLParagraphElement インターフェース (`<p>`)
// https://html.spec.whatwg.org/multipage/text-level-semantics.html#the-p-element

const std = @import("std");
const HTMLElement = @import("./html_element.zig").HTMLElement;

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

    // TODO: textContent, innerHTML などのプロパティ実装
}; 