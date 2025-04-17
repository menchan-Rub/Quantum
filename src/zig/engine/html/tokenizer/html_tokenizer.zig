const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// HTMLトークンの種類を定義
pub const TokenType = enum {
    DOCTYPE,
    StartTag,
    EndTag,
    Comment,
    Character,
    EOF,
    WhiteSpace,
    Error,
};

// 属性を表す構造体
pub const Attribute = struct {
    name: []const u8,
    value: ?[]const u8,

    pub fn init(name: []const u8, value: ?[]const u8) Attribute {
        return Attribute{
            .name = name,
            .value = value,
        };
    }
};

// HTMLトークンを表す構造体
pub const Token = struct {
    token_type: TokenType,
    data: union(enum) {
        doctype: struct {
            name: ?[]const u8,
            public_identifier: ?[]const u8,
            system_identifier: ?[]const u8,
            force_quirks: bool,
        },
        tag: struct {
            name: []const u8,
            self_closing: bool,
            attributes: std.ArrayList(Attribute),
        },
        comment: []const u8,
        character: []const u8,
        error: []const u8,
        whitespace: []const u8,
        eof: void,
    },

    pub fn deinit(self: *Token, allocator: *Allocator) void {
        switch (self.data) {
            .tag => |*tag| {
                tag.attributes.deinit();
            },
            else => {},
        }
    }
};

// トークナイザーの状態を表す列挙型
const State = enum {
    Data,
    TagOpen,
    EndTagOpen,
    TagName,
    BeforeAttributeName,
    AttributeName,
    AfterAttributeName,
    BeforeAttributeValue,
    AttributeValueDoubleQuoted,
    AttributeValueSingleQuoted,
    AttributeValueUnquoted,
    AfterAttributeValueQuoted,
    SelfClosingStartTag,
    BogusComment,
    MarkupDeclarationOpen,
    CommentStart,
    CommentStartDash,
    Comment,
    CommentEndDash,
    CommentEnd,
    CommentEndBang,
    DOCTYPE,
    BeforeDOCTYPEName,
    DOCTYPEName,
    AfterDOCTYPEName,
    AfterDOCTYPEPublicKeyword,
    BeforeDOCTYPEPublicIdentifier,
    DOCTYPEPublicIdentifier,
    AfterDOCTYPEPublicIdentifier,
    AfterDOCTYPESystemKeyword,
    BeforeDOCTYPESystemIdentifier,
    DOCTYPESystemIdentifier,
    AfterDOCTYPESystemIdentifier,
    BogusDOCTYPE,
    CDATASection,
    CDATASectionBracket,
    CDATASectionEnd,
};

// トークナイザー本体
pub const HTMLTokenizer = struct {
    allocator: *Allocator,
    input: []const u8,
    position: usize,
    current_state: State,
    current_token: ?Token,
    return_state: State,
    temporary_buffer: std.ArrayList(u8),
    attribute_name_start: usize,
    attribute_name_end: usize,
    attribute_value_start: usize,
    attribute_value_end: usize,
    emitted_tokens: std.ArrayList(Token),
    reconsume: bool,

    pub fn init(allocator: *Allocator, input: []const u8) !HTMLTokenizer {
        return HTMLTokenizer{
            .allocator = allocator,
            .input = input,
            .position = 0,
            .current_state = State.Data,
            .current_token = null,
            .return_state = State.Data,
            .temporary_buffer = std.ArrayList(u8).init(allocator),
            .attribute_name_start = 0,
            .attribute_name_end = 0,
            .attribute_value_start = 0,
            .attribute_value_end = 0,
            .emitted_tokens = std.ArrayList(Token).init(allocator),
            .reconsume = false,
        };
    }

    pub fn deinit(self: *HTMLTokenizer) void {
        self.temporary_buffer.deinit();
        for (self.emitted_tokens.items) |*token| {
            token.deinit(self.allocator);
        }
        self.emitted_tokens.deinit();
    }

    pub fn nextToken(self: *HTMLTokenizer) !?Token {
        // すでにエミットされたトークンがあれば返す
        if (self.emitted_tokens.items.len > 0) {
            const token = self.emitted_tokens.items[0];
            _ = self.emitted_tokens.orderedRemove(0);
            return token;
        }

        // EOFチェック
        if (self.position >= self.input.len) {
            return Token{
                .token_type = TokenType.EOF,
                .data = .{ .eof = {} },
            };
        }

        // トークン解析ループ
        while (self.position < self.input.len) {
            const c = self.input[self.position];
            
            if (!self.reconsume) {
                self.position += 1;
            } else {
                self.reconsume = false;
            }

            switch (self.current_state) {
                .Data => {
                    switch (c) {
                        '&' => {
                            self.return_state = State.Data;
                            // エンティティ解析は簡略化
                            try self.emitCharacter(&[_]u8{c});
                        },
                        '<' => {
                            self.current_state = State.TagOpen;
                        },
                        0 => {
                            try self.emitError("Unexpected NULL character");
                            try self.emitCharacter(&[_]u8{c});
                        },
                        else => {
                            if (c == '\t' or c == '\n' or c == '\f' or c == ' ') {
                                try self.emitWhitespace(&[_]u8{c});
                            } else {
                                try self.emitCharacter(&[_]u8{c});
                            }
                        },
                    }
                },
                .TagOpen => {
                    switch (c) {
                        '!' => {
                            self.current_state = State.MarkupDeclarationOpen;
                        },
                        '/' => {
                            self.current_state = State.EndTagOpen;
                        },
                        '?' => {
                            try self.emitError("Unexpected question mark in tag open");
                            self.current_state = State.BogusComment;
                            self.temporary_buffer.clearRetainingCapacity();
                            try self.temporary_buffer.append(c);
                        },
                        else => {
                            if (isAsciiAlpha(c)) {
                                self.current_token = Token{
                                    .token_type = TokenType.StartTag,
                                    .data = .{
                                        .tag = .{
                                            .name = "",
                                            .self_closing = false,
                                            .attributes = std.ArrayList(Attribute).init(self.allocator),
                                        },
                                    },
                                };
                                self.current_state = State.TagName;
                                self.reconsume = true;
                            } else {
                                try self.emitError("Invalid character in tag open");
                                try self.emitCharacter(&[_]u8{'<'});
                                self.current_state = State.Data;
                                self.reconsume = true;
                            }
                        },
                    }
                },
                .EndTagOpen => {
                    switch (c) {
                        '>' => {
                            try self.emitError("Missing end tag name");
                            self.current_state = State.Data;
                        },
                        0 => {
                            try self.emitError("Unexpected NULL character in end tag open");
                            self.current_token = Token{
                                .token_type = TokenType.EndTag,
                                .data = .{
                                    .tag = .{
                                        .name = "",
                                        .self_closing = false,
                                        .attributes = std.ArrayList(Attribute).init(self.allocator),
                                    },
                                },
                            };
                            self.current_state = State.TagName;
                            try self.appendToTagName('\u{FFFD}');
                        },
                        else => {
                            if (isAsciiAlpha(c)) {
                                self.current_token = Token{
                                    .token_type = TokenType.EndTag,
                                    .data = .{
                                        .tag = .{
                                            .name = "",
                                            .self_closing = false,
                                            .attributes = std.ArrayList(Attribute).init(self.allocator),
                                        },
                                    },
                                };
                                self.current_state = State.TagName;
                                self.reconsume = true;
                            } else {
                                try self.emitError("Invalid character in end tag open");
                                self.current_state = State.BogusComment;
                                self.temporary_buffer.clearRetainingCapacity();
                                try self.temporary_buffer.append(c);
                            }
                        },
                    }
                },
                .TagName => {
                    switch (c) {
                        '\t', '\n', '\f', ' ' => {
                            self.current_state = State.BeforeAttributeName;
                        },
                        '/' => {
                            self.current_state = State.SelfClosingStartTag;
                        },
                        '>' => {
                            self.current_state = State.Data;
                            if (self.current_token) |token| {
                                try self.emitted_tokens.append(token);
                                self.current_token = null;
                                if (self.emitted_tokens.items.len > 0) {
                                    return self.emitted_tokens.orderedRemove(0);
                                }
                            }
                        },
                        0 => {
                            try self.emitError("Unexpected NULL character in tag name");
                            try self.appendToTagName('\u{FFFD}');
                        },
                        else => {
                            try self.appendToTagName(c);
                        },
                    }
                },
                .BeforeAttributeName => {
                    switch (c) {
                        '\t', '\n', '\f', ' ' => {
                            // 空白は無視
                        },
                        '/', '>' => {
                            self.current_state = State.AfterAttributeName;
                            self.reconsume = true;
                        },
                        '=' => {
                            try self.emitError("Unexpected equals sign before attribute name");
                            self.attribute_name_start = self.position - 1;
                            self.attribute_name_end = self.position;
                            self.current_state = State.AttributeName;
                        },
                        else => {
                            self.attribute_name_start = self.position - 1;
                            self.current_state = State.AttributeName;
                        },
                    }
                },
                .AttributeName => {
                    switch (c) {
                        '\t', '\n', '\f', ' ', '/', '>' => {
                            self.attribute_name_end = self.position - 1;
                            self.current_state = State.AfterAttributeName;
                            self.reconsume = true;
                        },
                        '=' => {
                            self.attribute_name_end = self.position - 1;
                            self.current_state = State.BeforeAttributeValue;
                        },
                        0 => {
                            try self.emitError("Unexpected NULL character in attribute name");
                            // NULL文字は置換文字に置き換え
                        },
                        '"', '\'', '<' => {
                            try self.emitError("Unexpected character in attribute name");
                            // 処理は続行
                        },
                        else => {
                            // 属性名の一部として処理
                        },
                    }
                },
                .AfterAttributeName => {
                    switch (c) {
                        '\t', '\n', '\f', ' ' => {
                            // 空白は無視
                        },
                        '/' => {
                            try self.addAttributeWithoutValue();
                            self.current_state = State.SelfClosingStartTag;
                        },
                        '=' => {
                            self.current_state = State.BeforeAttributeValue;
                        },
                        '>' => {
                            try self.addAttributeWithoutValue();
                            self.current_state = State.Data;
                            if (self.current_token) |token| {
                                try self.emitted_tokens.append(token);
                                self.current_token = null;
                                if (self.emitted_tokens.items.len > 0) {
                                    return self.emitted_tokens.orderedRemove(0);
                                }
                            }
                        },
                        else => {
                            try self.addAttributeWithoutValue();
                            self.attribute_name_start = self.position - 1;
                            self.current_state = State.AttributeName;
                        },
                    }
                },
                .BeforeAttributeValue => {
                    switch (c) {
                        '\t', '\n', '\f', ' ' => {
                            // 空白は無視
                        },
                        '"' => {
                            self.current_state = State.AttributeValueDoubleQuoted;
                            self.attribute_value_start = self.position;
                        },
                        '\'' => {
                            self.current_state = State.AttributeValueSingleQuoted;
                            self.attribute_value_start = self.position;
                        },
                        '>' => {
                            try self.emitError("Expected attribute value but got '>'");
                            try self.addAttributeWithoutValue();
                            self.current_state = State.Data;
                            if (self.current_token) |token| {
                                try self.emitted_tokens.append(token);
                                self.current_token = null;
                                if (self.emitted_tokens.items.len > 0) {
                                    return self.emitted_tokens.orderedRemove(0);
                                }
                            }
                        },
                        else => {
                            self.current_state = State.AttributeValueUnquoted;
                            self.attribute_value_start = self.position - 1;
                            self.reconsume = true;
                        },
                    }
                },
                .AttributeValueDoubleQuoted => {
                    switch (c) {
                        '"' => {
                            self.attribute_value_end = self.position - 1;
                            try self.addAttribute();
                            self.current_state = State.AfterAttributeValueQuoted;
                        },
                        0 => {
                            try self.emitError("Unexpected NULL character in attribute value");
                            // NULL文字は置換文字に置き換え
                        },
                        else => {
                            // 属性値の一部として処理
                        },
                    }
                },
                .AttributeValueSingleQuoted => {
                    switch (c) {
                        '\'' => {
                            self.attribute_value_end = self.position - 1;
                            try self.addAttribute();
                            self.current_state = State.AfterAttributeValueQuoted;
                        },
                        0 => {
                            try self.emitError("Unexpected NULL character in attribute value");
                            // NULL文字は置換文字に置き換え
                        },
                        else => {
                            // 属性値の一部として処理
                        },
                    }
                },
                .AttributeValueUnquoted => {
                    switch (c) {
                        '\t', '\n', '\f', ' ' => {
                            self.attribute_value_end = self.position - 1;
                            try self.addAttribute();
                            self.current_state = State.BeforeAttributeName;
                        },
                        '>' => {
                            self.attribute_value_end = self.position - 1;
                            try self.addAttribute();
                            self.current_state = State.Data;
                            if (self.current_token) |token| {
                                try self.emitted_tokens.append(token);
                                self.current_token = null;
                                if (self.emitted_tokens.items.len > 0) {
                                    return self.emitted_tokens.orderedRemove(0);
                                }
                            }
                        },
                        0 => {
                            try self.emitError("Unexpected NULL character in attribute value");
                            // NULL文字は置換文字に置き換え
                        },
                        '"', '\'', '<', '=', '`' => {
                            try self.emitError("Unexpected character in unquoted attribute value");
                            // 処理は続行
                        },
                        else => {
                            // 属性値の一部として処理
                        },
                    }
                },
                .AfterAttributeValueQuoted => {
                    switch (c) {
                        '\t', '\n', '\f', ' ' => {
                            self.current_state = State.BeforeAttributeName;
                        },
                        '/' => {
                            self.current_state = State.SelfClosingStartTag;
                        },
                        '>' => {
                            self.current_state = State.Data;
                            if (self.current_token) |token| {
                                try self.emitted_tokens.append(token);
                                self.current_token = null;
                                if (self.emitted_tokens.items.len > 0) {
                                    return self.emitted_tokens.orderedRemove(0);
                                }
                            }
                        },
                        else => {
                            try self.emitError("Unexpected character after attribute value");
                            self.current_state = State.BeforeAttributeName;
                            self.reconsume = true;
                        },
                    }
                },
                .SelfClosingStartTag => {
                    switch (c) {
                        '>' => {
                            if (self.current_token) |*token| {
                                if (token.token_type == TokenType.StartTag or token.token_type == TokenType.EndTag) {
                                    token.data.tag.self_closing = true;
                                }
                            }
                            self.current_state = State.Data;
                            if (self.current_token) |token| {
                                try self.emitted_tokens.append(token);
                                self.current_token = null;
                                if (self.emitted_tokens.items.len > 0) {
                                    return self.emitted_tokens.orderedRemove(0);
                                }
                            }
                        },
                        else => {
                            try self.emitError("Unexpected character in self-closing start tag");
                            self.current_state = State.BeforeAttributeName;
                            self.reconsume = true;
                        },
                    }
                },
                .BogusComment => {
                    switch (c) {
                        '>' => {
                            self.current_state = State.Data;
                            const comment = try self.allocator.dupe(u8, self.temporary_buffer.items);
                            const token = Token{
                                .token_type = TokenType.Comment,
                                .data = .{ .comment = comment },
                            };
                            try self.emitted_tokens.append(token);
                            self.temporary_buffer.clearRetainingCapacity();
                            if (self.emitted_tokens.items.len > 0) {
                                return self.emitted_tokens.orderedRemove(0);
                            }
                        },
                        0 => {
                            try self.emitError("Unexpected NULL character in comment");
                            try self.temporary_buffer.append('\u{FFFD}');
                        },
                        else => {
                            try self.temporary_buffer.append(c);
                        },
                    }
                },
                .MarkupDeclarationOpen => {
                    if (self.position + 1 < self.input.len and 
                        self.input[self.position - 1] == '-' and 
                        self.input[self.position] == '-') {
                        self.position += 1;
                        self.current_state = State.CommentStart;
                        self.temporary_buffer.clearRetainingCapacity();
                    } else if (self.position + 6 < self.input.len and 
                               std.mem.eql(u8, self.input[self.position - 1..self.position + 6], "DOCTYPE")) {
                        self.position += 6;
                        self.current_state = State.DOCTYPE;
                    } else if (self.position + 6 < self.input.len and 
                               std.mem.eql(u8, self.input[self.position - 1..self.position + 6], "[CDATA[")) {
                        self.position += 6;
                        self.current_state = State.CDATASection;
                        // CDATAセクションの処理は簡略化
                        try self.emitCharacter("<![CDATA[");
                    } else {
                        try self.emitError("Incorrectly opened comment");
                        self.current_state = State.BogusComment;
                        self.temporary_buffer.clearRetainingCapacity();
                        self.reconsume = true;
                    }
                },
                .CommentStart => {
                    switch (c) {
                        '-' => {
                            self.current_state = State.CommentStartDash;
                        },
                        '>' => {
                            try self.emitError("Abruptly closed empty comment");
                            self.current_state = State.Data;
                            const comment = try self.allocator.dupe(u8, self.temporary_buffer.items);
                            const token = Token{
                                .token_type = TokenType.Comment,
                                .data = .{ .comment = comment },
                            };
                            try self.emitted_tokens.append(token);
                            self.temporary_buffer.clearRetainingCapacity();
                            if (self.emitted_tokens.items.len > 0) {
                                return self.emitted_tokens.orderedRemove(0);
                            }
                        },
                        else => {
                            self.current_state = State.Comment;
                            self.reconsume = true;
                        },
                    }
                },
                // 他の状態も同様に実装...（省略）
                else => {
                    // 簡略化のため、他の状態は基本的に処理をスキップしてDataに戻す
                    try self.emitError("Unimplemented tokenizer state");
                    self.current_state = State.Data;
                },
            }
        }

        // EOFに達した場合
        return Token{
            .token_type = TokenType.EOF,
            .data = .{ .eof = {} },
        };
    }

    // 補助関数
    fn emitError(self: *HTMLTokenizer, message: []const u8) !void {
        const error_message = try self.allocator.dupe(u8, message);
        const token = Token{
            .token_type = TokenType.Error,
            .data = .{ .error = error_message },
        };
        try self.emitted_tokens.append(token);
    }

    fn emitCharacter(self: *HTMLTokenizer, data: []const u8) !void {
        const character_data = try self.allocator.dupe(u8, data);
        const token = Token{
            .token_type = TokenType.Character,
            .data = .{ .character = character_data },
        };
        try self.emitted_tokens.append(token);
    }

    fn emitWhitespace(self: *HTMLTokenizer, data: []const u8) !void {
        const whitespace_data = try self.allocator.dupe(u8, data);
        const token = Token{
            .token_type = TokenType.WhiteSpace,
            .data = .{ .whitespace = whitespace_data },
        };
        try self.emitted_tokens.append(token);
    }

    fn appendToTagName(self: *HTMLTokenizer, c: u8) !void {
        if (self.current_token) |*token| {
            if (token.token_type == TokenType.StartTag or token.token_type == TokenType.EndTag) {
                const old_name = token.data.tag.name;
                const new_name = try self.allocator.alloc(u8, old_name.len + 1);
                std.mem.copy(u8, new_name, old_name);
                new_name[old_name.len] = std.ascii.toLower(c);
                
                if (old_name.len > 0) {
                    self.allocator.free(old_name);
                }
                
                token.data.tag.name = new_name;
            }
        }
    }

    fn addAttribute(self: *HTMLTokenizer) !void {
        if (self.current_token) |*token| {
            if (token.token_type == TokenType.StartTag or token.token_type == TokenType.EndTag) {
                const name = self.input[self.attribute_name_start..self.attribute_name_end + 1];
                const name_copy = try self.allocator.dupe(u8, name);
                
                const value = self.input[self.attribute_value_start..self.attribute_value_end + 1];
                const value_copy = try self.allocator.dupe(u8, value);
                
                const attribute = Attribute.init(name_copy, value_copy);
                try token.data.tag.attributes.append(attribute);
            }
        }
    }

    fn addAttributeWithoutValue(self: *HTMLTokenizer) !void {
        if (self.current_token) |*token| {
            if (token.token_type == TokenType.StartTag or token.token_type == TokenType.EndTag) {
                const name = self.input[self.attribute_name_start..self.attribute_name_end + 1];
                const name_copy = try self.allocator.dupe(u8, name);
                
                const attribute = Attribute.init(name_copy, null);
                try token.data.tag.attributes.append(attribute);
            }
        }
    }
};

// ユーティリティ関数
fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// テスト用
pub fn tokenize(allocator: *Allocator, html: []const u8) !std.ArrayList(Token) {
    var tokenizer = try HTMLTokenizer.init(allocator, html);
    defer tokenizer.deinit();
    
    var tokens = std.ArrayList(Token).init(allocator);
    
    while (try tokenizer.nextToken()) |token| {
        if (token.token_type == TokenType.EOF) {
            break;
        }
        try tokens.append(token);
    }
    
    return tokens;
} 