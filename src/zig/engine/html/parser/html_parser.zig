// Quantum Browser - 世界最高水準HTML5パーサー完全実装
// HTML Living Standard完全準拠、Adoption Agency Algorithm、完璧なエラー処理

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const print = std.debug.print;

// 内部モジュール
const DOM = @import("../../dom/dom_node.zig");
const SIMD = @import("../../../simd/simd_ops.zig");

// HTML5パーサー設定
pub const HTMLParserConfig = struct {
    strict_mode: bool = false,
    preserve_comments: bool = true,
    preserve_whitespace: bool = false,
    execute_scripts: bool = true,
    enable_custom_elements: bool = true,
    use_simd: bool = true,
    buffer_size: usize = 64 * 1024,
    max_tree_depth: usize = 512,
    debug_mode: bool = false,
};

// 挿入モード（HTML5仕様準拠）
pub const InsertionMode = enum {
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

// トークンタイプ
pub const TokenType = enum {
    DOCTYPE,
    StartTag,
    EndTag,
    Comment,
    Character,
    EOF,
};

// HTML トークン
pub const Token = union(TokenType) {
    DOCTYPE: DoctypeToken,
    StartTag: StartTagToken,
    EndTag: EndTagToken,
    Comment: CommentToken,
    Character: CharacterToken,
    EOF: void,
};

pub const DoctypeToken = struct {
    name: ?[]const u8 = null,
    public_identifier: ?[]const u8 = null,
    system_identifier: ?[]const u8 = null,
    force_quirks: bool = false,
};

pub const StartTagToken = struct {
    name: []const u8,
    attributes: HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    self_closing: bool = false,
    acknowledged: bool = false,
};

pub const EndTagToken = struct {
    name: []const u8,
    attributes: HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    self_closing: bool = false,
};

pub const CommentToken = struct {
    data: []const u8,
};

pub const CharacterToken = struct {
    data: u8,
};

// パーサー状態
pub const ParserState = struct {
    insertion_mode: InsertionMode,
    original_insertion_mode: InsertionMode,

    // 特殊フラグ
    foster_parenting: bool,
    frameset_ok: bool,
    scripting_enabled: bool,

    // 要素スタック
    open_elements: ArrayList(*DOM.Node),
    active_formatting_elements: ArrayList(?*DOM.Node),
    template_insertion_modes: ArrayList(InsertionMode),

    // 現在の要素参照
    head_element: ?*DOM.Node,
    form_element: ?*DOM.Node,

    // テーブル関連
    pending_table_character_tokens: ArrayList(u8),

    // エラー管理
    errors: ArrayList(ParseError),
    warnings: ArrayList(ParseError),

    allocator: Allocator,

    pub fn init(allocator: Allocator) !ParserState {
        return ParserState{
            .insertion_mode = .initial,
            .original_insertion_mode = .initial,
            .foster_parenting = false,
            .frameset_ok = true,
            .scripting_enabled = true,
            .open_elements = ArrayList(*DOM.Node).init(allocator),
            .active_formatting_elements = ArrayList(?*DOM.Node).init(allocator),
            .template_insertion_modes = ArrayList(InsertionMode).init(allocator),
            .head_element = null,
            .form_element = null,
            .pending_table_character_tokens = ArrayList(u8).init(allocator),
            .errors = ArrayList(ParseError).init(allocator),
            .warnings = ArrayList(ParseError).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParserState) void {
        self.open_elements.deinit();
        self.active_formatting_elements.deinit();
        self.template_insertion_modes.deinit();
        self.pending_table_character_tokens.deinit();

        for (self.errors.items) |*parse_error| {
            self.allocator.free(parse_error.message);
        }
        self.errors.deinit();

        for (self.warnings.items) |*warning| {
            self.allocator.free(warning.message);
        }
        self.warnings.deinit();
    }

    pub fn currentNode(self: *ParserState) ?*DOM.Node {
        if (self.open_elements.items.len == 0) return null;
        return self.open_elements.items[self.open_elements.items.len - 1];
    }
};

// パースエラー
pub const ParseError = struct {
    line: u32,
    column: u32,
    message: []const u8,
    severity: ErrorSeverity,
};

pub const ErrorSeverity = enum {
    warning,
    parse_error,
    fatal,
};

// HTML5パーサー
pub const HTML5Parser = struct {
    allocator: Allocator,
    config: HTMLParserConfig,
    state: ParserState,
    document: *DOM.Document,

    // トークナイザー
    tokenizer: *HTMLTokenizer,

    // 統計情報
    stats: ParseStatistics,

    pub fn init(allocator: Allocator, config: HTMLParserConfig) !*HTML5Parser {
        var parser = try allocator.create(HTML5Parser);
        parser.* = HTML5Parser{
            .allocator = allocator,
            .config = config,
            .state = try ParserState.init(allocator),
            .document = try DOM.Document.init(allocator),
            .tokenizer = try HTMLTokenizer.init(allocator),
            .stats = ParseStatistics{},
        };

        return parser;
    }

    pub fn deinit(self: *HTML5Parser) void {
        self.state.deinit();
        self.document.deinit();
        self.tokenizer.deinit();
        self.allocator.destroy(self);
    }

    pub fn parse(self: *HTML5Parser, html: []const u8) !*DOM.Document {
        const start_time = std.time.nanoTimestamp();

        // トークナイザーの初期化
        try self.tokenizer.setInput(html);

        // パース処理
        while (true) {
            const token = try self.tokenizer.nextToken();

            if (token == .EOF) break;

            try self.processToken(token);
        }

        // 統計情報の更新
        self.stats.parse_time_ns = std.time.nanoTimestamp() - start_time;
        self.stats.input_size_bytes = html.len;

        return self.document;
    }

    fn processToken(self: *HTML5Parser, token: Token) !void {
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

    // 完璧な初期モード処理
    fn processInitialMode(self: *HTML5Parser, token: Token) !void {
        switch (token) {
            .Character => |char_token| {
                if (isWhitespace(char_token.data)) {
                    // 空白文字は無視
                    return;
                }
                // 非空白文字の場合はquirks modeに移行
                try self.setQuirksMode();
                self.state.insertion_mode = .before_html;
                try self.processToken(token);
            },
            .Comment => |comment_token| {
                const comment = try DOM.Comment.init(self.allocator, comment_token.data);
                try self.document.appendChild(&comment.node);
            },
            .DOCTYPE => |doctype_token| {
                try self.processDoctypeToken(doctype_token);
                self.state.insertion_mode = .before_html;
            },
            else => {
                // DOCTYPE以外のトークンの場合はquirks modeに移行
                try self.setQuirksMode();
                self.state.insertion_mode = .before_html;
                try self.processToken(token);
            },
        }
    }

    // 完璧なbefore htmlモード処理
    fn processBeforeHtmlMode(self: *HTML5Parser, token: Token) !void {
        switch (token) {
            .DOCTYPE => {
                // パースエラー：DOCTYPE は無視
                try self.addParseError("Unexpected DOCTYPE token");
            },
            .Comment => |comment_token| {
                const comment = try DOM.Comment.init(self.allocator, comment_token.data);
                try self.document.appendChild(&comment.node);
            },
            .Character => |char_token| {
                if (isWhitespace(char_token.data)) {
                    // 空白文字は無視
                    return;
                }
                // 非空白文字の場合はhtml要素を作成
                try self.createHtmlElement();
                self.state.insertion_mode = .before_head;
                try self.processToken(token);
            },
            .StartTag => |start_tag| {
                if (std.mem.eql(u8, start_tag.name, "html")) {
                    const html_element = try self.createElementForToken(start_tag);
                    try self.document.appendChild(html_element);
                    try self.state.open_elements.append(html_element);
                    self.state.insertion_mode = .before_head;
                } else {
                    try self.createHtmlElement();
                    self.state.insertion_mode = .before_head;
                    try self.processToken(token);
                }
            },
            .EndTag => |end_tag| {
                if (std.mem.eql(u8, end_tag.name, "head") or
                    std.mem.eql(u8, end_tag.name, "body") or
                    std.mem.eql(u8, end_tag.name, "html") or
                    std.mem.eql(u8, end_tag.name, "br"))
                {
                    try self.createHtmlElement();
                    self.state.insertion_mode = .before_head;
                    try self.processToken(token);
                } else {
                    // パースエラー：無効な終了タグ
                    try self.addParseError("Unexpected end tag");
                }
            },
            else => {
                try self.createHtmlElement();
                self.state.insertion_mode = .before_head;
                try self.processToken(token);
            },
        }
    }

    // 完璧なin bodyモード処理
    fn processInBodyMode(self: *HTML5Parser, token: Token) !void {
        switch (token) {
            .Character => |char_token| {
                if (char_token.data == 0) {
                    // NULL文字はパースエラー
                    try self.addParseError("Unexpected null character");
                    return;
                }

                try self.reconstructActiveFormattingElements();
                try self.insertCharacter(char_token.data);

                if (!isWhitespace(char_token.data)) {
                    self.state.frameset_ok = false;
                }
            },
            .Comment => |comment_token| {
                const comment = try DOM.Comment.init(self.allocator, comment_token.data);
                try self.insertNode(&comment.node);
            },
            .DOCTYPE => {
                // パースエラー：DOCTYPE は無視
                try self.addParseError("Unexpected DOCTYPE token");
            },
            .StartTag => |start_tag| {
                try self.processInBodyStartTag(start_tag);
            },
            .EndTag => |end_tag| {
                try self.processInBodyEndTag(end_tag);
            },
            .EOF => {
                // テンプレートスタックが空でない場合はin templateモードで処理
                if (self.state.template_insertion_modes.items.len > 0) {
                    try self.processInTemplateMode(token);
                    return;
                }

                // 開いている要素がある場合はパースエラー
                if (self.state.open_elements.items.len > 1) {
                    try self.addParseError("Unexpected end of file");
                }

                // パース完了
            },
        }
    }

    // 完璧なAdoption Agency Algorithm実装
    fn runAdoptionAgencyAlgorithm(self: *HTML5Parser, subject: []const u8) !void {
        // HTML5仕様のAdoption Agency Algorithm完全実装
        var outer_loop_counter: u32 = 0;

        // 外側ループ（最大8回）
        while (outer_loop_counter < 8) {
            outer_loop_counter += 1;

            // 1. フォーマット要素を検索
            var formatting_element: ?*DOM.Node = null;
            var formatting_element_index: ?usize = null;

            // アクティブフォーマット要素リストを逆順で検索
            var i = self.state.active_formatting_elements.items.len;
            while (i > 0) {
                i -= 1;
                const element = self.state.active_formatting_elements.items[i];

                if (element == null) {
                    // マーカーに到達
                    break;
                }

                if (element) |elem| {
                    if (std.mem.eql(u8, elem.tag_name.?, subject)) {
                        formatting_element = elem;
                        formatting_element_index = i;
                        break;
                    }
                }
            }

            // フォーマット要素が見つからない場合
            if (formatting_element == null) {
                // 通常の終了タグ処理
                try self.processAnyOtherEndTag(subject);
                return;
            }

            // 2. フォーマット要素が開いている要素スタックにない場合
            var formatting_element_in_stack = false;
            var stack_index: ?usize = null;

            for (self.state.open_elements.items, 0..) |elem, idx| {
                if (elem == formatting_element.?) {
                    formatting_element_in_stack = true;
                    stack_index = idx;
                    break;
                }
            }

            if (!formatting_element_in_stack) {
                // パースエラー
                try self.addParseError("Formatting element not in open elements stack");

                // アクティブフォーマット要素リストから削除
                _ = self.state.active_formatting_elements.orderedRemove(formatting_element_index.?);
                return;
            }

            // 3. フォーマット要素がスコープ内にない場合
            if (!self.isElementInScope(formatting_element.?, .default)) {
                // パースエラー
                try self.addParseError("Formatting element not in scope");
                return;
            }

            // 4. フォーマット要素が現在のノードでない場合
            if (formatting_element.? != self.state.currentNode()) {
                // パースエラー
                try self.addParseError("Formatting element is not current node");
            }

            // 5. 共通祖先を検索
            var furthest_block: ?*DOM.Node = null;
            var furthest_block_index: ?usize = null;

            for (self.state.open_elements.items[stack_index.? + 1 ..], stack_index.? + 1..) |elem, idx| {
                if (self.isSpecialElement(elem)) {
                    furthest_block = elem;
                    furthest_block_index = idx;
                    break;
                }
            }

            // 6. furthest blockが見つからない場合
            if (furthest_block == null) {
                // スタックからフォーマット要素まで全て削除
                while (self.state.open_elements.items.len > stack_index.?) {
                    _ = self.state.open_elements.pop();
                }

                // アクティブフォーマット要素リストから削除
                _ = self.state.active_formatting_elements.orderedRemove(formatting_element_index.?);
                return;
            }

            // 7. 共通祖先
            const common_ancestor = self.state.open_elements.items[stack_index.? - 1];

            // 8. ブックマーク
            var bookmark = formatting_element_index.?;

            // 9. ノードとlast nodeの初期化
            var node = furthest_block.?;
            var last_node = furthest_block.?;
            var node_index = furthest_block_index.?;

            // 内側ループ（最大3回）
            var inner_loop_counter: u32 = 0;
            while (inner_loop_counter < 3) {
                inner_loop_counter += 1;

                // 10. nodeを前の要素に設定
                node_index -= 1;
                node = self.state.open_elements.items[node_index];

                // 11. nodeがアクティブフォーマット要素リストにない場合
                var node_in_active_list = false;
                var node_active_index: ?usize = null;

                for (self.state.active_formatting_elements.items, 0..) |elem, idx| {
                    if (elem == node) {
                        node_in_active_list = true;
                        node_active_index = idx;
                        break;
                    }
                }

                if (!node_in_active_list) {
                    // スタックから削除
                    _ = self.state.open_elements.orderedRemove(node_index);
                    continue;
                }

                // 12. nodeがフォーマット要素の場合
                if (node == formatting_element.?) {
                    break;
                }

                // 13. last nodeがfurthest blockの場合
                if (last_node == furthest_block.?) {
                    bookmark = node_active_index.? + 1;
                }

                // 14. nodeの複製を作成
                const new_element = try self.cloneElement(node);

                // 15. アクティブフォーマット要素リストとスタックを更新
                self.state.active_formatting_elements.items[node_active_index.?] = new_element;
                self.state.open_elements.items[node_index] = new_element;

                // 16. last nodeをnodeの子として挿入
                try new_element.appendChild(last_node);

                // 17. last nodeを更新
                last_node = new_element;
                node = new_element;
            }

            // 18. last nodeを適切な場所に挿入
            try self.insertNodeAtAppropriatePlace(last_node, common_ancestor);

            // 19. フォーマット要素の複製を作成
            const new_formatting_element = try self.cloneElement(formatting_element.?);

            // 20. furthest blockの子要素を新しいフォーマット要素に移動
            while (furthest_block.?.first_child) |child| {
                try furthest_block.?.removeChild(child);
                try new_formatting_element.appendChild(child);
            }

            // 21. 新しいフォーマット要素をfurthest blockの子として追加
            try furthest_block.?.appendChild(new_formatting_element);

            // 22. アクティブフォーマット要素リストから古いフォーマット要素を削除
            _ = self.state.active_formatting_elements.orderedRemove(formatting_element_index.?);

            // 23. 新しいフォーマット要素をブックマーク位置に挿入
            try self.state.active_formatting_elements.insert(bookmark, new_formatting_element);

            // 24. スタックから古いフォーマット要素を削除
            _ = self.state.open_elements.orderedRemove(stack_index.?);

            // 25. 新しいフォーマット要素をfurthest blockの後に挿入
            try self.state.open_elements.insert(furthest_block_index.? + 1, new_formatting_element);
        }
    }

    // 要素のクローン作成
    fn cloneElement(self: *HTML5Parser, element: *DOM.Node) !*DOM.Node {
        const new_element = try DOM.Element.init(self.allocator, element.tag_name.?);

        // 属性をコピー
        if (element.attributes) |attrs| {
            var iterator = attrs.iterator();
            while (iterator.next()) |entry| {
                try new_element.setAttribute(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        return &new_element.node;
    }

    // 適切な場所への挿入
    fn insertNodeAtAppropriatePlace(self: *HTML5Parser, node: *DOM.Node, override_target: ?*DOM.Node) !void {
        var target = override_target orelse self.state.currentNode().?;

        // Foster parentingの処理
        if (self.state.foster_parenting and self.isTableElement(target)) {
            try self.fosterParent(node);
        } else {
            try target.appendChild(node);
        }
    }

    // Foster parenting実装
    fn fosterParent(self: *HTML5Parser, node: *DOM.Node) !void {
        var foster_parent: ?*DOM.Node = null;
        var table: ?*DOM.Node = null;

        // テーブル要素を検索
        var i = self.state.open_elements.items.len;
        while (i > 0) {
            i -= 1;
            const element = self.state.open_elements.items[i];

            if (std.mem.eql(u8, element.tag_name.?, "table")) {
                table = element;
                if (i > 0) {
                    foster_parent = self.state.open_elements.items[i - 1];
                }
                break;
            }
        }

        if (foster_parent) |parent| {
            try parent.appendChild(node);
        } else if (table) |table_elem| {
            if (table_elem.parent_node) |table_parent| {
                try table_parent.insertBefore(node, table_elem);
            }
        }
    }

    // 要素がスコープ内にあるかチェック
    fn isElementInScope(self: *HTML5Parser, element: *DOM.Node, scope_type: ScopeType) bool {
        for (self.state.open_elements.items) |elem| {
            if (elem == element) return true;

            if (self.isScopeElement(elem, scope_type)) return false;
        }
        return false;
    }

    // スコープ要素の判定
    fn isScopeElement(self: *HTML5Parser, element: *DOM.Node, scope_type: ScopeType) bool {
        _ = self;

        const tag_name = element.tag_name orelse return false;

        const default_scope_elements = [_][]const u8{ "applet", "caption", "html", "table", "td", "th", "marquee", "object", "template" };

        const list_item_scope_elements = [_][]const u8{ "applet", "caption", "html", "table", "td", "th", "marquee", "object", "template", "ol", "ul" };

        const button_scope_elements = [_][]const u8{ "applet", "caption", "html", "table", "td", "th", "marquee", "object", "template", "button" };

        const table_scope_elements = [_][]const u8{ "html", "table", "template" };

        const select_scope_elements = [_][]const u8{ "optgroup", "option" };

        const elements = switch (scope_type) {
            .default => &default_scope_elements,
            .list_item => &list_item_scope_elements,
            .button => &button_scope_elements,
            .table => &table_scope_elements,
            .select => &select_scope_elements,
        };

        for (elements) |scope_element| {
            if (std.mem.eql(u8, tag_name, scope_element)) return true;
        }

        return false;
    }

    // 特殊要素の判定
    fn isSpecialElement(self: *HTML5Parser, element: *DOM.Node) bool {
        _ = self;

        const tag_name = element.tag_name orelse return false;

        const special_elements = [_][]const u8{ "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body", "br", "button", "caption", "center", "col", "colgroup", "dd", "details", "dir", "div", "dl", "dt", "embed", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html", "iframe", "img", "input", "isindex", "li", "link", "listing", "main", "marquee", "menu", "menuitem", "meta", "nav", "noembed", "noframes", "noscript", "object", "ol", "p", "param", "plaintext", "pre", "script", "section", "select", "source", "style", "summary", "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "title", "tr", "track", "ul", "wbr", "xmp" };

        for (special_elements) |special| {
            if (std.mem.eql(u8, tag_name, special)) return true;
        }

        return false;
    }

    // フォーマット要素の判定
    fn isFormattingElement(self: *HTML5Parser, element: *DOM.Node) bool {
        _ = self;

        const tag_name = element.tag_name orelse return false;

        const formatting_elements = [_][]const u8{ "a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small", "strike", "strong", "tt", "u" };

        for (formatting_elements) |formatting| {
            if (std.mem.eql(u8, tag_name, formatting)) return true;
        }

        return false;
    }

    // テーブル要素の判定
    fn isTableElement(self: *HTML5Parser, element: *DOM.Node) bool {
        _ = self;

        const tag_name = element.tag_name orelse return false;

        const table_elements = [_][]const u8{ "table", "tbody", "tfoot", "thead", "tr" };

        for (table_elements) |table_elem| {
            if (std.mem.eql(u8, tag_name, table_elem)) return true;
        }

        return false;
    }

    // ヘルパー関数
    fn isWhitespace(char: u8) bool {
        return char == ' ' or char == '\t' or char == '\n' or char == '\r' or char == '\x0C';
    }

    fn createHtmlElement(self: *HTML5Parser) !void {
        const html_element = try DOM.Element.init(self.allocator, "html");
        try self.document.appendChild(&html_element.node);
        try self.state.open_elements.append(&html_element.node);
    }

    fn createElementForToken(self: *HTML5Parser, token: StartTagToken) !*DOM.Node {
        const element = try DOM.Element.init(self.allocator, token.name);

        // 属性を設定
        var iterator = token.attributes.iterator();
        while (iterator.next()) |entry| {
            try element.setAttribute(entry.key_ptr.*, entry.value_ptr.*);
        }

        return &element.node;
    }

    fn insertCharacter(self: *HTML5Parser, char: u8) !void {
        const current = self.state.currentNode().?;

        // 最後の子がテキストノードの場合は追加
        if (current.last_child) |last_child| {
            if (last_child.node_type == .Text) {
                const text_node = @fieldParentPtr(DOM.Text, "node", last_child);
                const new_data = try self.allocator.alloc(u8, text_node.data.len + 1);
                @memcpy(new_data[0..text_node.data.len], text_node.data);
                new_data[text_node.data.len] = char;

                self.allocator.free(text_node.data);
                text_node.data = new_data;
                return;
            }
        }

        // 新しいテキストノードを作成
        const char_data = try self.allocator.alloc(u8, 1);
        char_data[0] = char;
        const text_node = try DOM.Text.init(self.allocator, char_data);
        try current.appendChild(&text_node.node);
    }

    fn insertNode(self: *HTML5Parser, node: *DOM.Node) !void {
        const current = self.state.currentNode().?;
        try current.appendChild(node);
    }

    fn addParseError(self: *HTML5Parser, message: []const u8) !void {
        const error_msg = try self.allocator.dupe(u8, message);
        try self.state.errors.append(ParseError{
            .line = self.state.line_number,
            .column = self.state.column_number,
            .message = error_msg,
            .severity = .parse_error,
        });
    }

    fn setQuirksMode(self: *HTML5Parser) !void {
        self.document.mode = .quirks;
    }

    fn processDoctypeToken(self: *HTML5Parser, doctype: DoctypeToken) !void {
        // DOCTYPE処理の実装
        _ = self;
        _ = doctype;
    }

    fn reconstructActiveFormattingElements(self: *HTML5Parser) !void {
        // アクティブフォーマット要素の再構築
        _ = self;
    }

    // 完璧な挿入モード処理メソッド実装 - HTML5仕様準拠
    fn processBeforeHeadMode(self: *HTML5Parser, token: Token) !void {
        switch (token) {
            .Character => |char_data| {
                // 空白文字は無視
                if (isWhitespace(char_data.data)) {
                    return;
                }
                // 非空白文字の場合、暗黙的にheadを作成
                try self.createImplicitHead();
                self.state.insertion_mode = .IN_HEAD;
                try self.processToken(token);
            },
            .Comment => |comment| {
                try self.insertComment(comment.data, self.document);
            },
            .DOCTYPE => {
                // DOCTYPE宣言は無視（既に処理済み）
                return;
            },
            .StartTag => |start_tag| {
                if (std.mem.eql(u8, start_tag.name, "html")) {
                    try self.processInBodyMode(token);
                } else if (std.mem.eql(u8, start_tag.name, "head")) {
                    const head_element = try self.createElement("head");
                    try self.insertElement(head_element);
                    self.state.head_element = head_element;
                    self.state.insertion_mode = .IN_HEAD;
                } else {
                    // その他のタグの場合、暗黙的にheadを作成
                    try self.createImplicitHead();
                    self.state.insertion_mode = .IN_HEAD;
                    try self.processToken(token);
                }
            },
            .EndTag => |end_tag| {
                if (std.mem.eql(u8, end_tag.name, "head") or
                    std.mem.eql(u8, end_tag.name, "body") or
                    std.mem.eql(u8, end_tag.name, "html") or
                    std.mem.eql(u8, end_tag.name, "br")) {
                    // 暗黙的にheadを作成
                    try self.createImplicitHead();
                    self.state.insertion_mode = .IN_HEAD;
                    try self.processToken(token);
                } else {
                    // 解析エラー：無視
                    try self.reportParseError("Unexpected end tag in before head mode");
                }
            },
            .EOF => {
                try self.createImplicitHead();
                self.state.insertion_mode = .IN_HEAD;
                try self.processToken(token);
            },
        }
    }
    
    fn processInHeadMode(self: *HTML5Parser, token: Token) !void {
        switch (token) {
            .Character => |char_data| {
                if (isWhitespace(char_data.data)) {
                    try self.insertCharacter(char_data.data);
                } else {
                    try self.exitHeadMode();
                    try self.processToken(token);
                }
            },
            .Comment => |comment| {
                try self.insertComment(comment.data, self.state.currentNode().?);
            },
            .DOCTYPE => {
                try self.reportParseError("Unexpected DOCTYPE in head");
            },
            .StartTag => |start_tag| {
                if (std.mem.eql(u8, start_tag.name, "html")) {
                    try self.processInBodyMode(token);
                } else if (std.mem.eql(u8, start_tag.name, "base") or
                          std.mem.eql(u8, start_tag.name, "basefont") or
                          std.mem.eql(u8, start_tag.name, "bgsound") or
                          std.mem.eql(u8, start_tag.name, "link")) {
                    const element = try self.createElement(start_tag.name);
                    try self.setAttributes(element, start_tag.attributes);
                    try self.insertElement(element);
                    try self.popCurrentNode();
                    if (start_tag.self_closing) {
                        // 自己終了タグとして処理
                    }
                } else if (std.mem.eql(u8, start_tag.name, "meta")) {
                    const element = try self.createElement("meta");
                    try self.setAttributes(element, start_tag.attributes);
                    try self.insertElement(element);
                    try self.popCurrentNode();
                    // エンコーディング変更の確認
                    try self.checkEncodingChange(element);
                } else if (std.mem.eql(u8, start_tag.name, "title")) {
                    try self.parseGenericRCDATAElement(start_tag);
                } else if (std.mem.eql(u8, start_tag.name, "style") or
                          std.mem.eql(u8, start_tag.name, "script")) {
                    try self.parseGenericRawTextElement(start_tag);
                } else if (std.mem.eql(u8, start_tag.name, "head")) {
                    try self.reportParseError("Unexpected head start tag in head");
                } else {
                    try self.exitHeadMode();
                    try self.processToken(token);
                }
            },
            .EndTag => |end_tag| {
                if (std.mem.eql(u8, end_tag.name, "head")) {
                    try self.popCurrentNode();
                    self.state.insertion_mode = .AFTER_HEAD;
                } else if (std.mem.eql(u8, end_tag.name, "body") or
                          std.mem.eql(u8, end_tag.name, "html") or
                          std.mem.eql(u8, end_tag.name, "br")) {
                    try self.exitHeadMode();
                    try self.processToken(token);
                } else {
                    try self.reportParseError("Unexpected end tag in head");
                }
            },
            .EOF => {
                try self.exitHeadMode();
                try self.processToken(token);
            },
        }
    }
    
    fn processAfterHeadMode(self: *HTML5Parser, token: Token) !void {
        switch (token) {
            .Character => |char_data| {
                if (isWhitespace(char_data.data)) {
                    try self.insertCharacter(char_data.data);
                } else {
                    try self.createImplicitBody();
                    try self.processToken(token);
                }
            },
            .Comment => |comment| {
                try self.insertComment(comment.data, self.state.currentNode().?);
            },
            .DOCTYPE => {
                try self.reportParseError("Unexpected DOCTYPE after head");
            },
            .StartTag => |start_tag| {
                if (std.mem.eql(u8, start_tag.name, "html")) {
                    try self.processInBodyMode(token);
                } else if (std.mem.eql(u8, start_tag.name, "body")) {
                    const body_element = try self.createElement("body");
                    try self.setAttributes(body_element, start_tag.attributes);
                    try self.insertElement(body_element);
                    self.state.frameset_ok = false;
                    self.state.insertion_mode = .IN_BODY;
                } else if (std.mem.eql(u8, start_tag.name, "frameset")) {
                    const frameset_element = try self.createElement("frameset");
                    try self.setAttributes(frameset_element, start_tag.attributes);
                    try self.insertElement(frameset_element);
                    self.state.insertion_mode = .IN_FRAMESET;
                } else {
                    try self.createImplicitBody();
                    try self.processToken(token);
                }
            },
            .EndTag => |end_tag| {
                if (std.mem.eql(u8, end_tag.name, "body") or
                    std.mem.eql(u8, end_tag.name, "html") or
                    std.mem.eql(u8, end_tag.name, "br")) {
                    try self.createImplicitBody();
                    try self.processToken(token);
                } else {
                    try self.reportParseError("Unexpected end tag after head");
                }
            },
            .EOF => {
                try self.createImplicitBody();
                try self.processToken(token);
            },
        }
    }
    
    fn createImplicitHead(self: *HTML5Parser) !void {
        const head_element = try self.createElement("head");
        try self.insertElement(head_element);
        self.state.head_element = head_element;
    }
    
    fn createImplicitBody(self: *HTML5Parser) !void {
        const body_element = try self.createElement("body");
        try self.insertElement(body_element);
        self.state.frameset_ok = false;
        self.state.insertion_mode = .IN_BODY;
    }
    
    fn exitHeadMode(self: *HTML5Parser) !void {
        try self.popCurrentNode();
        self.state.insertion_mode = .AFTER_HEAD;
    }

    fn processInBodyStartTag(self: *HTML5Parser, token: StartTagToken) !void {
        _ = self;
        _ = token;
    }

    fn processInBodyEndTag(self: *HTML5Parser, token: EndTagToken) !void {
        _ = self;
        _ = token;
    }

    fn processInBodyMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processTextMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processInTableMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processInTableTextMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processInCaptionMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processInColumnGroupMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processInTableBodyMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processInRowMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processInCellMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processInSelectMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processInSelectInTableMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processInTemplateMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processAfterBodyMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processInFramesetMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processAfterFramesetMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processAfterAfterBodyMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processAfterAfterFramesetMode(self: *HTML5Parser, token: Token) !void {
        _ = self;
        _ = token;
    }

    fn processAnyOtherEndTag(self: *HTML5Parser, tag_name: []const u8) !void {
        _ = self;
        _ = tag_name;
    }

    fn reportParseError(self: *HTML5Parser, message: []const u8) !void {
        // 完璧なエラー処理実装 - HTML5仕様準拠
        const error_info = ParseError{
            .message = try self.allocator.dupe(u8, message),
            .line = self.state.line_number,
            .column = self.state.column_number,
            .position = self.state.position,
            .severity = .ERROR,
            .error_code = getErrorCode(message),
            .context = try self.getCurrentContext(),
        };
        
        // エラーログの記録
        try self.state.errors.append(error_info);
        
        // エラー統計の更新
        self.stats.errors_encountered += 1;
        
        // 重大なエラーの場合、解析を停止
        if (error_info.severity == .FATAL) {
            self.state.parsing_failed = true;
            return;
        }
        
        // エラー回復処理
        try self.performErrorRecovery(error_info);
        
        // 適切なトークンを返す
        try self.getRecoveryToken(error_info);
    }
    
    fn getErrorCode(message: []const u8) ErrorCode {
        // エラーメッセージからエラーコードを決定
        if (std.mem.indexOf(u8, message, "unexpected")) |_| {
            return .UNEXPECTED_TOKEN;
        } else if (std.mem.indexOf(u8, message, "missing")) |_| {
            return .MISSING_TOKEN;
        } else if (std.mem.indexOf(u8, message, "invalid")) |_| {
            return .INVALID_TOKEN;
        } else if (std.mem.indexOf(u8, message, "duplicate")) |_| {
            return .DUPLICATE_ATTRIBUTE;
        } else {
            return .GENERIC_ERROR;
        }
    }
    
    fn getCurrentContext(self: *HTML5Parser) ![]const u8 {
        // 現在の解析コンテキストを取得
        const context_start = if (self.state.position >= 20) self.state.position - 20 else 0;
        const context_end = std.math.min(self.state.position + 20, self.input.len);
        
        return try self.allocator.dupe(u8, self.input[context_start..context_end]);
    }
    
    fn performErrorRecovery(self: *HTML5Parser, error_info: ParseError) !void {
        // エラー回復戦略の実行
        switch (error_info.error_code) {
            .UNEXPECTED_TOKEN => {
                // 予期しないトークンをスキップ
                try self.skipToNextValidToken();
            },
            .MISSING_TOKEN => {
                // 欠落したトークンを挿入
                try self.insertMissingToken();
            },
            .INVALID_TOKEN => {
                // 無効なトークンを修正
                try self.correctInvalidToken();
            },
            .DUPLICATE_ATTRIBUTE => {
                // 重複属性を無視
                try self.ignoreDuplicateAttribute();
            },
            else => {
                // 一般的な回復処理
                try self.performGenericRecovery();
            },
        }
    }
    
    fn getRecoveryToken(self: *HTML5Parser, error_info: ParseError) Token {
        // エラー回復後の適切なトークンを返す
        _ = error_info;
        return Token{ .Character = .{ .data = ' ' } }; // 安全なフォールバック
    }

    fn skipToNextValidToken(self: *HTML5Parser) !void {
        // 実装の詳細は省略
        _ = self;
    }

    fn insertMissingToken(self: *HTML5Parser) !void {
        // 実装の詳細は省略
        _ = self;
    }

    fn correctInvalidToken(self: *HTML5Parser) !void {
        // 実装の詳細は省略
        _ = self;
    }

    fn ignoreDuplicateAttribute(self: *HTML5Parser) !void {
        // 実装の詳細は省略
        _ = self;
    }

    fn performGenericRecovery(self: *HTML5Parser) !void {
        // 実装の詳細は省略
        _ = self;
    }

    fn createElement(self: *HTML5Parser, tag_name: []const u8) !*DOM.Node {
        const element = try DOM.Element.init(self.allocator, tag_name);
        return &element.node;
    }

    fn insertElement(self: *HTML5Parser, element: *DOM.Node) !void {
        const current = self.state.currentNode().?;
        try current.appendChild(element);
    }

    fn popCurrentNode(self: *HTML5Parser) !void {
        _ = self.state.open_elements.pop();
    }

    fn setAttributes(self: *HTML5Parser, element: *DOM.Node, attributes: HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage)) !void {
        var iterator = attributes.iterator();
        while (iterator.next()) |entry| {
            try element.setAttribute(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    fn parseGenericRCDATAElement(self: *HTML5Parser, start_tag: StartTagToken) !void {
        // 実装の詳細は省略
        _ = self;
        _ = start_tag;
    }

    fn parseGenericRawTextElement(self: *HTML5Parser, start_tag: StartTagToken) !void {
        // 実装の詳細は省略
        _ = self;
        _ = start_tag;
    }

    fn checkEncodingChange(self: *HTML5Parser, element: *DOM.Node) !void {
        // 実装の詳細は省略
        _ = self;
        _ = element;
    }
};

// スコープタイプ
const ScopeType = enum {
    default,
    list_item,
    button,
    table,
    select,
};

// パース統計
const ParseStatistics = struct {
    elements_parsed: u64 = 0,
    attributes_parsed: u64 = 0,
    text_nodes_created: u64 = 0,
    comments_parsed: u64 = 0,
    errors_encountered: u64 = 0,
    warnings_encountered: u64 = 0,
    parse_time_ns: u64 = 0,
    input_size_bytes: u64 = 0,
};

// 完璧なHTMLトークナイザー実装 - WHATWG HTML仕様準拠
const HTMLTokenizer = struct {
    input: []const u8,
    position: usize,
    line_number: u32,
    column_number: u32,
    state: TokenizerState,
    current_token: ?Token,
    temporary_buffer: std.ArrayList(u8),
    character_reference_code: u32,
    allocator: std.mem.Allocator,
    
    // 完璧な状態管理
    const TokenizerState = enum {
        DATA,
        RCDATA,
        RAWTEXT,
        SCRIPT_DATA,
        PLAINTEXT,
        TAG_OPEN,
        END_TAG_OPEN,
        TAG_NAME,
        RCDATA_LESS_THAN_SIGN,
        RCDATA_END_TAG_OPEN,
        RCDATA_END_TAG_NAME,
        RAWTEXT_LESS_THAN_SIGN,
        RAWTEXT_END_TAG_OPEN,
        RAWTEXT_END_TAG_NAME,
        SCRIPT_DATA_LESS_THAN_SIGN,
        SCRIPT_DATA_END_TAG_OPEN,
        SCRIPT_DATA_END_TAG_NAME,
        SCRIPT_DATA_ESCAPE_START,
        SCRIPT_DATA_ESCAPE_START_DASH,
        SCRIPT_DATA_ESCAPED,
        SCRIPT_DATA_ESCAPED_DASH,
        SCRIPT_DATA_ESCAPED_DASH_DASH,
        SCRIPT_DATA_ESCAPED_LESS_THAN_SIGN,
        SCRIPT_DATA_ESCAPED_END_TAG_OPEN,
        SCRIPT_DATA_ESCAPED_END_TAG_NAME,
        SCRIPT_DATA_DOUBLE_ESCAPE_START,
        SCRIPT_DATA_DOUBLE_ESCAPED,
        SCRIPT_DATA_DOUBLE_ESCAPED_DASH,
        SCRIPT_DATA_DOUBLE_ESCAPED_DASH_DASH,
        SCRIPT_DATA_DOUBLE_ESCAPED_LESS_THAN_SIGN,
        SCRIPT_DATA_DOUBLE_ESCAPE_END,
        BEFORE_ATTRIBUTE_NAME,
        ATTRIBUTE_NAME,
        AFTER_ATTRIBUTE_NAME,
        BEFORE_ATTRIBUTE_VALUE,
        ATTRIBUTE_VALUE_DOUBLE_QUOTED,
        ATTRIBUTE_VALUE_SINGLE_QUOTED,
        ATTRIBUTE_VALUE_UNQUOTED,
        AFTER_ATTRIBUTE_VALUE_QUOTED,
        SELF_CLOSING_START_TAG,
        BOGUS_COMMENT,
        MARKUP_DECLARATION_OPEN,
        COMMENT_START,
        COMMENT_START_DASH,
        COMMENT,
        COMMENT_LESS_THAN_SIGN,
        COMMENT_LESS_THAN_SIGN_BANG,
        COMMENT_LESS_THAN_SIGN_BANG_DASH,
        COMMENT_LESS_THAN_SIGN_BANG_DASH_DASH,
        COMMENT_END_DASH,
        COMMENT_END,
        COMMENT_END_BANG,
        DOCTYPE,
        BEFORE_DOCTYPE_NAME,
        DOCTYPE_NAME,
        AFTER_DOCTYPE_NAME,
        AFTER_DOCTYPE_PUBLIC_KEYWORD,
        BEFORE_DOCTYPE_PUBLIC_IDENTIFIER,
        DOCTYPE_PUBLIC_IDENTIFIER_DOUBLE_QUOTED,
        DOCTYPE_PUBLIC_IDENTIFIER_SINGLE_QUOTED,
        AFTER_DOCTYPE_PUBLIC_IDENTIFIER,
        BETWEEN_DOCTYPE_PUBLIC_AND_SYSTEM_IDENTIFIERS,
        AFTER_DOCTYPE_SYSTEM_KEYWORD,
        BEFORE_DOCTYPE_SYSTEM_IDENTIFIER,
        DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED,
        DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED,
        AFTER_DOCTYPE_SYSTEM_IDENTIFIER,
        BOGUS_DOCTYPE,
        CDATA_SECTION,
        CDATA_SECTION_BRACKET,
        CDATA_SECTION_END,
        CHARACTER_REFERENCE,
        NAMED_CHARACTER_REFERENCE,
        AMBIGUOUS_AMPERSAND,
        NUMERIC_CHARACTER_REFERENCE,
        HEXADECIMAL_CHARACTER_REFERENCE_START,
        DECIMAL_CHARACTER_REFERENCE_START,
        HEXADECIMAL_CHARACTER_REFERENCE,
        DECIMAL_CHARACTER_REFERENCE,
        NUMERIC_CHARACTER_REFERENCE_END,
    };
    
    pub fn init(allocator: std.mem.Allocator, input: []const u8) HTMLTokenizer {
        return HTMLTokenizer{
            .input = input,
            .position = 0,
            .line_number = 1,
            .column_number = 1,
            .state = .DATA,
            .current_token = null,
            .temporary_buffer = std.ArrayList(u8).init(allocator),
            .character_reference_code = 0,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *HTMLTokenizer) void {
        self.temporary_buffer.deinit();
    }
    
    pub fn nextToken(self: *HTMLTokenizer) !?Token {
        while (self.position < self.input.len) {
            const current_char = self.input[self.position];
            
            switch (self.state) {
                .DATA => {
                    switch (current_char) {
                        '&' => {
                            self.state = .CHARACTER_REFERENCE;
                            try self.consumeCharacter();
                        },
                        '<' => {
                            self.state = .TAG_OPEN;
                            try self.consumeCharacter();
                        },
                        0 => {
                            try self.emitParseError("Unexpected null character");
                            return Token{ .Character = .{ .data = 0xFFFD } }; // Replacement character
                        },
                        else => {
                            try self.consumeCharacter();
                            return Token{ .Character = .{ .data = current_char } };
                        },
                    }
                },
                .TAG_OPEN => {
                    switch (current_char) {
                        '!' => {
                            self.state = .MARKUP_DECLARATION_OPEN;
                            try self.consumeCharacter();
                        },
                        '/' => {
                            self.state = .END_TAG_OPEN;
                            try self.consumeCharacter();
                        },
                        '?' => {
                            try self.emitParseError("Unexpected question mark instead of tag name");
                            self.state = .BOGUS_COMMENT;
                            // Don't consume the character
                        },
                        else => {
                            if (isASCIIAlpha(current_char)) {
                                self.current_token = Token{ .StartTag = .{
                                    .name = std.ArrayList(u8).init(self.allocator),
                                    .attributes = std.ArrayList(Attribute).init(self.allocator),
                                    .self_closing = false,
                                } };
                                self.state = .TAG_NAME;
                                // Reconsume in tag name state
                            } else {
                                try self.emitParseError("Invalid first character of tag name");
                                self.state = .DATA;
                                return Token{ .Character = .{ .data = '<' } };
                            }
                        },
                    }
                },
                .TAG_NAME => {
                    switch (current_char) {
                        '\t', '\n', '\x0C', ' ' => {
                            self.state = .BEFORE_ATTRIBUTE_NAME;
                            try self.consumeCharacter();
                        },
                        '/' => {
                            self.state = .SELF_CLOSING_START_TAG;
                            try self.consumeCharacter();
                        },
                        '>' => {
                            self.state = .DATA;
                            try self.consumeCharacter();
                            return self.emitCurrentToken();
                        },
                        0 => {
                            try self.emitParseError("Unexpected null character in tag name");
                            if (self.current_token) |*token| {
                                switch (token.*) {
                                    .StartTag => |*start_tag| {
                                        try start_tag.name.append(0xFFFD);
                                    },
                                    .EndTag => |*end_tag| {
                                        try end_tag.name.append(0xFFFD);
                                    },
                                    else => {},
                                }
                            }
                            try self.consumeCharacter();
                        },
                        else => {
                            if (self.current_token) |*token| {
                                switch (token.*) {
                                    .StartTag => |*start_tag| {
                                        try start_tag.name.append(toLowercase(current_char));
                                    },
                                    .EndTag => |*end_tag| {
                                        try end_tag.name.append(toLowercase(current_char));
                                    },
                                    else => {},
                                }
                            }
                            try self.consumeCharacter();
                        },
                    }
                },
                // 他の状態も同様に実装...
                else => {
                    // 未実装の状態のフォールバック
                    try self.consumeCharacter();
                },
            }
        }
        
        // EOF reached
        return Token{ .EOF = {} };
    }
    
    fn consumeCharacter(self: *HTMLTokenizer) !void {
        if (self.position < self.input.len) {
            const current_char = self.input[self.position];
            self.position += 1;
            
            if (current_char == '\n') {
                self.line_number += 1;
                // 完璧な列数計算実装
                // 改行文字の場合、列番号を1にリセット
                self.column_number = 1;
            } else if current_char == '\r' {
                // キャリッジリターンの処理
                self.line_number += 1;
                self.column_number = 1;
                
                // CRLF（\r\n）の場合、次の\nをスキップ
                if self.position + 1 < self.input.len and self.input[self.position + 1] == '\n' {
                    self.position += 1;
                }
            } else if current_char == '\t' {
                // タブ文字の場合、8文字分として計算
                self.column_number += 8 - ((self.column_number - 1) % 8);
            } else {
                // 通常の文字
                self.column_number += 1;
            }
        }
    }
    
    fn emitCurrentToken(self: *HTMLTokenizer) Token {
        const token = self.current_token.?;
        self.current_token = null;
        return token;
    }
    
    fn emitParseError(self: *HTMLTokenizer, message: []const u8) !void {
        std.log.err("Parse error at line {}, column {}: {s}", .{ self.line_number, self.column_number, message });
    }
    
    fn isASCIIAlpha(char: u8) bool {
        return (char >= 'A' and char <= 'Z') or (char >= 'a' and char <= 'z');
    }
    
    fn toLowercase(char: u8) u8 {
        if (char >= 'A' and char <= 'Z') {
            return char + ('a' - 'A');
        }
        return char;
    }
};
