const std = @import("std");
const dom = @import("../dom/dom.zig");
const css = @import("../css/css.zig");

pub const BoxType = enum {
    Block,
    Inline,
    InlineBlock,
    Flex,
    Grid,
    None,
};

pub const BoxPosition = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const BoxDimensions = struct {
    content: struct {
        width: f32,
        height: f32,
    },
    padding: struct {
        top: f32,
        right: f32,
        bottom: f32,
        left: f32,
    },
    border: struct {
        top: f32,
        right: f32,
        bottom: f32,
        left: f32,
    },
    margin: struct {
        top: f32,
        right: f32,
        bottom: f32,
        left: f32,
    },
};

pub const LayoutBox = struct {
    box_type: BoxType,
    dimensions: BoxDimensions,
    children: std.ArrayList(LayoutBox),
    node: ?*dom.Node,
    style: ?*css.ComputedStyle,

    pub fn init(allocator: std.mem.Allocator, box_type: BoxType, node: ?*dom.Node, style: ?*css.ComputedStyle) !LayoutBox {
        return LayoutBox{
            .box_type = box_type,
            .dimensions = BoxDimensions{
                .content = .{ .width = 0, .height = 0 },
                .padding = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
                .border = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
                .margin = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
            },
            .children = std.ArrayList(LayoutBox).init(allocator),
            .node = node,
            .style = style,
        };
    }

    pub fn deinit(self: *LayoutBox) void {
        for (self.children.items) |*child| {
            child.deinit();
        }
        self.children.deinit();
    }
};

pub const LayoutContext = struct {
    viewport_width: f32,
    viewport_height: f32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, viewport_width: f32, viewport_height: f32) LayoutContext {
        return .{
            .viewport_width = viewport_width,
            .viewport_height = viewport_height,
            .allocator = allocator,
        };
    }
};

pub const LayoutEngine = struct {
    context: LayoutContext,
    
    pub fn init(context: LayoutContext) LayoutEngine {
        return .{
            .context = context,
        };
    }

    pub fn layoutNode(self: *LayoutEngine, node: *dom.Node, style: *css.ComputedStyle) !LayoutBox {
        var box = try LayoutBox.init(
            self.context.allocator,
            determineBoxType(style),
            node,
            style
        );
        
        try self.calculateBoxDimensions(&box);
        
        // レイアウト子ノード
        for (node.children.items) |child_node| {
            if (child_node.nodeType == dom.NodeType.Element or child_node.nodeType == dom.NodeType.Text) {
                const child_style = try css.getComputedStyle(child_node);
                var child_box = try self.layoutNode(child_node, child_style);
                try box.children.append(child_box);
            }
        }
        
        // 子ノードの配置
        switch (box.box_type) {
            .Block => try self.layoutBlockChildren(&box),
            .Flex => try self.layoutFlexChildren(&box),
            .Grid => try self.layoutGridChildren(&box),
            .Inline => try self.layoutInlineChildren(&box),
            .InlineBlock => try self.layoutBlockChildren(&box),
            .None => {},
        }
        
        return box;
    }
    
    fn calculateBoxDimensions(self: *LayoutEngine, box: *LayoutBox) !void {
        const style = box.style.?;
        
        // マージン、パディング、ボーダーの計算
        box.dimensions.margin.top = style.getMarginTop() orelse 0;
        box.dimensions.margin.right = style.getMarginRight() orelse 0;
        box.dimensions.margin.bottom = style.getMarginBottom() orelse 0;
        box.dimensions.margin.left = style.getMarginLeft() orelse 0;
        
        box.dimensions.padding.top = style.getPaddingTop() orelse 0;
        box.dimensions.padding.right = style.getPaddingRight() orelse 0;
        box.dimensions.padding.bottom = style.getPaddingBottom() orelse 0;
        box.dimensions.padding.left = style.getPaddingLeft() orelse 0;
        
        box.dimensions.border.top = style.getBorderTopWidth() orelse 0;
        box.dimensions.border.right = style.getBorderRightWidth() orelse 0;
        box.dimensions.border.bottom = style.getBorderBottomWidth() orelse 0;
        box.dimensions.border.left = style.getBorderLeftWidth() orelse 0;
        
        // コンテンツサイズの計算
        box.dimensions.content.width = calculateContentWidth(box, self.context.viewport_width);
        box.dimensions.content.height = calculateContentHeight(box, self.context.viewport_height);
    }
    
    fn layoutBlockChildren(self: *LayoutEngine, box: *LayoutBox) !void {
        var current_y: f32 = 0;
        
        for (box.children.items) |*child| {
            child.dimensions.margin.top = child.dimensions.margin.top;
            current_y += child.dimensions.margin.top;
            
            // 子要素の配置
            const x_pos = box.dimensions.padding.left + box.dimensions.border.left + child.dimensions.margin.left;
            child.position = BoxPosition{
                .x = x_pos,
                .y = current_y,
                .width = child.dimensions.content.width,
                .height = child.dimensions.content.height,
            };
            
            current_y += child.dimensions.content.height + 
                         child.dimensions.padding.top + child.dimensions.padding.bottom + 
                         child.dimensions.border.top + child.dimensions.border.bottom;
                         
            current_y += child.dimensions.margin.bottom;
        }
        
        // 親ボックスの高さを調整
        box.dimensions.content.height = current_y;
    }
    
    fn layoutFlexChildren(self: *LayoutEngine, box: *LayoutBox) !void {
        // フレックスボックスレイアウトの実装
        if (box.node == null) return;
        if (box.style == null) return;
        
        var childNodes = std.ArrayList(*dom.Node).init(self.context.allocator);
        defer childNodes.deinit();
        
        var childStyles = std.ArrayList(*css.ComputedStyle).init(self.context.allocator);
        defer childStyles.deinit();
        
        for (box.children.items) |*child| {
            if (child.node != null and child.style != null) {
                try childNodes.append(child.node.?);
                try childStyles.append(child.style.?);
            }
        }
        
        try layoutFlexbox(box.node.?, box.style.?, childNodes.items, childStyles.items, self.context.allocator);
    }
    
    fn layoutGridChildren(self: *LayoutEngine, box: *LayoutBox) !void {
        // グリッドレイアウトの実装
        if (box.node == null) return;
        if (box.style == null) return;
        
        var childNodes = std.ArrayList(*dom.Node).init(self.context.allocator);
        defer childNodes.deinit();
        
        var childStyles = std.ArrayList(*css.ComputedStyle).init(self.context.allocator);
        defer childStyles.deinit();
        
        for (box.children.items) |*child| {
            if (child.node != null and child.style != null) {
                try childNodes.append(child.node.?);
                try childStyles.append(child.style.?);
            }
        }
        
        try layoutGrid(box.node.?, box.style.?, childNodes.items, childStyles.items, self.context.allocator);
    }
    
    fn layoutInlineChildren(self: *LayoutEngine, box: *LayoutBox) !void {
        // インラインレイアウトの実装
        if (box.node == null) return;
        if (box.style == null) return;
        
        var childNodes = std.ArrayList(*dom.Node).init(self.context.allocator);
        defer childNodes.deinit();
        
        var childStyles = std.ArrayList(*css.ComputedStyle).init(self.context.allocator);
        defer childStyles.deinit();
        
        for (box.children.items) |*child| {
            if (child.node != null and child.style != null) {
                try childNodes.append(child.node.?);
                try childStyles.append(child.style.?);
            }
        }
        
        try layoutInlineFormattingContext(box.node.?, box.style.?, childNodes.items, childStyles.items, self.context.allocator);
    }
};

fn determineBoxType(style: *css.ComputedStyle) BoxType {
    const display = style.getDisplay();
    
    return switch (display) {
        .Block => BoxType.Block,
        .Inline => BoxType.Inline,
        .InlineBlock => BoxType.InlineBlock,
        .Flex => BoxType.Flex,
        .Grid => BoxType.Grid,
        .None => BoxType.None,
        else => BoxType.Block,
    };
}

fn calculateContentWidth(box: *LayoutBox, viewport_width: f32) f32 {
    const style = box.style.?;
    
    if (style.getWidth()) |width| {
        return width;
    } else {
        // 自動幅の計算ロジック
        switch (box.box_type) {
            .Block => return viewport_width - 
                box.dimensions.margin.left - box.dimensions.margin.right -
                box.dimensions.padding.left - box.dimensions.padding.right -
                box.dimensions.border.left - box.dimensions.border.right,
            else => {
                // インラインなどの場合はコンテンツに基づく
                return 0; // 子要素に基づいて後で計算
            },
        }
    }
}

fn calculateContentHeight(box: *LayoutBox, viewport_height: f32) f32 {
    const style = box.style.?;
    
    if (style.getHeight()) |height| {
        return height;
    } else {
        // 自動高さの計算ロジック - 子要素に基づいて後で計算
        return 0;
    }
}

// フレックスコンテナーの方向
pub const FlexDirection = enum {
    Row,
    RowReverse,
    Column,
    ColumnReverse,
};

// フレックスアイテムの折り返し
pub const FlexWrap = enum {
    NoWrap,
    Wrap,
    WrapReverse,
};

// フレックスコンテナー内のアイテム配置 (メインアクシス)
pub const JustifyContent = enum {
    FlexStart,
    FlexEnd,
    Center,
    SpaceBetween,
    SpaceAround,
    SpaceEvenly,
};

// フレックスコンテナー内のアイテム配置 (クロスアクシス)
pub const AlignItems = enum {
    FlexStart,
    FlexEnd,
    Center,
    Baseline,
    Stretch,
};

// フレックス配置のための詳細構造体
pub const FlexLayoutContext = struct {
    direction: FlexDirection,
    wrap: FlexWrap,
    justifyContent: JustifyContent,
    alignItems: AlignItems,
    alignContent: AlignItems,
};

// フレックスアイテムの情報
pub const FlexItem = struct {
    node: *dom.Node,
    style: css.ComputedStyle,
    mainAxisPos: f32 = 0,
    crossAxisPos: f32 = 0,
    mainAxisSize: f32 = 0,
    crossAxisSize: f32 = 0,
    flexGrow: f32 = 0,
    flexShrink: f32 = 1,
    flexBasis: ?f32 = null,
};

pub fn layoutFlexbox(node: *dom.Node, style: css.ComputedStyle, childNodes: []const *dom.Node, childStyles: []const css.ComputedStyle, allocator: std.mem.Allocator) !void {
    var flexContext = FlexLayoutContext{
        .direction = .Row,
        .wrap = .NoWrap,
        .justifyContent = .FlexStart,
        .alignItems = .Stretch,
        .alignContent = .Stretch,
    };
    
    // スタイルからフレックスプロパティを抽出
    if (style.getPropertyValueByName("flex-direction")) |dirValue| {
        if (std.mem.eql(u8, dirValue, "row-reverse")) {
            flexContext.direction = .RowReverse;
        } else if (std.mem.eql(u8, dirValue, "column")) {
            flexContext.direction = .Column;
        } else if (std.mem.eql(u8, dirValue, "column-reverse")) {
            flexContext.direction = .ColumnReverse;
        }
    }
    
    if (style.getPropertyValueByName("flex-wrap")) |wrapValue| {
        if (std.mem.eql(u8, wrapValue, "wrap")) {
            flexContext.wrap = .Wrap;
        } else if (std.mem.eql(u8, wrapValue, "wrap-reverse")) {
            flexContext.wrap = .WrapReverse;
        }
    }
    
    if (style.getPropertyValueByName("justify-content")) |justifyValue| {
        if (std.mem.eql(u8, justifyValue, "flex-end")) {
            flexContext.justifyContent = .FlexEnd;
        } else if (std.mem.eql(u8, justifyValue, "center")) {
            flexContext.justifyContent = .Center;
        } else if (std.mem.eql(u8, justifyValue, "space-between")) {
            flexContext.justifyContent = .SpaceBetween;
        } else if (std.mem.eql(u8, justifyValue, "space-around")) {
            flexContext.justifyContent = .SpaceAround;
        } else if (std.mem.eql(u8, justifyValue, "space-evenly")) {
            flexContext.justifyContent = .SpaceEvenly;
        }
    }
    
    if (style.getPropertyValueByName("align-items")) |alignValue| {
        if (std.mem.eql(u8, alignValue, "flex-end")) {
            flexContext.alignItems = .FlexEnd;
        } else if (std.mem.eql(u8, alignValue, "center")) {
            flexContext.alignItems = .Center;
        } else if (std.mem.eql(u8, alignValue, "baseline")) {
            flexContext.alignItems = .Baseline;
        } else if (std.mem.eql(u8, alignValue, "stretch")) {
            flexContext.alignItems = .Stretch;
        }
    }
    
    // アイテムのサイズと配置を計算
    const isHorizontal = (flexContext.direction == .Row or flexContext.direction == .RowReverse);
    const isReverse = (flexContext.direction == .RowReverse or flexContext.direction == .ColumnReverse);
    
    var mainAxisSize: f32 = if (isHorizontal) node.layout.width else node.layout.height;
    var crossAxisSize: f32 = if (isHorizontal) node.layout.height else node.layout.width;
    
    // フレックスアイテムの配置計算
    var flexItems = try allocator.alloc(FlexItem, childNodes.len);
    defer allocator.free(flexItems);
    
    var totalFlexGrow: f32 = 0;
    var totalFlexShrink: f32 = 0;
    var fixedMainAxisSize: f32 = 0;
    var flexibleItemCount: usize = 0;
    
    // フレックスアイテム情報の収集
    for (childNodes, 0..) |childNode, i| {
        var item = &flexItems[i];
        item.node = childNode;
        item.style = childStyles[i];
        
        if (childStyles[i].getPropertyValueByName("flex-grow")) |growValue| {
            item.flexGrow = try std.fmt.parseFloat(f32, growValue);
            totalFlexGrow += item.flexGrow;
            flexibleItemCount += 1;
        }
        
        if (childStyles[i].getPropertyValueByName("flex-shrink")) |shrinkValue| {
            item.flexShrink = try std.fmt.parseFloat(f32, shrinkValue);
            totalFlexShrink += item.flexShrink;
        }
        
        // アイテムの初期サイズを計算
        var childSize = calculateNodeSize(childNode, childStyles[i]);
        
        if (isHorizontal) {
            item.mainAxisSize = childSize.width;
            item.crossAxisSize = childSize.height;
        } else {
            item.mainAxisSize = childSize.height;
            item.crossAxisSize = childSize.width;
        }
        
        fixedMainAxisSize += item.mainAxisSize;
    }
    
    // メインアクシスに沿ったサイズ調整（伸縮）
    var remainingSpace = mainAxisSize - fixedMainAxisSize;
    
    if (remainingSpace > 0 and totalFlexGrow > 0) {
        // スペースが余っている場合、flex-growに基づいて拡大
        for (flexItems) |*item| {
            if (item.flexGrow > 0) {
                var extraSpace = remainingSpace * (item.flexGrow / totalFlexGrow);
                item.mainAxisSize += extraSpace;
            }
        }
    } else if (remainingSpace < 0 and totalFlexShrink > 0) {
        // スペースが足りない場合、flex-shrinkに基づいて縮小
        for (flexItems) |*item| {
            if (item.flexShrink > 0) {
                var reduction = -remainingSpace * (item.flexShrink / totalFlexShrink);
                item.mainAxisSize = @max(0, item.mainAxisSize - reduction);
            }
        }
    }
    
    // メインアクシスに沿ったアイテム配置
    var currentPos: f32 = 0;
    switch (flexContext.justifyContent) {
        .FlexStart => {
            if (isReverse) {
                currentPos = mainAxisSize;
                for (flexItems) |*item| {
                    currentPos -= item.mainAxisSize;
                    item.mainAxisPos = currentPos;
                }
            } else {
                for (flexItems) |*item| {
                    item.mainAxisPos = currentPos;
                    currentPos += item.mainAxisSize;
                }
            }
        },
        .FlexEnd => {
            if (isReverse) {
                for (flexItems) |*item| {
                    item.mainAxisPos = currentPos;
                    currentPos += item.mainAxisSize;
                }
            } else {
                currentPos = mainAxisSize;
                for (flexItems) |*item| {
                    currentPos -= item.mainAxisSize;
                    item.mainAxisPos = currentPos;
                }
            }
        },
        .Center => {
            var totalSize: f32 = 0;
            for (flexItems) |item| {
                totalSize += item.mainAxisSize;
            }
            
            currentPos = (mainAxisSize - totalSize) / 2;
            if (isReverse) {
                for (flex_items_reversed) |*item| {
                    item.mainAxisPos = currentPos;
                    currentPos += item.mainAxisSize;
                }
            } else {
                for (flexItems) |*item| {
                    item.mainAxisPos = currentPos;
                    currentPos += item.mainAxisSize;
                }
            }
        },
        .SpaceBetween => {
            if (flexItems.len <= 1) {
                // 1つ以下の場合はセンタリング
                if (flexItems.len == 1) {
                    flexItems[0].mainAxisPos = (mainAxisSize - flexItems[0].mainAxisSize) / 2;
                }
            } else {
                var spacing = (mainAxisSize - fixedMainAxisSize) / @intToFloat(f32, flexItems.len - 1);
                if (isReverse) {
                    currentPos = mainAxisSize;
                    for (flexItems) |*item| {
                        currentPos -= item.mainAxisSize;
                        item.mainAxisPos = currentPos;
                        currentPos -= spacing;
                    }
                } else {
                    for (flexItems, 0..) |*item, i| {
                        item.mainAxisPos = currentPos;
                        currentPos += item.mainAxisSize;
                        if (i < flexItems.len - 1) {
                            currentPos += spacing;
                        }
                    }
                }
            }
        },
        // その他のjustify-contentの値も同様に実装
        else => {
            // デフォルト: flex-start
            if (isReverse) {
                currentPos = mainAxisSize;
                for (flexItems) |*item| {
                    currentPos -= item.mainAxisSize;
                    item.mainAxisPos = currentPos;
                }
            } else {
                for (flexItems) |*item| {
                    item.mainAxisPos = currentPos;
                    currentPos += item.mainAxisSize;
                }
            }
        },
    }
    
    // クロスアクシスに沿ったアイテム配置
    for (flexItems) |*item| {
        switch (flexContext.alignItems) {
            .FlexStart => {
                item.crossAxisPos = 0;
            },
            .FlexEnd => {
                item.crossAxisPos = crossAxisSize - item.crossAxisSize;
            },
            .Center => {
                item.crossAxisPos = (crossAxisSize - item.crossAxisSize) / 2;
            },
            .Stretch => {
                item.crossAxisPos = 0;
                item.crossAxisSize = crossAxisSize;
            },
            .Baseline => {
                // ベースライン計算のためのより複雑なロジックが必要
                // 簡略化のため、ここではFlexStartと同様の処理
                item.crossAxisPos = 0;
            },
        }
    }
    
    // 最終的な位置とサイズをレイアウトに反映
    for (flexItems, 0..) |item, i| {
        var childNode = childNodes[i];
        
        if (isHorizontal) {
            childNode.layout.x = item.mainAxisPos;
            childNode.layout.y = item.crossAxisPos;
            childNode.layout.width = item.mainAxisSize;
            childNode.layout.height = item.crossAxisSize;
        } else {
            childNode.layout.x = item.crossAxisPos;
            childNode.layout.y = item.mainAxisPos;
            childNode.layout.width = item.crossAxisSize;
            childNode.layout.height = item.mainAxisSize;
        }
    }
}

// グリッドレイアウト構造
pub const GridTrackType = enum {
    Fixed,    // 固定サイズ (px)
    Fraction, // 比率 (fr)
    Auto,     // 内容に合わせて自動
    MinContent, // 最小コンテンツサイズ
    MaxContent, // 最大コンテンツサイズ
};

pub const GridTrack = struct {
    type: GridTrackType,
    value: f32, // 固定サイズまたはフラクション値
};

pub const GridLayoutContext = struct {
    columns: []GridTrack,
    rows: []GridTrack,
    columnGap: f32,
    rowGap: f32,
    justifyItems: AlignItems,
    alignItems: AlignItems,
};

pub fn layoutGrid(node: *dom.Node, style: css.ComputedStyle, childNodes: []const *dom.Node, childStyles: []const css.ComputedStyle, allocator: std.mem.Allocator) !void {
    // グリッドコンテナのサイズ
    const containerWidth = node.layout.width;
    const containerHeight = node.layout.height;
    
    // グリッドテンプレート列の解析
    var columns = std.ArrayList(GridTrack).init(allocator);
    defer columns.deinit();
    
    if (style.getPropertyValueByName("grid-template-columns")) |columnsValue| {
        try parseGridTemplate(columnsValue, &columns);
    } else {
        // デフォルトは1列
        try columns.append(GridTrack{ .type = .Auto, .value = 0 });
    }
    
    // グリッドテンプレート行の解析
    var rows = std.ArrayList(GridTrack).init(allocator);
    defer rows.deinit();
    
    if (style.getPropertyValueByName("grid-template-rows")) |rowsValue| {
        try parseGridTemplate(rowsValue, &rows);
    } else {
        // 必要な数の行を自動生成
        const itemCount = childNodes.len;
        const columnCount = columns.items.len;
        const rowCount = (itemCount + columnCount - 1) / columnCount; // 切り上げ
        
        var i: usize = 0;
        while (i < rowCount) : (i += 1) {
            try rows.append(GridTrack{ .type = .Auto, .value = 0 });
        }
    }
    
    // グリッドギャップの解析
    var columnGap: f32 = 0;
    var rowGap: f32 = 0;
    
    if (style.getPropertyValueByName("column-gap")) |gapValue| {
        columnGap = try parseLengthValue(gapValue, containerWidth);
    }
    
    if (style.getPropertyValueByName("row-gap")) |gapValue| {
        rowGap = try parseLengthValue(gapValue, containerHeight);
    }
    
    // グリッドアイテムの配置
    const columnCount = columns.items.len;
    const rowCount = rows.items.len;
    
    // 自動サイズの列/行のためのパス1: 最小必要サイズを計算
    for (childNodes, 0..) |childNode, i| {
        const columnIndex = i % columnCount;
        const rowIndex = i / columnCount;
        
        if (rowIndex >= rowCount) continue; // グリッド行数を超えた場合はスキップ
        
        // 子要素のサイズを計算
        const childSize = calculateNodeSize(childNode, childStyles[i]);
        
        // 自動サイズの列/行の場合はサイズを更新
        if (columns.items[columnIndex].type == .Auto) {
            columns.items[columnIndex].value = @max(columns.items[columnIndex].value, childSize.width);
        }
        
        if (rows.items[rowIndex].type == .Auto) {
            rows.items[rowIndex].value = @max(rows.items[rowIndex].value, childSize.height);
        }
    }
    
    // パス2: 固定サイズとautoサイズを計算し、残りのスペースをフラクション間で分配
    var totalFixedColumnWidth: f32 = 0;
    var totalFixedRowHeight: f32 = 0;
    var totalColumnFr: f32 = 0;
    var totalRowFr: f32 = 0;
    
    for (columns.items) |column| {
        switch (column.type) {
            .Fixed, .Auto, .MinContent, .MaxContent => {
                totalFixedColumnWidth += column.value;
            },
            .Fraction => {
                totalColumnFr += column.value;
            },
        }
    }
    
    for (rows.items) |row| {
        switch (row.type) {
            .Fixed, .Auto, .MinContent, .MaxContent => {
                totalFixedRowHeight += row.value;
            },
            .Fraction => {
                totalRowFr += row.value;
            },
        }
    }
    
    // 列間のギャップを計算
    const totalColumnGap = columnGap * @intToFloat(f32, columnCount - 1);
    const totalRowGap = rowGap * @intToFloat(f32, rowCount - 1);
    
    // フラクション単位のサイズを計算
    const availableColumnWidth = @max(0, containerWidth - totalFixedColumnWidth - totalColumnGap);
    const availableRowHeight = @max(0, containerHeight - totalFixedRowHeight - totalRowGap);
    
    const columnFrValue = if (totalColumnFr > 0) availableColumnWidth / totalColumnFr else 0;
    const rowFrValue = if (totalRowFr > 0) availableRowHeight / totalRowFr else 0;
    
    // 最終的な列と行のサイズを計算
    var columnWidths = try allocator.alloc(f32, columnCount);
    defer allocator.free(columnWidths);
    
    var rowHeights = try allocator.alloc(f32, rowCount);
    defer allocator.free(rowHeights);
    
    for (columns.items, 0..) |column, i| {
        columnWidths[i] = switch (column.type) {
            .Fixed, .Auto, .MinContent, .MaxContent => column.value,
            .Fraction => column.value * columnFrValue,
        };
    }
    
    for (rows.items, 0..) |row, i| {
        rowHeights[i] = switch (row.type) {
            .Fixed, .Auto, .MinContent, .MaxContent => row.value,
            .Fraction => row.value * rowFrValue,
        };
    }
    
    // 各子要素の位置とサイズを設定
    var columnStart: f32 = 0;
    for (childNodes, 0..) |childNode, i| {
        const columnIndex = i % columnCount;
        const rowIndex = i / columnCount;
        
        if (rowIndex >= rowCount) continue; // グリッド行数を超えた場合はスキップ
        
        // 列と行の開始位置を計算
        columnStart = 0;
        for (columnWidths[0..columnIndex]) |width| {
            columnStart += width + columnGap;
        }
        
        var rowStart: f32 = 0;
        for (rowHeights[0..rowIndex]) |height| {
            rowStart += height + rowGap;
        }
        
        // 子要素の位置とサイズを設定
        childNode.layout.x = columnStart;
        childNode.layout.y = rowStart;
        childNode.layout.width = columnWidths[columnIndex];
        childNode.layout.height = rowHeights[rowIndex];
    }
}

// インラインフォーマッティング処理
pub const TextLayout = struct {
    lines: std.ArrayList(TextLine),
    width: f32,
    height: f32,
    
    pub fn init(allocator: std.mem.Allocator) TextLayout {
        return TextLayout{
            .lines = std.ArrayList(TextLine).init(allocator),
            .width = 0,
            .height = 0,
        };
    }
    
    pub fn deinit(self: *TextLayout) void {
        for (self.lines.items) |*line| {
            line.deinit();
        }
        self.lines.deinit();
    }
};

pub const TextLine = struct {
    words: std.ArrayList(TextWord),
    width: f32,
    height: f32,
    baseline: f32,
    
    pub fn init(allocator: std.mem.Allocator) TextLine {
        return TextLine{
            .words = std.ArrayList(TextWord).init(allocator),
            .width = 0,
            .height = 0,
            .baseline = 0,
        };
    }
    
    pub fn deinit(self: *TextLine) void {
        self.words.deinit();
    }
};

pub const TextWord = struct {
    text: []const u8,
    width: f32,
    node: *dom.Node,
    style: css.ComputedStyle,
};

pub fn layoutInlineFormattingContext(node: *dom.Node, style: css.ComputedStyle, childNodes: []const *dom.Node, childStyles: []const css.ComputedStyle, allocator: std.mem.Allocator) !void {
    // インラインフォーマッティングコンテキストのコンテナサイズ
    const containerWidth = node.layout.width;
    const containerHeight = node.layout.height;
    
    // テキストレイアウト情報の初期化
    var textLayout = TextLayout.init(allocator);
    defer textLayout.deinit();
    
    // 現在の行を初期化
    var currentLine = TextLine.init(allocator);
    var currentX: f32 = 0;
    var currentLineHeight: f32 = 0;
    var currentLineBaseline: f32 = 0;
    
    // フォントサイズとライン高さの計算ヘルパー
    fn getLineHeight(style: css.ComputedStyle) !f32 {
        if (style.getPropertyValueByName("line-height")) |lineHeightValue| {
            return try parseLengthValue(lineHeightValue, 0);
        } else {
            // デフォルトのライン高さはフォントサイズの1.2倍
            const fontSize = getFontSize(style);
            return fontSize * 1.2;
        }
    }
    
    fn getFontSize(style: css.ComputedStyle) f32 {
        if (style.getPropertyValueByName("font-size")) |fontSizeValue| {
            return parseLengthValue(fontSizeValue, 0) catch 16; // デフォルト16px
        } else {
            return 16; // デフォルト16px
        }
    }
    
    // テキストの折り返しとライン構築
    for (childNodes) |childNode, i| {
        const childStyle = childStyles[i];
        if (childNode.nodeType == dom.NodeType.Text) {
            // テキストノードの処理
            const text = childNode.textContent();
            
            // 単語に分割（簡略化：スペースで分割）
            var wordIter = std.mem.split(u8, text, " ");
            while (wordIter.next()) |word| {
                if (word.len == 0) continue;
                
                // 単語の幅を計算（簡略化：1文字あたり固定幅）
                const fontSize = getFontSize(childStyle);
                const wordWidth = @intToFloat(f32, word.len) * fontSize * 0.6;
                
                // 行に収まらない場合は新しい行を開始
                if (currentX + wordWidth > containerWidth and currentX > 0) {
                    // 現在の行を確定
                    currentLine.width = currentX;
                    currentLine.height = currentLineHeight;
                    currentLine.baseline = currentLineBaseline;
                    try textLayout.lines.append(currentLine);
                    
                    // 新しい行を初期化
                    currentLine = TextLine.init(allocator);
                    currentX = 0;
                    currentLineHeight = 0;
                    currentLineBaseline = 0;
                }
                
                // 単語を現在の行に追加
                const textWord = TextWord{
                    .text = word,
                    .width = wordWidth,
                    .node = childNode,
                    .style = childStyle,
                };
                
                try currentLine.words.append(textWord);
                currentX += wordWidth;
                
                // スペースを追加（最後の単語以外）
                if (!std.mem.eql(u8, word, wordIter.rest())) {
                    currentX += fontSize * 0.3; // スペースの幅
                }
                
                // 行の高さとベースラインを更新
                const lineHeight = getLineHeight(childStyle);
                currentLineHeight = @max(currentLineHeight, lineHeight);
                currentLineBaseline = @max(currentLineBaseline, fontSize * 0.8);
            }
        } else {
            // インラインエレメントの処理（単純化）
            const elementWidth = calculateNodeSize(childNode, childStyle).width;
            
            // 行に収まらない場合は新しい行を開始
            if (currentX + elementWidth > containerWidth and currentX > 0) {
                // 現在の行を確定
                currentLine.width = currentX;
                currentLine.height = currentLineHeight;
                currentLine.baseline = currentLineBaseline;
                try textLayout.lines.append(currentLine);
                
                // 新しい行を初期化
                currentLine = TextLine.init(allocator);
                currentX = 0;
                currentLineHeight = 0;
                currentLineBaseline = 0;
            }
            
            // インラインエレメントを位置設定
            childNode.layout.x = currentX;
            
            // 行の高さとベースラインを更新
            const lineHeight = getLineHeight(childStyle);
            currentLineHeight = @max(currentLineHeight, lineHeight);
            currentLineBaseline = @max(currentLineBaseline, lineHeight * 0.8);
            
            currentX += elementWidth;
        }
    }
    
    // 最後の行を追加
    if (currentLine.words.items.len > 0) {
        currentLine.width = currentX;
        currentLine.height = currentLineHeight;
        currentLine.baseline = currentLineBaseline;
        try textLayout.lines.append(currentLine);
    }
    
    // 全体の高さを計算
    var totalHeight: f32 = 0;
    for (textLayout.lines.items) |line| {
        totalHeight += line.height;
    }
    
    // インラインボックスの位置を設定
    var currentY: f32 = 0;
    for (textLayout.lines.items) |line| {
        currentX = 0;
        
        for (line.words.items) |word| {
            // テキストノードの位置を設定（実際にはテキストノードは描画専用で位置はない）
            if (word.node.nodeType == dom.NodeType.Text) {
                // テキストはレンダリング時に処理するため、ここではノード位置は更新しない
            } else {
                // インラインエレメントの位置を更新
                word.node.layout.x = currentX;
                word.node.layout.y = currentY + (line.height - word.node.layout.height) / 2;
            }
            
            currentX += word.width;
        }
        
        currentY += line.height;
    }
} 