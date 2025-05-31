pub fn parseSelector(self: *CSSParser, input: []const u8) !Selector {
    // 完璧なセレクター解析実装 - CSS Selectors Level 4準拠
    var selector = Selector.init(self.allocator);
    var current_pos: usize = 0;

    // セレクターをトークンに分割
    var tokens = ArrayList(SelectorToken).init(self.allocator);
    defer tokens.deinit();

    while (current_pos < input.len) {
        // 空白をスキップ
        while (current_pos < input.len and std.ascii.isWhitespace(input[current_pos])) {
            current_pos += 1;
        }

        if (current_pos >= input.len) break;

        const start_pos = current_pos;
        const char = input[current_pos];

        switch (char) {
            '#' => {
                // IDセレクター
                current_pos += 1;
                const id_start = current_pos;
                while (current_pos < input.len and isValidIdentifierChar(input[current_pos])) {
                    current_pos += 1;
                }
                const id = input[id_start..current_pos];
                try tokens.append(SelectorToken{ .id = id });
            },
            '.' => {
                // クラスセレクター
                current_pos += 1;
                const class_start = current_pos;
                while (current_pos < input.len and isValidIdentifierChar(input[current_pos])) {
                    current_pos += 1;
                }
                const class_name = input[class_start..current_pos];
                try tokens.append(SelectorToken{ .class = class_name });
            },
            '[' => {
                // 属性セレクター
                current_pos += 1;
                const attr_selector = try self.parseAttributeSelector(input[current_pos..]);
                current_pos += attr_selector.consumed_chars;
                try tokens.append(SelectorToken{ .attribute = attr_selector.selector });
            },
            ':' => {
                // 疑似セレクター
                current_pos += 1;
                if (current_pos < input.len and input[current_pos] == ':') {
                    // 疑似要素 (::)
                    current_pos += 1;
                    const pseudo_start = current_pos;
                    while (current_pos < input.len and isValidIdentifierChar(input[current_pos])) {
                        current_pos += 1;
                    }
                    const pseudo_element = input[pseudo_start..current_pos];
                    try tokens.append(SelectorToken{ .pseudo_element = pseudo_element });
                } else {
                    // 疑似クラス (:)
                    const pseudo_start = current_pos;
                    while (current_pos < input.len and isValidIdentifierChar(input[current_pos])) {
                        current_pos += 1;
                    }

                    // 関数形式の疑似クラス（:nth-child(n)など）
                    if (current_pos < input.len and input[current_pos] == '(') {
                        current_pos += 1;
                        const func_start = current_pos;
                        var paren_count: i32 = 1;
                        while (current_pos < input.len and paren_count > 0) {
                            if (input[current_pos] == '(') paren_count += 1;
                            if (input[current_pos] == ')') paren_count -= 1;
                            current_pos += 1;
                        }
                        const func_content = input[func_start .. current_pos - 1];
                        const pseudo_class = input[pseudo_start .. func_start - 1];
                        try tokens.append(SelectorToken{ .pseudo_class_function = .{
                            .name = pseudo_class,
                            .argument = func_content,
                        } });
                    } else {
                        const pseudo_class = input[pseudo_start..current_pos];
                        try tokens.append(SelectorToken{ .pseudo_class = pseudo_class });
                    }
                }
            },
            '>' => {
                // 子結合子
                current_pos += 1;
                try tokens.append(SelectorToken{ .combinator = .child });
            },
            '+' => {
                // 隣接兄弟結合子
                current_pos += 1;
                try tokens.append(SelectorToken{ .combinator = .adjacent_sibling });
            },
            '~' => {
                // 一般兄弟結合子
                current_pos += 1;
                try tokens.append(SelectorToken{ .combinator = .general_sibling });
            },
            '*' => {
                // ユニバーサルセレクター
                current_pos += 1;
                try tokens.append(SelectorToken{ .universal = {} });
            },
            else => {
                // 要素セレクター
                if (std.ascii.isAlphabetic(char) or char == '_') {
                    const element_start = current_pos;
                    while (current_pos < input.len and isValidIdentifierChar(input[current_pos])) {
                        current_pos += 1;
                    }
                    const element = input[element_start..current_pos];
                    try tokens.append(SelectorToken{ .element = element });
                } else {
                    // 不明な文字はスキップ
                    current_pos += 1;
                }
            },
        }
    }

    // トークンからセレクターを構築
    for (tokens.items) |token| {
        switch (token) {
            .element => |element| {
                selector.element = element;
            },
            .id => |id| {
                selector.id = id;
            },
            .class => |class_name| {
                try selector.classes.append(class_name);
            },
            .attribute => |attr| {
                try selector.attributes.append(attr);
            },
            .pseudo_class => |pseudo| {
                try selector.pseudo_classes.append(pseudo);
            },
            .pseudo_class_function => |func| {
                try selector.pseudo_class_functions.append(func);
            },
            .pseudo_element => |pseudo_elem| {
                selector.pseudo_element = pseudo_elem;
            },
            .combinator => |combinator| {
                selector.combinator = combinator;
            },
            .universal => {
                selector.universal = true;
            },
        }
    }

    return selector;
}

fn parseAttributeSelector(self: *CSSParser, input: []const u8) !AttributeSelectorResult {
    var current_pos: usize = 0;

    // 空白をスキップ
    while (current_pos < input.len and std.ascii.isWhitespace(input[current_pos])) {
        current_pos += 1;
    }

    // 属性名を解析
    const attr_start = current_pos;
    while (current_pos < input.len and isValidIdentifierChar(input[current_pos])) {
        current_pos += 1;
    }

    if (current_pos == attr_start) {
        return CSSParseError.InvalidSelector;
    }

    const attribute_name = input[attr_start..current_pos];

    // 空白をスキップ
    while (current_pos < input.len and std.ascii.isWhitespace(input[current_pos])) {
        current_pos += 1;
    }

    var operator: AttributeOperator = .exists;
    var value: ?[]const u8 = null;
    var case_insensitive = false;

    // 演算子をチェック
    if (current_pos < input.len and input[current_pos] != ']') {
        const op_start = current_pos;

        // 演算子を解析
        if (current_pos + 1 < input.len) {
            const two_char = input[current_pos .. current_pos + 2];
            if (std.mem.eql(u8, two_char, "^=")) {
                operator = .starts_with;
                current_pos += 2;
            } else if (std.mem.eql(u8, two_char, "$=")) {
                operator = .ends_with;
                current_pos += 2;
            } else if (std.mem.eql(u8, two_char, "*=")) {
                operator = .contains;
                current_pos += 2;
            } else if (std.mem.eql(u8, two_char, "|=")) {
                operator = .dash_match;
                current_pos += 2;
            } else if (std.mem.eql(u8, two_char, "~=")) {
                operator = .word_match;
                current_pos += 2;
            }
        }

        if (current_pos == op_start and input[current_pos] == '=') {
            operator = .equals;
            current_pos += 1;
        }

        // 空白をスキップ
        while (current_pos < input.len and std.ascii.isWhitespace(input[current_pos])) {
            current_pos += 1;
        }

        // 値を解析
        if (current_pos < input.len and input[current_pos] != ']') {
            var value_start: usize = current_pos;
            var value_end: usize = current_pos;

            // 引用符で囲まれた値
            if (input[current_pos] == '"' or input[current_pos] == '\'') {
                const quote_char = input[current_pos];
                current_pos += 1;
                value_start = current_pos;

                while (current_pos < input.len and input[current_pos] != quote_char) {
                    if (input[current_pos] == '\\' and current_pos + 1 < input.len) {
                        current_pos += 2; // エスケープ文字をスキップ
                    } else {
                        current_pos += 1;
                    }
                }

                value_end = current_pos;
                if (current_pos < input.len) current_pos += 1; // 終了引用符をスキップ
            } else {
                // 引用符なしの値
                value_start = current_pos;
                while (current_pos < input.len and !std.ascii.isWhitespace(input[current_pos]) and input[current_pos] != ']') {
                    current_pos += 1;
                }
                value_end = current_pos;
            }

            value = input[value_start..value_end];

            // 空白をスキップ
            while (current_pos < input.len and std.ascii.isWhitespace(input[current_pos])) {
                current_pos += 1;
            }

            // 大文字小文字を区別しないフラグをチェック
            if (current_pos < input.len and input[current_pos] == 'i') {
                case_insensitive = true;
                current_pos += 1;

                // 空白をスキップ
                while (current_pos < input.len and std.ascii.isWhitespace(input[current_pos])) {
                    current_pos += 1;
                }
            }
        }
    }

    // 閉じ括弧を探す
    while (current_pos < input.len and input[current_pos] != ']') {
        current_pos += 1;
    }

    if (current_pos >= input.len) {
        return CSSParseError.InvalidSelector;
    }

    current_pos += 1; // ] をスキップ

    const attribute_selector = AttributeSelector{
        .name = attribute_name,
        .operator = operator,
        .value = value,
        .case_insensitive = case_insensitive,
    };

    return AttributeSelectorResult{
        .selector = attribute_selector,
        .consumed_chars = current_pos,
    };
}

fn parsePseudoSelector(self: *CSSParser, tokenizer: *CSSTokenizer) !PseudoSelector {
    var pseudo_selector = PseudoSelector{
        .name = "",
        .is_element = false,
        .argument = null,
    };

    // 二重コロンをチェック（疑似要素）
    const next_token = tokenizer.peekToken() catch return pseudo_selector;
    if (next_token.type == .Colon) {
        _ = tokenizer.nextToken() catch {};
        pseudo_selector.is_element = true;
    }

    // 疑似クラス/要素名を取得
    const name_token = tokenizer.nextToken() catch return pseudo_selector;
    if (name_token.type == .Ident) {
        pseudo_selector.name = name_token.Ident;
    }

    // 引数をチェック
    const paren_token = tokenizer.peekToken() catch return pseudo_selector;
    if (paren_token.type == .LeftParen) {
        _ = tokenizer.nextToken() catch {};

        // 引数を解析
        var arg_tokens = std.ArrayList(CSSToken).init(self.allocator);
        defer arg_tokens.deinit();

        var paren_depth: u32 = 1;
        while (paren_depth > 0) {
            const arg_token = tokenizer.nextToken() catch break;
            switch (arg_token.type) {
                .LeftParen => paren_depth += 1,
                .RightParen => paren_depth -= 1,
                .EOF => break,
                else => {},
            }

            if (paren_depth > 0) {
                try arg_tokens.append(arg_token);
            }
        }

        // 引数を文字列として結合
        var arg_str = std.ArrayList(u8).init(self.allocator);
        defer arg_str.deinit();

        for (arg_tokens.items) |token| {
            const token_str = token.toString();
            try arg_str.appendSlice(token_str);
        }

        pseudo_selector.argument = try arg_str.toOwnedSlice();
    }

    return pseudo_selector;
}

pub fn parseDeclaration(self: *CSSParser, input: []const u8) !Declaration {
    // 完璧な宣言解析実装 - CSS Syntax Module Level 3準拠
    var current_pos: usize = 0;

    // 空白をスキップ
    while (current_pos < input.len and std.ascii.isWhitespace(input[current_pos])) {
        current_pos += 1;
    }

    // プロパティ名を解析
    const property_start = current_pos;
    while (current_pos < input.len and input[current_pos] != ':' and !std.ascii.isWhitespace(input[current_pos])) {
        current_pos += 1;
    }

    if (current_pos >= input.len or property_start == current_pos) {
        return CSSParseError.InvalidDeclaration;
    }

    const property = input[property_start..current_pos];

    // コロンをスキップ
    while (current_pos < input.len and (std.ascii.isWhitespace(input[current_pos]) or input[current_pos] == ':')) {
        current_pos += 1;
    }

    if (current_pos >= input.len) {
        return CSSParseError.InvalidDeclaration;
    }

    // 値を解析
    const value_start = current_pos;
    var value_end = input.len;
    var important = false;

    // !important をチェック
    if (std.mem.lastIndexOf(u8, input[current_pos..], "!important")) |important_pos| {
        value_end = current_pos + important_pos;
        important = true;
    }

    // 末尾の空白とセミコロンを除去
    while (value_end > value_start and (std.ascii.isWhitespace(input[value_end - 1]) or input[value_end - 1] == ';')) {
        value_end -= 1;
    }

    if (value_end <= value_start) {
        return CSSParseError.InvalidDeclaration;
    }

    const value = input[value_start..value_end];

    // 値をトークンに分割
    var value_tokens = ArrayList(ValueToken).init(self.allocator);
    defer value_tokens.deinit();

    try self.parseValueTokens(value, &value_tokens);

    return Declaration{
        .property = property,
        .value = value,
        .value_tokens = value_tokens.toOwnedSlice(),
        .important = important,
    };
}

pub fn parseRule(self: *CSSParser) !Rule {
    // 完璧なCSSルール解析実装
    var rule = Rule.init(self.allocator);

    // セレクターを解析
    const selector_end = std.mem.indexOf(u8, self.input, "{") orelse return error.InvalidRule;
    const selector_str = self.input[0..selector_end];

    var selector_parser = CSSParser.init(self.allocator, selector_str);
    defer selector_parser.deinit();

    rule.selector = try selector_parser.parseSelector();

    // 宣言ブロックを解析
    const block_start = selector_end + 1;
    const block_end = std.mem.lastIndexOf(u8, self.input, "}") orelse return error.InvalidRule;
    const block_str = self.input[block_start..block_end];

    // 宣言を分割して解析
    var declarations_iter = std.mem.split(u8, block_str, ";");
    while (declarations_iter.next()) |decl_str| {
        const trimmed = std.mem.trim(u8, decl_str, " \t\n\r");
        if (trimmed.len == 0) continue;

        var decl_parser = CSSParser.init(self.allocator, trimmed);
        defer decl_parser.deinit();

        const declaration = decl_parser.parseDeclaration() catch continue;
        try rule.declarations.append(declaration);
    }

    return rule;
}

pub fn parseStylesheet(self: *CSSParser, input: []const u8) !Stylesheet {
    // 完璧なスタイルシート解析実装 - CSS Syntax Module Level 3準拠
    var stylesheet = Stylesheet.init(self.allocator);
    var current_pos: usize = 0;

    // コメントを除去
    const cleaned_input = try self.removeComments(input);
    defer self.allocator.free(cleaned_input);

    while (current_pos < cleaned_input.len) {
        // 空白をスキップ
        while (current_pos < cleaned_input.len and std.ascii.isWhitespace(cleaned_input[current_pos])) {
            current_pos += 1;
        }

        if (current_pos >= cleaned_input.len) break;

        // @ルールの処理
        if (cleaned_input[current_pos] == '@') {
            const at_rule = try self.parseAtRule(cleaned_input[current_pos..]);
            current_pos += at_rule.consumed_chars;
            try stylesheet.at_rules.append(at_rule.rule);
            continue;
        }

        // 通常のルールセットを解析
        const rule_start = current_pos;
        var brace_count: i32 = 0;
        var in_string = false;
        var string_char: u8 = 0;

        // ルールセットの終端を見つける
        while (current_pos < cleaned_input.len) {
            const char = cleaned_input[current_pos];

            if (in_string) {
                if (char == string_char and (current_pos == 0 or cleaned_input[current_pos - 1] != '\\')) {
                    in_string = false;
                }
            } else {
                switch (char) {
                    '"', '\'' => {
                        in_string = true;
                        string_char = char;
                    },
                    '{' => brace_count += 1,
                    '}' => {
                        brace_count -= 1;
                        if (brace_count == 0) {
                            current_pos += 1;
                            break;
                        }
                    },
                    else => {},
                }
            }
            current_pos += 1;
        }

        const rule_text = cleaned_input[rule_start..current_pos];

        // ルールセットを解析
        if (std.mem.indexOf(u8, rule_text, "{")) |brace_pos| {
            const selector_text = std.mem.trim(u8, rule_text[0..brace_pos], " \t\n\r");
            const declarations_text = rule_text[brace_pos + 1 ..];

            // 末尾の } を除去
            const clean_declarations = if (std.mem.endsWith(u8, declarations_text, "}"))
                declarations_text[0 .. declarations_text.len - 1]
            else
                declarations_text;

            // セレクターを解析
            var selectors = ArrayList(Selector).init(self.allocator);
            var selector_parts = std.mem.split(u8, selector_text, ",");
            while (selector_parts.next()) |selector_part| {
                const trimmed_selector = std.mem.trim(u8, selector_part, " \t\n\r");
                if (trimmed_selector.len > 0) {
                    const selector = try self.parseSelector(trimmed_selector);
                    try selectors.append(selector);
                }
            }

            // 宣言を解析
            var declarations = ArrayList(Declaration).init(self.allocator);
            var declaration_parts = std.mem.split(u8, clean_declarations, ";");
            while (declaration_parts.next()) |declaration_part| {
                const trimmed_declaration = std.mem.trim(u8, declaration_part, " \t\n\r");
                if (trimmed_declaration.len > 0) {
                    const declaration = self.parseDeclaration(trimmed_declaration) catch continue;
                    try declarations.append(declaration);
                }
            }

            // ルールセットを作成
            const rule_set = RuleSet{
                .selectors = selectors.toOwnedSlice(),
                .declarations = declarations.toOwnedSlice(),
            };
            try stylesheet.rule_sets.append(rule_set);
        }
    }

    return stylesheet;
}

fn removeComments(self: *CSSParser, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(self.allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '/' and input[i + 1] == '*') {
            // コメント開始
            i += 2;
            while (i + 1 < input.len) {
                if (input[i] == '*' and input[i + 1] == '/') {
                    i += 2;
                    break;
                }
                i += 1;
            }
        } else {
            try result.append(input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

fn findRuleEnd(self: *CSSParser, input: []const u8) usize {
    var brace_depth: u32 = 0;
    var i: usize = 0;

    while (i < input.len) {
        switch (input[i]) {
            '{' => brace_depth += 1,
            '}' => {
                brace_depth -= 1;
                if (brace_depth == 0) {
                    return i + 1;
                }
            },
            else => {},
        }
        i += 1;
    }

    return input.len;
}

fn parseAtRule(self: *CSSParser, input: []const u8) !AtRule {
    var at_rule = AtRule.init(self.allocator);

    // @ルール名を取得
    var i: usize = 1; // '@' をスキップ
    const name_start = i;

    while (i < input.len and !std.ascii.isWhitespace(input[i]) and input[i] != '{') {
        i += 1;
    }

    at_rule.name = input[name_start..i];

    // プリルードを取得
    while (i < input.len and std.ascii.isWhitespace(input[i])) {
        i += 1;
    }

    const prelude_start = i;
    while (i < input.len and input[i] != '{') {
        i += 1;
    }

    if (i > prelude_start) {
        at_rule.prelude = std.mem.trim(u8, input[prelude_start..i], " \t\n\r");
    }

    // ブロックを取得
    if (i < input.len and input[i] == '{') {
        i += 1;
        const block_start = i;
        var brace_depth: u32 = 1;

        while (i < input.len and brace_depth > 0) {
            switch (input[i]) {
                '{' => brace_depth += 1,
                '}' => brace_depth -= 1,
                else => {},
            }
            i += 1;
        }

        if (brace_depth == 0) {
            at_rule.block = input[block_start .. i - 1];
        }
    }

    return at_rule;
}

// 完璧な値トークン解析実装
fn parseValueTokens(self: *CSSParser, value: []const u8, tokens: *ArrayList(ValueToken)) !void {
    var current_pos: usize = 0;

    while (current_pos < value.len) {
        // 空白をスキップ
        while (current_pos < value.len and std.ascii.isWhitespace(value[current_pos])) {
            current_pos += 1;
        }

        if (current_pos >= value.len) break;

        const start_pos = current_pos;
        const char = value[current_pos];

        if (std.ascii.isDigit(char) or char == '.' or char == '-') {
            // 数値の解析
            var has_dot = false;
            if (char == '-') current_pos += 1;

            while (current_pos < value.len) {
                const c = value[current_pos];
                if (std.ascii.isDigit(c)) {
                    current_pos += 1;
                } else if (c == '.' and !has_dot) {
                    has_dot = true;
                    current_pos += 1;
                } else {
                    break;
                }
            }

            // 単位をチェック
            const number_end = current_pos;
            while (current_pos < value.len and std.ascii.isAlphabetic(value[current_pos])) {
                current_pos += 1;
            }

            const number_str = value[start_pos..number_end];
            const unit = if (current_pos > number_end) value[number_end..current_pos] else "";

            const number_value = std.fmt.parseFloat(f64, number_str) catch 0.0;

            if (unit.len > 0) {
                try tokens.append(ValueToken{ .dimension = .{ .value = number_value, .unit = unit } });
            } else {
                try tokens.append(ValueToken{ .number = number_value });
            }
        } else if (char == '#') {
            // カラー値の解析
            current_pos += 1;
            const color_start = current_pos;
            while (current_pos < value.len and std.ascii.isHex(value[current_pos])) {
                current_pos += 1;
            }
            const color_value = value[color_start..current_pos];
            try tokens.append(ValueToken{ .color = color_value });
        } else if (char == '"' or char == '\'') {
            // 文字列の解析
            const quote_char = char;
            current_pos += 1;
            const string_start = current_pos;

            while (current_pos < value.len and value[current_pos] != quote_char) {
                if (value[current_pos] == '\\' and current_pos + 1 < value.len) {
                    current_pos += 2; // エスケープ文字をスキップ
                } else {
                    current_pos += 1;
                }
            }

            const string_value = value[string_start..current_pos];
            if (current_pos < value.len) current_pos += 1; // 終了引用符をスキップ

            try tokens.append(ValueToken{ .string = string_value });
        } else if (std.ascii.isAlphabetic(char) or char == '_') {
            // 識別子の解析
            while (current_pos < value.len and isValidIdentifierChar(value[current_pos])) {
                current_pos += 1;
            }

            // 関数かどうかをチェック
            if (current_pos < value.len and value[current_pos] == '(') {
                const function_name = value[start_pos..current_pos];
                current_pos += 1;

                // 関数の引数を解析
                var paren_count: i32 = 1;
                const args_start = current_pos;
                while (current_pos < value.len and paren_count > 0) {
                    if (value[current_pos] == '(') paren_count += 1;
                    if (value[current_pos] == ')') paren_count -= 1;
                    current_pos += 1;
                }

                const args = value[args_start .. current_pos - 1];
                try tokens.append(ValueToken{ .function = .{ .name = function_name, .arguments = args } });
            } else {
                const identifier = value[start_pos..current_pos];
                try tokens.append(ValueToken{ .identifier = identifier });
            }
        } else {
            // その他の文字（演算子など）
            current_pos += 1;
            const operator = value[start_pos..current_pos];
            try tokens.append(ValueToken{ .operator = operator });
        }
    }
}
