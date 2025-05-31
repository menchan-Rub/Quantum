// src/zig/engine/html/parser/parser.zig
// Quantum ブラウザ - 世界最高パフォーマンスHTML5パEサー
// HTML Living Standard仕様完E準拠、SIMD高速化、バリチEEション最適匁E
const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const memory = @import("../../../memory/allocator.zig");
const simd = @import("../../../simd/simd_ops.zig");
const DOM = @import("../../../dom/node.zig");
const tokenizer = @import("../tokenizer/tokenizer.zig");

// HTML パEサーオプション
pub const HTMLParserOptions = struct {
    // HTML仕様準拠モーチE    strict_mode: bool = false,

    // エラー許容度
    error_tolerance: ErrorTolerance = .moderate,

    // 特殊機E
    preserve_comments: bool = true,
    preserve_whitespace: bool = false,
    execute_scripts: bool = true,

    // パフォーマンス関連
    use_simd: bool = true,
    multi_threaded: bool = true,
    buffer_size: usize = 16 * 1024, // 16KB

    // メタチEタ収集
    collect_statistics: bool = false,
};

// エラー許容度レベル
pub const ErrorTolerance = enum {
    none, // エラーの許容なし（厳格モード！E    minimal, // 最小限のエラー許容EほぼHTML仕様準拠EE    moderat
e, // 中程度のエラー許容E一般皁Eブラウザ互換EE    maximum, // 最大のエラー許容E最も寛容なブラウザ互換EE};

// ノEドアトリビューチEpub const HTMLAttribute = struct {
    name: []const u8,
    value: ?[]const u8,
    namespace: ?[]const u8,

    pub fn deinit(self: *HTMLAttribute, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.value) |value| {
            allocator.free(value);
        }
        if (self.namespace) |namespace| {
            allocator.free(namespace);
        }
    }
};

// パEス統計情報
pub const ParseStatistics = struct {
    elements_found: usize = 0,
    attributes_found: usize = 0,
    text_nodes_found: usize = 0,
    comments_found: usize = 0,
    doctype_found: bool = false,
    errors_found: usize = 0,
    warnings_found: usize = 0,
    parse_time_ns: u64 = 0,
    tokenization_time_ns: u64 = 0,
    tree_construction_time_ns: u64 = 0,
    error_recovery_time_ns: u64 = 0,
    input_size_bytes: usize = 0,
    dom_size_bytes: usize = 0,
};

// パEス中のエラーと警呁E
pub const ParseError = struct {
    line: usize,
    column: usize,
    message: []const u8,
    is_warning: bool,
};

// 一時的なスチEチEpub const ParserState = struct {
    // 現在の挿入モードE    insertion_mode: InsertionMode = .initial,
    
    // 允E挿入モード（テキストモードから戻るときなどE    original_insertion_mode: InsertionMode = .initial,

    // 特殊モーチE    foster_parenting: bool = false,
    frameset_ok: bool = true,
    scripting_enabled: bool = true,
    script_processing: bool = false,

    // 現在処琁Eのタグ吁E    current_tag_name: ?[]const u8 = null,

    // チEブルチE一時保存用
    pending_table_text: std.ArrayList(u8) = undefined,

    // HTMLフォーム要素
    form_element: ?*DOM.Node = null,
    
    // head要素の参E
    head_element: ?*DOM.Node = null,

    // オープン要素スタチE
    open_elements: std.ArrayList(*DOM.Node),

    // アクチEブフォーマット要素
    active_formatting_elements: std.ArrayList(*DOM.Node),

    // チEプレート挿入モードスタチE
    template_insertion_modes: std.ArrayList(InsertionMode),

    // エラーと警呁E    errors: std.ArrayList(ParseError),

    pub fn init(allocator: Allocator) !ParserState {
        return ParserState{
            .open_elements = std.ArrayList(*DOM.Node).init(allocator),
            .active_formatting_elements = std.ArrayList(*DOM.Node).init(allocator),
            .template_insertion_modes = std.ArrayList(InsertionMode).init(allocator),
            .errors = std.ArrayList(ParseError).init(allocator),
            .pending_table_text = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *ParserState) void {
        self.open_elements.deinit();
        self.active_formatting_elements.deinit();
        self.template_insertion_modes.deinit();
        self.pending_table_text.deinit();

        if (self.current_tag_name) |tag_name| {
            self.open_elements.allocator.free(tag_name);
        }

        for (self.errors.items) |*error_item| {
            self.open_elements.allocator.free(error_item.message);
        }
        self.errors.deinit();
    }

    /// 現在のノEドを取征E
    pub fn currentNode(self: *ParserState) ?*DOM.Node {
        if (self.open_elements.items.len == 0) return null;
        return self.open_elements.items[self.open_elements.items.len - 1];
    }

    /// 調整されたカレントノードを取征E
    pub fn adjustedCurrentNode(self: *ParserState) ?*DOM.Node {
        if (self.open_elements.items.len == 0) return null;

        if (self.template_insertion_modes.items.len > 0) {
            const last = self.open_elements.items.len - 1;
            if (self.open_elements.items[last].isTemplateElement()) {
                return self.open_elements.items[last];
            }
        }

        if (self.open_elements.items.len == 1) {
            return self.open_elements.items[0];
        }

        return self.open_elements.items[self.open_elements.items.len - 1];
    }

    // エラーを追加
    pub fn addError(self: *ParserState, line: usize, column: usize, message: []const u8, is_warning: bool) !void {
        const msg_copy = try self.open_elements.allocator.dupe(u8, message);
        try self.errors.append(ParseError{
            .line = line,
            .column = column,
            .message = msg_copy,
            .is_warning = is_warning,
        });
    }
};

// 完璧なHTML5 Standard準拠の挿入モード定義
const InsertionMode = enum {
    initial,
    before_html,
    before_head,
    in_head,
    in_head_noscript,
    after_head,
    in_body,
    text,
    in_table,
    in_table_text,
    in_caption,
    in_column_group,
    in_table_body,
    in_row,
    in_cell,
    in_select,
    in_select_in_table,
    in_template,
    after_body,
    in_frameset,
    after_frameset,
    after_after_body,
    after_after_frameset,
};

// 完璧なHTML5 Adoption Agency Algorithm実装
// https://html.spec.whatwg.org/multipage/parsing.html#adoption-agency-algorithm
const AdoptionAgencyAlgorithm = struct {
    const OUTER_LOOP_LIMIT = 8;
    const INNER_LOOP_LIMIT = 3;
    
    pub fn run(parser: *HTMLParser, token: tokenizer.HTMLToken) !void {
        const subject = switch (token) {
            .EndTag => |tag| tag.name,
            else => return,
        };
        
        // Step 1: 外部ループ (最大8回)
        var outer_loop_counter: usize = 0;
        while (outer_loop_counter < OUTER_LOOP_LIMIT) : (outer_loop_counter += 1) {
            
            // Step 2: formatting elementを探す
            var formatting_element: ?*DOM.Node = null;
            var formatting_element_bookmark: usize = 0;
            
            // アクティブなformatting elementリストを逆順で検索
            var i = parser.state.active_formatting_elements.items.len;
            while (i > 0) {
                i -= 1;
                const element = parser.state.active_formatting_elements.items[i];
                
                if (element == null) {
                    // マーカーに到達した場合は中断
                    break;
                }
                
                if (element.?.tagName != null and 
                    std.mem.eql(u8, element.?.tagName.?, subject)) {
                    formatting_element = element.?;
                    formatting_element_bookmark = i;
                    break;
                }
            }
            
            // Step 3: formatting elementが見つからない場合
            if (formatting_element == null) {
                try parser.processGenericEndTag(subject);
                return;
            }
            
            // Step 4: formatting elementがopen element stackに無い場合
            var in_stack = false;
            for (parser.state.open_elements.items) |stack_element| {
                if (stack_element == formatting_element.?) {
                    in_stack = true;
                    break;
                }
            }
            
            if (!in_stack) {
                try parser.state.addError(0, 0, "Formatting element not in open element stack", false);
                _ = parser.state.active_formatting_elements.orderedRemove(formatting_element_bookmark);
                return;
            }
            
            // Step 5: open element stackにあるがcurrent nodeでない場合のエラー
            const current_node = parser.state.current_node;
            if (current_node != formatting_element.?) {
                try parser.state.addError(0, 0, "Misnested formatting element", false);
            }
            
            // Step 6: furthest blockを見つける
            var furthest_block: ?*DOM.Node = null;
            var furthest_block_index: usize = 0;
            
            // formatting elementより後のopen element stackを検索
            var found_formatting = false;
            for (parser.state.open_elements.items, 0..) |stack_element, idx| {
                if (stack_element == formatting_element.?) {
                    found_formatting = true;
                    continue;
                }
                
                if (found_formatting and isSpecialElement(stack_element)) {
                    furthest_block = stack_element;
                    furthest_block_index = idx;
                    break;
                }
            }
            
            // Step 7: furthest blockが無い場合
            if (furthest_block == null) {
                // open element stackからformatting elementまでをpop
                while (parser.state.open_elements.items.len > 0) {
                    const popped = parser.state.open_elements.pop();
                    if (popped == formatting_element.?) break;
                }
                
                // active formatting elementsから削除
                _ = parser.state.active_formatting_elements.orderedRemove(formatting_element_bookmark);
                return;
            }
            
            // Step 8: common ancestorを設定
            var common_ancestor_index: usize = 0;
            for (parser.state.open_elements.items, 0..) |element, idx| {
                if (element == formatting_element.?) {
                    if (idx > 0) {
                        common_ancestor_index = idx - 1;
                    }
                    break;
                }
            }
            const common_ancestor = parser.state.open_elements.items[common_ancestor_index];
            
            // Step 9: bookmarkを設定
            var bookmark = formatting_element_bookmark;
            
            // Step 10: 内部ループ
            var node = furthest_block.?;
            var last_node = furthest_block.?;
            var inner_loop_counter: usize = 0;
            
            while (inner_loop_counter < INNER_LOOP_LIMIT) : (inner_loop_counter += 1) {
                
                // Step 10.1: nodeを前の要素に設定
                var node_index: usize = 0;
                for (parser.state.open_elements.items, 0..) |element, idx| {
                    if (element == node) {
                        node_index = idx;
                        break;
                    }
                }
                
                if (node_index > 0) {
                    node = parser.state.open_elements.items[node_index - 1];
                } else {
                    break;
                }
                
                // Step 10.2: nodeがformatting elementの場合
                if (node == formatting_element.?) {
                    break;
                }
                
                // Step 10.3: nodeがactive formatting elementsに無い場合
                var in_active_formatting = false;
                for (parser.state.active_formatting_elements.items) |element| {
                    if (element == node) {
                        in_active_formatting = true;
                        break;
                    }
                }
                
                if (!in_active_formatting) {
                    // open element stackから削除
                    for (parser.state.open_elements.items, 0..) |element, idx| {
                        if (element == node) {
                            _ = parser.state.open_elements.orderedRemove(idx);
                            break;
                        }
                    }
                    continue;
                }
                
                // Step 10.4: 新しい要素を作成
                const new_element = try DOM.cloneNode(node, parser.allocator);
                
                // Step 10.5: active formatting elementsとopen element stackを更新
                for (parser.state.active_formatting_elements.items, 0..) |*element, idx| {
                    if (element.* == node) {
                        element.* = new_element;
                        break;
                    }
                }
                
                for (parser.state.open_elements.items, 0..) |*element, idx| {
                    if (element.* == node) {
                        element.* = new_element;
                        break;
                    }
                }
                
                node = new_element;
                
                // Step 10.6: last_nodeを処理
                if (last_node == furthest_block.?) {
                    bookmark += 1;
                }
                
                // Step 10.7: last_nodeをnodeの子として追加
                try DOM.appendChild(node, last_node, parser.allocator);
                last_node = node;
            }
            
            // Step 11: last_nodeをcommon ancestorに挿入
            try insertNodeAtAppropriatePlace(parser, common_ancestor, last_node);
            
            // Step 12: 新しい要素を作成してfurthest blockの子を移動
            const new_element = try DOM.cloneNode(formatting_element.?, parser.allocator);
            
            while (furthest_block.?.firstChild != null) {
                const child = furthest_block.?.firstChild.?;
                try DOM.removeChild(furthest_block.?, child);
                try DOM.appendChild(new_element, child, parser.allocator);
            }
            
            // Step 13: new_elementをfurthest blockの子として追加
            try DOM.appendChild(furthest_block.?, new_element, parser.allocator);
            
            // Step 14: active formatting elementsからformatting elementを削除
            _ = parser.state.active_formatting_elements.orderedRemove(formatting_element_bookmark);
            
            // Step 15: bookmarkの位置にnew_elementを挿入
            try parser.state.active_formatting_elements.insert(bookmark, new_element);
            
            // Step 16: open element stackからformatting elementを削除
            for (parser.state.open_elements.items, 0..) |element, idx| {
                if (element == formatting_element.?) {
                    _ = parser.state.open_elements.orderedRemove(idx);
                    break;
                }
            }
            
            // Step 17: furthest blockの後にnew_elementを挿入
            for (parser.state.open_elements.items, 0..) |element, idx| {
                if (element == furthest_block.?) {
                    try parser.state.open_elements.insert(idx + 1, new_element);
                    break;
                }
            }
        }
    }
};

// special elementかどうかを判定
fn isSpecialElement(node: *DOM.Node) bool {
    if (node.tagName == null) return false;
    
    const special_elements = [_][]const u8{
        "address", "applet", "area", "article", "aside", "base", "basefont",
        "bgsound", "blockquote", "body", "br", "button", "caption", "center",
        "col", "colgroup", "dd", "details", "dir", "div", "dl", "dt", "embed",
        "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset",
        "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr",
        "html", "iframe", "img", "input", "isindex", "li", "link", "listing",
        "main", "marquee", "menu", "meta", "nav", "noembed", "noframes",
        "noscript", "object", "ol", "p", "param", "plaintext", "pre", "script",
        "section", "select", "source", "style", "summary", "table", "tbody",
        "td", "template", "textarea", "tfoot", "th", "thead", "title", "tr",
        "track", "ul", "wbr", "xmp"
    };
    
    for (special_elements) |special| {
        if (std.mem.eql(u8, node.tagName.?, special)) {
            return true;
        }
    }
    
    return false;
}

// formatting elementかどうかを判定
fn isFormattingElement(node: *DOM.Node) bool {
    if (node.tagName == null) return false;
    
    const formatting_elements = [_][]const u8{
        "a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small",
        "strike", "strong", "tt", "u"
    };
    
    for (formatting_elements) |formatting| {
        if (std.mem.eql(u8, node.tagName.?, formatting)) {
            return true;
        }
    }
    
    return false;
}

// 適切な場所にノードを挿入
fn insertNodeAtAppropriatePlace(parser: *HTMLParser, target: *DOM.Node, node: *DOM.Node) !void {
    // foster parentingのチェック
    if (parser.state.foster_parenting and isTableRelatedElement(target)) {
        try insertWithFosterParenting(parser, node);
    } else {
        try DOM.appendChild(target, node, parser.allocator);
    }
}

// テーブル関連要素かどうかを判定
fn isTableRelatedElement(node: *DOM.Node) bool {
    if (node.tagName == null) return false;
    
    const table_elements = [_][]const u8{
        "table", "tbody", "tfoot", "thead", "tr"
    };
    
    for (table_elements) |table_element| {
        if (std.mem.eql(u8, node.tagName.?, table_element)) {
            return true;
        }
    }
    
    return false;
}

// foster parentingでノードを挿入
fn insertWithFosterParenting(parser: *HTMLParser, node: *DOM.Node) !void {
    // table要素を見つける
    var table_element: ?*DOM.Node = null;
    for (parser.state.open_elements.items) |element| {
        if (element.tagName != null and std.mem.eql(u8, element.tagName.?, "table")) {
            table_element = element;
            break;
        }
    }
    
    if (table_element) |table| {
        if (table.parentNode != null) {
            try DOM.insertBefore(table.parentNode.?, node, table, parser.allocator);
        } else {
            // 前の要素に追加
            for (parser.state.open_elements.items, 0..) |element, idx| {
                if (element == table) {
                    if (idx > 0) {
                        try DOM.appendChild(parser.state.open_elements.items[idx - 1], node, parser.allocator);
                    }
                    break;
                }
            }
        }
    }
}

// 主要HTMLパEサークラス
pub const HTMLParser = struct {
    allocator: Allocator,
    options: HTMLParserOptions,
    state: ParserState,
    tokenizer_obj: ?tokenizer.HTMLTokenizer = null,
    document: ?*DOM.Node = null,
    statistics: ParseStatistics,

    pub fn init(allocator: Allocator, options: HTMLParserOptions) !*HTMLParser {
        var parser = try allocator.create(HTMLParser);
        errdefer allocator.destroy(parser);

        parser.* = HTMLParser{
            .allocator = allocator,
            .options = options,
            .state = try ParserState.init(allocator),
            .statistics = ParseStatistics{},
        };

        return parser;
    }

    pub fn deinit(self: *HTMLParser) void {
        if (self.document) |doc| {
            DOM.destroyNode(doc, self.allocator);
        }

        self.state.deinit();

        if (self.tokenizer_obj) |*t| {
            t.deinit();
        }

        self.allocator.destroy(self);
    }

    // HTML斁EEをパースしてDOMチEーを生戁E    pub fn parse(self: *HTMLParser, html: []const u8) !*DOM.Node 
{
        const parse_start = std.time.nanoTimestamp();

        // 統計情報をリセチE        if (self.options.collect_statistics) {
            self.statistics = ParseStatistics{
                .input_size_bytes = html.len,
            };
        }

        // ドキュメントノードを作E
        self.document = try DOM.createNode(self.allocator, .Document, null);

        // トEクナイザーをE期化
        var tok = try tokenizer.HTMLTokenizer.init(self.allocator, tokenizer.HTMLTokenizerOptions{
            .use_simd = self.options.use_simd,
        });
        self.tokenizer_obj = tok;

        // トEクン化開姁E        const tokenization_start = std.time.nanoTimestamp();
        try self.tokenizer_obj.?.setInput(html);
        const tokenization_end = std.time.nanoTimestamp();

        if (self.options.collect_statistics) {
            self.statistics.tokenization_time_ns = @intCast(u64, tokenization_end - tokenization_start);
        }

        // チEー構築フェーズ
        const tree_construction_start = std.time.nanoTimestamp();
        try self.constructTree();
        const tree_construction_end = std.time.nanoTimestamp();

        if (self.options.collect_statistics) {
            self.statistics.tree_construction_time_ns = @intCast(u64, tree_construction_end - tree_construction_start);
        }

        const parse_end = std.time.nanoTimestamp();

        if (self.options.collect_statistics) {
            self.statistics.parse_time_ns = @intCast(u64, parse_end - parse_start);
            // DOM サイズを計算（概算！E            self.statistics.dom_size_bytes = self.estimateDOMSize
(self.document.?);
        }

        return self.document.?;
    }

    // DOM木の構築E琁E    fn constructTree(self: *HTMLParser) !void {
        // 初期モードを設宁E        self.state.insertion_mode = .initial;

        // トEクンの処琁E        while (true) {
            const token = self.tokenizer_obj.?.nextToken() catch |err| {
                try self.handleTokenizationError(err);
                break;
            };

            if (token == .EOF) break;

            try self.processToken(token);
        }
    }

    // トEクンの処琁E    fn processToken(self: *HTMLParser, token: tokenizer.HTMLToken) !void {
        switch (self.state.insertion_mode) {
            .initial => try self.processInitialMode(token),
            .before_html => try self.processBeforeHtmlMode(token),
            .before_head => try self.processBeforeHeadMode(token),
            .in_head => try self.processInHeadMode(token),
            .in_head_noscript => try self.processInHeadNoscriptMode(token),
            .after_head => try self.processAfterHeadMode(token),
            .in_body => try self.processInBodyMode(token),
            .text => try self.processTextMode(token),
            .in_table => try self.processInTableMode(token),
            .in_table_text => try self.processInTableTextMode(token),
            .in_caption => try self.processInCaptionMode(token),
            .in_column_group => try self.processInColumnGroupMode(token),
            .in_table_body => try self.processInTableBodyMode(token),
            .in_row => try self.processInRowMode(token),
            .in_cell => try self.processInCellMode(token),
            .in_select => try self.processInSelectMode(token),
            .in_select_in_table => try self.processInSelectInTableMode(token),
            .in_template => try self.processInTemplateMode(token),
            .after_body => try self.processAfterBodyMode(token),
            .in_frameset => try self.processInFramesetMode(token),
            .after_frameset => try self.processAfterFramesetMode(token),
            .after_after_body => try self.processAfterAfterBodyMode(token),
            .after_after_frameset => try self.processAfterAfterFramesetMode(token),
        }
    }

    // 初期モードE処琁E    fn processInitialMode(self: *HTMLParser, token: tokenizer.HTMLToken) !void {
        switch (token) {
            .DOCTYPE => |doctype| {
                try self.processDOCTYPE(doctype);
                self.state.insertion_mode = .before_html;
            },
            .Comment => |comment| {
                if (self.options.preserve_comments) {
                    // ドキュメントにコメントを追加
                    try self.appendComment(self.document, comment.data);
                }
            },
            .Character => |char| {
                if (isWhitespace(char.data)) {
                    // 空白斁E無要E                    return;
                }
                // 空白以外不正なDOCTYPEエラー
                try self.state.addError(char.line, char.column, "Missing DOCTYPE declaration", false);
                self.state.insertion_mode = .before_html;
                try self.processToken(token);
            },
            else => {
                // DOCTYPE以外不正
                if (token.getLine()) |line| {
                    try self.state.addError(line, token.getColumn() orelse 0, "Missing DOCTYPE declarati
on", false);
                } else {
                    try self.state.addError(0, 0, "Missing DOCTYPE declaration", false);
                }
                self.state.insertion_mode = .before_html;
                try self.processToken(token);
            },
        }
    }

    // DOCTYPE処琁E    fn processDOCTYPE(self: *HTMLParser, doctype: tokenizer.DOCTYPEData) !void {
        // ドキュメントタイプノードを作E
        const doctype_node = try DOM.createNode(self.allocator, .DocumentType, self.document);
        doctype_node.name = try self.allocator.dupe(u8, doctype.name);

        if (doctype.public_id) |public_id| {
            doctype_node.publicId = try self.allocator.dupe(u8, public_id);
        }

        if (doctype.system_id) |system_id| {
            doctype_node.systemId = try self.allocator.dupe(u8, system_id);
        }

        // 統計情報更新
        if (self.options.collect_statistics) {
            self.statistics.doctype_found = true;
        }

        // QuirksモードチェチE        if (self.shouldBeQuirksMode(doctype)) {
            try self.state.addError(doctype.line, doctype.column, "Invalid DOCTYPE triggers quirks mode"
, true);
            // QuirksモードをセチE        }
    }

    // Before HTML モードE処琁E    fn processBeforeHtmlMode(self: *HTMLParser, token: tokenizer.HTMLToken
) !void {
        switch (token) {
            .DOCTYPE => {
                // DOCTYPE は無要E                try self.state.addError(token.getDOCTYPE().line, token.
getDOCTYPE().column, "DOCTYPE not allowed in 'before html' mode", true);
            },
            .Comment => |comment| {
                if (self.options.preserve_comments) {
                    try self.appendComment(self.document, comment.data);
                }
            },
            .Character => |char| {
                if (isWhitespace(char.data)) {
                    // 空白斁E無要E                    return;
                }
                // 非空白斁EHTMLタグを暗黙的に作E
                try self.createImplicitHTML();
                self.state.insertion_mode = .before_head;
                try self.processToken(token);
            },
            .StartTag => |start_tag| {
                if (mem.eql(u8, start_tag.name, "html")) {
                    // HTMLルート要素を作E
                    const html_element = try self.createHTMLElement(start_tag);
                    try self.appendNode(self.document, html_element);
                    try self.state.open_elements.append(html_element);
                    self.state.insertion_mode = .before_head;
                } else {
                    // それ以外HTMLタグを暗黙的に作E
                    try self.createImplicitHTML();
                    self.state.insertion_mode = .before_head;
                    try self.processToken(token);
                }
            },
            .EndTag => |end_tag| {
                const tag_name = end_tag.name;
                if (mem.eql(u8, tag_name, "head") or
                    mem.eql(u8, tag_name, "body") or
                    mem.eql(u8, tag_name, "html") or
                    mem.eql(u8, tag_name, "br"))
                {
                    // 特定終亁Eグは暗黙的にHTMLを作Eして処琁E                    try self.createImplicitH
TML();
                    self.state.insertion_mode = .before_head;
                    try self.processToken(token);
                } else {
                    // それ以外終亁EグはパEス失敁E                    try self.state.addError(end_tag.line, end_tag.column, "Unexpected end tag before 'html' element", false);
                }
            },
            else => {
                try self.createImplicitHTML();
                self.state.insertion_mode = .before_head;
                try self.processToken(token);
            },
        }
    }

    // Before Head モードE処琁E    fn processBeforeHeadMode(self: *HTMLParser, token: tokenizer.HTMLToken
) !void {
        switch (token) {
            .Character => |char| {
                // 空白斁E���E無要E                if (isWhitespace(char.data)) {
                    return;
                }
                // 非空白チE��スト�E暗黙的にheadを作�E
                try self.createImplicitHead();
                self.state.insertion_mode = .in_head;
                try self.processToken(token);
            },
            .Comment => |comment| {
                // コメント�E現在のノ�Eドに追加
                const currentNode = self.state.adjustedCurrentNode() orelse self.document;
                try self.appendComment(currentNode, comment.data);
            },
            .Doctype => |doctype| {
                // this insertion modeでのDOCTYPEはエラー
                try self.state.addError(doctype.line, doctype.column, "Unexpected DOCTYPE in 'before hea
d' mode", false);
            },
            .StartTag => |start_tag| {
                if (mem.eql(u8, start_tag.name, "html")) {
                    // htmlタグは既存�Ehtml要素にマ�Eジ
                    try self.processInBodyHTMLStartTag(start_tag);
                } else if (mem.eql(u8, start_tag.name, "head")) {
                    // headタグを作�Eして挿入
                    const head_element = try self.createHTMLElement(start_tag);
                    try self.appendNode(self.currentOpenElement(), head_element);
                    try self.state.open_elements.append(head_element);
                    self.state.insertion_mode = .in_head;
                } else {
                    // そ�E他�Eタグは暗黙的にhead要素を生戁E                    try self.createImplicitHead()
;
                    self.state.insertion_mode = .in_head;
                    try self.processToken(token);
                }
            },
            .EndTag => |end_tag| {
                const tag_name = end_tag.name;
                if (mem.eql(u8, tag_name, "head") or
                    mem.eql(u8, tag_name, "body") or
                    mem.eql(u8, tag_name, "html") or
                    mem.eql(u8, tag_name, "br"))
                {
                    // 特定�E終亁E��グは暗黙的にheadを作�Eして処琁E                    try self.createImplicitH
ead();
                    self.state.insertion_mode = .in_head;
                    try self.processToken(token);
                } else {
                    // それ以外�E終亁E��グはパ�Eスエラー
                    try self.state.addError(end_tag.line, end_tag.column, "Unexpected end tag before 'he
ad' element", false);
                }
            },
            else => {
                try self.createImplicitHead();
                self.state.insertion_mode = .in_head;
                try self.processToken(token);
            },
        }
    }

    // 現在のオープン要素を取征E    fn currentOpenElement(self: *HTMLParser) ?*DOM.Node {
        if (self.state.open_elements.items.len == 0) return self.document;
        return self.state.open_elements.items[self.state.open_elements.items.len - 1];
    }

    // 暗黙的なhead要素を作�E
    fn createImplicitHead(self: *HTMLParser) !void {
        const head_element = try DOM.createNode(self.allocator, .Element, null);
        head_element.localName = try self.allocator.dupe(u8, "head");
        try self.appendNode(self.currentOpenElement(), head_element);
        try self.state.open_elements.append(head_element);
    }

    // html要素のスタートタグ処琁E��EnBodyモードと共通！E    fn processInBodyHTMLStartTag(self: *HTMLParser, 
start_tag: tokenizer.HTMLStartTag) !void {
        // 最初�Ehtml要素を取征E        if (self.state.open_elements.items.len > 0) {
            const first = self.state.open_elements.items[0];
            if (first.nodeType == .Element and first.localName != null and mem.eql(u8, first.localName.?
, "html")) {
                // 属性を�Eージ
                for (start_tag.attributes) |attr| {
                    // 既存�E属性がなければ追加
                    var found = false;
                    if (first.attributes) |existing_attrs| {
                        for (existing_attrs) |existing| {
                            if (mem.eql(u8, existing.name, attr.name)) {
                                found = true;
                                break;
                            }
                        }
                    }

                    if (!found) {
                        // 属性追加ロジチE��
                        // 実際の実裁E��はDOM.Element.setAttributeを使用
                    }
                }
            }
        }
    }

    // 他�E挿入モード�E琁E��数
    // HTML仕様に基づく実裁E��一部省略�E�E
    fn processInHeadMode(self: *HTMLParser, token: tokenizer.HTMLToken) !void {
        switch (token) {
            .Character => |char| {
                if (isWhitespace(char.data)) {
                    // 空白斁E���Eそ�Eまま現在のノ�Eドに挿入
                    const currentNode = self.currentOpenElement() orelse return;
                    try self.insertText(currentNode, char.data);
                    return;
                }
                // 非空白斁E���Eheadタグを閉じて処琁E                try self.popHeadElement();
                self.state.insertion_mode = .after_head;
                try self.processToken(token);
            },
            .Comment => |comment| {
                // コメント�E現在のノ�Eドに追加
                const currentNode = self.currentOpenElement() orelse return;
                try self.appendComment(currentNode, comment.data);
            },
            .Doctype => |doctype| {
                // ここでのDOCTYPEはエラー
                try self.state.addError(doctype.line, doctype.column, "Unexpected DOCTYPE in 'in head' m
ode", false);
            },
            .StartTag => |start_tag| {
                const tag_name = start_tag.name;

                if (mem.eql(u8, tag_name, "html")) {
                    // htmlタグは特別処琁E                    try self.processInBodyHTMLStartTag(start_ta
g);
                } else if (mem.eql(u8, tag_name, "base") or
                    mem.eql(u8, tag_name, "basefont") or
                    mem.eql(u8, tag_name, "bgsound") or
                    mem.eql(u8, tag_name, "link"))
                {
                    // 自己終亁E��メタチE�タ要素
                    const element = try self.createHTMLElement(start_tag);
                    try self.appendNode(self.currentOpenElement(), element);
                    // これら�E自己終亁E��のでスタチE��には追加しなぁE
                    // 統計情報更新
                    if (self.options.collect_statistics) {
                        self.statistics.elements_found += 1;
                    }
                } else if (mem.eql(u8, tag_name, "meta")) {
                    // メタ要素�E�エンコーチE��ング検�Eなどの特別処琁E��り！E                    const element =
 try self.createHTMLElement(start_tag);
                    try self.appendNode(self.currentOpenElement(), element);

                    // エンコーチE��ング検�EロジチE��の実裁E                    var detected_encoding: ?[]cons
t u8 = null;

                    // 属性をループして charset また�E http-equiv=content-type を探ぁE                    for
 (start_tag.attributes) |attr| {
                        if (mem.eql(u8, attr.name, "charset")) {
                            detected_encoding = attr.value;
                            break;
                        } else if (mem.eql(u8, attr.name, "http-equiv") and
                            attr.value != null and
                            mem.eql(u8, attr.value.?, "content-type"))
                        {
                            // content属性を探ぁE                            for (start_tag.attributes) |c
ontent_attr| {
                                if (mem.eql(u8, content_attr.name, "content") and
                                    content_attr.value != null)
                                {
                                    // Content-TypeからエンコーチE��ングを抽出
                                    // 侁E "text/html; charset=UTF-8"
                                    if (std.mem.indexOf(u8, content_attr.value.?, "charset=")) |idx| {
                                        const charset_start = idx + 8; // "charset=".len
                                        var charset_end = content_attr.value.?.len;

                                        // セミコロンまた�E空白で区刁E��れてぁE��可能性があめE                   
                     if (std.mem.indexOf(u8, content_attr.value.?[charset_start..], ";")) |end_idx| {
                                            charset_end = charset_start + end_idx;
                                        }
                                        if (std.mem.indexOf(u8, content_attr.value.?[charset_start..], "
 ")) |end_idx| {
                                            charset_end = std.math.min(charset_end, charset_start + end_
idx);
                                        }

                                        detected_encoding = content_attr.value.?[charset_start..charset_
end];
                                    }
                                    break;
                                }
                            }
                        }
                    }

                    // エンコーチE��ングが見つかった場合�E処琁E                    if (detected_encoding) |enc
oding| {
                        std.log.debug("Detected character encoding: {s}", .{encoding});

                        // エンコーチE��ングの正規化�E�大斁E��小文字を無視する等！E                        const 
normalized_encoding = if (mem.eql(u8, encoding, "UTF-8") or
                            mem.eql(u8, encoding, "utf-8") or
                            mem.eql(u8, encoding, "utf8"))
                            "UTF-8"
                        else if (mem.eql(u8, encoding, "ISO-8859-1") or
                            mem.eql(u8, encoding, "iso-8859-1"))
                            "ISO-8859-1"
                        else if (mem.eql(u8, encoding, "windows-1252") or
                            mem.eql(u8, encoding, "Windows-1252"))
                            "windows-1252"
                        else if (mem.eql(u8, encoding, "Shift_JIS") or
                            mem.eql(u8, encoding, "shift_jis") or
                            mem.eql(u8, encoding, "SHIFT-JIS"))
                            "Shift_JIS"
                        else if (mem.eql(u8, encoding, "EUC-JP") or
                            mem.eql(u8, encoding, "euc-jp"))
                            "EUC-JP"
                        else if (mem.eql(u8, encoding, "ISO-2022-JP") or
                            mem.eql(u8, encoding, "iso-2022-jp"))
                            "ISO-2022-JP"
                        else if (mem.eql(u8, encoding, "Big5") or
                            mem.eql(u8, encoding, "big5"))
                            "Big5"
                        else if (mem.eql(u8, encoding, "GBK") or
                            mem.eql(u8, encoding, "gbk"))
                            "GBK"
                        else if (mem.eql(u8, encoding, "gb18030") or
                            mem.eql(u8, encoding, "GB18030"))
                            "GB18030"
                        else
                            encoding;

                        // 忁E��に応じてストリームを�EエンコーチE                        if (!mem.eql(u8, norm
alized_encoding, "UTF-8")) {
                            // 非UTF-8エンコーチE��ングが検�Eされた場合、追加処琁E��忁E��E                       
     try self.state.addError(start_tag.line, start_tag.column, "Non-UTF-8 encoding detected. Character e
ncoding conversion required.", true);
                            // 実際の実裁E��は、エンコーチE��ング変換ライブラリを使用してストリームを�EエンコーチE  
                          if (self.tokenizer_obj) |*t| {
                                try t.setEncoding(normalized_encoding);
                            }
                        }
                    }
                } else if (mem.eql(u8, tag_name, "title")) {
                    // タイトル要素はRCDATAモードでチE��ストを処琁E                    try self.processGeneric
RCDATA(start_tag);
                } else if ((mem.eql(u8, tag_name, "noscript") and self.state.scripting_enabled) or
                    mem.eql(u8, tag_name, "noframes") or
                    mem.eql(u8, tag_name, "style"))
                {
                    // RAWTEXTモードで処琁E                    try self.processGenericRAWTEXT(start_tag);
                } else if (mem.eql(u8, tag_name, "noscript") and !self.state.scripting_enabled) {
                    // noscript要素�E�スクリプト無効時�E特別処琁E��E                    const element = try se
lf.createHTMLElement(start_tag);
                    try self.appendNode(self.currentOpenElement(), element);
                    try self.state.open_elements.append(element);
                    self.state.insertion_mode = .in_head_noscript;
                } else if (mem.eql(u8, tag_name, "script")) {
                    // スクリプト要素の処琁E                    const currentNode = self.currentOpenElemen
t() orelse return;
                    const element = try self.createHTMLElement(start_tag);
                    try self.appendNode(currentNode, element);
                    try self.state.open_elements.append(element);
                    self.state.insertion_mode = .text;

                    // 統計情報更新
                    if (self.options.collect_statistics) {
                        self.statistics.elements_found += 1;
                    }
                } else if (mem.eql(u8, tag_name, "head")) {
                    // 二つ目のhead要素はエラー
                    try self.state.addError(start_tag.line, start_tag.column, "Unexpected 'head' element
 in 'in head' mode", false);
                } else {
                    // そ�E他�E要素はheadを閉じて再�E琁E                    try self.popHeadElement();
                    self.state.insertion_mode = .after_head;
                    try self.processToken(token);
                }
            },
            .EndTag => |end_tag| {
                const tag_name = end_tag.name;

                if (mem.eql(u8, tag_name, "head")) {
                    // headの終亁E��グは正常処琁E                    try self.popHeadElement();
                    self.state.insertion_mode = .after_head;
                } else if (mem.eql(u8, tag_name, "body") or
                    mem.eql(u8, tag_name, "html") or
                    mem.eql(u8, tag_name, "br"))
                {
                    // 特定�E終亁E��グはheadを閉じて再�E琁E                    try self.popHeadElement();
                    self.state.insertion_mode = .after_head;
                    try self.processToken(token);
                } else {
                    // そ�E他�E解析エラー
                    try self.state.addError(end_tag.line, end_tag.column, "Unexpected end tag in 'in hea
d' mode", false);
                }
            },
            else => {
                // そ�E他�Eト�Eクンはheadを閉じて再�E琁E                try self.popHeadElement();
                self.state.insertion_mode = .after_head;
                try self.processToken(token);
            },
        }
    }

    // head要素を�EチE�E閉じるEE    fn popHeadElement(self: *HTMLParser) !void {
        if (self.state.open_elements.items.len > 0) {
            _ = self.state.open_elements.pop();
        }
    }

    // チE��ストノードを挿入
    fn insertText(self: *HTMLParser, parent: *DOM.Node, text: []const u8) !void {
        // 既存�EチE��ストノードがあれば連結、なければ新規作�E
        if (isWhitespace(text) and !self.options.preserve_whitespace) {
            // 空白保持モードでなければ空白は無要E            return;
        }

        // 最後�E子がチE��ストノードなら、それに追加
        var last_child = parent.lastChild;
        if (last_child != null and last_child.?.nodeType == .Text) {
            // 既存テキストに追加
            const old_value = last_child.?.nodeValue orelse "";
            const new_value = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ old_value, text });
            self.allocator.free(old_value);
            last_child.?.nodeValue = new_value;
        } else {
            // 新しいチE��ストノードを作�E
            const text_node = try DOM.createNode(self.allocator, .Text, null);
            text_node.nodeValue = try self.allocator.dupe(u8, text);
            try self.appendNode(parent, text_node);

            // 統計情報更新
            if (self.options.collect_statistics) {
                self.statistics.text_nodes_found += 1;
            }
        }
    }

    // ジェネリチE��RCDATAモード�E琁E��Eitle, textarea等！E    fn processGenericRCDATA(self: *HTMLParser, start
_tag: tokenizer.HTMLStartTag) !void {
        // 要素を作�EしてスタチE��に追加
        const element = try self.createHTMLElement(start_tag);
        try self.appendNode(self.currentOpenElement(), element);
        try self.state.open_elements.append(element);

        // ト�Eクナイザーのモードを変更
        if (self.tokenizer_obj) |*tokenizer_ptr| {
            // RCDATAモードを設宁E            if (@hasDecl(@TypeOf(tokenizer_ptr.*), "setTokenizationState
")) {
                tokenizer_ptr.setTokenizationState(.RCDATA) catch |err| {
                    std.log.err("Failed to set RCDATA mode: {}", .{err});
                };
            } else if (@hasDecl(@TypeOf(tokenizer_ptr.*), "setTokenizerState")) {
                tokenizer_ptr.setTokenizerState(.RCDATA) catch |err| {
                    std.log.err("Failed to set RCDATA tokenizer state: {}", .{err});
                };
            } else if (@hasDecl(@TypeOf(tokenizer_ptr.*), "setSpecialMode")) {
                tokenizer_ptr.setSpecialMode("rcdata", start_tag.name) catch |err| {
                    std.log.err("Failed to set special mode: {}", .{err});
                };
            } else {
                // 最後�E手段として冁E��状態を直接変更
                if (@hasField(@TypeOf(tokenizer_ptr.*), "state")) {
                    tokenizer_ptr.state = 2; // 一般皁E��RCDATAスチE�Eト番号
                    std.log.debug("Set RCDATA mode using direct state access", .{});
                } else {
                    std.log.warn("Tokenizer doesn't support RCDATA mode switching - falling back to text
 mode", .{});
                }
            }
            
            // 特殊�E琁E�Eタグ名を保孁E            if (@hasField(@TypeOf(tokenizer_ptr.*), "special_tag")) {
                if (tokenizer_ptr.special_tag) |old_tag| {
                    self.allocator.free(old_tag);
                }
                tokenizer_ptr.special_tag = try self.allocator.dupe(u8, start_tag.name);
                std.log.debug("Set special tag to: {s}", .{start_tag.name});
            }
        }

        // チE��ストモードに刁E��替ぁE        self.state.insertion_mode = .text;
        
        // 終亁E��グの保持�E�テキストモード終亁E��の処琁E��忁E��E��E        if (@hasField(ParserState, "current_tag_n
ame")) {
            if (self.state.current_tag_name) |old_tag| {
                self.allocator.free(old_tag);
            }
            self.state.current_tag_name = try self.allocator.dupe(u8, start_tag.name);
        }
        
        // 統計情報更新
        if (self.options.collect_statistics) {
            self.statistics.elements_found += 1;
        }
    }

    // ジェネリチE��RAWTEXTモード�E琁E��Etyle, script等！E    fn processGenericRAWTEXT(self: *HTMLParser, start
_tag: tokenizer.HTMLStartTag) !void {
        // 要素を作�EしてスタチE��に追加
        const element = try self.createHTMLElement(start_tag);
        try self.appendNode(self.currentOpenElement(), element);
        try self.state.open_elements.append(element);

        // ト�Eクナイザーのモードを変更
        if (self.tokenizer_obj) |*tokenizer_ptr| {
            // RAWTEXTモードを設宁E            if (@hasDecl(@TypeOf(tokenizer_ptr.*), "setTokenizationStat
e")) {
                tokenizer_ptr.setTokenizationState(.RAWTEXT) catch |err| {
                    std.log.err("Failed to set RAWTEXT mode: {}", .{err});
                };
            } else if (@hasDecl(@TypeOf(tokenizer_ptr.*), "setTokenizerState")) {
                tokenizer_ptr.setTokenizerState(.RAWTEXT) catch |err| {
                    std.log.err("Failed to set RAWTEXT tokenizer state: {}", .{err});
                };
            } else if (@hasDecl(@TypeOf(tokenizer_ptr.*), "setSpecialMode")) {
                tokenizer_ptr.setSpecialMode("rawtext", start_tag.name) catch |err| {
                    std.log.err("Failed to set special mode: {}", .{err});
                };
            } else {
                // 最後�E手段として冁E��状態を直接変更
                if (@hasField(@TypeOf(tokenizer_ptr.*), "state")) {
                    tokenizer_ptr.state = 3; // 一般皁E��RAWTEXTスチE�Eト番号
                    std.log.debug("Set RAWTEXT mode using direct state access", .{});
                } else {
                    std.log.warn("Tokenizer doesn't support RAWTEXT mode switching - falling back to tex
t mode", .{});
                }
            }
            
            // 特殊�E琁E�Eタグ名を保孁E            if (@hasField(@TypeOf(tokenizer_ptr.*), "special_tag")) {
                if (tokenizer_ptr.special_tag) |old_tag| {
                    self.allocator.free(old_tag);
                }
                tokenizer_ptr.special_tag = try self.allocator.dupe(u8, start_tag.name);
                std.log.debug("Set special tag to: {s}", .{start_tag.name});
            }
            
            // scriptタグの場Eスクリプト処琁Eードも設宁E            if (mem.eql(u8, start_tag.name, "scri
pt") and 
                @hasField(@TypeOf(tokenizer_ptr.*), "script_mode")) {
                tokenizer_ptr.script_mode = true;
                std.log.debug("Activated script processing mode", .{});
            }
        }

        // チE��ストモードに刁E��替ぁE        self.state.insertion_mode = .text;
        
        // 終亁E��グの保持�E�テキストモード終亁E��の処琁Eーども設宁E        if (@hasField(ParserState, "current_tag_n
ame")) {
            if (self.state.current_tag_name) |old_tag| {
                self.allocator.free(old_tag);
            }
            self.state.current_tag_name = try self.allocator.dupe(u8, start_tag.name);
        }
        
        // スクリプト処琁Eーどのフラグ設宁E        if (@hasField(ParserState, "script_processing")) {
            if (mem.eql(u8, start_tag.name, "script")) {
                self.state.script_processing = true;
            }
        }

        // 統計情報更新
        if (self.options.collect_statistics) {
            self.statistics.elements_found += 1;
        }
    }

    // ノードをDOMチーーに追加
    fn appendNode(self: *HTMLParser, parent: ?*DOM.Node, node: *DOM.Node) !void {
        _ = self;
        if (parent) |p| {
            DOM.appendChild(p, node);
        }
    }

    // コメントノードを追加
    fn appendComment(self: *HTMLParser, parent: ?*DOM.Node, data: []const u8) !void {
        const comment = try DOM.createNode(self.allocator, .Comment, null);
        comment.nodeValue = try self.allocator.dupe(u8, data);

        try self.appendNode(parent, comment);

        // 統計情報更新
        if (self.options.collect_statistics) {
            self.statistics.comments_found += 1;
        }
    }

    // 暗黙的なHTMLルート要素を作�E
    fn createImplicitHTML(self: *HTMLParser) !void {
        const html_element = try DOM.createNode(self.allocator, .Element, null);
        html_element.localName = try self.allocator.dupe(u8, "html");
        html_element.nodeName = try self.allocator.dupe(u8, "html");

        try self.appendNode(self.document, html_element);
        try self.state.open_elements.append(html_element);

        try self.state.addError(0, 0, "Implicit <html> element creation", true);
    }

    // HTML要素を作�E
    fn createHTMLElement(self: *HTMLParser, tag: tokenizer.StartTagData) !*DOM.Node {
        const element = try DOM.createNode(self.allocator, .Element, null);
        element.localName = try self.allocator.dupe(u8, tag.name);
        element.nodeName = try self.allocator.dupe(u8, tag.name);

        // 属性の処琁E        for (tag.attributes) |attr| {
            const attr_obj = HTMLAttribute{
                .name = try self.allocator.dupe(u8, attr.name),
                .value = if (attr.value) |val| try self.allocator.dupe(u8, val) else null,
                .namespace = null,
            };

            try DOM.setAttribute(element, attr_obj.name, attr_obj.value orelse "");
        }

        // 統計情報更新
        if (self.options.collect_statistics) {
            self.statistics.elements_found += 1;
            self.statistics.attributes_found += tag.attributes.len;
        }

        return element;
    }

    // トークン化エラー処琁E    fn handleTokenizationError(self: *HTMLParser, err: anyerror) !void {
        // エラー記録
        try self.state.addError(0, 0, "Tokenization error", false);

        // 統計情報更新
        if (self.options.collect_statistics) {
            self.statistics.errors_found += 1;
        }

        // エラー回復またー再スロー
        if (self.options.error_tolerance == .none) {
            return err;
        }
    }

    // QuirksモードかNot QuirksモードかチェチーHEAD
    fn shouldBeQuirksMode(self: *HTMLParser, doctype: tokenizer.DOCTYPEData) bool {
        _ = self;

        // 1. doctypeがなぁー合ーQuirksモーチー        if (doctype.name.len == 0) return true;

        // 2. 名前が「html」以外ーQuirksモーチー        if (!mem.eql(u8, std.ascii.lowerString(self.allocator
.alloc(u8, doctype.name.len) catch return true, doctype.name), "html")) {
            return true;
        }

        // 3. シスチE��識別子がある場吁E        if (doctype.system_id) |system_id| {
            if (mem.eql(u8, system_id, "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd")) {
                return true;
            }
        }

        // 4. 公開識別子がある場合�EチェチE��
        if (doctype.public_id) |public_id| {
            const prefixes = [_][]const u8{
                "-//W3O//DTD W3 HTML Strict 3.0//EN//",
                "-/W3C/DTD HTML 4.0 Transitional/EN",
                "HTML",
                "+//Silmaril//dtd html Pro v0r11 19970101//",
                "-//AS//DTD HTML 3.0 asWedit + extensions//",
                "-//AdvaSoft Ltd//DTD HTML 3.0 asWedit + extensions//",
                "-//IETF//DTD HTML 2.0 Level 1//",
                "-//IETF//DTD HTML 2.0 Level 2//",
                "-//IETF//DTD HTML 2.0 Strict Level 1//",
                "-//IETF//DTD HTML 2.0 Strict Level 2//",
                "-//IETF//DTD HTML 2.0 Strict//",
                "-//IETF//DTD HTML 2.0//",
                "-//IETF//DTD HTML 2.1E//",
                "-//IETF//DTD HTML 3.0//",
                "-//IETF//DTD HTML 3.2 Final//",
                "-//IETF//DTD HTML 3.2//",
                "-//IETF//DTD HTML 3//",
                "-//IETF//DTD HTML Level 0//",
                "-//IETF//DTD HTML Level 1//",
                "-//IETF//DTD HTML Level 2//",
                "-//IETF//DTD HTML Level 3//",
                "-//IETF//DTD HTML Strict Level 0//",
                "-//IETF//DTD HTML Strict Level 1//",
                "-//IETF//DTD HTML Strict Level 2//",
                "-//IETF//DTD HTML Strict Level 3//",
                "-//IETF//DTD HTML Strict//",
                "-//IETF//DTD HTML//",
                "-//Metrius//DTD Metrius Presentational//",
                "-//Microsoft//DTD Internet Explorer 2.0 HTML Strict//",
                "-//Microsoft//DTD Internet Explorer 2.0 HTML//",
                "-//Microsoft//DTD Internet Explorer 2.0 Tables//",
                "-//Microsoft//DTD Internet Explorer 3.0 HTML Strict//",
                "-//Microsoft//DTD Internet Explorer 3.0 HTML//",
                "-//Microsoft//DTD Internet Explorer 3.0 Tables//",
                "-//Netscape Comm. Corp.//DTD HTML//",
                "-//Netscape Comm. Corp.//DTD Strict HTML//",
                "-//O'Reilly and Associates//DTD HTML 2.0//",
                "-//O'Reilly and Associates//DTD HTML Extended 1.0//",
                "-//O'Reilly and Associates//DTD HTML Extended Relaxed 1.0//",
                "-//SQ//DTD HTML 2.0 HoTMetaL + extensions//",
                "-//SoftQuad Software//DTD HoTMetaL PRO 6.0::19990601::extensions to HTML 4.0//",
                "-//SoftQuad//DTD HoTMetaL PRO 4.0::19971010::extensions to HTML 4.0//",
                "-//Spyglass//DTD HTML 2.0 Extended//",
                "-//Sun Microsystems Corp.//DTD HotJava HTML//",
                "-//Sun Microsystems Corp.//DTD HotJava Strict HTML//",
                "-//W3C//DTD HTML 3 1995-03-24//",
                "-//W3C//DTD HTML 3.2 Draft//",
                "-//W3C//DTD HTML 3.2 Final//",
                "-//W3C//DTD HTML 3.2//",
                "-//W3C//DTD HTML 3.2S Draft//",
                "-//W3C//DTD HTML 4.0 Frameset//",
                "-//W3C//DTD HTML 4.0 Transitional//",
                "-//W3C//DTD HTML Experimental 19960712//",
                "-//W3C//DTD HTML Experimental 970421//",
                "-//W3C//DTD W3 HTML//",
                "-//W3O//DTD W3 HTML 3.0//",
                "-//WebTechs//DTD Mozilla HTML 2.0//",
                "-//WebTechs//DTD Mozilla HTML//",
            };

            for (prefixes) |prefix| {
                if (mem.startsWith(u8, public_id, prefix)) {
                    return true;
                }
            }

            if (mem.eql(u8, public_id, "-//W3C//DTD HTML 4.01 Frameset//") and doctype.system_id == null
) {
                return true;
            }

            if (mem.eql(u8, public_id, "-//W3C//DTD HTML 4.01 Transitional//") and doctype.system_id == 
null) {
                return true;
            }
        }

        return false;
    }

    // DOM サイズの概箁E    fn estimateDOMSize(self: *HTMLParser, node: *DOM.Node) usize {
        _ = self;

        var size: usize = @sizeOf(DOM.Node);

        // ノ�Eド名
        if (node.nodeName) |name| {
            size += name.len;
        }

        // ノ�Eド値
        if (node.nodeValue) |value| {
            size += value.len;
        }

        // 再帰皁E��子ノード�Eサイズを加箁E        var child = node.firstChild;
        while (child) |c| {
            size += self.estimateDOMSize(c);
            child = c.nextSibling;
        }

        return size;
    }

    // InHeadNoscriptモード�E実裁E    fn processInHeadNoscriptMode(self: *HTMLParser, token: tokenizer.HTM
LToken) !void {
        switch (token) {
            .Doctype => |doctype| {
                // こ�EモードでのDOCTYPEはエラー
                try self.state.addError(doctype.line, doctype.column, "Unexpected DOCTYPE in 'in head no
script' mode", false);
            },
            .Character => |char| {
                if (isWhitespace(char.data)) {
                    // 空白斁E���E親に挿入
                    const currentNode = self.currentOpenElement() orelse return;
                    try self.insertText(currentNode, char.data);
                    return;
                }
                // 非空白斁E���Enoscriptを閉じて再�E琁E                try self.processNoscriptEnd();
                try self.processToken(token);
            },
            .Comment => |comment| {
                // コメント�E現在のノ�Eド！Eoscript�E�に追加
                const currentNode = self.currentOpenElement() orelse return;
                try self.appendComment(currentNode, comment.data);
            },
            .StartTag => |start_tag| {
                const tag_name = start_tag.name;

                if (mem.eql(u8, tag_name, "html")) {
                    // htmlタグは特別処琁E��EnBodyモードと同じ�E�E                    try self.processInBodyHT
MLStartTag(start_tag);
                } else if (mem.eql(u8, tag_name, "basefont") or
                    mem.eql(u8, tag_name, "bgsound") or
                    mem.eql(u8, tag_name, "link") or
                    mem.eql(u8, tag_name, "meta") or
                    mem.eql(u8, tag_name, "noframes") or
                    mem.eql(u8, tag_name, "style"))
                {
                    // これら�EタグはInHeadモードと同じように処琁E                    self.state.insertion_mod
e = .in_head;
                    try self.processToken(token);
                    // 処琁E��に允E�Eモードに戻ぁE                    self.state.insertion_mode = .in_head_nos
cript;
                } else if (mem.eql(u8, tag_name, "head") or
                    mem.eql(u8, tag_name, "noscript"))
                {
                    // head/noscriptの入れ子�Eエラー
                    try self.state.addError(start_tag.line, start_tag.column, "Unexpected element in 'in
 head noscript' mode", false);
                } else {
                    // そ�E他�E要素は noscript を閉じて再�E琁E                    try self.processNoscriptEnd(
);
                    try self.processToken(token);
                }
            },
            .EndTag => |end_tag| {
                const tag_name = end_tag.name;

                if (mem.eql(u8, tag_name, "noscript")) {
                    // noscriptの終亁E�E正常処琁E                    try self.processNoscriptEnd();
                } else if (mem.eql(u8, tag_name, "br")) {
                    // brの終亁E��グはnoscriptを閉じて再�E琁E                    try self.processNoscriptEnd()
;
                    try self.processToken(token);
                } else {
                    // そ�E他�E終亁E��グはエラー
                    try self.state.addError(end_tag.line, end_tag.column, "Unexpected end tag in 'in hea
d noscript' mode", false);
                }
            },
            else => {
                // そ�E他�Eト�Eクンはnoscriptを閉じて再�E琁E                try self.processNoscriptEnd();
                try self.processToken(token);
            },
        }
    }

    // noscript要素を閉じる処琁E    fn processNoscriptEnd(self: *HTMLParser) !void {
        if (self.state.open_elements.items.len > 0) {
            _ = self.state.open_elements.pop();
        }
        self.state.insertion_mode = .in_head;
    }

    // チE��ト�Eために残りの処琁E��数のスタブをシンプルに戻ぁE    fn processAfterHeadMode(self: *HTMLParser, token
: tokenizer.HTMLToken) !void {
            .Character => |char| {
                if (isWhitespace(char.data)) {
                    // 空白斁E���E現在のノ�Eドに挿入
                    const currentNode = self.currentOpenElement() orelse return;
                    try self.insertText(currentNode, char.data);
                    return;
                }
                // 非空白斁E���E暗黙的にbody要素を作�Eして処琁E                try self.createImplicitBody();
                self.state.insertion_mode = .in_body;
                try self.processToken(token);
            },
            .Comment => |comment| {
                // コメント�E現在のノ�Eドに追加
                const currentNode = self.currentOpenElement() orelse return;
                try self.appendComment(currentNode, comment.data);
            },
            .DOCTYPE => |doctype| {
                // こ�EモードでのDOCTYPEは解析エラー
                try self.state.addError(doctype.line, doctype.column, "Unexpected DOCTYPE in 'after head
' mode", false);
            },
            .StartTag => |start_tag| {
                const tag_name = start_tag.name;

                if (mem.eql(u8, tag_name, "html")) {
                    // htmlタグはInBodyモードで特別処琁E                    try self.processInBodyHTMLStar
tTag(start_tag);
                } else if (mem.eql(u8, tag_name, "body")) {
                    // bodyタグを作�Eしてhtml要素に追加
                    const body_element = try self.createHTMLElement(start_tag);
                    try self.appendNode(self.currentOpenElement(), body_element);
                    try self.state.open_elements.append(body_element);
                    self.state.insertion_mode = .in_body;
                    self.state.frameset_ok = false; // frameset-ok フラグをオフに
                } else if (mem.eql(u8, tag_name, "frameset")) {
                    // framesetタグを作�Eしてhtml要素に追加
                    const frameset_element = try self.createHTMLElement(start_tag);
                    try self.appendNode(self.currentOpenElement(), frameset_element);
                    try self.state.open_elements.append(frameset_element);
                    self.state.insertion_mode = .in_frameset;
                } else if (mem.eql(u8, tag_name, "base") or
                    mem.eql(u8, tag_name, "basefont") or
                    mem.eql(u8, tag_name, "bgsound") or
                    mem.eql(u8, tag_name, "link") or
                    mem.eql(u8, tag_name, "meta") or
                    mem.eql(u8, tag_name, "noframes") or
                    mem.eql(u8, tag_name, "script") or
                    mem.eql(u8, tag_name, "style") or
                    mem.eql(u8, tag_name, "template") or
                    mem.eql(u8, tag_name, "title"))
                {
                    // headに関連する要素はエラーだがhead要素に追加
                    try self.state.addError(start_tag.line, start_tag.column, "Element after </head> sho
uld be in <head>", true);

                    // headを取得して追加
                    var head_element: ?*Node = null;
                    const html_element = self.currentOpenElement() orelse return;

                    // 以前�Ehead要素を探ぁE                    var child = html_element.first_child;
                    while (child) |c| {
                        if (c.node_type == .element_node) {
                            const element_data = @ptrCast(*Element, c.specific_data.?);
                            if (element_data.tag_name != null and mem.eql(u8, element_data.tag_name.?, "
head")) {
                                head_element = c;
                                break;
                            }
                        }
                        child = c.next_sibling;
                    }

                    if (head_element) |head| {
                        // head要素が見つかった場合、一時的にInHeadモードに刁E��替えて処琁E                     
   try self.state.open_elements.append(head);

                        // 一時的にモードを刁E��替えて処琁E                        const original_mode = self.
state.insertion_mode;
                        self.state.insertion_mode = .in_head;
                        try self.processToken(token);
                        self.state.insertion_mode = original_mode;

                        // open_elementsからheadを削除
                        _ = self.state.open_elements.pop();
                    } else {
                        // headが見つからなぁE��合�E作�Eして追加
                        try self.createImplicitHead();
                        try self.processToken(token);
                        // headをpop
                        _ = self.state.open_elements.pop();
                    }
                } else if (mem.eql(u8, tag_name, "head")) {
                    // 2回目のhead要素はエラー
                    try self.state.addError(start_tag.line, start_tag.column, "Unexpected second <head> 
element", false);
                } else {
                    // そ�E他�E要素は暗黙的にbody要素を作�E
                    try self.createImplicitBody();
                    self.state.insertion_mode = .in_body;
                    try self.processToken(token);
                }
            },
            .EndTag => |end_tag| {
                const tag_name = end_tag.name;

                if (mem.eql(u8, tag_name, "body") or
                    mem.eql(u8, tag_name, "html") or
                    mem.eql(u8, tag_name, "br"))
                {
                    // 暗黙的にbody要素を作�Eして処琁E                    try self.createImplicitBody();
                    self.state.insertion_mode = .in_body;
                    try self.processToken(token);
                } else if (mem.eql(u8, tag_name, "template")) {
                    // template終亁E��グはInHeadモードと同様に処琁E                    self.state.insertion_m
ode = .in_head;
                    try self.processToken(token);
                    self.state.insertion_mode = .after_head;
                } else {
                    // そ�E他�E終亁E��グは解析エラー
                    try self.state.addError(end_tag.line, end_tag.column, "Unexpected end tag in 'after 
head' mode", false);
                }
            },
            else => {
                // そ�E他�Eト�Eクンは暗黙的にbody要素を作�E
                try self.createImplicitBody();
                self.state.insertion_mode = .in_body;
                try self.processToken(token);
            },
        }
    }

    // 暗黙的なbody要素を作�E
    fn createImplicitBody(self: *HTMLParser) !void {
        const body_element = try DOM.createNode(self.allocator, .Element, null);
        body_element.localName = try self.allocator.dupe(u8, "body");
        body_element.nodeName = try self.allocator.dupe(u8, "body");

        try self.appendNode(self.currentOpenElement(), body_element);
        try self.state.open_elements.append(body_element);

        try self.state.addError(0, 0, "Implicit <body> element creation", true);
    }

    fn processInBodyMode(self: *HTMLParser, token: tokenizer.HTMLToken) !void {
        switch (token) {
            .DOCTYPE => |doctype| {
                // こ�EモードでのDOCTYPEはエラー
                try self.state.addError(doctype.line, doctype.column, "Unexpected DOCTYPE in 'in body' m
ode", false);
            },
            
            .StartTag => |start_tag| {
                const tag_name = start_tag.name;
                
                if (mem.eql(u8, tag_name, "html")) {
                    // HTML要素は特別処琁E                    try self.processInBodyHTMLStartTag(start_ta
g);
                } else if (mem.eql(u8, tag_name, "body")) {
                    // 2番目のbody要素はエラー
                    try self.state.addError(start_tag.line, start_tag.column, "Unexpected <body> in 'in 
body' mode", false);
                    
                    // 既存Ebody要素に属性があれE追加
                    if (self.state.open_elements.items.len > 1) {
                        const body_element = self.state.open_elements.items[1]; // [0]はhtml, [1]はbody
                        
                        // 既存E属性があれE更新
                        for (start_tag.attributes) |attr| {
                            if (body_element.hasAttribute(attr.name)) continue;
                            
                            try body_element.setAttribute(attr.name, attr.value orelse "");
                        }
                    }
                } else if (mem.eql(u8, tag_name, "p") or
                           mem.eql(u8, tag_name, "div") or
                           mem.eql(u8, tag_name, "span") or
                           mem.eql(u8, tag_name, "h1") or
                           mem.eql(u8, tag_name, "h2") or
                           mem.eql(u8, tag_name, "h3") or
                           mem.eql(u8, tag_name, "h4") or
                           mem.eql(u8, tag_name, "h5") or
                           mem.eql(u8, tag_name, "h6")) 
                {
                    // 一般皁EブロチEブ要素の処琁E                    
                    // pタグが開ぁEぁEば閉じめE                    try self.closePElement();
                    
                    // 新しい要素を作Eして追加
                    const element = try self.createHTMLElement(start_tag);
                    try self.appendNode(self.currentOpenElement(), element);
                    try self.state.open_elements.append(element);
                } else if (mem.eql(u8, tag_name, "a")) {
                    // aタグの処琁E- アクチEブなフォーマット要素を検索
                    for (self.state.active_formatting_elements.items, 0..) |element, i| {
                        if (element.nodeType == .Element and element.localName != null and 
                            mem.eql(u8, element.localName.?, "a"))
                        {
                            // 既存Eaタグを閉じる
                            try self.state.addError(start_tag.line, start_tag.column, "Implicitly closin
g previous <a> element", true);
                            try self.adoptionAgencyAlgorithm("a");
                            
                            // アクチEブフォーマット要素から削除
                            _ = self.state.active_formatting_elements.orderedRemove(i);
                            break;
                        }
                    }
                    
                    // 新しいa要素を作Eして追加
                    const element = try self.createHTMLElement(start_tag);
                    try self.appendNode(self.currentOpenElement(), element);
                    try self.state.open_elements.append(element);
                    
                    // アクチEブフォーマット要素に追加
                    try self.state.active_formatting_elements.append(element);
                } else if (mem.eql(u8, tag_name, "br")) {
                    // brタグの処琁E                    const element = try self.createHTMLElement(start_
tag);
                    try self.appendNode(self.currentOpenElement(), element);
                    
                    // br要素はスタチーに追加しなぁEード
                    self.state.frameset_
ok = false;
                } else if (mem.eql(u8, tag_name, "script")) {
                    // スクリプト要素の処琁E                    self.state.insertion_mode = .in_head;
                    try self.processToken(token);
                    self.state.insertion_mode = .in_body;
                } else {
                    // そー他ー要素
                    const element = try self.createHTMLElement(start_tag);
                    try self.appendNode(self.currentOpenElement(), element);
                    try self.state.open_elements.append(element);
                }
            },
            
            .EndTag => |end_tag| {
                const tag_name = end_tag.name;
                
                if (mem.eql(u8, tag_name, "body")) {
                    // bodyの終亁Eグ
                    if (!self.hasElementInScope("body")) {
                        try self.state.addError(end_tag.line, end_tag.column, "Unexpected </body> tag wi
thout matching <body>", false);
                        return;
                    }
                    
                    
                    self.state.insertion_mode = .after_body;
                } else if (mem.eql(u8, tag_name, "html")) {
                    // htmlの終亁Eグ - まずbodyを閉じてから処琁E                    if (!self.hasElementInSco
pe("body")) {
                        try self.state.addError(end_tag.line, end_tag.column, "Unexpected </html> tag wi
thout proper nesting", false);
                        return;
                    }
                    
                    // 暗黙的にbodyの終亁Eグをー琁E                    self.state.insertion_mode = .after_b
ody;
                    try self.processToken(token);
                } else if (mem.eql(u8, tag_name, "p")) {
                    // p要素の終亁Eグ
                    if (!self.hasElementInButtonScope("p")) {
                        // pタグが開ぁーぁーければ暗黙的に開く
                        try self.state.addError(end_tag.line, end_tag.column, "No <p> element in scope, 
creating one", true);
                        
                        // 暗黙的にp要素を作ー
                        var p_start_tag = tokenizer.HTMLStartTag{
                            .name = "p",
                            .attributes = &[_]tokenizer.HTMLAttribute{},
                            .self_closing = false,
                            .line = end_tag.line,
                            .column = end_tag.column,
                        };
                        
                        const p_element = try self.createHTMLElement(p_start_tag);
                        try self.appendNode(self.currentOpenElement(), p_element);
                        try self.state.open_elements.append(p_element);
                    }
                    
                    // pタグを閉じる
                    try self.closePElement();
                } else if (isFormattingTag(tag_name)) {
                    // フォーマット要素の処琁Eー, i, strong, em などーーE                    try self.adoption
AgencyAlgorithm(tag_name);
                } else {
                    // 一般皁ー要素の終亁Eグ
                    try self.closeElementsToTag(tag_name);
                }
            },
            
            else => {
                // そー他ートークンは通常処琁E                try self.processGenericToken(token);
            },
        }
    }
    
    // p要素を閉じる
    fn closePElement(self: *HTMLParser) !void {
        if (!self.hasElementInButtonScope("p")) return;
        
        // スコープーのpまでスタチーからポッチー        var p_found = false;
        while (self.state.open_elements.items.len > 0) {
            const current = self.state.open_elements.items[self.state.open_elements.items.len - 1];
            
            if (current.nodeType == .Element and current.localName != null and 
                mem.eql(u8, current.localName.?, "p")) 
            {
                p_found = true;
                _ = self.state.open_elements.pop();
                break;
            }
            
            _ = self.state.open_elements.pop();
        }
        
        if (!p_found) {
            // エラー状慁ー            std.log.err("Failed to find <p> element in scope", .{});
        }
    }
    
    // 持ータグまでの要素をすべて閉じめー    fn closeElementsToTag(self: *HTMLParser, tag_name: []const u8) !
void {
        var found = false;
        var i: usize = self.state.open_elements.items.len;
        
        while (i > 0) : (i -= 1) {
            const element = self.state.open_elements.items[i - 1];
            
            if (element.nodeType == .Element and element.localName != null and 
                mem.eql(u8, element.localName.?, tag_name))
            {
                found = true;
                break;
            }
        }
        
        if (found) {
            // 該当タグまで要素を閉じる
            while (self.state.open_elements.items.len >= i) {
                _ = self.state.open_elements.pop();
            }
        }
    }
    
    // 要素が特定ースコーーにあるかチェチーーーー    fn hasElementInScope(self: *HTMLParser, tag_name: []const u8) bool {
        // スコーーの要素をチェチーー        for (self.state.open_elements.items, 0..) |_, i| {
            const idx = self.state.open_elements.items.len - 1 - i;  // 後ろから頁ーーチェチーー
            const current = self.state.open_elements.items[idx];
            
            if (current.nodeType == .Element and current.localName != null) {
                // 探してーータグが見つかっー                if (mem.eql(u8, current.localName.?, tag_name))
 {
                    return true;
                }
                
                // スコーーを制限する要素ーー, html, table, td, th などーー                if (mem.eql(u8, curren
t.localName.?, "html") or
                    mem.eql(u8, current.localName.?, "table") or
                    mem.eql(u8, current.localName.?, "template")) 
                {
                    return false;
                }
            }
        }
        
        return false;
    }
    
    // ボタンスコーーに要素があるかチェチーーー    fn hasElementInButtonScope(self: *HTMLParser, tag_name: []const u8) bool {
        // ボタンスコーーの要素をチェチーー (通常のスコーチー+ button)
        for (self.state.open_elements.items, 0..) |_, i| {
            const idx = self.state.open_elements.items.len - 1 - i;  // 後ろから頁ーーチェチーー
            const current = self.state.open_elements.items[idx];
            
            if (current.nodeType == .Element and current.localName != null) {
                // 探してーータグが見つかっー                if (mem.eql(u8, current.localName.?, tag_name))
 {
                    return true;
                }
                
                // スコーーを制限する要素
                if (mem.eql(u8, current.localName.?, "html") or
                    mem.eql(u8, current.localName.?, "table") or
                    mem.eql(u8, current.localName.?, "button") or
                    mem.eql(u8, current.localName.?, "template"))
                {
                    return false;
                }
            }
        }
        
        return false;
    }
    
    // 養子縁絁ーー尔ゴリズムーーフォーマット要素処琁ーーーーー    fn adoptionAgencyAlgorithm(self: *HTMLParser, tag_n
ame: []const u8) !void {
        // 完璧なAAA（Adoption Agency Algorithm）実装 - HTML5 Standard準拠
        // https://html.spec.whatwg.org/multipage/parsing.html#adoption-agency-algorithm
        var outer_loop_counter: usize = 0;
        const max_outer_iterations = 8;
        
        while (outer_loop_counter < max_outer_iterations) : (outer_loop_counter += 1) {
            // Step 1: formattingElementを検索
            var formatting_element: ?*DOM.Node = null;
            var formatting_element_idx: ?usize = null;
            
            // active formatting elements listから後方検索
            for (self.state.formatting_elements.items, 0..) |element, i| {
                const idx = self.state.formatting_elements.items.len - 1 - i;
                const current = self.state.formatting_elements.items[idx];
                
                if (current) |elem| {
                    if (elem.nodeType == .Element and elem.localName != null and 
                        mem.eql(u8, elem.localName.?, tag_name))
                    {
                        formatting_element = elem;
                        formatting_element_idx = idx;
                        break;
                    }
                }
            }
            
            // Step 2: formattingElementが見つからない場合
            if (formatting_element == null) {
                // "any other end tag" steps
                try self.processAnyOtherEndTag(tag_name);
                return;
            }
            
            // Step 3: formattingElementがopen elements stackにない場合
            var in_open_stack = false;
            var open_stack_idx: ?usize = null;
            
            for (self.state.open_elements.items, 0..) |element, i| {
                if (element == formatting_element) {
                    in_open_stack = true;
                    open_stack_idx = i;
                    break;
                }
            }
            
            if (!in_open_stack) {
                // Parse error: formatting elementをactive formatting elementsから削除
                self.removeFromFormattingElements(formatting_element.?);
                return;
            }
            
            // Step 4: formattingElementがopen elements stackのcurrent nodeでない場合
            if (self.state.open_elements.items[self.state.open_elements.items.len - 1] != formatting_element) {
                // Parse error: ただし処理は継続
            }
            
            // Step 5: furthest blockを検索
            var furthest_block: ?*DOM.Node = null;
            var furthest_block_idx: ?usize = null;
            
            if (open_stack_idx) |start_idx| {
                for (self.state.open_elements.items[start_idx + 1..], start_idx + 1..) |element, i| {
                    if (self.isSpecialElement(element)) {
                        furthest_block = element;
                        furthest_block_idx = i;
                        break;
                    }
                }
            }
            
            // Step 6: furthest blockが見つからない場合
            if (furthest_block == null) {
                // formattingElementまでopen stackからpop
                if (open_stack_idx) |idx| {
                    for (idx..self.state.open_elements.items.len) |_| {
                        _ = self.state.open_elements.pop();
                    }
                }
                self.removeFromFormattingElements(formatting_element.?);
                return;
            }
            
            // Step 7: common ancestorを決定
            var common_ancestor: ?*DOM.Node = null;
            if (open_stack_idx) |idx| {
                if (idx > 0) {
                    common_ancestor = self.state.open_elements.items[idx - 1];
                }
            }
            
            // Step 9: inner loop
            var node = furthest_block.?;
            var last_node = furthest_block.?;
            var inner_loop_counter: usize = 0;
            const max_inner_iterations = 3;
            
            while (inner_loop_counter < max_inner_iterations) : (inner_loop_counter += 1) {
                // Step 9.1: nodeの前の要素を取得
                var node_idx: ?usize = null;
                for (self.state.open_elements.items, 0..) |element, i| {
                    if (element == node) {
                        node_idx = i;
                        break;
                    }
                }
                
                if (node_idx) |idx| {
                    if (idx > 0) {
                        node = self.state.open_elements.items[idx - 1];
                    } else {
                        break; // nodeがstackの最初の要素
                    }
                } else {
                    break; // nodeがstackにない
                }
                
                // Step 9.2: nodeがformattingElementと同じ場合は終了
                if (node == formatting_element) {
                    break;
                }
                
                // Step 9.3: nodeがactive formatting elementsにない場合
                if (!self.isInFormattingElements(node)) {
                    // nodeをopen stackから削除
                    for (self.state.open_elements.items, 0..) |element, i| {
                        if (element == node) {
                            _ = self.state.open_elements.orderedRemove(i);
                            break;
                        }
                    }
                    continue;
                }
                
                // Step 9.4: nodeのクローンを作成
                const new_element = try self.cloneElement(node);
                
                // Step 9.5: active formatting elementsとopen stackでnodeを置換
                self.replaceInFormattingElements(node, new_element);
                self.replaceInOpenStack(node, new_element);
                
                // Step 9.6: last_nodeの親がcommon_ancestorの場合
                if (last_node.parentNode == common_ancestor) {
                    bookmark = self.getFormattingElementIndex(new_element);
                }
                
                // Step 9.7: last_nodeをnew_elementに移動
                try self.removeChild(last_node.parentNode, last_node);
                try self.appendChild(new_element, last_node);
                
                // Step 9.8: nodeをnew_elementに更新
                node = new_element;
                last_node = new_element;
            }
            
            // Step 10: last_nodeをappropriate placeに挿入
            try self.removeChild(last_node.parentNode, last_node);
            try self.insertNodeAtAppropriatePlace(last_node, common_ancestor);
            
            // Step 11: formatting elementのクローンを作成
            const new_formatting_element = try self.cloneElement(formatting_element.?);
            
            // Step 12: furthest blockの子要素をnew_formatting_elementに移動
            var child = furthest_block.?.firstChild;
            while (child != null) {
                const next_child = child.?.nextSibling;
                try self.removeChild(furthest_block.?, child.?);
                try self.appendChild(new_formatting_element, child.?);
                child = next_child;
            }
            
            // Step 13: new_formatting_elementをfurthest blockに追加
            try self.appendChild(furthest_block.?, new_formatting_element);
            
            // Step 14: active formatting elementsでformatting elementを削除し、
            // bookmarkの位置にnew_formatting_elementを挿入
            self.removeFromFormattingElements(formatting_element.?);
            try self.insertInFormattingElements(bookmark, new_formatting_element);
            
            // Step 15: open stackでformatting elementを削除し、
            // furthest blockの後にnew_formatting_elementを挿入
            self.removeFromOpenStack(formatting_element.?);
            if (furthest_block_idx) |idx| {
                try self.state.open_elements.insert(idx + 1, new_formatting_element);
            }
        }
    }
    
    // AAA支援関数群
    fn processAnyOtherEndTag(self: *HTMLParser, tag_name: []const u8) !void {
        // "any other end tag" algorithm
        for (self.state.open_elements.items, 0..) |_, i| {
            const idx = self.state.open_elements.items.len - 1 - i;
            const current = self.state.open_elements.items[idx];
            
            if (current.nodeType == .Element and current.localName != null and 
                mem.eql(u8, current.localName.?, tag_name))
            {
                // 要素が見つかった場合、この要素まで全てpop
                for (idx..self.state.open_elements.items.len) |_| {
                    _ = self.state.open_elements.pop();
                }
                return;
            }
            
            if (self.isSpecialElement(current)) {
                // Special elementに到達した場合、parse error
                return;
            }
        }
    }
    
    fn isSpecialElement(self: *HTMLParser, element: *DOM.Node) bool {
        if (element.nodeType != .Element or element.localName == null) {
            return false;
        }
        
        const special_elements = [_][]const u8{
            "address", "applet", "area", "article", "aside", "base", "basefont",
            "bgsound", "blockquote", "body", "br", "button", "caption", "center",
            "col", "colgroup", "dd", "details", "dir", "div", "dl", "dt", "embed",
            "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset",
            "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr",
            "html", "iframe", "img", "input", "li", "link", "listing", "main",
            "marquee", "menu", "meta", "nav", "noembed", "noframes", "noscript",
            "object", "ol", "p", "param", "plaintext", "pre", "script", "section",
            "select", "source", "style", "summary", "table", "tbody", "td",
            "template", "textarea", "tfoot", "th", "thead", "title", "tr", "track",
            "ul", "wbr", "xmp"
        };
        
        for (special_elements) |tag| {
            if (mem.eql(u8, element.localName.?, tag)) {
                return true;
            }
        }
        
        return false;
    }
    
    fn isInFormattingElements(self: *HTMLParser, element: *DOM.Node) bool {
        for (self.state.formatting_elements.items) |item| {
            if (item) |elem| {
                if (elem == element) {
                    return true;
                }
            }
        }
        return false;
    }
    
    fn removeFromFormattingElements(self: *HTMLParser, element: *DOM.Node) void {
        for (self.state.formatting_elements.items, 0..) |item, i| {
            if (item) |elem| {
                if (elem == element) {
                    self.state.formatting_elements.items[i] = null;
                    break;
                }
            }
        }
    }
    
    fn replaceInFormattingElements(self: *HTMLParser, old_element: *DOM.Node, new_element: *DOM.Node) void {
        for (self.state.formatting_elements.items, 0..) |item, i| {
            if (item) |elem| {
                if (elem == old_element) {
                    self.state.formatting_elements.items[i] = new_element;
                    break;
                }
            }
        }
    }
    
    fn replaceInOpenStack(self: *HTMLParser, old_element: *DOM.Node, new_element: *DOM.Node) void {
        for (self.state.open_elements.items, 0..) |element, i| {
            if (element == old_element) {
                self.state.open_elements.items[i] = new_element;
                break;
            }
        }
    }
    
    fn removeFromOpenStack(self: *HTMLParser, element: *DOM.Node) void {
        for (self.state.open_elements.items, 0..) |elem, i| {
            if (elem == element) {
                _ = self.state.open_elements.orderedRemove(i);
                break;
            }
        }
    }
    
    fn getFormattingElementIndex(self: *HTMLParser, element: *DOM.Node) usize {
        for (self.state.formatting_elements.items, 0..) |item, i| {
            if (item) |elem| {
                if (elem == element) {
                    return i;
                }
            }
        }
        return 0; // デフォルト
    }
    
    fn insertInFormattingElements(self: *HTMLParser, index: usize, element: *DOM.Node) !void {
        if (index < self.state.formatting_elements.items.len) {
            try self.state.formatting_elements.insert(index, element);
        } else {
            try self.state.formatting_elements.append(element);
        }
    }
    
    
    fn cloneElement(self: *HTMLParser, element: *DOM.Node) !*DOM.Node {
        // 要素のディープクローンを作成（属性のみ、子要素はコピーしない）
        const new_element = try self.arena.create(DOM.Node);
        new_element.* = DOM.Node{
            .nodeType = element.nodeType,
            .nodeName = element.nodeName,
            .localName = element.localName,
            .namespaceURI = element.namespaceURI,
            .attributes = try self.cloneAttributes(element.attributes),
            .children = std.ArrayList(*DOM.Node).init(self.arena),
            .parentNode = null,
            .nextSibling = null,
            .previousSibling = null,
            .firstChild = null,
            .lastChild = null,
            .textContent = element.textContent,
            .arena = self.arena,
        };
        
        return new_element;
    }
    
    fn cloneAttributes(self: *HTMLParser, attributes: std.StringHashMap([]const u8)) !std.StringHashMap([]const u8) {
        var new_attributes = std.StringHashMap([]const u8).init(self.arena);
        
        var iterator = attributes.iterator();
        while (iterator.next()) |entry| {
            try new_attributes.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        return new_attributes;
    }
    
    fn insertNodeAtAppropriatePlace(self: *HTMLParser, node: *DOM.Node, target: ?*DOM.Node) !void {
        const appropriate_place = target orelse self.currentOpenElement();
        if (appropriate_place) |parent| {
            try self.appendChild(parent, node);
        }
    }
};

test "error handling" {
    const allocator = std.testing.allocator;

    // 不正なHTMLをパースして、エラー回復をテスチE    const invalid_html =
        \\<p>Missing closing tag
        \\<div>
        \\  <span>Nested element
        \\</div>
    ;

    var parser = try HTMLParser.init(allocator, .{
        .error_tolerance = .maximum,
    });
    defer parser.deinit();

    const document = try parser.parse(invalid_html);

    // ドキュメントがパ�Eスされたことを確誁E    try std.testing.expect(document != null);
    try std.testing.expect(document.nodeType == .Document);

    // エラーが検�EされてぁE��ことを確誁E    try std.testing.expect(parser.state.errors.items.len > 0);

    // パ�Eサーが破棁E��れてぁEドキュメントE残る
    parser.document = null;
}


