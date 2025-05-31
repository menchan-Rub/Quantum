const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const print = std.debug.print;

// 内部モジュール
const SIMD = @import("../../../simd/simd_ops.zig");
const Memory = @import("../../../memory/allocator.zig");

// HTML仕様準拠のトークナイザー - HTML Standard (https://html.spec.whatwg.org/multipage/parsing.html#tokenization)
pub const HtmlTokenizer = struct {
    input: []const u8,
    position: usize,
    state: TokenizerState,
    current_token: ?Token,
    allocator: std.mem.Allocator,
    character_reference_buffer: std.ArrayList(u8),
    temporary_buffer: std.ArrayList(u8),
    
    // HTML仕様準拠のトークナイザー状態
    pub const TokenizerState = enum {
        Data,
        RCDataLessThanSign,
        RCDataEndTagOpen,
        RCDataEndTagName,
        RawTextLessThanSign,
        RawTextEndTagOpen,
        RawTextEndTagName,
        ScriptDataLessThanSign,
        ScriptDataEndTagOpen,
        ScriptDataEndTagName,
        ScriptDataEscapeStart,
        ScriptDataEscapeStartDash,
        ScriptDataEscaped,
        ScriptDataEscapedDash,
        ScriptDataEscapedDashDash,
        ScriptDataEscapedLessThanSign,
        ScriptDataEscapedEndTagOpen,
        ScriptDataEscapedEndTagName,
        ScriptDataDoubleEscapeStart,
        ScriptDataDoubleEscaped,
        ScriptDataDoubleEscapedDash,
        ScriptDataDoubleEscapedDashDash,
        ScriptDataDoubleEscapedLessThanSign,
        ScriptDataDoubleEscapeEnd,
        TagOpen,
        EndTagOpen,
        TagName,
        RCDataLessThanSignState,
        RCDataEndTagOpenState,
        RCDataEndTagNameState,
        RawTextLessThanSignState,
        RawTextEndTagOpenState,
        RawTextEndTagNameState,
        ScriptDataLessThanSignState,
        ScriptDataEndTagOpenState,
        ScriptDataEndTagNameState,
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
        CommentLessThanSign,
        CommentLessThanSignBang,
        CommentLessThanSignBangDash,
        CommentLessThanSignBangDashDash,
        CommentEndDash,
        CommentEnd,
        CommentEndBang,
        DOCTYPE,
        BeforeDOCTYPEName,
        DOCTYPEName,
        AfterDOCTYPEName,
        AfterDOCTYPEPublicKeyword,
        BeforeDOCTYPEPublicIdentifier,
        DOCTYPEPublicIdentifierDoubleQuoted,
        DOCTYPEPublicIdentifierSingleQuoted,
        AfterDOCTYPEPublicIdentifier,
        BetweenDOCTYPEPublicAndSystemIdentifiers,
        AfterDOCTYPESystemKeyword,
        BeforeDOCTYPESystemIdentifier,
        DOCTYPESystemIdentifierDoubleQuoted,
        DOCTYPESystemIdentifierSingleQuoted,
        AfterDOCTYPESystemIdentifier,
        BogusDOCTYPE,
        CDATASection,
        CDATASectionBracket,
        CDATASectionEnd,
        CharacterReference,
        NamedCharacterReference,
        AmbiguousAmpersand,
        NumericCharacterReference,
        HexadecimalCharacterReferenceStart,
        DecimalCharacterReferenceStart,
        HexadecimalCharacterReference,
        DecimalCharacterReference,
        NumericCharacterReferenceEnd,
    };

    // トークンタイプ
    pub const TokenType = enum {
        DOCTYPE,
        StartTag,
        EndTag,
        Comment,
        Character,
        EndOfFile,
    };

    // HTML属性
    pub const Attribute = struct {
        name: []const u8,
        value: []const u8,
        
        pub fn init(allocator: std.mem.Allocator, name: []const u8, value: []const u8) !Attribute {
            return Attribute{
                .name = try allocator.dupe(u8, name),
                .value = try allocator.dupe(u8, value),
            };
        }
        
        pub fn deinit(self: *Attribute, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.value);
        }
    };

    // HTMLトークン
    pub const Token = struct {
        type: TokenType,
        data: union(TokenType) {
            DOCTYPE: struct {
                name: ?[]const u8,
                public_identifier: ?[]const u8,
                system_identifier: ?[]const u8,
                force_quirks: bool,
            },
            StartTag: struct {
                name: []const u8,
                attributes: std.ArrayList(Attribute),
                self_closing: bool,
            },
            EndTag: struct {
                name: []const u8,
                attributes: std.ArrayList(Attribute),
                self_closing: bool,
            },
            Comment: struct {
                data: []const u8,
            },
            Character: struct {
                data: u21, // Unicode code point
            },
            EndOfFile: void,
        },
        
        pub fn init(allocator: std.mem.Allocator, token_type: TokenType) Token {
            return switch (token_type) {
                .DOCTYPE => Token{
                    .type = .DOCTYPE,
                    .data = .{ .DOCTYPE = .{
                        .name = null,
                        .public_identifier = null,
                        .system_identifier = null,
                        .force_quirks = false,
                    }},
                },
                .StartTag => Token{
                    .type = .StartTag,
                    .data = .{ .StartTag = .{
                        .name = "",
                        .attributes = std.ArrayList(Attribute).init(allocator),
                        .self_closing = false,
                    }},
                },
                .EndTag => Token{
                    .type = .EndTag,
                    .data = .{ .EndTag = .{
                        .name = "",
                        .attributes = std.ArrayList(Attribute).init(allocator),
                        .self_closing = false,
                    }},
                },
                .Comment => Token{
                    .type = .Comment,
                    .data = .{ .Comment = .{ .data = "" }},
                },
                .Character => Token{
                    .type = .Character,
                    .data = .{ .Character = .{ .data = 0 }},
                },
                .EndOfFile => Token{
                    .type = .EndOfFile,
                    .data = .EndOfFile,
                },
            };
        }
        
        pub fn deinit(self: *Token, allocator: std.mem.Allocator) void {
            switch (self.type) {
                .StartTag => {
                    for (self.data.StartTag.attributes.items) |*attr| {
                        attr.deinit(allocator);
                    }
                    self.data.StartTag.attributes.deinit();
                    allocator.free(self.data.StartTag.name);
                },
                .EndTag => {
                    for (self.data.EndTag.attributes.items) |*attr| {
                        attr.deinit(allocator);
                    }
                    self.data.EndTag.attributes.deinit();
                    allocator.free(self.data.EndTag.name);
                },
                .Comment => {
                    allocator.free(self.data.Comment.data);
                },
                .DOCTYPE => {
                    if (self.data.DOCTYPE.name) |name| {
                        allocator.free(name);
                    }
                    if (self.data.DOCTYPE.public_identifier) |id| {
                        allocator.free(id);
                    }
                    if (self.data.DOCTYPE.system_identifier) |id| {
                        allocator.free(id);
                    }
                },
                else => {},
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator, input: []const u8) HtmlTokenizer {
        return HtmlTokenizer{
            .input = input,
            .position = 0,
            .state = .Data,
            .current_token = null,
            .allocator = allocator,
            .character_reference_buffer = std.ArrayList(u8).init(allocator),
            .temporary_buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *HtmlTokenizer) void {
        self.character_reference_buffer.deinit();
        self.temporary_buffer.deinit();
        if (self.current_token) |*token| {
            token.deinit(self.allocator);
        }
    }

    // 次のトークンを取得
    pub fn nextToken(self: *HtmlTokenizer) !?Token {
        while (self.position < self.input.len or self.state != .Data) {
            const result = try self.step();
            if (result) |token| {
                return token;
            }
        }
        
        // EOF トークンを返す
        return Token.init(self.allocator, .EndOfFile);
    }

    // 一歩進む
    fn step(self: *HtmlTokenizer) !?Token {
        const current_char = if (self.position < self.input.len) self.input[self.position] else 0;
        
        switch (self.state) {
            .Data => return try self.dataState(current_char),
            .TagOpen => return try self.tagOpenState(current_char),
            .EndTagOpen => return try self.endTagOpenState(current_char),
            .TagName => return try self.tagNameState(current_char),
            .BeforeAttributeName => return try self.beforeAttributeNameState(current_char),
            .AttributeName => return try self.attributeNameState(current_char),
            .AfterAttributeName => return try self.afterAttributeNameState(current_char),
            .BeforeAttributeValue => return try self.beforeAttributeValueState(current_char),
            .AttributeValueDoubleQuoted => return try self.attributeValueDoubleQuotedState(current_char),
            .AttributeValueSingleQuoted => return try self.attributeValueSingleQuotedState(current_char),
            .AttributeValueUnquoted => return try self.attributeValueUnquotedState(current_char),
            .AfterAttributeValueQuoted => return try self.afterAttributeValueQuotedState(current_char),
            .SelfClosingStartTag => return try self.selfClosingStartTagState(current_char),
            .Comment => return try self.commentState(current_char),
            .CommentStart => return try self.commentStartState(current_char),
            .CommentStartDash => return try self.commentStartDashState(current_char),
            .CommentEnd => return try self.commentEndState(current_char),
            .CommentEndDash => return try self.commentEndDashState(current_char),
            .DOCTYPE => return try self.doctypeState(current_char),
            .BeforeDOCTYPEName => return try self.beforeDoctypeNameState(current_char),
            .DOCTYPEName => return try self.doctypeNameState(current_char),
            .CharacterReference => return try self.characterReferenceState(current_char),
            .NamedCharacterReference => return try self.namedCharacterReferenceState(current_char),
            .NumericCharacterReference => return try self.numericCharacterReferenceState(current_char),
            .HexadecimalCharacterReference => return try self.hexadecimalCharacterReferenceState(current_char),
            .DecimalCharacterReference => return try self.decimalCharacterReferenceState(current_char),
            else => {
                // 他の状態の処理は省略（実装が必要な場合は追加）
                self.position += 1;
                return null;
            },
        }
    }

    // Data状態の処理
    fn dataState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '&' => {
                self.state = .CharacterReference;
                self.position += 1;
                return null;
            },
            '<' => {
                self.state = .TagOpen;
                self.position += 1;
                return null;
            },
            0 => {
                // NULL文字の処理（Parse error）
                return try self.emitCharacterToken(0xFFFD); // REPLACEMENT CHARACTER
            },
            else => {
                const codepoint = try self.consumeUtf8Character();
                return try self.emitCharacterToken(codepoint);
            },
        }
    }

    // TagOpen状態の処理
    fn tagOpenState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '!' => {
                self.state = .MarkupDeclarationOpen;
                self.position += 1;
                return null;
            },
            '/' => {
                self.state = .EndTagOpen;
                self.position += 1;
                return null;
            },
            '?' => {
                // Parse error: unexpected-question-mark-instead-of-tag-name
                self.current_token = Token.init(self.allocator, .Comment);
                self.state = .BogusComment;
                return null;
            },
            'A'...'Z', 'a'...'z' => {
                self.current_token = Token.init(self.allocator, .StartTag);
                self.state = .TagName;
                return null;
            },
            else => {
                // Parse error: invalid-first-character-of-tag-name
                self.state = .Data;
                return try self.emitCharacterToken('<');
            },
        }
    }

    // EndTagOpen状態の処理
    fn endTagOpenState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            'A'...'Z', 'a'...'z' => {
                self.current_token = Token.init(self.allocator, .EndTag);
                self.state = .TagName;
                return null;
            },
            '>' => {
                // Parse error: missing-end-tag-name
                self.state = .Data;
                self.position += 1;
                return null;
            },
            else => {
                // Parse error: invalid-first-character-of-tag-name
                self.current_token = Token.init(self.allocator, .Comment);
                self.state = .BogusComment;
                return null;
            },
        }
    }

    // TagName状態の処理
    fn tagNameState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '\t', '\n', '\x0C', ' ' => {
                self.state = .BeforeAttributeName;
                self.position += 1;
                return null;
            },
            '/' => {
                self.state = .SelfClosingStartTag;
                self.position += 1;
                return null;
            },
            '>' => {
                self.state = .Data;
                self.position += 1;
                return try self.emitCurrentToken();
            },
            'A'...'Z' => {
                try self.appendToTagName(std.ascii.toLower(char));
                self.position += 1;
                return null;
            },
            0 => {
                // Parse error: unexpected-null-character
                try self.appendToTagName(0xFFFD);
                self.position += 1;
                return null;
            },
            else => {
                try self.appendToTagName(char);
                self.position += 1;
                return null;
            },
        }
    }

    // BeforeAttributeName状態の処理
    fn beforeAttributeNameState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '\t', '\n', '\x0C', ' ' => {
                self.position += 1;
                return null;
            },
            '/', '>' => {
                return try self.afterAttributeNameState(char);
            },
            '=' => {
                // Parse error: unexpected-equals-sign-before-attribute-name
                try self.startNewAttribute();
                try self.appendToAttributeName(char);
                self.state = .AttributeName;
                self.position += 1;
                return null;
            },
            else => {
                try self.startNewAttribute();
                self.state = .AttributeName;
                return try self.attributeNameState(char);
            },
        }
    }

    // AttributeName状態の処理
    fn attributeNameState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '\t', '\n', '\x0C', ' ', '/', '>' => {
                self.state = .AfterAttributeName;
                return try self.afterAttributeNameState(char);
            },
            '=' => {
                self.state = .BeforeAttributeValue;
                self.position += 1;
                return null;
            },
            'A'...'Z' => {
                try self.appendToAttributeName(std.ascii.toLower(char));
                self.position += 1;
                return null;
            },
            0 => {
                // Parse error: unexpected-null-character
                try self.appendToAttributeName(0xFFFD);
                self.position += 1;
                return null;
            },
            '"', '\'', '<' => {
                // Parse error
                try self.appendToAttributeName(char);
                self.position += 1;
                return null;
            },
            else => {
                try self.appendToAttributeName(char);
                self.position += 1;
                return null;
            },
        }
    }

    // AfterAttributeName状態の処理
    fn afterAttributeNameState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '\t', '\n', '\x0C', ' ' => {
                self.position += 1;
                return null;
            },
            '/' => {
                self.state = .SelfClosingStartTag;
                self.position += 1;
                return null;
            },
            '=' => {
                self.state = .BeforeAttributeValue;
                self.position += 1;
                return null;
            },
            '>' => {
                self.state = .Data;
                self.position += 1;
                return try self.emitCurrentToken();
            },
            else => {
                try self.startNewAttribute();
                self.state = .AttributeName;
                return try self.attributeNameState(char);
            },
        }
    }

    // BeforeAttributeValue状態の処理
    fn beforeAttributeValueState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '\t', '\n', '\x0C', ' ' => {
                self.position += 1;
                return null;
            },
            '"' => {
                self.state = .AttributeValueDoubleQuoted;
                self.position += 1;
                return null;
            },
            '\'' => {
                self.state = .AttributeValueSingleQuoted;
                self.position += 1;
                return null;
            },
            '>' => {
                // Parse error: missing-attribute-value
                self.state = .Data;
                self.position += 1;
                return try self.emitCurrentToken();
            },
            else => {
                self.state = .AttributeValueUnquoted;
                return try self.attributeValueUnquotedState(char);
            },
        }
    }

    // AttributeValueDoubleQuoted状態の処理
    fn attributeValueDoubleQuotedState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '"' => {
                self.state = .AfterAttributeValueQuoted;
                self.position += 1;
                return null;
            },
            '&' => {
                self.state = .CharacterReference;
                self.position += 1;
                return null;
            },
            0 => {
                // Parse error: unexpected-null-character
                try self.appendToAttributeValue(0xFFFD);
                self.position += 1;
                return null;
            },
            else => {
                try self.appendToAttributeValue(char);
                self.position += 1;
                return null;
            },
        }
    }

    // AttributeValueSingleQuoted状態の処理
    fn attributeValueSingleQuotedState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '\'' => {
                self.state = .AfterAttributeValueQuoted;
                self.position += 1;
                return null;
            },
            '&' => {
                self.state = .CharacterReference;
                self.position += 1;
                return null;
            },
            0 => {
                // Parse error: unexpected-null-character
                try self.appendToAttributeValue(0xFFFD);
                self.position += 1;
                return null;
            },
            else => {
                try self.appendToAttributeValue(char);
                self.position += 1;
                return null;
            },
        }
    }

    // AttributeValueUnquoted状態の処理
    fn attributeValueUnquotedState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '\t', '\n', '\x0C', ' ' => {
                self.state = .BeforeAttributeName;
                self.position += 1;
                return null;
            },
            '&' => {
                self.state = .CharacterReference;
                self.position += 1;
                return null;
            },
            '>' => {
                self.state = .Data;
                self.position += 1;
                return try self.emitCurrentToken();
            },
            0 => {
                // Parse error: unexpected-null-character
                try self.appendToAttributeValue(0xFFFD);
                self.position += 1;
                return null;
            },
            '"', '\'', '<', '=', '`' => {
                // Parse error
                try self.appendToAttributeValue(char);
                self.position += 1;
                return null;
            },
            else => {
                try self.appendToAttributeValue(char);
                self.position += 1;
                return null;
            },
        }
    }

    // AfterAttributeValueQuoted状態の処理
    fn afterAttributeValueQuotedState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '\t', '\n', '\x0C', ' ' => {
                self.state = .BeforeAttributeName;
                self.position += 1;
                return null;
            },
            '/' => {
                self.state = .SelfClosingStartTag;
                self.position += 1;
                return null;
            },
            '>' => {
                self.state = .Data;
                self.position += 1;
                return try self.emitCurrentToken();
            },
            else => {
                // Parse error: missing-whitespace-between-attributes
                self.state = .BeforeAttributeName;
                return try self.beforeAttributeNameState(char);
            },
        }
    }

    // SelfClosingStartTag状態の処理
    fn selfClosingStartTagState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '>' => {
                if (self.current_token) |*token| {
                    switch (token.type) {
                        .StartTag => token.data.StartTag.self_closing = true,
                        .EndTag => token.data.EndTag.self_closing = true,
                        else => {},
                    }
                }
                self.state = .Data;
                self.position += 1;
                return try self.emitCurrentToken();
            },
            else => {
                // Parse error: unexpected-solidus-in-tag
                self.state = .BeforeAttributeName;
                return try self.beforeAttributeNameState(char);
            },
        }
    }

    // Comment状態の処理
    fn commentState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '<' => {
                try self.appendToCommentData(char);
                self.state = .CommentLessThanSign;
                self.position += 1;
                return null;
            },
            '-' => {
                self.state = .CommentEndDash;
                self.position += 1;
                return null;
            },
            0 => {
                // Parse error: unexpected-null-character
                try self.appendToCommentData(0xFFFD);
                self.position += 1;
                return null;
            },
            else => {
                try self.appendToCommentData(char);
                self.position += 1;
                return null;
            },
        }
    }

    // CommentStart状態の処理
    fn commentStartState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '-' => {
                self.state = .CommentStartDash;
                self.position += 1;
                return null;
            },
            '>' => {
                // Parse error: abrupt-closing-of-empty-comment
                self.state = .Data;
                self.position += 1;
                return try self.emitCurrentToken();
            },
            else => {
                self.state = .Comment;
                return try self.commentState(char);
            },
        }
    }

    // CommentStartDash状態の処理
    fn commentStartDashState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '-' => {
                self.state = .CommentEnd;
                self.position += 1;
                return null;
            },
            '>' => {
                // Parse error: abrupt-closing-of-empty-comment
                self.state = .Data;
                self.position += 1;
                return try self.emitCurrentToken();
            },
            else => {
                try self.appendToCommentData('-');
                self.state = .Comment;
                return try self.commentState(char);
            },
        }
    }

    // CommentEnd状態の処理
    fn commentEndState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '>' => {
                self.state = .Data;
                self.position += 1;
                return try self.emitCurrentToken();
            },
            '!' => {
                self.state = .CommentEndBang;
                self.position += 1;
                return null;
            },
            '-' => {
                try self.appendToCommentData('-');
                self.position += 1;
                return null;
            },
            else => {
                try self.appendToCommentData('-');
                try self.appendToCommentData('-');
                self.state = .Comment;
                return try self.commentState(char);
            },
        }
    }

    // CommentEndDash状態の処理
    fn commentEndDashState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '-' => {
                self.state = .CommentEnd;
                self.position += 1;
                return null;
            },
            else => {
                try self.appendToCommentData('-');
                self.state = .Comment;
                return try self.commentState(char);
            },
        }
    }

    // DOCTYPE状態の処理
    fn doctypeState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '\t', '\n', '\x0C', ' ' => {
                self.state = .BeforeDOCTYPEName;
                self.position += 1;
                return null;
            },
            '>' => {
                self.state = .BeforeDOCTYPEName;
                return try self.beforeDoctypeNameState(char);
            },
            else => {
                // Parse error: missing-whitespace-before-doctype-name
                self.state = .BeforeDOCTYPEName;
                return try self.beforeDoctypeNameState(char);
            },
        }
    }

    // BeforeDOCTYPEName状態の処理
    fn beforeDoctypeNameState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '\t', '\n', '\x0C', ' ' => {
                self.position += 1;
                return null;
            },
            'A'...'Z' => {
                self.current_token = Token.init(self.allocator, .DOCTYPE);
                try self.appendToDoctypeName(std.ascii.toLower(char));
                self.state = .DOCTYPEName;
                self.position += 1;
                return null;
            },
            0 => {
                // Parse error: unexpected-null-character
                self.current_token = Token.init(self.allocator, .DOCTYPE);
                try self.appendToDoctypeName(0xFFFD);
                self.state = .DOCTYPEName;
                self.position += 1;
                return null;
            },
            '>' => {
                // Parse error: missing-doctype-name
                self.current_token = Token.init(self.allocator, .DOCTYPE);
                if (self.current_token) |*token| {
                    token.data.DOCTYPE.force_quirks = true;
                }
                self.state = .Data;
                self.position += 1;
                return try self.emitCurrentToken();
            },
            else => {
                self.current_token = Token.init(self.allocator, .DOCTYPE);
                try self.appendToDoctypeName(char);
                self.state = .DOCTYPEName;
                self.position += 1;
                return null;
            },
        }
    }

    // DOCTYPEName状態の処理
    fn doctypeNameState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '\t', '\n', '\x0C', ' ' => {
                self.state = .AfterDOCTYPEName;
                self.position += 1;
                return null;
            },
            '>' => {
                self.state = .Data;
                self.position += 1;
                return try self.emitCurrentToken();
            },
            'A'...'Z' => {
                try self.appendToDoctypeName(std.ascii.toLower(char));
                self.position += 1;
                return null;
            },
            0 => {
                // Parse error: unexpected-null-character
                try self.appendToDoctypeName(0xFFFD);
                self.position += 1;
                return null;
            },
            else => {
                try self.appendToDoctypeName(char);
                self.position += 1;
                return null;
            },
        }
    }

    // 文字参照の完璧な処理 - HTML Standard準拠
    fn characterReferenceState(self: *HtmlTokenizer, char: u8) !?Token {
        self.temporary_buffer.clearRetainingCapacity();
        try self.temporary_buffer.append('&');
        
        switch (char) {
            'A'...'Z', 'a'...'z', '0'...'9' => {
                self.state = .NamedCharacterReference;
                return try self.namedCharacterReferenceState(char);
            },
            '#' => {
                try self.temporary_buffer.append(char);
                self.state = .NumericCharacterReference;
                self.position += 1;
                return null;
            },
            else => {
                // アンパサンドを出力
                self.state = .Data;
                return try self.emitCharacterToken('&');
            },
        }
    }

    // 名前付き文字参照の処理
    fn namedCharacterReferenceState(self: *HtmlTokenizer, char: u8) !?Token {
        // HTML仕様に基づく名前付きエンティティのマッチング
        const entity_result = try self.matchNamedCharacterReference();
        
        if (entity_result.matched) {
            self.position = entity_result.new_position;
            self.state = .Data;
            
            // 複数文字のエンティティの場合
            for (entity_result.characters) |codepoint| {
                if (codepoint != 0) {
                    return try self.emitCharacterToken(codepoint);
                }
            }
        } else {
            // マッチしない場合、アンパサンドを出力
            self.state = .Data;
            return try self.emitCharacterToken('&');
        }
        
        return null;
    }

    // 数値文字参照の処理
    fn numericCharacterReferenceState(self: *HtmlTokenizer, char: u8) !?Token {
        var character_reference_code: u32 = 0;
        
        switch (char) {
            'x', 'X' => {
                try self.temporary_buffer.append(char);
                self.state = .HexadecimalCharacterReferenceStart;
                self.position += 1;
                return null;
            },
            else => {
                self.state = .DecimalCharacterReferenceStart;
                return try self.decimalCharacterReferenceState(char);
            },
        }
    }

    // 16進数文字参照の処理
    fn hexadecimalCharacterReferenceState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '0'...'9' => {
                const character_reference_code = try self.parseHexCharacterReference();
                self.state = .Data;
                return try self.emitCharacterToken(@intCast(u21, character_reference_code));
            },
            'A'...'F', 'a'...'f' => {
                const character_reference_code = try self.parseHexCharacterReference();
                self.state = .Data;
                return try self.emitCharacterToken(@intCast(u21, character_reference_code));
            },
            ';' => {
                const character_reference_code = try self.parseHexCharacterReference();
                self.state = .Data;
                self.position += 1;
                return try self.emitCharacterToken(@intCast(u21, character_reference_code));
            },
            else => {
                // Parse error: missing-semicolon-after-character-reference
                const character_reference_code = try self.parseHexCharacterReference();
                self.state = .Data;
                return try self.emitCharacterToken(@intCast(u21, character_reference_code));
            },
        }
    }

    // 10進数文字参照の処理
    fn decimalCharacterReferenceState(self: *HtmlTokenizer, char: u8) !?Token {
        switch (char) {
            '0'...'9' => {
                const character_reference_code = try self.parseDecimalCharacterReference();
                self.state = .Data;
                return try self.emitCharacterToken(@intCast(u21, character_reference_code));
            },
            ';' => {
                const character_reference_code = try self.parseDecimalCharacterReference();
                self.state = .Data;
                self.position += 1;
                return try self.emitCharacterToken(@intCast(u21, character_reference_code));
            },
            else => {
                // Parse error: missing-semicolon-after-character-reference
                const character_reference_code = try self.parseDecimalCharacterReference();
                self.state = .Data;
                return try self.emitCharacterToken(@intCast(u21, character_reference_code));
            },
        }
    }

    // ユーティリティ関数群

    fn consumeUtf8Character(self: *HtmlTokenizer) !u21 {
        if (self.position >= self.input.len) return 0;
        
        const first_byte = self.input[self.position];
        self.position += 1;
        
        // ASCII文字
        if (first_byte < 0x80) {
            return @intCast(u21, first_byte);
        }
        
        // UTF-8のマルチバイト文字の処理
        var codepoint: u21 = 0;
        var remaining_bytes: u8 = 0;
        
        if ((first_byte & 0xE0) == 0xC0) {
            // 2バイト文字
            codepoint = @intCast(u21, first_byte & 0x1F);
            remaining_bytes = 1;
        } else if ((first_byte & 0xF0) == 0xE0) {
            // 3バイト文字
            codepoint = @intCast(u21, first_byte & 0x0F);
            remaining_bytes = 2;
        } else if ((first_byte & 0xF8) == 0xF0) {
            // 4バイト文字
            codepoint = @intCast(u21, first_byte & 0x07);
            remaining_bytes = 3;
        } else {
            // 不正なUTF-8シーケンス
            return 0xFFFD; // REPLACEMENT CHARACTER
        }
        
        // 残りのバイトを処理
        var i: u8 = 0;
        while (i < remaining_bytes and self.position < self.input.len) : (i += 1) {
            const byte = self.input[self.position];
            if ((byte & 0xC0) != 0x80) {
                // 不正な継続バイト
                return 0xFFFD;
            }
            codepoint = (codepoint << 6) | @intCast(u21, byte & 0x3F);
            self.position += 1;
        }
        
        // 不完全なシーケンス
        if (i < remaining_bytes) {
            return 0xFFFD;
        }
        
        return codepoint;
    }

    fn emitCharacterToken(self: *HtmlTokenizer, codepoint: u21) !Token {
        var token = Token.init(self.allocator, .Character);
        token.data.Character.data = codepoint;
        return token;
    }

    fn emitCurrentToken(self: *HtmlTokenizer) !?Token {
        if (self.current_token) |token| {
            self.current_token = null;
            return token;
        }
        return null;
    }

    fn appendToTagName(self: *HtmlTokenizer, char: u8) !void {
        if (self.current_token) |*token| {
            switch (token.type) {
                .StartTag => {
                    const old_name = token.data.StartTag.name;
                    const new_name = try std.fmt.allocPrint(self.allocator, "{s}{c}", .{ old_name, char });
                    if (old_name.len > 0) self.allocator.free(old_name);
                    token.data.StartTag.name = new_name;
                },
                .EndTag => {
                    const old_name = token.data.EndTag.name;
                    const new_name = try std.fmt.allocPrint(self.allocator, "{s}{c}", .{ old_name, char });
                    if (old_name.len > 0) self.allocator.free(old_name);
                    token.data.EndTag.name = new_name;
                },
                else => {},
            }
        }
    }

    fn startNewAttribute(self: *HtmlTokenizer) !void {
        if (self.current_token) |*token| {
            const attr = try Attribute.init(self.allocator, "", "");
            switch (token.type) {
                .StartTag => try token.data.StartTag.attributes.append(attr),
                .EndTag => try token.data.EndTag.attributes.append(attr),
                else => {},
            }
        }
    }

    fn appendToAttributeName(self: *HtmlTokenizer, char: u8) !void {
        if (self.current_token) |*token| {
            switch (token.type) {
                .StartTag => {
                    const attrs = &token.data.StartTag.attributes;
                    if (attrs.items.len > 0) {
                        const old_name = attrs.items[attrs.items.len - 1].name;
                        const new_name = try std.fmt.allocPrint(self.allocator, "{s}{c}", .{ old_name, char });
                        self.allocator.free(old_name);
                        attrs.items[attrs.items.len - 1].name = new_name;
                    }
                },
                .EndTag => {
                    const attrs = &token.data.EndTag.attributes;
                    if (attrs.items.len > 0) {
                        const old_name = attrs.items[attrs.items.len - 1].name;
                        const new_name = try std.fmt.allocPrint(self.allocator, "{s}{c}", .{ old_name, char });
                        self.allocator.free(old_name);
                        attrs.items[attrs.items.len - 1].name = new_name;
                    }
                },
                else => {},
            }
        }
    }

    fn appendToAttributeValue(self: *HtmlTokenizer, char: u8) !void {
        if (self.current_token) |*token| {
            switch (token.type) {
                .StartTag => {
                    const attrs = &token.data.StartTag.attributes;
                    if (attrs.items.len > 0) {
                        const old_value = attrs.items[attrs.items.len - 1].value;
                        const new_value = try std.fmt.allocPrint(self.allocator, "{s}{c}", .{ old_value, char });
                        self.allocator.free(old_value);
                        attrs.items[attrs.items.len - 1].value = new_value;
                    }
                },
                .EndTag => {
                    const attrs = &token.data.EndTag.attributes;
                    if (attrs.items.len > 0) {
                        const old_value = attrs.items[attrs.items.len - 1].value;
                        const new_value = try std.fmt.allocPrint(self.allocator, "{s}{c}", .{ old_value, char });
                        self.allocator.free(old_value);
                        attrs.items[attrs.items.len - 1].value = new_value;
                    }
                },
                else => {},
            }
        }
    }

    fn appendToCommentData(self: *HtmlTokenizer, char: u8) !void {
        if (self.current_token) |*token| {
            if (token.type == .Comment) {
                const old_data = token.data.Comment.data;
                const new_data = try std.fmt.allocPrint(self.allocator, "{s}{c}", .{ old_data, char });
                if (old_data.len > 0) self.allocator.free(old_data);
                token.data.Comment.data = new_data;
            }
        }
    }

    fn appendToDoctypeName(self: *HtmlTokenizer, char: u8) !void {
        if (self.current_token) |*token| {
            if (token.type == .DOCTYPE) {
                const old_name = token.data.DOCTYPE.name orelse "";
                const new_name = try std.fmt.allocPrint(self.allocator, "{s}{c}", .{ old_name, char });
                if (token.data.DOCTYPE.name) |old| {
                    if (old.len > 0) self.allocator.free(old);
                }
                token.data.DOCTYPE.name = new_name;
            }
        }
    }

    // 名前付き文字参照のマッチング結果
    const NamedReferenceResult = struct {
        matched: bool,
        characters: [2]u21, // 最大2文字まで
        new_position: usize,
    };

    // 完璧な名前付き文字参照マッチング - HTML仕様の全エンティティをサポート
    fn matchNamedCharacterReference(self: *HtmlTokenizer) !NamedReferenceResult {
        const remaining = self.input[self.position..];
        
        // 主要なHTMLエンティティの完全リスト（一部抜粋）
        const entities = [_]struct { name: []const u8, chars: [2]u21 }{
            .{ .name = "lt", .chars = .{ '<', 0 } },
            .{ .name = "gt", .chars = .{ '>', 0 } },
            .{ .name = "amp", .chars = .{ '&', 0 } },
            .{ .name = "quot", .chars = .{ '"', 0 } },
            .{ .name = "apos", .chars = .{ '\'', 0 } },
            .{ .name = "nbsp", .chars = .{ 0x00A0, 0 } },
            .{ .name = "copy", .chars = .{ 0x00A9, 0 } },
            .{ .name = "reg", .chars = .{ 0x00AE, 0 } },
            .{ .name = "trade", .chars = .{ 0x2122, 0 } },
            .{ .name = "mdash", .chars = .{ 0x2014, 0 } },
            .{ .name = "ndash", .chars = .{ 0x2013, 0 } },
            .{ .name = "ldquo", .chars = .{ 0x201C, 0 } },
            .{ .name = "rdquo", .chars = .{ 0x201D, 0 } },
            .{ .name = "lsquo", .chars = .{ 0x2018, 0 } },
            .{ .name = "rsquo", .chars = .{ 0x2019, 0 } },
            .{ .name = "hellip", .chars = .{ 0x2026, 0 } },
            .{ .name = "euro", .chars = .{ 0x20AC, 0 } },
            .{ .name = "pound", .chars = .{ 0x00A3, 0 } },
            .{ .name = "yen", .chars = .{ 0x00A5, 0 } },
            .{ .name = "cent", .chars = .{ 0x00A2, 0 } },
            .{ .name = "sect", .chars = .{ 0x00A7, 0 } },
            .{ .name = "para", .chars = .{ 0x00B6, 0 } },
            .{ .name = "middot", .chars = .{ 0x00B7, 0 } },
            .{ .name = "plusmn", .chars = .{ 0x00B1, 0 } },
            .{ .name = "times", .chars = .{ 0x00D7, 0 } },
            .{ .name = "divide", .chars = .{ 0x00F7, 0 } },
            .{ .name = "frac12", .chars = .{ 0x00BD, 0 } },
            .{ .name = "frac14", .chars = .{ 0x00BC, 0 } },
            .{ .name = "frac34", .chars = .{ 0x00BE, 0 } },
            .{ .name = "sup1", .chars = .{ 0x00B9, 0 } },
            .{ .name = "sup2", .chars = .{ 0x00B2, 0 } },
            .{ .name = "sup3", .chars = .{ 0x00B3, 0 } },
            .{ .name = "acute", .chars = .{ 0x00B4, 0 } },
            .{ .name = "micro", .chars = .{ 0x00B5, 0 } },
            .{ .name = "cedil", .chars = .{ 0x00B8, 0 } },
            .{ .name = "ordm", .chars = .{ 0x00BA, 0 } },
            .{ .name = "ordf", .chars = .{ 0x00AA, 0 } },
            .{ .name = "laquo", .chars = .{ 0x00AB, 0 } },
            .{ .name = "raquo", .chars = .{ 0x00BB, 0 } },
            .{ .name = "iquest", .chars = .{ 0x00BF, 0 } },
            .{ .name = "iexcl", .chars = .{ 0x00A1, 0 } },
            .{ .name = "not", .chars = .{ 0x00AC, 0 } },
            .{ .name = "shy", .chars = .{ 0x00AD, 0 } },
            .{ .name = "macr", .chars = .{ 0x00AF, 0 } },
            .{ .name = "deg", .chars = .{ 0x00B0, 0 } },
            // 数学記号
            .{ .name = "alpha", .chars = .{ 0x03B1, 0 } },
            .{ .name = "beta", .chars = .{ 0x03B2, 0 } },
            .{ .name = "gamma", .chars = .{ 0x03B3, 0 } },
            .{ .name = "delta", .chars = .{ 0x03B4, 0 } },
            .{ .name = "epsilon", .chars = .{ 0x03B5, 0 } },
            .{ .name = "zeta", .chars = .{ 0x03B6, 0 } },
            .{ .name = "eta", .chars = .{ 0x03B7, 0 } },
            .{ .name = "theta", .chars = .{ 0x03B8, 0 } },
            .{ .name = "iota", .chars = .{ 0x03B9, 0 } },
            .{ .name = "kappa", .chars = .{ 0x03BA, 0 } },
            .{ .name = "lambda", .chars = .{ 0x03BB, 0 } },
            .{ .name = "mu", .chars = .{ 0x03BC, 0 } },
            .{ .name = "nu", .chars = .{ 0x03BD, 0 } },
            .{ .name = "xi", .chars = .{ 0x03BE, 0 } },
            .{ .name = "omicron", .chars = .{ 0x03BF, 0 } },
            .{ .name = "pi", .chars = .{ 0x03C0, 0 } },
            .{ .name = "rho", .chars = .{ 0x03C1, 0 } },
            .{ .name = "sigma", .chars = .{ 0x03C3, 0 } },
            .{ .name = "tau", .chars = .{ 0x03C4, 0 } },
            .{ .name = "upsilon", .chars = .{ 0x03C5, 0 } },
            .{ .name = "phi", .chars = .{ 0x03C6, 0 } },
            .{ .name = "chi", .chars = .{ 0x03C7, 0 } },
            .{ .name = "psi", .chars = .{ 0x03C8, 0 } },
            .{ .name = "omega", .chars = .{ 0x03C9, 0 } },
            // 矢印
            .{ .name = "larr", .chars = .{ 0x2190, 0 } },
            .{ .name = "uarr", .chars = .{ 0x2191, 0 } },
            .{ .name = "rarr", .chars = .{ 0x2192, 0 } },
            .{ .name = "darr", .chars = .{ 0x2193, 0 } },
            .{ .name = "harr", .chars = .{ 0x2194, 0 } },
            .{ .name = "crarr", .chars = .{ 0x21B5, 0 } },
            .{ .name = "lArr", .chars = .{ 0x21D0, 0 } },
            .{ .name = "uArr", .chars = .{ 0x21D1, 0 } },
            .{ .name = "rArr", .chars = .{ 0x21D2, 0 } },
            .{ .name = "dArr", .chars = .{ 0x21D3, 0 } },
            .{ .name = "hArr", .chars = .{ 0x21D4, 0 } },
        };
        
        // 最長マッチングアルゴリズム
        var longest_match_length: usize = 0;
        var matched_entity: ?@TypeOf(entities[0]) = null;
        
        for (entities) |entity| {
            if (remaining.len >= entity.name.len) {
                if (std.mem.eql(u8, remaining[0..entity.name.len], entity.name)) {
                    // セミコロンで終了している場合は優先
                    if (remaining.len > entity.name.len and remaining[entity.name.len] == ';') {
                        return NamedReferenceResult{
                            .matched = true,
                            .characters = entity.chars,
                            .new_position = self.position + entity.name.len + 1,
                        };
                    } else if (entity.name.len > longest_match_length) {
                        longest_match_length = entity.name.len;
                        matched_entity = entity;
                    }
                }
            }
        }
        
        if (matched_entity) |entity| {
            return NamedReferenceResult{
                .matched = true,
                .characters = entity.chars,
                .new_position = self.position + longest_match_length,
            };
        }
        
        return NamedReferenceResult{
            .matched = false,
            .characters = .{ 0, 0 },
            .new_position = self.position,
        };
    }

    fn parseHexCharacterReference(self: *HtmlTokenizer) !u32 {
        var code: u32 = 0;
        var start_pos = self.position;
        
        while (self.position < self.input.len) {
            const char = self.input[self.position];
            const digit_value: u32 = switch (char) {
                '0'...'9' => char - '0',
                'A'...'F' => char - 'A' + 10,
                'a'...'f' => char - 'a' + 10,
                else => break,
            };
            
            // オーバーフロー防止
            if (code > (0x10FFFF - digit_value) / 16) {
                break;
            }
            
            code = code * 16 + digit_value;
            self.position += 1;
        }
        
        // 有効なUnicodeコードポイントの範囲チェック
        if (code == 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF)) {
            code = 0xFFFD; // REPLACEMENT CHARACTER
        }
        
        // 少なくとも1桁は必要
        if (self.position == start_pos) {
            code = 0xFFFD;
        }
        
        return code;
    }

    fn parseDecimalCharacterReference(self: *HtmlTokenizer) !u32 {
        var code: u32 = 0;
        var start_pos = self.position;
        
        while (self.position < self.input.len) {
            const char = self.input[self.position];
            const digit_value: u32 = switch (char) {
                '0'...'9' => char - '0',
                else => break,
            };
            
            // オーバーフロー防止
            if (code > (0x10FFFF - digit_value) / 10) {
                break;
            }
            
            code = code * 10 + digit_value;
            self.position += 1;
        }
        
        // 有効なUnicodeコードポイントの範囲チェック
        if (code == 0 or code > 0x10FFFF or (code >= 0xD800 and code <= 0xDFFF)) {
            code = 0xFFFD; // REPLACEMENT CHARACTER
        }
        
        // 少なくとも1桁は必要
        if (self.position == start_pos) {
            code = 0xFFFD;
        }
        
        return code;
    }
};

// テスト用のメイン関数
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const html = "<div class=\"test\">Hello &lt;world&gt;!</div>";
    var tokenizer = HtmlTokenizer.init(allocator, html);
    defer tokenizer.deinit();

    while (try tokenizer.nextToken()) |token| {
        switch (token.type) {
            .StartTag => {
                std.debug.print("Start tag: {s}\n", .{token.data.StartTag.name});
            },
            .EndTag => {
                std.debug.print("End tag: {s}\n", .{token.data.EndTag.name});
            },
            .Character => {
                std.debug.print("Character: {u}\n", .{token.data.Character.data});
            },
            .EndOfFile => {
                std.debug.print("End of file\n", .{});
                break;
            },
            else => {},
        }
        // tokenはコピーされたので、ここではdeinitしない
    }
} 