// src/zig/dom/elements/html_button_element.zig
// HTMLButtonElement インターフェース (`<button>`)
// https://html.spec.whatwg.org/multipage/form-elements.html#the-button-element

const std = @import("std");
const HTMLElement = @import("./html_element.zig").HTMLElement;
const Element = @import("../element.zig").Element; // Element へのアクセス
const HTMLFormElement = @import("./html_form_element.zig").HTMLFormElement; // form プロパティ用

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
        // TODO: 値の検証 ("submit" | "reset" | "button")
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
        // 実装:
        // 1. form 属性の値 (ID) を取得
        // 2. ドキュメントツリーを探索して ID に一致する form 要素を見つける
        // 3. 見つからなければ、祖先要素を辿って form 要素を探す
        // 4. 見つかった form 要素の HTMLFormElement を返す
        // TODO: 上記ロジックを実装
        _ = self; // 未使用警告回避
        return null; // 仮実装
    }

    // TODO: formAction, formEnctype, formMethod, formNoValidate, formTarget
    //       labels (NodeList)
}; 