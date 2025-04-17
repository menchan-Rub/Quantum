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
        // 一般的なHTMLエンティティの初期化
        try self.addEntity("amp", "&");
        try self.addEntity("lt", "<");
        try self.addEntity("gt", ">");
        try self.addEntity("quot", "\"");
        try self.addEntity("apos", "'");
        // 他のエンティティも追加...
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
        // 文字参照の処理（HTML仕様に従って実装）
        // 簡略化のため、基本的なエンティティのみサポート
        if (self.pos >= self.input.len) {
            return null;
        }
        
        const start_pos = self.pos;
        const c = self.input[self.pos];
        
        if (c == '#') {
            // 数値文字参照
            self.pos += 1;
            self.column += 1;
            
            if (self.pos >= self.input.len) {
                self.pos = start_pos;
                return null;
            }
            
            const is_hex = self.input[self.pos] == 'x' or self.input[self.pos] == 'X';
            
            if (is_hex) {
                self.pos += 1;
                self.column += 1;
            }
            
            var code: u32 = 0;
            var digits: usize = 0;
            
            while (self.pos < self.input.len) {
                const ch = self.input[self.pos];
                
                var digit_value: u8 = undefined;
                
                if (is_hex) {
                    // 16進数
                    if (ch >= '0' and ch <= '9') {
                        digit_value = ch - '0';
                    } else if (ch >= 'a' and ch <= 'f') {
                        digit_value = ch - 'a' + 10;
                    } else if (ch >= 'A' and ch <= 'F') {
                        digit_value = ch - 'A' + 10;
                    } else {
                        break;
                    }
                } else {
                    // 10進数
                    if (ch >= '0' and ch <= '9') {
                        digit_value = ch - '0';
                    } else {
                        break;
                    }
                }
                
                digits += 1;
                code = code * (if (is_hex) @as(u32, 16) else @as(u32, 10)) + digit_value;
                
                self.pos += 1;
                self.column += 1;
            }
            
            if (digits == 0) {
                self.pos = start_pos;
                return null;
            }
            
            if (self.pos < self.input.len and self.input[self.pos] == ';') {
                self.pos += 1;
                self.column += 1;
            }
            
            // Unicodeコードポイントを文字列に変換
            var buf: [4]u8 = undefined;
            if (code == 0) {
                // NULLはREPLACEMENT CHARACTERに置き換え
                code = 0xFFFD;
            }
            
            const len = std.unicode.utf8Encode(code, &buf) catch {
                // 無効なコードポイント
                return try self.allocator.dupe(u8, "\u{FFFD}");
            };
            
            return try self.allocator.dupe(u8, buf[0..len]);
        } else {
            // 名前付き文字参照
            var entity_name = std.ArrayList(u8).init(self.allocator);
            defer entity_name.deinit();
            
            while (self.pos < self.input.len) {
                const ch = self.input[self.pos];
                
                if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9')) {
                    try entity_name.append(ch);
                    self.pos += 1;
                    self.column += 1;
                } else {
                    break;
                }
            }
            
            if (entity_name.items.len == 0) {
                self.pos = start_pos;
                return null;
            }
            
            // セミコロンがあれば消費
            if (self.pos < self.input.len and self.input[self.pos] == ';') {
                self.pos += 1;
                self.column += 1;
            }
            
            // エンティティを解決
            if (self.entity_map.get(entity_name.items)) |value| {
                return try self.allocator.dupe(u8, value);
            }
            
            // 未知のエンティティは元の文字列を返す
            var result = std.ArrayList(u8).init(self.allocator);
            defer result.deinit();
            
            try result.append('&');
            try result.appendSlice(entity_name.items);
            if (self.input[self.pos - 1] == ';') {
                try result.append(';');
            }
            
            return try self.allocator.dupe(u8, result.items);
        }
    }
}; 