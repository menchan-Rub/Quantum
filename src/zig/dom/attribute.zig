// src/zig/dom/attribute.zig
// DOM の Attribute (Attr) インターフェースに対応する構造体を定義します。
// https://dom.spec.whatwg.org/#interface-attr

const std = @import("std");
const mem = @import("../memory/allocator.zig"); // Global allocator
const errors = @import("../util/error.zig");   // Common errors
const validation = @import("../util/validation.zig"); // Validation functions

// Forward declaration needed for owner_element
const Element = @import("./element.zig").Element;

// 属性構造体
pub const Attribute = struct {
    // Namespace URI (例: "http://www.w3.org/1999/xhtml")。なければ null。
    namespace_uri: ?[]const u8,
    // Namespace prefix (例: "xlink")。なければ null。
    prefix: ?[]const u8,
    // Local name (例: "href")。
    local_name: []const u8,
    // Attribute value。
    value: []const u8,

    // この属性を所有する要素へのポインタ (なければ null)
    // 属性が要素に追加されるときに設定される。
    owner_element: ?*Element = null,

    // 属性を作成する関数。
    // 文字列は通常アロケータによって所有される (例: パース時に dupe される)。
    // この関数は Attribute 構造体自体のメモリ確保のみを行う。
    pub fn create(
        allocator: std.mem.Allocator,
        namespace_uri: ?[]const u8,
        prefix: ?[]const u8,
        local_name: []const u8,
        value: []const u8,
    ) !*Attribute {
        // 名前空間とプレフィックスを検証
        try validation.validateNamespaceAndPrefix(namespace_uri, prefix, local_name);
        // 属性名を検証
        try validation.validateName(local_name);
        if (prefix) |p| {
             try validation.validateName(p);
        }

        const attr = try allocator.create(Attribute);
        attr.* = Attribute{
            .namespace_uri = namespace_uri,
            .prefix = prefix,
            .local_name = local_name,
            .value = value,
        };
        std.log.debug("Created Attribute (name: {?s}:{s}, value: {s})", .{ prefix, local_name, value });
        return attr;
    }

    // 属性を破棄する関数。
    // この関数は Attribute 構造体自体のメモリを解放する。
    // 文字列スライスの解放は呼び出し元 (通常は ElementData の属性マップ) の責任。
    pub fn destroy(attr: *Attribute, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying Attribute (name: {?s}:{s})", .{ attr.prefix, attr.local_name });
        // owner_element の参照をクリアする必要があるか？ (通常は要素側で管理)
        // value 文字列はこの関数では解放しない (setValue で管理されるか、ElementData 側で管理される)
        allocator.destroy(attr);
    }

    // --- DOM Attr API (抜粋) ---

    // name (qualified name) を取得 (例: "xlink:href" or "class")
    pub fn name(self: *const Attribute, allocator: std.mem.Allocator) ![]const u8 {
        if (self.prefix) |p| {
            // prefix + ":" + local_name
            return std.fmt.allocPrint(allocator, "{s}:{s}", .{ p, self.local_name });
        } else {
            // local_name を複製して返す (呼び出し元が解放)
            return allocator.dupe(u8, self.local_name);
        }
    }

    // value の取得 (プロパティアクセス用)
    pub fn getValue(self: *const Attribute) []const u8 {
        return self.value;
    }

    // value の設定 (プロパティアクセス用)
    // value 文字列の所有権管理に注意。
    // 通常は Element.setAttribute() 経由で変更されるべき。
    pub fn setValue(self: *Attribute, allocator: std.mem.Allocator, new_value: []const u8) void {
        // TODO: 属性値の変更を通知するメカニズム (例: MutationObserver)
        //      この属性が要素に接続されている場合、関連する要素に変更イベントを発火させる必要がある。
        //      例: self.owner_element.?.dispatchAttributeChanged(self.local_name, self.value, new_value);

        // 古い value 文字列を解放 (この属性が所有権を持っていたと仮定)
        // 新しい値は呼び出し元が所有権を持っているか、ここで dupe されたものを受け取る。
        // ここでは渡されたスライスをそのまま保持する (所有権は移譲されたとみなす)。
        // 注意: Element.setAttribute などで呼び出される場合、新しい値は Element が所有権を持つべき。
        //       単純なプロパティアクセスとして使う場合は注意が必要。
        allocator.free(self.value); // 解放する前に所有権を確認する必要があるかもしれない
        self.value = new_value;
    }

    // specified プロパティ (常に true)
    pub fn specified(self: *const Attribute) bool {
        _ = self;
        return true;
    }

    // --- ヘルパー関数 ---

    // 属性名が一致するかどうかを確認 (名前空間とローカル名で比較)
    pub fn matches(self: *const Attribute, ns: ?[]const u8, local_name: []const u8) bool {
        if (!std.mem.eql(u8, self.local_name, local_name)) {
            return false;
        }
        // 両方 null か、両方が同じ文字列か
        if (self.namespace_uri == null and ns == null) {
            return true;
        } else if (self.namespace_uri != null and ns != null) {
            return std.mem.eql(u8, self.namespace_uri.?, ns.?);
        } else {
            return false;
        }
    }

    // HTML 用の属性名一致チェック (ASCII case-insensitive)
    pub fn matchesHTML(self: *const Attribute, html_name: []const u8) bool {
        // HTML 属性は名前空間を持たない
        if (self.namespace_uri != null) {
            return false;
        }
        return std.ascii.eqlIgnoreCase(self.local_name, html_name);
    }
};

// Attribute のテスト
test "Attribute creation and basic properties" {
    const allocator = std.testing.allocator;
    const ns = "http://example.com/ns";
    const prefix = "ex";
    const name = "myAttr";
    const value = "testValue";

    var attr = try Attribute.create(allocator, ns, prefix, name, value);
    defer attr.destroy(allocator);

    try std.testing.expectEqualStrings(ns, attr.namespace_uri.?);
    try std.testing.expectEqualStrings(prefix, attr.prefix.?);
    try std.testing.expectEqualStrings(name, attr.local_name);
    try std.testing.expectEqualStrings(value, attr.value);
    try std.testing.expect(attr.owner_element == null);
    try std.testing.expect(attr.specified());

    const qualified_name = try attr.name(allocator);
    defer allocator.free(qualified_name);
    try std.testing.expectEqualStrings("ex:myAttr", qualified_name);
}

test "Attribute creation without namespace" {
    const allocator = std.testing.allocator;
    const name = "class";
    const value = "container";

    var attr = try Attribute.create(allocator, null, null, name, value);
    defer attr.destroy(allocator);

    try std.testing.expect(attr.namespace_uri == null);
    try std.testing.expect(attr.prefix == null);
    try std.testing.expectEqualStrings(name, attr.local_name);
    try std.testing.expectEqualStrings(value, attr.value);

    const qualified_name = try attr.name(allocator);
    defer allocator.free(qualified_name);
    try std.testing.expectEqualStrings("class", qualified_name);
}

test "Attribute matches" {
    const allocator = std.testing.allocator;
    const ns = "http://example.com/ns";
    var attr_ns = try Attribute.create(allocator, ns, "ex", "myAttr", "v1");
    defer attr_ns.destroy(allocator);
    var attr_no_ns = try Attribute.create(allocator, null, null, "myAttr", "v2");
    defer attr_no_ns.destroy(allocator);
    var attr_html = try Attribute.create(allocator, null, null, "CLASS", "v3");
    defer attr_html.destroy(allocator);

    try std.testing.expect(attr_ns.matches(ns, "myAttr"));
    try std.testing.expect(!attr_ns.matches(null, "myAttr"));
    try std.testing.expect(!attr_ns.matches(ns, "otherAttr"));

    try std.testing.expect(attr_no_ns.matches(null, "myAttr"));
    try std.testing.expect(!attr_no_ns.matches(ns, "myAttr"));

    try std.testing.expect(attr_html.matchesHTML("class"));
    try std.testing.expect(attr_html.matchesHTML("CLASS"));
    try std.testing.expect(!attr_html.matchesHTML("id"));
    try std.testing.expect(!attr_ns.matchesHTML("myAttr"));
} 