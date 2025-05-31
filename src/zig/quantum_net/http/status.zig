// src/zig/quantum_net/http/status.zig
// HTTP ステータスコード定義

const std = @import("std");

/// HTTP ステータスコード構造体
pub const Status = struct {
    code: u16, // ステータスコード
    message: []const u8, // ステータスメッセージ

    // よく使われるステータスコードの定義（静的インスタンス）
    pub const continue_status = Status{ .code = 100, .message = "Continue" };
    pub const switching_protocols = Status{ .code = 101, .message = "Switching Protocols" };
    pub const processing = Status{ .code = 102, .message = "Processing" };
    pub const early_hints = Status{ .code = 103, .message = "Early Hints" };

    pub const ok = Status{ .code = 200, .message = "OK" };
    pub const created = Status{ .code = 201, .message = "Created" };
    pub const accepted = Status{ .code = 202, .message = "Accepted" };
    pub const non_authoritative_information = Status{ .code = 203, .message = "Non-Authoritative Information" };
    pub const no_content = Status{ .code = 204, .message = "No Content" };
    pub const reset_content = Status{ .code = 205, .message = "Reset Content" };
    pub const partial_content = Status{ .code = 206, .message = "Partial Content" };
    pub const multi_status = Status{ .code = 207, .message = "Multi-Status" };
    pub const already_reported = Status{ .code = 208, .message = "Already Reported" };
    pub const im_used = Status{ .code = 226, .message = "IM Used" };

    pub const multiple_choices = Status{ .code = 300, .message = "Multiple Choices" };
    pub const moved_permanently = Status{ .code = 301, .message = "Moved Permanently" };
    pub const found = Status{ .code = 302, .message = "Found" };
    pub const see_other = Status{ .code = 303, .message = "See Other" };
    pub const not_modified = Status{ .code = 304, .message = "Not Modified" };
    pub const use_proxy = Status{ .code = 305, .message = "Use Proxy" };
    pub const temporary_redirect = Status{ .code = 307, .message = "Temporary Redirect" };
    pub const permanent_redirect = Status{ .code = 308, .message = "Permanent Redirect" };

    pub const bad_request = Status{ .code = 400, .message = "Bad Request" };
    pub const unauthorized = Status{ .code = 401, .message = "Unauthorized" };
    pub const payment_required = Status{ .code = 402, .message = "Payment Required" };
    pub const forbidden = Status{ .code = 403, .message = "Forbidden" };
    pub const not_found = Status{ .code = 404, .message = "Not Found" };
    pub const method_not_allowed = Status{ .code = 405, .message = "Method Not Allowed" };
    pub const not_acceptable = Status{ .code = 406, .message = "Not Acceptable" };
    pub const proxy_authentication_required = Status{ .code = 407, .message = "Proxy Authentication Required" };
    pub const request_timeout = Status{ .code = 408, .message = "Request Timeout" };
    pub const conflict = Status{ .code = 409, .message = "Conflict" };
    pub const gone = Status{ .code = 410, .message = "Gone" };
    pub const length_required = Status{ .code = 411, .message = "Length Required" };
    pub const precondition_failed = Status{ .code = 412, .message = "Precondition Failed" };
    pub const payload_too_large = Status{ .code = 413, .message = "Payload Too Large" };
    pub const uri_too_long = Status{ .code = 414, .message = "URI Too Long" };
    pub const unsupported_media_type = Status{ .code = 415, .message = "Unsupported Media Type" };
    pub const range_not_satisfiable = Status{ .code = 416, .message = "Range Not Satisfiable" };
    pub const expectation_failed = Status{ .code = 417, .message = "Expectation Failed" };
    pub const im_a_teapot = Status{ .code = 418, .message = "I'm a teapot" };
    pub const misdirected_request = Status{ .code = 421, .message = "Misdirected Request" };
    pub const unprocessable_entity = Status{ .code = 422, .message = "Unprocessable Entity" };
    pub const locked = Status{ .code = 423, .message = "Locked" };
    pub const failed_dependency = Status{ .code = 424, .message = "Failed Dependency" };
    pub const too_early = Status{ .code = 425, .message = "Too Early" };
    pub const upgrade_required = Status{ .code = 426, .message = "Upgrade Required" };
    pub const precondition_required = Status{ .code = 428, .message = "Precondition Required" };
    pub const too_many_requests = Status{ .code = 429, .message = "Too Many Requests" };
    pub const request_header_fields_too_large = Status{ .code = 431, .message = "Request Header Fields Too Large" };
    pub const unavailable_for_legal_reasons = Status{ .code = 451, .message = "Unavailable For Legal Reasons" };

    pub const internal_server_error = Status{ .code = 500, .message = "Internal Server Error" };
    pub const not_implemented = Status{ .code = 501, .message = "Not Implemented" };
    pub const bad_gateway = Status{ .code = 502, .message = "Bad Gateway" };
    pub const service_unavailable = Status{ .code = 503, .message = "Service Unavailable" };
    pub const gateway_timeout = Status{ .code = 504, .message = "Gateway Timeout" };
    pub const http_version_not_supported = Status{ .code = 505, .message = "HTTP Version Not Supported" };
    pub const variant_also_negotiates = Status{ .code = 506, .message = "Variant Also Negotiates" };
    pub const insufficient_storage = Status{ .code = 507, .message = "Insufficient Storage" };
    pub const loop_detected = Status{ .code = 508, .message = "Loop Detected" };
    pub const not_extended = Status{ .code = 510, .message = "Not Extended" };
    pub const network_authentication_required = Status{ .code = 511, .message = "Network Authentication Required" };

    /// ステータスコードからステータス構造体を取得
    pub fn fromCode(code: u16) !Status {
        return switch (code) {
            100 => continue_status,
            101 => switching_protocols,
            102 => processing,
            103 => early_hints,

            200 => ok,
            201 => created,
            202 => accepted,
            203 => non_authoritative_information,
            204 => no_content,
            205 => reset_content,
            206 => partial_content,
            207 => multi_status,
            208 => already_reported,
            226 => im_used,

            300 => multiple_choices,
            301 => moved_permanently,
            302 => found,
            303 => see_other,
            304 => not_modified,
            305 => use_proxy,
            307 => temporary_redirect,
            308 => permanent_redirect,

            400 => bad_request,
            401 => unauthorized,
            402 => payment_required,
            403 => forbidden,
            404 => not_found,
            405 => method_not_allowed,
            406 => not_acceptable,
            407 => proxy_authentication_required,
            408 => request_timeout,
            409 => conflict,
            410 => gone,
            411 => length_required,
            412 => precondition_failed,
            413 => payload_too_large,
            414 => uri_too_long,
            415 => unsupported_media_type,
            416 => range_not_satisfiable,
            417 => expectation_failed,
            418 => im_a_teapot,
            421 => misdirected_request,
            422 => unprocessable_entity,
            423 => locked,
            424 => failed_dependency,
            425 => too_early,
            426 => upgrade_required,
            428 => precondition_required,
            429 => too_many_requests,
            431 => request_header_fields_too_large,
            451 => unavailable_for_legal_reasons,

            500 => internal_server_error,
            501 => not_implemented,
            502 => bad_gateway,
            503 => service_unavailable,
            504 => gateway_timeout,
            505 => http_version_not_supported,
            506 => variant_also_negotiates,
            507 => insufficient_storage,
            508 => loop_detected,
            510 => not_extended,
            511 => network_authentication_required,
            
            else => return error.UnknownStatusCode,
        };
    }

    /// ステータスコードの種類を取得
    pub fn getCategory(self: Status) StatusCategory {
        const code_range = self.code / 100;
        return switch (code_range) {
            1 => .Informational,
            2 => .Success,
            3 => .Redirection,
            4 => .ClientError,
            5 => .ServerError,
            else => .Unknown,
        };
    }

    /// ステータスをフォーマットして文字列に変換
    pub fn format(self: Status, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{} {s}", .{ self.code, self.message });
    }

    /// ステータスが成功を表しているか
    pub fn isSuccess(self: Status) bool {
        return self.code >= 200 and self.code < 300;
    }

    /// ステータスがエラーを表しているか
    pub fn isError(self: Status) bool {
        return self.code >= 400;
    }

    /// ステータスが情報を表しているか
    pub fn isInformational(self: Status) bool {
        return self.code >= 100 and self.code < 200;
    }

    /// ステータスがリダイレクトを表しているか
    pub fn isRedirection(self: Status) bool {
        return self.code >= 300 and self.code < 400;
    }

    /// ステータスがクライアントエラーを表しているか
    pub fn isClientError(self: Status) bool {
        return self.code >= 400 and self.code < 500;
    }

    /// ステータスがサーバーエラーを表しているか
    pub fn isServerError(self: Status) bool {
        return self.code >= 500 and self.code < 600;
    }

    /// ステータスがリダイレクトを示すかチェック
    pub fn isRedirect(self: Status) bool {
        return self.code >= 300 and self.code < 400;
    }

    /// ステータスの文字列表現を取得
    pub fn toString(self: Status) []const u8 {
        return self.message;
    }

    /// ステータスコードとメッセージの完全な文字列を生成
    pub fn toFullString(self: Status, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{d} {s}", .{ self.code, self.message });
    }
};

/// HTTPステータスコードのカテゴリー
pub const StatusCategory = enum {
    Informational, // 1xx
    Success, // 2xx
    Redirection, // 3xx
    ClientError, // 4xx
    ServerError, // 5xx
    Unknown, // その他
};

test "Status fromCode" {
    try std.testing.expectEqual(Status.ok, try Status.fromCode(200));
    try std.testing.expectEqual(Status.not_found, try Status.fromCode(404));
    try std.testing.expectEqual(Status.internal_server_error, try Status.fromCode(500));

    try std.testing.expectError(error.UnknownStatusCode, Status.fromCode(999));
}

test "Status categories" {
    try std.testing.expectEqual(StatusCategory.Informational, Status.continue_status.getCategory());
    try std.testing.expectEqual(StatusCategory.Success, Status.ok.getCategory());
    try std.testing.expectEqual(StatusCategory.Redirection, Status.moved_permanently.getCategory());
    try std.testing.expectEqual(StatusCategory.ClientError, Status.bad_request.getCategory());
    try std.testing.expectEqual(StatusCategory.ServerError, Status.internal_server_error.getCategory());
}

test "Status predicates" {
    try std.testing.expect(Status.ok.isSuccess());
    try std.testing.expect(!Status.not_found.isSuccess());

    try std.testing.expect(Status.not_found.isError());
    try std.testing.expect(Status.internal_server_error.isError());
    try std.testing.expect(!Status.ok.isError());

    try std.testing.expect(Status.continue_status.isInformational());
    try std.testing.expect(Status.not_found.isClientError());
    try std.testing.expect(Status.internal_server_error.isServerError());
}
