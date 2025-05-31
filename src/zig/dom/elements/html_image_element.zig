// src/zig/dom/elements/html_image_element.zig
// HTMLImageElement インターフェース (`<img>`)
// https://html.spec.whatwg.org/multipage/embedded-content.html#the-img-element

const std = @import("std");
const HTMLElement = @import("./html_element.zig").HTMLElement;
const Element = @import("../element.zig").Element; // Element へのアクセス

pub const HTMLImageElement = struct {
    base: HTMLElement,
    // 画像の状態を追跡する内部フィールド
    natural_width: u32 = 0, // 実際の画像の幅
    natural_height: u32 = 0, // 実際の画像の高さ
    current_src: ?[]const u8 = null, // 現在のソースURL
    is_complete: bool = false, // 画像の読み込みが完了したか
    is_loading: bool = false, // 画像が読み込み中か

    pub fn create(allocator: std.mem.Allocator, html_element: HTMLElement) !*HTMLImageElement {
        const el = try allocator.create(HTMLImageElement);
        el.* = HTMLImageElement{ .base = html_element };
        return el;
    }

    pub fn destroy(self: *HTMLImageElement, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying HTMLImageElement specific data for <{s}>", .{self.base.element.data.tag_name});
        // 現在のsrcを解放
        if (self.current_src) |current| {
            allocator.free(current);
        }
        // ベース HTMLElement を破棄
        self.base.destroy(allocator);
        // この構造体を破棄
        allocator.destroy(self);
    }

    // --- Properties ---

    pub fn src(self: *const HTMLImageElement) ?[]const u8 {
        return self.base.element.getAttribute("src");
    }
    pub fn setSrc(self: *HTMLImageElement, value: []const u8) !void {
        try self.base.element.setAttribute("src", value);
        // 画像の読み込みをシミュレート
        self.is_loading = true;
        self.is_complete = false;
        // 実際のブラウザでは画像読み込みを開始し、完了時にイベントを発行
    }

    pub fn alt(self: *const HTMLImageElement) ?[]const u8 {
        return self.base.element.getAttribute("alt");
    }
    pub fn setAlt(self: *HTMLImageElement, value: []const u8) !void {
        try self.base.element.setAttribute("alt", value);
    }

    // width/height は属性値を数値に変換する必要があるが、ここでは文字列として扱う
    pub fn width(self: *const HTMLImageElement) ?[]const u8 {
        return self.base.element.getAttribute("width");
    }
    pub fn setWidth(self: *HTMLImageElement, value: []const u8) !void {
        // 数値検証
        for (value) |c| {
            if (c < '0' or c > '9') {
                if (c != '.' and c != '%' and c != 'p' and c != 'x') {
                    return error.InvalidWidthValue;
                }
            }
        }
        try self.base.element.setAttribute("width", value);
    }

    pub fn height(self: *const HTMLImageElement) ?[]const u8 {
        return self.base.element.getAttribute("height");
    }
    pub fn setHeight(self: *HTMLImageElement, value: []const u8) !void {
        // 数値検証
        for (value) |c| {
            if (c < '0' or c > '9') {
                if (c != '.' and c != '%' and c != 'p' and c != 'x') {
                    return error.InvalidHeightValue;
                }
            }
        }
        try self.base.element.setAttribute("height", value);
    }

    // loading (e.g., "lazy", "eager")
    pub fn loading(self: *const HTMLImageElement) ?[]const u8 {
        return self.base.element.getAttribute("loading");
    }
    pub fn setLoading(self: *HTMLImageElement, value: []const u8) !void {
        // 値検証 ("lazy" | "eager")
        if (!std.mem.eql(u8, value, "lazy") and
            !std.mem.eql(u8, value, "eager") and
            !std.mem.eql(u8, value, "auto"))
        {
            return error.InvalidLoadingValue;
        }
        try self.base.element.setAttribute("loading", value);
    }

    // decoding (e.g., "sync", "async", "auto")
    pub fn decoding(self: *const HTMLImageElement) ?[]const u8 {
        return self.base.element.getAttribute("decoding");
    }
    pub fn setDecoding(self: *HTMLImageElement, value: []const u8) !void {
        // 値検証 ("sync" | "async" | "auto")
        if (!std.mem.eql(u8, value, "sync") and
            !std.mem.eql(u8, value, "async") and
            !std.mem.eql(u8, value, "auto"))
        {
            return error.InvalidDecodingValue;
        }
        try self.base.element.setAttribute("decoding", value);
    }

    // 自然寸法と状態プロパティの実装
    pub fn naturalWidth(self: *const HTMLImageElement) u32 {
        return self.natural_width;
    }

    pub fn naturalHeight(self: *const HTMLImageElement) u32 {
        return self.natural_height;
    }

    pub fn currentSrc(self: *const HTMLImageElement) ?[]const u8 {
        return self.current_src;
    }

    pub fn complete(self: *const HTMLImageElement) bool {
        return self.is_complete;
    }

    // 画像ロード完了をシミュレートする内部メソッド
    // 実際のブラウザでは、ネットワーク層から呼び出される
    pub fn _setImageLoaded(self: *HTMLImageElement, allocator: std.mem.Allocator, img_width: u32, img_height: u32) !void {
        self.natural_width = img_width;
        self.natural_height = img_height;
        self.is_loading = false;
        self.is_complete = true;

        // currentSrcを更新
        if (self.src()) |src_value| {
            if (self.current_src) |old_src| {
                allocator.free(old_src);
            }
            self.current_src = try allocator.dupe(u8, src_value);
        }

        // 実際のブラウザでは、ここでloadイベントを発火
    }

    // 画像ロード失敗をシミュレートする内部メソッド
    pub fn _setImageLoadError(self: *HTMLImageElement) void {
        self.natural_width = 0;
        self.natural_height = 0;
        self.is_loading = false;
        self.is_complete = true; // エラーでもcompleteはtrue

        // 実際のブラウザでは、ここでerrorイベントを発火
    }
};
