// src/zig/dom/elements/html_div_element.zig
// HTMLDivElement インターフェース
// https://html.spec.whatwg.org/multipage/dom.html#htmldivelement

const std = @import("std");
const allocator_module = @import("../../memory/allocator.zig");
const HTMLElement = @import("./html_element.zig").HTMLElement;

pub const HTMLDivElement = struct {
    base: HTMLElement,
    // Div 固有のプロパティは現在なし

    pub fn create(allocator: std.mem.Allocator, html_element: HTMLElement) !*HTMLDivElement {
        const div = try allocator.create(HTMLDivElement);
        div.* = HTMLDivElement{
            .base = html_element,
        };
        return div;
    }

    pub fn destroy(self: *HTMLDivElement, allocator: std.mem.Allocator) void {
        // Div 固有のデータがあればここで解放
        std.log.debug("Destroying HTMLDivElement specific data (if any) for <{s}>", .{self.base.element.data.tag_name});
        // まずベース HTMLElement を破棄
        self.base.destroy(allocator);
        // 次に自身の構造体を破棄
        allocator.destroy(self);
    }

    // HTML Div 要素には現在、固有のメソッドやプロパティはない。
}; 