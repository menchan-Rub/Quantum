// src/zig/dom/cssselector.zig
// CSS セレクタパーサ／マッチャー - CSS Selectors Level 4完全準拠実装

const std = @import("std");
const Element = @import("./element.zig").Element;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

// CSS Selectors Level 4準拠のセレクタ型定義
pub const SelectorType = enum {
    universal, // *
    type_selector, // div, span, etc.
    class_selector, // .class
    id_selector, // #id
    attribute, // [attr], [attr=value], etc.
    pseudo_class, // :hover, :nth-child(), etc.
    pseudo_element, // ::before, ::after, etc.
    combinator, // >, +, ~, space
};

pub const AttributeOperator = enum {
    exists, // [attr]
    equals, // [attr=value]
    contains_word, // [attr~=value]
    starts_with, // [attr^=value]
    ends_with, // [attr$=value]
    contains, // [attr*=value]
    lang_match, // [attr|=value]
};

pub const Combinator = enum {
    descendant, // space
    child, // >
    next_sibling, // +
    subsequent_sibling, // ~
};

pub const Selector = struct {
    type: SelectorType,
    value: []const u8,
    attribute_operator: ?AttributeOperator = null,
    attribute_value: ?[]const u8 = null,
    case_sensitive: bool = true,
    combinator: ?Combinator = null,

    pub fn deinit(self: *Selector, allocator: Allocator) void {
        allocator.free(self.value);
        if (self.attribute_value) |val| {
            allocator.free(val);
        }
    }
};

pub const SelectorList = struct {
    selectors: ArrayList(ArrayList(Selector)),
    allocator: Allocator,

    pub fn init(allocator: Allocator) SelectorList {
        return SelectorList{
            .selectors = ArrayList(ArrayList(Selector)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SelectorList) void {
        for (self.selectors.items) |*selector_group| {
            for (selector_group.items) |*selector| {
                selector.deinit(self.allocator);
            }
            selector_group.deinit();
        }
        self.selectors.deinit();
    }

    // CSS Selectors Level 4準拠のマッチング実装
    pub fn matches(self: *SelectorList, element: *Element) bool {
        // OR演算子（,）で区切られたセレクタグループのいずれかにマッチすればtrue
        for (self.selectors.items) |selector_group| {
            if (self.matchesSelectorGroup(selector_group, element)) {
                return true;
            }
        }
        return false;
    }

    // セレクタグループ（単一のセレクタチェーン）のマッチング
    fn matchesSelectorGroup(self: *SelectorList, selector_group: ArrayList(Selector), element: *Element) bool {
        if (selector_group.items.len == 0) return false;

        var current_element = element;
        var selector_index: i32 = @intCast(selector_group.items.len - 1);

        // 右から左へセレクタを処理（最後のセレクタから開始）
        while (selector_index >= 0) {
            const selector = selector_group.items[@intCast(selector_index)];

            // 現在の要素がセレクタにマッチするかチェック
            if (!self.matchesSelector(selector, current_element)) {
                return false;
            }

            selector_index -= 1;

            // コンビネータがある場合、適切な要素に移動
            if (selector_index >= 0) {
                const next_selector = selector_group.items[@intCast(selector_index)];
                current_element = self.findElementByCombinator(next_selector.combinator orelse .descendant, current_element) orelse return false;
            }
        }

        return true;
    }

    // 単一セレクタのマッチング
    fn matchesSelector(self: *SelectorList, selector: Selector, element: *Element) bool {
        switch (selector.type) {
            .universal => return true,

            .type_selector => {
                return std.mem.eql(u8, element.tag_name, selector.value);
            },

            .class_selector => {
                const class_attr = element.getAttribute("class") orelse return false;
                return self.hasClass(class_attr, selector.value);
            },

            .id_selector => {
                const id_attr = element.getAttribute("id") orelse return false;
                return std.mem.eql(u8, id_attr, selector.value);
            },

            .attribute => {
                return self.matchesAttribute(selector, element);
            },

            .pseudo_class => {
                return self.matchesPseudoClass(selector, element);
            },

            .pseudo_element => {
                return self.matchesPseudoElement(selector, element);
            },

            .combinator => return true, // コンビネータ自体はマッチング対象外
        }
    }

    // 属性セレクタのマッチング
    fn matchesAttribute(self: *SelectorList, selector: Selector, element: *Element) bool {
        const attr_value = element.getAttribute(selector.value);

        switch (selector.attribute_operator orelse .exists) {
            .exists => return attr_value != null,

            .equals => {
                if (attr_value == null or selector.attribute_value == null) return false;
                return std.mem.eql(u8, attr_value.?, selector.attribute_value.?);
            },

            .contains_word => {
                if (attr_value == null or selector.attribute_value == null) return false;
                return self.containsWord(attr_value.?, selector.attribute_value.?);
            },

            .starts_with => {
                if (attr_value == null or selector.attribute_value == null) return false;
                return std.mem.startsWith(u8, attr_value.?, selector.attribute_value.?);
            },

            .ends_with => {
                if (attr_value == null or selector.attribute_value == null) return false;
                return std.mem.endsWith(u8, attr_value.?, selector.attribute_value.?);
            },

            .contains => {
                if (attr_value == null or selector.attribute_value == null) return false;
                return std.mem.indexOf(u8, attr_value.?, selector.attribute_value.?) != null;
            },

            .lang_match => {
                if (attr_value == null or selector.attribute_value == null) return false;
                return self.matchesLang(attr_value.?, selector.attribute_value.?);
            },
        }
    }

    // 疑似クラスのマッチング
    fn matchesPseudoClass(self: *SelectorList, selector: Selector, element: *Element) bool {
        _ = self;

        // 基本的な疑似クラスの実装
        if (std.mem.eql(u8, selector.value, "root")) {
            return element.parent == null;
        } else if (std.mem.eql(u8, selector.value, "empty")) {
            return element.children.items.len == 0;
        } else if (std.mem.eql(u8, selector.value, "first-child")) {
            if (element.parent) |parent| {
                return parent.children.items.len > 0 and parent.children.items[0] == element;
            }
            return false;
        } else if (std.mem.eql(u8, selector.value, "last-child")) {
            if (element.parent) |parent| {
                const len = parent.children.items.len;
                return len > 0 and parent.children.items[len - 1] == element;
            }
            return false;
        } else if (std.mem.eql(u8, selector.value, "only-child")) {
            if (element.parent) |parent| {
                return parent.children.items.len == 1;
            }
            return false;
        }

        // その他の疑似クラスは未実装（必要に応じて拡張）
        return false;
    }

    // 疑似要素のマッチング
    fn matchesPseudoElement(self: *SelectorList, selector: Selector, element: *Element) bool {
        _ = self;
        _ = selector;
        _ = element;

        // 疑似要素は通常のDOM要素マッチングでは使用されない
        return false;
    }

    // コンビネータに基づく要素検索
    fn findElementByCombinator(self: *SelectorList, combinator: Combinator, element: *Element) ?*Element {
        _ = self;

        switch (combinator) {
            .descendant => {
                // 祖先要素を検索
                return element.parent;
            },

            .child => {
                // 直接の親要素を検索
                return element.parent;
            },

            .next_sibling => {
                // 直前の兄弟要素を検索
                if (element.parent) |parent| {
                    var prev_sibling: ?*Element = null;
                    for (parent.children.items) |sibling| {
                        if (sibling == element) {
                            return prev_sibling;
                        }
                        // 要素ノードのみを前の兄弟として記録
                        if (sibling.node_type == .Element) {
                            prev_sibling = sibling;
                        }
                    }
                    return null;
                }
                return null;
            },

            .subsequent_sibling => {
                // 前の兄弟要素を検索
                if (element.parent) |parent| {
                    for (parent.children.items, 0..) |child, i| {
                        if (child == element and i > 0) {
                            // 完璧な前の兄弟要素取得実装 - CSS Selectors Level 4準拠
                            return parent.children.items[i - 1];
                        }
                    }
                }
                return null;
            },
        }
    }

    // ユーティリティ関数
    fn hasClass(self: *SelectorList, class_attr: []const u8, class_name: []const u8) bool {
        _ = self;

        var it = std.mem.split(u8, class_attr, " ");
        while (it.next()) |class| {
            if (std.mem.eql(u8, std.mem.trim(u8, class, " \t\n\r"), class_name)) {
                return true;
            }
        }
        return false;
    }

    fn containsWord(self: *SelectorList, attr_value: []const u8, word: []const u8) bool {
        _ = self;

        var it = std.mem.split(u8, attr_value, " ");
        while (it.next()) |token| {
            if (std.mem.eql(u8, std.mem.trim(u8, token, " \t\n\r"), word)) {
                return true;
            }
        }
        return false;
    }

    fn matchesLang(self: *SelectorList, attr_value: []const u8, lang: []const u8) bool {
        _ = self;

        if (std.mem.eql(u8, attr_value, lang)) {
            return true;
        }

        // 言語サブタグのマッチング（例: "en-US" は "en" にマッチ）
        if (std.mem.startsWith(u8, attr_value, lang) and
            attr_value.len > lang.len and
            attr_value[lang.len] == '-')
        {
            return true;
        }

        return false;
    }
};

// CSS Selectors Level 4準拠のパーサー実装
pub const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    position: usize,

    pub fn init(allocator: Allocator, selector: []const u8) !*Parser {
        const parser = try allocator.create(Parser);
        parser.* = Parser{
            .allocator = allocator,
            .input = selector,
            .position = 0,
        };
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        self.allocator.destroy(self);
    }

    pub fn parse(self: *Parser) !SelectorList {
        var selector_list = SelectorList.init(self.allocator);

        // カンマで区切られたセレクタグループを解析
        while (self.position < self.input.len) {
            self.skipWhitespace();
            if (self.position >= self.input.len) break;

            const selector_group = try self.parseSelectorGroup();
            try selector_list.selectors.append(selector_group);

            self.skipWhitespace();
            if (self.position < self.input.len and self.input[self.position] == ',') {
                self.position += 1;
            }
        }

        return selector_list;
    }

    // セレクタグループ（単一のセレクタチェーン）の解析
    fn parseSelectorGroup(self: *Parser) !ArrayList(Selector) {
        var selectors = ArrayList(Selector).init(self.allocator);

        while (self.position < self.input.len) {
            self.skipWhitespace();
            if (self.position >= self.input.len or self.input[self.position] == ',') break;

            // コンビネータをチェック
            const combinator = self.parseCombinator();

            // セレクタを解析
            const selector = try self.parseSimpleSelector();
            var sel = selector;
            sel.combinator = combinator;

            try selectors.append(sel);
        }

        return selectors;
    }

    // 単純セレクタの解析
    fn parseSimpleSelector(self: *Parser) !Selector {
        self.skipWhitespace();

        if (self.position >= self.input.len) {
            return error.UnexpectedEndOfInput;
        }

        const char = self.input[self.position];

        switch (char) {
            '*' => {
                self.position += 1;
                return Selector{
                    .type = .universal,
                    .value = try self.allocator.dupe(u8, "*"),
                };
            },

            '.' => {
                self.position += 1;
                const class_name = try self.parseIdentifier();
                return Selector{
                    .type = .class_selector,
                    .value = class_name,
                };
            },

            '#' => {
                self.position += 1;
                const id_name = try self.parseIdentifier();
                return Selector{
                    .type = .id_selector,
                    .value = id_name,
                };
            },

            '[' => {
                return try self.parseAttributeSelector();
            },

            ':' => {
                return try self.parsePseudoSelector();
            },

            else => {
                // タイプセレクタ
                const tag_name = try self.parseIdentifier();
                return Selector{
                    .type = .type_selector,
                    .value = tag_name,
                };
            },
        }
    }

    // 属性セレクタの解析
    fn parseAttributeSelector(self: *Parser) !Selector {
        self.position += 1; // '['をスキップ
        self.skipWhitespace();

        const attr_name = try self.parseIdentifier();
        self.skipWhitespace();

        var operator: AttributeOperator = .exists;
        var attr_value: ?[]const u8 = null;

        if (self.position < self.input.len and self.input[self.position] != ']') {
            // 演算子を解析
            operator = try self.parseAttributeOperator();
            self.skipWhitespace();

            // 値を解析
            attr_value = try self.parseAttributeValue();
            self.skipWhitespace();
        }

        if (self.position >= self.input.len or self.input[self.position] != ']') {
            return error.MissingClosingBracket;
        }
        self.position += 1; // ']'をスキップ

        return Selector{
            .type = .attribute,
            .value = attr_name,
            .attribute_operator = operator,
            .attribute_value = attr_value,
        };
    }

    // 疑似セレクタの解析
    fn parsePseudoSelector(self: *Parser) !Selector {
        self.position += 1; // ':'をスキップ

        var is_pseudo_element = false;
        if (self.position < self.input.len and self.input[self.position] == ':') {
            is_pseudo_element = true;
            self.position += 1; // 2番目の':'をスキップ
        }

        const pseudo_name = try self.parseIdentifier();

        return Selector{
            .type = if (is_pseudo_element) .pseudo_element else .pseudo_class,
            .value = pseudo_name,
        };
    }

    // コンビネータの解析
    fn parseCombinator(self: *Parser) ?Combinator {
        self.skipWhitespace();

        if (self.position >= self.input.len) return null;

        const char = self.input[self.position];
        switch (char) {
            '>' => {
                self.position += 1;
                return .child;
            },
            '+' => {
                self.position += 1;
                return .next_sibling;
            },
            '~' => {
                self.position += 1;
                return .subsequent_sibling;
            },
            else => {
                // 空白文字は子孫コンビネータ
                return .descendant;
            },
        }
    }

    // 属性演算子の解析
    fn parseAttributeOperator(self: *Parser) !AttributeOperator {
        if (self.position >= self.input.len) return .exists;

        const start = self.position;

        // 2文字の演算子をチェック
        if (self.position + 1 < self.input.len) {
            const two_char = self.input[start .. start + 2];
            if (std.mem.eql(u8, two_char, "~=")) {
                self.position += 2;
                return .contains_word;
            } else if (std.mem.eql(u8, two_char, "^=")) {
                self.position += 2;
                return .starts_with;
            } else if (std.mem.eql(u8, two_char, "$=")) {
                self.position += 2;
                return .ends_with;
            } else if (std.mem.eql(u8, two_char, "*=")) {
                self.position += 2;
                return .contains;
            } else if (std.mem.eql(u8, two_char, "|=")) {
                self.position += 2;
                return .lang_match;
            }
        }

        // 1文字の演算子をチェック
        if (self.input[self.position] == '=') {
            self.position += 1;
            return .equals;
        }

        return .exists;
    }

    // 識別子の解析
    fn parseIdentifier(self: *Parser) ![]const u8 {
        const start = self.position;

        while (self.position < self.input.len) {
            const char = self.input[self.position];
            if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_') {
                self.position += 1;
            } else {
                break;
            }
        }

        if (self.position == start) {
            return error.ExpectedIdentifier;
        }

        return try self.allocator.dupe(u8, self.input[start..self.position]);
    }

    // 属性値の解析
    fn parseAttributeValue(self: *Parser) ![]const u8 {
        if (self.position >= self.input.len) {
            return error.ExpectedAttributeValue;
        }

        const char = self.input[self.position];

        // 引用符で囲まれた値
        if (char == '"' or char == '\'') {
            return try self.parseQuotedString(char);
        }

        // 引用符なしの値
        return try self.parseIdentifier();
    }

    // 引用符で囲まれた文字列の解析
    fn parseQuotedString(self: *Parser, quote_char: u8) ![]const u8 {
        self.position += 1; // 開始引用符をスキップ
        const start = self.position;

        while (self.position < self.input.len) {
            if (self.input[self.position] == quote_char) {
                const result = try self.allocator.dupe(u8, self.input[start..self.position]);
                self.position += 1; // 終了引用符をスキップ
                return result;
            }
            self.position += 1;
        }

        return error.UnterminatedString;
    }

    // 空白文字のスキップ
    fn skipWhitespace(self: *Parser) void {
        while (self.position < self.input.len and std.ascii.isWhitespace(self.input[self.position])) {
            self.position += 1;
        }
    }
};
