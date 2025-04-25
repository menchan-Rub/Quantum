// src/zig/dom/elements/html_input_element.zig
// HTMLInputElement インターフェース (`<input>`)
// https://html.spec.whatwg.org/multipage/input.html#the-input-element

const std = @import("std");
const HTMLElement = @import("./html_element.zig").HTMLElement;
const Element = @import("../element.zig").Element; // Element へのアクセス

pub const HTMLInputElement = struct {
    base: HTMLElement,

    /// インスタンスを生成
    pub fn create(allocator: std.mem.Allocator, html_element: HTMLElement) !*HTMLInputElement {
        const el = try allocator.create(HTMLInputElement);
        el.* = HTMLInputElement{ .base = html_element };
        return el;
    }

    /// 特殊な破棄処理
    pub fn destroy(self: *HTMLInputElement, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying HTMLInputElement specific data for <{s}>", .{self.base.element.data.tag_name});
        self.base.destroy(allocator);
        allocator.destroy(self);
    }

    // --- Properties ---

    pub fn getType(self: *const HTMLInputElement) ?[]const u8 {
        return self.base.element.getAttribute("type");
    }
    pub fn setType(self: *HTMLInputElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("type", new_value);
    }

    pub fn value(self: *const HTMLInputElement) ?[]const u8 {
        return self.base.element.getAttribute("value");
    }
    pub fn setValue(self: *HTMLInputElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("value", new_value);
    }

    pub fn name(self: *const HTMLInputElement) ?[]const u8 {
        return self.base.element.getAttribute("name");
    }
    pub fn setName(self: *HTMLInputElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("name", new_value);
    }

    pub fn placeholder(self: *const HTMLInputElement) ?[]const u8 {
        return self.base.element.getAttribute("placeholder");
    }
    pub fn setPlaceholder(self: *HTMLInputElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("placeholder", new_value);
    }

    // Boolean attributes
    pub fn disabled(self: *const HTMLInputElement) bool {
        return self.base.element.hasAttribute("disabled");
    }
    pub fn setDisabled(self: *HTMLInputElement, new_value: bool) !void {
        if (new_value) {
            try self.base.element.setAttribute("disabled", ""); // 値は空文字列で設定
        } else {
            try self.base.element.removeAttribute("disabled");
        }
    }

    pub fn readonly(self: *const HTMLInputElement) bool {
        return self.base.element.hasAttribute("readonly");
    }
    pub fn setReadonly(self: *HTMLInputElement, new_value: bool) !void {
        if (new_value) {
            try self.base.element.setAttribute("readonly", "");
        } else {
            try self.base.element.removeAttribute("readonly");
        }
    }

    pub fn required(self: *const HTMLInputElement) bool {
        return self.base.element.hasAttribute("required");
    }
    pub fn setRequired(self: *HTMLInputElement, new_value: bool) !void {
        if (new_value) {
            try self.base.element.setAttribute("required", "");
        } else {
            try self.base.element.removeAttribute("required");
        }
    }

    pub fn checked(self: *const HTMLInputElement) bool {
        return self.base.element.hasAttribute("checked");
    }
    pub fn setChecked(self: *HTMLInputElement, new_value: bool) !void {
        if (new_value) {
            try self.base.element.setAttribute("checked", "");
        } else {
            try self.base.element.removeAttribute("checked");
        }
    }

    // TODO: files, form, list, max, min, step, pattern などのプロパティとメソッド (checkValidity, etc.)
}; 