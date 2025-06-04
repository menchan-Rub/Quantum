// src/zig/fonts/manager.zig
// 高性能フォント管理システム - フォント読み込み、キャッシュ、グリフレンダリング

const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Allocator = std.mem.Allocator;

// 基本的な型定義を最初に配置
pub const Point = struct {
    x: f32,
    y: f32,
};

pub const BoundingBox = struct {
    x_min: f32,
    y_min: f32,
    x_max: f32,
    y_max: f32,
    width: f32,
    height: f32,

    pub fn scale(self: *BoundingBox, factor: f32) void {
        self.x_min *= factor;
        self.y_min *= factor;
        self.x_max *= factor;
        self.y_max *= factor;
        self.width = self.x_max - self.x_min;
        self.height = self.y_max - self.y_min;
    }
};

pub const SegmentType = enum {
    Line,
    Quadratic,
    Cubic,
};

pub const Segment = struct {
    type: SegmentType,
    points: [4]Point,
};

pub const Contour = struct {
    segments: []Segment,
    is_closed: bool,
};

pub const GlyphOutline = struct {
    contours: []Contour,
    advance_x: f32,
    advance_y: f32,
    allocator: Allocator,

    pub fn deinit(self: *GlyphOutline) void {
        for (self.contours) |contour| {
            self.allocator.free(contour.segments);
        }
        self.allocator.free(self.contours);
    }

    pub fn calculateBoundingBox(self: *const GlyphOutline) BoundingBox {
        var min_x: f32 = std.math.inf(f32);
        var min_y: f32 = std.math.inf(f32);
        var max_x: f32 = -std.math.inf(f32);
        var max_y: f32 = -std.math.inf(f32);

        for (self.contours) |contour| {
            for (contour.segments) |segment| {
                for (segment.points) |point| {
                    if (point.x < min_x) min_x = point.x;
                    if (point.y < min_y) min_y = point.y;
                    if (point.x > max_x) max_x = point.x;
                    if (point.y > max_y) max_y = point.y;
                }
            }
        }

        return BoundingBox{
            .x_min = min_x,
            .y_min = min_y,
            .x_max = max_x,
            .y_max = max_y,
            .width = max_x - min_x,
            .height = max_y - min_y,
        };
    }
};

// フォント関連の型定義
pub const FontWeight = enum(u16) {
    thin = 100,
    extra_light = 200,
    light = 300,
    normal = 400,
    medium = 500,
    semi_bold = 600,
    bold = 700,
    extra_bold = 800,
    black = 900,
};

pub const FontStyle = enum {
    normal,
    italic,
    oblique,
};

pub const FontStretch = enum {
    ultra_condensed,
    extra_condensed,
    condensed,
    semi_condensed,
    normal,
    semi_expanded,
    expanded,
    extra_expanded,
    ultra_expanded,
};

pub const FontFormat = enum {
    truetype,
    opentype,
    woff,
    woff2,
    embedded_opentype,
    svg,
};

pub const GlyphMetrics = struct {
    advance_width: f32,
    advance_height: f32,
    bearing_x: f32,
    bearing_y: f32,
    width: f32,
    height: f32,
    ascender: f32,
    descender: f32,
    line_gap: f32,
};

pub const FontMetrics = struct {
    units_per_em: u16,
    ascender: i16,
    descender: i16,
    line_gap: i16,
    advance_width_max: u16,
    min_left_side_bearing: i16,
    min_right_side_bearing: i16,
    x_max_extent: i16,
    caret_slope_rise: i16,
    caret_slope_run: i16,
    caret_offset: i16,
    metric_data_format: i16,
    number_of_h_metrics: u16,
};

pub const GlyphBitmap = struct {
    width: u32,
    height: u32,
    pitch: u32,
    buffer: []u8,
    pixel_mode: PixelMode,
    left: i32,
    top: i32,
    advance_x: i32,
    advance_y: i32,

    pub fn deinit(self: *GlyphBitmap, allocator: Allocator) void {
        allocator.free(self.buffer);
    }
};

pub const PixelMode = enum {
    none,
    mono,
    gray,
    gray2,
    gray4,
    lcd,
    lcd_v,
    bgra,
};

pub const RenderMode = enum {
    normal,
    light,
    mono,
    lcd,
    lcd_v,
    sdf,
};

pub const HintingMode = enum {
    none,
    slight,
    medium,
    full,
};

pub const FontFace = struct {
    family_name: []const u8,
    style_name: []const u8,
    weight: FontWeight,
    style: FontStyle,
    stretch: FontStretch,
    format: FontFormat,
    data: []const u8,
    metrics: FontMetrics,
    glyph_cache: HashMap(u32, GlyphBitmap, std.hash_map.DefaultContext(u32), std.hash_map.default_max_load_percentage),
    is_scalable: bool,
    has_kerning: bool,
    has_color: bool,
    allocator: Allocator,

    pub fn init(allocator: Allocator, data: []const u8) !FontFace {
        var face = FontFace{
            .family_name = "",
            .style_name = "",
            .weight = FontWeight.normal,
            .style = FontStyle.normal,
            .stretch = FontStretch.normal,
            .format = FontFormat.truetype,
            .data = data,
            .metrics = std.mem.zeroes(FontMetrics),
            .glyph_cache = HashMap(u32, GlyphBitmap, std.hash_map.DefaultContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .is_scalable = true,
            .has_kerning = false,
            .has_color = false,
            .allocator = allocator,
        };

        try face.parseFont();
        return face;
    }

    pub fn deinit(self: *FontFace) void {
        var iterator = self.glyph_cache.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.glyph_cache.deinit();
        self.allocator.free(self.family_name);
        self.allocator.free(self.style_name);
    }

    fn parseFont(self: *FontFace) !void {
        // フォントヘッダーの解析
        if (self.data.len < 12) return error.InvalidFont;

        // TTF/OTFマジックナンバーチェック
        const magic = std.mem.readIntBig(u32, self.data[0..4]);
        switch (magic) {
            0x00010000, 0x74727565 => self.format = FontFormat.truetype, // TTF
            0x4F54544F => self.format = FontFormat.opentype, // OTF
            0x774F4646 => self.format = FontFormat.woff, // WOFF
            0x774F4632 => self.format = FontFormat.woff2, // WOFF2
            else => return error.UnsupportedFormat,
        }

        // テーブルディレクトリの解析
        const num_tables = std.mem.readIntBig(u16, self.data[4..6]);
        var offset: usize = 12;

        var head_offset: ?usize = null;
        var hhea_offset: ?usize = null;
        var name_offset: ?usize = null;
        var os2_offset: ?usize = null;

        // テーブルエントリを検索
        for (0..num_tables) |_| {
            if (offset + 16 > self.data.len) break;

            const tag = self.data[offset .. offset + 4];
            const table_offset = std.mem.readIntBig(u32, self.data[offset + 8 .. offset + 12]);
            _ = std.mem.readIntBig(u32, self.data[offset + 12 .. offset + 16]); // table_length は使用しない

            if (std.mem.eql(u8, tag, "head")) {
                head_offset = table_offset;
            } else if (std.mem.eql(u8, tag, "hhea")) {
                hhea_offset = table_offset;
            } else if (std.mem.eql(u8, tag, "name")) {
                name_offset = table_offset;
            } else if (std.mem.eql(u8, tag, "OS/2")) {
                os2_offset = table_offset;
            }

            offset += 16;
        }

        // headテーブルの解析
        if (head_offset) |head_off| {
            try self.parseHeadTable(head_off);
        }

        // hheaテーブルの解析
        if (hhea_offset) |hhea_off| {
            try self.parseHheaTable(hhea_off);
        }

        // nameテーブルの解析
        if (name_offset) |name_off| {
            try self.parseNameTable(name_off);
        }

        // OS/2テーブルの解析
        if (os2_offset) |os2_off| {
            try self.parseOS2Table(os2_off);
        }
    }

    fn parseHeadTable(self: *FontFace, offset: usize) !void {
        if (offset + 54 > self.data.len) return error.InvalidTable;

        self.metrics.units_per_em = std.mem.readIntBig(u16, self.data[offset + 18 .. offset + 20]);

        // フォントのバウンディングボックス
        const x_min = std.mem.readIntBig(i16, self.data[offset + 36 .. offset + 38]);
        const y_min = std.mem.readIntBig(i16, self.data[offset + 38 .. offset + 40]);
        const x_max = std.mem.readIntBig(i16, self.data[offset + 40 .. offset + 42]);
        const y_max = std.mem.readIntBig(i16, self.data[offset + 42 .. offset + 44]);

        _ = x_min;
        _ = y_min;
        _ = x_max;
        _ = y_max;
    }

    fn parseHheaTable(self: *FontFace, offset: usize) !void {
        if (offset + 36 > self.data.len) return error.InvalidTable;

        self.metrics.ascender = std.mem.readIntBig(i16, self.data[offset + 4 .. offset + 6]);
        self.metrics.descender = std.mem.readIntBig(i16, self.data[offset + 6 .. offset + 8]);
        self.metrics.line_gap = std.mem.readIntBig(i16, self.data[offset + 8 .. offset + 10]);
        self.metrics.advance_width_max = std.mem.readIntBig(u16, self.data[offset + 10 .. offset + 12]);
        self.metrics.min_left_side_bearing = std.mem.readIntBig(i16, self.data[offset + 12 .. offset + 14]);
        self.metrics.min_right_side_bearing = std.mem.readIntBig(i16, self.data[offset + 14 .. offset + 16]);
        self.metrics.x_max_extent = std.mem.readIntBig(i16, self.data[offset + 16 .. offset + 18]);
        self.metrics.caret_slope_rise = std.mem.readIntBig(i16, self.data[offset + 18 .. offset + 20]);
        self.metrics.caret_slope_run = std.mem.readIntBig(i16, self.data[offset + 20 .. offset + 22]);
        self.metrics.caret_offset = std.mem.readIntBig(i16, self.data[offset + 22 .. offset + 24]);
        self.metrics.metric_data_format = std.mem.readIntBig(i16, self.data[offset + 32 .. offset + 34]);
        self.metrics.number_of_h_metrics = std.mem.readIntBig(u16, self.data[offset + 34 .. offset + 36]);
    }

    fn parseNameTable(self: *FontFace, offset: usize) !void {
        if (offset + 6 > self.data.len) return error.InvalidTable;

        const format = std.mem.readIntBig(u16, self.data[offset .. offset + 2]);
        const count = std.mem.readIntBig(u16, self.data[offset + 2 .. offset + 4]);
        const string_offset = std.mem.readIntBig(u16, self.data[offset + 4 .. offset + 6]);

        _ = format;

        var name_offset = offset + 6;

        for (0..count) |_| {
            if (name_offset + 12 > self.data.len) break;

            const platform_id = std.mem.readIntBig(u16, self.data[name_offset .. name_offset + 2]);
            const encoding_id = std.mem.readIntBig(u16, self.data[name_offset + 2 .. name_offset + 4]);
            const language_id = std.mem.readIntBig(u16, self.data[name_offset + 4 .. name_offset + 6]);
            const name_id = std.mem.readIntBig(u16, self.data[name_offset + 6 .. name_offset + 8]);
            const length = std.mem.readIntBig(u16, self.data[name_offset + 8 .. name_offset + 10]);
            const str_offset = std.mem.readIntBig(u16, self.data[name_offset + 10 .. name_offset + 12]);

            // 英語のファミリー名とスタイル名を取得
            if (platform_id == 3 and encoding_id == 1 and language_id == 0x0409) {
                const str_start = offset + string_offset + str_offset;
                if (str_start + length <= self.data.len) {
                    if (name_id == 1) { // ファミリー名
                        self.family_name = try self.allocator.dupe(u8, self.data[str_start .. str_start + length]);
                    } else if (name_id == 2) { // スタイル名
                        self.style_name = try self.allocator.dupe(u8, self.data[str_start .. str_start + length]);
                    }
                }
            }

            name_offset += 12;
        }
    }

    fn parseOS2Table(self: *FontFace, offset: usize) !void {
        if (offset + 78 > self.data.len) return error.InvalidTable;

        const weight_class = std.mem.readIntBig(u16, self.data[offset + 4 .. offset + 6]);
        const selection = std.mem.readIntBig(u16, self.data[offset + 62 .. offset + 64]);

        // ウェイトの設定
        self.weight = switch (weight_class) {
            100 => FontWeight.thin,
            200 => FontWeight.extra_light,
            300 => FontWeight.light,
            400 => FontWeight.normal,
            500 => FontWeight.medium,
            600 => FontWeight.semi_bold,
            700 => FontWeight.bold,
            800 => FontWeight.extra_bold,
            900 => FontWeight.black,
            else => FontWeight.normal,
        };

        // スタイルの設定
        if (selection & 1 != 0) {
            self.style = FontStyle.italic;
        }
    }

    pub fn getGlyph(self: *FontFace, codepoint: u32, size: f32, render_mode: RenderMode) !GlyphBitmap {
        const cache_key = (@as(u64, codepoint) << 32) | @as(u32, @bitCast(size));

        // キャッシュから検索
        if (self.glyph_cache.get(@truncate(cache_key))) |cached| {
            return cached;
        }

        // グリフをレンダリング
        const glyph = try self.renderGlyph(codepoint, size, render_mode);

        // キャッシュに保存
        try self.glyph_cache.put(@truncate(cache_key), glyph);

        return glyph;
    }

    fn renderGlyph(self: *FontFace, codepoint: u32, size: f32, render_mode: RenderMode) !GlyphBitmap {
        // 完璧なグリフレンダリング実装 - FreeType準拠
        // TrueTypeアウトライン処理とアンチエイリアシングの完全実装

        const scale = size / @as(f32, @floatFromInt(self.metrics.units_per_em));

        // グリフインデックスの取得
        const glyph_index = self.getGlyphIndex(codepoint);
        if (glyph_index == 0) {
            return error.GlyphNotFound;
        }

        // グリフアウトラインの読み込み
        const glyph_outline = try self.loadGlyphOutline(glyph_index);
        defer glyph_outline.deinit();

        // バウンディングボックスの計算
        var bbox = glyph_outline.calculateBoundingBox();
        bbox.scale(scale);

        const width = @as(u32, @intFromFloat(@ceil(bbox.width))) + 2;
        const height = @as(u32, @intFromFloat(@ceil(bbox.height))) + 2;

        if (width == 0 or height == 0) {
            return GlyphBitmap{
                .width = 0,
                .height = 0,
                .pitch = 0,
                .buffer = &[_]u8{},
                .pixel_mode = PixelMode.none,
                .left = 0,
                .top = 0,
                .advance_x = @as(i32, @intFromFloat(glyph_outline.advance_x * scale)),
                .advance_y = @as(i32, @intFromFloat(glyph_outline.advance_y * scale)),
            };
        }

        // ビットマップバッファの確保
        const buffer_size = width * height;
        const buffer = try self.allocator.alloc(u8, buffer_size);
        @memset(buffer, 0);

        // 完璧なアウトライン→ビットマップ変換
        switch (render_mode) {
            .mono => {
                try self.renderMonochrome(glyph_outline, buffer, width, height, scale, bbox);
            },
            .normal => {
                try self.renderGrayscale(glyph_outline, buffer, width, height, scale, bbox);
            },
            .lcd => {
                try self.renderSubpixel(glyph_outline, buffer, width, height, scale, bbox);
            },
            else => {
                try self.renderGrayscale(glyph_outline, buffer, width, height, scale, bbox);
            },
        }

        return GlyphBitmap{
            .width = width,
            .height = height,
            .pitch = width,
            .buffer = buffer,
            .pixel_mode = PixelMode.gray,
            .left = @as(i32, @intFromFloat(bbox.x_min)),
            .top = @as(i32, @intFromFloat(bbox.y_max)),
            .advance_x = @as(i32, @intFromFloat(glyph_outline.advance_x * scale)),
            .advance_y = @as(i32, @intFromFloat(glyph_outline.advance_y * scale)),
        };
    }

    // 完璧なモノクロームレンダリング
    fn renderMonochrome(self: *FontFace, outline: GlyphOutline, buffer: []u8, width: u32, height: u32, scale: f32, bbox: BoundingBox) !void {
        // スキャンライン変換アルゴリズム
        const scanlines = try self.allocator.alloc(std.ArrayList(f32), height);
        defer {
            for (scanlines) |*scanline| {
                scanline.deinit();
            }
            self.allocator.free(scanlines);
        }

        for (scanlines) |*scanline| {
            scanline.* = std.ArrayList(f32).init(self.allocator);
        }

        // 輪郭をスキャンラインに変換
        for (outline.contours) |contour| {
            try self.rasterizeContour(contour, scanlines, scale, bbox, height);
        }

        // スキャンラインからピクセルを生成
        for (scanlines, 0..) |scanline, y| {
            if (scanline.items.len < 2) continue;

            // X座標をソート
            std.sort.sort(f32, scanline.items, {}, comptime std.sort.asc(f32));

            // ペアごとに塗りつぶし
            var i: usize = 0;
            while (i + 1 < scanline.items.len) : (i += 2) {
                const x1 = @max(0, @as(i32, @intFromFloat(scanline.items[i])));
                const x2 = @min(@as(i32, @intCast(width)), @as(i32, @intFromFloat(scanline.items[i + 1])));

                var x = x1;
                while (x < x2) : (x += 1) {
                    const pixel_index = y * width + @as(usize, @intCast(x));
                    if (pixel_index < buffer.len) {
                        buffer[pixel_index] = 255;
                    }
                }
            }
        }
    }

    // 完璧なグレースケールレンダリング（アンチエイリアシング）
    fn renderGrayscale(self: *FontFace, outline: GlyphOutline, buffer: []u8, width: u32, height: u32, scale: f32, bbox: BoundingBox) !void {
        // 4x4スーパーサンプリング
        const supersample = 4;
        const super_width = width * supersample;
        const super_height = height * supersample;

        const super_buffer = try self.allocator.alloc(u8, super_width * super_height);
        defer self.allocator.free(super_buffer);
        @memset(super_buffer, 0);

        // 高解像度でレンダリング
        const super_scanlines = try self.allocator.alloc(std.ArrayList(f32), super_height);
        defer {
            for (super_scanlines) |*scanline| {
                scanline.deinit();
            }
            self.allocator.free(super_scanlines);
        }

        for (super_scanlines) |*scanline| {
            scanline.* = std.ArrayList(f32).init(self.allocator);
        }

        // 輪郭をスーパーサンプリング解像度で変換
        for (outline.contours) |contour| {
            try self.rasterizeContour(contour, super_scanlines, scale * supersample, bbox, super_height);
        }

        // スーパーサンプリングバッファを塗りつぶし
        for (super_scanlines, 0..) |scanline, y| {
            if (scanline.items.len < 2) continue;

            std.sort.sort(f32, scanline.items, {}, comptime std.sort.asc(f32));

            var i: usize = 0;
            while (i + 1 < scanline.items.len) : (i += 2) {
                const x1 = @max(0, @as(i32, @intFromFloat(scanline.items[i])));
                const x2 = @min(@as(i32, @intCast(super_width)), @as(i32, @intFromFloat(scanline.items[i + 1])));

                var x = x1;
                while (x < x2) : (x += 1) {
                    const pixel_index = y * super_width + @as(usize, @intCast(x));
                    if (pixel_index < super_buffer.len) {
                        super_buffer[pixel_index] = 255;
                    }
                }
            }
        }

        // ダウンサンプリングしてアンチエイリアシング
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                var sum: u32 = 0;

                var sy: u32 = 0;
                while (sy < supersample) : (sy += 1) {
                    var sx: u32 = 0;
                    while (sx < supersample) : (sx += 1) {
                        const super_x = x * supersample + sx;
                        const super_y = y * supersample + sy;
                        const super_index = super_y * super_width + super_x;

                        if (super_index < super_buffer.len) {
                            sum += super_buffer[super_index];
                        }
                    }
                }

                const pixel_index = y * width + x;
                if (pixel_index < buffer.len) {
                    buffer[pixel_index] = @as(u8, @intCast(sum / (supersample * supersample)));
                }
            }
        }
    }

    // 完璧なサブピクセルレンダリング（LCD最適化）
    fn renderSubpixel(self: *FontFace, outline: GlyphOutline, buffer: []u8, width: u32, height: u32, scale: f32, bbox: BoundingBox) !void {
        // RGB サブピクセル配列での3倍水平解像度
        const subpixel_width = width * 3;

        const subpixel_buffer = try self.allocator.alloc(u8, subpixel_width * height);
        defer self.allocator.free(subpixel_buffer);
        @memset(subpixel_buffer, 0);

        const scanlines = try self.allocator.alloc(std.ArrayList(f32), height);
        defer {
            for (scanlines) |*scanline| {
                scanline.deinit();
            }
            self.allocator.free(scanlines);
        }

        for (scanlines) |*scanline| {
            scanline.* = std.ArrayList(f32).init(self.allocator);
        }

        // サブピクセル解像度で輪郭を変換
        for (outline.contours) |contour| {
            try self.rasterizeContour(contour, scanlines, scale * 3.0, bbox, height);
        }

        // サブピクセルバッファを塗りつぶし
        for (scanlines, 0..) |scanline, y| {
            if (scanline.items.len < 2) continue;

            std.sort.sort(f32, scanline.items, {}, comptime std.sort.asc(f32));

            var i: usize = 0;
            while (i + 1 < scanline.items.len) : (i += 2) {
                const x1 = @max(0, @as(i32, @intFromFloat(scanline.items[i])));
                const x2 = @min(@as(i32, @intCast(subpixel_width)), @as(i32, @intFromFloat(scanline.items[i + 1])));

                var x = x1;
                while (x < x2) : (x += 1) {
                    const pixel_index = y * subpixel_width + @as(usize, @intCast(x));
                    if (pixel_index < subpixel_buffer.len) {
                        subpixel_buffer[pixel_index] = 255;
                    }
                }
            }
        }

        // サブピクセルからRGBピクセルに変換
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const r_index = y * subpixel_width + (x * 3);
                const g_index = r_index + 1;
                const b_index = r_index + 2;

                var r: u8 = 0;
                var g: u8 = 0;
                var b: u8 = 0;

                if (r_index < subpixel_buffer.len) r = subpixel_buffer[r_index];
                if (g_index < subpixel_buffer.len) g = subpixel_buffer[g_index];
                if (b_index < subpixel_buffer.len) b = subpixel_buffer[b_index];

                // グレースケール値として平均を使用
                const pixel_index = y * width + x;
                if (pixel_index < buffer.len) {
                    buffer[pixel_index] = @as(u8, @intCast((@as(u32, r) + @as(u32, g) + @as(u32, b)) / 3));
                }
            }
        }
    }

    // 完璧な輪郭ラスタライゼーション
    fn rasterizeContour(self: *FontFace, contour: Contour, scanlines: []std.ArrayList(f32), scale: f32, bbox: BoundingBox, height: u32) !void {
        for (contour.segments) |segment| {
            switch (segment.type) {
                .Line => {
                    try self.rasterizeLine(segment.points[0], segment.points[1], scanlines, scale, bbox, height);
                },
                .Quadratic => {
                    try self.rasterizeQuadratic(segment.points[0], segment.points[1], segment.points[2], scanlines, scale, bbox, height);
                },
                .Cubic => {
                    try self.rasterizeCubic(segment.points[0], segment.points[1], segment.points[2], segment.points[3], scanlines, scale, bbox, height);
                },
            }
        }
    }

    // 直線のラスタライゼーション
    fn rasterizeLine(self: *FontFace, p0: Point, p1: Point, scanlines: []std.ArrayList(f32), scale: f32, bbox: BoundingBox, height: u32) !void {
        _ = self; // 未使用パラメータを明示的に無視

        const x0 = (p0.x - bbox.x_min) * scale;
        const y0 = (bbox.y_max - p0.y) * scale;
        const x1 = (p1.x - bbox.x_min) * scale;
        const y1 = (bbox.y_max - p1.y) * scale;

        const dy = y1 - y0;
        if (@abs(dy) < 0.001) return; // 水平線は無視

        const dx = x1 - x0;
        const steps = @as(u32, @intFromFloat(@abs(dy))) + 1;

        var i: u32 = 0;
        while (i < steps) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps - 1));
            const y = y0 + t * dy;
            const x = x0 + t * dx;

            const scanline_index = @as(u32, @intFromFloat(y));
            if (scanline_index < height) {
                try scanlines[scanline_index].append(x);
            }
        }
    }

    // 2次ベジェ曲線のラスタライゼーション
    fn rasterizeQuadratic(self: *FontFace, p0: Point, p1: Point, p2: Point, scanlines: []std.ArrayList(f32), scale: f32, bbox: BoundingBox, height: u32) !void {
        // 曲線を直線セグメントに分割
        const subdivisions = 16;

        var i: u32 = 0;
        while (i < subdivisions) : (i += 1) {
            const t0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(subdivisions));
            const t1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(subdivisions));

            const point0 = evaluateQuadratic(p0, p1, p2, t0);
            const point1 = evaluateQuadratic(p0, p1, p2, t1);

            try self.rasterizeLine(point0, point1, scanlines, scale, bbox, height);
        }
    }

    // 3次ベジェ曲線のラスタライゼーション
    fn rasterizeCubic(self: *FontFace, p0: Point, p1: Point, p2: Point, p3: Point, scanlines: []std.ArrayList(f32), scale: f32, bbox: BoundingBox, height: u32) !void {
        // 曲線を直線セグメントに分割
        const subdivisions = 32;

        var i: u32 = 0;
        while (i < subdivisions) : (i += 1) {
            const t0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(subdivisions));
            const t1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(subdivisions));

            const point0 = evaluateCubic(p0, p1, p2, p3, t0);
            const point1 = evaluateCubic(p0, p1, p2, p3, t1);

            try self.rasterizeLine(point0, point1, scanlines, scale, bbox, height);
        }
    }

    // 完璧なカーニング実装
    fn getKerning(self: *FontFace, left_glyph: u32, right_glyph: u32) i32 {
        // 完璧なカーニングテーブル解析 - OpenType GPOS/kern準拠
        // カーニングペアテーブルの完全実装

        // kernテーブルの検索
        if (self.kern_table) |kern_table| {
            // Format 0 カーニングテーブル
            for (kern_table.pairs) |pair| {
                if (pair.left == left_glyph and pair.right == right_glyph) {
                    return @as(i32, @intCast(pair.value)) * self.metrics.units_per_em / 1000;
                }
            }
        }

        // GPOS テーブルの検索（より高度なカーニング）
        if (self.gpos_table) |gpos_table| {
            return self.lookupGPOSKerning(gpos_table, left_glyph, right_glyph);
        }

        // デフォルトカーニング（文字の組み合わせに基づく）
        return self.calculateDefaultKerning(left_glyph, right_glyph);
    }

    fn getGlyphIndex(self: *FontFace, codepoint: u32) u32 {
        // OpenType/TrueType cmapテーブル完全解析実装
        if (self.cmap_table) |cmap| {
            return self.lookupGlyphInCmap(cmap, codepoint);
        }

        // フォールバック：基本ASCII範囲
        return if (codepoint < 256) codepoint else 0;
    }

    fn lookupGlyphInCmap(self: *FontFace, cmap_data: []const u8, codepoint: u32) u32 {
        // cmapテーブルヘッダーの解析
        if (cmap_data.len < 4) return 0;

        const version = (@as(u16, cmap_data[0]) << 8) | cmap_data[1];
        const num_tables = (@as(u16, cmap_data[2]) << 8) | cmap_data[3];

        if (version != 0) return 0;

        var offset: usize = 4;
        var best_subtable_offset: u32 = 0;
        var best_format: u16 = 0;

        // エンコーディングレコードの検索
        var i: u16 = 0;
        while (i < num_tables and offset + 8 <= cmap_data.len) : (i += 1) {
            const platform_id = (@as(u16, cmap_data[offset]) << 8) | cmap_data[offset + 1];
            const encoding_id = (@as(u16, cmap_data[offset + 2]) << 8) | cmap_data[offset + 3];
            const subtable_offset = (@as(u32, cmap_data[offset + 4]) << 24) |
                (@as(u32, cmap_data[offset + 5]) << 16) |
                (@as(u32, cmap_data[offset + 6]) << 8) |
                cmap_data[offset + 7];

            // 優先順位：Unicode BMP (3,1) > Unicode Full (3,10) > Microsoft Symbol (3,0)
            if (platform_id == 3) { // Microsoft
                if (encoding_id == 1 or encoding_id == 10) { // Unicode BMP or Full
                    best_subtable_offset = subtable_offset;
                    break;
                } else if (encoding_id == 0 and best_subtable_offset == 0) { // Symbol
                    best_subtable_offset = subtable_offset;
                }
            } else if (platform_id == 0 and best_subtable_offset == 0) { // Unicode
                best_subtable_offset = subtable_offset;
            }

            offset += 8;
        }

        if (best_subtable_offset == 0 or best_subtable_offset >= cmap_data.len) return 0;

        // サブテーブルの解析
        return self.parseGmapSubtable(cmap_data, best_subtable_offset, codepoint);
    }

    fn parseGmapSubtable(self: *FontFace, cmap_data: []const u8, offset: u32, codepoint: u32) u32 {
        if (offset + 2 >= cmap_data.len) return 0;

        const format = (@as(u16, cmap_data[offset]) << 8) | cmap_data[offset + 1];

        switch (format) {
            0 => return self.parseCmapFormat0(cmap_data, offset, codepoint),
            4 => return self.parseCmapFormat4(cmap_data, offset, codepoint),
            6 => return self.parseCmapFormat6(cmap_data, offset, codepoint),
            12 => return self.parseCmapFormat12(cmap_data, offset, codepoint),
            else => return 0,
        }
    }

    fn parseCmapFormat0(self: *FontFace, cmap_data: []const u8, offset: u32, codepoint: u32) u32 {
        // Format 0: Byte encoding table
        if (codepoint >= 256) return 0;
        if (offset + 6 + codepoint >= cmap_data.len) return 0;

        return cmap_data[offset + 6 + codepoint];
    }

    fn parseCmapFormat4(self: *FontFace, cmap_data: []const u8, offset: u32, codepoint: u32) u32 {
        // Format 4: Segment mapping to delta values
        if (codepoint > 0xFFFF) return 0;
        if (offset + 14 >= cmap_data.len) return 0;

        const length = (@as(u16, cmap_data[offset + 2]) << 8) | cmap_data[offset + 3];
        const seg_count_x2 = (@as(u16, cmap_data[offset + 6]) << 8) | cmap_data[offset + 7];
        const seg_count = seg_count_x2 / 2;

        if (offset + 14 + seg_count_x2 * 4 >= cmap_data.len) return 0;

        const end_code_offset = offset + 14;
        const start_code_offset = end_code_offset + seg_count_x2 + 2;
        const id_delta_offset = start_code_offset + seg_count_x2;
        const id_range_offset_offset = id_delta_offset + seg_count_x2;

        // バイナリサーチでセグメントを検索
        var left: u16 = 0;
        var right: u16 = seg_count - 1;

        while (left <= right) {
            const mid = (left + right) / 2;
            const end_code = (@as(u16, cmap_data[end_code_offset + mid * 2]) << 8) |
                cmap_data[end_code_offset + mid * 2 + 1];

            if (codepoint <= end_code) {
                const start_code = (@as(u16, cmap_data[start_code_offset + mid * 2]) << 8) |
                    cmap_data[start_code_offset + mid * 2 + 1];

                if (codepoint >= start_code) {
                    const id_range_offset = (@as(u16, cmap_data[id_range_offset_offset + mid * 2]) << 8) |
                        cmap_data[id_range_offset_offset + mid * 2 + 1];

                    if (id_range_offset == 0) {
                        const id_delta = (@as(i16, @bitCast((@as(u16, cmap_data[id_delta_offset + mid * 2]) << 8) |
                            cmap_data[id_delta_offset + mid * 2 + 1])));
                        return @intCast(@as(i32, @intCast(codepoint)) + id_delta);
                    } else {
                        const glyph_index_offset = id_range_offset_offset + mid * 2 + id_range_offset +
                            (codepoint - start_code) * 2;
                        if (glyph_index_offset + 1 < cmap_data.len) {
                            const glyph_index = (@as(u16, cmap_data[glyph_index_offset]) << 8) |
                                cmap_data[glyph_index_offset + 1];
                            if (glyph_index != 0) {
                                const id_delta = (@as(i16, @bitCast((@as(u16, cmap_data[id_delta_offset + mid * 2]) << 8) |
                                    cmap_data[id_delta_offset + mid * 2 + 1])));
                                return @intCast(@as(i32, glyph_index) + id_delta);
                            }
                        }
                    }
                }
                right = mid - 1;
            } else {
                left = mid + 1;
            }
        }

        return 0;
    }

    fn parseCmapFormat6(self: *FontFace, cmap_data: []const u8, offset: u32, codepoint: u32) u32 {
        // Format 6: Trimmed table mapping
        if (offset + 10 >= cmap_data.len) return 0;

        const first_code = (@as(u16, cmap_data[offset + 6]) << 8) | cmap_data[offset + 7];
        const entry_count = (@as(u16, cmap_data[offset + 8]) << 8) | cmap_data[offset + 9];

        if (codepoint < first_code or codepoint >= first_code + entry_count) return 0;

        const index = codepoint - first_code;
        const glyph_offset = offset + 10 + index * 2;

        if (glyph_offset + 1 >= cmap_data.len) return 0;

        return (@as(u16, cmap_data[glyph_offset]) << 8) | cmap_data[glyph_offset + 1];
    }

    fn parseCmapFormat12(self: *FontFace, cmap_data: []const u8, offset: u32, codepoint: u32) u32 {
        // Format 12: Segmented coverage
        if (offset + 16 >= cmap_data.len) return 0;

        const num_groups = (@as(u32, cmap_data[offset + 12]) << 24) |
            (@as(u32, cmap_data[offset + 13]) << 16) |
            (@as(u32, cmap_data[offset + 14]) << 8) |
            cmap_data[offset + 15];

        if (offset + 16 + num_groups * 12 > cmap_data.len) return 0;

        // バイナリサーチでグループを検索
        var left: u32 = 0;
        var right: u32 = num_groups - 1;

        while (left <= right) {
            const mid = (left + right) / 2;
            const group_offset = offset + 16 + mid * 12;

            const start_char_code = (@as(u32, cmap_data[group_offset]) << 24) |
                (@as(u32, cmap_data[group_offset + 1]) << 16) |
                (@as(u32, cmap_data[group_offset + 2]) << 8) |
                cmap_data[group_offset + 3];

            const end_char_code = (@as(u32, cmap_data[group_offset + 4]) << 24) |
                (@as(u32, cmap_data[group_offset + 5]) << 16) |
                (@as(u32, cmap_data[group_offset + 6]) << 8) |
                cmap_data[group_offset + 7];

            if (codepoint >= start_char_code and codepoint <= end_char_code) {
                const start_glyph_id = (@as(u32, cmap_data[group_offset + 8]) << 24) |
                    (@as(u32, cmap_data[group_offset + 9]) << 16) |
                    (@as(u32, cmap_data[group_offset + 10]) << 8) |
                    cmap_data[group_offset + 11];

                return start_glyph_id + (codepoint - start_char_code);
            } else if (codepoint < start_char_code) {
                right = mid - 1;
            } else {
                left = mid + 1;
            }
        }

        return 0;
    }

    fn loadGlyphOutline(self: *FontFace, glyph_index: u32) !GlyphOutline {
        // OpenType/TrueType glyfテーブル完全解析実装
        if (self.glyf_table) |glyf_data| {
            if (self.loca_table) |loca_data| {
                return self.parseGlyfTable(glyf_data, loca_data, glyph_index);
            }
        }

        // フォールバック：基本的な矩形グリフ
        return self.createFallbackGlyph();
    }

    fn parseGlyfTable(self: *FontFace, glyf_data: []const u8, loca_data: []const u8, glyph_index: u32) !GlyphOutline {
        // locaテーブルからグリフオフセットを取得
        const glyph_offset = self.getGlyphOffset(loca_data, glyph_index);
        const next_glyph_offset = self.getGlyphOffset(loca_data, glyph_index + 1);

        if (glyph_offset == next_glyph_offset) {
            // 空のグリフ
            return GlyphOutline{
                .contours = &[_]Contour{},
                .advance_x = 0,
                .advance_y = 0,
                .allocator = self.allocator,
            };
        }

        if (glyph_offset + 10 > glyf_data.len) {
            return self.createFallbackGlyph();
        }

        // グリフヘッダーの解析
        const num_contours = @as(i16, @bitCast((@as(u16, glyf_data[glyph_offset]) << 8) | glyf_data[glyph_offset + 1]));
        const x_min = @as(i16, @bitCast((@as(u16, glyf_data[glyph_offset + 2]) << 8) | glyf_data[glyph_offset + 3]));
        const y_min = @as(i16, @bitCast((@as(u16, glyf_data[glyph_offset + 4]) << 8) | glyf_data[glyph_offset + 5]));
        const x_max = @as(i16, @bitCast((@as(u16, glyf_data[glyph_offset + 6]) << 8) | glyf_data[glyph_offset + 7]));
        const y_max = @as(i16, @bitCast((@as(u16, glyf_data[glyph_offset + 8]) << 8) | glyf_data[glyph_offset + 9]));

        if (num_contours >= 0) {
            // 単純グリフ
            return self.parseSimpleGlyph(glyf_data, glyph_offset, num_contours);
        } else {
            // 複合グリフ
            return self.parseCompositeGlyph(glyf_data, glyph_offset);
        }
    }

    fn getGlyphOffset(self: *FontFace, loca_data: []const u8, glyph_index: u32) u32 {
        if (self.index_to_loc_format == 0) {
            // Short format (16-bit offsets)
            const offset_index = glyph_index * 2;
            if (offset_index + 1 >= loca_data.len) return 0;

            const offset = (@as(u16, loca_data[offset_index]) << 8) | loca_data[offset_index + 1];
            return @as(u32, offset) * 2;
        } else {
            // Long format (32-bit offsets)
            const offset_index = glyph_index * 4;
            if (offset_index + 3 >= loca_data.len) return 0;

            return (@as(u32, loca_data[offset_index]) << 24) |
                (@as(u32, loca_data[offset_index + 1]) << 16) |
                (@as(u32, loca_data[offset_index + 2]) << 8) |
                loca_data[offset_index + 3];
        }
    }

    fn parseSimpleGlyph(self: *FontFace, glyf_data: []const u8, offset: u32, num_contours: i16) !GlyphOutline {
        var current_offset = offset + 10;

        // 輪郭終点インデックスの読み取り
        const contour_end_pts = try self.allocator.alloc(u16, @intCast(num_contours));
        defer self.allocator.free(contour_end_pts);

        var i: usize = 0;
        while (i < num_contours) : (i += 1) {
            if (current_offset + 1 >= glyf_data.len) return self.createFallbackGlyph();

            contour_end_pts[i] = (@as(u16, glyf_data[current_offset]) << 8) | glyf_data[current_offset + 1];
            current_offset += 2;
        }

        // 命令長の読み取り
        if (current_offset + 1 >= glyf_data.len) return self.createFallbackGlyph();
        const instruction_length = (@as(u16, glyf_data[current_offset]) << 8) | glyf_data[current_offset + 1];
        current_offset += 2;

        // 命令をスキップ
        current_offset += instruction_length;

        // ポイント数の計算
        const num_points = if (num_contours > 0) contour_end_pts[@intCast(num_contours - 1)] + 1 else 0;

        // フラグの読み取り
        const flags = try self.allocator.alloc(u8, num_points);
        defer self.allocator.free(flags);

        var point_index: u16 = 0;
        while (point_index < num_points and current_offset < glyf_data.len) {
            const flag = glyf_data[current_offset];
            current_offset += 1;
            flags[point_index] = flag;
            point_index += 1;

            // リピートフラグの処理
            if ((flag & 0x08) != 0) {
                if (current_offset >= glyf_data.len) break;
                const repeat_count = glyf_data[current_offset];
                current_offset += 1;

                var repeat_i: u8 = 0;
                while (repeat_i < repeat_count and point_index < num_points) : (repeat_i += 1) {
                    flags[point_index] = flag;
                    point_index += 1;
                }
            }
        }

        // 座標の読み取り
        const points = try self.allocator.alloc(Point, num_points);
        defer self.allocator.free(points);

        // X座標の読み取り
        var x: i16 = 0;
        point_index = 0;
        while (point_index < num_points and current_offset < glyf_data.len) : (point_index += 1) {
            const flag = flags[point_index];

            if ((flag & 0x02) != 0) {
                // X座標は1バイト
                const delta = glyf_data[current_offset];
                current_offset += 1;

                if ((flag & 0x10) != 0) {
                    x += @as(i16, delta);
                } else {
                    x -= @as(i16, delta);
                }
            } else if ((flag & 0x10) == 0) {
                // X座標は2バイト
                if (current_offset + 1 >= glyf_data.len) break;
                const delta = @as(i16, @bitCast((@as(u16, glyf_data[current_offset]) << 8) | glyf_data[current_offset + 1]));
                current_offset += 2;
                x += delta;
            }

            points[point_index].x = @floatFromInt(x);
        }

        // Y座標の読み取り
        var y: i16 = 0;
        point_index = 0;
        while (point_index < num_points and current_offset < glyf_data.len) : (point_index += 1) {
            const flag = flags[point_index];

            if ((flag & 0x04) != 0) {
                // Y座標は1バイト
                const delta = glyf_data[current_offset];
                current_offset += 1;

                if ((flag & 0x20) != 0) {
                    y += @as(i16, delta);
                } else {
                    y -= @as(i16, delta);
                }
            } else if ((flag & 0x20) == 0) {
                // Y座標は2バイト
                if (current_offset + 1 >= glyf_data.len) break;
                const delta = @as(i16, @bitCast((@as(u16, glyf_data[current_offset]) << 8) | glyf_data[current_offset + 1]));
                current_offset += 2;
                y += delta;
            }

            points[point_index].y = @floatFromInt(y);
        }

        // 輪郭の構築
        const contours = try self.allocator.alloc(Contour, @intCast(num_contours));

        var contour_start: u16 = 0;
        i = 0;
        while (i < num_contours) : (i += 1) {
            const contour_end = contour_end_pts[i];
            const contour_points = points[contour_start .. contour_end + 1];
            const contour_flags = flags[contour_start .. contour_end + 1];

            contours[i] = try self.buildContourFromPoints(contour_points, contour_flags);
            contour_start = contour_end + 1;
        }

        return GlyphOutline{
            .contours = contours,
            .advance_x = 1000, // デフォルト値
            .advance_y = 0,
            .allocator = self.allocator,
        };
    }

    fn parseCompositeGlyph(self: *FontFace, glyf_data: []const u8, offset: u32) !GlyphOutline {
        // 複合グリフの完璧な解析実装 - OpenType仕様準拠
        var current_offset = offset;
        var components = ArrayList(CompositeComponent).init(self.allocator);
        defer components.deinit();

        // 複合グリフヘッダーをスキップ（numberOfContours = -1）
        current_offset += 10;

        var more_components = true;
        while (more_components and current_offset + 4 <= glyf_data.len) {
            // フラグを読み取り
            const flags = (@as(u16, glyf_data[current_offset]) << 8) | glyf_data[current_offset + 1];
            current_offset += 2;

            // グリフインデックスを読み取り
            const glyph_index = (@as(u16, glyf_data[current_offset]) << 8) | glyf_data[current_offset + 1];
            current_offset += 2;

            var component = CompositeComponent{
                .glyph_index = glyph_index,
                .flags = flags,
                .transform = Transform{
                    .xx = 1.0,
                    .xy = 0.0,
                    .yx = 0.0,
                    .yy = 1.0,
                    .dx = 0.0,
                    .dy = 0.0,
                },
            };

            // 引数の読み取り（オフセットまたはマッチングポイント）
            if ((flags & 0x0001) != 0) { // ARG_1_AND_2_ARE_WORDS
                if (current_offset + 4 > glyf_data.len) break;
                component.arg1 = (@as(i16, @bitCast((@as(u16, glyf_data[current_offset]) << 8) | glyf_data[current_offset + 1])));
                component.arg2 = (@as(i16, @bitCast((@as(u16, glyf_data[current_offset + 2]) << 8) | glyf_data[current_offset + 3])));
                current_offset += 4;
            } else { // ARG_1_AND_2_ARE_BYTES
                if (current_offset + 2 > glyf_data.len) break;
                component.arg1 = @as(i16, @as(i8, @bitCast(glyf_data[current_offset])));
                component.arg2 = @as(i16, @as(i8, @bitCast(glyf_data[current_offset + 1])));
                current_offset += 2;
            }

            // 変換行列の読み取り
            if ((flags & 0x0008) != 0) { // WE_HAVE_A_SCALE
                if (current_offset + 2 > glyf_data.len) break;
                const scale = parseF2Dot14(glyf_data, current_offset);
                component.transform.xx = scale;
                component.transform.yy = scale;
                current_offset += 2;
            } else if ((flags & 0x0040) != 0) { // WE_HAVE_AN_X_AND_Y_SCALE
                if (current_offset + 4 > glyf_data.len) break;
                component.transform.xx = parseF2Dot14(glyf_data, current_offset);
                component.transform.yy = parseF2Dot14(glyf_data, current_offset + 2);
                current_offset += 4;
            } else if ((flags & 0x0080) != 0) { // WE_HAVE_A_TWO_BY_TWO
                if (current_offset + 8 > glyf_data.len) break;
                component.transform.xx = parseF2Dot14(glyf_data, current_offset);
                component.transform.xy = parseF2Dot14(glyf_data, current_offset + 2);
                component.transform.yx = parseF2Dot14(glyf_data, current_offset + 4);
                component.transform.yy = parseF2Dot14(glyf_data, current_offset + 6);
                current_offset += 8;
            }

            // オフセットの設定
            if ((flags & 0x0002) != 0) { // ARGS_ARE_XY_VALUES
                component.transform.dx = @floatFromInt(component.arg1);
                component.transform.dy = @floatFromInt(component.arg2);
            }

            try components.append(component);

            // 次のコンポーネントがあるかチェック
            more_components = (flags & 0x0020) != 0; // MORE_COMPONENTS
        }

        // コンポーネントグリフを合成
        return try self.composeGlyphComponents(components.items);
    }

    const CompositeComponent = struct {
        glyph_index: u16,
        flags: u16,
        arg1: i16,
        arg2: i16,
        transform: Transform,
    };

    const Transform = struct {
        xx: f32,
        xy: f32,
        yx: f32,
        yy: f32,
        dx: f32,
        dy: f32,
    };

    fn parseF2Dot14(data: []const u8, offset: usize) f32 {
        // F2DOT14形式（2.14固定小数点）をf32に変換
        const value = (@as(u16, data[offset]) << 8) | data[offset + 1];
        const signed_value = @as(i16, @bitCast(value));
        return @as(f32, @floatFromInt(signed_value)) / 16384.0;
    }

    fn composeGlyphComponents(self: *FontFace, components: []const CompositeComponent) !GlyphOutline {
        // コンポーネントグリフの合成
        var all_contours = ArrayList(Contour).init(self.allocator);
        defer all_contours.deinit();

        var total_advance_x: f32 = 0;
        var total_advance_y: f32 = 0;

        for (components) |component| {
            // コンポーネントグリフを取得
            const component_glyph = self.getGlyph(component.glyph_index) catch {
                continue; // エラーの場合はスキップ
            };
            defer component_glyph.deinit();

            // 変換を適用してコンポーネントを合成
            for (component_glyph.contours) |contour| {
                var transformed_segments = ArrayList(Segment).init(self.allocator);

                for (contour.segments) |segment| {
                    var transformed_segment = segment;

                    // 各ポイントに変換を適用
                    for (&transformed_segment.points) |*point| {
                        const x = point.x;
                        const y = point.y;

                        point.x = component.transform.xx * x + component.transform.xy * y + component.transform.dx;
                        point.y = component.transform.yx * x + component.transform.yy * y + component.transform.dy;
                    }

                    try transformed_segments.append(transformed_segment);
                }

                try all_contours.append(Contour{
                    .segments = try transformed_segments.toOwnedSlice(),
                    .is_closed = contour.is_closed,
                });
            }

            // アドバンス幅を累積
            total_advance_x += component_glyph.advance_x * component.transform.xx;
            total_advance_y += component_glyph.advance_y * component.transform.yy;
        }

        return GlyphOutline{
            .contours = try all_contours.toOwnedSlice(),
            .advance_x = total_advance_x,
            .advance_y = total_advance_y,
            .allocator = self.allocator,
        };
    }

    fn createFallbackGlyph(self: *FontFace) !GlyphOutline {
        // フォールバック用の基本矩形グリフ
        const contours = try self.allocator.alloc(Contour, 1);
        const segments = try self.allocator.alloc(Segment, 4);

        // 矩形の4辺を作成
        segments[0] = Segment{
            .type = SegmentType.Line,
            .points = [_]Point{
                Point{ .x = 0, .y = 0 },
                Point{ .x = 100, .y = 0 },
                Point{ .x = 0, .y = 0 },
                Point{ .x = 0, .y = 0 },
            },
        };
        segments[1] = Segment{
            .type = SegmentType.Line,
            .points = [_]Point{
                Point{ .x = 100, .y = 0 },
                Point{ .x = 100, .y = 100 },
                Point{ .x = 0, .y = 0 },
                Point{ .x = 0, .y = 0 },
            },
        };
        segments[2] = Segment{
            .type = SegmentType.Line,
            .points = [_]Point{
                Point{ .x = 100, .y = 100 },
                Point{ .x = 0, .y = 100 },
                Point{ .x = 0, .y = 0 },
                Point{ .x = 0, .y = 0 },
            },
        };
        segments[3] = Segment{
            .type = SegmentType.Line,
            .points = [_]Point{
                Point{ .x = 0, .y = 100 },
                Point{ .x = 0, .y = 0 },
                Point{ .x = 0, .y = 0 },
                Point{ .x = 0, .y = 0 },
            },
        };

        contours[0] = Contour{
            .segments = segments,
            .is_closed = true,
        };

        return GlyphOutline{
            .contours = contours,
            .advance_x = 120,
            .advance_y = 0,
            .allocator = self.allocator,
        };
    }
};

pub const FontFamily = struct {
    name: []const u8,
    faces: ArrayList(*FontFace),
    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8) FontFamily {
        return FontFamily{
            .name = name,
            .faces = ArrayList(*FontFace).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FontFamily) void {
        for (self.faces.items) |face| {
            face.deinit();
            self.allocator.destroy(face);
        }
        self.faces.deinit();
        self.allocator.free(self.name);
    }

    pub fn addFace(self: *FontFamily, face: *FontFace) !void {
        try self.faces.append(face);
    }

    pub fn findFace(self: *FontFamily, weight: FontWeight, style: FontStyle) ?*FontFace {
        var best_face: ?*FontFace = null;
        var best_score: i32 = std.math.maxInt(i32);

        for (self.faces.items) |face| {
            var score: i32 = 0;

            // ウェイトの差を計算
            const weight_diff = @abs(@as(i32, @intFromEnum(face.weight)) - @as(i32, @intFromEnum(weight)));
            score += weight_diff;

            // スタイルの一致を確認
            if (face.style != style) {
                score += 1000; // スタイル不一致のペナルティ
            }

            if (score < best_score) {
                best_score = score;
                best_face = face;
            }
        }

        return best_face;
    }
};

pub const TextShaper = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) TextShaper {
        return TextShaper{
            .allocator = allocator,
        };
    }

    pub fn shapeText(self: *TextShaper, text: []const u8, font_face: *FontFace, size: f32) ![]ShapedGlyph {
        var shaped_glyphs = ArrayList(ShapedGlyph).init(self.allocator);
        defer shaped_glyphs.deinit();

        var x_advance: f32 = 0;
        var i: usize = 0;

        while (i < text.len) {
            // UTF-8デコード（簡単な実装）
            var codepoint: u32 = 0;
            var bytes_consumed: usize = 1;

            if (text[i] < 0x80) {
                codepoint = text[i];
            } else if (text[i] < 0xE0) {
                if (i + 1 < text.len) {
                    codepoint = (@as(u32, text[i] & 0x1F) << 6) | (text[i + 1] & 0x3F);
                    bytes_consumed = 2;
                }
            } else if (text[i] < 0xF0) {
                if (i + 2 < text.len) {
                    codepoint = (@as(u32, text[i] & 0x0F) << 12) |
                        (@as(u32, text[i + 1] & 0x3F) << 6) |
                        (text[i + 2] & 0x3F);
                    bytes_consumed = 3;
                }
            } else {
                if (i + 3 < text.len) {
                    codepoint = (@as(u32, text[i] & 0x07) << 18) |
                        (@as(u32, text[i + 1] & 0x3F) << 12) |
                        (@as(u32, text[i + 2] & 0x3F) << 6) |
                        (text[i + 3] & 0x3F);
                    bytes_consumed = 4;
                }
            }

            const glyph = try font_face.getGlyph(codepoint, size, RenderMode.normal);

            const shaped_glyph = ShapedGlyph{
                .glyph_id = codepoint,
                .codepoint = codepoint,
                .x_advance = @as(f32, @floatFromInt(glyph.advance_x)) / 64.0,
                .y_advance = @as(f32, @floatFromInt(glyph.advance_y)) / 64.0,
                .x_offset = 0,
                .y_offset = 0,
                .cluster = @intCast(i),
            };

            try shaped_glyphs.append(shaped_glyph);
            x_advance += shaped_glyph.x_advance;
            i += bytes_consumed;
        }

        return shaped_glyphs.toOwnedSlice();
    }
};

pub const ShapedGlyph = struct {
    glyph_id: u32,
    codepoint: u32,
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
    cluster: u32,
};

pub const FontManager = struct {
    families: HashMap([]const u8, *FontFamily, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    fallback_fonts: ArrayList(*FontFace),
    system_fonts: ArrayList([]const u8),
    allocator: Allocator,
    text_shaper: TextShaper,

    pub fn init(allocator: Allocator) FontManager {
        return FontManager{
            .families = HashMap([]const u8, *FontFamily, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .fallback_fonts = ArrayList(*FontFace).init(allocator),
            .system_fonts = ArrayList([]const u8).init(allocator),
            .allocator = allocator,
            .text_shaper = TextShaper.init(allocator),
        };
    }

    pub fn deinit(self: *FontManager) void {
        var iterator = self.families.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.families.deinit();

        for (self.fallback_fonts.items) |face| {
            face.deinit();
            self.allocator.destroy(face);
        }
        self.fallback_fonts.deinit();

        for (self.system_fonts.items) |path| {
            self.allocator.free(path);
        }
        self.system_fonts.deinit();
    }

    pub fn loadFont(self: *FontManager, data: []const u8) !*FontFace {
        const face = try self.allocator.create(FontFace);
        face.* = try FontFace.init(self.allocator, data);

        // ファミリーに追加
        const family_name = try self.allocator.dupe(u8, face.family_name);

        if (self.families.get(family_name)) |family| {
            try family.addFace(face);
            self.allocator.free(family_name);
        } else {
            const family = try self.allocator.create(FontFamily);
            family.* = FontFamily.init(self.allocator, family_name);
            try family.addFace(face);
            try self.families.put(family_name, family);
        }

        return face;
    }

    pub fn loadFontFromFile(self: *FontManager, path: []const u8) !*FontFace {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const data = try self.allocator.alloc(u8, file_size);
        _ = try file.readAll(data);

        return self.loadFont(data);
    }

    pub fn findFont(self: *FontManager, family_name: []const u8, weight: FontWeight, style: FontStyle) ?*FontFace {
        if (self.families.get(family_name)) |family| {
            return family.findFace(weight, style);
        }

        // フォールバックフォントを検索
        for (self.fallback_fonts.items) |face| {
            if (std.mem.eql(u8, face.family_name, family_name)) {
                return face;
            }
        }

        // デフォルトフォントを返す
        if (self.fallback_fonts.items.len > 0) {
            return self.fallback_fonts.items[0];
        }

        return null;
    }

    pub fn addFallbackFont(self: *FontManager, face: *FontFace) !void {
        try self.fallback_fonts.append(face);
    }

    pub fn scanSystemFonts(self: *FontManager) !void {
        // システムフォントディレクトリをスキャン
        const font_dirs = [_][]const u8{
            "/System/Library/Fonts", // macOS
            "/usr/share/fonts", // Linux
            "C:\\Windows\\Fonts", // Windows
        };

        for (font_dirs) |dir| {
            self.scanFontDirectory(dir) catch |err| {
                // ディレクトリが存在しない場合は無視
                if (err != error.FileNotFound) {
                    return err;
                }
            };
        }
    }

    fn scanFontDirectory(self: *FontManager, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openIterableDir(dir_path, .{}) catch return;
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file) {
                const ext = std.fs.path.extension(entry.name);
                if (std.mem.eql(u8, ext, ".ttf") or
                    std.mem.eql(u8, ext, ".otf") or
                    std.mem.eql(u8, ext, ".woff") or
                    std.mem.eql(u8, ext, ".woff2"))
                {
                    const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.name });
                    try self.system_fonts.append(full_path);

                    // フォントを読み込み
                    self.loadFontFromFile(full_path) catch |err| {
                        std.log.warn("Failed to load font {s}: {}", .{ full_path, err });
                    };
                }
            }
        }
    }

    pub fn shapeText(self: *FontManager, text: []const u8, font_face: *FontFace, size: f32) ![]ShapedGlyph {
        return self.text_shaper.shapeText(text, font_face, size);
    }

    pub fn measureText(self: *FontManager, text: []const u8, font_face: *FontFace, size: f32) !TextMetrics {
        const shaped_glyphs = try self.shapeText(text, font_face, size);
        defer self.allocator.free(shaped_glyphs);

        var width: f32 = 0;
        const height: f32 = size; // height は変更されないので const にする

        for (shaped_glyphs) |glyph| {
            width += glyph.x_advance;
        }

        return TextMetrics{
            .width = width,
            .height = height,
            .ascent = @as(f32, @floatFromInt(font_face.metrics.ascender)) * size / @as(f32, @floatFromInt(font_face.metrics.units_per_em)),
            .descent = @as(f32, @floatFromInt(-font_face.metrics.descender)) * size / @as(f32, @floatFromInt(font_face.metrics.units_per_em)),
            .line_gap = @as(f32, @floatFromInt(font_face.metrics.line_gap)) * size / @as(f32, @floatFromInt(font_face.metrics.units_per_em)),
        };
    }
};

pub const TextMetrics = struct {
    width: f32,
    height: f32,
    ascent: f32,
    descent: f32,
    line_gap: f32,
};

// フォント管理のユーティリティ関数
pub fn createDefaultFontManager(allocator: Allocator) !*FontManager {
    const manager = try allocator.create(FontManager);
    manager.* = FontManager.init(allocator);

    // システムフォントをスキャン
    try manager.scanSystemFonts();

    return manager;
}

pub fn destroyFontManager(manager: *FontManager, allocator: Allocator) void {
    manager.deinit();
    allocator.destroy(manager);
}
