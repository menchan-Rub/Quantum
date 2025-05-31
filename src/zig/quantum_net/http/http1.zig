// src/zig/quantum_net/http/http1.zig
// HTTP/1.1 プロトコル実装

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Headers = @import("./headers.zig").Headers;
const Method = @import("./methods.zig").Method;
const Status = @import("./status.zig").Status;
const Version = @import("./versions.zig").Version;
const Uri = @import("../url.zig").Uri;

/// HTTPリクエストの解析と生成を行う構造体
pub const Http1Request = struct {
    method: Method,
    uri: Uri,
    version: Version,
    headers: Headers,
    body: ?[]const u8,
    allocator: Allocator,

    /// 新しいHTTPリクエストを作成
    pub fn init(
        allocator: Allocator,
        method: Method,
        uri: Uri,
        version: Version,
        headers: Headers,
        body: ?[]const u8,
    ) Http1Request {
        return Http1Request{
            .method = method,
            .uri = uri,
            .version = version,
            .headers = headers,
            .body = body,
            .allocator = allocator,
        };
    }

    /// リクエストを解放
    pub fn deinit(self: *Http1Request) void {
        self.headers.deinit();
        if (self.body) |body| {
            self.allocator.free(body);
        }
        // URIはここで解放しない（外部で管理）
    }

    /// 生の文字列からHTTPリクエストを解析
    pub fn parse(allocator: Allocator, raw_request: []const u8) !Http1Request {
        var lines = mem.split(u8, raw_request, "\r\n");

        // リクエストライン解析
        const request_line = lines.next() orelse return error.InvalidRequest;
        var req_parts = mem.split(u8, request_line, " ");

        // メソッド解析
        const method_str = req_parts.next() orelse return error.InvalidRequest;
        const method = try Method.fromString(method_str);

        // URIパース
        const uri_str = req_parts.next() orelse return error.InvalidRequest;
        var uri = try Uri.parse(allocator, uri_str);
        errdefer uri.deinit();

        // HTTPバージョン解析
        const version_str = req_parts.next() orelse return error.InvalidRequest;
        const version = try Version.fromString(version_str);

        // ヘッダー解析
        var headers = Headers.init(allocator);
        errdefer headers.deinit();

        while (lines.next()) |line| {
            if (line.len == 0) break; // ヘッダー終了

            const colon_pos = mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
            const name = line[0..colon_pos];
            var value = line[colon_pos + 1 ..];

            // 先頭の空白を除去
            while (value.len > 0 and value[0] == ' ') {
                value = value[1..];
            }

            try headers.append(name, value);
        }

        // ボディ解析
        var body: ?[]const u8 = null;
        const content_length = headers.get("Content-Length");

        if (content_length) |cl| {
            const len = try std.fmt.parseInt(usize, cl, 10);
            if (len > 0) {
                const remaining = lines.rest();
                if (remaining.len >= len) {
                    body = try allocator.dupe(u8, remaining[0..len]);
                } else {
                    return error.IncompleteBody;
                }
            }
        }

        return Http1Request.init(
            allocator,
            method,
            uri,
            version,
            headers,
            body,
        );
    }

    /// HTTPリクエストを文字列に変換
    pub fn format(self: Http1Request, writer: anytype) !void {
        // リクエストライン
        try writer.print("{s} {s} {s}\r\n", .{
            self.method.toString(),
            self.uri.path,
            self.version.toString(),
        });

        // ヘッダー
        try self.headers.format(writer);

        // ボディ区切り
        try writer.writeAll("\r\n");

        // ボディがあれば書き込み
        if (self.body) |body| {
            try writer.writeAll(body);
        }
    }

    /// HTTPリクエストを文字列化
    pub fn toString(self: Http1Request) ![]const u8 {
        var list = std.ArrayList(u8).init(self.allocator);
        errdefer list.deinit();

        try self.format(list.writer());
        return list.toOwnedSlice();
    }
};

/// HTTPレスポンスの解析と生成を行う構造体
pub const Http1Response = struct {
    version: Version,
    status: Status,
    headers: Headers,
    body: ?[]const u8,
    allocator: Allocator,

    /// 新しいHTTPレスポンスを作成
    pub fn init(
        allocator: Allocator,
        version: Version,
        status: Status,
        headers: Headers,
        body: ?[]const u8,
    ) Http1Response {
        return Http1Response{
            .version = version,
            .status = status,
            .headers = headers,
            .body = body,
            .allocator = allocator,
        };
    }

    /// レスポンスを解放
    pub fn deinit(self: *Http1Response) void {
        self.headers.deinit();
        if (self.body) |body| {
            self.allocator.free(body);
        }
    }

    /// 生の文字列からHTTPレスポンスを解析
    pub fn parse(allocator: Allocator, raw_response: []const u8) !Http1Response {
        var lines = mem.split(u8, raw_response, "\r\n");

        // ステータスライン解析
        const status_line = lines.next() orelse return error.InvalidResponse;
        var status_parts = mem.split(u8, status_line, " ");

        // HTTPバージョン解析
        const version_str = status_parts.next() orelse return error.InvalidResponse;
        const version = try Version.fromString(version_str);

        // ステータスコード解析
        const status_code_str = status_parts.next() orelse return error.InvalidResponse;
        const status_code = try std.fmt.parseInt(u16, status_code_str, 10);
        const status = Status.fromCode(status_code) catch return error.InvalidStatusCode;

        // ヘッダー解析
        var headers = Headers.init(allocator);
        errdefer headers.deinit();

        while (lines.next()) |line| {
            if (line.len == 0) break; // ヘッダー終了

            const colon_pos = mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
            const name = line[0..colon_pos];
            var value = line[colon_pos + 1 ..];

            // 先頭の空白を除去
            while (value.len > 0 and value[0] == ' ') {
                value = value[1..];
            }

            try headers.append(name, value);
        }

        // ボディ解析
        var body: ?[]const u8 = null;
        const content_length = headers.get("Content-Length");

        if (content_length) |cl| {
            const len = try std.fmt.parseInt(usize, cl, 10);
            if (len > 0) {
                const remaining = lines.rest();
                if (remaining.len >= len) {
                    body = try allocator.dupe(u8, remaining[0..len]);
                } else {
                    return error.IncompleteBody;
                }
            }
        } else {
            // Transfer-Encoding: chunked の処理はここでは省略
            const remaining = lines.rest();
            if (remaining.len > 0) {
                body = try allocator.dupe(u8, remaining);
            }
        }

        return Http1Response.init(
            allocator,
            version,
            status,
            headers,
            body,
        );
    }

    /// HTTPレスポンスを文字列に変換
    pub fn format(self: Http1Response, writer: anytype) !void {
        // ステータスライン
        try writer.print("{s} {} {s}\r\n", .{
            self.version.toString(),
            self.status.code,
            self.status.message,
        });

        // ボディサイズの自動設定
        var headers_with_length = self.headers;
        if (self.body != null and !headers_with_length.contains("Content-Length")) {
            try headers_with_length.append("Content-Length", try std.fmt.allocPrint(self.allocator, "{d}", .{self.body.?.len}));
        }

        // ヘッダー
        try headers_with_length.format(writer);

        // ボディ区切り
        try writer.writeAll("\r\n");

        // ボディがあれば書き込み
        if (self.body) |body| {
            try writer.writeAll(body);
        }
    }

    /// HTTPレスポンスを文字列化
    pub fn toString(self: Http1Response) ![]const u8 {
        var list = std.ArrayList(u8).init(self.allocator);
        errdefer list.deinit();

        try self.format(list.writer());
        return list.toOwnedSlice();
    }

    /// 簡易レスポンス作成
    pub fn simple(
        allocator: Allocator,
        status: Status,
        body: []const u8,
    ) !Http1Response {
        var headers = Headers.init(allocator);
        errdefer headers.deinit();

        try headers.append("Content-Type", "text/plain");
        try headers.append("Content-Length", try std.fmt.allocPrint(allocator, "{d}", .{body.len}));

        return Http1Response.init(
            allocator,
            Version.Http11,
            status,
            headers,
            try allocator.dupe(u8, body),
        );
    }
};

// HTTP/1.1のパーサーとジェネレーターユーティリティ
pub const Http1Parser = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8),
    state: ParserState,

    const ParserState = enum {
        RequestLine,
        Headers,
        Body,
        Complete,
    };

    /// 新しいHTTPパーサーを初期化
    pub fn init(allocator: Allocator) Http1Parser {
        return Http1Parser{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
            .state = .RequestLine,
        };
    }

    /// パーサーを解放
    pub fn deinit(self: *Http1Parser) void {
        self.buffer.deinit();
    }

    /// データを追加し、パース処理を進める
    pub fn feed(self: *Http1Parser, data: []const u8) !void {
        try self.buffer.appendSlice(data);
    }

    /// 現在のデータでリクエストが完成しているか
    pub fn isComplete(self: *Http1Parser) bool {
        if (self.state == .Complete) return true;

        const buf = self.buffer.items;
        const header_end = mem.indexOf(u8, buf, "\r\n\r\n");

        if (header_end == null) return false;

        const headers_part = buf[0 .. header_end.? + 4];
        var lines = mem.split(u8, headers_part, "\r\n");
        _ = lines.next(); // リクエストライン飛ばす

        var content_length: ?usize = null;

        while (lines.next()) |line| {
            if (line.len == 0) break;

            if (mem.startsWith(u8, line, "Content-Length:")) {
                const val_start = mem.indexOfScalar(u8, line, ':').? + 1;
                var val = line[val_start..];
                while (val.len > 0 and val[0] == ' ') val = val[1..];

                content_length = std.fmt.parseInt(usize, val, 10) catch null;
            }
        }

        if (content_length) |len| {
            const body_start = header_end.? + 4;
            const body_len = buf.len - body_start;

            if (body_len >= len) {
                self.state = .Complete;
                return true;
            } else {
                return false;
            }
        } else {
            // ボディなし
            self.state = .Complete;
            return true;
        }
    }

    /// 完成したリクエストを取得
    pub fn getRequest(self: *Http1Parser) !Http1Request {
        if (!self.isComplete()) {
            return error.IncompleteRequest;
        }

        return Http1Request.parse(self.allocator, self.buffer.items);
    }

    /// リセット
    pub fn reset(self: *Http1Parser) void {
        self.buffer.clearRetainingCapacity();
        self.state = .RequestLine;
    }
};

test "Http1Request basic parsing" {
    const allocator = std.testing.allocator;

    const raw_request =
        \\GET /index.html HTTP/1.1
        \\Host: example.com
        \\User-Agent: Test
        \\Content-Length: 13
        \\
        \\Hello, World!
    ;

    const formatted_request = try std.mem.replaceOwned(u8, allocator, raw_request, "\n", "\r\n");
    defer allocator.free(formatted_request);

    var request = try Http1Request.parse(allocator, formatted_request);
    defer request.deinit();

    try std.testing.expectEqual(Method.Get, request.method);
    try std.testing.expectEqualStrings("/index.html", request.uri.path);
    try std.testing.expectEqual(Version.Http11, request.version);
    try std.testing.expectEqualStrings("example.com", request.headers.get("Host").?);
    try std.testing.expectEqualStrings("Test", request.headers.get("User-Agent").?);

    if (request.body) |body| {
        try std.testing.expectEqualStrings("Hello, World!", body);
    } else {
        return error.MissingBody;
    }
}

test "Http1Response basic creation" {
    const allocator = std.testing.allocator;

    var headers = Headers.init(allocator);
    defer headers.deinit();

    try headers.append("Content-Type", "text/html");
    try headers.append("Server", "Quantum");

    const body = "<html><body>Hello!</body></html>";

    var response = Http1Response.init(
        allocator,
        Version.Http11,
        Status.ok,
        headers,
        try allocator.dupe(u8, body),
    );
    defer response.deinit();

    // レスポンス文字列化
    const response_str = try response.toString();
    defer allocator.free(response_str);

    // 期待値との比較
    const expected_start = "HTTP/1.1 200 OK\r\n";
    try std.testing.expect(mem.startsWith(u8, response_str, expected_start));

    // ヘッダー含まれるか
    try std.testing.expect(mem.indexOf(u8, response_str, "Content-Type: text/html") != null);
    try std.testing.expect(mem.indexOf(u8, response_str, "Server: Quantum") != null);

    // ボディ含まれるか
    try std.testing.expect(mem.indexOf(u8, response_str, body) != null);
}

test "Http1Parser streaming" {
    const allocator = std.testing.allocator;

    var parser = Http1Parser.init(allocator);
    defer parser.deinit();

    // 分割されたリクエスト
    const part1 = "GET /index.html HTTP/1.1\r\nHost: example.com\r\n";
    const part2 = "User-Agent: Test\r\nContent-Length: 5\r\n\r\nHello";

    // 最初の部分を送信
    try parser.feed(part1);
    try std.testing.expect(!parser.isComplete());

    // 残りを送信
    try parser.feed(part2);
    try std.testing.expect(parser.isComplete());

    // リクエスト取得
    var request = try parser.getRequest();
    defer request.deinit();

    try std.testing.expectEqual(Method.Get, request.method);
    try std.testing.expectEqualStrings("/index.html", request.uri.path);
    try std.testing.expectEqualStrings("example.com", request.headers.get("Host").?);

    if (request.body) |body| {
        try std.testing.expectEqualStrings("Hello", body);
    } else {
        return error.MissingBody;
    }
}
