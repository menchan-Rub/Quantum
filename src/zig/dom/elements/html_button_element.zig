// src/zig/dom/elements/html_button_element.zig
// HTMLButtonElement インターフェース (`<button>`)
// https://html.spec.whatwg.org/multipage/form-elements.html#the-button-element

const std = @import("std");
const HTMLElement = @import("./html_element.zig").HTMLElement;
const Element = @import("../element.zig").Element; // Element へのアクセス
const HTMLFormElement = @import("./html_form_element.zig").HTMLFormElement; // form プロパティ用
const Document = @import("../document.zig").Document; // ID要素検索用

pub const HTMLButtonElement = struct {
    base: HTMLElement,

    /// インスタンスを生成
    pub fn create(allocator: std.mem.Allocator, html_element: HTMLElement) !*HTMLButtonElement {
        const el = try allocator.create(HTMLButtonElement);
        el.* = HTMLButtonElement{ .base = html_element };
        return el;
    }

    /// 特殊な破棄処理
    pub fn destroy(self: *HTMLButtonElement, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying HTMLButtonElement specific data for <{s}>", .{self.base.element.data.tag_name});
        self.base.destroy(allocator);
        allocator.destroy(self);
    }

    // --- Properties ---

    // type: "submit", "reset", "button" のいずれか (デフォルトは "submit")
    pub fn getType(self: *const HTMLButtonElement) []const u8 {
        const type_attr = self.base.element.getAttribute("type");
        if (type_attr) |t| {
            // 小文字に変換して比較
            var lower_buf: [10]u8 = undefined; // submit, reset, button を格納できるサイズ
            const lower_t = std.ascii.lowerString(lower_buf[0..std.math.min(t.len, lower_buf.len)], t);
            if (std.mem.eql(u8, lower_t, "submit") or
                std.mem.eql(u8, lower_t, "reset") or
                std.mem.eql(u8, lower_t, "button"))
            {
                return t; // 元の属性値を返す (仕様に準拠)
            }
        }
        return "submit"; // デフォルト値
    }
    pub fn setType(self: *HTMLButtonElement, new_value: []const u8) !void {
        // 値の検証 ("submit" | "reset" | "button")
        var lower_buf: [10]u8 = undefined;
        const lower_value = std.ascii.lowerString(lower_buf[0..std.math.min(new_value.len, lower_buf.len)], new_value);

        if (!std.mem.eql(u8, lower_value, "submit") and
            !std.mem.eql(u8, lower_value, "reset") and
            !std.mem.eql(u8, lower_value, "button"))
        {
            return error.InvalidButtonType;
        }

        try self.base.element.setAttribute("type", new_value);
    }

    pub fn name(self: *const HTMLButtonElement) ?[]const u8 {
        return self.base.element.getAttribute("name");
    }
    pub fn setName(self: *HTMLButtonElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("name", new_value);
    }

    pub fn value(self: *const HTMLButtonElement) ?[]const u8 {
        return self.base.element.getAttribute("value");
    }
    pub fn setValue(self: *HTMLButtonElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("value", new_value);
    }

    // Boolean attributes
    pub fn disabled(self: *const HTMLButtonElement) bool {
        return self.base.element.hasAttribute("disabled");
    }
    pub fn setDisabled(self: *HTMLButtonElement, new_value: bool) !void {
        if (new_value) {
            try self.base.element.setAttribute("disabled", "");
        } else {
            try self.base.element.removeAttribute("disabled");
        }
    }

    pub fn autofocus(self: *const HTMLButtonElement) bool {
        return self.base.element.hasAttribute("autofocus");
    }
    pub fn setAutofocus(self: *HTMLButtonElement, new_value: bool) !void {
        if (new_value) {
            try self.base.element.setAttribute("autofocus", "");
        } else {
            try self.base.element.removeAttribute("autofocus");
        }
    }

    // form プロパティ (読み取り専用)
    // 関連付けられた form 要素を返す
    pub fn form(self: *const HTMLButtonElement) ?*HTMLFormElement {
        // 注: このメソッドはDOMの実装によって詳細が異なります
        // 現在の実装ではnullを返しますが、実際のDOM実装では
        // 以下の手順でformを検索します:
        // 1. form 属性の値 (ID) を取得し、一致するform要素を探す
        // 2. 見つからなければ、祖先要素を辿って最も近いform要素を探す
        _ = self;
        return null;
    }

    // フォームのアクション属性を上書きするURL
    pub fn formAction(self: *const HTMLButtonElement) ?[]const u8 {
        return self.base.element.getAttribute("formaction");
    }

    pub fn setFormAction(self: *HTMLButtonElement, url: []const u8) !void {
        try self.base.element.setAttribute("formaction", url);
    }

    // フォームのエンコードタイプを上書き
    pub fn formEnctype(self: *const HTMLButtonElement) ?[]const u8 {
        const enctype = self.base.element.getAttribute("formenctype");
        if (enctype) |enc| {
            return enc;
        }
        return null;
    }

    pub fn setFormEnctype(self: *HTMLButtonElement, enctype: []const u8) !void {
        // 有効な値を検証
        var lower_buf: [30]u8 = undefined;
        const lower_enctype = std.ascii.lowerString(lower_buf[0..std.math.min(enctype.len, lower_buf.len)], enctype);

        if (!std.mem.eql(u8, lower_enctype, "application/x-www-form-urlencoded") and
            !std.mem.eql(u8, lower_enctype, "multipart/form-data") and
            !std.mem.eql(u8, lower_enctype, "text/plain"))
        {
            return error.InvalidEnctypeValue;
        }

        try self.base.element.setAttribute("formenctype", enctype);
    }

    // フォームの送信メソッドを上書き
    pub fn formMethod(self: *const HTMLButtonElement) ?[]const u8 {
        const method = self.base.element.getAttribute("formmethod");
        if (method) |m| {
            return m;
        }
        return null;
    }

    pub fn setFormMethod(self: *HTMLButtonElement, method: []const u8) !void {
        // 有効な値を検証
        var lower_buf: [10]u8 = undefined;
        const lower_method = std.ascii.lowerString(lower_buf[0..std.math.min(method.len, lower_buf.len)], method);

        if (!std.mem.eql(u8, lower_method, "get") and
            !std.mem.eql(u8, lower_method, "post") and
            !std.mem.eql(u8, lower_method, "dialog"))
        {
            return error.InvalidMethodValue;
        }

        try self.base.element.setAttribute("formmethod", method);
    }

    // フォームの検証をスキップするかどうか
    pub fn formNoValidate(self: *const HTMLButtonElement) bool {
        return self.base.element.hasAttribute("formnovalidate");
    }

    pub fn setFormNoValidate(self: *HTMLButtonElement, no_validate: bool) !void {
        if (no_validate) {
            try self.base.element.setAttribute("formnovalidate", "");
        } else {
            try self.base.element.removeAttribute("formnovalidate");
        }
    }

    // フォーム送信後のレスポンスを表示するコンテキスト
    pub fn formTarget(self: *const HTMLButtonElement) ?[]const u8 {
        return self.base.element.getAttribute("formtarget");
    }

    pub fn setFormTarget(self: *HTMLButtonElement, target: []const u8) !void {
        try self.base.element.setAttribute("formtarget", target);
    }
};
