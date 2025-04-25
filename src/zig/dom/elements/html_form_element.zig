// src/zig/dom/elements/html_form_element.zig
// HTMLFormElement インターフェース (`<form>`)
// https://html.spec.whatwg.org/multipage/forms.html#the-form-element

const std = @import("std");
const HTMLElement = @import("./html_element.zig").HTMLElement;
const Element = @import("../element.zig").Element; // Element へのアクセス
const Document = @import("../document.zig").Document; // submit/reset メソッド用

pub const HTMLFormElement = struct {
    base: HTMLElement,

    pub fn create(allocator: std.mem.Allocator, html_element: HTMLElement) !*HTMLFormElement {
        const el = try allocator.create(HTMLFormElement);
        el.* = HTMLFormElement{ .base = html_element };
        return el;
    }

    pub fn destroy(self: *HTMLFormElement, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying HTMLFormElement specific data for <{s}>", .{self.base.element.data.tag_name});
        self.base.destroy(allocator);
        allocator.destroy(self);
    }

    // --- Properties ---

    pub fn action(self: *const HTMLFormElement) ?[]const u8 {
        return self.base.element.getAttribute("action");
    }
    pub fn setAction(self: *HTMLFormElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("action", new_value);
    }

    // method: "get" or "post" (デフォルトは "get")
    pub fn method(self: *const HTMLFormElement) []const u8 {
        const method_attr = self.base.element.getAttribute("method");
        if (method_attr) |m| {
            var lower_buf: [4]u8 = undefined; // get, post を格納できるサイズ
            const lower_m = std.ascii.lowerString(lower_buf[0..std.math.min(m.len, lower_buf.len)], m);
            if (std.mem.eql(u8, lower_m, "post")) {
                return "post";
            }
        }
        return "get"; // デフォルト値
    }
    pub fn setMethod(self: *HTMLFormElement, new_value: []const u8) !void {
        // TODO: 値の検証 ("get" | "post")
        try self.base.element.setAttribute("method", new_value);
    }

    // enctype: e.g., "application/x-www-form-urlencoded", "multipart/form-data", "text/plain"
    pub fn enctype(self: *const HTMLFormElement) ?[]const u8 {
        return self.base.element.getAttribute("enctype");
    }
    pub fn setEnctype(self: *HTMLFormElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("enctype", new_value);
    }

    pub fn target(self: *const HTMLFormElement) ?[]const u8 {
        return self.base.element.getAttribute("target");
    }
    pub fn setTarget(self: *HTMLFormElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("target", new_value);
    }

    // Boolean attribute
    pub fn noValidate(self: *const HTMLFormElement) bool {
        return self.base.element.hasAttribute("novalidate");
    }
    pub fn setNoValidate(self: *HTMLFormElement, new_value: bool) !void {
        if (new_value) {
            try self.base.element.setAttribute("novalidate", "");
        } else {
            try self.base.element.removeAttribute("novalidate");
        }
    }

    pub fn name(self: *const HTMLFormElement) ?[]const u8 {
        return self.base.element.getAttribute("name");
    }
    pub fn setName(self: *HTMLFormElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("name", new_value);
    }

    pub fn rel(self: *const HTMLFormElement) ?[]const u8 {
        return self.base.element.getAttribute("rel");
    }
    pub fn setRel(self: *HTMLFormElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("rel", new_value);
    }

    // --- Methods ---

    pub fn submit(self: *HTMLFormElement) !void {
        // TODO: フォーム送信処理を実装 (イベント発行、バリデーション、ナビゲーションなど)
        _ = self; // 未使用警告回避
        std.log.warn("HTMLFormElement.submit() is not yet implemented.", .{});
    }

    pub fn reset(self: *HTMLFormElement) !void {
        // TODO: フォームリセット処理を実装 (子要素の値をリセット)
        _ = self; // 未使用警告回避
        std.log.warn("HTMLFormElement.reset() is not yet implemented.", .{});
    }

    pub fn checkValidity(self: *const HTMLFormElement) !bool {
        // TODO: フォーム要素のバリデーションチェックを実装
        _ = self; // 未使用警告回避
        return true; // 仮実装
    }

    pub fn reportValidity(self: *const HTMLFormElement) !bool {
        // TODO: バリデーションチェックと結果報告 (UI 表示) を実装
        _ = self; // 未使用警告回避
        return true; // 仮実装
    }

    // TODO: elements (HTMLFormControlsCollection), length プロパティ
}; 