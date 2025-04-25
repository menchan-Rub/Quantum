// src/zig/dom/elements/html_span_element.zig
// HTMLSpanElement インターフェース
// https://html.spec.whatwg.org/multipage/dom.html#htmlspanelement

const std = @import("std");
const allocator_module = @import("../../memory/allocator.zig"); // Avoid name collision
const HTMLElement = @import("./html_element.zig").HTMLElement;

pub const HTMLSpanElement = struct {
    base: HTMLElement,
    // Span 固有のプロパティは現在なし

    pub fn create(allocator: std.mem.Allocator, html_element: HTMLElement) !*HTMLSpanElement {
        const span = try allocator.create(HTMLSpanElement);
        span.* = HTMLSpanElement{
            .base = html_element,
        };
        return span;
    }

    pub fn destroy(self: *HTMLSpanElement, allocator: std.mem.Allocator) void {
        // Span 固有のデータがあればここで解放
        std.log.debug("Destroying HTMLSpanElement specific data (if any) for <{s}>", .{self.base.element.data.tag_name});
        // まずベース HTMLElement を破棄
        self.base.destroy(allocator);
        // 次に自身の構造体を破棄
        allocator.destroy(self);
    }

    // HTML Span 要素には現在、固有のメソッドやプロパティはない。
}; 