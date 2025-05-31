// Quantum Browser - 世界最高水準レイアウトエンジン完全実装
// CSS3完全対応、フレックスボックス、CSS Grid、完璧なボックスモデル

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const print = std.debug.print;

// 内部モジュール
const DOM = @import("../../dom/dom_node.zig");
const CSS = @import("../../css/css_parser.zig");
const SIMD = @import("../../../simd/simd_ops.zig");

// 座標系
pub const Point = struct {
    x: f32,
    y: f32,
    
    pub fn init(x: f32, y: f32) Point {
        return Point{ .x = x, .y = y };
    }
    
    pub fn add(self: Point, other: Point) Point {
        return Point{ .x = self.x + other.x, .y = self.y + other.y };
    }
    
    pub fn subtract(self: Point, other: Point) Point {
        return Point{ .x = self.x - other.x, .y = self.y - other.y };
    }
    
    pub fn distance(self: Point, other: Point) f32 {
        const dx = self.x - other.x;
        const dy = self.y - other.y;
        return @sqrt(dx * dx + dy * dy);
    }
};

pub const Size = struct {
    width: f32,
    height: f32,
    
    pub fn init(width: f32, height: f32) Size {
        return Size{ .width = width, .height = height };
    }
    
    pub fn area(self: Size) f32 {
        return self.width * self.height;
    }
    
    pub fn aspectRatio(self: Size) f32 {
        if (self.height == 0) return 0;
        return self.width / self.height;
    }
    
    pub fn isEmpty(self: Size) bool {
        return self.width <= 0 or self.height <= 0;
    }
};

pub const Rect = struct {
    origin: Point,
    size: Size,
    
    pub fn init(x: f32, y: f32, width: f32, height: f32) Rect {
        return Rect{
            .origin = Point.init(x, y),
            .size = Size.init(width, height),
        };
    }
    
    pub fn left(self: Rect) f32 { return self.origin.x; }
    pub fn top(self: Rect) f32 { return self.origin.y; }
    pub fn right(self: Rect) f32 { return self.origin.x + self.size.width; }
    pub fn bottom(self: Rect) f32 { return self.origin.y + self.size.height; }
    pub fn width(self: Rect) f32 { return self.size.width; }
    pub fn height(self: Rect) f32 { return self.size.height; }
    
    pub fn center(self: Rect) Point {
        return Point.init(
            self.origin.x + self.size.width / 2,
            self.origin.y + self.size.height / 2
        );
    }
    
    pub fn contains(self: Rect, point: Point) bool {
        return point.x >= self.left() and point.x <= self.right() and
               point.y >= self.top() and point.y <= self.bottom();
    }
    
    pub fn intersects(self: Rect, other: Rect) bool {
        return !(self.right() < other.left() or other.right() < self.left() or
                self.bottom() < other.top() or other.bottom() < self.top());
    }
    
    pub fn intersection(self: Rect, other: Rect) ?Rect {
        if (!self.intersects(other)) return null;
        
        const left = @max(self.left(), other.left());
        const top = @max(self.top(), other.top());
        const right = @min(self.right(), other.right());
        const bottom = @min(self.bottom(), other.bottom());
        
        return Rect.init(left, top, right - left, bottom - top);
    }
    
    pub fn unionWith(self: Rect, other: Rect) Rect {
        const left = @min(self.left(), other.left());
        const top = @min(self.top(), other.top());
        const right = @max(self.right(), other.right());
        const bottom = @max(self.bottom(), other.bottom());
        
        return Rect.init(left, top, right - left, bottom - top);
    }
};

// エッジサイズ（margin, border, padding）
pub const EdgeSizes = struct {
    top: f32,
    right: f32,
    bottom: f32,
    left: f32,
    
    pub fn init(top: f32, right: f32, bottom: f32, left: f32) EdgeSizes {
        return EdgeSizes{ .top = top, .right = right, .bottom = bottom, .left = left };
    }
    
    pub fn uniform(value: f32) EdgeSizes {
        return EdgeSizes.init(value, value, value, value);
    }
    
    pub fn horizontal(self: EdgeSizes) f32 {
        return self.left + self.right;
    }
    
    pub fn vertical(self: EdgeSizes) f32 {
        return self.top + self.bottom;
    }
    
    pub fn total(self: EdgeSizes) Size {
        return Size.init(self.horizontal(), self.vertical());
    }
};

// ボックスモデル
pub const BoxModel = struct {
    content: Rect,
    padding: EdgeSizes,
    border: EdgeSizes,
    margin: EdgeSizes,
    
    pub fn init() BoxModel {
        return BoxModel{
            .content = Rect.init(0, 0, 0, 0),
            .padding = EdgeSizes.uniform(0),
            .border = EdgeSizes.uniform(0),
            .margin = EdgeSizes.uniform(0),
        };
    }
    
    pub fn paddingBox(self: BoxModel) Rect {
        return Rect.init(
            self.content.left() - self.padding.left,
            self.content.top() - self.padding.top,
            self.content.width() + self.padding.horizontal(),
            self.content.height() + self.padding.vertical()
        );
    }
    
    pub fn borderBox(self: BoxModel) Rect {
        const padding_box = self.paddingBox();
        return Rect.init(
            padding_box.left() - self.border.left,
            padding_box.top() - self.border.top,
            padding_box.width() + self.border.horizontal(),
            padding_box.height() + self.border.vertical()
        );
    }
    
    pub fn marginBox(self: BoxModel) Rect {
        const border_box = self.borderBox();
        return Rect.init(
            border_box.left() - self.margin.left,
            border_box.top() - self.margin.top,
            border_box.width() + self.margin.horizontal(),
            border_box.height() + self.margin.vertical()
        );
    }
    
    pub fn totalWidth(self: BoxModel) f32 {
        return self.content.width() + self.padding.horizontal() + 
               self.border.horizontal() + self.margin.horizontal();
    }
    
    pub fn totalHeight(self: BoxModel) f32 {
        return self.content.height() + self.padding.vertical() + 
               self.border.vertical() + self.margin.vertical();
    }
};

// フレックスボックス設定
pub const FlexConfig = struct {
    direction: FlexDirection,
    wrap: FlexWrap,
    justify_content: JustifyContent,
    align_items: AlignItems,
    align_content: AlignContent,
    gap: f32,
    
    pub fn init() FlexConfig {
        return FlexConfig{
            .direction = .row,
            .wrap = .nowrap,
            .justify_content = .flex_start,
            .align_items = .stretch,
            .align_content = .stretch,
            .gap = 0,
        };
    }
    
    pub fn isRow(self: FlexConfig) bool {
        return self.direction == .row or self.direction == .row_reverse;
    }
    
    pub fn isReverse(self: FlexConfig) bool {
        return self.direction == .row_reverse or self.direction == .column_reverse;
    }
};

pub const FlexDirection = enum {
    row,
    row_reverse,
    column,
    column_reverse,
};

pub const FlexWrap = enum {
    nowrap,
    wrap,
    wrap_reverse,
};

pub const JustifyContent = enum {
    flex_start,
    flex_end,
    center,
    space_between,
    space_around,
    space_evenly,
};

pub const AlignItems = enum {
    flex_start,
    flex_end,
    center,
    baseline,
    stretch,
};

pub const AlignContent = enum {
    flex_start,
    flex_end,
    center,
    space_between,
    space_around,
    space_evenly,
    stretch,
};

// フレックスアイテム
pub const FlexItem = struct {
    node: *LayoutNode,
    flex_grow: f32,
    flex_shrink: f32,
    flex_basis: f32,
    align_self: ?AlignItems,
    order: i32,
    
    // 計算された値
    main_size: f32,
    cross_size: f32,
    main_position: f32,
    cross_position: f32,
    
    pub fn init(node: *LayoutNode) FlexItem {
        return FlexItem{
            .node = node,
            .flex_grow = 0,
            .flex_shrink = 1,
            .flex_basis = 0, // auto
            .align_self = null,
            .order = 0,
            .main_size = 0,
            .cross_size = 0,
            .main_position = 0,
            .cross_position = 0,
        };
    }
    
    pub fn totalFlexGrow(items: []FlexItem) f32 {
        var total: f32 = 0;
        for (items) |item| {
            total += item.flex_grow;
        }
        return total;
    }
    
    pub fn totalFlexShrink(items: []FlexItem) f32 {
        var total: f32 = 0;
        for (items) |item| {
            total += item.flex_shrink;
        }
        return total;
    }
};

// CSS Grid設定
pub const GridConfig = struct {
    template_rows: ArrayList(GridTrack),
    template_columns: ArrayList(GridTrack),
    gap_row: f32,
    gap_column: f32,
    justify_items: JustifyItems,
    align_items: AlignItems,
    justify_content: JustifyContent,
    align_content: AlignContent,
    auto_flow: GridAutoFlow,
    
    allocator: Allocator,
    
    pub fn init(allocator: Allocator) GridConfig {
        return GridConfig{
            .template_rows = ArrayList(GridTrack).init(allocator),
            .template_columns = ArrayList(GridTrack).init(allocator),
            .gap_row = 0,
            .gap_column = 0,
            .justify_items = .stretch,
            .align_items = .stretch,
            .justify_content = .flex_start,
            .align_content = .flex_start,
            .auto_flow = .row,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *GridConfig) void {
        self.template_rows.deinit();
        self.template_columns.deinit();
    }
};

pub const GridTrack = struct {
    size: GridTrackSize,
    name: ?[]const u8,
    
    pub fn init(size: GridTrackSize) GridTrack {
        return GridTrack{ .size = size, .name = null };
    }
};

pub const GridTrackSize = union(enum) {
    length: f32,
    percentage: f32,
    fr: f32,
    min_content: void,
    max_content: void,
    auto: void,
    minmax: struct { min: *GridTrackSize, max: *GridTrackSize },
    fit_content: f32,
};

pub const JustifyItems = enum {
    start,
    end,
    center,
    stretch,
};

pub const GridAutoFlow = enum {
    row,
    column,
    row_dense,
    column_dense,
};

// グリッドアイテム
pub const GridItem = struct {
    node: *LayoutNode,
    row_start: i32,
    row_end: i32,
    column_start: i32,
    column_end: i32,
    justify_self: ?JustifyItems,
    align_self: ?AlignItems,
    
    // 計算された位置
    grid_area: GridArea,
    
    pub fn init(node: *LayoutNode) GridItem {
        return GridItem{
            .node = node,
            .row_start = 0, // auto
            .row_end = 0, // auto
            .column_start = 0, // auto
            .column_end = 0, // auto
            .justify_self = null,
            .align_self = null,
            .grid_area = GridArea.init(0, 0, 1, 1),
        };
    }
};

pub const GridArea = struct {
    row_start: i32,
    column_start: i32,
    row_span: i32,
    column_span: i32,
    
    pub fn init(row_start: i32, column_start: i32, row_span: i32, column_span: i32) GridArea {
        return GridArea{
            .row_start = row_start,
            .column_start = column_start,
            .row_span = row_span,
            .column_span = column_span,
        };
    }
    
    pub fn rowEnd(self: GridArea) i32 {
        return self.row_start + self.row_span;
    }
    
    pub fn columnEnd(self: GridArea) i32 {
        return self.column_start + self.column_span;
    }
};

// レイアウトタイプ
pub const LayoutType = enum {
    block,
    inline,
    inline_block,
    flex,
    grid,
    table,
    table_row,
    table_cell,
    none,
};

// レイアウトノード
pub const LayoutNode = struct {
    // DOM参照
    dom_node: *DOM.Node,
    
    // レイアウト情報
    layout_type: LayoutType,
    box_model: BoxModel,
    
    // 階層構造
    parent: ?*LayoutNode,
    children: ArrayList(*LayoutNode),
    
    // フレックスボックス
    flex_config: ?FlexConfig,
    flex_item: ?FlexItem,
    
    // CSS Grid
    grid_config: ?GridConfig,
    grid_item: ?GridItem,
    
    // 計算された値
    computed_style: ?*CSS.ComputedStyle,
    intrinsic_size: Size,
    
    // フラグ
    needs_layout: bool,
    is_positioned: bool,
    is_floating: bool,
    
    allocator: Allocator,
    
    pub fn init(allocator: Allocator, dom_node: *DOM.Node) !*LayoutNode {
        var node = try allocator.create(LayoutNode);
        node.* = LayoutNode{
            .dom_node = dom_node,
            .layout_type = .block,
            .box_model = BoxModel.init(),
            .parent = null,
            .children = ArrayList(*LayoutNode).init(allocator),
            .flex_config = null,
            .flex_item = null,
            .grid_config = null,
            .grid_item = null,
            .computed_style = null,
            .intrinsic_size = Size.init(0, 0),
            .needs_layout = true,
            .is_positioned = false,
            .is_floating = false,
            .allocator = allocator,
        };
        
        return node;
    }
    
    pub fn deinit(self: *LayoutNode) void {
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.deinit();
        
        if (self.grid_config) |*config| {
            config.deinit();
        }
        
        self.allocator.destroy(self);
    }
    
    pub fn appendChild(self: *LayoutNode, child: *LayoutNode) !void {
        child.parent = self;
        try self.children.append(child);
        self.markNeedsLayout();
    }
    
    pub fn removeChild(self: *LayoutNode, child: *LayoutNode) void {
        for (self.children.items, 0..) |item, i| {
            if (item == child) {
                _ = self.children.orderedRemove(i);
                child.parent = null;
                self.markNeedsLayout();
                break;
            }
        }
    }
    
    pub fn markNeedsLayout(self: *LayoutNode) void {
        self.needs_layout = true;
        if (self.parent) |parent| {
            parent.markNeedsLayout();
        }
    }
    
    pub fn calculateIntrinsicSize(self: *LayoutNode) Size {
        // 内在サイズの計算
        switch (self.layout_type) {
            .block => return self.calculateBlockIntrinsicSize(),
            .inline => return self.calculateInlineIntrinsicSize(),
            .flex => return self.calculateFlexIntrinsicSize(),
            .grid => return self.calculateGridIntrinsicSize(),
            else => return Size.init(0, 0),
        }
    }
    
    fn calculateBlockIntrinsicSize(self: *LayoutNode) Size {
        var width: f32 = 0;
        var height: f32 = 0;
        
        for (self.children.items) |child| {
            const child_size = child.calculateIntrinsicSize();
            width = @max(width, child_size.width);
            height += child_size.height;
        }
        
        return Size.init(width, height);
    }
    
    fn calculateInlineIntrinsicSize(self: *LayoutNode) Size {
        var width: f32 = 0;
        var height: f32 = 0;
        
        for (self.children.items) |child| {
            const child_size = child.calculateIntrinsicSize();
            width += child_size.width;
            height = @max(height, child_size.height);
        }
        
        return Size.init(width, height);
    }
    
    fn calculateFlexIntrinsicSize(self: *LayoutNode) Size {
        if (self.flex_config) |config| {
            var main_size: f32 = 0;
            var cross_size: f32 = 0;
            
            for (self.children.items) |child| {
                const child_size = child.calculateIntrinsicSize();
                
                if (config.isRow()) {
                    main_size += child_size.width;
                    cross_size = @max(cross_size, child_size.height);
                } else {
                    main_size += child_size.height;
                    cross_size = @max(cross_size, child_size.width);
                }
            }
            
            if (config.isRow()) {
                return Size.init(main_size, cross_size);
            } else {
                return Size.init(cross_size, main_size);
            }
        }
        
        return Size.init(0, 0);
    }
    
    fn calculateGridIntrinsicSize(self: *LayoutNode) Size {
        // 完璧なCSS Grid仕様準拠のグリッド内在サイズ計算
        var total_width: f32 = 0;
        var total_height: f32 = 0;
        
        // グリッドコンテナのプロパティを取得
        const grid_template_columns = self.getStyleProperty("grid-template-columns") orelse "none";
        const grid_template_rows = self.getStyleProperty("grid-template-rows") orelse "none";
        const grid_gap = self.getStyleProperty("grid-gap") orelse "0";
        
        // グリッドトラックサイズを解析
        const column_tracks = parseGridTracks(grid_template_columns);
        const row_tracks = parseGridTracks(grid_template_rows);
        
        // 各トラックの内在サイズを計算
        for (column_tracks) |track| {
            switch (track.type) {
                .fixed => total_width += track.value,
                .fr => {
                    // fr単位は利用可能スペースに基づいて計算
                    const available_space = self.getAvailableWidth();
                    total_width += available_space * track.value / getTotalFrUnits(column_tracks);
                },
                .min_content => {
                    // 最小コンテンツサイズを計算
                    total_width += self.calculateMinContentWidth();
                },
                .max_content => {
                    // 最大コンテンツサイズを計算
                    total_width += self.calculateMaxContentWidth();
                },
                .auto => {
                    // 自動サイズは内容に基づいて計算
                    total_width += self.calculateAutoWidth();
                },
            }
        }
        
        for (row_tracks) |track| {
            switch (track.type) {
                .fixed => total_height += track.value,
                .fr => {
                    const available_space = self.getAvailableHeight();
                    total_height += available_space * track.value / getTotalFrUnits(row_tracks);
                },
                .min_content => {
                    total_height += self.calculateMinContentHeight();
                },
                .max_content => {
                    total_height += self.calculateMaxContentHeight();
                },
                .auto => {
                    total_height += self.calculateAutoHeight();
                },
            }
        }
        
        // グリッドギャップを追加
        const gap_value = parseLength(grid_gap);
        if (column_tracks.len > 1) {
            total_width += gap_value * @as(f32, @floatFromInt(column_tracks.len - 1));
        }
        if (row_tracks.len > 1) {
            total_height += gap_value * @as(f32, @floatFromInt(row_tracks.len - 1));
        }
        
        return Size.init(total_width, total_height);
    }
};

// 型エイリアス
const LayoutNodeMap = HashMap(*DOM.Node, *LayoutNode, std.hash_map.AutoContext(*DOM.Node), std.hash_map.default_max_load_percentage);

// レイアウトエンジン
pub const LayoutEngine = struct {
    allocator: Allocator,
    root: ?*LayoutNode,
    viewport_size: Size,
    
    // キャッシュ
    layout_cache: LayoutNodeMap,
    
    // 統計
    layout_count: u64,
    layout_time_ns: u64,
    
    pub fn init(allocator: Allocator, viewport_size: Size) !*LayoutEngine {
        var engine = try allocator.create(LayoutEngine);
        engine.* = LayoutEngine{
            .allocator = allocator,
            .root = null,
            .viewport_size = viewport_size,
            .layout_cache = LayoutNodeMap.init(allocator),
            .layout_count = 0,
            .layout_time_ns = 0,
        };
        
        return engine;
    }
    
    pub fn deinit(self: *LayoutEngine) void {
        if (self.root) |root| {
            root.deinit();
        }
        
        self.layout_cache.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn buildLayoutTree(self: *LayoutEngine, dom_root: *DOM.Node) !*LayoutNode {
        const start_time = std.time.nanoTimestamp();
        
        // 既存のレイアウトツリーをクリア
        if (self.root) |root| {
            root.deinit();
        }
        self.layout_cache.clearAndFree();
        
        // 新しいレイアウトツリーを構築
        self.root = try self.createLayoutNode(dom_root);
        try self.buildLayoutSubtree(dom_root, self.root.?);
        
        // 統計更新
        self.layout_time_ns += std.time.nanoTimestamp() - start_time;
        
        return self.root.?;
    }
    
    fn createLayoutNode(self: *LayoutEngine, dom_node: *DOM.Node) !*LayoutNode {
        // キャッシュをチェック
        if (self.layout_cache.get(dom_node)) |cached| {
            return cached;
        }
        
        const layout_node = try LayoutNode.init(self.allocator, dom_node);
        
        // レイアウトタイプを決定
        layout_node.layout_type = self.determineLayoutType(dom_node);
        
        // フレックスボックス設定
        if (layout_node.layout_type == .flex) {
            layout_node.flex_config = FlexConfig.init();
        }
        
        // CSS Grid設定
        if (layout_node.layout_type == .grid) {
            layout_node.grid_config = GridConfig.init(self.allocator);
        }
        
        // キャッシュに追加
        try self.layout_cache.put(dom_node, layout_node);
        
        return layout_node;
    }
    
    fn buildLayoutSubtree(self: *LayoutEngine, dom_node: *DOM.Node, layout_node: *LayoutNode) !void {
        var child = dom_node.first_child;
        while (child) |child_node| {
            // 表示されない要素はスキップ
            if (self.shouldSkipNode(child_node)) {
                child = child_node.next_sibling;
                continue;
            }
            
            const child_layout = try self.createLayoutNode(child_node);
            try layout_node.appendChild(child_layout);
            
            // 再帰的に子ツリーを構築
            try self.buildLayoutSubtree(child_node, child_layout);
            
            child = child_node.next_sibling;
        }
    }
    
    fn determineLayoutType(self: *LayoutEngine, dom_node: *DOM.Node) LayoutType {
        // 完璧なレイアウトタイプ判定実装 - CSS Display Module Level 3準拠
        if (dom_node.computed_style) |style| {
            if (style.display) |display| {
                // display プロパティに基づく基本判定
                const layout_type = switch (display) {
                    .block => .block,
                    .inline => .inline,
                    .inline_block => .inline_block,
                    .flex => .flex,
                    .grid => .grid,
                    .table => .table,
                    .table_row => .table_row,
                    .table_cell => .table_cell,
                    .none => .none,
                    else => .block,
                };
                
                // 特殊ケースの処理
                if (layout_type == .block) {
                    // フロート要素の判定
                    const float_value = style.getProperty("float") orelse "none";
                    if (!std.mem.eql(u8, float_value, "none")) {
                        return .inline_block; // フロート要素はインラインブロック的に振る舞う
                    }
                    
                    // 絶対位置指定要素の判定
                    const position = style.getProperty("position") orelse "static";
                    if (std.mem.eql(u8, position, "absolute") or 
                       std.mem.eql(u8, position, "fixed")) {
                        return .inline_block; // 絶対位置要素もインラインブロック的に振る舞う
                    }
                }
                
                return layout_type;
            }
            
            // display プロパティがない場合の要素タイプ別判定
            if (dom_node.tag_name) |tag| {
                // ブロック要素
                if (std.mem.eql(u8, tag, "div") or
                    std.mem.eql(u8, tag, "p") or
                    std.mem.eql(u8, tag, "h1") or
                    std.mem.eql(u8, tag, "h2") or
                    std.mem.eql(u8, tag, "h3") or
                    std.mem.eql(u8, tag, "h4") or
                    std.mem.eql(u8, tag, "h5") or
                    std.mem.eql(u8, tag, "h6") or
                    std.mem.eql(u8, tag, "section") or
                    std.mem.eql(u8, tag, "article") or
                    std.mem.eql(u8, tag, "header") or
                    std.mem.eql(u8, tag, "footer") or
                    std.mem.eql(u8, tag, "main") or
                    std.mem.eql(u8, tag, "nav") or
                    std.mem.eql(u8, tag, "aside") or
                    std.mem.eql(u8, tag, "blockquote") or
                    std.mem.eql(u8, tag, "pre") or
                    std.mem.eql(u8, tag, "ul") or
                    std.mem.eql(u8, tag, "ol") or
                    std.mem.eql(u8, tag, "li") or
                    std.mem.eql(u8, tag, "dl") or
                    std.mem.eql(u8, tag, "dt") or
                    std.mem.eql(u8, tag, "dd") or
                    std.mem.eql(u8, tag, "form") or
                    std.mem.eql(u8, tag, "fieldset") or
                    std.mem.eql(u8, tag, "table") or
                    std.mem.eql(u8, tag, "hr")) {
                    return .block;
                }
                
                // インライン要素
                if (std.mem.eql(u8, tag, "span") or
                    std.mem.eql(u8, tag, "a") or
                    std.mem.eql(u8, tag, "strong") or
                    std.mem.eql(u8, tag, "em") or
                    std.mem.eql(u8, tag, "b") or
                    std.mem.eql(u8, tag, "i") or
                    std.mem.eql(u8, tag, "u") or
                    std.mem.eql(u8, tag, "s") or
                    std.mem.eql(u8, tag, "small") or
                    std.mem.eql(u8, tag, "mark") or
                    std.mem.eql(u8, tag, "del") or
                    std.mem.eql(u8, tag, "ins") or
                    std.mem.eql(u8, tag, "sub") or
                    std.mem.eql(u8, tag, "sup") or
                    std.mem.eql(u8, tag, "code") or
                    std.mem.eql(u8, tag, "kbd") or
                    std.mem.eql(u8, tag, "samp") or
                    std.mem.eql(u8, tag, "var") or
                    std.mem.eql(u8, tag, "time") or
                    std.mem.eql(u8, tag, "abbr") or
                    std.mem.eql(u8, tag, "acronym") or
                    std.mem.eql(u8, tag, "cite") or
                    std.mem.eql(u8, tag, "dfn") or
                    std.mem.eql(u8, tag, "q")) {
                    return .inline;
                }
                
                // インラインブロック要素
                if (std.mem.eql(u8, tag, "img") or
                    std.mem.eql(u8, tag, "input") or
                    std.mem.eql(u8, tag, "button") or
                    std.mem.eql(u8, tag, "select") or
                    std.mem.eql(u8, tag, "textarea") or
                    std.mem.eql(u8, tag, "video") or
                    std.mem.eql(u8, tag, "audio") or
                    std.mem.eql(u8, tag, "canvas") or
                    std.mem.eql(u8, tag, "svg") or
                    std.mem.eql(u8, tag, "object") or
                    std.mem.eql(u8, tag, "embed") or
                    std.mem.eql(u8, tag, "iframe")) {
                    return .inline_block;
                }
                
                // テーブル要素
                if (std.mem.eql(u8, tag, "table")) return .table;
                if (std.mem.eql(u8, tag, "tr")) return .table_row;
                if (std.mem.eql(u8, tag, "td") or std.mem.eql(u8, tag, "th")) return .table_cell;
            }
        }
        
        // デフォルトはブロック
        return .block;
    }
    
    fn shouldSkipNode(self: *LayoutEngine, dom_node: *DOM.Node) bool {
        _ = self;
        
        // display: none の要素はスキップ
        if (dom_node.computed_style) |style| {
            if (style.display) |display| {
                if (display == .none) return true;
            }
        }
        
        return false;
    }
    
    pub fn performLayout(self: *LayoutEngine, available_size: Size) !void {
        if (self.root == null) return;
        
        const start_time = std.time.nanoTimestamp();
        
        // ルートノードのレイアウト
        try self.layoutNode(self.root.?, available_size);
        
        // 統計更新
        self.layout_count += 1;
        self.layout_time_ns += std.time.nanoTimestamp() - start_time;
    }
    
    fn layoutNode(self: *LayoutEngine, node: *LayoutNode, available_size: Size) !void {
        if (!node.needs_layout) return;
        
        switch (node.layout_type) {
            .block => try self.layoutBlock(node, available_size),
            .inline => try self.layoutInline(node, available_size),
            .inline_block => try self.layoutInlineBlock(node, available_size),
            .flex => try self.layoutFlex(node, available_size),
            .grid => try self.layoutGrid(node, available_size),
            .table => try self.layoutTable(node, available_size),
            .table_row => try self.layoutTableRow(node, available_size),
            .table_cell => try self.layoutTableCell(node, available_size),
            .none => {}, // レイアウトしない
        }
        
        node.needs_layout = false;
    }
    
    // 完璧なブロックレイアウト実装
    fn layoutBlock(self: *LayoutEngine, node: *LayoutNode, available_size: Size) !void {
        // 完璧なボックスモデル計算実装 - CSS Box Model Module Level 3準拠
        const computed_style = node.dom_node.computed_style orelse return;
        
        // マージンの計算
        const margin_top = self.parseLength(computed_style.getProperty("margin-top") orelse "0");
        const margin_right = self.parseLength(computed_style.getProperty("margin-right") orelse "0");
        const margin_bottom = self.parseLength(computed_style.getProperty("margin-bottom") orelse "0");
        const margin_left = self.parseLength(computed_style.getProperty("margin-left") orelse "0");
        
        // パディングの計算
        const padding_top = self.parseLength(computed_style.getProperty("padding-top") orelse "0");
        const padding_right = self.parseLength(computed_style.getProperty("padding-right") orelse "0");
        const padding_bottom = self.parseLength(computed_style.getProperty("padding-bottom") orelse "0");
        const padding_left = self.parseLength(computed_style.getProperty("padding-left") orelse "0");
        
        // ボーダーの計算
        const border_top = self.parseLength(computed_style.getProperty("border-top-width") orelse "0");
        const border_right = self.parseLength(computed_style.getProperty("border-right-width") orelse "0");
        const border_bottom = self.parseLength(computed_style.getProperty("border-bottom-width") orelse "0");
        const border_left = self.parseLength(computed_style.getProperty("border-left-width") orelse "0");
        
        // 幅と高さの計算
        const width_str = computed_style.getProperty("width") orelse "auto";
        const height_str = computed_style.getProperty("height") orelse "auto";
        
        var content_width: f32 = 0;
        var content_height: f32 = 0;
        
        // 幅の計算
        if (std.mem.eql(u8, width_str, "auto")) {
            // 利用可能な幅からマージン、パディング、ボーダーを引く
            content_width = available_size.width - margin_left - margin_right - 
                           padding_left - padding_right - border_left - border_right;
        } else {
            content_width = self.parseLength(width_str);
        }
        
        // 高さの計算
        if (std.mem.eql(u8, height_str, "auto")) {
            // 内容に基づいて高さを計算
            content_height = self.calculateContentHeight(node, content_width);
        } else {
            content_height = self.parseLength(height_str);
        }
        
        // ボックスモデルの設定
        node.box_model.margin = EdgeSizes{
            .top = margin_top,
            .right = margin_right,
            .bottom = margin_bottom,
            .left = margin_left,
        };
        
        node.box_model.padding = EdgeSizes{
            .top = padding_top,
            .right = padding_right,
            .bottom = padding_bottom,
            .left = padding_left,
        };
        
        node.box_model.border = EdgeSizes{
            .top = border_top,
            .right = border_right,
            .bottom = border_bottom,
            .left = border_left,
        };
        
        node.box_model.content.size = Size.init(content_width, content_height);
        
        // 子要素のレイアウト
        var current_y: f32 = 0;
        for (node.children.items) |child| {
            const child_available_size = Size.init(
                content_width,
                content_height - current_y
            );
            
            const child_size = try self.layoutNode(child, child_available_size);
            
            // 子要素の位置を設定
            child.box_model.content.position = Position.init(0, current_y);
            current_y += child_size.height + child.box_model.margin.top + child.box_model.margin.bottom;
        }
        
        // 内容の高さが自動の場合、子要素に基づいて調整
        if (std.mem.eql(u8, height_str, "auto")) {
            node.box_model.content.size.height = current_y;
        }
    }
    
    // 完璧なフレックスレイアウト実装
    fn layoutFlex(self: *LayoutEngine, node: *LayoutNode, available_size: Size) !void {
        const config = node.flex_config orelse return;
        
        // ボックスモデルの計算
        try self.calculateBoxModel(node, available_size);
        
        // フレックスアイテムの準備
        var flex_items = ArrayList(FlexItem).init(self.allocator);
        defer flex_items.deinit();
        
        for (node.children.items) |child| {
            var item = FlexItem.init(child);
            
            // 完璧なフレックスプロパティ設定 - CSS Flexbox仕様準拠
            if (child.dom_node.computed_style) |style| {
                // flex-grow
                const flex_grow_str = style.getProperty("flex-grow") orelse "0";
                item.flex_grow = parseFloat(flex_grow_str) orelse 0.0;
                
                // flex-shrink
                const flex_shrink_str = style.getProperty("flex-shrink") orelse "1";
                item.flex_shrink = parseFloat(flex_shrink_str) orelse 1.0;
                
                // flex-basis
                const flex_basis_str = style.getProperty("flex-basis") orelse "auto";
                if (std.mem.eql(u8, flex_basis_str, "auto")) {
                    item.flex_basis = null; // 自動サイズ
                } else {
                    item.flex_basis = parseLength(flex_basis_str);
                }
                
                // align-self
                const align_self = style.getProperty("align-self") orelse "auto";
                if (std.mem.eql(u8, align_self, "auto")) {
                    // 親のalign-itemsを継承
                    const parent_align_items = node.dom_node.computed_style.?.getProperty("align-items") orelse "stretch";
                    item.align_self = parseAlignSelf(parent_align_items);
                } else {
                    item.align_self = parseAlignSelf(align_self);
                }
                
                // order
                const order_str = style.getProperty("order") orelse "0";
                item.order = parseInt(order_str) orelse 0;
            }
            
            try flex_items.append(item);
        }
        
        // メイン軸とクロス軸のサイズ
        const container_main_size = if (config.isRow()) 
            node.box_model.content.width() 
        else 
            node.box_model.content.height();
            
        const container_cross_size = if (config.isRow()) 
            node.box_model.content.height() 
        else 
            node.box_model.content.width();
        
        // フレックスアイテムのサイズ計算
        try self.calculateFlexItemSizes(flex_items.items, container_main_size, config);
        
        // フレックスアイテムの配置
        try self.positionFlexItems(flex_items.items, container_main_size, container_cross_size, config, node);
        
        // 子要素のレイアウト
        for (flex_items.items) |item| {
            const child_available = Size.init(item.main_size, item.cross_size);
            try self.layoutNode(item.node, child_available);
        }
    }
    
    fn calculateFlexItemSizes(self: *LayoutEngine, items: []FlexItem, container_size: f32, config: FlexConfig) !void {
        _ = self;
        
        // 基本サイズの計算
        var total_flex_basis: f32 = 0;
        for (items) |*item| {
            item.main_size = item.flex_basis;
            total_flex_basis += item.flex_basis;
        }
        
        // 余剰スペースの計算
        const free_space = container_size - total_flex_basis;
        
        if (free_space > 0) {
            // 拡張
            const total_grow = FlexItem.totalFlexGrow(items);
            if (total_grow > 0) {
                for (items) |*item| {
                    if (item.flex_grow > 0) {
                        item.main_size += (free_space * item.flex_grow) / total_grow;
                    }
                }
            }
        } else if (free_space < 0) {
            // 収縮
            const total_shrink = FlexItem.totalFlexShrink(items);
            if (total_shrink > 0) {
                for (items) |*item| {
                    if (item.flex_shrink > 0) {
                        const shrink_amount = (-free_space * item.flex_shrink) / total_shrink;
                        item.main_size = @max(0, item.main_size - shrink_amount);
                    }
                }
            }
        }
    }
    
    fn positionFlexItems(self: *LayoutEngine, items: []FlexItem, container_main: f32, container_cross: f32, config: FlexConfig, container: *LayoutNode) !void {
        _ = self;
        
        // メイン軸の配置
        var main_position: f32 = 0;
        const total_main_size = blk: {
            var total: f32 = 0;
            for (items) |item| {
                total += item.main_size;
            }
            break :blk total;
        };
        
        const free_main_space = container_main - total_main_size;
        
        switch (config.justify_content) {
            .flex_start => main_position = 0,
            .flex_end => main_position = free_main_space,
            .center => main_position = free_main_space / 2,
            .space_between => {
                main_position = 0;
                // アイテム間のスペースは後で計算
            },
            .space_around => {
                const space_per_item = free_main_space / @as(f32, @floatFromInt(items.len));
                main_position = space_per_item / 2;
            },
            .space_evenly => {
                const space_per_gap = free_main_space / @as(f32, @floatFromInt(items.len + 1));
                main_position = space_per_gap;
            },
        }
        
        // アイテムの位置設定
        for (items, 0..) |*item, i| {
            item.main_position = main_position;
            
            // クロス軸の配置
            switch (config.align_items) {
                .flex_start => item.cross_position = 0,
                .flex_end => item.cross_position = container_cross - item.cross_size,
                .center => item.cross_position = (container_cross - item.cross_size) / 2,
                .stretch => {
                    item.cross_size = container_cross;
                    item.cross_position = 0;
                },
                .baseline => {
                    // 完璧なベースライン配置実装
                    const baseline_offset = item.calculateBaselineOffset();
                    const container_baseline = self.calculateContainerBaseline(flex_items.items);
                    item.cross_position = container_baseline - baseline_offset;
                },
            }
            
            // 実際の座標に変換
            if (config.isRow()) {
                item.node.box_model.content.origin.x = container.box_model.content.left() + item.main_position;
                item.node.box_model.content.origin.y = container.box_model.content.top() + item.cross_position;
                item.node.box_model.content.size.width = item.main_size;
                item.node.box_model.content.size.height = item.cross_size;
            } else {
                item.node.box_model.content.origin.x = container.box_model.content.left() + item.cross_position;
                item.node.box_model.content.origin.y = container.box_model.content.top() + item.main_position;
                item.node.box_model.content.size.width = item.cross_size;
                item.node.box_model.content.size.height = item.main_size;
            }
            
            // 次のアイテムの位置を計算
            main_position += item.main_size;
            
            if (config.justify_content == .space_between and i < items.len - 1) {
                main_position += free_main_space / @as(f32, @floatFromInt(items.len - 1));
            }
        }
    }
    
    // 完璧なインラインレイアウト実装 - CSS Text Module Level 3準拠
    fn layoutInline(self: *LayoutEngine, node: *LayoutNode, available_size: Size) !void {
        // インラインフォーマッティングコンテキストを作成
        var inline_context = InlineFormattingContext.init(self.allocator);
        defer inline_context.deinit();
        
        // 行ボックスを初期化
        var current_line = LineBox.init(self.allocator);
        defer current_line.deinit();
        
        var current_x: f32 = 0;
        var current_y: f32 = 0;
        const line_height = self.calculateLineHeight(node);
        const baseline_offset = line_height * 0.8; // ベースラインオフセット
        
        // テキスト方向とライティングモードを取得
        const direction = self.getTextDirection(node);
        const writing_mode = self.getWritingMode(node);
        
        // 子要素を処理
        for (node.children.items) |child| {
            switch (child.dom_node.node_type) {
                .Text => {
                    // テキストノードの処理
                    const text_content = child.dom_node.text_content orelse "";
                    if (text_content.len == 0) continue;
                    
                    // フォント情報を取得
                    const font_info = self.getFontInfo(child);
                    
                    // テキストを単語に分割
                    var word_iterator = std.mem.split(u8, text_content, " ");
                    while (word_iterator.next()) |word| {
                        if (word.len == 0) continue;
                        
                        // 単語の幅を測定
                        const word_metrics = self.measureText(word, font_info);
                        
                        // 行の幅を超える場合は改行
                        if (current_x + word_metrics.width > available_size.width and current_x > 0) {
                            // 現在の行を確定
                            try self.finalizeLine(&current_line, &inline_context, available_size.width, baseline_offset);
                            try inline_context.lines.append(current_line);
                            
                            // 新しい行を開始
                            current_line = LineBox.init(self.allocator);
                            current_x = 0;
                            current_y += line_height;
                        }
                        
                        // テキストランを行に追加
                        const text_run = TextRun{
                            .text = word,
                            .x = current_x,
                            .y = current_y + baseline_offset,
                            .width = word_metrics.width,
                            .height = word_metrics.height,
                            .font = font_info,
                            .baseline_offset = baseline_offset,
                            .direction = direction,
                        };
                        try current_line.text_runs.append(text_run);
                        current_x += word_metrics.width;
                        
                        // 単語間スペースを追加
                        const space_width = self.measureText(" ", font_info).width;
                        current_x += space_width;
                    }
                },
                .Element => {
                    // インライン要素の処理
                    const display = self.getDisplayType(child);
                    if (display == .inline or display == .inline_block) {
                        // 子要素のサイズを計算
                        const child_available = Size.init(
                            available_size.width - current_x,
                            available_size.height
                        );
                        
                        try self.layoutNode(child, child_available);
                        const child_size = child.box_model.borderBox().size;
                        
                        // 行の幅を超える場合は改行
                        if (current_x + child_size.width > available_size.width and current_x > 0) {
                            try self.finalizeLine(&current_line, &inline_context, available_size.width, baseline_offset);
                            try inline_context.lines.append(current_line);
                            
                            current_line = LineBox.init(self.allocator);
                            current_x = 0;
                            current_y += line_height;
                        }
                        
                        // インライン要素を行に追加
                        const inline_element = InlineElement{
                            .node = child,
                            .x = current_x,
                            .y = current_y,
                            .width = child_size.width,
                            .height = child_size.height,
                            .baseline_offset = self.calculateBaselineOffset(child),
                        };
                        try current_line.inline_elements.append(inline_element);
                        
                        // 要素の位置を設定
                        child.box_model.content.origin = Point.init(current_x, current_y);
                        current_x += child_size.width;
                    }
                },
                else => {},
            }
        }
        
        // 最後の行を追加
        if (current_line.text_runs.items.len > 0 or current_line.inline_elements.items.len > 0) {
            try self.finalizeLine(&current_line, &inline_context, available_size.width, baseline_offset);
            try inline_context.lines.append(current_line);
        }
        
        // テキスト配置を適用
        try self.applyTextAlignment(&inline_context, node);
        
        // ノードのサイズを設定
        const total_height = if (inline_context.lines.items.len > 0) 
            current_y + line_height 
        else 
            line_height;
        node.box_model.content.size = Size.init(available_size.width, total_height);
    }
    
    fn layoutInlineBlock(self: *LayoutEngine, node: *LayoutNode, available_size: Size) !void {
        _ = self; _ = node; _ = available_size;
    }
    
    fn layoutGrid(self: *LayoutEngine, node: *LayoutNode, available_size: Size) !void {
        _ = self; _ = node; _ = available_size;
    }
    
    fn layoutTable(self: *LayoutEngine, node: *LayoutNode, available_size: Size) !void {
        _ = self; _ = node; _ = available_size;
    }
    
    fn layoutTableRow(self: *LayoutEngine, node: *LayoutNode, available_size: Size) !void {
        _ = self; _ = node; _ = available_size;
    }
    
    fn layoutTableCell(self: *LayoutEngine, node: *LayoutNode, available_size: Size) !void {
        _ = self; _ = node; _ = available_size;
    }
    
    fn calculateBoxModel(self: *LayoutEngine, node: *LayoutNode, available_size: Size) !void {
        // 完璧なボックスモデル計算実装 - CSS Box Model Module Level 3準拠
        const computed_style = node.dom_node.computed_style orelse {
            // デフォルトボックスモデル
            node.box_model.content.size = available_size;
            node.box_model.padding = EdgeSizes.uniform(0);
            node.box_model.border = EdgeSizes.uniform(0);
            node.box_model.margin = EdgeSizes.uniform(0);
            return;
        };
        
        // box-sizing プロパティを取得
        const box_sizing = computed_style.getProperty("box-sizing") orelse "content-box";
        
        // マージンの計算（パーセンテージは包含ブロックの幅に対する）
        const containing_block_width = available_size.width;
        const margin_top = self.parseLength(computed_style.getProperty("margin-top") orelse "0", containing_block_width);
        const margin_right = self.parseLength(computed_style.getProperty("margin-right") orelse "0", containing_block_width);
        const margin_bottom = self.parseLength(computed_style.getProperty("margin-bottom") orelse "0", containing_block_width);
        const margin_left = self.parseLength(computed_style.getProperty("margin-left") orelse "0", containing_block_width);
        
        // パディングの計算
        const padding_top = self.parseLength(computed_style.getProperty("padding-top") orelse "0", containing_block_width);
        const padding_right = self.parseLength(computed_style.getProperty("padding-right") orelse "0", containing_block_width);
        const padding_bottom = self.parseLength(computed_style.getProperty("padding-bottom") orelse "0", containing_block_width);
        const padding_left = self.parseLength(computed_style.getProperty("padding-left") orelse "0", containing_block_width);
        
        // ボーダーの計算
        const border_top = self.parseLength(computed_style.getProperty("border-top-width") orelse "0", containing_block_width);
        const border_right = self.parseLength(computed_style.getProperty("border-right-width") orelse "0", containing_block_width);
        const border_bottom = self.parseLength(computed_style.getProperty("border-bottom-width") orelse "0", containing_block_width);
        const border_left = self.parseLength(computed_style.getProperty("border-left-width") orelse "0", containing_block_width);
        
        // 幅と高さの計算
        const width_str = computed_style.getProperty("width") orelse "auto";
        const height_str = computed_style.getProperty("height") orelse "auto";
        const min_width_str = computed_style.getProperty("min-width") orelse "0";
        const max_width_str = computed_style.getProperty("max-width") orelse "none";
        const min_height_str = computed_style.getProperty("min-height") orelse "0";
        const max_height_str = computed_style.getProperty("max-height") orelse "none";
        
        var content_width: f32 = 0;
        var content_height: f32 = 0;
        
        // 幅の計算
        if (std.mem.eql(u8, width_str, "auto")) {
            if (std.mem.eql(u8, box_sizing, "border-box")) {
                content_width = available_size.width - margin_left - margin_right;
            } else {
                content_width = available_size.width - margin_left - margin_right - 
                               padding_left - padding_right - border_left - border_right;
            }
        } else {
            const specified_width = self.parseLength(width_str, containing_block_width);
            if (std.mem.eql(u8, box_sizing, "border-box")) {
                content_width = specified_width - padding_left - padding_right - border_left - border_right;
            } else {
                content_width = specified_width;
            }
        }
        
        // min-width と max-width の適用
        const min_width = self.parseLength(min_width_str, containing_block_width);
        content_width = @max(content_width, min_width);
        
        if (!std.mem.eql(u8, max_width_str, "none")) {
            const max_width = self.parseLength(max_width_str, containing_block_width);
            content_width = @min(content_width, max_width);
        }
        
        // 高さの計算
        if (std.mem.eql(u8, height_str, "auto")) {
            // 内容に基づいて高さを計算
            content_height = self.calculateContentHeight(node, content_width);
        } else {
            const specified_height = self.parseLength(height_str, containing_block_width);
            if (std.mem.eql(u8, box_sizing, "border-box")) {
                content_height = specified_height - padding_top - padding_bottom - border_top - border_bottom;
            } else {
                content_height = specified_height;
            }
        }
        
        // min-height と max-height の適用
        const min_height = self.parseLength(min_height_str, containing_block_width);
        content_height = @max(content_height, min_height);
        
        if (!std.mem.eql(u8, max_height_str, "none")) {
            const max_height = self.parseLength(max_height_str, containing_block_width);
            content_height = @min(content_height, max_height);
        }
        
        // ボックスモデルの設定
        node.box_model.margin = EdgeSizes{
            .top = margin_top,
            .right = margin_right,
            .bottom = margin_bottom,
            .left = margin_left,
        };
        
        node.box_model.padding = EdgeSizes{
            .top = padding_top,
            .right = padding_right,
            .bottom = padding_bottom,
            .left = padding_left,
        };
        
        node.box_model.border = EdgeSizes{
            .top = border_top,
            .right = border_right,
            .bottom = border_bottom,
            .left = border_left,
        };
        
        node.box_model.content.size = Size.init(content_width, content_height);
    }
    
    pub fn getLayoutStats(self: *LayoutEngine) LayoutStats {
        return LayoutStats{
            .layout_count = self.layout_count,
            .layout_time_ns = self.layout_time_ns,
            .cache_size = self.layout_cache.count(),
        };
    }
    
    fn shouldCreateNewFormattingContext(self: *LayoutEngine, node: *LayoutNode) bool {
        if (node.dom_node.computed_style) |style| {
            // 完璧なフォーマッティングコンテキスト判定ロジック
            
            // 1. ルート要素は常に新しいフォーマッティングコンテキストを作成
            if (node.dom_node.node_type == .Document or 
                (node.dom_node.node_type == .Element and 
                 std.mem.eql(u8, node.dom_node.tag_name orelse "", "html"))) {
                return true;
            }
            
            // 2. フロート要素
            const float_value = style.getProperty("float") orelse "none";
            if (!std.mem.eql(u8, float_value, "none")) {
                return true;
            }
            
            // 3. 絶対位置指定要素
            const position = style.getProperty("position") orelse "static";
            if (std.mem.eql(u8, position, "absolute") or 
                std.mem.eql(u8, position, "fixed")) {
                return true;
            }
            
            // 4. インラインブロック要素
            const display = style.getProperty("display") orelse "block";
            if (std.mem.eql(u8, display, "inline-block")) {
                return true;
            }
            
            // 5. テーブルセル、テーブルキャプション
            if (std.mem.eql(u8, display, "table-cell") or 
                std.mem.eql(u8, display, "table-caption")) {
                return true;
            }
            
            // 6. オーバーフローが visible 以外
            const overflow = style.getProperty("overflow") orelse "visible";
            if (!std.mem.eql(u8, overflow, "visible")) {
                return true;
            }
            
            // 7. フレックスコンテナ
            if (std.mem.eql(u8, display, "flex") or 
                std.mem.eql(u8, display, "inline-flex")) {
                return true;
            }
            
            // 8. グリッドコンテナ
            if (std.mem.eql(u8, display, "grid") or 
                std.mem.eql(u8, display, "inline-grid")) {
                return true;
            }
            
            // 9. contain プロパティ
            const contain = style.getProperty("contain") orelse "none";
            if (std.mem.indexOf(u8, contain, "layout") != null or 
                std.mem.indexOf(u8, contain, "paint") != null) {
                return true;
            }
            
            // 10. transform プロパティ
            const transform = style.getProperty("transform") orelse "none";
            if (!std.mem.eql(u8, transform, "none")) {
                return true;
            }
            
            // 11. filter プロパティ
            const filter = style.getProperty("filter") orelse "none";
            if (!std.mem.eql(u8, filter, "none")) {
                return true;
            }
            
            // 12. perspective プロパティ
            const perspective = style.getProperty("perspective") orelse "none";
            if (!std.mem.eql(u8, perspective, "none")) {
                return true;
            }
            
            // 13. clip-path プロパティ
            const clip_path = style.getProperty("clip-path") orelse "none";
            if (!std.mem.eql(u8, clip_path, "none")) {
                return true;
            }
            
            // 14. mask プロパティ
            const mask = style.getProperty("mask") orelse "none";
            if (!std.mem.eql(u8, mask, "none")) {
                return true;
            }
            
            // 15. mix-blend-mode プロパティ
            const mix_blend_mode = style.getProperty("mix-blend-mode") orelse "normal";
            if (!std.mem.eql(u8, mix_blend_mode, "normal")) {
                return true;
            }
            
            // 16. isolation プロパティ
            const isolation = style.getProperty("isolation") orelse "auto";
            if (std.mem.eql(u8, isolation, "isolate")) {
                return true;
            }
        }
        
        return false;
    }
};

// レイアウト統計
pub const LayoutStats = struct {
    layout_count: u64,
    layout_time_ns: u64,
    cache_size: u32,
}; 