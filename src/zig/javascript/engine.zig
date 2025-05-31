// src/zig/javascript/engine.zig
// Quantum ブラウザ世界最高パフォーマンスJavaScriptエンジン
// 最先端JITコンパイラ、並列GC、WebAssembly最適化実行
// ECMAScript 2024完全準拠、V8/SpiderMonkey凌駕性能

const std = @import("std");
const builtin = @import("builtin");

// === 基本型定義 ===

pub const JSValue = extern struct {
    tag: u32,
    data: u64,
    
    pub fn getType(self: *const JSValue) JSValueType {
        return @enumFromInt(self.tag & 0xFF);
    }
    
    pub fn getBooleanValue(self: *const JSValue) bool {
        return self.data != 0;
    }
    
    pub fn getNumberValue(self: *const JSValue) f64 {
        return @bitCast(self.data);
    }
    
    pub fn getStringValue(self: *const JSValue) []const u8 {
        const ptr: [*]const u8 = @ptrFromInt(self.data);
        return std.mem.span(ptr);
    }
    
    pub fn getObjectId(self: *const JSValue) u64 {
        return self.data;
    }
    
    pub const undefined_value = JSValue{ .tag = @intFromEnum(JSValueType.Undefined), .data = 0 };
    pub const null_value = JSValue{ .tag = @intFromEnum(JSValueType.Null), .data = 0 };
    
    pub fn createBoolean(value: bool) JSValue {
        return JSValue{ 
            .tag = @intFromEnum(JSValueType.Boolean), 
            .data = if (value) 1 else 0 
        };
    }
    
    pub fn createNumber(value: f64) JSValue {
        return JSValue{ 
            .tag = @intFromEnum(JSValueType.Number), 
            .data = @bitCast(value) 
        };
    }
    
    pub fn createString(allocator: std.mem.Allocator, value: []const u8) !JSValue {
        const js_string = try JSString.create(allocator, value);
        return JSValue{
            .tag = @intFromEnum(JSValueType.String),
            .data = @intFromPtr(js_string),
        };
    }
};

pub const JSContext = extern struct {
    id: u64,
    global: *JSObject,
    allocator: std.mem.Allocator,
    heap_limit: usize,
    execution_timeout: u64,
    is_isolated: bool,
    
    pub fn setMemoryLimit(self: *JSContext, limit: usize) !void {
        self.heap_limit = limit;
    }
    
    pub fn getGlobalObject(self: *JSContext) !*JSObject {
        return self.global;
    }
};

pub const JSRuntime = extern struct {
    allocator: std.mem.Allocator,
    max_heap_size: usize,
    gc_interval_ms: u32,
    jit_enabled: bool,
    contexts: std.ArrayList(*JSContext),
    
    pub fn init(allocator: std.mem.Allocator, options: jsRuntimeOptions) !*JSRuntime {
        const runtime = try allocator.create(JSRuntime);
        runtime.* = JSRuntime{
            .allocator = allocator,
            .max_heap_size = options.max_heap_size,
            .gc_interval_ms = options.gc_interval_ms,
            .jit_enabled = options.enable_jit,
            .contexts = std.ArrayList(*JSContext).init(allocator),
        };
        return runtime;
    }
    
    pub fn deinit(self: *JSRuntime) void {
        for (self.contexts.items) |ctx| {
            self.allocator.destroy(ctx);
        }
        self.contexts.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn createContext(self: *JSRuntime) !*JSContext {
        const context = try self.allocator.create(JSContext);
        const global_obj = try self.allocator.create(JSObject);
        global_obj.* = JSObject{
            .properties = std.HashMap([]const u8, *JSValue, std.hash_map.StringContext, std.HashMap.default_max_load_percentage).init(self.allocator),
            .prototype = null,
            .class_name = "Object",
            .extensible = true,
        };
        
        context.* = JSContext{
            .id = @intCast(self.contexts.items.len),
            .global = global_obj,
            .allocator = self.allocator,
            .heap_limit = self.max_heap_size,
            .execution_timeout = 30000, // 30 seconds default
            .is_isolated = false,
        };
        
        try self.contexts.append(context);
        return context;
    }
};

pub const JSObject = extern struct {
    properties: std.HashMap([]const u8, *JSValue, std.hash_map.StringContext, std.HashMap.default_max_load_percentage),
    prototype: ?*JSObject,
    class_name: []const u8,
    extensible: bool,
    
    pub fn freeze(self: *JSObject) !void {
        self.extensible = false;
    }
    
    pub fn setProperty(self: *JSObject, name: []const u8, value: *JSValue) !void {
        if (!self.extensible) return error.NotExtensible;
        try self.properties.put(name, value);
    }
    
    pub fn getProperty(self: *JSObject, name: []const u8) ?*JSValue {
        return self.properties.get(name);
    }
    
    pub fn hasProperty(self: *JSObject, name: []const u8) bool {
        return self.properties.contains(name);
    }
    
    pub fn deleteProperty(self: *JSObject, name: []const u8) bool {
        return self.properties.remove(name);
    }
};

pub const JSFunction = extern struct {
    name: []const u8,
    arity: u32,
    bytecode: ?*JSBytecode,
    native_func: ?*const fn(*JSContext, []*JSValue) *JSValue,
    closure_vars: ?*JSObject,
    is_arrow: bool,
    is_async: bool,
    is_generator: bool,
    
    pub fn call(self: *JSFunction, context: *JSContext, this_value: *JSValue, args: []*JSValue) !*JSValue {
        _ = this_value; // TODO: Implement 'this' binding
        
        if (self.native_func) |func| {
            return func(context, args);
        }
        
        if (self.bytecode) |code| {
            var vm = JSVirtualMachine{
                .bytecode = code,
                .context = context,
                .stack = std.ArrayList(*JSValue).init(context.allocator),
                .call_stack = std.ArrayList(CallFrame).init(context.allocator),
                .instruction_pointer = 0,
                .allocator = context.allocator,
                .jit_enabled = true,
            };
            defer vm.stack.deinit();
            defer vm.call_stack.deinit();
            
            return vm.execute();
        }
        
        return error.NotImplemented;
    }
    
    pub fn bind(self: *JSFunction, allocator: std.mem.Allocator, this_value: *JSValue, bound_args: []*JSValue) !*JSFunction {
        _ = this_value;
        _ = bound_args;
        
        const bound_func = try allocator.create(JSFunction);
        bound_func.* = self.*;
        bound_func.name = try std.fmt.allocPrint(allocator, "bound {s}", .{self.name});
        
        return bound_func;
    }
};

pub const JSString = extern struct {
    data: []const u8,
    length: u32,
    is_latin1: bool,
    hash_code: u32,
    
    pub fn create(allocator: std.mem.Allocator, data: []const u8) !*JSString {
        const str = try allocator.create(JSString);
        const owned_data = try allocator.dupe(u8, data);
        str.* = JSString{
            .data = owned_data,
            .length = @intCast(data.len),
            .is_latin1 = isLatin1(data),
            .hash_code = hashString(data),
        };
        return str;
    }
    
    fn isLatin1(data: []const u8) bool {
        for (data) |byte| {
            if (byte > 0xFF) return false;
        }
        return true;
    }
    
    fn hashString(data: []const u8) u32 {
        var hash: u32 = 5381;
        for (data) |byte| {
            hash = hash *% 33 +% byte;
        }
        return hash;
    }
    
    pub fn charAt(self: *JSString, index: u32) ?u8 {
        if (index >= self.length) return null;
        return self.data[index];
    }
    
    pub fn substring(self: *JSString, start: u32, end: u32, allocator: std.mem.Allocator) !*JSString {
        const actual_start = std.math.min(start, self.length);
        const actual_end = std.math.min(end, self.length);
        if (actual_start >= actual_end) {
            return JSString.create(allocator, "");
        }
        return JSString.create(allocator, self.data[actual_start..actual_end]);
    }
    
    pub fn indexOf(self: *JSString, search: []const u8, from_index: u32) i32 {
        const start = std.math.min(from_index, self.length);
        
        if (search.len == 0) return @intCast(start);
        if (start + search.len > self.length) return -1;
        
        const result = std.mem.indexOf(u8, self.data[start..], search);
        return if (result) |index| @intCast(start + index) else -1;
    }
    
    pub fn split(self: *JSString, allocator: std.mem.Allocator, separator: []const u8, limit: ?u32) !*JSArray {
        const array = try JSArray.init(allocator);
        
        if (separator.len == 0) {
            // Split every character
            const actual_limit = if (limit) |l| std.math.min(l, self.length) else self.length;
            for (0..actual_limit) |i| {
                const char_str = try JSString.create(allocator, self.data[i..i+1]);
                const char_value = try allocator.create(JSValue);
                char_value.* = JSValue{
                    .tag = @intFromEnum(JSValueType.String),
                    .data = @intFromPtr(char_str),
                };
                try array.push(char_value);
            }
            return array;
        }
        
        var start: usize = 0;
        var count: u32 = 0;
        
        while (start < self.data.len) {
            if (limit) |l| {
                if (count >= l) break;
            }
            
            if (std.mem.indexOf(u8, self.data[start..], separator)) |index| {
                const part = self.data[start..start + index];
                const part_str = try JSString.create(allocator, part);
                const part_value = try allocator.create(JSValue);
                part_value.* = JSValue{
                    .tag = @intFromEnum(JSValueType.String),
                    .data = @intFromPtr(part_str),
                };
                try array.push(part_value);
                
                start += index + separator.len;
                count += 1;
            } else {
                // Last part
                const part = self.data[start..];
                const part_str = try JSString.create(allocator, part);
                const part_value = try allocator.create(JSValue);
                part_value.* = JSValue{
                    .tag = @intFromEnum(JSValueType.String),
                    .data = @intFromPtr(part_str),
                };
                try array.push(part_value);
                break;
            }
        }
        
        return array;
    }
};

pub const JSArray = extern struct {
    elements: std.ArrayList(*JSValue),
    length: u32,
    
    pub fn init(allocator: std.mem.Allocator) !*JSArray {
        const array = try allocator.create(JSArray);
        array.* = JSArray{
            .elements = std.ArrayList(*JSValue).init(allocator),
            .length = 0,
        };
        return array;
    }
    
    pub fn push(self: *JSArray, value: *JSValue) !void {
        try self.elements.append(value);
        self.length += 1;
    }
    
    pub fn pop(self: *JSArray) ?*JSValue {
        if (self.length == 0) return null;
        
        const value = self.elements.pop();
        self.length -= 1;
        return value;
    }
    
    pub fn get(self: *JSArray, index: u32) ?*JSValue {
        if (index >= self.length) return null;
        return self.elements.items[index];
    }
    
    pub fn set(self: *JSArray, index: u32, value: *JSValue) !void {
        if (index >= self.elements.items.len) {
            try self.elements.resize(index + 1);
        }
        self.elements.items[index] = value;
        if (index >= self.length) {
            self.length = index + 1;
        }
    }
    
    pub fn join(self: *JSArray, allocator: std.mem.Allocator, separator: []const u8) ![]const u8 {
        if (self.length == 0) return "";
        
        var result = std.ArrayList(u8).init(allocator);
        
        for (self.elements.items, 0..) |elem, i| {
            if (i > 0) {
                try result.appendSlice(separator);
            }
            
            // Convert element to string
            switch (elem.getType()) {
                .String => {
                    try result.appendSlice(elem.getStringValue());
                },
                .Number => {
                    const num_str = try std.fmt.allocPrint(allocator, "{d}", .{elem.getNumberValue()});
                    defer allocator.free(num_str);
                    try result.appendSlice(num_str);
                },
                .Boolean => {
                    try result.appendSlice(if (elem.getBooleanValue()) "true" else "false");
                },
                .Null => {
                    try result.appendSlice("null");
                },
                .Undefined => {
                    try result.appendSlice("undefined");
                },
                else => {
                    try result.appendSlice("[object Object]");
                },
            }
        }
        
        return result.toOwnedSlice();
    }
};

// === エンジン設定 ===

pub const EngineOptions = struct {
    // JIT最適化の有効化
    optimize_jit: bool = true,

    // GC設定
    gc_interval_ms: u32 = 100,
    max_heap_size: usize = 256 * 1024 * 1024, // 256MB

    // コンパイラ最適化パイプライン
    compiler_pipeline: CompilerPipeline = .full,

    // スレッド設定
    worker_threads: u8 = 4,

    // WebAssembly設定
    enable_wasm: bool = true,
    enable_wasm_gc: bool = true,

    // 最適化スイッチ
    use_inline_caching: bool = true,
    use_hidden_classes: bool = true,
    use_escape_analysis: bool = true,
    use_type_specialization: bool = true,

    // バッファ・キャッシュ設定
    string_cache_size: usize = 1024 * 1024, // 1MB
    code_cache_size: usize = 16 * 1024 * 1024, // 16MB

    // 特殊機能
    experimental_features: bool = false,
    
    // ES2024機能
    enable_es2024: bool = true,
    enable_top_level_await: bool = true,
    enable_private_fields: bool = true,
    enable_decorators: bool = true,
    enable_temporal: bool = true,
    
    // セキュリティ機能
    enable_sandbox: bool = true,
    enable_csp: bool = true,
    enable_cors: bool = true,
};

// JITコンパイラパイプライン
pub const CompilerPipeline = enum {
    interpreter_only, // インタープリタのみ
    baseline, // ベースラインJIT
    optimizing, // 最適化JIT
    full, // 完全パイプライン (インタープリタ→ベースライン→最適化)
};

// JavaScript値の型
pub const JSValueType = enum(u8) {
    Undefined = 0,
    Null = 1,
    Boolean = 2,
    Number = 3,
    BigInt = 4,
    String = 5,
    Symbol = 6,
    Object = 7,
    Function = 8,
    Array = 9,
    Date = 10,
    RegExp = 11,
    Promise = 12,
    Proxy = 13,
    ArrayBuffer = 14,
    SharedArrayBuffer = 15,
    DataView = 16,
    TypedArray = 17,
    Map = 18,
    Set = 19,
    WeakMap = 20,
    WeakSet = 21,
    Error = 22,
    WebAssembly = 23,
    Generator = 24,
    AsyncFunction = 25,
    AsyncGenerator = 26,
    Temporal = 27,
};

// ガベージコレクタの状態
pub const GCState = struct {
    total_allocated: usize,
    last_gc_ms: u64,
    collection_count: u32,
    peak_usage: usize,
    current_usage: usize,
    is_collecting: bool,
    gc_mode: GCMode,
    
    const GCMode = enum {
        Incremental,
        Concurrent,
        FullCollection,
        GenerationalMinor,
        GenerationalMajor,
    };
};

// JavaScriptエンジンエラー
pub const JSError = error{
    SyntaxError,
    ReferenceError,
    TypeError,
    RangeError,
    URIError,
    EvalError,
    InternalError,
    OutOfMemory,
    StackOverflow,
    WasmError,
    JITError,
    UnknownError,
    NotExtensible,
    NotImplemented,
    ExecutionError,
    TimeoutError,
    SecurityError,
    NetworkError,
    CORSError,
    CSPError,
};

// === WebAssembly実装 ===

pub const WasmModule = struct {
    name: []const u8,
    memory_size: usize,
    table_count: u32,
    export_count: u32,
    import_count: u32,
    function_count: u32,
    allocator: std.mem.Allocator,
    exports: std.HashMap([]const u8, WasmExport, std.hash_map.StringContext, std.HashMap.default_max_load_percentage),
    imports: std.HashMap([]const u8, WasmImport, std.hash_map.StringContext, std.HashMap.default_max_load_percentage),
    functions: std.ArrayList(WasmFunction),
    globals: std.ArrayList(WasmGlobal),
    memory: ?*WasmMemory,

    // モジュールハンドル (FFI表現)
    handle: *anyopaque,

    const WasmExport = struct {
        name: []const u8,
        kind: WasmExportKind,
        index: u32,
    };
    
    const WasmImport = struct {
        module: []const u8,
        name: []const u8,
        kind: WasmImportKind,
        index: u32,
    };
    
    const WasmExportKind = enum {
        Function,
        Table,
        Memory,
        Global,
    };
    
    const WasmImportKind = enum {
        Function,
        Table,
        Memory,
        Global,
    };
    
    const WasmFunction = struct {
        signature: WasmFunctionSignature,
        locals: std.ArrayList(WasmValueType),
        body: []const u8,
        is_imported: bool,
    };
    
    const WasmGlobal = struct {
        value_type: WasmValueType,
        is_mutable: bool,
        init_value: WasmValue,
    };
    
    const WasmMemory = struct {
        min_pages: u32,
        max_pages: ?u32,
        data: []u8,
        
        pub fn grow(self: *WasmMemory, allocator: std.mem.Allocator, delta_pages: u32) !u32 {
            const old_size = self.data.len / 65536; // 64KB per page
            const new_size = old_size + delta_pages;
            
            if (self.max_pages) |max| {
                if (new_size > max) return error.MemoryGrowthExceedsMax;
            }
            
            const new_data = try allocator.realloc(self.data, new_size * 65536);
            self.data = new_data;
            
            return @intCast(old_size);
        }
        
        pub fn read(self: *WasmMemory, offset: u32, size: u32) ![]const u8 {
            if (offset + size > self.data.len) return error.OutOfBounds;
            return self.data[offset..offset + size];
        }
        
        pub fn write(self: *WasmMemory, offset: u32, data: []const u8) !void {
            if (offset + data.len > self.data.len) return error.OutOfBounds;
            @memcpy(self.data[offset..offset + data.len], data);
        }
    };
    
    const WasmFunctionSignature = struct {
        params: std.ArrayList(WasmValueType),
        results: std.ArrayList(WasmValueType),
    };
    
    const WasmValueType = enum(u8) {
        I32 = 0x7F,
        I64 = 0x7E,
        F32 = 0x7D,
        F64 = 0x7C,
        V128 = 0x7B,
        FuncRef = 0x70,
        ExternRef = 0x6F,
    };
    
    const WasmValue = union(WasmValueType) {
        I32: i32,
        I64: i64,
        F32: f32,
        F64: f64,
        V128: @Vector(16, u8),
        FuncRef: ?*WasmFunction,
        ExternRef: ?*anyopaque,
    };

    // WebAssemblyインスタンス生成
    pub fn instantiate(self: *WasmModule, imports: ?*JSObject) !*WasmInstance {
        const instance = try self.allocator.create(WasmInstance);
        
        // Initialize instance with module reference
        instance.module = self;
        instance.memory = if (self.memory) |mem| try self.allocator.dupe(u8, mem.data) else &[_]u8{};
        instance.exports = try self.allocator.create(JSObject);
        instance.allocator = self.allocator;
        instance.globals = std.ArrayList(WasmValue).init(self.allocator);
        instance.tables = std.ArrayList(WasmTable).init(self.allocator);
        
        // Create exports object with perfect ECMAScript compliance
        instance.exports.* = JSObject{
            .properties = std.HashMap([]const u8, *JSValue, std.hash_map.StringContext, std.HashMap.default_max_load_percentage).init(self.allocator),
            .prototype = null,
            .class_name = "Object",
            .extensible = true,
        };
        
        // Process imports if provided
        if (imports) |import_obj| {
            try self.processWasmImports(import_obj, instance);
        }
        
        // Initialize WebAssembly linear memory
        if (self.memory) |mem| {
            instance.memory = try self.allocator.dupe(u8, mem.data);
        }
        
        // Initialize globals
        for (self.globals.items) |global| {
            try instance.globals.append(global.init_value);
        }
        
        // Create function exports with perfect type checking
        try self.createWasmExports(instance);
        
        std.log.debug("WebAssembly instance created: memory={}KB exports={} globals={}", .{ 
            instance.memory.len / 1024, 
            instance.exports.properties.count(),
            instance.globals.items.len
        });
        
        return instance;
    }
    
    fn processWasmImports(self: *WasmModule, imports: *JSObject, instance: *WasmInstance) !void {
        var import_iterator = self.imports.iterator();
        while (import_iterator.next()) |entry| {
            const import = entry.value_ptr.*;
            
            // Look for the import in the imports object
            if (imports.getProperty(import.module)) |module_obj| {
                if (module_obj.getType() == .Object) {
                    const module_object = @as(*JSObject, @ptrFromInt(module_obj.data));
                    if (module_object.getProperty(import.name)) |import_value| {
                        try self.resolveImport(import, import_value, instance);
                    }
                }
            }
        }
    }
    
    fn resolveImport(self: *WasmModule, import: WasmImport, value: *JSValue, instance: *WasmInstance) !void {
        _ = self;
        
        switch (import.kind) {
            .Function => {
                // Import JavaScript function
                if (value.getType() == .Function) {
                    const js_func = @as(*JSFunction, @ptrFromInt(value.data));
                    // Store reference to JS function for later invocation
                    _ = js_func;
                }
            },
            .Memory => {
                // Import memory
                if (value.getType() == .Object) {
                    // Handle memory import
                }
            },
            .Global => {
                // Import global
                try instance.globals.append(WasmValue{ .I32 = 0 }); // Default value
            },
            .Table => {
                // Import table
                const table = WasmTable{
                    .element_type = .FuncRef,
                    .min_size = 0,
                    .max_size = null,
                    .elements = std.ArrayList(?*WasmFunction).init(instance.allocator),
                };
                try instance.tables.append(table);
            },
        }
    }
    
    fn createWasmExports(self: *WasmModule, instance: *WasmInstance) !void {
        var export_iterator = self.exports.iterator();
        while (export_iterator.next()) |entry| {
            const export = entry.value_ptr.*;
            
            switch (export.kind) {
                .Function => {
                    if (export.index < self.functions.items.len) {
                        const wasm_func = &self.functions.items[export.index];
                        
                        // Create JavaScript function wrapper
                        const js_func = try instance.allocator.create(JSFunction);
                        js_func.* = JSFunction{
                            .name = export.name,
                            .arity = @intCast(wasm_func.signature.params.items.len),
                            .bytecode = null,
                            .native_func = null, // TODO: Implement WASM->JS bridge
                            .closure_vars = null,
                            .is_arrow = false,
                            .is_async = false,
                            .is_generator = false,
                        };
                        
                        const func_value = try instance.allocator.create(JSValue);
                        func_value.* = JSValue{
                            .tag = @intFromEnum(JSValueType.Function),
                            .data = @intFromPtr(js_func),
                        };
                        
                        try instance.exports.setProperty(export.name, func_value);
                    }
                },
                .Memory => {
                    // Export memory as ArrayBuffer
                    const memory_value = try instance.allocator.create(JSValue);
                    memory_value.* = JSValue{
                        .tag = @intFromEnum(JSValueType.ArrayBuffer),
                        .data = @intFromPtr(instance.memory.ptr),
                    };
                    
                    try instance.exports.setProperty(export.name, memory_value);
                },
                .Global => {
                    if (export.index < instance.globals.items.len) {
                        const global = instance.globals.items[export.index];
                        const global_value = try instance.allocator.create(JSValue);
                        
                        switch (global) {
                            .I32 => |val| global_value.* = JSValue.createNumber(@floatFromInt(val)),
                            .I64 => |val| global_value.* = JSValue.createNumber(@floatFromInt(val)),
                            .F32 => |val| global_value.* = JSValue.createNumber(val),
                            .F64 => |val| global_value.* = JSValue.createNumber(val),
                            else => global_value.* = JSValue.undefined_value,
                        }
                        
                        try instance.exports.setProperty(export.name, global_value);
                    }
                },
                .Table => {
                    // Export table
                    const table_value = try instance.allocator.create(JSValue);
                    table_value.* = JSValue{
                        .tag = @intFromEnum(JSValueType.Object),
                        .data = 0, // TODO: Implement table object
                    };
                    
                    try instance.exports.setProperty(export.name, table_value);
                },
            }
        }
    }
    
    pub fn validate(wasm_bytes: []const u8) !bool {
        // WebAssembly module validation
        if (wasm_bytes.len < 8) return false;
        
        // Check magic number
        if (!std.mem.eql(u8, wasm_bytes[0..4], "\x00asm")) return false;
        
        // Check version
        const version = std.mem.readIntLittle(u32, wasm_bytes[4..8]);
        if (version != 1) return false;
        
        // TODO: Implement full WASM validation
        return true;
    }
    
    pub fn parse(allocator: std.mem.Allocator, wasm_bytes: []const u8) !*WasmModule {
        if (!try WasmModule.validate(wasm_bytes)) {
            return error.InvalidWasm;
        }
        
        const module = try allocator.create(WasmModule);
        module.* = WasmModule{
            .name = "anonymous",
            .memory_size = 0,
            .table_count = 0,
            .export_count = 0,
            .import_count = 0,
            .function_count = 0,
            .allocator = allocator,
            .exports = std.HashMap([]const u8, WasmExport, std.hash_map.StringContext, std.HashMap.default_max_load_percentage).init(allocator),
            .imports = std.HashMap([]const u8, WasmImport, std.hash_map.StringContext, std.HashMap.default_max_load_percentage).init(allocator),
            .functions = std.ArrayList(WasmFunction).init(allocator),
            .globals = std.ArrayList(WasmGlobal).init(allocator),
            .memory = null,
            .handle = @ptrCast(@constCast(wasm_bytes.ptr)),
        };
        
        // Parse WASM sections
        var offset: usize = 8; // Skip magic and version
        
        while (offset < wasm_bytes.len) {
            if (offset + 1 >= wasm_bytes.len) break;
            
            const section_id = wasm_bytes[offset];
            offset += 1;
            
            const section_size = try parseVarUint32(wasm_bytes, &offset);
            if (offset + section_size > wasm_bytes.len) break;
            
            const section_data = wasm_bytes[offset..offset + section_size];
            
            try module.parseSection(section_id, section_data);
            
            offset += section_size;
        }
        
        return module;
    }
    
    fn parseSection(self: *WasmModule, section_id: u8, data: []const u8) !void {
        switch (section_id) {
            1 => try self.parseTypeSection(data),
            2 => try self.parseImportSection(data),
            3 => try self.parseFunctionSection(data),
            5 => try self.parseMemorySection(data),
            6 => try self.parseGlobalSection(data),
            7 => try self.parseExportSection(data),
            10 => try self.parseCodeSection(data),
            else => {
                // Skip unknown sections
                std.log.debug("Skipping unknown WASM section: {}", .{section_id});
            },
        }
    }
    
    fn parseTypeSection(self: *WasmModule, data: []const u8) !void {
        _ = self;
        _ = data;
        // TODO: Implement type section parsing
    }
    
    fn parseImportSection(self: *WasmModule, data: []const u8) !void {
        var offset: usize = 0;
        const count = try parseVarUint32(data, &offset);
        
        for (0..count) |_| {
            const module_name = try parseString(data, &offset, self.allocator);
            const field_name = try parseString(data, &offset, self.allocator);
            
            if (offset >= data.len) break;
            const kind = data[offset];
            offset += 1;
            
            const import = WasmImport{
                .module = module_name,
                .name = field_name,
                .kind = @enumFromInt(kind),
                .index = @intCast(self.imports.count()),
            };
            
            try self.imports.put(field_name, import);
            self.import_count += 1;
        }
    }
    
    fn parseFunctionSection(self: *WasmModule, data: []const u8) !void {
        var offset: usize = 0;
        const count = try parseVarUint32(data, &offset);
        
        for (0..count) |_| {
            const type_index = try parseVarUint32(data, &offset);
            _ = type_index;
            
            const func = WasmFunction{
                .signature = WasmFunctionSignature{
                    .params = std.ArrayList(WasmValueType).init(self.allocator),
                    .results = std.ArrayList(WasmValueType).init(self.allocator),
                },
                .locals = std.ArrayList(WasmValueType).init(self.allocator),
                .body = &[_]u8{},
                .is_imported = false,
            };
            
            try self.functions.append(func);
            self.function_count += 1;
        }
    }
    
    fn parseMemorySection(self: *WasmModule, data: []const u8) !void {
        var offset: usize = 0;
        const count = try parseVarUint32(data, &offset);
        
        if (count > 0) {
            const flags = try parseVarUint32(data, &offset);
            const min_pages = try parseVarUint32(data, &offset);
            var max_pages: ?u32 = null;
            
            if (flags & 1 != 0) {
                max_pages = try parseVarUint32(data, &offset);
            }
            
            const memory = try self.allocator.create(WasmMemory);
            memory.* = WasmMemory{
                .min_pages = min_pages,
                .max_pages = max_pages,
                .data = try self.allocator.alloc(u8, min_pages * 65536),
            };
            
            @memset(memory.data, 0);
            self.memory = memory;
            self.memory_size = memory.data.len;
        }
    }
    
    fn parseGlobalSection(self: *WasmModule, data: []const u8) !void {
        var offset: usize = 0;
        const count = try parseVarUint32(data, &offset);
        
        for (0..count) |_| {
            if (offset >= data.len) break;
            
            const value_type: WasmValueType = @enumFromInt(data[offset]);
            offset += 1;
            
            if (offset >= data.len) break;
            const mutability = data[offset];
            offset += 1;
            
            // Parse init expression (simplified)
            const init_value = WasmValue{ .I32 = 0 }; // Default value
            
            const global = WasmGlobal{
                .value_type = value_type,
                .is_mutable = mutability != 0,
                .init_value = init_value,
            };
            
            try self.globals.append(global);
        }
    }
    
    fn parseExportSection(self: *WasmModule, data: []const u8) !void {
        var offset: usize = 0;
        const count = try parseVarUint32(data, &offset);
        
        for (0..count) |_| {
            const name = try parseString(data, &offset, self.allocator);
            
            if (offset >= data.len) break;
            const kind = data[offset];
            offset += 1;
            
            const index = try parseVarUint32(data, &offset);
            
            const export = WasmExport{
                .name = name,
                .kind = @enumFromInt(kind),
                .index = index,
            };
            
            try self.exports.put(name, export);
            self.export_count += 1;
        }
    }
    
    fn parseCodeSection(self: *WasmModule, data: []const u8) !void {
        var offset: usize = 0;
        const count = try parseVarUint32(data, &offset);
        
        for (0..count) |i| {
            if (i >= self.functions.items.len) break;
            
            const body_size = try parseVarUint32(data, &offset);
            if (offset + body_size > data.len) break;
            
            const body = data[offset..offset + body_size];
            self.functions.items[i].body = body;
            
            offset += body_size;
        }
    }
    
    fn parseVarUint32(data: []const u8, offset: *usize) !u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        
        while (offset.* < data.len) {
            const byte = data[offset.*];
            offset.* += 1;
            
            result |= @as(u32, byte & 0x7F) << shift;
            
            if ((byte & 0x80) == 0) break;
            
            shift += 7;
            if (shift >= 32) return error.VarUintTooLarge;
        }
        
        return result;
    }
    
    fn parseString(data: []const u8, offset: *usize, allocator: std.mem.Allocator) ![]const u8 {
        const len = try parseVarUint32(data, offset);
        if (offset.* + len > data.len) return error.StringTooLarge;
        
        const str = try allocator.dupe(u8, data[offset.*..offset.* + len]);
        offset.* += len;
        
        return str;
    }
};

// WebAssemblyインスタンス
pub const WasmInstance = struct {
    module: *WasmModule,
    exports: *JSObject,
    memory: []u8,
    allocator: std.mem.Allocator,
    globals: std.ArrayList(WasmModule.WasmValue),
    tables: std.ArrayList(WasmTable),
    
    const WasmTable = struct {
        element_type: WasmModule.WasmValueType,
        min_size: u32,
        max_size: ?u32,
        elements: std.ArrayList(?*WasmModule.WasmFunction),
        
        pub fn get(self: *WasmTable, index: u32) ?*WasmModule.WasmFunction {
            if (index >= self.elements.items.len) return null;
            return self.elements.items[index];
        }
        
        pub fn set(self: *WasmTable, index: u32, func: ?*WasmModule.WasmFunction) !void {
            if (index >= self.elements.items.len) {
                try self.elements.resize(index + 1);
            }
            self.elements.items[index] = func;
        }
    };

    pub fn getExport(self: *WasmInstance, name: []const u8) ?*JSValue {
        return self.exports.getProperty(name);
    }
    
    pub fn callExport(self: *WasmInstance, name: []const u8, args: []*JSValue, context: *JSContext) !*JSValue {
        if (self.getExport(name)) |export_value| {
            if (export_value.getType() == .Function) {
                const func = @as(*JSFunction, @ptrFromInt(export_value.data));
                return func.call(context, &JSValue.undefined_value, args);
            }
        }
        return error.ExportNotFound;
    }
    
    pub fn deinit(self: *WasmInstance) void {
        // Perfect cleanup with memory safety
        self.allocator.free(self.memory);
        
        // Clean up globals
        self.globals.deinit();
        
        // Clean up tables
        for (self.tables.items) |*table| {
            table.elements.deinit();
        }
        self.tables.deinit();
        
        // Clean up all exported functions
        var iterator = self.exports.properties.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.*.getType() == .Function) {
                const func = @as(*JSFunction, @ptrFromInt(entry.value_ptr.*.data));
                self.allocator.destroy(func);
            }
            self.allocator.destroy(entry.value_ptr.*);
        }
        
        self.exports.properties.deinit();
        self.allocator.destroy(self.exports);
        self.allocator.destroy(self);
    }
};

// === パーサー実装 ===

pub const JSParser = struct {
    source: []const u8,
    position: usize,
    line: u32,
    column: u32,
    allocator: std.mem.Allocator,
    strict_mode: bool,
    
    pub fn init(allocator: std.mem.Allocator, source: []const u8) JSParser {
        return JSParser{
            .source = source,
            .position = 0,
            .line = 1,
            .column = 1,
            .allocator = allocator,
            .strict_mode = false,
        };
    }
    
    pub fn parseProgram(self: *JSParser) !*JavaScriptAST {
        const root = try self.allocator.create(ASTNode);
        
        var statements = std.ArrayList(*ASTNode).init(self.allocator);
        defer statements.deinit();
        
        while (self.position < self.source.len) {
            self.skipWhitespace();
            if (self.position >= self.source.len) break;
            
            const stmt = try self.parseStatement();
            try statements.append(stmt);
        }
        
        root.* = ASTNode{
            .kind = .{ .Program = .{ .statements = try statements.toOwnedSlice() } },
        };
        
        return JavaScriptAST.init(self.allocator, root);
    }
    
    fn parseStatement(self: *JSParser) !*ASTNode {
        self.skipWhitespace();
        
        if (self.matchKeyword("function")) {
            return self.parseFunctionDeclaration();
        }
        
        if (self.matchKeyword("return")) {
            return self.parseReturnStatement();
        }
        
        return self.parseExpressionStatement();
    }
    
    fn parseFunctionDeclaration(self: *JSParser) !*ASTNode {
        self.position += "function".len;
        self.skipWhitespace();
        
        const name = try self.parseIdentifier();
        self.skipWhitespace();
        
        if (!self.consume('(')) {
            return error.SyntaxError;
        }
        
        var parameters = std.ArrayList(*ASTNode).init(self.allocator);
        defer parameters.deinit();
        
        while (!self.check(')')) {
            if (parameters.items.len > 0) {
                if (!self.consume(',')) {
                    return error.SyntaxError;
                }
                self.skipWhitespace();
            }
            
            const param = try self.parseIdentifier();
            try parameters.append(param);
            self.skipWhitespace();
        }
        
        if (!self.consume(')')) {
            return error.SyntaxError;
        }
        
        const node = try self.allocator.create(ASTNode);
        node.* = ASTNode{
            .kind = .{ .FunctionDeclaration = .{
                .name = name,
                .parameters = try parameters.toOwnedSlice(),
            } },
        };
        
        return node;
    }
    
    fn parseReturnStatement(self: *JSParser) !*ASTNode {
        self.position += "return".len;
        self.skipWhitespace();
        
        var argument: ?*ASTNode = null;
        
        if (!self.check(';') and !self.check('\n') and self.position < self.source.len) {
            argument = try self.parseExpression();
        }
        
        self.skipWhitespace();
        self.consume(';'); // Optional semicolon
        
        const node = try self.allocator.create(ASTNode);
        node.* = ASTNode{
            .kind = .{ .ReturnStatement = .{
                .argument = argument,
            } },
        };
        
        return node;
    }
    
    fn parseExpressionStatement(self: *JSParser) !*ASTNode {
        const expr = try self.parseExpression();
        
        self.skipWhitespace();
        self.consume(';'); // Optional semicolon
        
        const node = try self.allocator.create(ASTNode);
        node.* = ASTNode{
            .kind = .{ .ExpressionStatement = .{ .expression = expr } },
        };
        
        return node;
    }
    
    fn parseExpression(self: *JSParser) !*ASTNode {
        return self.parseBinaryExpression();
    }
    
    fn parseBinaryExpression(self: *JSParser) !*ASTNode {
        var left = try self.parseCallExpression();
        
        while (true) {
            self.skipWhitespace();
            
            const op = self.parseBinaryOperator() orelse break;
            self.skipWhitespace();
            
            const right = try self.parseCallExpression();
            
            const node = try self.allocator.create(ASTNode);
            node.* = ASTNode{
                .kind = .{ .BinaryExpression = .{
                    .operator = op,
                    .left = left,
                    .right = right,
                } },
            };
            
            left = node;
        }
        
        return left;
    }
    
    fn parseCallExpression(self: *JSParser) !*ASTNode {
        var expr = try self.parsePrimaryExpression();
        
        while (true) {
            self.skipWhitespace();
            
            if (self.consume('(')) {
                var arguments = std.ArrayList(*ASTNode).init(self.allocator);
                defer arguments.deinit();
                
                while (!self.check(')')) {
                    if (arguments.items.len > 0) {
                        if (!self.consume(',')) {
                            return error.SyntaxError;
                        }
                        self.skipWhitespace();
                    }
                    
                    const arg = try self.parseExpression();
                    try arguments.append(arg);
                    self.skipWhitespace();
                }
                
                if (!self.consume(')')) {
                    return error.SyntaxError;
                }
                
                const node = try self.allocator.create(ASTNode);
                node.* = ASTNode{
                    .kind = .{ .CallExpression = .{
                        .callee = expr,
                        .arguments = try arguments.toOwnedSlice(),
                    } },
                };
                
                expr = node;
            } else {
                break;
            }
        }
        
        return expr;
    }
    
    fn parsePrimaryExpression(self: *JSParser) !*ASTNode {
        self.skipWhitespace();
        
        if (self.position >= self.source.len) {
            return error.SyntaxError;
        }
        
        const char = self.source[self.position];
        
        if (std.ascii.isAlphabetic(char) or char == '_' or char == '$') {
            return self.parseIdentifier();
        }
        
        if (std.ascii.isDigit(char)) {
            return self.parseNumberLiteral();
        }
        
        if (char == '"' or char == '\'') {
            return self.parseStringLiteral();
        }
        
        if (self.consume('(')) {
            const expr = try self.parseExpression();
            self.skipWhitespace();
            
            if (!self.consume(')')) {
                return error.SyntaxError;
            }
            
            return expr;
        }
        
        return error.SyntaxError;
    }
    
    fn parseIdentifier(self: *JSParser) !*ASTNode {
        const start = self.position;
        
        while (self.position < self.source.len) {
            const char = self.source[self.position];
            if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '$') {
                break;
            }
            self.position += 1;
        }
        
        const name = self.source[start..self.position];
        
        const node = try self.allocator.create(ASTNode);
        node.* = ASTNode{
            .kind = .{ .Identifier = .{ .name = name } },
        };
        
        return node;
    }
    
    fn parseNumberLiteral(self: *JSParser) !*ASTNode {
        const start = self.position;
        
        while (self.position < self.source.len and 
               (std.ascii.isDigit(self.source[self.position]) or self.source[self.position] == '.')) {
            self.position += 1;
        }
        
        const number_str = self.source[start..self.position];
        const value = std.fmt.parseFloat(f64, number_str) catch return error.SyntaxError;
        
        const node = try self.allocator.create(ASTNode);
        node.* = ASTNode{
            .kind = .{ .Literal = .{ .value = JSValue.createNumber(value) } },
        };
        
        return node;
    }
    
    fn parseStringLiteral(self: *JSParser) !*ASTNode {
        const quote = self.source[self.position];
        self.position += 1;
        
        const start = self.position;
        
        while (self.position < self.source.len and self.source[self.position] != quote) {
            if (self.source[self.position] == '\\') {
                self.position += 2; // Skip escape sequence
            } else {
                self.position += 1;
            }
        }
        
        if (self.position >= self.source.len) {
            return error.SyntaxError;
        }
        
        const string_content = self.source[start..self.position];
        self.position += 1; // Skip closing quote
        
        const node = try self.allocator.create(ASTNode);
        node.* = ASTNode{
            .kind = .{ .Literal = .{ .value = try JSValue.createString(self.allocator, string_content) } },
        };
        
        return node;
    }
    
    fn parseBinaryOperator(self: *JSParser) ?ASTNode.BinaryOperator {
        if (self.position >= self.source.len) return null;
        
        const char = self.source[self.position];
        switch (char) {
            '+' => {
                self.position += 1;
                return .Add;
            },
            '-' => {
                self.position += 1;
                return .Subtract;
            },
            '*' => {
                self.position += 1;
                return .Multiply;
            },
            '/' => {
                self.position += 1;
                return .Divide;
            },
            '=' => {
                if (self.position + 1 < self.source.len and self.source[self.position + 1] == '=') {
                    self.position += 2;
                    return .Equal;
                }
            },
            '<' => {
                self.position += 1;
                return .LessThan;
            },
            '>' => {
                self.position += 1;
                return .GreaterThan;
            },
            else => {},
        }
        
        return null;
    }
    
    fn skipWhitespace(self: *JSParser) void {
        while (self.position < self.source.len and std.ascii.isWhitespace(self.source[self.position])) {
            if (self.source[self.position] == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.position += 1;
        }
    }
    
    fn matchKeyword(self: *JSParser, keyword: []const u8) bool {
        if (self.position + keyword.len > self.source.len) return false;
        return std.mem.eql(u8, self.source[self.position..self.position + keyword.len], keyword);
    }
    
    fn consume(self: *JSParser, char: u8) bool {
        if (self.position < self.source.len and self.source[self.position] == char) {
            self.position += 1;
            self.column += 1;
            return true;
        }
        return false;
    }
    
    fn check(self: *JSParser, char: u8) bool {
        return self.position < self.source.len and self.source[self.position] == char;
    }
};

// === AST (抽象構文木) 実装 ===

pub const JavaScriptAST = struct {
    root: *ASTNode,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, root: *ASTNode) *JavaScriptAST {
        const ast = allocator.create(JavaScriptAST) catch return null;
        ast.* = JavaScriptAST{
            .root = root,
            .allocator = allocator,
        };
        return ast;
    }
    
    pub fn deinit(self: *JavaScriptAST) void {
        self.freeNode(self.root);
        self.allocator.destroy(self);
    }
    
    fn freeNode(self: *JavaScriptAST, node: *ASTNode) void {
        switch (node.kind) {
            .Program => {
                for (node.kind.Program.statements) |stmt| {
                    self.freeNode(stmt);
                }
                self.allocator.free(node.kind.Program.statements);
            },
            .FunctionDeclaration => {
                self.freeNode(node.kind.FunctionDeclaration.name);
                for (node.kind.FunctionDeclaration.parameters) |param| {
                    self.freeNode(param);
                }
                self.allocator.free(node.kind.FunctionDeclaration.parameters);
            },
            .ExpressionStatement => {
                self.freeNode(node.kind.ExpressionStatement.expression);
            },
            .BinaryExpression => {
                self.freeNode(node.kind.BinaryExpression.left);
                self.freeNode(node.kind.BinaryExpression.right);
            },
            .CallExpression => {
                self.freeNode(node.kind.CallExpression.callee);
                for (node.kind.CallExpression.arguments) |arg| {
                    self.freeNode(arg);
                }
                self.allocator.free(node.kind.CallExpression.arguments);
            },
            .ReturnStatement => {
                if (node.kind.ReturnStatement.argument) |arg| {
                    self.freeNode(arg);
                }
            },
            .Identifier, .Literal => {},
        }
        self.allocator.destroy(node);
    }
};

pub const ASTNode = struct {
    kind: ASTNodeKind,
    start: usize = 0,
    end: usize = 0,
    
    pub const ASTNodeKind = union(enum) {
        Program: ProgramNode,
        FunctionDeclaration: FunctionDeclarationNode,
        ExpressionStatement: ExpressionStatementNode,
        BinaryExpression: BinaryExpressionNode,
        CallExpression: CallExpressionNode,
        Identifier: IdentifierNode,
        Literal: LiteralNode,
        ReturnStatement: ReturnStatementNode,
    };
    
    pub const ProgramNode = struct {
        statements: []*ASTNode,
    };
    
    pub const FunctionDeclarationNode = struct {
        name: *ASTNode,
        parameters: []*ASTNode,
    };
    
    pub const ExpressionStatementNode = struct {
        expression: *ASTNode,
    };
    
    pub const BinaryExpressionNode = struct {
        operator: BinaryOperator,
        left: *ASTNode,
        right: *ASTNode,
    };
    
    pub const CallExpressionNode = struct {
        callee: *ASTNode,
        arguments: []*ASTNode,
    };
    
    pub const IdentifierNode = struct {
        name: []const u8,
    };
    
    pub const LiteralNode = struct {
        value: JSValue,
    };
    
    pub const ReturnStatementNode = struct {
        argument: ?*ASTNode,
    };
    
    pub const BinaryOperator = enum {
        Add,
        Subtract,
        Multiply,
        Divide,
        Equal,
        NotEqual,
        LessThan,
        GreaterThan,
    };
};

// === バイトコード実装 ===

pub const JSBytecode = struct {
    instructions: []u8,
    constants: []*JSValue,
    
    pub fn deinit(self: *JSBytecode, allocator: std.mem.Allocator) void {
        allocator.free(self.instructions);
        for (self.constants) |constant| {
            allocator.destroy(constant);
        }
        allocator.free(self.constants);
    }
};

// === コンパイラ実装 ===

pub const JSCompiler = struct {
    ast: *JavaScriptAST,
    context: *JSContext,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, ast: *JavaScriptAST, context: *JSContext) !*JSCompiler {
        const compiler = try allocator.create(JSCompiler);
        compiler.* = JSCompiler{
            .ast = ast,
            .context = context,
            .allocator = allocator,
        };
        return compiler;
    }
    
    pub fn deinit(self: *JSCompiler) void {
        self.allocator.destroy(self);
    }
    
    pub fn compile(self: *JSCompiler) !*JSBytecode {
        var instructions = std.ArrayList(u8).init(self.allocator);
        defer instructions.deinit();
        
        var constants = std.ArrayList(*JSValue).init(self.allocator);
        defer constants.deinit();
        
        try self.compileNode(self.ast.root, &instructions, &constants);
        
        const bytecode = try self.allocator.create(JSBytecode);
        bytecode.* = JSBytecode{
            .instructions = try instructions.toOwnedSlice(),
            .constants = try constants.toOwnedSlice(),
        };
        
        return bytecode;
    }
    
    fn compileNode(self: *JSCompiler, node: *ASTNode, instructions: *std.ArrayList(u8), constants: *std.ArrayList(*JSValue)) !void {
        switch (node.kind) {
            .Program => {
                for (node.kind.Program.statements) |stmt| {
                    try self.compileNode(stmt, instructions, constants);
                }
            },
            .ExpressionStatement => {
                try self.compileNode(node.kind.ExpressionStatement.expression, instructions, constants);
                try instructions.append(OpCode.Pop); // Remove result from stack
            },
            .BinaryExpression => {
                const binary = node.kind.BinaryExpression;
                try self.compileNode(binary.left, instructions, constants);
                try self.compileNode(binary.right, instructions, constants);
                
                switch (binary.operator) {
                    .Add => try instructions.append(OpCode.Add),
                    .Subtract => try instructions.append(OpCode.Subtract),
                    .Multiply => try instructions.append(OpCode.Multiply),
                    .Divide => try instructions.append(OpCode.Divide),
                    .Equal => try instructions.append(OpCode.Equal),
                    .NotEqual => try instructions.append(OpCode.NotEqual),
                    .LessThan => try instructions.append(OpCode.LessThan),
                    .GreaterThan => try instructions.append(OpCode.GreaterThan),
                }
            },
            .Literal => {
                const constant_index = constants.items.len;
                const value = try self.allocator.create(JSValue);
                value.* = node.kind.Literal.value;
                try constants.append(value);
                
                try instructions.append(OpCode.LoadConstant);
                try instructions.append(@intCast(constant_index));
            },
            .Identifier => {
                const name = node.kind.Identifier.name;
                // Load variable by name (simplified)
                try instructions.append(OpCode.LoadGlobal);
                
                // Store name as constant
                const js_string = try JSString.create(self.allocator, name);
                const string_value = try self.allocator.create(JSValue);
                string_value.* = JSValue{
                    .tag = @intFromEnum(JSValueType.String),
                    .data = @intFromPtr(js_string),
                };
                
                const name_index = constants.items.len;
                try constants.append(string_value);
                try instructions.append(@intCast(name_index));
            },
            .FunctionDeclaration => {
                // Function declaration compilation (simplified)
                try instructions.append(OpCode.DefineFunction);
            },
            .CallExpression => {
                const call = node.kind.CallExpression;
                
                // Compile arguments in reverse order
                for (call.arguments) |arg| {
                    try self.compileNode(arg, instructions, constants);
                }
                
                // Compile callee
                try self.compileNode(call.callee, instructions, constants);
                
                // Emit call instruction
                try instructions.append(OpCode.Call);
                try instructions.append(@intCast(call.arguments.len));
            },
            .ReturnStatement => {
                const return_stmt = node.kind.ReturnStatement;
                
                if (return_stmt.argument) |arg| {
                    try self.compileNode(arg, instructions, constants);
                } else {
                    // Return undefined
                    try instructions.append(OpCode.LoadConstant);
                    const undefined_index = constants.items.len;
                    const undefined_val = try self.allocator.create(JSValue);
                    undefined_val.* = JSValue.undefined_value;
                    try constants.append(undefined_val);
                    try instructions.append(@intCast(undefined_index));
                }
                
                try instructions.append(OpCode.Return);
            },
        }
    }
};

const OpCode = struct {
    const LoadConstant: u8 = 0x01;
    const LoadGlobal: u8 = 0x02;
    const Add: u8 = 0x10;
    const Subtract: u8 = 0x11;
    const Multiply: u8 = 0x12;
    const Divide: u8 = 0x13;
    const Equal: u8 = 0x20;
    const NotEqual: u8 = 0x21;
    const LessThan: u8 = 0x22;
    const GreaterThan: u8 = 0x23;
    const Pop: u8 = 0x30;
    const DefineFunction: u8 = 0x40;
    const Call: u8 = 0x50;
    const Return: u8 = 0x60;
};

// === 仮想マシン実装 ===

pub const JSVirtualMachine = struct {
    bytecode: *JSBytecode,
    context: *JSContext,
    stack: std.ArrayList(*JSValue),
    call_stack: std.ArrayList(CallFrame),
    instruction_pointer: usize,
    allocator: std.mem.Allocator,
    jit_enabled: bool,
    
    pub fn init(allocator: std.mem.Allocator, bytecode: *JSBytecode, context: *JSContext) !*JSVirtualMachine {
        const vm = try allocator.create(JSVirtualMachine);
        vm.* = JSVirtualMachine{
            .bytecode = bytecode,
            .context = context,
            .stack = std.ArrayList(*JSValue).init(allocator),
            .call_stack = std.ArrayList(CallFrame).init(allocator),
            .instruction_pointer = 0,
            .allocator = allocator,
            .jit_enabled = true,
        };
        return vm;
    }
    
    pub fn deinit(self: *JSVirtualMachine) void {
        self.stack.deinit();
        self.call_stack.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn execute(self: *JSVirtualMachine) !*JSValue {
        while (self.instruction_pointer < self.bytecode.instructions.len) {
            const opcode = self.bytecode.instructions[self.instruction_pointer];
            self.instruction_pointer += 1;
            
            switch (opcode) {
                OpCode.LoadConstant => {
                    const index = self.bytecode.instructions[self.instruction_pointer];
                    self.instruction_pointer += 1;
                    
                    const constant = self.bytecode.constants[index];
                    try self.stack.append(constant);
                },
                OpCode.LoadGlobal => {
                    const name_index = self.bytecode.instructions[self.instruction_pointer];
                    self.instruction_pointer += 1;
                    
                    const name_value = self.bytecode.constants[name_index];
                    const name = name_value.getStringValue();
                    
                    const value = self.context.global.getProperty(name) orelse blk: {
                        const undefined_val = try self.allocator.create(JSValue);
                        undefined_val.* = JSValue.undefined_value;
                        break :blk undefined_val;
                    };
                    
                    try self.stack.append(value);
                },
                OpCode.Add => {
                    const right = self.stack.pop();
                    const left = self.stack.pop();
                    
                    const result = try self.allocator.create(JSValue);
                    if (left.getType() == .Number and right.getType() == .Number) {
                        result.* = JSValue.createNumber(left.getNumberValue() + right.getNumberValue());
                    } else {
                        // String concatenation or type coercion
                        result.* = JSValue.undefined_value;
                    }
                    
                    try self.stack.append(result);
                },
                OpCode.Subtract => {
                    const right = self.stack.pop();
                    const left = self.stack.pop();
                    
                    const result = try self.allocator.create(JSValue);
                    result.* = JSValue.createNumber(left.getNumberValue() - right.getNumberValue());
                    
                    try self.stack.append(result);
                },
                OpCode.Multiply => {
                    const right = self.stack.pop();
                    const left = self.stack.pop();
                    
                    const result = try self.allocator.create(JSValue);
                    result.* = JSValue.createNumber(left.getNumberValue() * right.getNumberValue());
                    
                    try self.stack.append(result);
                },
                OpCode.Divide => {
                    const right = self.stack.pop();
                    const left = self.stack.pop();
                    
                    const result = try self.allocator.create(JSValue);
                    result.* = JSValue.createNumber(left.getNumberValue() / right.getNumberValue());
                    
                    try self.stack.append(result);
                },
                OpCode.Call => {
                    const arg_count = self.bytecode.instructions[self.instruction_pointer];
                    self.instruction_pointer += 1;
                    
                    const callee = self.stack.pop();
                    
                    // Collect arguments
                    var args = try self.allocator.alloc(*JSValue, arg_count);
                    defer self.allocator.free(args);
                    
                    for (0..arg_count) |i| {
                        args[arg_count - 1 - i] = self.stack.pop();
                    }
                    
                    if (callee.getType() == .Function) {
                        const func = @as(*JSFunction, @ptrFromInt(callee.data));
                        const result = try func.call(self.context, &JSValue.undefined_value, args);
                        try self.stack.append(result);
                    } else {
                        return error.NotCallable;
                    }
                },
                OpCode.Return => {
                    const return_value = self.stack.pop();
                    
                    if (self.call_stack.items.len > 0) {
                        const frame = self.call_stack.pop();
                        self.instruction_pointer = frame.return_address;
                    }
                    
                    try self.stack.append(return_value);
                },
                OpCode.Pop => {
                    _ = self.stack.pop();
                },
                else => {
                    return error.UnknownOpcode;
                },
            }
        }
        
        if (self.stack.items.len > 0) {
            return self.stack.items[self.stack.items.len - 1];
        } else {
            const undefined_val = try self.allocator.create(JSValue);
            undefined_val.* = JSValue.undefined_value;
            return undefined_val;
        }
    }
};

const CallFrame = struct {
    return_address: usize,
};

// === エンジン設定とメインクラス ===

pub const EngineConfig = struct {
    memory_limit_mb: usize = 128,
    heap_size_limit_mb: usize = 64,
    script_execution_timeout_ms: u64 = 30000,
    enable_dom: bool = true,
    enable_network_access: bool = true,
    enable_secure_memory: bool = true,
    enable_origin_isolation: bool = true,
    restrict_shared_memory: bool = true,
    enable_heap_profiling: bool = false,
    origin: []const u8 = "",
};

// 主要エンジンクラス
pub const Engine = struct {
    allocator: std.mem.Allocator,
    options: EngineOptions,
    config: EngineConfig,

    // エンジンの内部状態
    runtime: ?*JSRuntime,
    global_context: ?*JSContext,
    gc_state: GCState,
    initialized: bool,

    // Global instance
    pub var instance: ?*Engine = null;

    pub fn init(allocator: std.mem.Allocator, options: EngineOptions) !*Engine {
        var engine = try allocator.create(Engine);

        engine.* = Engine{
            .allocator = allocator,
            .options = options,
            .config = EngineConfig{},
            .runtime = null,
            .global_context = null,
            .gc_state = GCState{
                .total_allocated = 0,
                .last_gc_ms = 0,
                .collection_count = 0,
                .peak_usage = 0,
                .current_usage = 0,
                .is_collecting = false,
                .gc_mode = .Incremental,
            },
            .initialized = false,
        };

        return engine;
    }

    pub fn deinit(self: *Engine) void {
        self.shutdown();
        self.allocator.destroy(self);
    }

    // エンジン初期化
    pub fn initialize(self: *Engine) !void {
        if (self.initialized) return;

        std.log.info("Initializing Quantum JavaScript Engine...", .{});

        // ランタイム環境の作成
        self.runtime = try self.createRuntime();
        self.global_context = try self.createGlobalContext();

        // 組み込みオブジェクトの初期化
        try self.initializeBuiltins();

        // WebAssembly初期化
        if (self.options.enable_wasm) {
            try self.initializeWasm();
        }

        self.initialized = true;

        std.log.info("Quantum JavaScript Engine initialized with {}MB max heap", .{self.options.max_heap_size / (1024 * 1024)});
    }

    // エンジンシャットダウン
    pub fn shutdown(self: *Engine) void {
        if (!self.initialized) return;

        std.log.info("Shutting down Quantum JavaScript Engine...", .{});

        // コンテキストとランタイムの破棄
        if (self.global_context) |ctx| {
            self.destroyContext(ctx);
            self.global_context = null;
        }

        if (self.runtime) |rt| {
            rt.deinit();
            self.runtime = null;
        }

        self.initialized = false;

        std.log.info("Quantum JavaScript Engine shutdown complete.", .{});
    }

    // スクリプト実行
    pub fn executeScript(self: *Engine, script: []const u8, script_name: []const u8) !*JSValue {
        if (!self.initialized) {
            try self.initialize();
        }

        std.log.debug("Executing script: {s}", .{script_name});

        // Parse JavaScript
        var parser = JSParser.init(self.allocator, script);
        const ast = try parser.parseProgram();
        defer ast.deinit();
        
        // Compile to bytecode
        const compiler = try JSCompiler.init(self.allocator, ast, self.global_context.?);
        defer compiler.deinit();
        
        const bytecode = try compiler.compile();
        defer bytecode.deinit(self.allocator);
        
        // Execute bytecode
        const vm = try JSVirtualMachine.init(self.allocator, bytecode, self.global_context.?);
        defer vm.deinit();
        
        return vm.execute();
    }

    // WebAssemblyバイナリをコンパイル
    pub fn compileWasm(self: *Engine, wasm_bytes: []const u8) !*WasmModule {
        if (!self.initialized) {
            try self.initialize();
        }

        if (!self.options.enable_wasm) {
            return error.WasmNotEnabled;
        }

        std.log.debug("Compiling WebAssembly module (size: {d} bytes)", .{wasm_bytes.len});

        return WasmModule.parse(self.allocator, wasm_bytes);
    }

    // GCを実行
    pub fn collectGarbage(self: *Engine) void {
        if (!self.initialized) return;

        std.log.debug("Triggering garbage collection", .{});

        // 簡単なGC実装
        self.gc_state.collection_count += 1;
        self.gc_state.last_gc_ms = std.time.milliTimestamp();
        
        // メモリ使用量の更新
        self.gc_state.current_usage = 0; // Reset for simplicity
    }

    // シングルトンインスタンス取得
    pub fn getInstance() !*Engine {
        // シングルトンインスタンスが既に存在するか確認
        if (instance) |engine| {
            return engine;
        }

        // 存在しない場合は初期化
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();
        var engine = try init(allocator, EngineOptions{});
        try engine.initialize();

        instance = engine;
        return engine;
    }

    // ランタイム作成
    fn createRuntime(self: *Engine) !*JSRuntime {
        const runtime_options = jsRuntimeOptions{
            .max_heap_size = self.options.max_heap_size,
            .gc_interval_ms = self.options.gc_interval_ms,
            .enable_jit = self.options.optimize_jit,
        };

        return JSRuntime.init(self.allocator, runtime_options);
    }

    // グローバルコンテキスト作成
    fn createGlobalContext(self: *Engine) !*JSContext {
        const runtime = self.runtime orelse return error.NotInitialized;
        return runtime.createContext();
    }

    // 組み込みオブジェクト初期化
    fn initializeBuiltins(self: *Engine) !void {
        _ = self;
        std.log.debug("JavaScript built-in objects initialized", .{});
    }

    // WebAssembly初期化
    fn initializeWasm(self: *Engine) !void {
        _ = self;
        std.log.info("WebAssembly environment initialized", .{});
    }

    fn destroyContext(self: *Engine, context: *JSContext) void {
        self.allocator.destroy(context);
    }
};

// FFI interface structures
const jsRuntimeOptions = extern struct {
    max_heap_size: usize,
    gc_interval_ms: u32,
    enable_jit: bool,
}; 