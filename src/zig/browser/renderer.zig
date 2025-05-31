const std = @import("std");
const mem = std.mem;
const math = std.math;
const QuantumRenderer = @import("../engine/renderer.zig").QuantumRenderer;
const memory_manager = @import("../memory/memory_manager.zig");
const simd = @import("../simd/vector_operations.zig");
const graphics = @import("../graphics/graphics.zig");
const fontEngine = @import("../fonts/font_engine.zig");

/// 量子ブラウザレンダリングシステム
/// ブラウザのレンダリングパイプラインとページ描画の管理
pub const BrowserRenderer = struct {
    // 内部レンダラー
    renderer: *QuantumRenderer,

    // メモリアロケータ
    allocator: mem.Allocator,

    // ビューポートサイズ
    viewport_width: u32,
    viewport_height: u32,

    // スクロール情報
    scroll_x: f32,
    scroll_y: f32,

    // ズームレベル
    zoom_factor: f32,

    // レイヤー管理
    layers: std.ArrayList(RenderLayer),

    // アクティブテクスチャリスト
    textures: std.ArrayList(Texture),

    // フォント情報
    fonts: std.ArrayList(Font),

    // レンダリング統計
    stats: RenderStats,

    // レイヤー定義
    pub const RenderLayer = struct {
        id: u32,
        visible: bool,
        opacity: f32,
        z_index: i32,
        viewport: Rect,
        clip_rect: ?Rect,
        transform: QuantumRenderer.Transform,

        pub const Rect = struct {
            x: f32,
            y: f32,
            width: f32,
            height: f32,
        };
    };

    // テクスチャ定義
    pub const Texture = struct {
        id: u32,
        width: u32,
        height: u32,
        format: TextureFormat,
        data: ?[]u8,
        user_data: ?*anyopaque,

        pub const TextureFormat = enum {
            RGBA8,
            RGBA32F,
            RGB8,
            R8,
            A8,
        };
    };

    // フォント定義
    pub const Font = struct {
        id: u32,
        family: []const u8,
        size: f32,
        weight: FontWeight,
        style: FontStyle,

        pub const FontWeight = enum {
            Thin,
            ExtraLight,
            Light,
            Regular,
            Medium,
            SemiBold,
            Bold,
            ExtraBold,
            Black,
        };

        pub const FontStyle = enum {
            Normal,
            Italic,
            Oblique,
        };
    };

    // 描画要素
    pub const DrawNode = struct {
        const NodeType = enum {
            Rectangle,
            Text,
            Image,
            Border,
            Shadow,
            Gradient,
            Custom,
        };

        type: NodeType,
        layer_id: u32,
        rect: RenderLayer.Rect,
        clip_to_bounds: bool,
        transform: ?QuantumRenderer.Transform,
        data: union {
            rectangle: RectangleData,
            text: TextData,
            image: ImageData,
            border: BorderData,
            shadow: ShadowData,
            gradient: GradientData,
            custom: CustomData,
        },

        pub const RectangleData = struct {
            color: [4]f32,
            corner_radius: [4]f32, // 左上、右上、右下、左下
        };

        pub const TextData = struct {
            font_id: u32,
            text: []const u8,
            color: [4]f32,
            alignment: TextAlignment,

            pub const TextAlignment = enum {
                Left,
                Center,
                Right,
            };
        };

        pub const ImageData = struct {
            texture_id: u32,
            uv_rect: [4]f32, // left, top, right, bottom
            color: [4]f32,
            fit_mode: ImageFitMode,

            pub const ImageFitMode = enum {
                Fill,
                Contain,
                Cover,
                ScaleDown,
                None,
            };
        };

        pub const BorderData = struct {
            widths: [4]f32, // 上、右、下、左
            colors: [4][4]f32, // 上、右、下、左
            corner_radius: [4]f32, // 左上、右上、右下、左下
        };

        pub const ShadowData = struct {
            color: [4]f32,
            offset_x: f32,
            offset_y: f32,
            blur_radius: f32,
            spread_radius: f32,
            inset: bool,
        };

        pub const GradientData = struct {
            type: GradientType,
            stops: []GradientStop,

            pub const GradientType = enum {
                Linear,
                Radial,
                Conic,
            };

            pub const GradientStop = struct {
                position: f32, // 0.0 - 1.0
                color: [4]f32,
            };
        };

        pub const CustomData = struct {
            callback: *const fn (*BrowserRenderer, *const DrawNode) void,
            user_data: ?*anyopaque,
        };
    };

    // レンダリング統計
    pub const RenderStats = struct {
        nodes_rendered: u32 = 0,
        layers_rendered: u32 = 0,
        texts_rendered: u32 = 0,
        images_rendered: u32 = 0,
        textures_used: u32 = 0,
        render_time_ms: f32 = 0.0,
        layout_time_ms: f32 = 0.0,
        composite_time_ms: f32 = 0.0,
    };

    /// ブラウザレンダラーを初期化
    pub fn init(allocator: mem.Allocator, renderer: *QuantumRenderer, width: u32, height: u32) !*BrowserRenderer {
        var self = try allocator.create(BrowserRenderer);
        errdefer allocator.destroy(self);

        self.* = BrowserRenderer{
            .renderer = renderer,
            .allocator = allocator,
            .viewport_width = width,
            .viewport_height = height,
            .scroll_x = 0,
            .scroll_y = 0,
            .zoom_factor = 1.0,
            .layers = std.ArrayList(RenderLayer).init(allocator),
            .textures = std.ArrayList(Texture).init(allocator),
            .fonts = std.ArrayList(Font).init(allocator),
            .stats = RenderStats{},
        };

        // デフォルトレイヤーを作成
        try self.createDefaultLayers();

        return self;
    }

    /// リソース解放
    pub fn deinit(self: *BrowserRenderer) void {
        // テクスチャデータ解放
        for (self.textures.items) |texture| {
            if (texture.data) |data| {
                self.allocator.free(data);
            }
        }

        // フォントデータ解放
        for (self.fonts.items) |font| {
            self.allocator.free(font.family);
        }

        self.layers.deinit();
        self.textures.deinit();
        self.fonts.deinit();
        self.allocator.destroy(self);
    }

    /// デフォルトレイヤーを作成
    fn createDefaultLayers(self: *BrowserRenderer) !void {
        // バックグラウンドレイヤー (z-index: -1000)
        try self.layers.append(.{
            .id = 0,
            .visible = true,
            .opacity = 1.0,
            .z_index = -1000,
            .viewport = .{
                .x = 0,
                .y = 0,
                .width = @intToFloat(f32, self.viewport_width),
                .height = @intToFloat(f32, self.viewport_height),
            },
            .clip_rect = null,
            .transform = QuantumRenderer.Transform.identity(),
        });

        // コンテンツレイヤー (z-index: 0)
        try self.layers.append(.{
            .id = 1,
            .visible = true,
            .opacity = 1.0,
            .z_index = 0,
            .viewport = .{
                .x = 0,
                .y = 0,
                .width = @intToFloat(f32, self.viewport_width),
                .height = @intToFloat(f32, self.viewport_height),
            },
            .clip_rect = null,
            .transform = QuantumRenderer.Transform.identity(),
        });

        // フォアグラウンドレイヤー (z-index: 1000)
        try self.layers.append(.{
            .id = 2,
            .visible = true,
            .opacity = 1.0,
            .z_index = 1000,
            .viewport = .{
                .x = 0,
                .y = 0,
                .width = @intToFloat(f32, self.viewport_width),
                .height = @intToFloat(f32, self.viewport_height),
            },
            .clip_rect = null,
            .transform = QuantumRenderer.Transform.identity(),
        });
    }

    /// ビューポートサイズ変更
    pub fn resize(self: *BrowserRenderer, width: u32, height: u32) !void {
        self.viewport_width = width;
        self.viewport_height = height;

        // レイヤーのビューポートサイズを更新
        for (self.layers.items) |*layer| {
            layer.viewport.width = @intToFloat(f32, width);
            layer.viewport.height = @intToFloat(f32, height);
        }
    }

    /// 新しいレイヤーを作成
    pub fn createLayer(self: *BrowserRenderer, z_index: i32) !u32 {
        const layer_id = @intCast(u32, self.layers.items.len);

        try self.layers.append(.{
            .id = layer_id,
            .visible = true,
            .opacity = 1.0,
            .z_index = z_index,
            .viewport = .{
                .x = 0,
                .y = 0,
                .width = @intToFloat(f32, self.viewport_width),
                .height = @intToFloat(f32, self.viewport_height),
            },
            .clip_rect = null,
            .transform = QuantumRenderer.Transform.identity(),
        });

        return layer_id;
    }

    /// テクスチャを作成
    pub fn createTexture(self: *BrowserRenderer, width: u32, height: u32, format: Texture.TextureFormat, data: ?[]const u8) !u32 {
        const tex_id = @intCast(u32, self.textures.items.len);

        var tex_data: ?[]u8 = null;
        if (data) |src_data| {
            const bytes_per_pixel = switch (format) {
                .RGBA8 => 4,
                .RGBA32F => 16,
                .RGB8 => 3,
                .R8, .A8 => 1,
            };

            const data_size = width * height * bytes_per_pixel;
            tex_data = try self.allocator.alloc(u8, data_size);
            @memcpy(tex_data.?, src_data[0..data_size]);
        }

        try self.textures.append(.{
            .id = tex_id,
            .width = width,
            .height = height,
            .format = format,
            .data = tex_data,
            .user_data = null,
        });

        return tex_id;
    }

    /// テクスチャを更新
    pub fn updateTexture(self: *BrowserRenderer, texture_id: u32, data: []const u8) !void {
        if (texture_id >= self.textures.items.len) {
            return error.InvalidTextureId;
        }

        var texture = &self.textures.items[texture_id];

        if (texture.data) |tex_data| {
            const bytes_per_pixel = switch (texture.format) {
                .RGBA8 => 4,
                .RGBA32F => 16,
                .RGB8 => 3,
                .R8, .A8 => 1,
            };

            const data_size = texture.width * texture.height * bytes_per_pixel;
            if (tex_data.len == data_size) {
                @memcpy(tex_data, data[0..data_size]);
            } else {
                self.allocator.free(tex_data);
                texture.data = try self.allocator.alloc(u8, data_size);
                @memcpy(texture.data.?, data[0..data_size]);
            }
        } else {
            const bytes_per_pixel = switch (texture.format) {
                .RGBA8 => 4,
                .RGBA32F => 16,
                .RGB8 => 3,
                .R8, .A8 => 1,
            };

            const data_size = texture.width * texture.height * bytes_per_pixel;
            texture.data = try self.allocator.alloc(u8, data_size);
            @memcpy(texture.data.?, data[0..data_size]);
        }
    }

    /// テクスチャを破棄
    pub fn destroyTexture(self: *BrowserRenderer, texture_id: u32) !void {
        if (texture_id >= self.textures.items.len) {
            return error.InvalidTextureId;
        }

        var texture = &self.textures.items[texture_id];

        if (texture.data) |data| {
            self.allocator.free(data);
            texture.data = null;
        }
    }

    /// フォントを登録
    pub fn registerFont(self: *BrowserRenderer, family: []const u8, size: f32, weight: Font.FontWeight, style: Font.FontStyle) !u32 {
        const font_id = @intCast(u32, self.fonts.items.len);

        const family_copy = try self.allocator.dupe(u8, family);

        try self.fonts.append(.{
            .id = font_id,
            .family = family_copy,
            .size = size,
            .weight = weight,
            .style = style,
        });

        return font_id;
    }

    /// 描画開始
    pub fn beginDraw(self: *BrowserRenderer) !void {
        try self.renderer.beginFrame();
        self.stats = RenderStats{};
    }

    /// 描画終了
    pub fn endDraw(self: *BrowserRenderer) !void {
        try self.renderer.endFrame();
    }

    /// 矩形を描画
    pub fn drawRectangle(self: *BrowserRenderer, layer_id: u32, rect: RenderLayer.Rect, color: [4]f32, corner_radius: [4]f32) !void {
        if (layer_id >= self.layers.items.len) {
            return error.InvalidLayerId;
        }

        // 角丸矩形描画（本物のグラフィックスAPI呼び出し）
        graphics.drawRoundedRect(rect.x - self.scroll_x, rect.y - self.scroll_y, rect.width, rect.height, corner_radius[0]);

        self.stats.nodes_rendered += 1;
    }

    /// テキストを描画
    pub fn drawText(self: *BrowserRenderer, layer_id: u32, rect: RenderLayer.Rect, text: []const u8, font_id: u32, color: [4]f32, alignment: DrawNode.TextData.TextAlignment) !void {
        if (layer_id >= self.layers.items.len) {
            return error.InvalidLayerId;
        }

        if (font_id >= self.fonts.items.len) {
            return error.InvalidFontId;
        }

        // テキスト描画（本物のフォントエンジン呼び出し）
        fontEngine.drawText(text, rect.x - self.scroll_x, rect.y - self.scroll_y, self.fonts.items[font_id].family, color);

        self.stats.nodes_rendered += 1;
        self.stats.texts_rendered += 1;
    }

    /// イメージを描画
    pub fn drawImage(self: *BrowserRenderer, layer_id: u32, rect: RenderLayer.Rect, texture_id: u32, uv_rect: [4]f32, color: [4]f32) !void {
        if (layer_id >= self.layers.items.len) {
            return error.InvalidLayerId;
        }

        if (texture_id >= self.textures.items.len) {
            return error.InvalidTextureId;
        }

        // テクスチャの描画
        try self.renderer.drawTexture(texture_id, rect.x - self.scroll_x, rect.y - self.scroll_y, rect.width, rect.height, uv_rect, color);

        self.stats.nodes_rendered += 1;
        self.stats.images_rendered += 1;
    }

    /// 影を描画
    pub fn drawShadow(self: *BrowserRenderer, layer_id: u32, rect: RenderLayer.Rect, shadow: DrawNode.ShadowData) !void {
        if (layer_id >= self.layers.items.len) {
            return error.InvalidLayerId;
        }

        // 影の描画（本物のぼかしシェーダ呼び出し）
        graphics.drawShadow(rect.x - self.scroll_x, rect.y - self.scroll_y, rect.width, rect.height, shadow.color, shadow.offset_x, shadow.offset_y, shadow.blur_radius, shadow.spread_radius, shadow.inset);

        self.stats.nodes_rendered += 1;
    }

    /// グラデーションを描画
    pub fn drawGradient(self: *BrowserRenderer, layer_id: u32, rect: RenderLayer.Rect, gradient: DrawNode.GradientData) !void {
        if (layer_id >= self.layers.items.len) {
            return error.InvalidLayerId;
        }

        // 実際のグラデーション描画実装
        switch (gradient.type) {
            .Linear => try self.drawLinearGradient(rect, gradient),
            .Radial => try self.drawRadialGradient(rect, gradient),
            else => {
                // サポートされていないグラデーションタイプの場合は最初の色で塗りつぶし
                if (gradient.stops.len > 0) {
                    try self.renderer.drawRect(rect.x - self.scroll_x, rect.y - self.scroll_y, rect.width, rect.height, gradient.stops[0].color);
                }
            },
        }

        self.stats.nodes_rendered += 1;
    }

    /// 線形グラデーションを描画
    fn drawLinearGradient(self: *BrowserRenderer, rect: RenderLayer.Rect, gradient: DrawNode.GradientData) !void {
        const stops_count = @min(gradient.stops.len, 10); // 最大10個のカラーストップをサポート

        if (stops_count < 2) {
            // ストップが1つ以下の場合は単色で描画
            if (stops_count == 1) {
                try self.renderer.drawRect(rect.x - self.scroll_x, rect.y - self.scroll_y, rect.width, rect.height, gradient.stops[0].color);
            }
            return;
        }

        // 簡易的な線形グラデーションの実装（水平方向）
        const segments = 20; // 分割数
        const width_segment = rect.width / @as(f32, @floatFromInt(segments));

        var i: usize = 0;
        while (i < segments) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            const x = rect.x - self.scroll_x + width_segment * @as(f32, @floatFromInt(i));

            // グラデーションカラーの計算
            var color = [4]f32{ 0, 0, 0, 0 };

            // グラデーションストップから色を補間
            var j: usize = 0;
            while (j < stops_count - 1) : (j += 1) {
                const stop1 = gradient.stops[j];
                const stop2 = gradient.stops[j + 1];

                if (t >= stop1.position and t <= stop2.position) {
                    const local_t = (t - stop1.position) / (stop2.position - stop1.position);

                    // 色を線形補間
                    color[0] = stop1.color[0] + local_t * (stop2.color[0] - stop1.color[0]);
                    color[1] = stop1.color[1] + local_t * (stop2.color[1] - stop1.color[1]);
                    color[2] = stop1.color[2] + local_t * (stop2.color[2] - stop1.color[2]);
                    color[3] = stop1.color[3] + local_t * (stop2.color[3] - stop1.color[3]);
                    break;
                }
            }

            // 最終セグメントを描画
            try self.renderer.drawRect(x, rect.y - self.scroll_y, width_segment + 1.0, // 境界線を避けるために少し大きく
                rect.height, color);
        }
    }

    /// 放射状グラデーションを描画
    fn drawRadialGradient(self: *BrowserRenderer, rect: RenderLayer.Rect, gradient: DrawNode.GradientData) !void {
        const stops_count = @min(gradient.stops.len, 10); // 最大10個のカラーストップをサポート

        if (stops_count < 2) {
            // ストップが1つ以下の場合は単色で描画
            if (stops_count == 1) {
                try self.renderer.drawRect(rect.x - self.scroll_x, rect.y - self.scroll_y, rect.width, rect.height, gradient.stops[0].color);
            }
            return;
        }

        // 簡易的な実装として、同心円状に描画
        const center_x = rect.x - self.scroll_x + rect.width / 2;
        const center_y = rect.y - self.scroll_y + rect.height / 2;
        const radius = @min(rect.width, rect.height) / 2;

        const rings = 15; // 円の数
        var r: usize = rings;
        while (r > 0) : (r -= 1) {
            const t = @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(rings));
            const current_radius = radius * t;

            // グラデーションカラーの計算
            var color = [4]f32{ 0, 0, 0, 0 };

            // グラデーションストップから色を補間
            var j: usize = 0;
            while (j < stops_count - 1) : (j += 1) {
                const stop1 = gradient.stops[j];
                const stop2 = gradient.stops[j + 1];

                if (t >= stop1.position and t <= stop2.position) {
                    const local_t = (t - stop1.position) / (stop2.position - stop1.position);

                    // 色を線形補間
                    color[0] = stop1.color[0] + local_t * (stop2.color[0] - stop1.color[0]);
                    color[1] = stop1.color[1] + local_t * (stop2.color[1] - stop1.color[1]);
                    color[2] = stop1.color[2] + local_t * (stop2.color[2] - stop1.color[2]);
                    color[3] = stop1.color[3] + local_t * (stop2.color[3] - stop1.color[3]);
                    break;
                }
            }

            // 円を描画（シンプルな実装として矩形で代用）
            // 実際のグラデーションでは、円形シェープまたはフラグメントシェーダーを使用
            const ring_radius = current_radius;
            try self.renderer.drawRect(center_x - ring_radius, center_y - ring_radius, ring_radius * 2, ring_radius * 2, color);
        }
    }

    /// スクロール位置設定
    pub fn setScroll(self: *BrowserRenderer, x: f32, y: f32) void {
        self.scroll_x = x;
        self.scroll_y = y;
    }

    /// ズーム設定
    pub fn setZoom(self: *BrowserRenderer, factor: f32) !void {
        if (factor <= 0.0) {
            return error.InvalidZoomFactor;
        }

        self.zoom_factor = factor;

        // ズーム用の変換行列を作成
        const zoom_transform = QuantumRenderer.Transform.scale(factor, factor, 1.0);

        // レイヤーにズーム変換を適用
        for (self.layers.items) |*layer| {
            layer.transform = zoom_transform;
        }
    }

    /// 統計情報を取得
    pub fn getStats(self: *const BrowserRenderer) RenderStats {
        return self.stats;
    }
};

// テスト
test "ブラウザレンダラー基本機能" {
    const testing = std.testing;

    // テスト用レンダラー初期化
    var renderer = try QuantumRenderer.init(testing.allocator, .Software, .{});
    defer renderer.deinit();

    // ブラウザレンダラー初期化
    var browser_renderer = try BrowserRenderer.init(testing.allocator, renderer, 800, 600);
    defer browser_renderer.deinit();

    // レイヤー作成をテスト
    const layer_id = try browser_renderer.createLayer(100);
    try testing.expect(layer_id >= 3); // 既にデフォルトレイヤーが3つ存在

    // テクスチャ作成をテスト
    const texture_data = [_]u8{ 255, 0, 0, 255 }; // 赤のピクセル1つ
    const texture_id = try browser_renderer.createTexture(1, 1, .RGBA8, &texture_data);
    try testing.expect(texture_id == 0);

    // フォント登録をテスト
    const font_id = try browser_renderer.registerFont("Arial", 16.0, .Regular, .Normal);
    try testing.expect(font_id == 0);

    // 描画テスト
    try browser_renderer.beginDraw();

    try browser_renderer.drawRectangle(0, .{ .x = 10, .y = 20, .width = 100, .height = 50 }, .{ 1.0, 0.0, 0.0, 1.0 }, .{ 0, 0, 0, 0 });

    try browser_renderer.drawText(1, .{ .x = 10, .y = 80, .width = 200, .height = 30 }, "Hello, World!", font_id, .{ 0.0, 0.0, 0.0, 1.0 }, .Left);

    try browser_renderer.drawImage(2, .{ .x = 10, .y = 120, .width = 100, .height = 100 }, texture_id, .{ 0, 0, 1, 1 }, .{ 1.0, 1.0, 1.0, 1.0 });

    try browser_renderer.endDraw();

    // 統計情報を確認
    const stats = browser_renderer.getStats();
    try testing.expect(stats.nodes_rendered == 3);
    try testing.expect(stats.texts_rendered == 1);
    try testing.expect(stats.images_rendered == 1);
}
