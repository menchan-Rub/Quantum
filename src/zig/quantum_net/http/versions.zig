// src/zig/quantum_net/http/versions.zig
// HTTP バージョン定義

const std = @import("std");

/// HTTP バージョン列挙型
pub const Version = enum {
    Http10, // HTTP/1.0
    Http11, // HTTP/1.1
    Http2, // HTTP/2
    Http3, // HTTP/3

    /// 文字列からHTTPバージョンを取得
    pub fn fromString(version_str: []const u8) !Version {
        if (std.mem.eql(u8, version_str, "HTTP/1.0")) return .Http10;
        if (std.mem.eql(u8, version_str, "HTTP/1.1")) return .Http11;
        if (std.mem.eql(u8, version_str, "HTTP/2")) return .Http2;
        if (std.mem.eql(u8, version_str, "HTTP/3")) return .Http3;

        return error.UnsupportedVersion;
    }

    /// HTTPバージョンを文字列に変換
    pub fn toString(self: Version) []const u8 {
        return switch (self) {
            .Http10 => "HTTP/1.0",
            .Http11 => "HTTP/1.1",
            .Http2 => "HTTP/2",
            .Http3 => "HTTP/3",
        };
    }

    /// バージョンが永続的接続をサポートしているか
    pub fn supportsPersistentConnections(self: Version) bool {
        return switch (self) {
            .Http10 => false, // デフォルトではサポートしない（Connection: keep-alive指定時は例外）
            else => true, // HTTP/1.1以降はデフォルトでサポート
        };
    }

    /// バージョンがストリーミングをサポートしているか
    pub fn supportsStreaming(self: Version) bool {
        return switch (self) {
            .Http10, .Http11 => false, // チャンクトランスファーは別
            .Http2, .Http3 => true, // HTTP/2, HTTP/3はストリーム対応
        };
    }

    /// バージョンが多重化をサポートしているか
    pub fn supportsMultiplexing(self: Version) bool {
        return switch (self) {
            .Http10, .Http11 => false, // コネクションあたり1リクエスト
            .Http2, .Http3 => true, // コネクションあたり複数リクエスト
        };
    }

    /// バージョンがServer Pushをサポートしているか
    pub fn supportsServerPush(self: Version) bool {
        return switch (self) {
            .Http10, .Http11 => false,
            .Http2 => true,
            .Http3 => true,
        };
    }
};

test "Version fromString" {
    try std.testing.expectEqual(Version.Http10, try Version.fromString("HTTP/1.0"));
    try std.testing.expectEqual(Version.Http11, try Version.fromString("HTTP/1.1"));
    try std.testing.expectEqual(Version.Http2, try Version.fromString("HTTP/2"));
    try std.testing.expectEqual(Version.Http3, try Version.fromString("HTTP/3"));

    try std.testing.expectError(error.UnsupportedVersion, Version.fromString("HTTP/0.9"));
}

test "Version toString" {
    try std.testing.expectEqualStrings("HTTP/1.0", Version.Http10.toString());
    try std.testing.expectEqualStrings("HTTP/1.1", Version.Http11.toString());
    try std.testing.expectEqualStrings("HTTP/2", Version.Http2.toString());
    try std.testing.expectEqualStrings("HTTP/3", Version.Http3.toString());
}

test "Version features" {
    try std.testing.expect(!Version.Http10.supportsPersistentConnections());
    try std.testing.expect(Version.Http11.supportsPersistentConnections());

    try std.testing.expect(!Version.Http11.supportsMultiplexing());
    try std.testing.expect(Version.Http2.supportsMultiplexing());

    try std.testing.expect(!Version.Http11.supportsServerPush());
    try std.testing.expect(Version.Http2.supportsServerPush());
}
