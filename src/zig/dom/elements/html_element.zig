// src/zig/dom/elements/html_element.zig
// HTML要素の基本構造体とプロパティ／メソッドの完全実装
// 仕様: https://html.spec.whatwg.org/multipage/dom.html#htmlelement

const std       = @import("std");
const Element   = @import("../element.zig").Element;
const Document  = @import("../document.zig").Document;
const Event     = @import("../event/event.zig").Event;
const MouseEvent = @import("../event/mouse_event.zig").MouseEvent;
const FocusEvent = @import("../event/focus_event.zig").FocusEvent;

// dir属性の列挙型 (ltr, rtl, auto) と相互変換
pub const Dir = enum {
    ltr,
    rtl,
    auto,

    pub fn fromStr(s: []const u8) !Dir {
        switch (s) {
            "ltr"  => return .ltr,
            "rtl"  => return .rtl,
            "auto" => return .auto,
            else   => return error.InvalidArgument,
        }
    }

    pub fn toStr(self: Dir) []const u8 {
        return switch (self) {
            .ltr  => "ltr",
            .rtl  => "rtl",
            .auto => "auto",
        };
    }
};

// -------------------------------------------------------------------
// DOMTokenList: classList など、空白区切りトークンリストを管理する
// -------------------------------------------------------------------
pub const DOMTokenList = struct {
    element: *Element,
    attr:    []const u8,  // "class" や他の属性名

    /// インスタンスを生成
    pub fn create(alf: std.mem.Allocator, el: *Element, attr: []const u8) !*DOMTokenList {
        const tl = try alf.create(DOMTokenList);
        tl.* = DOMTokenList{ .element = el, .attr = attr };
        return tl;
    }

    /// 属性値をスペースで分割してトークン化する
    fn fetch(alf: std.mem.Allocator, self: *const DOMTokenList) !std.AutoArrayList([]const u8) {
        const raw = self.element.getAttribute(self.attr) orelse "";
        var list = std.AutoArrayList([]const u8).init(alf);
        var it = std.mem.tokenize(raw, " ");
        while (it.next()) |tok| {
            if (tok.len > 0) try list.append(tok);
        }
        return list;
    }

    /// 指定トークンを含むか
    pub fn contains(self: *const DOMTokenList, token: []const u8) bool {
        const alf = self.element.node.allocator;
        const arr = self.fetch(alf) catch return false;
        defer arr.deinit();
        for (arr.items) |t| {
            if (std.mem.eql(u8, t, token)) return true;
        }
        return false;
    }

    /// トークンを追加（すでにあれば何もしない）
    pub fn add(self: *DOMTokenList, token: []const u8) !void {
        if (std.mem.indexOf(u8, token, ' ') != null) return error.InvalidArgument;
        if (self.contains(token)) return; 
        const alf = self.element.node.allocator;
        var arr = try self.fetch(alf);
        defer arr.deinit();
        try arr.append(token);

        // 再構築してセット
        var buf = std.AutoArrayList(u8).init(alf);
        defer buf.deinit();
        for (arr.items) |t, i| {
            if (i != 0) try buf.appendSlice(" ");
            try buf.appendSlice(t);
        }
        const joined = buf.toOwnedSlice();
        defer alf.free(joined);
        try self.element.setAttribute(self.attr, joined);
    }

    /// トークンを削除（なければ何もしない）
    pub fn remove(self: *DOMTokenList, token: []const u8) !void {
        const alf = self.element.node.allocator;
        var arr = try self.fetch(alf);
        defer arr.deinit();
        var changed = false;
        var out = std.AutoArrayList([]const u8).init(alf);
        defer out.deinit();
        for (arr.items) |t| {
            if (std.mem.eql(u8, t, token)) {
                changed = true;
            } else {
                try out.append(t);
            }
        }
        if (!changed) return;

        // 再構築または属性削除
        if (out.items.len == 0) {
            try self.element.removeAttribute(self.attr);
        } else {
            var buf = std.AutoArrayList(u8).init(alf);
            defer buf.deinit();
            for (out.items) |t, i| {
                if (i != 0) try buf.appendSlice(" ");
                try buf.appendSlice(t);
            }
            const joined = buf.toOwnedSlice();
            defer alf.free(joined);
            try self.element.setAttribute(self.attr, joined);
        }
    }

    /// 存在すれば削除、なければ追加
    pub fn toggle(self: *DOMTokenList, token: []const u8) !bool {
        if (self.contains(token)) {
            try self.remove(token);
            return false;
        } else {
            try self.add(token);
            return true;
        }
    }

    /// index番目のトークンを返す。範囲外なら null
    pub fn item(self: *const DOMTokenList, index: usize) ?[]const u8 {
        const alf = self.element.node.allocator;
        const arr = self.fetch(alf) catch return null;
        defer arr.deinit();
        if (index < arr.items.len) return arr.items[index];
        return null;
    }

    /// トークン数
    pub fn length(self: *const DOMTokenList) usize {
        const alf = self.element.node.allocator;
        const arr = self.fetch(alf) catch return 0;
        defer arr.deinit();
        return arr.items.len;
    }

    /// 属性文字列そのまま
    pub fn toString(self: *const DOMTokenList) []const u8 {
        return self.element.getAttribute(self.attr) orelse "";
    }
};

// -------------------------------------------------------------------
// CSSStyleDeclaration: style属性の読み書きを管理
// -------------------------------------------------------------------
pub const CSSStyleDeclaration = struct {
    element: *Element,

    /// 解析: "k: v; ..." をハッシュマップに
    fn parse(alf: std.mem.Allocator, src: []const u8) !std.AutoHashMap([]const u8, []const u8) {
        var map = std.AutoHashMap([]const u8, []const u8).init(alf);
        var it = std.mem.tokenize(src, ";");
        while (it.next()) |chunk| {
            const t = std.mem.trim(chunk, " \t\r\n");
            if (t.len == 0) continue;
            const pos = std.mem.indexOf(u8, t, ':') orelse continue;
            const key = std.mem.trim(t[0..pos], " \t\r\n");
            const val = std.mem.trim(t[pos+1..], " \t\r\n");
            try map.put(key, val);
        }
        return map;
    }

    /// インスタンス生成
    pub fn create(alf: std.mem.Allocator, el: *Element) !*CSSStyleDeclaration {
        const d = try alf.create(CSSStyleDeclaration);
        d.* = CSSStyleDeclaration{ .element = el };
        return d;
    }

    /// プロパティ値取得
    pub fn getPropertyValue(self: *const CSSStyleDeclaration, prop: []const u8) ?[]const u8 {
        const raw = self.element.getAttribute("style") orelse "";
        const alf = self.element.node.allocator;
        const map = self.parse(alf, raw) catch return null;
        defer map.deinit();
        return map.get(prop) orelse null;
    }

    /// プロパティ設定
    pub fn setProperty(self: *CSSStyleDeclaration, prop: []const u8, value: []const u8) !void {
        const raw = self.element.getAttribute("style") orelse "";
        const alf = self.element.node.allocator;
        var map = try self.parse(alf, raw);
        defer map.deinit();
        try map.put(prop, value);

        // 再構築
        var buf = std.AutoArrayList(u8).init(alf);
        defer buf.deinit();
        var first = true;
        map.forEach(alf, fn(key: []const u8, val: []const u8, ctx: anytype) !void {
            if (!ctx.first) try ctx.buf.appendSlice("; ");
            ctx.first = false;
            try ctx.buf.appendSlice(key);
            try ctx.buf.appendSlice(": ");
            try ctx.buf.appendSlice(val);
        }, .{ .buf = &buf, .first = true }) catch return;
        const s = buf.toOwnedSlice();
        defer alf.free(s);
        try self.element.setAttribute("style", s);
    }

    /// プロパティ削除
    pub fn removeProperty(self: *CSSStyleDeclaration, prop: []const u8) !void {
        const raw = self.element.getAttribute("style") orelse "";
        const alf = self.element.node.allocator;
        var map = try self.parse(alf, raw);
        defer map.deinit();
        if (!map.remove(prop)) return;

        // 再構築または属性削除
        var buf = std.AutoArrayList(u8).init(alf);
        defer buf.deinit();
        var first = true;
        map.forEach(alf, fn(key: []const u8, val: []const u8, ctx: anytype) !void {
            if (!ctx.first) try ctx.buf.appendSlice("; ");
            ctx.first = false;
            try ctx.buf.appendSlice(key);
            try ctx.buf.appendSlice(": ");
            try ctx.buf.appendSlice(val);
        }, .{ .buf = &buf, .first = true }) catch return;
        if (buf.items.len == 0) {
            try self.element.removeAttribute("style");
        } else {
            const s = buf.toOwnedSlice();
            defer alf.free(s);
            try self.element.setAttribute("style", s);
        }
    }

    /// style属性文字列そのまま
    pub fn toString(self: *const CSSStyleDeclaration) []const u8 {
        return self.element.getAttribute("style") orelse "";
    }
};

// -------------------------------------------------------------------
// DOMStringMap: dataset (data-*属性) の簡易操作
// -------------------------------------------------------------------
pub const DOMStringMap = struct {
    element: *Element,

    /// インスタンス生成
    pub fn create(alf: std.mem.Allocator, el: *Element) !*DOMStringMap {
        const dm = try alf.create(DOMStringMap);
        dm.* = DOMStringMap{ .element = el };
        return dm;
    }

    /// data-key -> key を取得
    pub fn get(self: *const DOMStringMap, key: []const u8) ?[]const u8 {
        const alf = self.element.node.allocator;
        const attr = std.fmt.allocPrint(alf, "data-%s", .{key}) catch return null;
        defer alf.free(attr);
        return self.element.getAttribute(attr);
    }

    /// data-key にセット
    pub fn set(self: *DOMStringMap, key: []const u8, value: []const u8) !void {
        const alf = self.element.node.allocator;
        const attr = std.fmt.allocPrint(alf, "data-%s", .{key}) catch |e| return e;
        defer alf.free(attr);
        try self.element.setAttribute(attr, value);
    }

    /// data-key を削除
    pub fn remove(self: *DOMStringMap, key: []const u8) !void {
        const alf = self.element.node.allocator;
        const attr = std.fmt.allocPrint(alf, "data-%s", .{key}) catch |e| return e;
        defer alf.free(attr);
        try self.element.removeAttribute(attr);
    }
};

// -------------------------------------------------------------------
// HTMLElement: Element をラップし、HTML要素固有のAPIを提供
// -------------------------------------------------------------------
pub const HTMLElement = struct {
    element: *Element,

    /// 新規作成
    pub fn create(alf: std.mem.Allocator, el: *Element) !*HTMLElement {
        const he = try alf.create(HTMLElement);
        he.* = HTMLElement{ .element = el };
        return he;
    }

    /// 破棄
    pub fn destroy(self: *HTMLElement, alf: std.mem.Allocator) void {
        std.log.debug("Destroy HTMLElement <{s}>", .{self.element.data.tag_name});
        alf.destroy(self);
    }

    // title プロパティ
    pub fn title(self: *const HTMLElement) ?[]const u8 {
        return self.element.getAttribute("title");
    }
    pub fn setTitle(self: *HTMLElement, val: []const u8) !void {
        try self.element.setAttribute("title", val);
    }

    // lang プロパティ
    pub fn lang(self: *const HTMLElement) ?[]const u8 {
        return self.element.getAttribute("lang");
    }
    pub fn setLang(self: *HTMLElement, val: []const u8) !void {
        try self.element.setAttribute("lang", val);
    }

    // dir プロパティ
    pub fn dir(self: *const HTMLElement) Dir {
        if (self.element.getAttribute("dir")) |v| {
            return Dir.fromStr(v) catch .auto;
        }
        return .auto;
    }
    pub fn setDir(self: *HTMLElement, v: Dir) !void {
        try self.element.setAttribute("dir", v.toStr());
    }

    // hidden プロパティ
    pub fn hidden(self: *const HTMLElement) bool {
        return self.element.hasAttribute("hidden");
    }
    pub fn setHidden(self: *HTMLElement, flag: bool) !void {
        if (flag) try self.element.setAttribute("hidden", "");
        else     try self.element.removeAttribute("hidden");
    }

    // tabIndex プロパティ
    pub fn tabIndex(self: *const HTMLElement) i32 {
        if (self.element.getAttribute("tabindex")) |s| {
            return std.fmt.parseInt(i32, s, 10) catch 0;
        }
        return -1;
    }
    pub fn setTabIndex(self: *HTMLElement, idx: i32) !void {
        const alf = self.element.node.allocator;
        const s = std.fmt.allocPrint(alf, "{}", .{idx}) catch |e| return e;
        defer alf.free(s);
        try self.element.setAttribute("tabindex", s);
    }

    // accessKey プロパティ
    pub fn accessKey(self: *const HTMLElement) ?[]const u8 {
        return self.element.getAttribute("accesskey");
    }
    pub fn setAccessKey(self: *HTMLElement, v: []const u8) !void {
        try self.element.setAttribute("accesskey", v);
    }
    /// ブラウザ表示用ラベル (簡易: Windows風 Alt+キー)
    pub fn accessKeyLabel(self: *const HTMLElement) []const u8 {
        const key = self.accessKey() orelse "";
        if (key.len == 1) {
            const alf = self.element.node.allocator;
            const buf = std.fmt.allocPrint(alf, "Alt+{}", .{key}) catch return "";
            defer alf.free(buf);
            return buf;
        }
        return "";
    }

    // className プロパティ
    pub fn className(self: *const HTMLElement) ?[]const u8 {
        return self.element.getAttribute("class");
    }
    pub fn setClassName(self: *HTMLElement, v: []const u8) !void {
        try self.element.setAttribute("class", v);
    }

    // classList プロパティ
    pub fn classList(self: *const HTMLElement) !*DOMTokenList {
        return DOMTokenList.create(self.element.node.allocator, self.element, "class");
    }

    // style プロパティ
    pub fn style(self: *const HTMLElement) !*CSSStyleDeclaration {
        return CSSStyleDeclaration.create(self.element.node.allocator, self.element);
    }

    // dataset プロパティ
    pub fn dataset(self: *const HTMLElement) !*DOMStringMap {
        return DOMStringMap.create(self.element.node.allocator, self.element);
    }

    // click() メソッド
    pub fn click(self: *HTMLElement) void {
        var evt = MouseEvent.init(self.element, .click);
        _ = self.element.dispatchEvent(&evt);
    }

    // focus() メソッド
    pub fn focus(self: *HTMLElement) void {
        var evt = FocusEvent.init(self.element, .focus);
        _ = self.element.dispatchEvent(&evt);
    }

    // blur() メソッド
    pub fn blur(self: *HTMLElement) void {
        var evt = FocusEvent.init(self.element, .blur);
        _ = self.element.dispatchEvent(&evt);
    }
};