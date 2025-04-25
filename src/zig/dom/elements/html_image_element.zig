// src/zig/dom/elements/html_image_element.zig
// HTMLImageElement インターフェース (`<img>`)
// https://html.spec.whatwg.org/multipage/embedded-content.html#the-img-element

const std = @import("std");
const HTMLElement = @import("./html_element.zig").HTMLElement;
const Element = @import("../element.zig").Element; // Element へのアクセス

pub const HTMLImageElement = struct {
    base: HTMLElement,

    pub fn create(allocator: std.mem.Allocator, html_element: HTMLElement) !*HTMLImageElement {
        const el = try allocator.create(HTMLImageElement);
        el.* = HTMLImageElement{ .base = html_element };
        return el;
    }

    pub fn destroy(self: *HTMLImageElement, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying HTMLImageElement specific data for <{s}>", .{self.base.element.data.tag_name});
        // ベース HTMLElement を破棄
        self.base.destroy(allocator);
        // この構造体を破棄
        allocator.destroy(self);
    }

    // --- Properties ---

    pub fn src(self: *const HTMLImageElement) ?[]const u8 {
        return self.base.element.getAttribute("src");
    }
    pub fn setSrc(self: *HTMLImageElement, value: []const u8) !void {
        try self.base.element.setAttribute("src", value);
    }

    pub fn alt(self: *const HTMLImageElement) ?[]const u8 {
        return self.base.element.getAttribute("alt");
    }
    pub fn setAlt(self: *HTMLImageElement, value: []const u8) !void {
        try self.base.element.setAttribute("alt", value);
    }

    // width/height は属性値を数値に変換する必要があるが、ここでは文字列として扱う
    pub fn width(self: *const HTMLImageElement) ?[]const u8 {
        return self.base.element.getAttribute("width");
    }
    pub fn setWidth(self: *HTMLImageElement, value: []const u8) !void {
        // TODO: 数値検証
        try self.base.element.setAttribute("width", value);
    }

    pub fn height(self: *const HTMLImageElement) ?[]const u8 {
        return self.base.element.getAttribute("height");
    }
    pub fn setHeight(self: *HTMLImageElement, value: []const u8) !void {
        // TODO: 数値検証
        try self.base.element.setAttribute("height", value);
    }

    // loading (e.g., "lazy", "eager")
    pub fn loading(self: *const HTMLImageElement) ?[]const u8 {
        return self.base.element.getAttribute("loading");
    }
    pub fn setLoading(self: *HTMLImageElement, value: []const u8) !void {
        // TODO: 値検証 ("lazy" | "eager")
        try self.base.element.setAttribute("loading", value);
    }

    // decoding (e.g., "sync", "async", "auto")
    pub fn decoding(self: *const HTMLImageElement) ?[]const u8 {
        return self.base.element.getAttribute("decoding");
    }
    pub fn setDecoding(self: *HTMLImageElement, value: []const u8) !void {
        // TODO: 値検証 ("sync" | "async" | "auto")
        try self.base.element.setAttribute("decoding", value);
    }

    // TODO: naturalWidth, naturalHeight, currentSrc, complete などの状態プロパティ
}; 