// src/zig/util/validation.zig
// DOM関連の検証関数を提供します。

const std = @import("std");
const errors = @import("./error.zig");

// XML Name production characters (RFC 5646 および XML 1.0 第5版に基づく)
// https://www.w3.org/TR/xml/#NT-Name
// https://www.w3.org/TR/xml-names/#NT-NCName
fn isNameStartChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == ':' or c == '_';
}

fn isNameChar(c: u8) bool {
    return isNameStartChar(c) or std.ascii.isDigit(c) or c == '.' or c == '-';
}

// QName (Qualified Name) の検証
// https://www.w3.org/TR/xml-names/#NT-QName
pub fn validateQName(qname: []const u8) !void {
    if (qname.len == 0) {
        return errors.DomError.InvalidCharacterError;
    }

    var saw_colon = false;
    var first_char = true;
    for (qname) |char| {
        if (first_char) {
            if (!isNameStartChar(char)) {
                return errors.DomError.InvalidCharacterError;
            }
            first_char = false;
        } else {
            if (char == ':') {
                if (saw_colon) {
                    // コロンは1つまで
                    return errors.DomError.InvalidCharacterError;
                }
                saw_colon = true;
                // コロンの直後も NameStartChar である必要がある
                // （次のループでチェックされる）
            } else if (!isNameChar(char)) {
                return errors.DomError.InvalidCharacterError;
            }
        }
    }
    // コロンで終わることはできない
    if (qname[qname.len - 1] == ':') {
        return errors.DomError.InvalidCharacterError;
    }
}

// NCName (Non-Colonized Name) の検証
// https://www.w3.org/TR/xml-names/#NT-NCName
pub fn validateNCName(ncname: []const u8) !void {
    if (ncname.len == 0) {
        return errors.DomError.InvalidCharacterError;
    }
    if (!isNameStartChar(ncname[0]) or ncname[0] == ':') {
         return errors.DomError.InvalidCharacterError;
    }
    for (ncname) |char| {
        if (!isNameChar(char) or char == ':') {
            return errors.DomError.InvalidCharacterError;
        }
    }
}

// 属性名 (local name) とプレフィックスの検証
// Element.setAttributeNS などの呼び出し元で使用される想定
pub fn validateAttributeNameAndPrefix(prefix: ?[]const u8, local_name: []const u8) !void {
    try validateNCName(local_name);
    if (prefix) |p| {
        try validateNCName(p);
    }
}

// XML Namespace URI と Prefix の整合性検証
// https://dom.spec.whatwg.org/#validate
pub fn validateNamespaceAndPrefix(namespace_uri: ?[]const u8, prefix: ?[]const u8, local_name: []const u8) !void {
    const xml_ns = "http://www.w3.org/XML/1998/namespace";
    const xmlns_ns = "http://www.w3.org/2000/xmlns/";

    // プレフィックスの検証
    if (prefix) |p| {
        // プレフィックス自体は NCName でなければならない (validateAttributeNameAndPrefix でチェック済み想定)

        // プレフィックスが "xml" の場合
        if (std.mem.eql(u8, p, "xml")) {
            if (namespace_uri == null or !std.mem.eql(u8, namespace_uri.?, xml_ns)) {
                 std.log.err("Prefix 'xml' requires namespace '{s}'", .{xml_ns});
                 return errors.DomError.NamespaceError;
            }
        } else if (std.mem.eql(u8, local_name, "xmlns")) {
             // プレフィックスが 'xml' 以外で、ローカル名が "xmlns" の場合 (例: foo:xmlns)
            // これは予約されており、許可されない
             std.log.err("Attributes with local name 'xmlns' cannot have a prefix other than 'xml'", .{});
             return errors.DomError.NamespaceError;
        }
        // Namespace URI が空でプレフィックスがある場合
        if (namespace_uri == null or namespace_uri.?.len == 0) {
            std.log.err("Non-empty prefix requires a non-empty namespace URI", .{});
            return errors.DomError.NamespaceError;
        }
        // namespace が xmlns_ns で prefix が "xmlns" 以外の場合
         if (std.mem.eql(u8, namespace_uri orelse "", xmlns_ns) and !std.mem.eql(u8, p, "xmlns")) {
            std.log.err("Namespace '{s}' must be used with prefix 'xmlns'", .{xmlns_ns});
            return errors.DomError.NamespaceError;
         }

    } else { // プレフィックスがない場合
        // ローカル名が "xmlns" の場合 (デフォルト名前空間宣言)
        if (std.mem.eql(u8, local_name, "xmlns")) {
             // namespace が xmlns_ns である必要がある
            if (namespace_uri == null or !std.mem.eql(u8, namespace_uri.?, xmlns_ns)) {
                 std.log.err("Default namespace declaration ('xmlns') requires namespace '{s}'", .{xmlns_ns});
                 return errors.DomError.NamespaceError;
            }
        }
    }
}


// テスト
test "validateQName" {
    try validateQName("a");
    try validateQName("a:b");
    try validateQName("_a:b-c.d");
    try validateQName(":a"); // Allowed by XML spec, but maybe not NCName

    try std.testing.expectError(errors.DomError.InvalidCharacterError, validateQName(""));
    try std.testing.expectError(errors.DomError.InvalidCharacterError, validateQName("1a"));
    try std.testing.expectError(errors.DomError.InvalidCharacterError, validateQName("-a"));
    try std.testing.expectError(errors.DomError.InvalidCharacterError, validateQName("a:"));
    try std.testing.expectError(errors.DomError.InvalidCharacterError, validateQName("a:b:c"));
    try std.testing.expectError(errors.DomError.InvalidCharacterError, validateQName("a b"));
}

test "validateNCName" {
    try validateNCName("a");
    try validateNCName("_a");
    try validateNCName("a-b.c");

    try std.testing.expectError(errors.DomError.InvalidCharacterError, validateNCName(""));
    try std.testing.expectError(errors.DomError.InvalidCharacterError, validateNCName("1a"));
    try std.testing.expectError(errors.DomError.InvalidCharacterError, validateNCName("-a"));
    try std.testing.expectError(errors.DomError.InvalidCharacterError, validateNCName("a:b"));
    try std.testing.expectError(errors.DomError.InvalidCharacterError, validateNCName(":a"));
    try std.testing.expectError(errors.DomError.InvalidCharacterError, validateNCName("a b"));
}

test "validateNamespaceAndPrefix" {
    const xml_ns = "http://www.w3.org/XML/1998/namespace";
    const xmlns_ns = "http://www.w3.org/2000/xmlns/";
    const custom_ns = "http://example.com/ns";

    // OK cases
    try validateNamespaceAndPrefix(null, null, "attr");
    try validateNamespaceAndPrefix(custom_ns, "p", "attr");
    try validateNamespaceAndPrefix(xml_ns, "xml", "lang");
    try validateNamespaceAndPrefix(xmlns_ns, null, "xmlns"); // Default NS declaration
    try validateNamespaceAndPrefix(xmlns_ns, "xmlns", "p");   // Namespace prefix declaration (e.g. xmlns:p="...")

    // Error cases
    // Prefix 'xml' requires XML namespace
    try std.testing.expectError(errors.DomError.NamespaceError, validateNamespaceAndPrefix(custom_ns, "xml", "lang"));
    try std.testing.expectError(errors.DomError.NamespaceError, validateNamespaceAndPrefix(null, "xml", "lang"));
    // Prefix requires a namespace
    try std.testing.expectError(errors.DomError.NamespaceError, validateNamespaceAndPrefix(null, "p", "attr"));
    try std.testing.expectError(errors.DomError.NamespaceError, validateNamespaceAndPrefix("", "p", "attr"));
    // Local name 'xmlns' cannot have a prefix other than 'xml'
    // (Technically XML spec allows xml:xmlns, but DOM spec might restrict? Let's forbid for now)
    try std.testing.expectError(errors.DomError.NamespaceError, validateNamespaceAndPrefix(custom_ns, "p", "xmlns"));
    // Default namespace declaration requires xmlns namespace
    try std.testing.expectError(errors.DomError.NamespaceError, validateNamespaceAndPrefix(custom_ns, null, "xmlns"));
    try std.testing.expectError(errors.DomError.NamespaceError, validateNamespaceAndPrefix(null, null, "xmlns"));
    // Namespace prefix declaration must use 'xmlns' prefix
    try std.testing.expectError(errors.DomError.NamespaceError, validateNamespaceAndPrefix(xmlns_ns, "p", "attr"));


} 