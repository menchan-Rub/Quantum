// src/zig/quantum_net/http/methods.zig
// HTTP メソッド定義

const std = @import("std");

/// HTTP メソッド列挙型
pub const Method = enum {
    Get,
    Post,
    Put,
    Delete,
    Head,
    Options,
    Patch,
    Connect,
    Trace,
    Custom, // カスタムメソッド用

    /// 文字列からHTTPメソッドを取得
    pub fn fromString(method_str: []const u8) !Method {
        if (std.mem.eql(u8, method_str, "GET")) return .Get;
        if (std.mem.eql(u8, method_str, "POST")) return .Post;
        if (std.mem.eql(u8, method_str, "PUT")) return .Put;
        if (std.mem.eql(u8, method_str, "DELETE")) return .Delete;
        if (std.mem.eql(u8, method_str, "HEAD")) return .Head;
        if (std.mem.eql(u8, method_str, "OPTIONS")) return .Options;
        if (std.mem.eql(u8, method_str, "PATCH")) return .Patch;
        if (std.mem.eql(u8, method_str, "CONNECT")) return .Connect;
        if (std.mem.eql(u8, method_str, "TRACE")) return .Trace;

        // 他のメソッドは未実装
        return error.UnsupportedMethod;
    }

    /// HTTPメソッドを文字列に変換
    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .Get => "GET",
            .Post => "POST",
            .Put => "PUT",
            .Delete => "DELETE",
            .Head => "HEAD",
            .Options => "OPTIONS",
            .Patch => "PATCH",
            .Connect => "CONNECT",
            .Trace => "TRACE",
            .Custom => "CUSTOM", // 実際には使われない
        };
    }

    /// メソッドがボディを持つ可能性があるか
    pub fn mayHaveBody(self: Method) bool {
        return switch (self) {
            .Get, .Head, .Options, .Trace => false,
            else => true,
        };
    }

    /// メソッドが安全(副作用がない)か
    pub fn isSafe(self: Method) bool {
        return switch (self) {
            .Get, .Head, .Options, .Trace => true,
            else => false,
        };
    }

    /// メソッドがべき等(何度実行しても同じ結果)か
    pub fn isIdempotent(self: Method) bool {
        return switch (self) {
            .Post, .Connect, .Custom => false,
            else => true,
        };
    }

    /// メソッドがキャッシュ可能か
    pub fn isCacheable(self: Method) bool {
        return switch (self) {
            .Get, .Head => true,
            else => false,
        };
    }
};

test "Method fromString" {
    try std.testing.expectEqual(Method.Get, try Method.fromString("GET"));
    try std.testing.expectEqual(Method.Post, try Method.fromString("POST"));
    try std.testing.expectEqual(Method.Put, try Method.fromString("PUT"));
    try std.testing.expectEqual(Method.Delete, try Method.fromString("DELETE"));
    try std.testing.expectEqual(Method.Head, try Method.fromString("HEAD"));
    try std.testing.expectEqual(Method.Options, try Method.fromString("OPTIONS"));

    try std.testing.expectError(error.UnsupportedMethod, Method.fromString("INVALID"));
}

test "Method toString" {
    try std.testing.expectEqualStrings("GET", Method.Get.toString());
    try std.testing.expectEqualStrings("POST", Method.Post.toString());
    try std.testing.expectEqualStrings("PUT", Method.Put.toString());
    try std.testing.expectEqualStrings("DELETE", Method.Delete.toString());
}

test "Method properties" {
    try std.testing.expect(Method.Get.isSafe());
    try std.testing.expect(!Method.Post.isSafe());

    try std.testing.expect(Method.Get.isIdempotent());
    try std.testing.expect(!Method.Post.isIdempotent());
    try std.testing.expect(Method.Put.isIdempotent());

    try std.testing.expect(Method.Get.isCacheable());
    try std.testing.expect(!Method.Post.isCacheable());
}
