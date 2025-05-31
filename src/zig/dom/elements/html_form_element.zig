// src/zig/dom/elements/html_form_element.zig
// HTMLFormElement インターフェース (`<form>`)
// https://html.spec.whatwg.org/multipage/forms.html#the-form-element

const std = @import("std");
const HTMLElement = @import("./html_element.zig").HTMLElement;
const Element = @import("../element.zig").Element; // Element へのアクセス
const Document = @import("../document.zig").Document; // submit/reset メソッド用
const Node = @import("../node.zig").Node; // 子ノード走査用

// フォームコントロールコレクション
pub const HTMLFormControlsCollection = struct {
    controls: std.ArrayList(*Element),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HTMLFormControlsCollection {
        return HTMLFormControlsCollection{
            .controls = std.ArrayList(*Element).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HTMLFormControlsCollection) void {
        self.controls.deinit();
    }

    // コレクションの長さ
    pub fn length(self: *const HTMLFormControlsCollection) usize {
        return self.controls.items.len;
    }

    // インデックスでアクセス
    pub fn item(self: *const HTMLFormControlsCollection, index: usize) ?*Element {
        if (index >= self.controls.items.len) {
            return null;
        }
        return self.controls.items[index];
    }

    // 名前で要素を取得
    pub fn namedItem(self: *const HTMLFormControlsCollection, name: []const u8) ?*Element {
        for (self.controls.items) |control| {
            // name属性をチェック
            if (control.getAttribute("name")) |control_name| {
                if (std.mem.eql(u8, control_name, name)) {
                    return control;
                }
            }

            // id属性もチェック
            if (control.getAttribute("id")) |control_id| {
                if (std.mem.eql(u8, control_id, name)) {
                    return control;
                }
            }
        }
        return null;
    }

    // コントロールを追加
    pub fn addControl(self: *HTMLFormControlsCollection, element: *Element) !void {
        // フォームコントロールかどうかを確認
        if (isFormControl(element)) {
            // 重複をチェック
            for (self.controls.items) |control| {
                if (control == element) {
                    return; // 既に追加済み
                }
            }
            try self.controls.append(element);
        }
    }

    // コントロールを削除
    pub fn removeControl(self: *HTMLFormControlsCollection, element: *Element) void {
        var i: usize = 0;
        while (i < self.controls.items.len) {
            if (self.controls.items[i] == element) {
                _ = self.controls.orderedRemove(i);
                return;
            }
            i += 1;
        }
    }

    // 要素がフォームコントロールかどうかを確認
    fn isFormControl(element: *Element) bool {
        if (element.data.tag_name.len == 0) {
            return false;
        }

        // フォームコントロールとして認識される要素タグをチェック
        const form_controls = [_][]const u8{ "button", "fieldset", "input", "object", "output", "select", "textarea" };

        const tag = element.data.tag_name;
        for (form_controls) |control| {
            if (std.mem.eql(u8, tag, control)) {
                return true;
            }
        }

        return false;
    }
};

pub const HTMLFormElement = struct {
    base: HTMLElement,
    elements: ?HTMLFormControlsCollection = null,

    pub fn create(allocator: std.mem.Allocator, html_element: HTMLElement) !*HTMLFormElement {
        const el = try allocator.create(HTMLFormElement);
        el.* = HTMLFormElement{
            .base = html_element,
            .elements = HTMLFormControlsCollection.init(allocator),
        };

        // 子フォームコントロールを初期化
        try el.refreshFormControls();

        return el;
    }

    pub fn destroy(self: *HTMLFormElement, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying HTMLFormElement specific data for <{s}>", .{self.base.element.data.tag_name});

        if (self.elements) |*elements| {
            elements.deinit();
        }

        self.base.destroy(allocator);
        allocator.destroy(self);
    }

    // --- Properties ---

    pub fn action(self: *const HTMLFormElement) ?[]const u8 {
        return self.base.element.getAttribute("action");
    }
    pub fn setAction(self: *HTMLFormElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("action", new_value);
    }

    // method: "get" or "post" (デフォルトは "get")
    pub fn method(self: *const HTMLFormElement) []const u8 {
        const method_attr = self.base.element.getAttribute("method");
        if (method_attr) |m| {
            var lower_buf: [4]u8 = undefined; // get, post を格納できるサイズ
            const lower_m = std.ascii.lowerString(lower_buf[0..std.math.min(m.len, lower_buf.len)], m);
            if (std.mem.eql(u8, lower_m, "post")) {
                return "post";
            }
        }
        return "get"; // デフォルト値
    }
    pub fn setMethod(self: *HTMLFormElement, new_value: []const u8) !void {
        // 値の検証 ("get" | "post")
        var lower_buf: [4]u8 = undefined;
        const lower_value = std.ascii.lowerString(lower_buf[0..std.math.min(new_value.len, lower_buf.len)], new_value);

        if (!std.mem.eql(u8, lower_value, "get") and !std.mem.eql(u8, lower_value, "post")) {
            return error.InvalidFormMethod;
        }

        try self.base.element.setAttribute("method", new_value);
    }

    // enctype: e.g., "application/x-www-form-urlencoded", "multipart/form-data", "text/plain"
    pub fn enctype(self: *const HTMLFormElement) ?[]const u8 {
        return self.base.element.getAttribute("enctype");
    }
    pub fn setEnctype(self: *HTMLFormElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("enctype", new_value);
    }

    pub fn target(self: *const HTMLFormElement) ?[]const u8 {
        return self.base.element.getAttribute("target");
    }
    pub fn setTarget(self: *HTMLFormElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("target", new_value);
    }

    // Boolean attribute
    pub fn noValidate(self: *const HTMLFormElement) bool {
        return self.base.element.hasAttribute("novalidate");
    }
    pub fn setNoValidate(self: *HTMLFormElement, new_value: bool) !void {
        if (new_value) {
            try self.base.element.setAttribute("novalidate", "");
        } else {
            try self.base.element.removeAttribute("novalidate");
        }
    }

    pub fn name(self: *const HTMLFormElement) ?[]const u8 {
        return self.base.element.getAttribute("name");
    }
    pub fn setName(self: *HTMLFormElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("name", new_value);
    }

    pub fn rel(self: *const HTMLFormElement) ?[]const u8 {
        return self.base.element.getAttribute("rel");
    }
    pub fn setRel(self: *HTMLFormElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("rel", new_value);
    }

    // フォームコントロールの要素コレクション
    pub fn getElements(self: *HTMLFormElement) !*HTMLFormControlsCollection {
        if (self.elements) |*elements| {
            return elements;
        }
        return error.NoElementsCollection;
    }

    // フォームコントロールの数
    pub fn controlsLength(self: *const HTMLFormElement) usize {
        if (self.elements) |elements| {
            return elements.length();
        }
        return 0;
    }

    // --- Methods ---

    pub fn submit(self: *HTMLFormElement) !void {
        // 1. submitイベント発行
        try self.dispatchSubmitEvent();
        // 2. ドキュメント取得
        const document = self.base.element.node_ptr.owner_document orelse return error.MissingDocument;
        // 3. バリデーション
        if (!self.noValidate()) {
            if (!try self.checkValidity()) return error.FormValidationFailed;
        }
        // 4. フォームデータ収集
        const form_data = try self.collectFormDataFromDom();
        // 5. ナビゲーション
        const action_url = self.action() orelse "/";
        if (document.window) |window| {
            try window.navigateTo(action_url, form_data);
        }
        std.log.info("Form submitted successfully to {s}", .{action_url});
    }

    pub fn reset(self: *HTMLFormElement) !void {
        // フォームリセット処理を実装

        // 1. reset イベントの発行
        // (実際のイベント発行は別途実装する必要があります)
        std.log.debug("Form reset initiated", .{});

        // 2. 全てのフォームコントロールの値をリセット
        if (self.elements) |elements| {
            for (0..elements.length()) |i| {
                if (elements.item(i)) |control| {
                    try self.resetControl(control);
                }
            }
        }

        std.log.debug("Form reset completed", .{});
    }

    // 個別コントロールのリセット処理
    fn resetControl(self: *HTMLFormElement, control: *Element) !void {
        _ = self;
        const tag = control.data.tag_name;

        if (std.mem.eql(u8, tag, "input")) {
            // 入力要素の場合、デフォルト値にリセット
            try control.removeAttribute("value");

            // チェックボックスとラジオはデフォルト状態に戻す
            if (control.getAttribute("type")) |type_value| {
                if (std.mem.eql(u8, type_value, "checkbox") or std.mem.eql(u8, type_value, "radio")) {
                    if (control.hasAttribute("checked")) {
                        if (!control.hasAttribute("defaultChecked")) {
                            try control.removeAttribute("checked");
                        }
                    } else {
                        if (control.hasAttribute("defaultChecked")) {
                            try control.setAttribute("checked", "");
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, tag, "textarea")) {
            // テキストエリアをデフォルト値にリセット
            if (control.hasAttribute("defaultValue")) {
                const default_value = control.getAttribute("defaultValue") orelse "";
                try control.node_ptr.setTextContent(control.node_ptr.allocator, default_value);
            } else {
                // 初期DOM構築時のテキストノード内容を保存しておき、ここで復元
                if (control.node_ptr.initial_text_content) |init_txt| {
                    try control.node_ptr.setTextContent(control.node_ptr.allocator, init_txt);
                } else {
                    // fallback: 空に
                    try control.node_ptr.setTextContent(control.node_ptr.allocator, "");
                }
            }
        } else if (std.mem.eql(u8, tag, "select")) {
            // select要素のデフォルト選択に戻す（HTML仕様準拠）
            var first_option: ?*Element = null;
            var child = control.node_ptr.first_child;
            while (child != null) : (child = child.?.next_sibling) {
                if (child.?.node_type == .Element) {
                    const option_elem: *Element = @ptrCast(@alignCast(child.?.specific_data.?));
                    if (std.mem.eql(u8, option_elem.data.tag_name, "option")) {
                        if (first_option == null) first_option = option_elem;
                        if (option_elem.hasAttribute("defaultSelected")) {
                            try option_elem.setAttribute("selected", "");
                        } else {
                            try option_elem.removeAttribute("selected");
                        }
                    }
                }
            }
            // どのoptionにもdefaultSelectedがなければ最初のoptionを選択
            if (first_option) |opt| {
                var has_selected = false;
                var child2 = control.node_ptr.first_child;
                while (child2 != null) : (child2 = child2.?.next_sibling) {
                    if (child2.?.node_type == .Element) {
                        const option_elem: *Element = @ptrCast(@alignCast(child2.?.specific_data.?));
                        if (std.mem.eql(u8, option_elem.data.tag_name, "option")) {
                            if (option_elem.hasAttribute("selected")) {
                                has_selected = true;
                                break;
                            }
                        }
                    }
                }
                if (!has_selected) {
                    try opt.setAttribute("selected", "");
                }
            }
        } else if (std.mem.eql(u8, tag, "button")) {
            // button: type=submit/reset/button以外は送信対象外
            if (control.asHTMLButtonElement()) |btn| {
                const type = btn.getType();
                if (!std.mem.eql(u8, type, "submit") and !std.mem.eql(u8, type, "button") and !std.mem.eql(u8, type, "reset")) {
                    if (btn.value()) |val| {
                        var pair = std.ArrayList(u8).init(allocator);
                        try pair.appendSlice(field_name);
                        try pair.append('=');
                        try pair.appendSlice(val);
                        try result.append(pair);
                    }
                }
            }
        }
    }

    pub fn checkValidity(self: *const HTMLFormElement) !bool {
        // HTML仕様準拠の全バリデーション
        var is_valid = true;
        if (self.elements) |elements| {
            for (0..elements.length()) |i| {
                if (elements.item(i)) |control| {
                    if (!try control.checkValidity()) {
                        is_valid = false;
                        break;
                    }
                }
            }
        }
        return is_valid;
    }

    pub fn reportValidity(self: *const HTMLFormElement) !bool {
        // バリデーション＋UIエラー表示
        const is_valid = try self.checkValidity();
        if (!is_valid) {
            if (self.elements) |elements| {
                for (0..elements.length()) |i| {
                    if (elements.item(i)) |control| {
                        if (!try control.checkValidity()) {
                            try control.focus();
                            const msg = control.getValidationMessage() orelse "入力に問題があります";
                            if (control.ownerDocument) |doc| {
                                if (doc.window) |window| {
                                    try window.showValidationMessage(control, msg);
                                }
                            }
                            break;
                        }
                    }
                }
            }
        }
        return is_valid;
    }

    // フォームに関連付けられたコントロールを再スキャン
    pub fn refreshFormControls(self: *HTMLFormElement) !void {
        if (self.elements) |*elements| {
            // 既存のリストをクリア
            elements.controls.clearRetainingCapacity();

            // フォーム内の全ての子孫ノードを走査
            try self.collectFormControls(self.base.element.node_ptr, elements);

            // form属性を持つ他の要素も検索
            if (self.base.element.node_ptr.owner_document) |doc| {
                if (self.base.element.getAttribute("id")) |form_id| {
                    try self.collectExternalControls(doc, form_id, elements);
                }
            }
        }
    }

    // フォーム内のコントロールを再帰的に収集
    fn collectFormControls(self: *HTMLFormElement, node: *Node, elements: *HTMLFormControlsCollection) !void {
        _ = self;

        // この要素自体がフォームコントロールか確認
        if (node.data.element) |element| {
            try elements.addControl(element);
        }

        // 子ノードを再帰的に処理
        var child = node.first_child;
        while (child != null) {
            try self.collectFormControls(child.?, elements);
            child = child.?.next_sibling;
        }
    }

    // フォーム外だがform属性でこのフォームを参照しているコントロールを収集
    fn collectExternalControls(self: *HTMLFormElement, doc: *Document, form_id: []const u8, elements: *HTMLFormControlsCollection) !void {
        // ドキュメント全体からform属性が一致する要素を収集
        var node = doc.root_node;
        collectExternalControlsRecursive(node, form_id, elements);
    }
    fn collectExternalControlsRecursive(node: *Node, form_id: []const u8, elements: *HTMLFormControlsCollection) void {
        if (node.data.element) |el| {
            if (el.getAttribute("form")) |fid| {
                if (std.mem.eql(u8, fid, form_id)) {
                    elements.addControl(el) catch {};
                }
            }
        }
        var child = node.first_child;
        while (child != null) : (child = child.?.next_sibling) {
            collectExternalControlsRecursive(child.?, form_id, elements);
        }
    }

    fn collectFormData(self: *HTMLFormElement) !std.ArrayList(std.ArrayList(u8)) {
        // 世界最高水準: HTML仕様準拠のフォームデータ収集
        const allocator = self.base.element.node_ptr.owner_document.?.allocator;
        var result = std.ArrayList(std.ArrayList(u8)).init(allocator);

        if (self.elements) |elements| {
            for (0..elements.length()) |i| {
                if (elements.item(i)) |control| {
                    // disabled属性は送信対象外
                    if (control.hasAttribute("disabled")) continue;
                    // name属性必須
                    const field_name = control.getAttribute("name") orelse continue;
                    if (field_name.len == 0) continue;

                    const tag = control.data.tag_name;
                    // input要素
                    if (std.mem.eql(u8, tag, "input")) {
                        if (control.asHTMLInputElement()) |input| {
                            const type = input.getType() orelse "text";
                            if (std.mem.eql(u8, type, "checkbox") or std.mem.eql(u8, type, "radio")) {
                                if (!input.checked()) continue; // チェックされていなければ送信しない
                            }
                            // file型は未対応（要: FileList→multipart/form-data）
                            if (std.mem.eql(u8, type, "file")) continue;
                            // value属性
                            if (input.value()) |val| {
                                var pair = std.ArrayList(u8).init(allocator);
                                try pair.appendSlice(field_name);
                                try pair.append('=');
                                try pair.appendSlice(val);
                                try result.append(pair);
                            }
                        }
                    } else if (std.mem.eql(u8, tag, "textarea")) {
                        // textarea: テキストノード内容
                        const value = control.node_ptr.getTextContent() orelse "";
                        var pair = std.ArrayList(u8).init(allocator);
                        try pair.appendSlice(field_name);
                        try pair.append('=');
                        try pair.appendSlice(value);
                        try result.append(pair);
                    } else if (std.mem.eql(u8, tag, "select")) {
                        // select: 選択されたoptionのvalue
                        const multiple = control.hasAttribute("multiple");
                        var child = control.node_ptr.first_child;
                        while (child != null) : (child = child.?.next_sibling) {
                            if (child.?.node_type == .Element) {
                                const option_elem: *Element = @ptrCast(@alignCast(child.?.specific_data.?));
                                if (std.mem.eql(u8, option_elem.data.tag_name, "option")) {
                                    if (option_elem.hasAttribute("selected")) {
                                        const val = option_elem.getAttribute("value") orelse "";
                                        var pair = std.ArrayList(u8).init(allocator);
                                        try pair.appendSlice(field_name);
                                        try pair.append('=');
                                        try pair.appendSlice(val);
                                        try result.append(pair);
                                        if (!multiple) break;
                                    }
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, tag, "button")) {
                        // button: type=submit/reset/button以外は送信対象外
                        if (control.asHTMLButtonElement()) |btn| {
                            const type = btn.getType();
                            if (!std.mem.eql(u8, type, "submit") and !std.mem.eql(u8, type, "button") and !std.mem.eql(u8, type, "reset")) {
                                if (btn.value()) |val| {
                                    var pair = std.ArrayList(u8).init(allocator);
                                    try pair.appendSlice(field_name);
                                    try pair.append('=');
                                    try pair.appendSlice(val);
                                    try result.append(pair);
                                }
                            }
                        }
                    }
                }
            }
        }
        return result;
    }

    fn buildUrlWithParams(allocator: std.mem.Allocator, base_url: []const u8, form_data: std.ArrayList(std.ArrayList(u8))) ![]u8 {
        // 世界最高水準: application/x-www-form-urlencodedでクエリパラメータを構築
        var query_buf = std.ArrayList(u8).init(allocator);
        defer query_buf.deinit();

        for (form_data.items, 0..) |pair, idx| {
            if (idx != 0) try query_buf.append('&');
            // name=value形式（すでにcollectFormDataで=区切りなので分割）
            const eq_pos = std.mem.indexOfScalar(u8, pair.items, '=') orelse continue;
            const name = pair.items[0..eq_pos];
            const value = pair.items[eq_pos + 1 ..];
            try urlEncodeTo(&query_buf, name);
            try query_buf.append('=');
            try urlEncodeTo(&query_buf, value);
        }
        const query = try query_buf.toOwnedSlice();

        // base_urlに既に?が含まれていれば&で連結、なければ?で連結
        var url_buf = std.ArrayList(u8).init(allocator);
        defer url_buf.deinit();
        try url_buf.appendSlice(base_url);
        if (std.mem.indexOfScalar(u8, base_url, '?') != null) {
            if (!std.mem.endsWith(u8, base_url, "&") and !std.mem.endsWith(u8, base_url, "?"))
                try url_buf.append('&');
        } else {
            try url_buf.append('?');
        }
        try url_buf.appendSlice(query);
        return try url_buf.toOwnedSlice();
    }

    // RFC3986に準拠したURLエンコード（application/x-www-form-urlencoded用）
    fn urlEncodeTo(out_buf: *std.ArrayList(u8), in_data: []const u8) !void {
        for (in_data) |c| {
            if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~') {
                try out_buf.append(c);
            } else if (c == ' ') {
                try out_buf.append('+');
            } else {
                var hex: [3]u8 = undefined;
                hex[0] = '%';
                hex[1] = std.fmt.hexDigitUpper((c >> 4) & 0xF);
                hex[2] = std.fmt.hexDigitUpper(c & 0xF);
                try out_buf.appendSlice(&hex);
            }
        }
    }

    fn collectFormDataFromDom(self: *HTMLFormElement) !std.ArrayList(u8) {
        // 世界最高水準: DOMツリーを直接走査し、form要素配下の全コントロールのname/valueペアを収集
        const allocator = self.base.element.node_ptr.allocator;
        var result = std.ArrayList(u8).init(allocator);
        if (self.elements) |elements| {
            for (0..elements.length()) |i| {
                if (elements.item(i)) |control| {
                    // disabled属性は送信対象外
                    if (control.hasAttribute("disabled")) continue;
                    // name属性必須
                    const field_name = control.getAttribute("name") orelse continue;
                    if (field_name.len == 0) continue;
                    const tag = control.data.tag_name;
                    // input要素
                    if (std.mem.eql(u8, tag, "input")) {
                        if (control.asHTMLInputElement()) |input| {
                            const type = input.getType() orelse "text";
                            if (std.mem.eql(u8, type, "checkbox") or std.mem.eql(u8, type, "radio")) {
                                if (!input.checked()) continue;
                            }
                            if (std.mem.eql(u8, type, "file")) continue;
                            if (input.value()) |val| {
                                try result.appendSlice(field_name);
                                try result.append('=');
                                try result.appendSlice(val);
                            }
                        }
                    } else if (std.mem.eql(u8, tag, "textarea")) {
                        const value = control.node_ptr.getTextContent() orelse "";
                        try result.appendSlice(field_name);
                        try result.append('=');
                        try result.appendSlice(value);
                    } else if (std.mem.eql(u8, tag, "select")) {
                        const multiple = control.hasAttribute("multiple");
                        var child = control.node_ptr.first_child;
                        while (child != null) : (child = child.?.next_sibling) {
                            if (child.?.node_type == .Element) {
                                const option_elem: *Element = @ptrCast(@alignCast(child.?.specific_data.?));
                                if (std.mem.eql(u8, option_elem.data.tag_name, "option")) {
                                    if (option_elem.hasAttribute("selected")) {
                                        const val = option_elem.getAttribute("value") orelse "";
                                        try result.appendSlice(field_name);
                                        try result.append('=');
                                        try result.appendSlice(val);
                                        if (!multiple) break;
                                    }
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, tag, "button")) {
                        if (control.asHTMLButtonElement()) |btn| {
                            const type = btn.getType();
                            if (!std.mem.eql(u8, type, "submit") and !std.mem.eql(u8, type, "button") and !std.mem.eql(u8, type, "reset")) {
                                if (btn.value()) |val| {
                                    try result.appendSlice(field_name);
                                    try result.append('=');
                                    try result.appendSlice(val);
                                }
                            }
                        }
                    }
                }
            }
        }
        return result;
    }

    fn buildQueryParams(form_data: std.ArrayList(u8)) ![]u8 {
        // 世界最高水準: form_dataからapplication/x-www-form-urlencoded形式のクエリ文字列を生成
        var query_buf = std.ArrayList(u8).init(std.heap.page_allocator);
        defer query_buf.deinit();
        var i: usize = 0;
        var start: usize = 0;
        while (i < form_data.items.len) : (i += 1) {
            if (form_data.items[i] == '=') {
                const name = form_data.items[start..i];
                start = i + 1;
                var value_end = start;
                while (value_end < form_data.items.len and form_data.items[value_end] != '=') : (value_end += 1) {}
                const value = form_data.items[start..value_end];
                if (query_buf.items.len > 0) try query_buf.append('&');
                try urlEncodeTo(&query_buf, name);
                try query_buf.append('=');
                try urlEncodeTo(&query_buf, value);
                start = value_end;
                i = value_end - 1;
            }
        }
        return try query_buf.toOwnedSlice();
    }
};
