// src/zig/quantum_net/http/headers.zig
// HTTP ヘッダー管理

const std = @import("std");
const Allocator = std.mem.Allocator;

/// HTTPヘッダーのキーと値のペア
pub const HeaderField = struct {
    name: []const u8,
    value: []const u8,

    /// ヘッダーフィールドの解放
    pub fn deinit(self: *HeaderField, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

/// HTTPヘッダーの集合を管理する構造体
pub const Headers = struct {
    fields: std.ArrayList(HeaderField),
    allocator: Allocator,

    /// ヘッダーコレクションの初期化
    pub fn init(allocator: Allocator) Headers {
        return Headers{
            .fields = std.ArrayList(HeaderField).init(allocator),
            .allocator = allocator,
        };
    }

    /// ヘッダーコレクションの解放
    pub fn deinit(self: *Headers) void {
        for (self.fields.items) |*field| {
            field.deinit(self.allocator);
        }
        self.fields.deinit();
    }

    /// 新しいヘッダーを追加
    pub fn append(self: *Headers, name: []const u8, value: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        const field = HeaderField{
            .name = name_copy,
            .value = value_copy,
        };

        try self.fields.append(field);
    }

    /// 指定したヘッダー名のヘッダーを全て削除
    pub fn remove(self: *Headers, name: []const u8) void {
        var i: usize = 0;
        while (i < self.fields.items.len) {
            const field = self.fields.items[i];
            if (std.ascii.eqlIgnoreCase(field.name, name)) {
                // このフィールドを削除
                const removed = self.fields.orderedRemove(i);
                removed.deinit(self.allocator);
            } else {
                i += 1;
            }
        }
    }

    /// 指定した名前のヘッダー値を取得（複数ある場合は最初のもの）
    pub fn get(self: Headers, name: []const u8) ?[]const u8 {
        for (self.fields.items) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, name)) {
                return field.value;
            }
        }
        return null;
    }

    /// 指定した名前のヘッダーが存在するか
    pub fn contains(self: Headers, name: []const u8) bool {
        return self.get(name) != null;
    }

    /// 指定した名前のヘッダー値を全て取得
    pub fn getAll(self: Headers, name: []const u8, allocator: Allocator) ![][]const u8 {
        var values = std.ArrayList([]const u8).init(allocator);
        errdefer values.deinit();

        for (self.fields.items) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, name)) {
                try values.append(field.value);
            }
        }

        return values.toOwnedSlice();
    }

    /// ヘッダーフィールドの数を取得
    pub fn count(self: Headers) usize {
        return self.fields.items.len;
    }

    /// 特定のヘッダー名の出現回数を取得
    pub fn countByName(self: Headers, name: []const u8) usize {
        var result: usize = 0;
        for (self.fields.items) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, name)) {
                result += 1;
            }
        }
        return result;
    }

    /// 全てのヘッダーをクリア
    pub fn clear(self: *Headers) void {
        for (self.fields.items) |*field| {
            field.deinit(self.allocator);
        }
        self.fields.clearRetainingCapacity();
    }

    /// 指定したヘッダー名の値を設定（既存の場合は置き換え）
    pub fn set(self: *Headers, name: []const u8, value: []const u8) !void {
        // 既存のヘッダーを削除
        self.remove(name);

        // 新しいヘッダーを追加
        try self.append(name, value);
    }

    /// ヘッダーを文字列に変換
    pub fn format(self: Headers, writer: anytype) !void {
        for (self.fields.items) |field| {
            try writer.print("{s}: {s}\r\n", .{ field.name, field.value });
        }
    }

    /// 新しいヘッダーを複製して作成
    pub fn clone(self: Headers) !Headers {
        var new_headers = Headers.init(self.allocator);
        errdefer new_headers.deinit();

        for (self.fields.items) |field| {
            try new_headers.append(field.name, field.value);
        }

        return new_headers;
    }

    /// コンテントタイプが指定したMIMEタイプに一致するか
    pub fn hasContentType(self: Headers, mime_type: []const u8) bool {
        const content_type = self.get("Content-Type") orelse return false;

        // パラメータを除いた部分だけ比較（例: "text/html; charset=utf-8" → "text/html"）
        const semicolon_pos = std.mem.indexOf(u8, content_type, ";");
        const mime_part = if (semicolon_pos) |pos| content_type[0..pos] else content_type;

        // 先頭と末尾の空白を取り除いて比較
        const trimmed = std.mem.trim(u8, mime_part, " \t");
        return std.ascii.eqlIgnoreCase(trimmed, mime_type);
    }

    /// Content-Lengthヘッダーの値を数値として取得
    pub fn getContentLength(self: Headers) ?usize {
        const content_length = self.get("Content-Length") orelse return null;
        return std.fmt.parseInt(usize, content_length, 10) catch null;
    }

    /// ヘッダーが空かどうか
    pub fn isEmpty(self: Headers) bool {
        return self.fields.items.len == 0;
    }
};

test "Headers basic operations" {
    const allocator = std.testing.allocator;

    var headers = Headers.init(allocator);
    defer headers.deinit();

    // ヘッダー追加
    try headers.append("Content-Type", "text/html");
    try headers.append("Content-Length", "1024");
    try headers.append("Accept-Encoding", "gzip");

    // 取得テスト
    try std.testing.expectEqualStrings("text/html", headers.get("Content-Type").?);
    try std.testing.expectEqualStrings("1024", headers.get("Content-Length").?);
    try std.testing.expectEqualStrings("gzip", headers.get("Accept-Encoding").?);

    // 大文字小文字を区別しない検索
    try std.testing.expectEqualStrings("text/html", headers.get("content-type").?);

    // 存在しないヘッダー
    try std.testing.expect(headers.get("X-Not-Exist") == null);

    // ヘッダー数
    try std.testing.expectEqual(@as(usize, 3), headers.count());

    // ヘッダー削除
    headers.remove("Content-Length");
    try std.testing.expect(headers.get("Content-Length") == null);
    try std.testing.expectEqual(@as(usize, 2), headers.count());

    // ヘッダー上書き
    try headers.set("Content-Type", "application/json");
    try std.testing.expectEqualStrings("application/json", headers.get("Content-Type").?);
    try std.testing.expectEqual(@as(usize, 2), headers.count());

    // MIMEタイプチェック
    try std.testing.expect(headers.hasContentType("application/json"));
    try std.testing.expect(!headers.hasContentType("text/html"));

    // 複数値ヘッダー
    try headers.append("Accept", "text/html");
    try headers.append("Accept", "application/json");

    try std.testing.expectEqual(@as(usize, 4), headers.count());
    try std.testing.expectEqual(@as(usize, 2), headers.countByName("Accept"));

    // 全値取得
    const accept_values = try headers.getAll("Accept", allocator);
    defer allocator.free(accept_values);
    try std.testing.expectEqual(@as(usize, 2), accept_values.len);
    try std.testing.expectEqualStrings("text/html", accept_values[0]);
    try std.testing.expectEqualStrings("application/json", accept_values[1]);

    // クリア
    headers.clear();
    try std.testing.expectEqual(@as(usize, 0), headers.count());
    try std.testing.expect(headers.isEmpty());
}
