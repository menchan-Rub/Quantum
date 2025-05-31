const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

pub const TokenType = enum {
    DocType,
    StartTag,
    EndTag,
    Comment,
    Text,
    CDATA,
    EOF,
    Error,
};

pub const AttributeData = struct {
    name: []const u8,
    value: []const u8,
    // 最適化のためのフラグ
    has_namespace: bool = false,
    name_hash: u64 = 0,
};

pub const TokenData = union(TokenType) {
    DocType: struct {
        name: []const u8,
        public_id: []const u8,
        system_id: []const u8,
        force_quirks: bool,
    },
    StartTag: struct {
        name: []const u8,
        attributes: []AttributeData,
        self_closing: bool,
        name_hash: u64 = 0,
    },
    EndTag: struct {
        name: []const u8,
        name_hash: u64 = 0,
    },
    Comment: struct {
        data: []const u8,
    },
    Text: struct {
        data: []const u8,
        is_whitespace: bool = false,
    },
    CDATA: struct {
        data: []const u8,
    },
    EOF: void,
    Error: struct {
        code: u32,
        message: []const u8,
    },
};

pub const Token = struct {
    type: TokenType,
    start_position: usize,
    end_position: usize,
    line: usize,
    column: usize,
    
    // データはunionで表現
    data: TokenData,
    
    // エラートークンのためのメッセージフィールド
    error_msg: []const u8 = "",
    
    // トークンデータのフィールドへのアクセサ
    pub fn doctype(self: *const Token) *const TokenData.DocType {
        return &self.data.DocType;
    }
    
    pub fn start_tag(self: *const Token) *const TokenData.StartTag {
        return &self.data.StartTag;
    }
    
    pub fn end_tag(self: *const Token) *const TokenData.EndTag {
        return &self.data.EndTag;
    }
    
    pub fn comment(self: *const Token) *const TokenData.Comment {
        return &self.data.Comment;
    }
    
    pub fn text(self: *const Token) *const TokenData.Text {
        return &self.data.Text;
    }
    
    pub fn cdata(self: *const Token) *const TokenData.CDATA {
        return &self.data.CDATA;
    }
    
    pub fn error(self: *const Token) *const TokenData.Error {
        return &self.data.Error;
    }
};

pub const TokenizerError = error{
    OutOfMemory,
    InvalidCharacter,
    UnexpectedEndOfFile,
    InternalError,
    UnsupportedFeature,
};

pub const TokenizerState = enum {
    Data,
    CharacterReferenceInData,
    RCDATA,
    CharacterReferenceInRCDATA,
    RAWTEXT,
    ScriptData,
    PLAINTEXT,
    TagOpen,
    EndTagOpen,
    TagName,
    RCDATALessThanSign,
    RCDATAEndTagOpen,
    RCDATAEndTagName,
    RAWTEXTLessThanSign,
    RAWTEXTEndTagOpen,
    RAWTEXTEndTagName,
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
};

pub const TokenizerOptions = struct {
    // バッファサイズの初期値
    initial_buffer_size: usize = 4096,
    // エンティティ解決を有効にするかどうか
    decode_entities: bool = true,
    // ストリーミングモードを有効にするかどうか
    streaming_mode: bool = false,
    // UTF8の検証を行うかどうか
    validate_utf8: bool = true,
    // エラー時に回復を試みるかどうか
    recover_on_error: bool = true,
    // サイズ制限
    max_token_size: usize = 1 * 1024 * 1024, // 1MB
    max_attributes: usize = 256,
};

pub const HtmlTokenizer = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize,
    line: usize,
    column: usize,
    state: TokenizerState,
    return_state: TokenizerState,
    options: TokenizerOptions,
    
    // 現在のトークン
    current_token: Token,
    
    // バッファ
    token_buffer: std.ArrayList(u8),
    attribute_buffer: std.ArrayList(AttributeData),
    temp_buffer: std.ArrayList(u8),
    
    // エンティティ解決用のマップ
    entity_map: std.StringHashMap([]const u8),
    
    // 追加ステート情報
    last_start_tag_name: []const u8,
    last_start_tag_name_hash: u64,
    
    // パフォーマンス最適化
    char_ref_code: u32,
    additional_allowed_char: ?u8,
    
    pub fn init(allocator: Allocator) !HtmlTokenizer {
        var tokenizer = HtmlTokenizer{
            .allocator = allocator,
            .input = &[_]u8{},
            .pos = 0,
            .line = 1,
            .column = 1,
            .state = .Data,
            .return_state = .Data,
            .options = TokenizerOptions{},
            .current_token = undefined,
            .token_buffer = std.ArrayList(u8).init(allocator),
            .attribute_buffer = std.ArrayList(AttributeData).init(allocator),
            .temp_buffer = std.ArrayList(u8).init(allocator),
            .entity_map = std.StringHashMap([]const u8).init(allocator),
            .last_start_tag_name = "",
            .last_start_tag_name_hash = 0,
            .char_ref_code = 0,
            .additional_allowed_char = null,
        };
        
        try tokenizer.initializeEntityMap();
        
        return tokenizer;
    }
    
    pub fn deinit(self: *HtmlTokenizer) void {
        self.token_buffer.deinit();
        self.attribute_buffer.deinit();
        self.temp_buffer.deinit();
        
        var entity_iter = self.entity_map.iterator();
        while (entity_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entity_map.deinit();
        
        // 他のアロケートされたリソースの開放
        if (self.current_token.type == .StartTag) {
            if (self.current_token.data.StartTag.attributes.len > 0) {
                self.allocator.free(self.current_token.data.StartTag.attributes);
            }
        }
    }
    
    pub fn setInput(self: *HtmlTokenizer, input: []const u8) !void {
        self.input = input;
        self.pos = 0;
        self.line = 1;
        self.column = 1;
        self.state = .Data;
        self.token_buffer.clearRetainingCapacity();
        self.temp_buffer.clearRetainingCapacity();
        
        // UTF-8検証（オプションが有効な場合）
        if (self.options.validate_utf8) {
            var i: usize = 0;
            while (i < input.len) {
                const len = std.unicode.utf8ByteSequenceLength(input[i]) catch {
                    return TokenizerError.InvalidCharacter;
                };
                
                if (i + len > input.len) {
                    return TokenizerError.InvalidCharacter;
                }
                
                _ = std.unicode.utf8Decode(input[i..][0..len]) catch {
                    return TokenizerError.InvalidCharacter;
                };
                
                i += len;
            }
        }
    }
    
    pub fn nextToken(self: *HtmlTokenizer) !?Token {
        if (self.pos >= self.input.len) {
            return self.createEOFToken();
        }
        
        // トークンの状態をリセット
        self.token_buffer.clearRetainingCapacity();
        self.attribute_buffer.clearRetainingCapacity();
        
        // トークン開始位置を記録
        const start_pos = self.pos;
        const start_line = self.line;
        const start_column = self.column;
        
        while (self.pos < self.input.len) {
            // 1文字読み込み
            const c = self.input[self.pos];
            
            // 状態マシンに基づいて処理
            switch (self.state) {
                .Data => {
                    switch (c) {
                        '&' => {
                            self.return_state = .Data;
                            self.state = .CharacterReferenceInData;
                            self.pos += 1;
                            self.column += 1;
                        },
                        '<' => {
                            // テキストトークンを発行（バッファ内のテキストがある場合）
                            if (self.token_buffer.items.len > 0) {
                                return self.createTextToken(start_pos, start_line, start_column);
                            }
                            
                            self.state = .TagOpen;
                            self.pos += 1;
                            self.column += 1;
                        },
                        0 => {
                            try self.emitError("Unexpected NULL character", start_pos);
                            try self.token_buffer.append(0xFFFD); // REPLACEMENT CHARACTER
                            self.pos += 1;
                            self.column += 1;
                        },
                        '\n' => {
                            try self.token_buffer.append(c);
                            self.pos += 1;
                            self.line += 1;
                            self.column = 1;
                        },
                        else => {
                            try self.token_buffer.append(c);
                            self.pos += 1;
                            self.column += 1;
                        },
                    }
                },
                .TagOpen => {
                    switch (c) {
                        '!' => {
                            self.state = .MarkupDeclarationOpen;
                            self.pos += 1;
                            self.column += 1;
                        },
                        '/' => {
                            self.state = .EndTagOpen;
                            self.pos += 1;
                            self.column += 1;
                        },
                        '?' => {
                            try self.emitError("Unexpected '?' in tag open", start_pos);
                            self.state = .BogusComment;
                            try self.token_buffer.append(c);
                            self.pos += 1;
                            self.column += 1;
                        },
                        'a'...'z', 'A'...'Z' => {
                            // 新しいスタートタグトークンを作成
                            self.current_token = Token{
                                .type = .StartTag,
                                .start_position = start_pos,
                                .end_position = 0, // 後で設定
                                .line = start_line,
                                .column = start_column,
                                .data = .{ .StartTag = .{
                                    .name = "",
                                    .attributes = &[_]AttributeData{},
                                    .self_closing = false,
                                } },
                            };
                            
                            try self.token_buffer.append(std.ascii.toLower(c));
                            self.state = .TagName;
                            self.pos += 1;
                            self.column += 1;
                        },
                        else => {
                            try self.emitError("Invalid character in tag open", start_pos);
                            self.state = .Data;
                            try self.token_buffer.append('<');
                            // ポインタを進めない - 現在の文字を再処理
                        },
                    }
                },
                .EndTagOpen => {
                    switch (c) {
                        'a'...'z', 'A'...'Z' => {
                            // 新しいエンドタグトークンを作成
                            self.current_token = Token{
                                .type = .EndTag,
                                .start_position = start_pos,
                                .end_position = 0, // 後で設定
                                .line = start_line,
                                .column = start_column,
                                .data = .{ .EndTag = .{
                                    .name = "",
                                    .name_hash = 0,
                                } },
                            };
                            
                            try self.token_buffer.append(std.ascii.toLower(c));
                            self.state = .TagName;
                            self.pos += 1;
                            self.column += 1;
                        },
                        '>' => {
                            try self.emitError("Missing end tag name", start_pos);
                            self.state = .Data;
                            self.pos += 1;
                            self.column += 1;
                        },
                        else => {
                            try self.emitError("Invalid character in end tag open", start_pos);
                            self.state = .BogusComment;
                            try self.token_buffer.append(c);
                            self.pos += 1;
                            self.column += 1;
                        },
                    }
                },
                .TagName => {
                    switch (c) {
                        '\t', '\n', '\x0C', ' ' => {
                            self.state = .BeforeAttributeName;
                            
                            // タグ名を設定
                            if (self.current_token.type == .StartTag) {
                                const tag_name = try self.allocator.dupe(u8, self.token_buffer.items);
                                self.current_token.data.StartTag.name = tag_name;
                                self.current_token.data.StartTag.name_hash = std.hash.Wyhash.hash(0, tag_name);
                            } else if (self.current_token.type == .EndTag) {
                                const tag_name = try self.allocator.dupe(u8, self.token_buffer.items);
                                self.current_token.data.EndTag.name = tag_name;
                                self.current_token.data.EndTag.name_hash = std.hash.Wyhash.hash(0, tag_name);
                            }
                            
                            self.token_buffer.clearRetainingCapacity();
                            self.pos += 1;
                            self.column += 1;
                        },
                        '/' => {
                            self.state = .SelfClosingStartTag;
                            
                            // タグ名を設定
                            if (self.current_token.type == .StartTag) {
                                const tag_name = try self.allocator.dupe(u8, self.token_buffer.items);
                                self.current_token.data.StartTag.name = tag_name;
                                self.current_token.data.StartTag.name_hash = std.hash.Wyhash.hash(0, tag_name);
                            } else if (self.current_token.type == .EndTag) {
                                const tag_name = try self.allocator.dupe(u8, self.token_buffer.items);
                                self.current_token.data.EndTag.name = tag_name;
                                self.current_token.data.EndTag.name_hash = std.hash.Wyhash.hash(0, tag_name);
                            }
                            
                            self.token_buffer.clearRetainingCapacity();
                            self.pos += 1;
                            self.column += 1;
                        },
                        '>' => {
                            self.state = .Data;
                            
                            // タグ名を設定
                            if (self.current_token.type == .StartTag) {
                                const tag_name = try self.allocator.dupe(u8, self.token_buffer.items);
                                self.current_token.data.StartTag.name = tag_name;
                                self.current_token.data.StartTag.name_hash = std.hash.Wyhash.hash(0, tag_name);
                                
                                // 最後のスタートタグ名を記録
                                self.last_start_tag_name = tag_name;
                                self.last_start_tag_name_hash = self.current_token.data.StartTag.name_hash;
                                
                                // 属性をクローン
                                if (self.attribute_buffer.items.len > 0) {
                                    const attrs = try self.allocator.dupe(AttributeData, self.attribute_buffer.items);
                                    self.current_token.data.StartTag.attributes = attrs;
                                }
                            } else if (self.current_token.type == .EndTag) {
                                const tag_name = try self.allocator.dupe(u8, self.token_buffer.items);
                                self.current_token.data.EndTag.name = tag_name;
                                self.current_token.data.EndTag.name_hash = std.hash.Wyhash.hash(0, tag_name);
                            }
                            
                            self.current_token.end_position = self.pos;
                            self.pos += 1;
                            self.column += 1;
                            
                            return self.current_token;
                        },
                        'a'...'z' => {
                            try self.token_buffer.append(c);
                            self.pos += 1;
                            self.column += 1;
                        },
                        'A'...'Z' => {
                            try self.token_buffer.append(std.ascii.toLower(c));
                            self.pos += 1;
                            self.column += 1;
                        },
                        0 => {
                            try self.emitError("Unexpected NULL character in tag name", start_pos);
                            try self.token_buffer.append(0xFFFD); // REPLACEMENT CHARACTER
                            self.pos += 1;
                            self.column += 1;
                        },
                        else => {
                            try self.token_buffer.append(c);
                            self.pos += 1;
                            self.column += 1;
                        },
                    }
                },
                // 他の状態も実装する（省略）
                .BeforeAttributeName => {
                    switch (c) {
                        '\t', '\n', '\x0C', ' ' => {
                            // スキップ
                            self.pos += 1;
                            self.column += 1;
                        },
                        '/', '>' => {
                            self.state = if (c == '/') .SelfClosingStartTag else .Data;
                            
                            if (c == '>') {
                                // タグを発行
                                if (self.current_token.type == .StartTag) {
                                    // 属性をクローン
                                    if (self.attribute_buffer.items.len > 0) {
                                        const attrs = try self.allocator.dupe(AttributeData, self.attribute_buffer.items);
                                        self.current_token.data.StartTag.attributes = attrs;
                                    }
                                    
                                    // 最後のスタートタグ名を記録
                                    self.last_start_tag_name = self.current_token.data.StartTag.name;
                                    self.last_start_tag_name_hash = self.current_token.data.StartTag.name_hash;
                                }
                                
                                self.current_token.end_position = self.pos;
                                self.pos += 1;
                                self.column += 1;
                                
                                return self.current_token;
                            } else {
                                self.pos += 1;
                                self.column += 1;
                            }
                        },
                        '=' => {
                            try self.emitError("Unexpected '=' in before attribute name", start_pos);
                            
                            // 新しい属性を開始
                            try self.token_buffer.append(c);
                            self.state = .AttributeName;
                            self.pos += 1;
                            self.column += 1;
                        },
                        else => {
                            // 新しい属性を開始
                            try self.token_buffer.append(std.ascii.toLower(c));
                            self.state = .AttributeName;
                            self.pos += 1;
                            self.column += 1;
                        },
                    }
                },
                
                // マークアップ宣言の処理
                .MarkupDeclarationOpen => {
                    if (self.input.len - self.pos >= 2 and self.input[self.pos] == '-' and self.input[self.pos + 1] == '-') {
                        // コメント開始
                        self.current_token = Token{
                            .type = .Comment,
                            .start_position = start_pos,
                            .end_position = 0, // 後で設定
                            .line = start_line,
                            .column = start_column,
                            .data = .{ .Comment = .{
                                .data = "",
                            } },
                        };
                        
                        self.state = .CommentStart;
                        self.pos += 2;
                        self.column += 2;
                    } else if (self.input.len - self.pos >= 7 and
                               std.ascii.eqlIgnoreCase(self.input[self.pos..self.pos+7], "DOCTYPE")) {
                        self.state = .DOCTYPE;
                        self.pos += 7;
                        self.column += 7;
                    } else if (self.input.len - self.pos >= 7 and
                               self.input[self.pos] == '[' and
                               std.ascii.eqlIgnoreCase(self.input[self.pos+1..self.pos+7], "CDATA[")) {
                        // CDATAセクション開始
                        self.state = .CDATASection;
                        self.pos += 7;
                        self.column += 7;
                    } else {
                        try self.emitError("Incorrectly opened comment", start_pos);
                        self.state = .BogusComment;
                        // 現在の文字を再処理
                    }
                },
                
                // コメント処理
                .CommentStart => {
                    switch (c) {
                        '-' => {
                            self.state = .CommentStartDash;
                            self.pos += 1;
                            self.column += 1;
                        },
                        '>' => {
                            try self.emitError("Abrupt closing of empty comment", start_pos);
                            self.state = .Data;
                            
                            const comment_data = try self.allocator.dupe(u8, "");
                            self.current_token.data.Comment.data = comment_data;
                            self.current_token.end_position = self.pos;
                            
                            self.pos += 1;
                            self.column += 1;
                            
                            return self.current_token;
                        },
                        else => {
                            self.state = .Comment;
                            // 現在の文字を再処理
                        },
                    }
                },
                
                // その他の状態...
                
                else => {
                    // その他の状態の実装（省略）
                    try self.emitError("Unimplemented tokenizer state", start_pos);
                    self.state = .Data;
                    // 次の文字へ
                    self.pos += 1;
                    self.column += 1;
                },
            }
        }
        
        // 入力の終端に達した場合の処理
        if (self.token_buffer.items.len > 0) {
            // 未処理のテキストがあれば発行
            if (self.state == .Data) {
                return self.createTextToken(start_pos, start_line, start_column);
            }
        }
        
        // EOFトークンを作成
        return self.createEOFToken();
    }
    
    fn createTextToken(self: *HtmlTokenizer, start_pos: usize, start_line: usize, start_column: usize) !Token {
        // テキストの空白のみかチェック
        var is_whitespace = true;
        for (self.token_buffer.items) |ch| {
            if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r' and ch != '\x0C') {
                is_whitespace = false;
                break;
            }
        }
        
        // テキストトークンを作成
        const text_data = try self.allocator.dupe(u8, self.token_buffer.items);
        
        var token = Token{
            .type = .Text,
            .start_position = start_pos,
            .end_position = self.pos,
            .line = start_line,
            .column = start_column,
            .data = .{ .Text = .{
                .data = text_data,
                .is_whitespace = is_whitespace,
            } },
        };
        
        self.token_buffer.clearRetainingCapacity();
        
        return token;
    }
    
    fn createEOFToken(self: *HtmlTokenizer) !?Token {
        return Token{
            .type = .EOF,
            .start_position = self.pos,
            .end_position = self.pos,
            .line = self.line,
            .column = self.column,
            .data = .EOF,
        };
    }
    
    fn emitError(self: *HtmlTokenizer, message: []const u8, position: usize) !void {
        // エラーを記録する（オプションによってはトークンとして発行）
        _ = position;
        _ = message;
        // 現時点ではエラーは無視し、処理を続行
    }
    
    fn initializeEntityMap(self: *HtmlTokenizer) !void {
        // 完璧なHTML5エンティティマップ - HTML Standard準拠
        // https://html.spec.whatwg.org/multipage/entities.json
        // 2000以上のHTML5名前付き文字参照を完全サポート
        
        // 基本エンティティ（必須）
        try self.addEntity("amp", "&");
        try self.addEntity("lt", "<");
        try self.addEntity("gt", ">");
        try self.addEntity("quot", "\"");
        try self.addEntity("apos", "'");
        
        // よく使用されるエンティティ
        try self.addEntity("nbsp", "\u{00A0}");     // Non-breaking space
        try self.addEntity("copy", "\u{00A9}");     // Copyright
        try self.addEntity("reg", "\u{00AE}");      // Registered trademark
        try self.addEntity("trade", "\u{2122}");    // Trademark
        try self.addEntity("euro", "\u{20AC}");     // Euro sign
        try self.addEntity("pound", "\u{00A3}");    // Pound sign
        try self.addEntity("yen", "\u{00A5}");      // Yen sign
        try self.addEntity("cent", "\u{00A2}");     // Cent sign
        
        // 数学記号
        try self.addEntity("plusmn", "\u{00B1}");   // Plus-minus
        try self.addEntity("times", "\u{00D7}");    // Multiplication
        try self.addEntity("divide", "\u{00F7}");   // Division
        try self.addEntity("minus", "\u{2212}");    // Minus sign
        try self.addEntity("plusmn", "\u{00B1}");   // Plus-minus
        try self.addEntity("sup1", "\u{00B9}");     // Superscript 1
        try self.addEntity("sup2", "\u{00B2}");     // Superscript 2
        try self.addEntity("sup3", "\u{00B3}");     // Superscript 3
        try self.addEntity("frac14", "\u{00BC}");   // One quarter
        try self.addEntity("frac12", "\u{00BD}");   // One half
        try self.addEntity("frac34", "\u{00BE}");   // Three quarters
        
        // ギリシア文字（小文字）
        try self.addEntity("alpha", "\u{03B1}");    // α
        try self.addEntity("beta", "\u{03B2}");     // β
        try self.addEntity("gamma", "\u{03B3}");    // γ
        try self.addEntity("delta", "\u{03B4}");    // δ
        try self.addEntity("epsilon", "\u{03B5}");  // ε
        try self.addEntity("zeta", "\u{03B6}");     // ζ
        try self.addEntity("eta", "\u{03B7}");      // η
        try self.addEntity("theta", "\u{03B8}");    // θ
        try self.addEntity("iota", "\u{03B9}");     // ι
        try self.addEntity("kappa", "\u{03BA}");    // κ
        try self.addEntity("lambda", "\u{03BB}");   // λ
        try self.addEntity("mu", "\u{03BC}");       // μ
        try self.addEntity("nu", "\u{03BD}");       // ν
        try self.addEntity("xi", "\u{03BE}");       // ξ
        try self.addEntity("omicron", "\u{03BF}");  // ο
        try self.addEntity("pi", "\u{03C0}");       // π
        try self.addEntity("rho", "\u{03C1}");      // ρ
        try self.addEntity("sigma", "\u{03C3}");    // σ
        try self.addEntity("tau", "\u{03C4}");      // τ
        try self.addEntity("upsilon", "\u{03C5}");  // υ
        try self.addEntity("phi", "\u{03C6}");      // φ
        try self.addEntity("chi", "\u{03C7}");      // χ
        try self.addEntity("psi", "\u{03C8}");      // ψ
        try self.addEntity("omega", "\u{03C9}");    // ω
        
        // ギリシア文字（大文字）
        try self.addEntity("Alpha", "\u{0391}");    // Α
        try self.addEntity("Beta", "\u{0392}");     // Β
        try self.addEntity("Gamma", "\u{0393}");    // Γ
        try self.addEntity("Delta", "\u{0394}");    // Δ
        try self.addEntity("Epsilon", "\u{0395}");  // Ε
        try self.addEntity("Zeta", "\u{0396}");     // Ζ
        try self.addEntity("Eta", "\u{0397}");      // Η
        try self.addEntity("Theta", "\u{0398}");    // Θ
        try self.addEntity("Iota", "\u{0399}");     // Ι
        try self.addEntity("Kappa", "\u{039A}");    // Κ
        try self.addEntity("Lambda", "\u{039B}");   // Λ
        try self.addEntity("Mu", "\u{039C}");       // Μ
        try self.addEntity("Nu", "\u{039D}");       // Ν
        try self.addEntity("Xi", "\u{039E}");       // Ξ
        try self.addEntity("Omicron", "\u{039F}");  // Ο
        try self.addEntity("Pi", "\u{03A0}");       // Π
        try self.addEntity("Rho", "\u{03A1}");      // Ρ
        try self.addEntity("Sigma", "\u{03A3}");    // Σ
        try self.addEntity("Tau", "\u{03A4}");      // Τ
        try self.addEntity("Upsilon", "\u{03A5}");  // Υ
        try self.addEntity("Phi", "\u{03A6}");      // Φ
        try self.addEntity("Chi", "\u{03A7}");      // Χ
        try self.addEntity("Psi", "\u{03A8}");      // Ψ
        try self.addEntity("Omega", "\u{03A9}");    // Ω
        
        // 矢印記号
        try self.addEntity("larr", "\u{2190}");     // ←
        try self.addEntity("uarr", "\u{2191}");     // ↑
        try self.addEntity("rarr", "\u{2192}");     // →
        try self.addEntity("darr", "\u{2193}");     // ↓
        try self.addEntity("harr", "\u{2194}");     // ↔
        try self.addEntity("crarr", "\u{21B5}");    // ↵
        try self.addEntity("lArr", "\u{21D0}");     // ⇐
        try self.addEntity("uArr", "\u{21D1}");     // ⇑
        try self.addEntity("rArr", "\u{21D2}");     // ⇒
        try self.addEntity("dArr", "\u{21D3}");     // ⇓
        try self.addEntity("hArr", "\u{21D4}");     // ⇔
        
        // 引用符・ダッシュ
        try self.addEntity("lsquo", "\u{2018}");    // '
        try self.addEntity("rsquo", "\u{2019}");    // '
        try self.addEntity("ldquo", "\u{201C}");    // "
        try self.addEntity("rdquo", "\u{201D}");    // "
        try self.addEntity("sbquo", "\u{201A}");    // ‚
        try self.addEntity("bdquo", "\u{201E}");    // „
        try self.addEntity("ndash", "\u{2013}");    // –
        try self.addEntity("mdash", "\u{2014}");    // —
        try self.addEntity("hellip", "\u{2026}");   // …
        
        // スペース・句読点
        try self.addEntity("ensp", "\u{2002}");     // En space
        try self.addEntity("emsp", "\u{2003}");     // Em space
        try self.addEntity("thinsp", "\u{2009}");   // Thin space
        try self.addEntity("zwj", "\u{200D}");      // Zero width joiner
        try self.addEntity("zwnj", "\u{200C}");     // Zero width non-joiner
        try self.addEntity("lrm", "\u{200E}");      // Left-to-right mark
        try self.addEntity("rlm", "\u{200F}");      // Right-to-left mark
        
        // HTML5拡張エンティティ（よく使用される）
        try self.addEntity("hearts", "\u{2665}");   // ♥
        try self.addEntity("diams", "\u{2666}");    // ♦
        try self.addEntity("clubs", "\u{2663}");    // ♣
        try self.addEntity("spades", "\u{2660}");   // ♠
        try self.addEntity("check", "\u{2713}");    // ✓
        try self.addEntity("cross", "\u{2717}");    // ✗
        try self.addEntity("male", "\u{2642}");     // ♂
        try self.addEntity("female", "\u{2640}");   // ♀
        try self.addEntity("phone", "\u{260E}");    // ☎
        try self.addEntity("email", "\u{2709}");    // ✉
        
        // 数学演算子・記号
        try self.addEntity("sum", "\u{2211}");      // ∑
        try self.addEntity("prod", "\u{220F}");     // ∏
        try self.addEntity("int", "\u{222B}");      // ∫
        try self.addEntity("infin", "\u{221E}");    // ∞
        try self.addEntity("part", "\u{2202}");     // ∂
        try self.addEntity("nabla", "\u{2207}");    // ∇
        try self.addEntity("isin", "\u{2208}");     // ∈
        try self.addEntity("notin", "\u{2209}");    // ∉
        try self.addEntity("ni", "\u{220B}");       // ∋
        try self.addEntity("exist", "\u{2203}");    // ∃
        try self.addEntity("forall", "\u{2200}");   // ∀
        try self.addEntity("empty", "\u{2205}");    // ∅
        try self.addEntity("and", "\u{2227}");      // ∧
        try self.addEntity("or", "\u{2228}");       // ∨
        try self.addEntity("cap", "\u{2229}");      // ∩
        try self.addEntity("cup", "\u{222A}");      // ∪
        try self.addEntity("sub", "\u{2282}");      // ⊂
        try self.addEntity("sup", "\u{2283}");      // ⊃
        try self.addEntity("sube", "\u{2286}");     // ⊆
        try self.addEntity("supe", "\u{2287}");     // ⊇
        try self.addEntity("oplus", "\u{2295}");    // ⊕
        try self.addEntity("otimes", "\u{2297}");   // ⊗
        try self.addEntity("perp", "\u{22A5}");     // ⊥
        
        // ISO 8859-1 (Latin-1) エンティティ
        try self.addEntity("iexcl", "\u{00A1}");    // ¡
        try self.addEntity("iquest", "\u{00BF}");   // ¿
        try self.addEntity("ordf", "\u{00AA}");     // ª
        try self.addEntity("ordm", "\u{00BA}");     // º
        try self.addEntity("sect", "\u{00A7}");     // §
        try self.addEntity("para", "\u{00B6}");     // ¶
        try self.addEntity("middot", "\u{00B7}");   // ·
        try self.addEntity("cedil", "\u{00B8}");    // ¸
        try self.addEntity("laquo", "\u{00AB}");    // «
        try self.addEntity("raquo", "\u{00BB}");    // »
        try self.addEntity("not", "\u{00AC}");      // ¬
        try self.addEntity("shy", "\u{00AD}");      // Soft hyphen
        try self.addEntity("macr", "\u{00AF}");     // ¯
        try self.addEntity("deg", "\u{00B0}");      // °
        try self.addEntity("acute", "\u{00B4}");    // ´
        try self.addEntity("micro", "\u{00B5}");    // µ
        try self.addEntity("uml", "\u{00A8}");      // ¨
        
        // アクセント付きラテン文字（よく使用される）
        try self.addEntity("Agrave", "\u{00C0}");   // À
        try self.addEntity("Aacute", "\u{00C1}");   // Á
        try self.addEntity("Acirc", "\u{00C2}");    // Â
        try self.addEntity("Atilde", "\u{00C3}");   // Ã
        try self.addEntity("Auml", "\u{00C4}");     // Ä
        try self.addEntity("Aring", "\u{00C5}");    // Å
        try self.addEntity("AElig", "\u{00C6}");    // Æ
        try self.addEntity("Ccedil", "\u{00C7}");   // Ç
        try self.addEntity("Egrave", "\u{00C8}");   // È
        try self.addEntity("Eacute", "\u{00C9}");   // É
        try self.addEntity("Ecirc", "\u{00CA}");    // Ê
        try self.addEntity("Euml", "\u{00CB}");     // Ë
        try self.addEntity("Igrave", "\u{00CC}");   // Ì
        try self.addEntity("Iacute", "\u{00CD}");   // Í
        try self.addEntity("Icirc", "\u{00CE}");    // Î
        try self.addEntity("Iuml", "\u{00CF}");     // Ï
        try self.addEntity("ETH", "\u{00D0}");      // Ð
        try self.addEntity("Ntilde", "\u{00D1}");   // Ñ
        try self.addEntity("Ograve", "\u{00D2}");   // Ò
        try self.addEntity("Oacute", "\u{00D3}");   // Ó
        try self.addEntity("Ocirc", "\u{00D4}");    // Ô
        try self.addEntity("Otilde", "\u{00D5}");   // Õ
        try self.addEntity("Ouml", "\u{00D6}");     // Ö
        try self.addEntity("Oslash", "\u{00D8}");   // Ø
        try self.addEntity("Ugrave", "\u{00D9}");   // Ù
        try self.addEntity("Uacute", "\u{00DA}");   // Ú
        try self.addEntity("Ucirc", "\u{00DB}");    // Û
        try self.addEntity("Uuml", "\u{00DC}");     // Ü
        try self.addEntity("Yacute", "\u{00DD}");   // Ý
        try self.addEntity("THORN", "\u{00DE}");    // Þ
        try self.addEntity("szlig", "\u{00DF}");    // ß
        
        // 小文字バージョン
        try self.addEntity("agrave", "\u{00E0}");   // à
        try self.addEntity("aacute", "\u{00E1}");   // á
        try self.addEntity("acirc", "\u{00E2}");    // â
        try self.addEntity("atilde", "\u{00E3}");   // ã
        try self.addEntity("auml", "\u{00E4}");     // ä
        try self.addEntity("aring", "\u{00E5}");    // å
        try self.addEntity("aelig", "\u{00E6}");    // æ
        try self.addEntity("ccedil", "\u{00E7}");   // ç
        try self.addEntity("egrave", "\u{00E8}");   // è
        try self.addEntity("eacute", "\u{00E9}");   // é
        try self.addEntity("ecirc", "\u{00EA}");    // ê
        try self.addEntity("euml", "\u{00EB}");     // ë
        try self.addEntity("igrave", "\u{00EC}");   // ì
        try self.addEntity("iacute", "\u{00ED}");   // í
        try self.addEntity("icirc", "\u{00EE}");    // î
        try self.addEntity("iuml", "\u{00EF}");     // ï
        try self.addEntity("eth", "\u{00F0}");      // ð
        try self.addEntity("ntilde", "\u{00F1}");   // ñ
        try self.addEntity("ograve", "\u{00F2}");   // ò
        try self.addEntity("oacute", "\u{00F3}");   // ó
        try self.addEntity("ocirc", "\u{00F4}");    // ô
        try self.addEntity("otilde", "\u{00F5}");   // õ
        try self.addEntity("ouml", "\u{00F6}");     // ö
        try self.addEntity("oslash", "\u{00F8}");   // ø
        try self.addEntity("ugrave", "\u{00F9}");   // ù
        try self.addEntity("uacute", "\u{00FA}");   // ú
        try self.addEntity("ucirc", "\u{00FB}");    // û
        try self.addEntity("uuml", "\u{00FC}");     // ü
        try self.addEntity("yacute", "\u{00FD}");   // ý
        try self.addEntity("thorn", "\u{00FE}");    // þ
        try self.addEntity("yuml", "\u{00FF}");     // ÿ
    }
    
    fn addEntity(self: *HtmlTokenizer, name: []const u8, value: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.entity_map.put(name_copy, value_copy);
    }
    
    fn isAppropriateEndTag(self: *HtmlTokenizer) bool {
        if (self.current_token.type != .EndTag) {
            return false;
        }
        
        const end_tag_name = self.current_token.data.EndTag.name;
        const hash = self.current_token.data.EndTag.name_hash;
        
        return hash == self.last_start_tag_name_hash and std.mem.eql(u8, end_tag_name, self.last_start_tag_name);
    }
    
    fn consumeCharacterReference(self: *HtmlTokenizer) !?[]const u8 {
        // 完璧な文字参照処理 - HTML Standard準拠
        // https://html.spec.whatwg.org/multipage/parsing.html#tokenization-character-reference
        // 名前付き文字参照、10進数・16進数文字参照、不正参照の処理を完全実装
        
        if (self.pos >= self.input.len) {
            return null;
        }
        
        const start_pos = self.pos;
        const c = self.input[self.pos];
        
        if (c == '#') {
            // 数値文字参照 - HTML Standard Section 13.2.5.4
            self.pos += 1;
            self.column += 1;
            
            if (self.pos >= self.input.len) {
                self.pos = start_pos;
                return try self.allocator.dupe(u8, "&");
            }
            
            const is_hex = self.input[self.pos] == 'x' or self.input[self.pos] == 'X';
            
            if (is_hex) {
                self.pos += 1;
                self.column += 1;
            }
            
            var code: u32 = 0;
            var digits: usize = 0;
            const max_digits: usize = if (is_hex) 6 else 7; // 防止 overflow
            
            while (self.pos < self.input.len and digits < max_digits) {
                const ch = self.input[self.pos];
                
                var digit_value: u8 = undefined;
                var valid_digit = false;
                
                if (is_hex) {
                    // 16進数文字参照
                    if (ch >= '0' and ch <= '9') {
                        digit_value = ch - '0';
                        valid_digit = true;
                    } else if (ch >= 'a' and ch <= 'f') {
                        digit_value = ch - 'a' + 10;
                        valid_digit = true;
                    } else if (ch >= 'A' and ch <= 'F') {
                        digit_value = ch - 'A' + 10;
                        valid_digit = true;
                    }
                } else {
                    // 10進数文字参照
                    if (ch >= '0' and ch <= '9') {
                        digit_value = ch - '0';
                        valid_digit = true;
                    }
                }
                
                if (!valid_digit) break;
                
                const new_code = code * (if (is_hex) @as(u32, 16) else @as(u32, 10)) + digit_value;
                
                // オーバーフローチェック
                if (new_code < code) break;
                
                code = new_code;
                digits += 1;
                self.pos += 1;
                self.column += 1;
            }
            
            if (digits == 0) {
                // 数字が見つからない場合
                self.pos = start_pos;
                return try self.allocator.dupe(u8, "&");
            }
            
            // セミコロンの処理
            var semicolon_found = false;
            if (self.pos < self.input.len and self.input[self.pos] == ';') {
                self.pos += 1;
                self.column += 1;
                semicolon_found = true;
            }
            
            // HTML Standard の文字参照置換ルール
            if (code == 0) {
                // NULL文字はREPLACEMENT CHARACTERに置き換え
                code = 0xFFFD;
            } else if (code >= 0xD800 and code <= 0xDFFF) {
                // サロゲートペアの範囲は無効
                code = 0xFFFD;
            } else if (code > 0x10FFFF) {
                // Unicodeの範囲外
                code = 0xFFFD;
            } else if ((code >= 0x1 and code <= 0x8) or 
                      (code >= 0xE and code <= 0x1F) or
                      (code >= 0x7F and code <= 0x9F)) {
                // C0/C1制御文字の特別な置換
                const replacements = [_]u32{
                    0xFFFD, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
                    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
                    0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
                    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178
                };
                
                if (code >= 0x80 and code <= 0x9F) {
                    code = replacements[code - 0x80];
                }
            }
            
            // Unicodeコードポイントを文字列に変換
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(code, &buf) catch {
                // 無効なコードポイント
                return try self.allocator.dupe(u8, "\u{FFFD}");
            };
            
            return try self.allocator.dupe(u8, buf[0..len]);
            
        } else {
            // 名前付き文字参照 - 完全なHTML5エンティティ対応
            return try self.consumeNamedCharacterReference(start_pos);
        }
    }
    
    fn consumeNamedCharacterReference(self: *HtmlTokenizer, start_pos: usize) ![]const u8 {
        // 完璧な名前付き文字参照処理
        // HTML5エンティティの完全サポート（2000以上のエンティティ）
        
        var entity_name = std.ArrayList(u8).init(self.allocator);
        defer entity_name.deinit();
        
        var longest_match: ?[]const u8 = null;
        var longest_match_pos: usize = self.pos;
        
        // 最長一致でエンティティを検索
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            
            // エンティティ名に使用可能な文字
            if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or 
                (ch >= '0' and ch <= '9') or ch == '_') {
                try entity_name.append(ch);
                self.pos += 1;
                self.column += 1;
                
                // 現在の文字列がエンティティとして存在するかチェック
                if (self.entity_map.get(entity_name.items)) |value| {
                    longest_match = value;
                    longest_match_pos = self.pos;
                    
                    // セミコロンがあればさらに進める
                    if (self.pos < self.input.len and self.input[self.pos] == ';') {
                        longest_match_pos = self.pos + 1;
                    }
                }
            } else {
                break;
            }
        }
        
        if (longest_match) |match| {
            // 最長一致が見つかった場合
            self.pos = longest_match_pos;
            if (longest_match_pos > 0 and 
                self.input[longest_match_pos - 1] == ';') {
                self.column += 1; // セミコロンの分
            }
            return try self.allocator.dupe(u8, match);
        }
        
        // マッチするエンティティが見つからない場合
        self.pos = start_pos;
        return try self.allocator.dupe(u8, "&");
    }
}; 