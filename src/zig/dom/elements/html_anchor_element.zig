// src/zig/dom/elements/html_anchor_element.zig
// HTMLAnchorElement インターフェース (`<a>`)
// https://html.spec.whatwg.org/multipage/text-level-semantics.html#the-a-element

const std = @import("std");
const allocator_module = @import("../../memory/allocator.zig");
const errors = @import("../../util/error.zig");
const HTMLElement = @import("./html_element.zig").HTMLElement;
const Element = @import("../element.zig").Element; // Element にアクセスするため必要
const Document = @import("../document.zig").Document; // テスト用にインポート

// DOMTokenList実装 - relListのために必要
pub const DOMTokenList = struct {
    tokens: std.ArrayList([]u8),
    allocator: std.mem.Allocator,
    attribute_name: []const u8,
    element: *Element,

    pub fn init(allocator: std.mem.Allocator, element: *Element, attribute_name: []const u8) DOMTokenList {
        var token_list = DOMTokenList{
            .tokens = std.ArrayList([]u8).init(allocator),
            .allocator = allocator,
            .attribute_name = attribute_name,
            .element = element,
        };

        // 属性から初期値を設定
        if (element.getAttribute(attribute_name)) |attr_value| {
            token_list.parseAttribute(attr_value);
        }

        return token_list;
    }

    pub fn deinit(self: *DOMTokenList) void {
        for (self.tokens.items) |token| {
            self.allocator.free(token);
        }
        self.tokens.deinit();
    }

    fn parseAttribute(self: *DOMTokenList, attribute_value: []const u8) void {
        // トークンをクリア
        for (self.tokens.items) |token| {
            self.allocator.free(token);
        }
        self.tokens.clearRetainingCapacity();

        // 空白で区切られたトークンをパース
        var iter = std.mem.tokenize(u8, attribute_value, " \t\n\r");
        while (iter.next()) |token| {
            if (token.len > 0) {
                const owned_token = self.allocator.dupe(u8, token) catch continue;
                self.tokens.append(owned_token) catch {
                    self.allocator.free(owned_token);
                };
            }
        }
    }

    // トークンリストの長さを取得
    pub fn length(self: *const DOMTokenList) usize {
        return self.tokens.items.len;
    }

    // インデックスでトークンを取得
    pub fn item(self: *const DOMTokenList, index: usize) ?[]const u8 {
        if (index >= self.tokens.items.len) {
            return null;
        }
        return self.tokens.items[index];
    }

    // トークンが含まれているか確認
    pub fn contains(self: *const DOMTokenList, token: []const u8) bool {
        for (self.tokens.items) |t| {
            if (std.mem.eql(u8, t, token)) {
                return true;
            }
        }
        return false;
    }

    // トークンを追加
    pub fn add(self: *DOMTokenList, token: []const u8) !void {
        if (!self.contains(token)) {
            const owned_token = try self.allocator.dupe(u8, token);
            try self.tokens.append(owned_token);
            try self.updateAttribute();
        }
    }

    // トークンを削除
    pub fn remove(self: *DOMTokenList, token: []const u8) !void {
        var i: usize = 0;
        while (i < self.tokens.items.len) {
            if (std.mem.eql(u8, self.tokens.items[i], token)) {
                const removed = self.tokens.orderedRemove(i);
                self.allocator.free(removed);
                try self.updateAttribute();
                return;
            }
            i += 1;
        }
    }

    // トークンを切り替え (あれば削除、なければ追加)
    pub fn toggle(self: *DOMTokenList, token: []const u8) !bool {
        for (self.tokens.items, 0..) |t, i| {
            if (std.mem.eql(u8, t, token)) {
                const removed = self.tokens.orderedRemove(i);
                self.allocator.free(removed);
                try self.updateAttribute();
                return false;
            }
        }

        const owned_token = try self.allocator.dupe(u8, token);
        try self.tokens.append(owned_token);
        try self.updateAttribute();
        return true;
    }

    // 属性値を更新
    fn updateAttribute(self: *DOMTokenList) !void {
        // トークンを空白区切りで結合
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();

        for (self.tokens.items, 0..) |token, i| {
            try buffer.appendSlice(token);
            if (i < self.tokens.items.len - 1) {
                try buffer.append(' ');
            }
        }

        try self.element.setAttribute(self.attribute_name, buffer.items);
    }

    // トークンリストを文字列として返す
    pub fn toString(self: *const DOMTokenList, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        for (self.tokens.items, 0..) |token, i| {
            try buffer.appendSlice(token);
            if (i < self.tokens.items.len - 1) {
                try buffer.append(' ');
            }
        }

        return buffer.toOwnedSlice();
    }
};

// URLパーサーと URL コンポーネント構造体
const URL = struct {
    protocol: ?[]u8 = null, // "https:"
    username: ?[]u8 = null, // "user"
    password: ?[]u8 = null, // "pass"
    hostname: ?[]u8 = null, // "example.com"
    port: ?[]u8 = null, // "8080"
    pathname: ?[]u8 = null, // "/path"
    search: ?[]u8 = null, // "?query=value"
    hash: ?[]u8 = null, // "#fragment"
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) URL {
        return URL{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *URL) void {
        if (self.protocol) |p| self.allocator.free(p);
        if (self.username) |u| self.allocator.free(u);
        if (self.password) |p| self.allocator.free(p);
        if (self.hostname) |h| self.allocator.free(h);
        if (self.port) |p| self.allocator.free(p);
        if (self.pathname) |p| self.allocator.free(p);
        if (self.search) |s| self.allocator.free(s);
        if (self.hash) |h| self.allocator.free(h);
    }

    // URLをパース
    pub fn parse(self: *URL, url_str: []const u8) !void {
        // 既存のデータをクリア
        self.deinit();
        self.protocol = null;
        self.username = null;
        self.password = null;
        self.hostname = null;
        self.port = null;
        self.pathname = null;
        self.search = null;
        self.hash = null;

        // パース処理
        var remaining = url_str;

        // ハッシュ部分の抽出
        if (std.mem.indexOf(u8, remaining, "#")) |hash_pos| {
            self.hash = try self.allocator.dupe(u8, remaining[hash_pos..]);
            remaining = remaining[0..hash_pos];
        }

        // クエリ文字列の抽出
        if (std.mem.indexOf(u8, remaining, "?")) |search_pos| {
            self.search = try self.allocator.dupe(u8, remaining[search_pos..]);
            remaining = remaining[0..search_pos];
        }

        // プロトコルの抽出
        if (std.mem.indexOf(u8, remaining, "://")) |protocol_end| {
            self.protocol = try self.allocator.dupe(u8, remaining[0 .. protocol_end + 1]);
            remaining = remaining[protocol_end + 3 ..];
        }

        // パス部分の抽出
        if (std.mem.indexOf(u8, remaining, "/")) |path_pos| {
            self.pathname = try self.allocator.dupe(u8, remaining[path_pos..]);
            remaining = remaining[0..path_pos];
        } else {
            self.pathname = try self.allocator.dupe(u8, "/");
        }

        // 認証情報と残りのホスト情報を抽出
        if (std.mem.indexOf(u8, remaining, "@")) |auth_pos| {
            const auth_part = remaining[0..auth_pos];
            remaining = remaining[auth_pos + 1 ..];

            if (std.mem.indexOf(u8, auth_part, ":")) |pass_pos| {
                self.username = try self.allocator.dupe(u8, auth_part[0..pass_pos]);
                self.password = try self.allocator.dupe(u8, auth_part[pass_pos + 1 ..]);
            } else {
                self.username = try self.allocator.dupe(u8, auth_part);
            }
        }

        // ポート番号の抽出
        if (std.mem.indexOf(u8, remaining, ":")) |port_pos| {
            self.port = try self.allocator.dupe(u8, remaining[port_pos + 1 ..]);
            remaining = remaining[0..port_pos];
        }

        // 残りはホスト名
        if (remaining.len > 0) {
            self.hostname = try self.allocator.dupe(u8, remaining);
        }
    }

    // オリジンを取得 (protocol://hostname:port)
    pub fn getOrigin(self: *const URL, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        if (self.protocol) |protocol| {
            try buffer.appendSlice(protocol);
            try buffer.appendSlice("//");
        } else {
            return error.MissingProtocol;
        }

        if (self.hostname) |hostname| {
            try buffer.appendSlice(hostname);
        } else {
            return error.MissingHostname;
        }

        if (self.port) |port| {
            try buffer.append(':');
            try buffer.appendSlice(port);
        }

        return buffer.toOwnedSlice();
    }

    // ホスト全体を取得 (hostname:port)
    pub fn getHost(self: *const URL, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();

        if (self.hostname) |hostname| {
            try buffer.appendSlice(hostname);
        } else {
            return error.MissingHostname;
        }

        if (self.port) |port| {
            try buffer.append(':');
            try buffer.appendSlice(port);
        }

        return buffer.toOwnedSlice();
    }
};

pub const HTMLAnchorElement = struct {
    base: HTMLElement,
    url_parser: ?URL = null,
    rel_list: ?DOMTokenList = null,
    // Anchor 固有のプロパティは属性として ElementData に格納されるため、
    // ここにフィールドは不要。アクセサメソッドを提供する。

    pub fn create(allocator: std.mem.Allocator, html_element: HTMLElement) !*HTMLAnchorElement {
        const anchor = try allocator.create(HTMLAnchorElement);
        anchor.* = HTMLAnchorElement{
            .base = html_element,
            .url_parser = URL.init(allocator),
            .rel_list = null,
        };

        // href属性があればパース
        if (html_element.element.getAttribute("href")) |href_value| {
            try anchor.url_parser.?.parse(href_value);
        }

        return anchor;
    }

    pub fn destroy(self: *HTMLAnchorElement, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying HTMLAnchorElement specific data (if any) for <{s}>", .{self.base.element.data.tag_name});

        // URLパーサーリソース解放
        if (self.url_parser) |*url| {
            url.deinit();
        }

        // relList解放
        if (self.rel_list) |*rel_list| {
            rel_list.deinit();
        }

        // まずベース HTMLElement を破棄
        self.base.destroy(allocator);
        // 次に自身の構造体を破棄
        allocator.destroy(self);
    }

    // --- Anchor Element Properties ---

    pub fn href(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("href");
    }

    pub fn setHref(self: *HTMLAnchorElement, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.base.element.setAttribute("href", value);

        // URLをパース
        if (self.url_parser) |*url| {
            try url.parse(value);
        }

        _ = allocator;
    }

    pub fn target(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("target");
    }

    pub fn setTarget(self: *HTMLAnchorElement, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.base.element.setAttribute("target", value);
        _ = allocator;
    }

    pub fn download(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("download");
    }

    pub fn setDownload(self: *HTMLAnchorElement, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.base.element.setAttribute("download", value);
        _ = allocator;
    }

    pub fn rel(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("rel");
    }

    pub fn setRel(self: *HTMLAnchorElement, allocator: std.mem.Allocator, value: []const u8) !void {
        try self.base.element.setAttribute("rel", value);

        // relListを更新
        if (self.rel_list) |*rel_list| {
            rel_list.parseAttribute(value);
        }

        _ = allocator;
    }

    // hreflang
    pub fn hreflang(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("hreflang");
    }
    pub fn setHreflang(self: *HTMLAnchorElement, value: []const u8) !void {
        try self.base.element.setAttribute("hreflang", value);
    }

    // type (名前衝突のため getType/setType に変更)
    pub fn getType(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("type");
    }
    pub fn setType(self: *HTMLAnchorElement, value: []const u8) !void {
        try self.base.element.setAttribute("type", value);
    }

    // referrerPolicy
    // Note: attribute is referrerpolicy, property is referrerPolicy
    pub fn referrerPolicy(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("referrerpolicy");
    }
    pub fn setReferrerPolicy(self: *HTMLAnchorElement, value: []const u8) !void {
        // 値の検証 (有効な列挙値か確認)
        var lower_buf: [20]u8 = undefined;
        const lower_value = std.ascii.lowerString(lower_buf[0..std.math.min(value.len, lower_buf.len)], value);

        const valid_values = [_][]const u8{ "", "no-referrer", "no-referrer-when-downgrade", "same-origin", "origin", "strict-origin", "origin-when-cross-origin", "strict-origin-when-cross-origin", "unsafe-url" };

        var valid = false;
        for (valid_values) |valid_value| {
            if (std.mem.eql(u8, lower_value, valid_value)) {
                valid = true;
                break;
            }
        }

        if (!valid) {
            return error.InvalidReferrerPolicy;
        }

        try self.base.element.setAttribute("referrerpolicy", value);
    }

    // ping
    pub fn ping(self: *const HTMLAnchorElement) ?[]const u8 {
        return self.base.element.getAttribute("ping");
    }
    pub fn setPing(self: *HTMLAnchorElement, value: []const u8) !void {
        try self.base.element.setAttribute("ping", value);
    }

    // relList - DOMTokenList実装
    pub fn relList(self: *HTMLAnchorElement, allocator: std.mem.Allocator) !*DOMTokenList {
        if (self.rel_list == null) {
            self.rel_list = DOMTokenList.init(allocator, self.base.element, "rel");
        }

        return &self.rel_list.?;
    }

    // text property (Node.textContent を利用)
    pub fn text(self: *const HTMLAnchorElement, allocator: std.mem.Allocator) !?[]const u8 {
        return self.base.element.node_ptr.textContent(allocator);
    }

    // URLパース機能

    // オリジン (プロトコル + ホスト + ポート)
    pub fn origin(self: *HTMLAnchorElement, allocator: std.mem.Allocator) ![]const u8 {
        if (self.url_parser) |*url| {
            return url.getOrigin(allocator);
        }
        return error.MissingUrlParser;
    }

    // プロトコル (例: "https:")
    pub fn protocol(self: *const HTMLAnchorElement) ?[]const u8 {
        if (self.url_parser) |url| {
            return url.protocol;
        }
        return null;
    }

    // ユーザー名
    pub fn username(self: *const HTMLAnchorElement) ?[]const u8 {
        if (self.url_parser) |url| {
            return url.username;
        }
        return null;
    }

    // パスワード
    pub fn password(self: *const HTMLAnchorElement) ?[]const u8 {
        if (self.url_parser) |url| {
            return url.password;
        }
        return null;
    }

    // ホスト (hostname:port)
    pub fn host(self: *HTMLAnchorElement, allocator: std.mem.Allocator) ![]const u8 {
        if (self.url_parser) |*url| {
            return url.getHost(allocator);
        }
        return error.MissingUrlParser;
    }

    // ホスト名 (ポートなし)
    pub fn hostname(self: *const HTMLAnchorElement) ?[]const u8 {
        if (self.url_parser) |url| {
            return url.hostname;
        }
        return null;
    }

    // ポート番号
    pub fn port(self: *const HTMLAnchorElement) ?[]const u8 {
        if (self.url_parser) |url| {
            return url.port;
        }
        return null;
    }

    // パス
    pub fn pathname(self: *const HTMLAnchorElement) ?[]const u8 {
        if (self.url_parser) |url| {
            return url.pathname;
        }
        return null;
    }

    // 検索パラメータ (?query=value)
    pub fn search(self: *const HTMLAnchorElement) ?[]const u8 {
        if (self.url_parser) |url| {
            return url.search;
        }
        return null;
    }

    // ハッシュフラグメント (#fragment)
    pub fn hash(self: *const HTMLAnchorElement) ?[]const u8 {
        if (self.url_parser) |url| {
            return url.hash;
        }
        return null;
    }
};

// HTMLAnchorElement のテスト
test "HTMLAnchorElement properties" {
    const allocator = std.testing.allocator;
    var doc = try std.testing.allocator.create(Document);
    doc.* = Document.create(allocator, "text/html") catch @panic("Failed to create doc");
    defer doc.destroy();

    var node = try doc.createElement("a");
    defer node.destroyRecursive(allocator);
    const element: *Element = @ptrCast(@alignCast(node.specific_data.?));
    const html_element = element.html_data.?;

    // AnchorElement を作成 (本来は Element.create 内で)
    var anchor = try HTMLAnchorElement.create(allocator, html_element.*);
    defer anchor.destroy(allocator);

    // プロパティを設定・取得
    try anchor.setHref(allocator, "https://example.com/path");
    try std.testing.expectEqualStrings("https://example.com/path", anchor.href().?);

    try anchor.setTarget(allocator, "_blank");
    try std.testing.expectEqualStrings("_blank", anchor.target().?);

    try anchor.setDownload(allocator, "filename.zip");
    try std.testing.expectEqualStrings("filename.zip", anchor.download().?);

    try anchor.setRel(allocator, "noopener noreferrer");
    try std.testing.expectEqualStrings("noopener noreferrer", anchor.rel().?);

    // textContent を設定して text プロパティを確認
    const text_node = try doc.createTextNode("Click Me");
    try node.appendChild(text_node);
    const text_content = try anchor.text(allocator);
    defer if (text_content) |t| allocator.free(t);
    try std.testing.expectEqualStrings("Click Me", text_content.?);
}
