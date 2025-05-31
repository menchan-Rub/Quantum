// src/zig/quantum_net/url.zig
// URL 解析と操作のためのユーティリティ

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

/// URL構造体
pub const Uri = struct {
    scheme: ?[]const u8 = null, // http, https, file など
    username: ?[]const u8 = null, // ユーザー名
    password: ?[]const u8 = null, // パスワード
    host: ?[]const u8 = null, // ホスト名
    port: ?u16 = null, // ポート番号
    path: []const u8, // パス
    query: ?[]const u8 = null, // クエリパラメータ
    fragment: ?[]const u8 = null, // フラグメント
    allocator: Allocator, // メモリアロケータ

    /// URLを解析して構造体を作成
    pub fn parse(allocator: Allocator, url_str: []const u8) !Uri {
        var uri = Uri{
            .path = "/",
            .allocator = allocator,
        };

        // スキーム部分を解析
        const scheme_end = mem.indexOf(u8, url_str, "://");
        if (scheme_end) |end| {
            uri.scheme = try allocator.dupe(u8, url_str[0..end]);

            // スキーム以降の部分
            const rest = url_str[end + 3 ..];

            // 認証情報（username:password@）部分を解析
            const auth_end = mem.indexOf(u8, rest, "@");
            if (auth_end) |auth_pos| {
                const auth_part = rest[0..auth_pos];
                const colon_pos = mem.indexOf(u8, auth_part, ":");

                if (colon_pos) |cp| {
                    uri.username = try allocator.dupe(u8, auth_part[0..cp]);
                    uri.password = try allocator.dupe(u8, auth_part[cp + 1 ..]);
                } else {
                    uri.username = try allocator.dupe(u8, auth_part);
                }

                // 残りの部分から続行
                const host_part = rest[auth_pos + 1 ..];
                try parseHostPathQueryFragment(allocator, &uri, host_part);
            } else {
                // ユーザー認証情報がない場合
                try parseHostPathQueryFragment(allocator, &uri, rest);
            }
        } else {
            // スキームがない場合 (相対URL)
            try parseHostPathQueryFragment(allocator, &uri, url_str);
        }

        return uri;
    }

    /// ホスト、パス、クエリ、フラグメント部分を解析
    fn parseHostPathQueryFragment(allocator: Allocator, uri: *Uri, str: []const u8) !void {
        // パス開始位置を検索
        const path_start = mem.indexOf(u8, str, "/");

        if (path_start) |ps| {
            // ホスト部分
            const host_part = str[0..ps];
            try parseHostPort(allocator, uri, host_part);

            // パス以降の部分
            const path_part = str[ps..];

            // フラグメント部分を解析
            const fragment_start = mem.indexOf(u8, path_part, "#");
            if (fragment_start) |fs| {
                // フラグメント
                uri.fragment = try allocator.dupe(u8, path_part[fs + 1 ..]);

                // クエリ部分を解析
                const query_part = path_part[0..fs];
                const query_start = mem.indexOf(u8, query_part, "?");

                if (query_start) |qs| {
                    // クエリ
                    uri.query = try allocator.dupe(u8, query_part[qs + 1 ..]);
                    // パス
                    uri.path = try allocator.dupe(u8, query_part[0..qs]);
                } else {
                    // クエリなし
                    uri.path = try allocator.dupe(u8, query_part);
                }
            } else {
                // フラグメントなし

                // クエリ部分を解析
                const query_start = mem.indexOf(u8, path_part, "?");

                if (query_start) |qs| {
                    uri.query = try allocator.dupe(u8, path_part[qs + 1 ..]);
                    uri.path = try allocator.dupe(u8, path_part[0..qs]);
                } else {
                    uri.path = try allocator.dupe(u8, path_part);
                }
            }
        } else {
            // パスなし、ホストのみ
            try parseHostPort(allocator, uri, str);
            uri.path = try allocator.dupe(u8, "/");
        }
    }

    /// ホストとポート部分を解析
    fn parseHostPort(allocator: Allocator, uri: *Uri, str: []const u8) !void {
        const colon = mem.indexOf(u8, str, ":");

        if (colon) |cp| {
            // ホスト
            uri.host = try allocator.dupe(u8, str[0..cp]);

            // ポート
            const port_str = str[cp + 1 ..];
            uri.port = try std.fmt.parseInt(u16, port_str, 10);
        } else {
            // ポートなし
            uri.host = try allocator.dupe(u8, str);

            // デフォルトポートを設定
            if (uri.scheme) |scheme| {
                if (mem.eql(u8, scheme, "http")) {
                    uri.port = 80;
                } else if (mem.eql(u8, scheme, "https")) {
                    uri.port = 443;
                }
            }
        }
    }

    /// URLの各部分を解放
    pub fn deinit(self: *Uri) void {
        if (self.scheme) |s| self.allocator.free(s);
        if (self.username) |u| self.allocator.free(u);
        if (self.password) |p| self.allocator.free(p);
        if (self.host) |h| self.allocator.free(h);
        if (self.path.len > 0) self.allocator.free(self.path);
        if (self.query) |q| self.allocator.free(q);
        if (self.fragment) |f| self.allocator.free(f);
    }

    /// URLを文字列に変換
    pub fn toString(self: Uri) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        // スキーム
        if (self.scheme) |scheme| {
            try buf.appendSlice(scheme);
            try buf.appendSlice("://");
        }

        // 認証情報
        if (self.username != null) {
            try buf.appendSlice(self.username.?);

            if (self.password) |pass| {
                try buf.append(':');
                try buf.appendSlice(pass);
            }

            try buf.append('@');
        }

        // ホスト
        if (self.host) |host| {
            try buf.appendSlice(host);
        }

        // ポート (デフォルトポートでない場合のみ)
        if (self.port) |port| {
            var is_default = false;

            if (self.scheme) |scheme| {
                is_default = (mem.eql(u8, scheme, "http") and port == 80) or
                    (mem.eql(u8, scheme, "https") and port == 443);
            }

            if (!is_default) {
                try buf.append(':');
                try buf.appendSlice(try std.fmt.allocPrint(self.allocator, "{d}", .{port}));
            }
        }

        // パス
        if (self.path.len > 0) {
            if (self.host != null and !mem.startsWith(u8, self.path, "/")) {
                try buf.append('/');
            }
            try buf.appendSlice(self.path);
        } else if (self.host != null) {
            try buf.append('/');
        }

        // クエリ
        if (self.query) |query| {
            try buf.append('?');
            try buf.appendSlice(query);
        }

        // フラグメント
        if (self.fragment) |fragment| {
            try buf.append('#');
            try buf.appendSlice(fragment);
        }

        return buf.toOwnedSlice();
    }

    /// URLを解析してクエリパラメータを取得
    pub fn queryParams(self: Uri) !std.StringHashMap([]const u8) {
        var params = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var it = params.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            params.deinit();
        }

        if (self.query == null or self.query.?.len == 0) {
            return params;
        }

        var pairs = mem.split(u8, self.query.?, "&");
        while (pairs.next()) |pair| {
            const eq_pos = mem.indexOf(u8, pair, "=") orelse continue;

            const key = pair[0..eq_pos];
            const value = pair[eq_pos + 1 ..];

            const decoded_key = try urlDecode(self.allocator, key);
            errdefer self.allocator.free(decoded_key);

            const decoded_val = try urlDecode(self.allocator, value);
            errdefer self.allocator.free(decoded_val);

            // 既存のキーがあれば解放
            if (params.get(decoded_key)) |old_val| {
                self.allocator.free(old_val);
            }

            try params.put(decoded_key, decoded_val);
        }

        return params;
    }

    /// 相対URLを現在のURLに対して解決
    pub fn resolve(self: Uri, rel_url: []const u8) !Uri {
        // 絶対URLの場合はそのまま解析
        if (mem.indexOf(u8, rel_url, "://") != null or mem.startsWith(u8, rel_url, "//")) {
            return parse(self.allocator, rel_url);
        }

        // 新しいURLを現在のURLをベースに作成
        var result = Uri{
            .scheme = if (self.scheme) |s| try self.allocator.dupe(u8, s) else null,
            .username = if (self.username) |u| try self.allocator.dupe(u8, u) else null,
            .password = if (self.password) |p| try self.allocator.dupe(u8, p) else null,
            .host = if (self.host) |h| try self.allocator.dupe(u8, h) else null,
            .port = self.port,
            .path = try self.allocator.dupe(u8, self.path),
            .query = null,
            .fragment = null,
            .allocator = self.allocator,
        };
        errdefer result.deinit();

        // 相対パスが/で始まる場合は絶対パス
        if (mem.startsWith(u8, rel_url, "/")) {
            // パスを置き換え
            self.allocator.free(result.path);
            result.path = try self.allocator.dupe(u8, rel_url);
        } else if (mem.startsWith(u8, rel_url, "?")) {
            // クエリのみの場合
            result.query = try self.allocator.dupe(u8, rel_url[1..]);
        } else if (mem.startsWith(u8, rel_url, "#")) {
            // フラグメントのみの場合
            result.fragment = try self.allocator.dupe(u8, rel_url[1..]);
        } else {
            // 相対パス
            // 現在のパスの最後のスラッシュまでを取得
            const last_slash = mem.lastIndexOf(u8, self.path, "/");
            if (last_slash) |pos| {
                const base_path = self.path[0 .. pos + 1]; // スラッシュも含める

                // 基本パスに相対パスを追加
                var buffer = try std.ArrayList(u8).initCapacity(self.allocator, base_path.len + rel_url.len);
                try buffer.appendSlice(base_path);
                try buffer.appendSlice(rel_url);

                // 古いパスを解放して新しいパスを設定
                self.allocator.free(result.path);
                result.path = try buffer.toOwnedSlice();
            } else {
                // 現在のパスにスラッシュがない場合は、相対パスを直接使用
                self.allocator.free(result.path);
                result.path = try self.allocator.dupe(u8, rel_url);
            }
        }

        // フラグメントとクエリを解析
        const fragment_start = mem.indexOf(u8, result.path, "#");
        if (fragment_start) |fs| {
            result.fragment = try self.allocator.dupe(u8, result.path[fs + 1 ..]);

            const query_start = mem.indexOf(u8, result.path[0..fs], "?");
            if (query_start) |qs| {
                result.query = try self.allocator.dupe(u8, result.path[qs + 1 .. fs]);

                // パスを調整（クエリとフラグメントを除去）
                const new_path = try self.allocator.dupe(u8, result.path[0..qs]);
                self.allocator.free(result.path);
                result.path = new_path;
            } else {
                // フラグメントのみを除去
                const new_path = try self.allocator.dupe(u8, result.path[0..fs]);
                self.allocator.free(result.path);
                result.path = new_path;
            }
        } else {
            // フラグメントなし、クエリのみ検索
            const query_start = mem.indexOf(u8, result.path, "?");
            if (query_start) |qs| {
                result.query = try self.allocator.dupe(u8, result.path[qs + 1 ..]);

                // パスを調整（クエリを除去）
                const new_path = try self.allocator.dupe(u8, result.path[0..qs]);
                self.allocator.free(result.path);
                result.path = new_path;
            }
        }

        // パスの正規化（例: a/b/../c → a/c）
        result.path = try normalizePath(self.allocator, result.path);

        return result;
    }

    /// URLエンコード文字列を生成
    pub fn encode(allocator: Allocator, str: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();

        for (str) |c| {
            if (isUrlSafe(c)) {
                try result.append(c);
            } else {
                // %XX形式でエンコード
                try result.append('%');
                try result.append(hexChar(c >> 4));
                try result.append(hexChar(c & 0x0F));
            }
        }

        return result.toOwnedSlice();
    }
};

/// URLエンコーディングのための安全な文字かをチェック
fn isUrlSafe(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

/// 16進数文字に変換
fn hexChar(value: u8) u8 {
    return switch (value) {
        0...9 => '0' + value,
        10...15 => 'A' + (value - 10),
        else => unreachable,
    };
}

/// URLエンコードされた文字列をデコード
pub fn urlDecode(allocator: Allocator, str: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < str.len) {
        switch (str[i]) {
            '%' => {
                if (i + 2 < str.len) {
                    const hex = str[i + 1 .. i + 3];
                    const value = try std.fmt.parseInt(u8, hex, 16);
                    try result.append(value);
                    i += 3;
                } else {
                    return error.InvalidEncoding;
                }
            },
            '+' => {
                try result.append(' ');
                i += 1;
            },
            else => {
                try result.append(str[i]);
                i += 1;
            },
        }
    }

    return result.toOwnedSlice();
}

/// パスを正規化（"." や ".." を解決）
fn normalizePath(allocator: Allocator, path: []const u8) ![]const u8 {
    // パスが空の場合は "/"
    if (path.len == 0) {
        return allocator.dupe(u8, "/");
    }

    var segments = std.ArrayList([]const u8).init(allocator);
    defer {
        // segments自体は解放するが、中の文字列は解放しない
        segments.deinit();
    }

    var parts = mem.split(u8, path, "/");

    var is_absolute = path[0] == '/';

    while (parts.next()) |part| {
        if (part.len == 0) {
            // 空のセグメント (連続するスラッシュなど) は無視
            continue;
        } else if (mem.eql(u8, part, ".")) {
            // 現在のディレクトリは無視
            continue;
        } else if (mem.eql(u8, part, "..")) {
            // 親ディレクトリ
            if (segments.items.len > 0) {
                _ = segments.pop();
            }
        } else {
            try segments.append(part);
        }
    }

    // 結果を構築
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    if (is_absolute) {
        try result.append('/');
    }

    for (segments.items, 0..) |segment, i| {
        if (i > 0) {
            try result.append('/');
        }
        try result.appendSlice(segment);
    }

    // 最終的なパスが空で、元のパスが絶対パスだった場合は "/"
    if (result.items.len == 0) {
        if (is_absolute) {
            try result.append('/');
        } else {
            try result.appendSlice(".");
        }
    }

    return result.toOwnedSlice();
}

test "Uri parse basic" {
    const allocator = std.testing.allocator;

    const url_str = "https://user:pass@example.com:8080/path/to/resource?query=value&foo=bar#fragment";
    var uri = try Uri.parse(allocator, url_str);
    defer uri.deinit();

    try std.testing.expectEqualStrings("https", uri.scheme.?);
    try std.testing.expectEqualStrings("user", uri.username.?);
    try std.testing.expectEqualStrings("pass", uri.password.?);
    try std.testing.expectEqualStrings("example.com", uri.host.?);
    try std.testing.expectEqual(@as(u16, 8080), uri.port.?);
    try std.testing.expectEqualStrings("/path/to/resource", uri.path);
    try std.testing.expectEqualStrings("query=value&foo=bar", uri.query.?);
    try std.testing.expectEqualStrings("fragment", uri.fragment.?);
}

test "Uri parse without components" {
    const allocator = std.testing.allocator;

    // スキームとホストだけ
    {
        const url_str = "http://example.com";
        var uri = try Uri.parse(allocator, url_str);
        defer uri.deinit();

        try std.testing.expectEqualStrings("http", uri.scheme.?);
        try std.testing.expectEqualStrings("example.com", uri.host.?);
        try std.testing.expectEqual(@as(u16, 80), uri.port.?);
        try std.testing.expectEqualStrings("/", uri.path);
        try std.testing.expect(uri.query == null);
        try std.testing.expect(uri.fragment == null);
    }

    // パスのみ
    {
        const url_str = "/foo/bar";
        var uri = try Uri.parse(allocator, url_str);
        defer uri.deinit();

        try std.testing.expect(uri.scheme == null);
        try std.testing.expect(uri.host == null);
        try std.testing.expect(uri.port == null);
        try std.testing.expectEqualStrings("/foo/bar", uri.path);
    }
}

test "Uri toString" {
    const allocator = std.testing.allocator;

    // フル URL
    {
        var uri = Uri{
            .scheme = try allocator.dupe(u8, "https"),
            .username = try allocator.dupe(u8, "user"),
            .password = try allocator.dupe(u8, "pass"),
            .host = try allocator.dupe(u8, "example.com"),
            .port = 8443,
            .path = try allocator.dupe(u8, "/path"),
            .query = try allocator.dupe(u8, "q=value"),
            .fragment = try allocator.dupe(u8, "section"),
            .allocator = allocator,
        };
        defer uri.deinit();

        const result = try uri.toString();
        defer allocator.free(result);

        try std.testing.expectEqualStrings("https://user:pass@example.com:8443/path?q=value#section", result);
    }

    // デフォルトポート
    {
        var uri = Uri{
            .scheme = try allocator.dupe(u8, "https"),
            .host = try allocator.dupe(u8, "example.com"),
            .port = 443, // HTTPSのデフォルトポート
            .path = try allocator.dupe(u8, "/"),
            .allocator = allocator,
        };
        defer uri.deinit();

        const result = try uri.toString();
        defer allocator.free(result);

        // デフォルトポートは省略される
        try std.testing.expectEqualStrings("https://example.com/", result);
    }
}

test "Uri queryParams" {
    const allocator = std.testing.allocator;

    var uri = try Uri.parse(allocator, "https://example.com/search?q=zig&lang=en&page=1");
    defer uri.deinit();

    var params = try uri.queryParams();
    defer {
        var it = params.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        params.deinit();
    }

    try std.testing.expectEqualStrings("zig", params.get("q").?);
    try std.testing.expectEqualStrings("en", params.get("lang").?);
    try std.testing.expectEqualStrings("1", params.get("page").?);
}

test "Uri resolve" {
    const allocator = std.testing.allocator;

    var base = try Uri.parse(allocator, "https://example.com/foo/bar");
    defer base.deinit();

    // 絶対URL
    {
        var resolved = try base.resolve("https://other.com/path");
        defer resolved.deinit();

        try std.testing.expectEqualStrings("https", resolved.scheme.?);
        try std.testing.expectEqualStrings("other.com", resolved.host.?);
        try std.testing.expectEqualStrings("/path", resolved.path);
    }

    // 絶対パス
    {
        var resolved = try base.resolve("/baz");
        defer resolved.deinit();

        try std.testing.expectEqualStrings("https", resolved.scheme.?);
        try std.testing.expectEqualStrings("example.com", resolved.host.?);
        try std.testing.expectEqualStrings("/baz", resolved.path);
    }

    // 相対パス
    {
        var resolved = try base.resolve("baz");
        defer resolved.deinit();

        try std.testing.expectEqualStrings("https", resolved.scheme.?);
        try std.testing.expectEqualStrings("example.com", resolved.host.?);
        try std.testing.expectEqualStrings("/foo/baz", resolved.path);
    }

    // 親パス参照 ".."
    {
        var resolved = try base.resolve("../qux");
        defer resolved.deinit();

        try std.testing.expectEqualStrings("/qux", resolved.path);
    }
}
