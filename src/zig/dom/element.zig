// src/zig/dom/element.zig
// DOM の Element インターフェースに対応する構造体を定義します。
// https://dom.spec.whatwg.org/#interface-element

const std = @import("std");
const mem = @import("../memory/allocator.zig"); // Global allocator
const errors = @import("../util/error.zig"); // Common errors
const Node = @import("./node.zig").Node;
const NodeType = @import("./node_type.zig").NodeType;
const Document = @import("./document.zig").Document;
const Attribute = @import("./attribute.zig").Attribute;
const ElementData = @import("./element_data.zig").ElementData;
const AttributeMap = @import("./element_data.zig").AttributeMap;
const HTMLElement = @import("./elements/html_element.zig").HTMLElement;
const HTMLAnchorElement = @import("./elements/html_anchor_element.zig").HTMLAnchorElement;
const HTMLDivElement = @import("./elements/html_div_element.zig").HTMLDivElement;
const HTMLSpanElement = @import("./elements/html_span_element.zig").HTMLSpanElement;
const HTMLImageElement = @import("./elements/html_image_element.zig").HTMLImageElement;
const HTMLInputElement = @import("./elements/html_input_element.zig").HTMLInputElement;
const HTMLButtonElement = @import("./elements/html_button_element.zig").HTMLButtonElement;
const HTMLFormElement = @import("./elements/html_form_element.zig").HTMLFormElement;
const HTMLHeadingElement = @import("./elements/html_heading_element.zig").HTMLHeadingElement;
const HTMLParagraphElement = @import("./elements/html_paragraph_element.zig").HTMLParagraphElement;
const HTMLScriptElement = @import("./elements/html_script_element.zig").HTMLScriptElement;
const HTMLStyleElement = @import("./elements/html_style_element.zig").HTMLStyleElement;
const HTMLTableElement = @import("./elements/html_table_element.zig").HTMLTableElement;
const HTMLCollection = std.ArrayList(*Node); // HTMLCollection の型エイリアス
const validation = @import("../util/validation.zig");
const MutationRecord = @import("./mutations/mutation_record.zig").MutationRecord;
const MutationType = @import("./mutations/mutation_record.zig").MutationType;
const NodeList = std.ArrayList(*Node);
const CSSSelector = @import("./cssselector.zig");

// HTML Namespace URI
const html_ns = "http://www.w3.org/1999/xhtml";

// --- HTML 要素の具象型を保持するための Tagged Union ---
pub const HTMLSpecificData = union(enum) {
    none: void, // HTML 要素ではない、または不明な要素
    generic: *HTMLElement, // 汎用 HTMLElement
    div: *HTMLDivElement,
    span: *HTMLSpanElement,
    a: *HTMLAnchorElement,
    img: *HTMLImageElement,
    input: *HTMLInputElement,
    button: *HTMLButtonElement,
    form: *HTMLFormElement,
    h1: *HTMLHeadingElement,
    h2: *HTMLHeadingElement,
    h3: *HTMLHeadingElement,
    h4: *HTMLHeadingElement,
    h5: *HTMLHeadingElement,
    h6: *HTMLHeadingElement,
    p: *HTMLParagraphElement,
    script: *HTMLScriptElement,
    style: *HTMLStyleElement,
    table: *HTMLTableElement,

    // Union が保持するポインタに基づいて destroy を呼び出すヘルパー
    // Node.destroyRecursive から呼び出される
    pub fn destroy(self: HTMLSpecificData, allocator: std.mem.Allocator) void {
        switch (self) {
            .none => {},
            .generic => |ptr| ptr.destroy(allocator),
            .div => |ptr| ptr.destroy(allocator),
            .span => |ptr| ptr.destroy(allocator),
            .a => |ptr| ptr.destroy(allocator),
            .img => |ptr| ptr.destroy(allocator),
            .input => |ptr| ptr.destroy(allocator),
            .button => |ptr| ptr.destroy(allocator),
            .form => |ptr| ptr.destroy(allocator),
            .h1 => |ptr| ptr.destroy(allocator),
            .h2 => |ptr| ptr.destroy(allocator),
            .h3 => |ptr| ptr.destroy(allocator),
            .h4 => |ptr| ptr.destroy(allocator),
            .h5 => |ptr| ptr.destroy(allocator),
            .h6 => |ptr| ptr.destroy(allocator),
            .p => |ptr| ptr.destroy(allocator),
            .script => |ptr| ptr.destroy(allocator),
            .style => |ptr| ptr.destroy(allocator),
            .table => |ptr| ptr.destroy(allocator),
        }
    }

    // HTMLElement へのポインタを取得するヘルパー (キャスト用)
    pub fn getBaseHTMLElement(self: HTMLSpecificData) ?*HTMLElement {
        return switch (self) {
            .none => null,
            .generic => |ptr| ptr,
            .div => |ptr| &ptr.base,
            .span => |ptr| &ptr.base,
            .a => |ptr| &ptr.base,
            .img => |ptr| &ptr.base,
            .input => |ptr| &ptr.base,
            .button => |ptr| &ptr.base,
            .form => |ptr| &ptr.base,
            .h1 => |ptr| &ptr.base,
            .h2 => |ptr| &ptr.base,
            .h3 => |ptr| &ptr.base,
            .h4 => |ptr| &ptr.base,
            .h5 => |ptr| &ptr.base,
            .h6 => |ptr| &ptr.base,
            .p => |ptr| &ptr.base,
            .script => |ptr| &ptr.base,
            .style => |ptr| &ptr.base,
            .table => |ptr| &ptr.base,
        };
    }
};

// Element 構造体。
// Node.specific_data からキャストして利用される。
// Node は含まず、Element 固有のデータのみを持つ。
pub const Element = struct {
    // この Element に固有のデータ。
    data: *ElementData,
    // この Element に関連付けられた Node へのポインタ (逆参照用)
    // Node.specific_data が Element* を指すため、通常は不要かもしれないが、
    // Element* から Node* へのアクセスを容易にするために保持する。
    // メモリ管理: このポインタは参照のみで、所有権は持たない。
    //            関連する Node が破棄される際に null 化される必要があるか検討。
    //            -> Node 破棄時に specific_data 経由で Element.destroy が呼ばれるため、
    //               通常は Element が先に破棄される。
    //            -> 設計上、Node と Element は 1:1 で生成・破棄される前提。
    node_ptr: *Node, // Node へのポインタを追加
    // HTML 要素の場合、具象型データへのポインタを保持する Union
    html_data: HTMLSpecificData = .none, // 型を ?*HTMLElement から変更し、デフォルトを .none に
    // アクセシビリティ属性
    role: ?[]const u8 = null,
    tabindex: ?i32 = null,
    aria_attributes: ?std.StringHashMap([]const u8) = null,

    // Element インスタンスを作成する関数。
    // Node も同時に作成し、*Node を返す。
    pub fn create(
        allocator: std.mem.Allocator,
        owner_document: *Document,
        local_name: []const u8,
        namespace_uri: ?[]const u8,
        prefix: ?[]const u8,
    ) !*Node { // 戻り値を *Node に変更
        // 要素名とプレフィックスを検証 (NCName)
        try validation.validateNCName(local_name);
        if (prefix) |p| {
            try validation.validateNCName(p);
        }
        // namespace と prefix の組み合わせ検証は setAttributeNS などで行う想定
        // (またはここで validation.validateNamespaceAndPrefix を呼び出す)

        var qualified_name_slice: []const u8 = undefined;
        var actual_ns = namespace_uri;
        var actual_local_name = local_name;
        var should_free_local_name = false;
        var should_free_qualified_name = false;

        if (namespace_uri == null or std.mem.eql(u8, namespace_uri.?, html_ns)) {
            actual_local_name = try std.ascii.allocLowerString(allocator, local_name);
            should_free_local_name = true;
            qualified_name_slice = actual_local_name;
            actual_ns = html_ns;
        } else {
            actual_local_name = local_name;
            if (prefix) |p| {
                qualified_name_slice = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ p, local_name });
                should_free_qualified_name = true;
            } else {
                qualified_name_slice = try allocator.dupe(u8, local_name);
                should_free_qualified_name = true;
            }
        }
        errdefer {
            if (should_free_local_name) allocator.free(actual_local_name);
            if (should_free_qualified_name) allocator.free(qualified_name_slice);
        }

        // 1. ElementData を作成
        const element_data = try ElementData.create(allocator, qualified_name_slice, actual_ns);
        errdefer element_data.destroy(allocator);

        // Element.create で確保した一時的な名前を解放
        if (should_free_local_name) allocator.free(actual_local_name);
        if (should_free_qualified_name) allocator.free(qualified_name_slice);

        // 2. Element 構造体を確保
        const element = try allocator.create(Element);
        errdefer allocator.destroy(element);

        // 3. Node を作成 (specific_data に element を設定)
        const node = try Node.create(allocator, .element_node, owner_document, @ptrCast(element));
        // Node 作成失敗時は Element も ElementData も破棄される (上記の errdefer)

        // 4. Element を初期化し、Node へのポインタを設定
        element.* = Element{
            .data = element_data,
            .node_ptr = node,
            .html_data = .none, // まず none で初期化
            .role = null,
            .tabindex = null,
            .aria_attributes = std.StringHashMap([]const u8).init(allocator),
        };

        // 5. HTML 要素の場合、HTMLElement と具象要素を作成して関連付ける
        if (actual_ns != null and std.mem.eql(u8, actual_ns.?, html_ns)) {
            // まずベース HTMLElement を作成
            const base_html_element = try HTMLElement.create(allocator, element);
            // エラー時: Node, Element, ElementData は既に errdefer で解放される
            // ここでは base_html_element の解放のみ考慮
            errdefer base_html_element.destroy(allocator);

            // タグ名に基づいて具象型を決定し、Union に格納
            if (std.mem.eql(u8, element.data.tag_name, "div")) {
                const div_element = try HTMLDivElement.create(allocator, base_html_element.*);
                errdefer div_element.destroy(allocator); // 具象型の解放も必要
                element.html_data = .{ .div = div_element };
            } else if (std.mem.eql(u8, element.data.tag_name, "span")) {
                const span_element = try HTMLSpanElement.create(allocator, base_html_element.*);
                errdefer span_element.destroy(allocator);
                element.html_data = .{ .span = span_element };
            } else if (std.mem.eql(u8, element.data.tag_name, "a")) {
                const anchor_element = try HTMLAnchorElement.create(allocator, base_html_element.*);
                errdefer anchor_element.destroy(allocator);
                element.html_data = .{ .a = anchor_element };
            } else {
                // 不明な HTML タグは generic として扱う
                element.html_data = .{ .generic = base_html_element };
            }
            // 注意: Union に値が設定された後は、errdefer で base_html_element を直接 destroy すると
            //       二重解放になる可能性がある (Union の destroy ヘルパーが呼ばれるため)。
            //       -> Union の設定前に base_html_element がエラーで解放されるケースと、
            //          Union 設定後に他のエラーで解放されるケースを正しく処理する必要がある。
            //       -> より安全なのは、Union 設定後に base_html_element の errdefer を解除するか、
            //          Element の errdefer 内で Union をチェックして解放すること。
            //       -> 現状の errdefer は、ここでのエラー時にのみ有効 (Node 作成前に失敗した場合)。
            //          Node 作成後にエラーが発生した場合、Node.destroyRecursive が Union を解放する。
        }

        std.log.debug("Created Element <{s}> (ns: {?s}) and associated Node", .{ qualified_name_slice, actual_ns });
        return node; // Node へのポインタを返す
    }

    // Element インスタンスと関連データを破棄する関数。
    // Node.destroyRecursive から specific_data を介して呼ばれる想定。
    // この関数は Element 構造体自身と ElementData のみを解放する。
    // Node 構造体自体の解放は Node.destroyRecursive が行う。
    pub fn destroy(element: *Element, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying Element data <{s}>", .{element.data.tag_name});

        // 1. ElementData を破棄 (属性を含む)
        element.data.destroy(allocator);

        // 2. Element 構造体自身を解放
        allocator.destroy(element);
    }

    // --- DOM Element API (属性操作) --- Access Node via self.node_ptr

    // 属性値を取得 (HTMLでは名前は小文字)
    pub fn getAttribute(self: *const Element, name: []const u8) ?[]const u8 {
        // HTML Namespace かどうかは self.data.namespace_uri で判定可能
        const is_html = self.data.namespace_uri != null and std.mem.eql(u8, self.data.namespace_uri.?, html_ns);
        var search_name = name;
        var lower_name_buf: [128]u8 = undefined; // Allocate buffer on stack if possible
        var lower_name_slice: []u8 = undefined;

        if (is_html) {
            // Try using stack buffer first
            if (name.len <= lower_name_buf.len) {
                lower_name_slice = std.ascii.lowerString(lower_name_buf[0..name.len], name);
                search_name = lower_name_slice;
            } else {
                // Fallback to heap allocation if name is too long (should be rare)
                // Need allocator -> get from node? Requires changing self to *Element
                // For now, just use original name if too long (suboptimal for HTML)
                // std.log.warn("Attribute name too long for stack buffer in getAttribute (HTML): {s}", .{name});
                search_name = name;
            }
        }

        const attr = self.getAttributeNodeNS(null, search_name);
        return if (attr) |a| a.value else null;
    }

    // 属性値を設定 (HTMLでは名前は小文字)
    pub fn setAttribute(self: *Element, name: []const u8, value: []const u8) !void {
        const allocator = self.node_ptr.owner_document.?.allocator;
        // ... (検証と名前の準備) ...
        var attr_name_key: []const u8 = undefined;
        const is_html = self.data.namespace_uri != null and std.mem.eql(u8, self.data.namespace_uri.?, html_ns);

        if (is_html) {
            attr_name_key = try std.ascii.allocLowerString(allocator, name);
        } else {
            attr_name_key = try allocator.dupe(u8, name);
        }
        errdefer allocator.free(attr_name_key);

        var existing_attr: ?*Attribute = null;
        var existing_key: ?[]const u8 = null;
        var old_value: ?[]const u8 = null;
        var it = self.data.attributes.iterator();
        while (it.next()) |entry| {
            const matches = if (is_html) entry.value_ptr.*.matchesHTML(attr_name_key) else std.mem.eql(u8, entry.key, attr_name_key);
            if (matches) {
                existing_attr = entry.value_ptr.*;
                existing_key = entry.key;
                old_value = try allocator.dupe(u8, existing_attr.?.value); // 古い値をコピー (エラー時は解放)
                errdefer allocator.free(old_value.?);
                break;
            }
        }

        if (existing_attr) |attr| {
            const new_value = try allocator.dupe(u8, value);
            // 属性値の変更前に古い値を記録
            attr.setValue(allocator, new_value);
            allocator.free(attr_name_key); // HTML の場合解放
            // --- MutationObserver 通知 (変更) ---
            self.queueAttributeMutation(attr_name_key, old_value);
            allocator.free(old_value.?); // コピーした古い値を解放
        } else {
            const new_value = try allocator.dupe(u8, value);
            errdefer allocator.free(new_value);
            const new_attr = try Attribute.create(allocator, null, null, attr_name_key, new_value);
            errdefer new_attr.destroy(allocator);
            // 属性キーの所有権は new_attr に移る (Attribute.create 内で dupe されるべき)
            // allocator.free(attr_name_key); // 不要
            new_attr.owner_element = self;
            const old = try self.data.setAttribute(attr_name_key, new_attr);
            std.debug.assert(old == null);
            // --- MutationObserver 通知 (追加) ---
            self.queueAttributeMutation(attr_name_key, null);
        }
    }

    // 属性を削除 (HTMLでは名前は小文字)
    pub fn removeAttribute(self: *Element, name: []const u8) !void {
        const allocator = self.node_ptr.owner_document.?.allocator;
        var key_to_remove: ?[]const u8 = null;
        var attr_to_remove: ?*Attribute = null;
        const is_html = self.data.namespace_uri != null and std.mem.eql(u8, self.data.namespace_uri.?, html_ns);
        var search_name_slice: []const u8 = undefined;
        var lower_name_buf: [128]u8 = undefined;

        if (is_html) {
            if (name.len <= lower_name_buf.len) {
                search_name_slice = std.ascii.lowerString(lower_name_buf[0..name.len], name);
            } else {
                search_name_slice = name; // Fallback
            }
        } else {
            search_name_slice = name;
        }

        var it = self.data.attributes.iterator();
        while (it.next()) |entry| {
            const matches = if (is_html) entry.value_ptr.*.matchesHTML(search_name_slice) else std.mem.eql(u8, entry.key, search_name_slice);
            if (matches) {
                key_to_remove = entry.key;
                attr_to_remove = entry.value_ptr.*;
                break;
            }
        }

        if (attr_to_remove) |attr| {
            const old_value_copy = try allocator.dupe(u8, attr.value);
            errdefer allocator.free(old_value_copy);
            const removed = self.data.removeAttribute(allocator, key_to_remove.?);
            std.debug.assert(removed.? == attr);
            attr.destroy(allocator);
            // --- MutationObserver 通知 ---
            self.queueAttributeMutation(key_to_remove.?, old_value_copy);
            allocator.free(old_value_copy); // コピーした古い値を解放
        } else {
            // 何もしない
        }
    }

    // 属性が存在するか確認 (HTMLでは名前は小文字)
    pub fn hasAttribute(self: *const Element, name: []const u8) bool {
        // const lower_name = std.ascii.lowerString(name); // Requires allocation or buffer
        var lower_name_buf: [128]u8 = undefined;
        var search_name_slice: []const u8 = undefined;
        const is_html = self.data.namespace_uri != null and std.mem.eql(u8, self.data.namespace_uri.?, html_ns);

        if (is_html) {
            if (name.len <= lower_name_buf.len) {
                search_name_slice = std.ascii.lowerString(lower_name_buf[0..name.len], name);
            } else {
                search_name_slice = name; // Fallback
            }
        } else {
            search_name_slice = name;
        }

        var it = self.data.attributes.iterator();
        while (it.next()) |entry| {
            if (is_html) {
                if (entry.value_ptr.*.matchesHTML(search_name_slice)) return true;
            } else {
                if (std.mem.eql(u8, entry.key, search_name_slice)) return true;
            }
        }
        return false;
    }

    // 属性ノードを取得 (名前空間付き)
    pub fn getAttributeNodeNS(self: *const Element, namespace_uri: ?[]const u8, local_name: []const u8) ?*Attribute {
        var it = self.data.attributes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.matches(namespace_uri, local_name)) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }

    // 属性ノードを設定 (名前空間付き)
    pub fn setAttributeNodeNS(self: *Element, attr: *Attribute) !?*Attribute {
        if (attr.owner_element != null and attr.owner_element != self) {
            return errors.DomError.InUseAttributeError;
        }
        const allocator = self.node_ptr.owner_document.?.allocator;

        var old_attr: ?*Attribute = null;
        var old_qualified_name: ?[]const u8 = null;
        var old_value: ?[]const u8 = null;
        var it = self.data.attributes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.matches(attr.namespace_uri, attr.local_name)) {
                old_attr = entry.value_ptr.*;
                old_qualified_name = entry.key;
                old_value = try allocator.dupe(u8, old_attr.value);
                errdefer allocator.free(old_value.?);
                break;
            }
        }

        // 新しい属性の qualifiedName を計算 (所有権は attribute が持つ想定に修正)
        const new_qualified_name = attr.qualifiedName(); // Attribute.qualifiedName を想定
        errdefer allocator.free(new_qualified_name); // If put fails

        attr.owner_element = self;

        // put はキーの所有権を取る
        const replaced = try self.data.setAttribute(new_qualified_name, attr);

        if (old_attr) |old| {
            // 古いエントリが存在し、かつ新しいエントリとキーが異なる場合、古いキーで削除
            if (old_qualified_name != null and !std.mem.eql(u8, old_qualified_name.?, new_qualified_name)) {
                const removed_old = self.data.removeAttribute(allocator, old_qualified_name.?);
                std.debug.assert(removed_old.? == old);
            }
            std.debug.assert(replaced.? == old);
            // --- MutationObserver 通知 (変更) ---
            self.queueAttributeMutation(old_qualified_name.?, old_value);
            if (old_value) |ov| allocator.free(ov); // コピーした古い値を解放
            return old;
        } else {
            std.debug.assert(replaced == null);
            // --- MutationObserver 通知 (追加) ---
            self.queueAttributeMutation(new_qualified_name, null);
            return null;
        }
    }

    // 属性ノードを削除 (名前空間付き)
    pub fn removeAttributeNode(self: *Element, attr: *Attribute) !*Attribute {
        var qualified_name_to_remove: ?[]const u8 = null;
        var found = false;
        var it = self.data.attributes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == attr) {
                qualified_name_to_remove = entry.key;
                found = true;
                break;
            }
        }

        if (found) {
            const allocator = self.node_ptr.owner_document.?.allocator;
            const old_value_copy = try allocator.dupe(u8, attr.value);
            errdefer allocator.free(old_value_copy);
            const removed = self.data.removeAttribute(allocator, qualified_name_to_remove.?);
            std.debug.assert(removed.? == attr);
            attr.owner_element = null;
            // --- MutationObserver 通知 ---
            self.queueAttributeMutation(qualified_name_to_remove.?, old_value_copy);
            allocator.free(old_value_copy);
            return attr;
        } else {
            return errors.DomError.NotFoundError;
        }
    }
    // --- 内部ヘルパー: 属性変更 MutationRecord キューイング ---
    fn queueAttributeMutation(self: *Element, attribute_name: []const u8, old_value: ?[]const u8) void {
        if (self.node_ptr.owner_document) |doc| {
            const allocator = doc.allocator;
            // レコードを作成 (エラー時はログ出力して処理継続)
            var record = MutationRecord.create(allocator, .attributes, self.node_ptr) catch |err| {
                std.log.err("属性変更の MutationRecord 作成に失敗: {}", .{err});
                return;
            };

            record.attributeName = attribute_name; // 属性名は参照のみ（コピーしない）
            record.oldValue = old_value; // 古い値の所有権を移譲

            // Document のキューに追加
            doc.queueMutationRecord(record) catch |err| {
                std.log.err("属性変更の MutationRecord キューイングに失敗: {}", .{err});
                // キューイング失敗時はレコードを破棄
                record.destroy();
                // old_value の所有権はこの関数が持つため、失敗時は解放する
                if (old_value) |ov| allocator.free(ov);
            };
        } else {
            // ownerDocument がない場合は何もしない
            // （通常は発生しないはずだが、安全のため）
        }
    }

    // --- 他の Element API ---
    pub fn tagName(self: *const Element) ![]const u8 {
        const allocator = self.node_ptr.owner_document.?.allocator;
        if (self.data.namespace_uri != null and std.mem.eql(u8, self.data.namespace_uri.?, html_ns)) {
            // HTML要素の場合は大文字で返す
            return std.ascii.allocUpperString(allocator, self.data.tag_name);
        } else {
            // HTML以外はそのまま返す
            return self.data.tag_name;
        }
    }

    /// この Element を HTMLElement として取得します
    pub fn asHTMLElement(self: *const Element) ?*HTMLElement {
        return self.html_data.getBaseHTMLElement();
    }

    /// この Element を HTMLAnchorElement として取得します
    pub fn asHTMLAnchorElement(self: *const Element) !?*HTMLAnchorElement {
        return switch (self.html_data) {
            .a => |ptr| ptr,
            else => null,
        };
    }

    /// この Element を HTMLDivElement として取得します
    pub fn asHTMLDivElement(self: *const Element) !?*HTMLDivElement {
        return switch (self.html_data) {
            .div => |ptr| ptr,
            else => null,
        };
    }

    /// この Element を HTMLSpanElement として取得します
    pub fn asHTMLSpanElement(self: *const Element) !?*HTMLSpanElement {
        return switch (self.html_data) {
            .span => |ptr| ptr,
            else => null,
        };
    }

    /// この Element を HTMLImageElement として取得します
    pub fn asHTMLImageElement(self: *const Element) !?*HTMLImageElement {
        return switch (self.html_data) {
            .img => |ptr| ptr,
            else => null,
        };
    }

    /// この Element を HTMLInputElement として取得します
    pub fn asHTMLInputElement(self: *const Element) !?*HTMLInputElement {
        return switch (self.html_data) {
            .input => |ptr| ptr,
            else => null,
        };
    }

    /// この Element を HTMLButtonElement として取得します
    pub fn asHTMLButtonElement(self: *const Element) !?*HTMLButtonElement {
        return switch (self.html_data) {
            .button => |ptr| ptr,
            else => null,
        };
    }

    /// この Element を HTMLFormElement として取得します
    pub fn asHTMLFormElement(self: *const Element) !?*HTMLFormElement {
        return switch (self.html_data) {
            .form => |ptr| ptr,
            else => null,
        };
    }

    /// この Element を HTMLHeadingElement として取得します
    pub fn asHTMLHeadingElement(self: *const Element) !?*HTMLHeadingElement {
        return switch (self.html_data) {
            .h1, .h2, .h3, .h4, .h5, .h6 => |ptr| ptr,
            else => null,
        };
    }

    /// この Element を HTMLParagraphElement として取得します
    pub fn asHTMLParagraphElement(self: *const Element) !?*HTMLParagraphElement {
        return switch (self.html_data) {
            .p => |ptr| ptr,
            else => null,
        };
    }

    /// この Element を HTMLScriptElement として取得します
    pub fn asHTMLScriptElement(self: *const Element) !?*HTMLScriptElement {
        return switch (self.html_data) {
            .script => |ptr| ptr,
            else => null,
        };
    }

    /// この Element を HTMLStyleElement として取得します
    pub fn asHTMLStyleElement(self: *const Element) !?*HTMLStyleElement {
        return switch (self.html_data) {
            .style => |ptr| ptr,
            else => null,
        };
    }

    /// この Element を HTMLTableElement として取得します
    pub fn asHTMLTableElement(self: *const Element) !?*HTMLTableElement {
        return switch (self.html_data) {
            .table => |ptr| ptr,
            else => null,
        };
    }

    /// タグ名で子要素を検索します
    pub fn getElementsByTagName(self: *Element, tag_name: []const u8) !*HTMLCollection {
        const allocator = self.node_ptr.owner_document.?.allocator;
        var collection = try HTMLCollection.create(allocator);
        errdefer collection.destroy();

        // 子ノードを再帰的に検索
        try self.collectElementsByTagName(tag_name, collection);

        return collection;
    }

    // 内部ヘルパー: タグ名で要素を収集
    fn collectElementsByTagName(self: *Element, tag_name: []const u8, collection: *HTMLCollection) !void {
        var child = self.node_ptr.first_child;
        while (child != null) : (child = child.?.next_sibling) {
            if (child.?.node_type == .element_node) {
                const child_elem: *Element = @ptrCast(@alignCast(child.?.specific_data.?));

                // タグ名が一致するか、"*"（全要素）の場合は追加
                if (std.mem.eql(u8, tag_name, "*") or
                    std.ascii.eqlIgnoreCase(child_elem.data.tag_name, tag_name))
                {
                    try collection.append(child.?);
                }

                // 子要素も再帰的に検索
                try child_elem.collectElementsByTagName(tag_name, collection);
            }
        }
    }

    /// CSSセレクタで最初の要素を検索します
    pub fn querySelector(self: *Element, selector: []const u8) !?*Element {
        // セレクタパーサーとマッチャーを初期化
        const allocator = self.node_ptr.owner_document.?.allocator;
        var parser = try CSSSelector.Parser.init(allocator, selector);
        defer parser.deinit();

        var selector_list = try parser.parse();
        defer selector_list.deinit();

        // 最初にマッチする要素を検索
        return self.querySelectorImpl(selector_list);
    }

    // 内部実装: セレクタマッチング
    fn querySelectorImpl(self: *Element, selector_list: CSSSelector.SelectorList) !?*Element {
        var child = self.node_ptr.first_child;
        while (child != null) : (child = child.?.next_sibling) {
            if (child.?.node_type == .element_node) {
                const child_elem: *Element = @ptrCast(@alignCast(child.?.specific_data.?));

                // この要素がセレクタにマッチするか確認
                if (selector_list.matches(child_elem)) {
                    return child_elem;
                }

                // 子孫要素も検索
                if (try child_elem.querySelectorImpl(selector_list)) |match| {
                    return match;
                }
            }
        }

        return null;
    }

    /// CSSセレクタで全ての要素を検索します
    pub fn querySelectorAll(self: *Element, selector: []const u8) !*NodeList {
        const allocator = self.node_ptr.owner_document.?.allocator;
        var result = try NodeList.create(allocator);
        errdefer result.destroy();

        // セレクタパーサーとマッチャーを初期化
        var parser = try CSSSelector.Parser.init(allocator, selector);
        defer parser.deinit();

        var selector_list = try parser.parse();
        defer selector_list.deinit();

        // マッチする全要素を収集
        try self.querySelectorAllImpl(selector_list, result);

        return result;
    }

    // 内部実装: 全マッチング要素収集
    fn querySelectorAllImpl(self: *Element, selector_list: CSSSelector.SelectorList, result: *NodeList) !void {
        var child = self.node_ptr.first_child;
        while (child != null) : (child = child.?.next_sibling) {
            if (child.?.node_type == .element_node) {
                const child_elem: *Element = @ptrCast(@alignCast(child.?.specific_data.?));

                // この要素がセレクタにマッチするか確認
                if (selector_list.matches(child_elem)) {
                    try result.append(child.?);
                }

                // 子孫要素も検索
                try child_elem.querySelectorAllImpl(selector_list, result);
            }
        }
    }

    // --- アクセシビリティ属性 Getter/Setter ---
    pub fn getRole(self: *const Element) ?[]const u8 {
        return self.role;
    }
    pub fn setRole(self: *Element, value: []const u8) void {
        self.role = value;
    }
    pub fn getTabIndex(self: *const Element) ?i32 {
        return self.tabindex;
    }
    pub fn setTabIndex(self: *Element, value: i32) void {
        self.tabindex = value;
    }
    pub fn getAria(self: *const Element, name: []const u8) ?[]const u8 {
        if (self.aria_attributes) |*map| {
            return map.get(name);
        }
        return null;
    }
    pub fn setAria(self: *Element, name: []const u8, value: []const u8) void {
        if (self.aria_attributes) |*map| {
            map.put(name, value) catch {};
        }
    }

    /// この要素がフォーカス可能か判定
    pub fn isFocusable(self: *const Element) bool {
        // tabindexが明示的に設定されていればフォーカス可
        if (self.tabindex) |idx| {
            if (idx >= 0) return true;
        }
        // disabled属性
        if (self.hasAttribute("disabled")) return false;
        // hidden属性
        if (self.hasAttribute("hidden")) return false;
        // type=hiddenのinput
        if (self.data.tag_name.len > 0 and std.mem.eql(u8, self.data.tag_name, "input")) {
            if (self.getAttribute("type")) |t| {
                if (std.mem.eql(u8, t, "hidden")) return false;
            }
        }
        // デフォルトでフォーカス可能な要素
        const focusable_tags = [_][]const u8{ "a", "input", "select", "textarea", "button" };
        for (focusable_tags) |tag| {
            if (std.mem.eql(u8, self.data.tag_name, tag)) return true;
        }
        return false;
    }

    /// ルートからtabindex順で次のフォーカス可能要素を取得
    pub fn findNextFocusable(root: *Node, current: *Element) ?*Element {
        var focusables = std.ArrayList(*Element).init(root.owner_document.?.allocator);
        defer focusables.deinit();
        collectFocusableElements(root, &focusables);
        if (focusables.items.len == 0) return null;
        // tabindex順・文書順でソート
        std.sort.sort(*Element, focusables.items, {}, struct {
            pub fn lessThan(_: void, a: *Element, b: *Element) bool {
                const ta = a.tabindex orelse 0;
                const tb = b.tabindex orelse 0;
                if (ta != tb) return ta < tb;
                return @intFromPtr(a) < @intFromPtr(b);
            }
        }.lessThan);
        var found = false;
        for (focusables.items) |el| {
            if (found) return el;
            if (el == current) found = true;
        }
        return null;
    }

    /// ルートからtabindex順で前のフォーカス可能要素を取得
    pub fn findPrevFocusable(root: *Node, current: *Element) ?*Element {
        var focusables = std.ArrayList(*Element).init(root.owner_document.?.allocator);
        defer focusables.deinit();
        collectFocusableElements(root, &focusables);
        if (focusables.items.len == 0) return null;
        std.sort.sort(*Element, focusables.items, {}, struct {
            pub fn lessThan(_: void, a: *Element, b: *Element) bool {
                const ta = a.tabindex orelse 0;
                const tb = b.tabindex orelse 0;
                if (ta != tb) return ta < tb;
                return @intFromPtr(a) < @intFromPtr(b);
            }
        }.lessThan);
        var prev: ?*Element = null;
        for (focusables.items) |el| {
            if (el == current) return prev;
            prev = el;
        }
        return null;
    }

    /// ツリー全体からフォーカス可能要素を収集
    fn collectFocusableElements(node: *Node, out: *std.ArrayList(*Element)) void {
        if (node.specific_data) |spec| {
            const el: *Element = @ptrCast(@alignCast(spec));
            if (el.isFocusable()) out.append(el) catch {};
        }
        var child = node.first_child;
        while (child != null) : (child = child.?.next_sibling) {
            collectFocusableElements(child.?, out);
        }
    }
};
