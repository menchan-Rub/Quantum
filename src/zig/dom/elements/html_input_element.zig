// src/zig/dom/elements/html_input_element.zig
// HTMLInputElement インターフェース (`<input>`)
// https://html.spec.whatwg.org/multipage/input.html#the-input-element

const std = @import("std");
const HTMLElement = @import("./html_element.zig").HTMLElement;
const Element = @import("../element.zig").Element; // Element へのアクセス
const HTMLFormElement = @import("./html_form_element.zig").HTMLFormElement;
const Document = @import("../document.zig").Document;

// FileList擬似実装 (本来はWeb APIの一部)
pub const FileList = struct {
    files: std.ArrayList(*File),

    pub fn init(allocator: std.mem.Allocator) FileList {
        return .{
            .files = std.ArrayList(*File).init(allocator),
        };
    }

    pub fn deinit(self: *FileList) void {
        for (self.files.items) |file| {
            file.deinit();
        }
        self.files.deinit();
    }

    pub fn length(self: *const FileList) usize {
        return self.files.items.len;
    }

    pub fn item(self: *const FileList, index: usize) ?*File {
        if (index >= self.files.items.len) {
            return null;
        }
        return self.files.items[index];
    }

    pub fn add(self: *FileList, file: *File) !void {
        try self.files.append(file);
    }
};

// File擬似実装
pub const File = struct {
    name: []const u8,
    type: []const u8,
    size: usize,
    last_modified: i64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, mime_type: []const u8, size: usize) !*File {
        const file = try allocator.create(File);
        file.* = .{
            .name = try allocator.dupe(u8, name),
            .type = try allocator.dupe(u8, mime_type),
            .size = size,
            .last_modified = std.time.timestamp(),
            .allocator = allocator,
        };
        return file;
    }

    pub fn deinit(self: *File) void {
        self.allocator.free(self.name);
        self.allocator.free(self.type);
        self.allocator.destroy(self);
    }
};

// ValidityState擬似実装
pub const ValidityState = struct {
    value_missing: bool = false,
    type_mismatch: bool = false,
    pattern_mismatch: bool = false,
    too_long: bool = false,
    too_short: bool = false,
    range_underflow: bool = false,
    range_overflow: bool = false,
    step_mismatch: bool = false,
    bad_input: bool = false,
    custom_error: bool = false,

    pub fn valid(self: ValidityState) bool {
        return !self.value_missing and
            !self.type_mismatch and
            !self.pattern_mismatch and
            !self.too_long and
            !self.too_short and
            !self.range_underflow and
            !self.range_overflow and
            !self.step_mismatch and
            !self.bad_input and
            !self.custom_error;
    }
};

pub const HTMLInputElement = struct {
    base: HTMLElement,
    files: ?FileList = null,
    validity_state: ValidityState = ValidityState{},
    validation_message: ?[]const u8 = null,

    /// インスタンスを生成
    pub fn create(allocator: std.mem.Allocator, html_element: HTMLElement) !*HTMLInputElement {
        const el = try allocator.create(HTMLInputElement);
        el.* = HTMLInputElement{ .base = html_element };

        // typeがfileの場合はFileListを初期化
        if (el.getType()) |t| {
            if (std.mem.eql(u8, t, "file")) {
                el.files = FileList.init(allocator);
            }
        }

        return el;
    }

    /// 特殊な破棄処理
    pub fn destroy(self: *HTMLInputElement, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying HTMLInputElement specific data for <{s}>", .{self.base.element.data.tag_name});

        // FileListの解放
        if (self.files) |*files| {
            files.deinit();
        }

        // ValidationMessageの解放
        if (self.validation_message) |msg| {
            allocator.free(msg);
        }

        self.base.destroy(allocator);
        allocator.destroy(self);
    }

    // --- Properties ---

    pub fn getType(self: *const HTMLInputElement) ?[]const u8 {
        return self.base.element.getAttribute("type");
    }
    pub fn setType(self: *HTMLInputElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("type", new_value);
    }

    pub fn value(self: *const HTMLInputElement) ?[]const u8 {
        return self.base.element.getAttribute("value");
    }
    pub fn setValue(self: *HTMLInputElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("value", new_value);
    }

    pub fn name(self: *const HTMLInputElement) ?[]const u8 {
        return self.base.element.getAttribute("name");
    }
    pub fn setName(self: *HTMLInputElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("name", new_value);
    }

    pub fn placeholder(self: *const HTMLInputElement) ?[]const u8 {
        return self.base.element.getAttribute("placeholder");
    }
    pub fn setPlaceholder(self: *HTMLInputElement, new_value: []const u8) !void {
        try self.base.element.setAttribute("placeholder", new_value);
    }

    // Boolean attributes
    pub fn disabled(self: *const HTMLInputElement) bool {
        return self.base.element.hasAttribute("disabled");
    }
    pub fn setDisabled(self: *HTMLInputElement, new_value: bool) !void {
        if (new_value) {
            try self.base.element.setAttribute("disabled", ""); // 値は空文字列で設定
        } else {
            try self.base.element.removeAttribute("disabled");
        }
    }

    pub fn readonly(self: *const HTMLInputElement) bool {
        return self.base.element.hasAttribute("readonly");
    }
    pub fn setReadonly(self: *HTMLInputElement, new_value: bool) !void {
        if (new_value) {
            try self.base.element.setAttribute("readonly", "");
        } else {
            try self.base.element.removeAttribute("readonly");
        }
    }

    pub fn required(self: *const HTMLInputElement) bool {
        return self.base.element.hasAttribute("required");
    }
    pub fn setRequired(self: *HTMLInputElement, new_value: bool) !void {
        if (new_value) {
            try self.base.element.setAttribute("required", "");
        } else {
            try self.base.element.removeAttribute("required");
        }
    }

    pub fn checked(self: *const HTMLInputElement) bool {
        return self.base.element.hasAttribute("checked");
    }
    pub fn setChecked(self: *HTMLInputElement, new_value: bool) !void {
        if (new_value) {
            try self.base.element.setAttribute("checked", "");
        } else {
            try self.base.element.removeAttribute("checked");
        }
    }

    // ファイル選択用入力のファイルリスト
    pub fn getFiles(self: *const HTMLInputElement) ?*const FileList {
        return if (self.files) |*files| files else null;
    }

    // 関連するフォーム要素
    pub fn form(self: *const HTMLInputElement) ?*HTMLFormElement {
        // 親ノードを辿ってform要素を返す
        var node = self.base.element.node_ptr.parent;
        while (node != null) : (node = node.?.parent) {
            if (node.?.data.element) |el| {
                if (std.mem.eql(u8, el.data.tag_name, "form")) {
                    return el.asHTMLFormElement();
                }
            }
        }
        return null;
    }

    // リスト属性 - datalistの参照先ID
    pub fn list(self: *const HTMLInputElement) ?*Element {
        // list属性（datalistの参照先ID）
        if (self.base.element.getAttribute("list")) |list_id| {
            if (self.base.element.node_ptr.owner_document) |doc| {
                return doc.getElementById(list_id);
            }
        }
        return null;
    }

    // 最大値
    pub fn max(self: *const HTMLInputElement) ?[]const u8 {
        return self.base.element.getAttribute("max");
    }
    pub fn setMax(self: *HTMLInputElement, max_value: []const u8) !void {
        try self.base.element.setAttribute("max", max_value);
    }

    // 最小値
    pub fn min(self: *const HTMLInputElement) ?[]const u8 {
        return self.base.element.getAttribute("min");
    }
    pub fn setMin(self: *HTMLInputElement, min_value: []const u8) !void {
        try self.base.element.setAttribute("min", min_value);
    }

    // ステップ値
    pub fn step(self: *const HTMLInputElement) ?[]const u8 {
        const step_attr = self.base.element.getAttribute("step");
        if (step_attr) |s| {
            return s;
        }
        return "any"; // デフォルト値
    }
    pub fn setStep(self: *HTMLInputElement, step_value: []const u8) !void {
        try self.base.element.setAttribute("step", step_value);
    }

    // 検証パターン (正規表現)
    pub fn pattern(self: *const HTMLInputElement) ?[]const u8 {
        return self.base.element.getAttribute("pattern");
    }
    pub fn setPattern(self: *HTMLInputElement, pattern_value: []const u8) !void {
        try self.base.element.setAttribute("pattern", pattern_value);
    }

    /// max属性の値をf64で取得（未設定時はnull）
    pub fn getMaxValue(self: *const HTMLInputElement) ?f64 {
        if (self.max()) |max_str| {
            return std.fmt.parseFloat(f64, max_str) catch null;
        }
        return null;
    }
    /// min属性の値をf64で取得（未設定時はnull）
    pub fn getMinValue(self: *const HTMLInputElement) ?f64 {
        if (self.min()) |min_str| {
            return std.fmt.parseFloat(f64, min_str) catch null;
        }
        return null;
    }

    // --- バリデーションメソッド ---

    // 入力が有効かどうかを返す
    pub fn checkValidity(self: *HTMLInputElement) bool {
        self.updateValidity();
        return self.validity_state.valid();
    }

    // 詳細なバリデーション状態を提供
    pub fn validity(self: *HTMLInputElement) ValidityState {
        self.updateValidity();
        return self.validity_state;
    }

    // バリデーションメッセージを取得
    pub fn validationMessage(self: *const HTMLInputElement) ?[]const u8 {
        return self.validation_message;
    }

    // カスタムエラーを設定
    pub fn setCustomValidity(self: *HTMLInputElement, allocator: std.mem.Allocator, message: []const u8) !void {
        if (self.validation_message) |msg| {
            allocator.free(msg);
        }

        if (message.len > 0) {
            self.validation_message = try allocator.dupe(u8, message);
            self.validity_state.custom_error = true;
        } else {
            self.validation_message = null;
            self.validity_state.custom_error = false;
        }
    }

    // 内部用 - バリデーション状態を更新
    fn updateValidity(self: *HTMLInputElement) void {
        // バリデーション状態をリセット
        self.validity_state = ValidityState{};

        // 必須フィールドのチェック
        if (self.required() and (self.value() == null or self.value().?.len == 0)) {
            self.validity_state.value_missing = true;
        }

        // 型チェック
        if (self.getType()) |t| {
            // 型ごとの検証
            if (std.mem.eql(u8, t, "email")) {
                // メールアドレスの簡易検証 (@ が含まれているか)
                if (self.value()) |val| {
                    if (val.len > 0 and !std.mem.indexOf(u8, val, "@")) {
                        self.validity_state.type_mismatch = true;
                    }
                }
            } else if (std.mem.eql(u8, t, "number") or std.mem.eql(u8, t, "range")) {
                // 数値範囲チェック
                if (self.value()) |val| {
                    if (val.len > 0) {
                        const num = std.fmt.parseFloat(f64, val) catch {
                            self.validity_state.bad_input = true;
                            return;
                        };

                        // 最小値チェック
                        if (self.min()) |min_str| {
                            const min_val = std.fmt.parseFloat(f64, min_str) catch 0;
                            if (num < min_val) {
                                self.validity_state.range_underflow = true;
                            }
                        }

                        // 最大値チェック
                        if (self.max()) |max_str| {
                            const max_val = std.fmt.parseFloat(f64, max_str) catch 0;
                            if (num > max_val) {
                                self.validity_state.range_overflow = true;
                            }
                        }

                        // ステップチェック
                        if (self.step()) |step_str| {
                            if (!std.mem.eql(u8, step_str, "any")) {
                                const step_val = std.fmt.parseFloat(f64, step_str) catch 0;
                                if (step_val > 0) {
                                    // ステップの倍数かどうかをチェック
                                    const min_val = if (self.min()) |min_str|
                                        std.fmt.parseFloat(f64, min_str) catch 0
                                    else
                                        0;

                                    const diff = num - min_val;
                                    const remainder = @mod(diff, step_val);

                                    // 浮動小数点の比較には許容誤差を使用
                                    const epsilon = 0.0000001;
                                    if (remainder > epsilon and (step_val - remainder) > epsilon) {
                                        self.validity_state.step_mismatch = true;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // パターンチェック
        if (self.pattern()) |pattern_str| {
            if (self.value()) |val| {
                if (val.len > 0 and pattern_str.len > 0) {
                    const re = std.regex.compile(pattern_str, .{}) catch {
                        self.validity_state.pattern_mismatch = true;
                        return;
                    };
                    defer re.deinit();
                    if (!std.regex.match(re, val)) {
                        self.validity_state.pattern_mismatch = true;
                    }
                }
            }
        }
    }

    // フォーカスを当てる
    pub fn focus(self: *HTMLInputElement) void {
        // UIイベント/コールバック経由で実際にフォーカスを設定
        if (self.base.element.node_ptr.owner_document) |doc| {
            if (doc.window) |window| {
                window.setFocus(self.base.element.node_ptr);
            }
        }
    }

    // フォーカスを外す
    pub fn blur(self: *HTMLInputElement) void {
        // UIイベント/コールバック経由で実際にフォーカスを外す
        if (self.base.element.node_ptr.owner_document) |doc| {
            if (doc.window) |window| {
                window.clearFocus(self.base.element.node_ptr);
            }
        }
    }

    // 選択する
    pub fn select(self: *HTMLInputElement) void {
        // UIイベント/コールバック経由でテキスト全体を選択
        if (self.base.element.node_ptr.owner_document) |doc| {
            if (doc.window) |window| {
                window.selectText(self.base.element.node_ptr);
            }
        }
    }
};
