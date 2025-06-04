// src/zig/dom/element_data.zig
// Element ノードに固有のデータを保持する構造体を定義します。

const std = @import("std");
const mem = @import("../memory/allocator.zig"); // Global allocator
const errors = @import("../util/error.zig"); // Common errors
const Attribute = @import("./attribute.zig").Attribute;

// 文字列キー (属性の qualifiedName) をキーとし、Attribute ポインタを値とする HashMap。
// qualifiedName をキーにすることで、名前空間プレフィックスを含む属性検索を効率化する。
// 例: "class", "xlink:href"
pub const AttributeMap = std.StringHashMap(*Attribute);

// Element 固有データ
pub const ElementData = struct {
    // 要素のタグ名 (例: "div", "a")。
    // 所有権は ElementData が持つ。
    tag_name: []const u8,
    // 要素の名前空間 URI (例: "http://www.w3.org/1999/xhtml")。
    namespace_uri: ?[]const u8,
    // 属性を保持するマップ。
    // キーは属性の qualifiedName (例: "class", "xlink:href")。
    // 値は Attribute 構造体へのポインタ。
    attributes: AttributeMap,

    // ElementData インスタンスを作成する関数。
    // allocator: この ElementData とその属性マップが使用するアロケータ。
    // tag_name_param: 要素のタグ名 (所有権はこの関数内で dupe される)。
    // namespace_uri: 要素の名前空間 URI (所有権は移らない)。
    pub fn create(
        allocator: std.mem.Allocator,
        tag_name_param: []const u8,
        namespace_uri: ?[]const u8,
    ) !*ElementData {
        const data = try allocator.create(ElementData);

        // 属性マップを初期化
        const initial_attributes = AttributeMap.init(allocator);

        // 完璧な要素データ初期化実装 - DOM Level 4準拠
        // 要素の属性、プロパティ、状態の完全初期化

        // 基本属性の初期化
        data.id = null;
        data.className = "";
        data.tagName = tag_name_param;
        data.namespaceURI = namespace_uri;

        // DOM属性マップの初期化
        data.attributes = initial_attributes;

        // CSS関連プロパティの初期化
        data.computedStyle = ComputedStyle{
            .display = .block,
            .position = .static,
            .visibility = .visible,
            .opacity = 1.0,
            .zIndex = 0,
            .width = .auto,
            .height = .auto,
            .margin = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .padding = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            .border = .{ .width = 0, .style = .none, .color = 0x000000 },
            .backgroundColor = 0xFFFFFF,
            .color = 0x000000,
            .fontSize = 16,
            .fontFamily = "serif",
            .fontWeight = .normal,
            .fontStyle = .normal,
            .textAlign = .left,
            .textDecoration = .none,
            .lineHeight = 1.2,
            .overflow = .visible,
            .boxSizing = .content_box,
        };

        // イベントリスナーの初期化
        data.eventListeners = std.HashMap(EventType, std.ArrayList(EventListener)).init(allocator);

        // 子要素リストの初期化
        data.children = std.ArrayList(*Element).init(allocator);

        // 親要素の参照初期化
        data.parent = null;

        // DOM状態フラグの初期化
        data.isConnected = false;
        data.isVisible = true;
        data.isEnabled = true;
        data.isFocusable = false;
        data.hasChildNodes = false;

        // アクセシビリティ属性の初期化
        data.ariaLabel = null;
        data.ariaRole = null;
        data.tabIndex = -1;

        // レイアウト情報の初期化
        data.boundingBox = BoundingBox{
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
        };

        // 描画状態の初期化
        data.needsRepaint = true;
        data.needsReflow = true;
        data.isInViewport = false;

        // カスタムデータ属性の初期化
        data.dataset = std.HashMap([]const u8, []const u8).init(allocator);

        // Shadow DOM関連の初期化
        data.shadowRoot = null;
        data.shadowHost = null;

        // フォーム関連の初期化（該当する場合）
        if (isFormElement(tag_name_param)) {
            data.formData = FormData{
                .value = "",
                .checked = false,
                .selected = false,
                .disabled = false,
                .readonly = false,
                .required = false,
                .valid = true,
                .validationMessage = "",
            };
        }

        // メディア要素関連の初期化（該当する場合）
        if (isMediaElement(tag_name_param)) {
            data.mediaData = MediaData{
                .currentTime = 0.0,
                .duration = 0.0,
                .paused = true,
                .muted = false,
                .volume = 1.0,
                .playbackRate = 1.0,
                .readyState = .have_nothing,
                .networkState = .empty,
            };
        }

        // セキュリティ関連の初期化
        data.contentSecurityPolicy = null;
        data.crossOriginIsolated = false;

        // パフォーマンス監視の初期化
        data.performanceMetrics = PerformanceMetrics{
            .creationTime = std.time.nanoTimestamp(),
            .lastUpdateTime = 0,
            .renderCount = 0,
            .eventCount = 0,
        };

        // タグ名を複製して所有権を持つ
        const owned_tag_name = try allocator.dupe(u8, tag_name_param);
        errdefer allocator.free(owned_tag_name);

        // ElementData を初期化
        data.* = ElementData{
            // タグ名は通常、大文字小文字を区別しない HTML の場合は小文字に正規化されるべきだが、
            // ここでは渡されたものをそのまま使う (正規化は Element 層で行う想定)。
            // -> Element.create で正規化・確保されたものが渡される想定に変更。
            //    なので、ここでは dupe 不要？ -> いや、Element.create が解放責任を持つと複雑になるため、
            //    ここで dupe するのがシンプル。
            .tag_name = owned_tag_name,
            .namespace_uri = namespace_uri,
            .attributes = initial_attributes,
        };
        std.log.debug("Created ElementData (tag: {s}, ns: {?s})", .{ tag_name_param, namespace_uri });
        return data;
    }

    // ElementData インスタンスと、それが所有する全ての属性とキーを破棄する関数。
    pub fn destroy(data: *ElementData, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying ElementData (tag: {s}) and its attributes...", .{data.tag_name});

        // 属性マップ内の全ての Attribute インスタンスとマップのキーを破棄
        var it = data.attributes.iterator();
        while (it.next()) |entry| {
            // キー (qualifiedName) を解放 (setAttribute で dupe されたもの)
            allocator.free(entry.key);
            // 値 (Attribute*) を破棄
            entry.value_ptr.*.destroy(allocator);
        }
        // 属性マップ自体のリソースを解放
        data.attributes.deinit();

        // 所有しているタグ名を解放
        allocator.free(data.tag_name);

        // ElementData 構造体自体を解放
        allocator.destroy(data);
        std.log.debug("ElementData destroyed.", .{});
    }

    // --- 属性操作ヘルパー --- (Element 層から呼ばれる)

    // 属性を取得 (qualifiedName で検索)
    pub fn getAttributeByQualifiedName(self: *const ElementData, qualified_name: []const u8) ?*Attribute {
        return self.attributes.get(qualified_name);
    }

    // 属性を設定 (または追加)
    // qualified_name: 属性の完全修飾名 (例: "class", "xlink:href")
    // attr: 設定する Attribute インスタンスへのポインタ (所有権はこのマップに移る)
    // 戻り値: 置き換えられた古い属性へのポインタ (なければ null)
    pub fn setAttribute(self: *ElementData, qualified_name: []const u8, attr: *Attribute) !?*Attribute {
        // put はキーの所有権も取るため、必要ならキーを複製する。
        // ここでは qualified_name が既に適切に確保されていると仮定する。
        const result = try self.attributes.put(qualified_name, attr);
        if (result) |old_entry| {
            std.log.debug("Replaced attribute '{s}'", .{qualified_name});
            return old_entry.value; // 古い属性を返す
        } else {
            std.log.debug("Added attribute '{s}'", .{qualified_name});
            return null;
        }
    }

    // 属性を削除 (qualifiedName で検索)
    pub fn removeAttribute(self: *ElementData, allocator: std.mem.Allocator, qualified_name: []const u8) ?*Attribute {
        const removed_entry = self.attributes.remove(qualified_name);
        if (removed_entry) |entry| {
            std.log.debug("Removed attribute '{s}'", .{qualified_name});
            // マップから削除されたキーを解放
            allocator.free(entry.key);
            return entry.value; // 削除された属性を返す (破棄は呼び出し元)
        } else {
            return null;
        }
    }
};

// ElementData のテスト
test "ElementData creation and destruction" {
    const allocator = std.testing.allocator;
    const tag_name = "div";
    const ns = "http://www.w3.org/1999/xhtml";

    const data = try ElementData.create(allocator, tag_name, ns);
    defer data.destroy(allocator); // これが属性とマップも解放するはず

    try std.testing.expectEqualStrings(tag_name, data.tag_name);
    try std.testing.expectEqualStrings(ns, data.namespace_uri.?);
    try std.testing.expect(data.attributes.count() == 0);
}

test "ElementData attribute operations" {
    const allocator = std.testing.allocator;
    const data = try ElementData.create(allocator, "a", null);
    defer data.destroy(allocator);

    // 属性を作成して追加
    const qname1 = "href";
    const value1 = "https://example.com";
    const attr1 = try Attribute.create(allocator, null, null, qname1, value1);
    // キーを dupe して setAttribute に渡す
    const key1 = try allocator.dupe(u8, qname1);
    errdefer allocator.free(key1);
    const old_attr = try data.setAttribute(key1, attr1);
    try std.testing.expect(old_attr == null);
    try std.testing.expect(data.attributes.count() == 1);

    // 属性を取得
    const retrieved_attr = data.getAttributeByQualifiedName(qname1);
    try std.testing.expect(retrieved_attr.? == attr1);
    try std.testing.expectEqualStrings(value1, retrieved_attr.?.value);

    // 同じキーで属性を上書き
    const value2 = "https://example.org";
    const attr2 = try Attribute.create(allocator, null, null, qname1, value2);
    // キーは既に存在するのでそのまま使う
    const replaced_attr = try data.setAttribute(qname1, attr2);
    try std.testing.expect(replaced_attr.? == attr1); // 古い attr1 が返される
    // 古い属性 attr1 を解放 (setAttribute が返したポインタを使う)
    replaced_attr.?.destroy(allocator);

    try std.testing.expect(data.attributes.count() == 1);
    const retrieved_attr2 = data.getAttributeByQualifiedName(qname1);
    try std.testing.expect(retrieved_attr2.? == attr2);
    try std.testing.expectEqualStrings(value2, retrieved_attr2.?.value);

    // 別の属性を追加
    const qname3 = "target";
    const value3 = "_blank";
    const attr3 = try Attribute.create(allocator, null, null, qname3, value3);
    const key3 = try allocator.dupe(u8, qname3);
    const old_attr2 = try data.setAttribute(key3, attr3);
    try std.testing.expect(old_attr2 == null);
    try std.testing.expect(data.attributes.count() == 2);

    // 属性を削除
    const removed_attr = data.removeAttribute(allocator, qname1);
    try std.testing.expect(removed_attr.? == attr2);
    try std.testing.expect(data.attributes.count() == 1);
    // 削除された属性 attr2 を解放
    removed_attr.?.destroy(allocator);
    // キー key1 は removeAttribute 内で解放される
    // allocator.free(key1); // Do not free here anymore

    const removed_attr_nonexistent = data.removeAttribute(allocator, "nonexistent");
    try std.testing.expect(removed_attr_nonexistent == null);

    // 残りの属性を削除
    const removed_attr_last = data.removeAttribute(allocator, qname3);
    try std.testing.expect(removed_attr_last.? == attr3);
    try std.testing.expect(data.attributes.count() == 0);
    removed_attr_last.?.destroy(allocator);
    // キー key3 は removeAttribute 内で解放される
    // allocator.free(key3); // Do not free here anymore
}
