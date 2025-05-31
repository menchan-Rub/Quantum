const std = @import("std");
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

// GraphicsAPI型の仮実装 (実際には対応するグラフィックスバックエンドを使用)
const GraphicsAPI = struct {
    // 実装省略
};

/// タイルベースのレンダリングエンジン
/// 画面を小さなタイルに分割し、変更のあるタイルのみを描画することで
/// レンダリング性能を最大化します
pub const TileRenderer = struct {
    const Self = @This();

    // タイルのデフォルトサイズ (通常のGPUのキャッシュラインに合わせた最適値)
    pub const DEFAULT_TILE_SIZE = 64;

    // 最大タイル数の制限
    pub const MAX_TILES_X = 256;
    pub const MAX_TILES_Y = 256;

    // アロケータ
    allocator: Allocator,

    // ビューポートサイズ
    viewport_width: u32,
    viewport_height: u32,

    // タイルサイズ
    tile_size: u32,

    // タイル分割数
    tiles_x: u32,
    tiles_y: u32,
    tile_count: u32,

    // タイル状態追跡
    dirty_tiles: []bool,

    // タイルのソート済みリスト (前後関係の処理用)
    tile_draw_order: []u32,

    // レンダリングキュー
    render_queue: RenderQueue,

    // 統計情報
    stats: RenderStats,

    // グラフィックスAPI
    graphics: *GraphicsAPI,

    // レンダーターゲット
    render_target: ?*anyopaque,

    pub const RenderStats = struct {
        frame_count: u64 = 0,
        total_tiles_processed: u64 = 0,
        total_dirty_tiles_rendered: u64 = 0,
        max_dirty_tiles_per_frame: u32 = 0,
        total_render_time_ns: u64 = 0,
        current_fps: f32 = 0.0,
    };

    /// レンダラーを初期化
    pub fn init(allocator: Allocator, graphics: *GraphicsAPI, width: u32, height: u32, tile_size: u32) !*Self {
        const tiles_x = math.divCeil(u32, width, tile_size) catch MAX_TILES_X;
        const tiles_y = math.divCeil(u32, height, tile_size) catch MAX_TILES_Y;
        const tile_count = tiles_x * tiles_y;

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // タイル状態追跡用のメモリ確保
        const dirty_tiles = try allocator.alloc(bool, tile_count);
        errdefer allocator.free(dirty_tiles);

        const tile_draw_order = try allocator.alloc(u32, tile_count);
        errdefer allocator.free(tile_draw_order);

        // 初期化
        self.* = .{
            .allocator = allocator,
            .viewport_width = width,
            .viewport_height = height,
            .tile_size = tile_size,
            .tiles_x = tiles_x,
            .tiles_y = tiles_y,
            .tile_count = tile_count,
            .dirty_tiles = dirty_tiles,
            .tile_draw_order = tile_draw_order,
            .render_queue = try RenderQueue.init(allocator, 1024),
            .stats = RenderStats{},
            .graphics = graphics,
            .render_target = null,
        };

        // 初期状態ですべてのタイルをダーティにマーク
        self.markAllTilesDirty();

        // 初期描画順序を設定
        for (0..tile_count) |i| {
            self.tile_draw_order[i] = @intCast(i);
        }

        return self;
    }

    /// リソース解放
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.dirty_tiles);
        self.allocator.free(self.tile_draw_order);
        self.render_queue.deinit();
        self.allocator.destroy(self);
    }

    /// レンダーターゲットを設定
    pub fn setRenderTarget(self: *Self, target: ?*anyopaque) void {
        self.render_target = target;
    }

    /// すべてのタイルをダーティとマーク（全画面再描画）
    pub fn markAllTilesDirty(self: *Self) void {
        @memset(self.dirty_tiles, true);
    }

    /// 特定のタイルをダーティとマーク
    pub fn markTileDirty(self: *Self, tile_x: u32, tile_y: u32) void {
        if (tile_x >= self.tiles_x or tile_y >= self.tiles_y) return;

        const tile_index = tile_y * self.tiles_x + tile_x;
        self.dirty_tiles[tile_index] = true;
    }

    /// 矩形領域をダーティとマーク
    pub fn markRectDirty(self: *Self, x: i32, y: i32, width: u32, height: u32) void {
        // 矩形がビューポート外なら何もしない
        if (x >= @as(i32, @intCast(self.viewport_width)) or y >= @as(i32, @intCast(self.viewport_height)) or
            x + @as(i32, @intCast(width)) <= 0 or y + @as(i32, @intCast(height)) <= 0)
        {
            return;
        }

        // ビューポート内の矩形部分だけをクリップ
        const clipped_x = @max(0, x);
        const clipped_y = @max(0, y);
        const clipped_right = @min(@as(i32, @intCast(self.viewport_width)), x + @as(i32, @intCast(width)));
        const clipped_bottom = @min(@as(i32, @intCast(self.viewport_height)), y + @as(i32, @intCast(height)));

        // クリップ後の矩形サイズ
        const clipped_width = @intCast(clipped_right - clipped_x);
        const clipped_height = @intCast(clipped_bottom - clipped_y);

        // 対応するタイル範囲を計算
        const start_tile_x = @divFloor(@as(u32, @intCast(clipped_x)), self.tile_size);
        const start_tile_y = @divFloor(@as(u32, @intCast(clipped_y)), self.tile_size);
        const end_tile_x = @min(self.tiles_x - 1, @divFloor(@as(u32, @intCast(clipped_x + clipped_width - 1)), self.tile_size));
        const end_tile_y = @min(self.tiles_y - 1, @divFloor(@as(u32, @intCast(clipped_y + clipped_height - 1)), self.tile_size));

        // タイルをダーティとしてマーク
        var tile_y = start_tile_y;
        while (tile_y <= end_tile_y) : (tile_y += 1) {
            var tile_x = start_tile_x;
            while (tile_x <= end_tile_x) : (tile_x += 1) {
                self.markTileDirty(tile_x, tile_y);
            }
        }
    }

    /// レンダリングを実行
    pub fn render(self: *Self, cur_time_ns: u64) !void {
        const start_time = std.time.nanoTimestamp();

        // フレームカウンタを更新
        self.stats.frame_count += 1;

        // レンダーキューをクリア
        self.render_queue.clear();

        // ダーティタイルをカウント
        var dirty_tile_count: u32 = 0;

        // ダーティなタイルのみを処理
        for (0..self.tile_count) |i| {
            if (!self.dirty_tiles[i]) continue;

            dirty_tile_count += 1;

            // タイルを処理し、描画コマンドをキューに追加
            try self.processTile(@intCast(i));

            // タイルをクリーンとマーク
            self.dirty_tiles[i] = false;
        }

        // 統計情報を更新
        self.stats.total_tiles_processed += self.tile_count;
        self.stats.total_dirty_tiles_rendered += dirty_tile_count;
        self.stats.max_dirty_tiles_per_frame = @max(self.stats.max_dirty_tiles_per_frame, dirty_tile_count);

        // 描画コマンドを実行
        try self.render_queue.executeCommands(self.graphics, self.render_target);

        // レンダリング時間の記録
        const end_time = std.time.nanoTimestamp();
        const frame_time_ns = @as(u64, @intCast(end_time - start_time));
        self.stats.total_render_time_ns += frame_time_ns;

        // FPSの計算 (1秒ごとに更新)
        const one_second_ns: u64 = 1_000_000_000;
        if (cur_time_ns % one_second_ns < frame_time_ns) {
            self.stats.current_fps = @as(f32, @floatFromInt(self.stats.frame_count)) /
                (@as(f32, @floatFromInt(self.stats.total_render_time_ns)) /
                    @as(f32, @floatFromInt(one_second_ns)));
        }
    }

    /// タイルをレンダリング
    fn processTile(self: *Self, tile_index: u32) !void {
        const tile_x = tile_index % self.tiles_x;
        const tile_y = tile_index / self.tiles_x;

        // タイルの左上座標
        const tile_start_x = tile_x * self.tile_size;
        const tile_start_y = tile_y * self.tile_size;

        // タイルの右下座標（ビューポート境界でクリップ）
        const tile_end_x = @min(self.viewport_width, tile_start_x + self.tile_size);
        const tile_end_y = @min(self.viewport_height, tile_start_y + self.tile_size);

        // タイルのサイズ
        const tile_width = tile_end_x - tile_start_x;
        const tile_height = tile_end_y - tile_start_y;

        // タイルを描画
        try self.render_queue.pushTile(tile_start_x, tile_start_y, tile_width, tile_height);
    }

    /// 統計情報をリセット
    pub fn resetStats(self: *Self) void {
        self.stats = RenderStats{};
    }

    /// 現在の統計情報を取得
    pub fn getStats(self: *Self) RenderStats {
        return self.stats;
    }

    /// ビューポートサイズ変更処理
    pub fn resize(self: *Self, new_width: u32, new_height: u32) !void {
        // 同じサイズなら何もしない
        if (self.viewport_width == new_width and self.viewport_height == new_height) {
            return;
        }

        // 新しいタイル数を計算
        const new_tiles_x = math.divCeil(u32, new_width, self.tile_size) catch MAX_TILES_X;
        const new_tiles_y = math.divCeil(u32, new_height, self.tile_size) catch MAX_TILES_Y;
        const new_tile_count = new_tiles_x * new_tiles_y;

        // タイル数が変わる場合はメモリを再確保
        if (new_tile_count != self.tile_count) {
            // 新しいバッファを確保
            const new_dirty_tiles = try self.allocator.alloc(bool, new_tile_count);
            errdefer self.allocator.free(new_dirty_tiles);

            const new_tile_draw_order = try self.allocator.alloc(u32, new_tile_count);
            errdefer self.allocator.free(new_tile_draw_order);

            // 古いバッファを解放
            self.allocator.free(self.dirty_tiles);
            self.allocator.free(self.tile_draw_order);

            // 新しいバッファを設定
            self.dirty_tiles = new_dirty_tiles;
            self.tile_draw_order = new_tile_draw_order;

            // 初期描画順序を設定
            for (0..new_tile_count) |i| {
                self.tile_draw_order[i] = @intCast(i);
            }
        }

        // 新しいサイズを設定
        self.viewport_width = new_width;
        self.viewport_height = new_height;
        self.tiles_x = new_tiles_x;
        self.tiles_y = new_tiles_y;
        self.tile_count = new_tile_count;

        // すべてのタイルをダーティにマーク
        self.markAllTilesDirty();
    }
};

/// レンダリングコマンドキュー
const RenderQueue = struct {
    const Self = @This();

    /// コマンドの最大数
    const DEFAULT_MAX_COMMANDS = 1024;

    /// コマンドタイプ
    const CommandType = enum(u8) {
        RenderTile,
        DrawRectangle,
        DrawTexture,
        PushClip,
        PopClip,
        Custom,
    };

    /// 基本コマンド構造体
    const Command = struct {
        type: CommandType,
    };

    /// タイル描画コマンド
    const RenderTileCmd = struct {
        base: Command,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    };

    /// 矩形描画コマンド
    const DrawRectangleCmd = struct {
        base: Command,
        x: i32,
        y: i32,
        width: u32,
        height: u32,
        color: u32,
    };

    // アロケータ
    allocator: Allocator,

    // コマンドバッファ
    commands: []u8,

    // 現在のコマンド数とバッファ使用量
    command_count: usize,
    buffer_used: usize,

    // 最大コマンド数
    max_commands: usize,

    /// レンダーキューを初期化
    pub fn init(allocator: Allocator, max_commands: usize) !Self {
        // 最大バッファサイズを計算 (最大のコマンドサイズ * 最大コマンド数)
        const max_cmd_size = @max(@sizeOf(RenderTileCmd), @sizeOf(DrawRectangleCmd));
        const buffer_size = max_cmd_size * max_commands;

        // コマンドバッファを確保
        const commands = try allocator.alloc(u8, buffer_size);

        return Self{
            .allocator = allocator,
            .commands = commands,
            .command_count = 0,
            .buffer_used = 0,
            .max_commands = max_commands,
        };
    }

    /// リソース解放
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.commands);
    }

    /// キューをクリア
    pub fn clear(self: *Self) void {
        self.command_count = 0;
        self.buffer_used = 0;
    }

    /// タイル描画コマンドを追加
    pub fn pushTile(self: *Self, x: u32, y: u32, width: u32, height: u32) !void {
        const cmd_size = @sizeOf(RenderTileCmd);

        // バッファが足りるか確認
        if (self.command_count >= self.max_commands or self.buffer_used + cmd_size > self.commands.len) {
            return error.QueueFull;
        }

        // コマンドを作成してバッファに追加
        const cmd_ptr = @as(*RenderTileCmd, @ptrCast(self.commands.ptr + self.buffer_used));
        cmd_ptr.* = RenderTileCmd{
            .base = Command{ .type = .RenderTile },
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        };

        // カウンターを更新
        self.command_count += 1;
        self.buffer_used += cmd_size;
    }

    /// 矩形描画コマンドを追加
    pub fn pushRectangle(self: *Self, x: i32, y: i32, width: u32, height: u32, color: u32) !void {
        const cmd_size = @sizeOf(DrawRectangleCmd);

        // バッファが足りるか確認
        if (self.command_count >= self.max_commands or self.buffer_used + cmd_size > self.commands.len) {
            return error.QueueFull;
        }

        // コマンドを作成してバッファに追加
        const cmd_ptr = @as(*DrawRectangleCmd, @ptrCast(self.commands.ptr + self.buffer_used));
        cmd_ptr.* = DrawRectangleCmd{
            .base = Command{ .type = .DrawRectangle },
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .color = color,
        };

        // カウンターを更新
        self.command_count += 1;
        self.buffer_used += cmd_size;
    }

    /// コマンドを実行
    pub fn executeCommands(self: *Self, graphics: *GraphicsAPI, render_target: ?*anyopaque) !void {
        _ = graphics;
        _ = render_target;

        var offset: usize = 0;
        var i: usize = 0;

        // すべてのコマンドを処理
        while (i < self.command_count) : (i += 1) {
            // コマンドヘッダを取得
            const cmd_ptr = @as(*const Command, @ptrCast(self.commands.ptr + offset));

            // コマンドタイプに応じて処理
            switch (cmd_ptr.type) {
                .RenderTile => {
                    const tile_cmd = @as(*const RenderTileCmd, @ptrCast(cmd_ptr));
                    try self.executeTileCommand(tile_cmd, graphics, render_target);
                    offset += @sizeOf(RenderTileCmd);
                },
                .DrawRectangle => {
                    const rect_cmd = @as(*const DrawRectangleCmd, @ptrCast(cmd_ptr));
                    try self.executeRectangleCommand(rect_cmd, graphics, render_target);
                    offset += @sizeOf(DrawRectangleCmd);
                },
                else => {
                    // 未実装のコマンド
                    return error.UnsupportedCommand;
                },
            }
        }
    }

    // 実際のコマンド実行処理
    fn executeTileCommand(self: *Self, cmd: *const RenderTileCmd, graphics: *GraphicsAPI, render_target: ?*anyopaque) !void {
        // GraphicsAPIを用いた実際のタイル描画
        try graphics.drawTile(cmd, render_target);
    }

    fn executeRectangleCommand(self: *Self, cmd: *const DrawRectangleCmd, graphics: *GraphicsAPI, render_target: ?*anyopaque) !void {
        // GraphicsAPIを用いた実際の矩形描画
        try graphics.drawRectangle(cmd, render_target);
    }
};

// テスト用のモックグラフィックスAPI
const MockGraphicsAPI = struct {
    // テスト用のシンプルな実装

    pub fn init() !MockGraphicsAPI {
        return MockGraphicsAPI{};
    }

    pub fn deinit(self: *MockGraphicsAPI) void {
        _ = self;
    }
};

test "TileRenderer - 基本初期化" {
    const allocator = std.testing.allocator;
    var graphics = try MockGraphicsAPI.init();
    defer graphics.deinit();

    const width: u32 = 1920;
    const height: u32 = 1080;
    const tile_size: u32 = 64;

    var renderer = try TileRenderer.init(allocator, &graphics, width, height, tile_size);
    defer renderer.deinit();

    try std.testing.expectEqual(width, renderer.viewport_width);
    try std.testing.expectEqual(height, renderer.viewport_height);
    try std.testing.expectEqual(tile_size, renderer.tile_size);

    // タイル数は切り上げになることを確認
    const expected_tiles_x = (width + tile_size - 1) / tile_size;
    const expected_tiles_y = (height + tile_size - 1) / tile_size;
    try std.testing.expectEqual(expected_tiles_x, renderer.tiles_x);
    try std.testing.expectEqual(expected_tiles_y, renderer.tiles_y);
    try std.testing.expectEqual(expected_tiles_x * expected_tiles_y, renderer.tile_count);
}

test "TileRenderer - ダーティ領域マーキング" {
    const allocator = std.testing.allocator;
    var graphics = try MockGraphicsAPI.init();
    defer graphics.deinit();

    const width: u32 = 320;
    const height: u32 = 240;
    const tile_size: u32 = 64;

    var renderer = try TileRenderer.init(allocator, &graphics, width, height, tile_size);
    defer renderer.deinit();

    // すべてのタイルをクリーンに設定
    @memset(renderer.dirty_tiles, false);

    // 矩形領域をダーティとしてマーク
    renderer.markRectDirty(10, 10, 100, 100);

    // 影響を受けるタイルをチェック
    try std.testing.expect(renderer.dirty_tiles[0]); // (0,0)
    try std.testing.expect(renderer.dirty_tiles[1]); // (1,0)
    try std.testing.expect(renderer.dirty_tiles[5]); // (0,1)
    try std.testing.expect(renderer.dirty_tiles[6]); // (1,1)

    // 影響を受けないタイルをチェック
    try std.testing.expect(!renderer.dirty_tiles[2]); // (2,0)
    try std.testing.expect(!renderer.dirty_tiles[10]); // (0,2)
}

test "TileRenderer - リサイズ" {
    const allocator = std.testing.allocator;
    var graphics = try MockGraphicsAPI.init();
    defer graphics.deinit();

    const width: u32 = 320;
    const height: u32 = 240;
    const tile_size: u32 = 64;

    var renderer = try TileRenderer.init(allocator, &graphics, width, height, tile_size);
    defer renderer.deinit();

    // リサイズ前のタイル数を保存
    const initial_tile_count = renderer.tile_count;

    // ビューポートをリサイズ
    try renderer.resize(640, 480);

    // 新しいサイズとタイル数をチェック
    try std.testing.expectEqual(@as(u32, 640), renderer.viewport_width);
    try std.testing.expectEqual(@as(u32, 480), renderer.viewport_height);
    try std.testing.expect(renderer.tile_count > initial_tile_count);

    // すべてのタイルがダーティになっていることを確認
    for (renderer.dirty_tiles) |is_dirty| {
        try std.testing.expect(is_dirty);
    }
}
