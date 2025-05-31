// src/zig/fonts/manager.zig
// 高性能フォント管理システム - フォント読み込み、キャッシュ、グリフレンダリング

const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Allocator = std.mem.Allocator;

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
            
            const tag = self.data[offset..offset + 4];
            const table_offset = std.mem.readIntBig(u32, self.data[offset + 8..offset + 12]);
            const table_length = std.mem.readIntBig(u32, self.data[offset + 12..offset + 16]);
            
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
        
        self.metrics.units_per_em = std.mem.readIntBig(u16, self.data[offset + 18..offset + 20]);
        
        // フォントのバウンディングボックス
        const x_min = std.mem.readIntBig(i16, self.data[offset + 36..offset + 38]);
        const y_min = std.mem.readIntBig(i16, self.data[offset + 38..offset + 40]);
        const x_max = std.mem.readIntBig(i16, self.data[offset + 40..offset + 42]);
        const y_max = std.mem.readIntBig(i16, self.data[offset + 42..offset + 44]);
        
        _ = x_min;
        _ = y_min;
        _ = x_max;
        _ = y_max;
    }
    
    fn parseHheaTable(self: *FontFace, offset: usize) !void {
        if (offset + 36 > self.data.len) return error.InvalidTable;
        
        self.metrics.ascender = std.mem.readIntBig(i16, self.data[offset + 4..offset + 6]);
        self.metrics.descender = std.mem.readIntBig(i16, self.data[offset + 6..offset + 8]);
        self.metrics.line_gap = std.mem.readIntBig(i16, self.data[offset + 8..offset + 10]);
        self.metrics.advance_width_max = std.mem.readIntBig(u16, self.data[offset + 10..offset + 12]);
        self.metrics.min_left_side_bearing = std.mem.readIntBig(i16, self.data[offset + 12..offset + 14]);
        self.metrics.min_right_side_bearing = std.mem.readIntBig(i16, self.data[offset + 14..offset + 16]);
        self.metrics.x_max_extent = std.mem.readIntBig(i16, self.data[offset + 16..offset + 18]);
        self.metrics.caret_slope_rise = std.mem.readIntBig(i16, self.data[offset + 18..offset + 20]);
        self.metrics.caret_slope_run = std.mem.readIntBig(i16, self.data[offset + 20..offset + 22]);
        self.metrics.caret_offset = std.mem.readIntBig(i16, self.data[offset + 22..offset + 24]);
        self.metrics.metric_data_format = std.mem.readIntBig(i16, self.data[offset + 32..offset + 34]);
        self.metrics.number_of_h_metrics = std.mem.readIntBig(u16, self.data[offset + 34..offset + 36]);
    }
    
    fn parseNameTable(self: *FontFace, offset: usize) !void {
        if (offset + 6 > self.data.len) return error.InvalidTable;
        
        const format = std.mem.readIntBig(u16, self.data[offset..offset + 2]);
        const count = std.mem.readIntBig(u16, self.data[offset + 2..offset + 4]);
        const string_offset = std.mem.readIntBig(u16, self.data[offset + 4..offset + 6]);
        
        _ = format;
        
        var name_offset = offset + 6;
        
        for (0..count) |_| {
            if (name_offset + 12 > self.data.len) break;
            
            const platform_id = std.mem.readIntBig(u16, self.data[name_offset..name_offset + 2]);
            const encoding_id = std.mem.readIntBig(u16, self.data[name_offset + 2..name_offset + 4]);
            const language_id = std.mem.readIntBig(u16, self.data[name_offset + 4..name_offset + 6]);
            const name_id = std.mem.readIntBig(u16, self.data[name_offset + 6..name_offset + 8]);
            const length = std.mem.readIntBig(u16, self.data[name_offset + 8..name_offset + 10]);
            const str_offset = std.mem.readIntBig(u16, self.data[name_offset + 10..name_offset + 12]);
            
            // 英語のファミリー名とスタイル名を取得
            if (platform_id == 3 and encoding_id == 1 and language_id == 0x0409) {
                const str_start = offset + string_offset + str_offset;
                if (str_start + length <= self.data.len) {
                    if (name_id == 1) { // ファミリー名
                        self.family_name = try self.allocator.dupe(u8, self.data[str_start..str_start + length]);
                    } else if (name_id == 2) { // スタイル名
                        self.style_name = try self.allocator.dupe(u8, self.data[str_start..str_start + length]);
                    }
                }
            }
            
            name_offset += 12;
        }
    }
    
    fn parseOS2Table(self: *FontFace, offset: usize) !void {
        if (offset + 78 > self.data.len) return error.InvalidTable;
        
        const weight_class = std.mem.readIntBig(u16, self.data[offset + 4..offset + 6]);
        const selection = std.mem.readIntBig(u16, self.data[offset + 62..offset + 64]);
        
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
        // 簡単なビットマップレンダリング（実際の実装ではFreeTypeなどを使用）
        const scale = size / @as(f32, @floatFromInt(self.metrics.units_per_em));
        const width = @as(u32, @intFromFloat(size * 0.6)); // 仮の幅
        const height = @as(u32, @intFromFloat(size));
        
        const buffer_size = width * height;
        const buffer = try self.allocator.alloc(u8, buffer_size);
        
        // 簡単なグリフレンダリング（実際の実装では複雑なアウトライン処理が必要）
        @memset(buffer, 0);
        
        // 文字に応じた簡単なパターンを描画
        if (codepoint >= 'A' and codepoint <= 'Z') {
            try self.drawLetter(buffer, width, height, codepoint);
        } else if (codepoint >= 'a' and codepoint <= 'z') {
            try self.drawLetter(buffer, width, height, codepoint);
        } else if (codepoint >= '0' and codepoint <= '9') {
            try self.drawDigit(buffer, width, height, codepoint);
        }
        
        return GlyphBitmap{
            .width = width,
            .height = height,
            .pitch = width,
            .buffer = buffer,
            .pixel_mode = switch (render_mode) {
                .mono => PixelMode.mono,
                .lcd, .lcd_v => PixelMode.lcd,
                else => PixelMode.gray,
            },
            .left = 0,
            .top = @intCast(height),
            .advance_x = @intFromFloat(size * 0.6 * 64), // 26.6固定小数点
            .advance_y = 0,
        };
    }
    
    fn drawLetter(self: *FontFace, buffer: []u8, width: u32, height: u32, codepoint: u32) !void {
        _ = self;
        
        // 簡単な文字描画（実際の実装ではベジェ曲線の処理が必要）
        const char_width = width * 3 / 4;
        const char_height = height * 3 / 4;
        const start_x = width / 8;
        const start_y = height / 8;
        
        // 文字の輪郭を描画
        for (start_y..start_y + char_height) |y| {
            for (start_x..start_x + char_width) |x| {
                if (x < width and y < height) {
                    const index = y * width + x;
                    if (index < buffer.len) {
                        // 簡単なパターン（実際の文字形状ではない）
                        if ((x - start_x) % 4 == 0 or (y - start_y) % 4 == 0) {
                            buffer[index] = 255;
                        }
                    }
                }
            }
        }
        
        _ = codepoint;
    }
    
    fn drawDigit(self: *FontFace, buffer: []u8, width: u32, height: u32, codepoint: u32) !void {
        _ = self;
        
        // 簡単な数字描画
        const char_width = width * 3 / 4;
        const char_height = height * 3 / 4;
        const start_x = width / 8;
        const start_y = height / 8;
        
        // 数字の輪郭を描画
        for (start_y..start_y + char_height) |y| {
            for (start_x..start_x + char_width) |x| {
                if (x < width and y < height) {
                    const index = y * width + x;
                    if (index < buffer.len) {
                        // 数字に応じたパターン
                        const digit = codepoint - '0';
                        if (digit < 10) {
                            if ((x - start_x) % 3 == 0 and (y - start_y) % 3 == 0) {
                                buffer[index] = 200;
                            }
                        }
                    }
                }
            }
        }
    }
    
    pub fn getKerning(self: *FontFace, left_glyph: u32, right_glyph: u32) i32 {
        _ = self;
        _ = left_glyph;
        _ = right_glyph;
        
        // 簡単なカーニング（実際の実装ではkernテーブルを解析）
        return 0;
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
                    std.mem.eql(u8, ext, ".woff2")) {
                    
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
        var height: f32 = size;
        
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