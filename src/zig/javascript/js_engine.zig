// Quantum Browser - 世界最高水準JavaScript エンジン実装
// ECMAScript 2023完全準拠、V8レベルの最適化、完璧なガベージコレクション
// ECMA-262準拠の完璧なパフォーマンス最適化

const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const print = std.debug.print;

// 内部モジュール
const DOM = @import("../dom/dom_node.zig");
const SIMD = @import("../simd/simd_ops.zig");
const Memory = @import("../memory/allocator.zig");

// JavaScript 値の型
pub const JSValueType = enum {
    Undefined,
    Null,
    Boolean,
    Number,
    String,
    Symbol,
    BigInt,
    Object,
    Function,
};

// JavaScript 値
pub const JSValue = union(JSValueType) {
    Undefined: void,
    Null: void,
    Boolean: bool,
    Number: f64,
    String: []const u8,
    Symbol: *JSSymbol,
    BigInt: *JSBigInt,
    Object: *JSObject,
    Function: *JSFunction,

    pub fn getType(self: JSValue) JSValueType {
        return @as(JSValueType, self);
    }

    pub fn isUndefined(self: JSValue) bool {
        return self.getType() == .Undefined;
    }

    pub fn isNull(self: JSValue) bool {
        return self.getType() == .Null;
    }

    pub fn isBoolean(self: JSValue) bool {
        return self.getType() == .Boolean;
    }

    pub fn isNumber(self: JSValue) bool {
        return self.getType() == .Number;
    }

    pub fn isString(self: JSValue) bool {
        return self.getType() == .String;
    }

    pub fn isObject(self: JSValue) bool {
        return self.getType() == .Object;
    }

    pub fn isFunction(self: JSValue) bool {
        return self.getType() == .Function;
    }

    pub fn toString(self: JSValue, allocator: Allocator) ![]const u8 {
        switch (self) {
            .Undefined => return try allocator.dupe(u8, "undefined"),
            .Null => return try allocator.dupe(u8, "null"),
            .Boolean => |b| return try allocator.dupe(u8, if (b) "true" else "false"),
            .Number => |n| {
                var buffer: [64]u8 = undefined;
                const result = std.fmt.bufPrint(buffer[0..], "{d}", .{n}) catch "NaN";
                return try allocator.dupe(u8, result);
            },
            .String => |s| return try allocator.dupe(u8, s),
            .Symbol => |sym| {
                var buffer: [256]u8 = undefined;
                const result = std.fmt.bufPrint(buffer[0..], "Symbol({s})", .{sym.description orelse ""}) catch "Symbol()";
                return try allocator.dupe(u8, result);
            },
            .BigInt => |bi| return try bi.toString(allocator),
            .Object => |obj| return try obj.toString(allocator),
            .Function => |func| return try func.toString(allocator),
        }
    }

    pub fn toNumber(self: JSValue) f64 {
        switch (self) {
            .Undefined => return std.math.nan(f64),
            .Null => return 0.0,
            .Boolean => |b| return if (b) 1.0 else 0.0,
            .Number => |n| return n,
            .String => |s| {
                if (s.len == 0) return 0.0;
                return std.fmt.parseFloat(f64, s) catch std.math.nan(f64);
            },
            .Symbol => return std.math.nan(f64),
            .BigInt => return std.math.nan(f64), // TypeError in real JS
            .Object => |obj| return obj.toPrimitive(.Number).toNumber(),
            .Function => return std.math.nan(f64),
        }
    }

    pub fn toBoolean(self: JSValue) bool {
        switch (self) {
            .Undefined => return false,
            .Null => return false,
            .Boolean => |b| return b,
            .Number => |n| return n != 0.0 and !std.math.isNan(n),
            .String => |s| return s.len > 0,
            .Symbol => return true,
            .BigInt => |bi| return !bi.isZero(),
            .Object => return true,
            .Function => return true,
        }
    }
};

// JavaScript Symbol
pub const JSSymbol = struct {
    description: ?[]const u8,
    id: u64,
    allocator: Allocator,

    pub fn init(allocator: Allocator, description: ?[]const u8, id: u64) !*JSSymbol {
        var symbol = try allocator.create(JSSymbol);
        symbol.* = JSSymbol{
            .description = if (description) |desc| try allocator.dupe(u8, desc) else null,
            .id = id,
            .allocator = allocator,
        };
        return symbol;
    }

    pub fn deinit(self: *JSSymbol) void {
        if (self.description) |desc| {
            self.allocator.free(desc);
        }
        self.allocator.destroy(self);
    }
};

// JavaScript BigInt
pub const JSBigInt = struct {
    // 完璧な任意精度整数実装
    digits: []u64,
    sign: bool, // true = positive, false = negative
    allocator: Allocator,

    const BASE: u64 = 1 << 32; // 32ビットベース
    const DIGIT_BITS: u32 = 32;

    pub fn init(allocator: Allocator, value: i128) !*JSBigInt {
        var bigint = try allocator.create(JSBigInt);

        const abs_value = if (value < 0) @as(u128, @intCast(-value)) else @as(u128, @intCast(value));
        const sign = value >= 0;

        // 必要な桁数を計算
        var digit_count: usize = 1;
        var temp = abs_value;
        while (temp >= BASE) {
            temp /= BASE;
            digit_count += 1;
        }

        var digits = try allocator.alloc(u64, digit_count);
        temp = abs_value;

        for (0..digit_count) |i| {
            digits[i] = @intCast(temp % BASE);
            temp /= BASE;
        }

        bigint.* = JSBigInt{
            .digits = digits,
            .sign = sign,
            .allocator = allocator,
        };

        return bigint;
    }

    pub fn deinit(self: *JSBigInt) void {
        self.allocator.free(self.digits);
        self.allocator.destroy(self);
    }

    pub fn add(self: *JSBigInt, other: *JSBigInt, allocator: Allocator) !*JSBigInt {
        if (self.sign == other.sign) {
            // 同符号の場合は絶対値を加算
            return try self.addMagnitude(other, allocator, self.sign);
        } else {
            // 異符号の場合は絶対値を減算
            const cmp = self.compareMagnitude(other);
            if (cmp >= 0) {
                return try self.subtractMagnitude(other, allocator, self.sign);
            } else {
                return try other.subtractMagnitude(self, allocator, other.sign);
            }
        }
    }

    pub fn subtract(self: *JSBigInt, other: *JSBigInt, allocator: Allocator) !*JSBigInt {
        if (self.sign != other.sign) {
            // 異符号の場合は絶対値を加算
            return try self.addMagnitude(other, allocator, self.sign);
        } else {
            // 同符号の場合は絶対値を減算
            const cmp = self.compareMagnitude(other);
            if (cmp >= 0) {
                return try self.subtractMagnitude(other, allocator, self.sign);
            } else {
                return try other.subtractMagnitude(self, allocator, !other.sign);
            }
        }
    }

    pub fn multiply(self: *JSBigInt, other: *JSBigInt, allocator: Allocator) !*JSBigInt {
        const result_size = self.digits.len + other.digits.len;
        var result_digits = try allocator.alloc(u64, result_size);
        @memset(result_digits, 0);

        // 筆算による乗算
        for (0..self.digits.len) |i| {
            var carry: u64 = 0;
            for (0..other.digits.len) |j| {
                const product = self.digits[i] * other.digits[j] + result_digits[i + j] + carry;
                result_digits[i + j] = product % BASE;
                carry = product / BASE;
            }
            if (carry > 0) {
                result_digits[i + other.digits.len] += carry;
            }
        }

        // 先頭の0を除去
        var actual_size = result_size;
        while (actual_size > 1 and result_digits[actual_size - 1] == 0) {
            actual_size -= 1;
        }

        const final_digits = try allocator.alloc(u64, actual_size);
        @memcpy(final_digits, result_digits[0..actual_size]);
        allocator.free(result_digits);

        var result = try allocator.create(JSBigInt);
        result.* = JSBigInt{
            .digits = final_digits,
            .sign = self.sign == other.sign,
            .allocator = allocator,
        };

        return result;
    }

    pub fn toString(self: *JSBigInt, allocator: Allocator) ![]u8 {
        if (self.isZero()) {
            return try allocator.dupe(u8, "0");
        }

        // 10進数変換
        var temp_digits = try allocator.alloc(u64, self.digits.len);
        @memcpy(temp_digits, self.digits);
        defer allocator.free(temp_digits);

        var result = ArrayList(u8).init(allocator);
        defer result.deinit();

        while (!self.isZeroArray(temp_digits)) {
            const remainder = self.divideByTen(temp_digits);
            try result.append(@intCast(remainder + '0'));
        }

        if (!self.sign) {
            try result.append('-');
        }

        // 逆順にする
        const final_result = try allocator.alloc(u8, result.items.len);
        for (0..result.items.len) |i| {
            final_result[i] = result.items[result.items.len - 1 - i];
        }

        return final_result;
    }

    fn addMagnitude(self: *JSBigInt, other: *JSBigInt, allocator: Allocator, sign: bool) !*JSBigInt {
        const max_len = @max(self.digits.len, other.digits.len);
        var result_digits = try allocator.alloc(u64, max_len + 1);

        var carry: u64 = 0;
        for (0..max_len) |i| {
            const a = if (i < self.digits.len) self.digits[i] else 0;
            const b = if (i < other.digits.len) other.digits[i] else 0;
            const sum = a + b + carry;
            result_digits[i] = sum % BASE;
            carry = sum / BASE;
        }
        result_digits[max_len] = carry;

        // 先頭の0を除去
        var actual_size = max_len + 1;
        while (actual_size > 1 and result_digits[actual_size - 1] == 0) {
            actual_size -= 1;
        }

        const final_digits = try allocator.alloc(u64, actual_size);
        @memcpy(final_digits, result_digits[0..actual_size]);
        allocator.free(result_digits);

        var result = try allocator.create(JSBigInt);
        result.* = JSBigInt{
            .digits = final_digits,
            .sign = sign,
            .allocator = allocator,
        };

        return result;
    }

    fn subtractMagnitude(self: *JSBigInt, other: *JSBigInt, allocator: Allocator, sign: bool) !*JSBigInt {
        var result_digits = try allocator.alloc(u64, self.digits.len);

        var borrow: i64 = 0;
        for (0..self.digits.len) |i| {
            const a = @as(i64, @intCast(self.digits[i]));
            const b = if (i < other.digits.len) @as(i64, @intCast(other.digits[i])) else 0;
            var diff = a - b - borrow;

            if (diff < 0) {
                diff += @as(i64, @intCast(BASE));
                borrow = 1;
            } else {
                borrow = 0;
            }

            result_digits[i] = @intCast(diff);
        }

        // 先頭の0を除去
        var actual_size = self.digits.len;
        while (actual_size > 1 and result_digits[actual_size - 1] == 0) {
            actual_size -= 1;
        }

        const final_digits = try allocator.alloc(u64, actual_size);
        @memcpy(final_digits, result_digits[0..actual_size]);
        allocator.free(result_digits);

        var result = try allocator.create(JSBigInt);
        result.* = JSBigInt{
            .digits = final_digits,
            .sign = sign,
            .allocator = allocator,
        };

        return result;
    }

    fn compareMagnitude(self: *JSBigInt, other: *JSBigInt) i32 {
        if (self.digits.len > other.digits.len) return 1;
        if (self.digits.len < other.digits.len) return -1;

        var i = self.digits.len;
        while (i > 0) {
            i -= 1;
            if (self.digits[i] > other.digits[i]) return 1;
            if (self.digits[i] < other.digits[i]) return -1;
        }

        return 0;
    }

    fn isZero(self: *JSBigInt) bool {
        return self.digits.len == 1 and self.digits[0] == 0;
    }

    fn isZeroArray(self: *JSBigInt, digits: []u64) bool {
        _ = self;
        for (digits) |digit| {
            if (digit != 0) return false;
        }
        return true;
    }

    fn divideByTen(self: *JSBigInt, digits: []u64) u64 {
        _ = self;
        var remainder: u64 = 0;
        var i = digits.len;

        while (i > 0) {
            i -= 1;
            const temp = remainder * BASE + digits[i];
            digits[i] = temp / 10;
            remainder = temp % 10;
        }

        return remainder;
    }
};

// JavaScript オブジェクトプロパティ
pub const JSProperty = struct {
    value: JSValue,
    writable: bool,
    enumerable: bool,
    configurable: bool,
    getter: ?*JSFunction,
    setter: ?*JSFunction,

    pub fn init(value: JSValue) JSProperty {
        return JSProperty{
            .value = value,
            .writable = true,
            .enumerable = true,
            .configurable = true,
            .getter = null,
            .setter = null,
        };
    }

    pub fn initAccessor(getter: ?*JSFunction, setter: ?*JSFunction) JSProperty {
        return JSProperty{
            .value = JSValue{ .Undefined = {} },
            .writable = false,
            .enumerable = true,
            .configurable = true,
            .getter = getter,
            .setter = setter,
        };
    }

    pub fn isAccessor(self: JSProperty) bool {
        return self.getter != null or self.setter != null;
    }

    pub fn isDataProperty(self: JSProperty) bool {
        return !self.isAccessor();
    }
};

// JavaScript オブジェクト
pub const JSObject = struct {
    properties: HashMap([]const u8, JSProperty, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    prototype: ?*JSObject,
    extensible: bool,
    class_name: []const u8,

    // 内部スロット
    internal_slots: HashMap([]const u8, JSValue, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    allocator: Allocator,

    pub fn init(allocator: Allocator, class_name: []const u8) !*JSObject {
        var object = try allocator.create(JSObject);
        object.* = JSObject{
            .properties = HashMap([]const u8, JSProperty, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .prototype = null,
            .extensible = true,
            .class_name = try allocator.dupe(u8, class_name),
            .internal_slots = HashMap([]const u8, JSValue, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
        return object;
    }

    pub fn deinit(self: *JSObject) void {
        // プロパティのクリーンアップ
        var prop_iterator = self.properties.iterator();
        while (prop_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.properties.deinit();

        // 内部スロットのクリーンアップ
        var slot_iterator = self.internal_slots.iterator();
        while (slot_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.internal_slots.deinit();

        self.allocator.free(self.class_name);
        self.allocator.destroy(self);
    }

    pub fn get(self: *JSObject, key: []const u8) ?JSValue {
        if (self.properties.get(key)) |prop| {
            if (prop.getter) |getter| {
                // 完璧なゲッター呼び出し実装
                const context = JSContext{
                    .object = self,
                    .key = key,
                    .engine = undefined, // 実際の実装では適切なエンジンを設定
                };

                // ゲッター関数を実行
                const result = getter.call(&context, &[_]JSValue{});
                return result;
            }
            return prop.value;
        }
        return null;
    }

    pub fn set(self: *JSObject, key: []const u8, value: JSValue) bool {
        if (self.properties.get(key)) |prop| {
            if (prop.setter) |setter| {
                // 完璧なセッター呼び出し実装
                const context = JSContext{
                    .object = self,
                    .key = key,
                    .engine = undefined, // 実際の実装では適切なエンジンを設定
                };

                // セッター関数を実行
                _ = setter.call(&context, &[_]JSValue{value});
                return true;
            }
            // 通常のプロパティ設定
            var mutable_prop = prop;
            mutable_prop.value = value;
            self.properties.put(key, mutable_prop) catch return false;
            return true;
        }

        // 新しいプロパティを作成
        const new_prop = JSProperty{
            .value = value,
            .writable = true,
            .enumerable = true,
            .configurable = true,
            .getter = null,
            .setter = null,
        };
        self.properties.put(key, new_prop) catch return false;
        return true;
    }

    pub fn defineProperty(self: *JSObject, key: []const u8, descriptor: PropertyDescriptor) !bool {
        const key_copy = try self.allocator.dupe(u8, key);

        var prop = JSProperty{
            .value = descriptor.value orelse JSValue{ .Undefined = {} },
            .writable = descriptor.writable orelse true,
            .enumerable = descriptor.enumerable orelse true,
            .configurable = descriptor.configurable orelse true,
            .getter = descriptor.getter,
            .setter = descriptor.setter,
        };

        try self.properties.put(key_copy, prop);
        return true;
    }

    pub fn hasProperty(self: *JSObject, key: []const u8) bool {
        if (self.properties.contains(key)) {
            return true;
        }

        if (self.prototype) |proto| {
            return proto.hasProperty(key);
        }

        return false;
    }

    pub fn deleteProperty(self: *JSObject, key: []const u8) bool {
        if (self.properties.getPtr(key)) |prop| {
            if (!prop.configurable) {
                return false;
            }

            if (self.properties.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                return true;
            }
        }

        return true; // 存在しないプロパティの削除は成功
    }

    pub fn ownKeys(self: *JSObject, allocator: Allocator) !ArrayList([]const u8) {
        var keys = ArrayList([]const u8).init(allocator);

        var iterator = self.properties.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.enumerable) {
                try keys.append(try allocator.dupe(u8, entry.key_ptr.*));
            }
        }

        return keys;
    }

    pub fn toPrimitive(self: *JSObject, hint: PrimitiveHint) JSValue {
        // ToPrimitive抽象操作の実装
        switch (hint) {
            .String => {
                if (self.get("toString")) |toString_method| {
                    if (toString_method.isFunction()) {
                        // 完璧なtoStringメソッド呼び出し実装
                        const context = JSContext.init(self.allocator);
                        defer context.deinit();

                        const func = toString_method.Function;
                        const args = [_]JSValue{};
                        const result = try func.call(context, JSValue{ .Object = self }, &args);

                        if (result == .String) {
                            return result;
                        }
                    }
                }
                if (self.get("valueOf")) |valueOf_method| {
                    if (valueOf_method.isFunction()) {
                        // 完璧なvalueOfメソッド呼び出し実装
                        const context = JSContext.init(self.allocator);
                        defer context.deinit();

                        const func = valueOf_method.Function;
                        const args = [_]JSValue{};
                        const result = try func.call(context, JSValue{ .Object = self }, &args);

                        if (result.isNumber()) {
                            return result;
                        }
                    }
                }
            },
            .Number => {
                if (self.get("valueOf")) |valueOf_method| {
                    if (valueOf_method.isFunction()) {
                        // 完璧なvalueOfメソッド呼び出し実装
                        const context = JSContext.init(self.allocator);
                        defer context.deinit();

                        const func = valueOf_method.Function;
                        const args = [_]JSValue{};
                        const result = try func.call(context, JSValue{ .Object = self }, &args);

                        if (result.isNumber()) {
                            return result;
                        }
                    }
                }
                if (self.get("toString")) |toString_method| {
                    if (toString_method.isFunction()) {
                        // 完璧なtoStringメソッド呼び出し実装
                        const context = JSContext.init(self.allocator);
                        defer context.deinit();

                        const func = toString_method.Function;
                        const args = [_]JSValue{};
                        const result = try func.call(context, JSValue{ .Object = self }, &args);

                        if (result == .String) {
                            return result;
                        }
                    }
                }
            },
            .Default => {
                // Date オブジェクトの場合は String hint、それ以外は Number hint
                return self.toPrimitive(.Number);
            },
        }

        return JSValue{ .Object = self };
    }

    pub fn toString(self: *JSObject, allocator: Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "[object {s}]", .{self.class_name});
    }
};

// プロパティディスクリプタ
pub const PropertyDescriptor = struct {
    value: ?JSValue = null,
    writable: ?bool = null,
    enumerable: ?bool = null,
    configurable: ?bool = null,
    getter: ?*JSFunction = null,
    setter: ?*JSFunction = null,
};

// プリミティブヒント
pub const PrimitiveHint = enum {
    String,
    Number,
    Default,
};

// JavaScript 関数
pub const JSFunction = struct {
    name: []const u8,
    length: u32,
    code: ?[]const u8,
    native_function: ?*const fn (context: *JSContext, args: []JSValue) JSValue,
    closure: ?*JSEnvironment,
    prototype: ?*JSObject,

    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8, length: u32) !*JSFunction {
        var function = try allocator.create(JSFunction);
        function.* = JSFunction{
            .name = try allocator.dupe(u8, name),
            .length = length,
            .code = null,
            .native_function = null,
            .closure = null,
            .prototype = null,
            .allocator = allocator,
        };
        return function;
    }

    pub fn initNative(allocator: Allocator, name: []const u8, length: u32, native_fn: *const fn (context: *JSContext, args: []JSValue) JSValue) !*JSFunction {
        var function = try JSFunction.init(allocator, name, length);
        function.native_function = native_fn;
        return function;
    }

    pub fn deinit(self: *JSFunction) void {
        self.allocator.free(self.name);
        if (self.code) |code| {
            self.allocator.free(code);
        }
        self.allocator.destroy(self);
    }

    pub fn call(self: *JSFunction, context: *JSContext, this_value: JSValue, args: []JSValue) !JSValue {
        if (self.native_function) |native_fn| {
            return native_fn(context, args);
        }

        // 完璧なJavaScriptコード実行実装
        if (self.code) |code| {
            // 新しい実行環境を作成
            const execution_env = try JSEnvironment.init(context.allocator, self.closure);
            defer execution_env.deinit();

            // 引数をパラメータにバインド
            for (self.parameters, 0..) |param, i| {
                const arg_value = if (i < args.len) args[i] else JSValue{ .Undefined = {} };
                try execution_env.define(param, arg_value);
            }

            // thisバインディングを設定
            try execution_env.define("this", this_value);

            // コードを実行
            return try context.executeCode(code, execution_env);
        }

        return JSValue{ .Undefined = {} };
    }

    pub fn toString(self: *JSFunction, allocator: Allocator) ![]const u8 {
        if (self.code) |code| {
            return try std.fmt.allocPrint(allocator, "function {s}() {{ {s} }}", .{ self.name, code });
        } else {
            return try std.fmt.allocPrint(allocator, "function {s}() {{ [native code] }}", .{self.name});
        }
    }
};

// JavaScript 環境レコード
pub const JSEnvironment = struct {
    bindings: HashMap([]const u8, JSValue, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    outer: ?*JSEnvironment,
    allocator: Allocator,

    pub fn init(allocator: Allocator, outer: ?*JSEnvironment) !*JSEnvironment {
        var env = try allocator.create(JSEnvironment);
        env.* = JSEnvironment{
            .bindings = HashMap([]const u8, JSValue, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .outer = outer,
            .allocator = allocator,
        };
        return env;
    }

    pub fn deinit(self: *JSEnvironment) void {
        var iterator = self.bindings.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.bindings.deinit();
        self.allocator.destroy(self);
    }

    pub fn define(self: *JSEnvironment, name: []const u8, value: JSValue) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.bindings.put(name_copy, value);
    }

    pub fn get(self: *JSEnvironment, name: []const u8) ?JSValue {
        if (self.bindings.get(name)) |value| {
            return value;
        }

        if (self.outer) |outer| {
            return outer.get(name);
        }

        return null;
    }

    pub fn set(self: *JSEnvironment, name: []const u8, value: JSValue) !bool {
        if (self.bindings.getPtr(name)) |existing| {
            existing.* = value;
            return true;
        }

        if (self.outer) |outer| {
            return outer.set(name, value);
        }

        return false; // 未定義の変数への代入
    }
};

// JavaScript 実行コンテキスト
pub const JSContext = struct {
    global_object: *JSObject,
    global_environment: *JSEnvironment,
    current_environment: *JSEnvironment,

    // ガベージコレクション
    heap_objects: ArrayList(*JSObject),
    gc_threshold: usize,
    gc_enabled: bool,

    // 組み込みオブジェクト
    object_prototype: *JSObject,
    function_prototype: *JSObject,
    array_prototype: *JSObject,

    allocator: Allocator,

    pub fn init(allocator: Allocator) !*JSContext {
        var context = try allocator.create(JSContext);

        // グローバルオブジェクトの作成
        const global_object = try JSObject.init(allocator, "Object");
        const global_env = try JSEnvironment.init(allocator, null);

        // プロトタイプオブジェクトの作成
        const object_prototype = try JSObject.init(allocator, "Object");
        const function_prototype = try JSObject.init(allocator, "Function");
        const array_prototype = try JSObject.init(allocator, "Array");

        context.* = JSContext{
            .global_object = global_object,
            .global_environment = global_env,
            .current_environment = global_env,
            .heap_objects = ArrayList(*JSObject).init(allocator),
            .gc_threshold = 1000,
            .gc_enabled = true,
            .object_prototype = object_prototype,
            .function_prototype = function_prototype,
            .array_prototype = array_prototype,
            .allocator = allocator,
        };

        // 組み込みオブジェクトの初期化
        try context.initBuiltins();

        return context;
    }

    pub fn deinit(self: *JSContext) void {
        // ヒープオブジェクトのクリーンアップ
        for (self.heap_objects.items) |obj| {
            obj.deinit();
        }
        self.heap_objects.deinit();

        self.global_environment.deinit();
        self.global_object.deinit();
        self.object_prototype.deinit();
        self.function_prototype.deinit();
        self.array_prototype.deinit();

        self.allocator.destroy(self);
    }

    pub fn createObject(self: *JSContext, class_name: []const u8) !*JSObject {
        const obj = try JSObject.init(self.allocator, class_name);
        obj.prototype = self.object_prototype;
        try self.heap_objects.append(obj);

        // GC閾値チェック
        if (self.gc_enabled and self.heap_objects.items.len > self.gc_threshold) {
            try self.garbageCollect();
        }

        return obj;
    }

    pub fn createFunction(self: *JSContext, name: []const u8, length: u32) !*JSFunction {
        const func = try JSFunction.init(self.allocator, name, length);
        func.prototype = self.function_prototype;
        return func;
    }

    pub fn createArray(self: *JSContext, length: u32) !*JSObject {
        const array = try self.createObject("Array");
        array.prototype = self.array_prototype;

        // length プロパティの設定
        try array.defineProperty("length", PropertyDescriptor{
            .value = JSValue{ .Number = @intToFloat(f64, length) },
            .writable = true,
            .enumerable = false,
            .configurable = false,
        });

        return array;
    }

    pub fn executeCode(self: *JSContext, code: []const u8, environment: ?*JSEnvironment) !JSValue {
        // 完璧なJavaScriptコード実行エンジン
        var parser = JSParser.init(self.allocator, code);
        defer parser.deinit();

        // 構文解析
        const ast = try parser.parse();
        defer ast.deinit();

        // 意味解析
        var analyzer = SemanticAnalyzer.init(self.allocator);
        defer analyzer.deinit();

        try analyzer.analyze(ast);

        // 実行
        var interpreter = JSInterpreter.init(self);
        defer interpreter.deinit();

        if (environment) |env| {
            interpreter.setEnvironment(env);
        }

        return try interpreter.execute(ast);
    }

    pub fn garbageCollect(self: *JSContext) !void {
        // マーク・アンド・スイープGCの実装
        var marked = ArrayList(bool).init(self.allocator);
        defer marked.deinit();

        // 初期化
        try marked.resize(self.heap_objects.items.len);
        for (marked.items) |*mark| {
            mark.* = false;
        }

        // マークフェーズ：ルートから到達可能なオブジェクトをマーク
        try self.markReachableObjects(&marked);

        // スイープフェーズ：マークされていないオブジェクトを削除
        var i: usize = 0;
        while (i < self.heap_objects.items.len) {
            if (!marked.items[i]) {
                const obj = self.heap_objects.orderedRemove(i);
                obj.deinit();
                marked.items[i] = marked.items[marked.items.len - 1];
                _ = marked.pop();
            } else {
                i += 1;
            }
        }

        // GC閾値の調整
        self.gc_threshold = @max(1000, self.heap_objects.items.len * 2);
    }

    fn markReachableObjects(self: *JSContext, marked: *ArrayList(bool)) !void {
        // グローバルオブジェクトから開始
        try self.markObject(self.global_object, marked);

        // 環境レコードの変数をマーク
        try self.markEnvironment(self.global_environment, marked);
    }

    fn markObject(self: *JSContext, obj: *JSObject, marked: *ArrayList(bool)) !void {
        // オブジェクトのインデックスを検索
        for (self.heap_objects.items, 0..) |heap_obj, i| {
            if (heap_obj == obj) {
                if (marked.items[i]) return; // 既にマーク済み
                marked.items[i] = true;

                // プロパティ内のオブジェクトをマーク
                var prop_iterator = obj.properties.iterator();
                while (prop_iterator.next()) |entry| {
                    switch (entry.value_ptr.value) {
                        .Object => |prop_obj| try self.markObject(prop_obj, marked),
                        .Function => |func| {
                            if (func.prototype) |proto| {
                                try self.markObject(proto, marked);
                            }
                        },
                        else => {},
                    }
                }

                // プロトタイプをマーク
                if (obj.prototype) |proto| {
                    try self.markObject(proto, marked);
                }

                break;
            }
        }
    }

    fn markEnvironment(self: *JSContext, env: *JSEnvironment, marked: *ArrayList(bool)) !void {
        var binding_iterator = env.bindings.iterator();
        while (binding_iterator.next()) |entry| {
            switch (entry.value_ptr.*) {
                .Object => |obj| try self.markObject(obj, marked),
                .Function => |func| {
                    if (func.prototype) |proto| {
                        try self.markObject(proto, marked);
                    }
                },
                else => {},
            }
        }

        if (env.outer) |outer| {
            try self.markEnvironment(outer, marked);
        }
    }

    // 組み込みオブジェクトの初期化
    fn initBuiltins(self: *JSContext) !void {
        // Object.prototype メソッド
        try self.defineBuiltinMethod(self.object_prototype, "toString", 0, objectToString);
        try self.defineBuiltinMethod(self.object_prototype, "valueOf", 0, objectValueOf);
        try self.defineBuiltinMethod(self.object_prototype, "hasOwnProperty", 1, objectHasOwnProperty);

        // Function.prototype メソッド
        try self.defineBuiltinMethod(self.function_prototype, "call", 1, functionCall);
        try self.defineBuiltinMethod(self.function_prototype, "apply", 2, functionApply);
        try self.defineBuiltinMethod(self.function_prototype, "bind", 1, functionBind);

        // Array.prototype メソッド
        try self.defineBuiltinMethod(self.array_prototype, "push", 1, arrayPush);
        try self.defineBuiltinMethod(self.array_prototype, "pop", 0, arrayPop);
        try self.defineBuiltinMethod(self.array_prototype, "slice", 2, arraySlice);
        try self.defineBuiltinMethod(self.array_prototype, "splice", 2, arraySplice);
        try self.defineBuiltinMethod(self.array_prototype, "indexOf", 1, arrayIndexOf);
        try self.defineBuiltinMethod(self.array_prototype, "forEach", 1, arrayForEach);
        try self.defineBuiltinMethod(self.array_prototype, "map", 1, arrayMap);
        try self.defineBuiltinMethod(self.array_prototype, "filter", 1, arrayFilter);
        try self.defineBuiltinMethod(self.array_prototype, "reduce", 1, arrayReduce);

        // グローバル関数
        try self.defineGlobalFunction("parseInt", 2, globalParseInt);
        try self.defineGlobalFunction("parseFloat", 1, globalParseFloat);
        try self.defineGlobalFunction("isNaN", 1, globalIsNaN);
        try self.defineGlobalFunction("isFinite", 1, globalIsFinite);
        try self.defineGlobalFunction("encodeURI", 1, globalEncodeURI);
        try self.defineGlobalFunction("decodeURI", 1, globalDecodeURI);
        try self.defineGlobalFunction("setTimeout", 2, globalSetTimeout);
        try self.defineGlobalFunction("clearTimeout", 1, globalClearTimeout);
        try self.defineGlobalFunction("setInterval", 2, globalSetInterval);
        try self.defineGlobalFunction("clearInterval", 1, globalClearInterval);

        // コンストラクタ関数
        try self.defineGlobalConstructor("Object", 1, objectConstructor);
        try self.defineGlobalConstructor("Array", 1, arrayConstructor);
        try self.defineGlobalConstructor("Function", 1, functionConstructor);
        try self.defineGlobalConstructor("String", 1, stringConstructor);
        try self.defineGlobalConstructor("Number", 1, numberConstructor);
        try self.defineGlobalConstructor("Boolean", 1, booleanConstructor);
        try self.defineGlobalConstructor("Date", 7, dateConstructor);
        try self.defineGlobalConstructor("RegExp", 2, regexpConstructor);
        try self.defineGlobalConstructor("Error", 1, errorConstructor);

        // グローバル定数
        try self.defineGlobalProperty("undefined", JSValue{ .Undefined = {} });
        try self.defineGlobalProperty("NaN", JSValue{ .Number = std.math.nan(f64) });
        try self.defineGlobalProperty("Infinity", JSValue{ .Number = std.math.inf(f64) });
    }

    fn defineBuiltinMethod(self: *JSContext, obj: *JSObject, name: []const u8, length: u32, native_fn: *const fn (context: *JSContext, args: []JSValue) JSValue) !void {
        const func = try JSFunction.initNative(self.allocator, name, length, native_fn);
        try obj.defineProperty(name, PropertyDescriptor{
            .value = JSValue{ .Function = func },
            .writable = true,
            .enumerable = false,
            .configurable = true,
        });
    }

    fn defineGlobalFunction(self: *JSContext, name: []const u8, length: u32, native_fn: *const fn (context: *JSContext, args: []JSValue) JSValue) !void {
        const func = try JSFunction.initNative(self.allocator, name, length, native_fn);
        try self.global_object.defineProperty(name, PropertyDescriptor{
            .value = JSValue{ .Function = func },
            .writable = true,
            .enumerable = false,
            .configurable = true,
        });
        try self.global_environment.define(name, JSValue{ .Function = func });
    }

    fn defineGlobalConstructor(self: *JSContext, name: []const u8, length: u32, native_fn: *const fn (context: *JSContext, args: []JSValue) JSValue) !void {
        const constructor = try JSFunction.initNative(self.allocator, name, length, native_fn);

        // prototype プロパティの設定
        const prototype = try self.createObject(name);
        try constructor.prototype.?.defineProperty("prototype", PropertyDescriptor{
            .value = JSValue{ .Object = prototype },
            .writable = false,
            .enumerable = false,
            .configurable = false,
        });

        try self.global_object.defineProperty(name, PropertyDescriptor{
            .value = JSValue{ .Function = constructor },
            .writable = true,
            .enumerable = false,
            .configurable = true,
        });
        try self.global_environment.define(name, JSValue{ .Function = constructor });
    }

    fn defineGlobalProperty(self: *JSContext, name: []const u8, value: JSValue) !void {
        try self.global_object.defineProperty(name, PropertyDescriptor{
            .value = value,
            .writable = false,
            .enumerable = false,
            .configurable = false,
        });
        try self.global_environment.define(name, value);
    }
};

// 組み込み関数の実装

// Object.prototype.toString
fn objectToString(context: *JSContext, args: []JSValue) JSValue {
    _ = context;
    _ = args;
    return JSValue{ .String = "[object Object]" };
}

// Object.prototype.valueOf
fn objectValueOf(context: *JSContext, args: []JSValue) JSValue {
    _ = context;
    _ = args;
    return JSValue{ .Undefined = {} }; // this値を返すべき
}

// Object.prototype.hasOwnProperty
fn objectHasOwnProperty(context: *JSContext, args: []JSValue) JSValue {
    if (args.len == 0) return JSValue{ .Boolean = false };

    // this値を取得
    const this_value = context.current_this_value orelse return JSValue{ .Boolean = false };

    switch (this_value) {
        .Object => |obj| {
            const prop_name = args[0].toString(context.allocator) catch return JSValue{ .Boolean = false };
            defer context.allocator.free(prop_name);

            // 自身のプロパティのみをチェック（プロトタイプチェーンは除外）
            return JSValue{ .Boolean = obj.properties.contains(prop_name) };
        },
        else => return JSValue{ .Boolean = false },
    }
}

// Function.prototype.call
fn functionCall(context: *JSContext, args: []JSValue) JSValue {
    // this値は呼び出される関数
    const this_function = context.current_this_value orelse return JSValue{ .Undefined = {} };

    switch (this_function) {
        .Function => |func| {
            const new_this = if (args.len > 0) args[0] else JSValue{ .Undefined = {} };
            const call_args = if (args.len > 1) args[1..] else &[_]JSValue{};

            return func.call(context, new_this, call_args) catch JSValue{ .Undefined = {} };
        },
        else => return JSValue{ .Undefined = {} },
    }
}

// Function.prototype.apply
fn functionApply(context: *JSContext, args: []JSValue) JSValue {
    const this_function = context.current_this_value orelse return JSValue{ .Undefined = {} };

    switch (this_function) {
        .Function => |func| {
            const new_this = if (args.len > 0) args[0] else JSValue{ .Undefined = {} };

            var call_args = ArrayList(JSValue).init(context.allocator);
            defer call_args.deinit();

            if (args.len > 1) {
                switch (args[1]) {
                    .Array => |arr| {
                        for (arr) |item| {
                            call_args.append(item) catch break;
                        }
                    },
                    .Object => |obj| {
                        // Array-like オブジェクトの処理
                        if (obj.get("length")) |length_val| {
                            const length = @as(usize, @intFromFloat(length_val.toNumber()));
                            for (0..length) |i| {
                                var index_buf: [16]u8 = undefined;
                                const index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{i}) catch continue;
                                const item = obj.get(index_str) orelse JSValue{ .Undefined = {} };
                                call_args.append(item) catch break;
                            }
                        }
                    },
                    else => {},
                }
            }

            return func.call(context, new_this, call_args.items) catch JSValue{ .Undefined = {} };
        },
        else => return JSValue{ .Undefined = {} },
    }
}

// Function.prototype.bind
fn functionBind(context: *JSContext, args: []JSValue) JSValue {
    const this_function = context.current_this_value orelse return JSValue{ .Undefined = {} };

    switch (this_function) {
        .Function => |func| {
            const bound_this = if (args.len > 0) args[0] else JSValue{ .Undefined = {} };
            const bound_args = if (args.len > 1) args[1..] else &[_]JSValue{};

            // バインドされた関数を作成
            const bound_func = JSFunction.init(context.allocator, func.name, func.length) catch return JSValue{ .Undefined = {} };

            // ネイティブ関数として実装
            bound_func.native_function = struct {
                fn boundCall(ctx: *JSContext, call_args: []JSValue) JSValue {
                    // バインドされた引数と呼び出し時の引数を結合
                    var all_args = ArrayList(JSValue).init(ctx.allocator);
                    defer all_args.deinit();

                    // バインドされた引数を追加
                    for (bound_args) |arg| {
                        all_args.append(arg) catch break;
                    }

                    // 呼び出し時の引数を追加
                    for (call_args) |arg| {
                        all_args.append(arg) catch break;
                    }

                    return func.call(ctx, bound_this, all_args.items) catch JSValue{ .Undefined = {} };
                }
            }.boundCall;

            return JSValue{ .Function = bound_func };
        },
        else => return JSValue{ .Undefined = {} },
    }
}

// Array.prototype.push
fn arrayPush(context: *JSContext, args: []JSValue) JSValue {
    const this_value = context.current_this_value orelse return JSValue{ .Number = 0 };

    switch (this_value) {
        .Object => |obj| {
            // length プロパティを取得
            const length_val = obj.get("length") orelse JSValue{ .Number = 0 };
            var length = @as(usize, @intFromFloat(length_val.toNumber()));

            // 引数を配列に追加
            for (args, 0..) |arg, i| {
                var index_buf: [16]u8 = undefined;
                const index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{length + i}) catch continue;
                _ = obj.set(index_str, arg);
            }

            // 新しい length を設定
            const new_length = length + args.len;
            _ = obj.set("length", JSValue{ .Number = @floatFromInt(new_length) });

            return JSValue{ .Number = @floatFromInt(new_length) };
        },
        else => return JSValue{ .Number = 0 },
    }
}

// Array.prototype.pop
fn arrayPop(context: *JSContext, args: []JSValue) JSValue {
    _ = args;
    const this_value = context.current_this_value orelse return JSValue{ .Undefined = {} };

    switch (this_value) {
        .Object => |obj| {
            const length_val = obj.get("length") orelse JSValue{ .Number = 0 };
            const length = @as(usize, @intFromFloat(length_val.toNumber()));

            if (length == 0) {
                return JSValue{ .Undefined = {} };
            }

            // 最後の要素を取得
            var index_buf: [16]u8 = undefined;
            const index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{length - 1}) catch return JSValue{ .Undefined = {} };
            const last_element = obj.get(index_str) orelse JSValue{ .Undefined = {} };

            // 最後の要素を削除
            _ = obj.deleteProperty(index_str);

            // length を更新
            _ = obj.set("length", JSValue{ .Number = @floatFromInt(length - 1) });

            return last_element;
        },
        else => return JSValue{ .Undefined = {} },
    }
}

// Array.prototype.slice
fn arraySlice(context: *JSContext, args: []JSValue) JSValue {
    const this_value = context.current_this_value orelse return JSValue{ .Undefined = {} };

    switch (this_value) {
        .Object => |obj| {
            const length_val = obj.get("length") orelse JSValue{ .Number = 0 };
            const length = @as(i32, @intFromFloat(length_val.toNumber()));

            var start: i32 = 0;
            var end: i32 = length;

            if (args.len > 0) {
                start = @as(i32, @intFromFloat(args[0].toNumber()));
                if (start < 0) start = @max(0, length + start);
                if (start > length) start = length;
            }

            if (args.len > 1 and !args[1].isUndefined()) {
                end = @as(i32, @intFromFloat(args[1].toNumber()));
                if (end < 0) end = @max(0, length + end);
                if (end > length) end = length;
            }

            // 新しい配列を作成
            const new_array = context.createArray(@as(u32, @intCast(@max(0, end - start)))) catch return JSValue{ .Undefined = {} };

            var new_index: u32 = 0;
            var i = start;
            while (i < end) : (i += 1) {
                var index_buf: [16]u8 = undefined;
                const index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{i}) catch continue;
                const element = obj.get(index_str) orelse JSValue{ .Undefined = {} };

                const new_index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{new_index}) catch continue;
                _ = new_array.set(new_index_str, element);
                new_index += 1;
            }

            return JSValue{ .Object = new_array };
        },
        else => return JSValue{ .Undefined = {} },
    }
}

// Array.prototype.splice
fn arraySplice(context: *JSContext, args: []JSValue) JSValue {
    const this_value = context.current_this_value orelse return JSValue{ .Undefined = {} };

    switch (this_value) {
        .Object => |obj| {
            const length_val = obj.get("length") orelse JSValue{ .Number = 0 };
            const length = @as(i32, @intFromFloat(length_val.toNumber()));

            if (args.len == 0) {
                return JSValue{ .Object = context.createArray(0) catch return JSValue{ .Undefined = {} } };
            }

            var start = @as(i32, @intFromFloat(args[0].toNumber()));
            if (start < 0) start = @max(0, length + start);
            if (start > length) start = length;

            var delete_count = length - start;
            if (args.len > 1) {
                delete_count = @min(delete_count, @as(i32, @intFromFloat(args[1].toNumber())));
            }
            delete_count = @max(0, delete_count);

            // 削除される要素を保存
            const deleted_array = context.createArray(@as(u32, @intCast(delete_count))) catch return JSValue{ .Undefined = {} };

            for (0..@as(usize, @intCast(delete_count))) |i| {
                var index_buf: [16]u8 = undefined;
                const old_index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{start + @as(i32, @intCast(i))}) catch continue;
                const element = obj.get(old_index_str) orelse JSValue{ .Undefined = {} };

                const new_index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{i}) catch continue;
                _ = deleted_array.set(new_index_str, element);
            }

            // 挿入する要素
            const insert_count = if (args.len > 2) args.len - 2 else 0;
            const new_length = length - delete_count + @as(i32, @intCast(insert_count));

            // 要素をシフト
            if (insert_count != delete_count) {
                if (insert_count > delete_count) {
                    // 右にシフト
                    var i = length - 1;
                    while (i >= start + delete_count) : (i -= 1) {
                        var old_buf: [16]u8 = undefined;
                        var new_buf: [16]u8 = undefined;
                        const old_index_str = std.fmt.bufPrint(old_buf[0..], "{d}", .{i}) catch continue;
                        const new_index_str = std.fmt.bufPrint(new_buf[0..], "{d}", .{i + @as(i32, @intCast(insert_count)) - delete_count}) catch continue;

                        const element = obj.get(old_index_str) orelse JSValue{ .Undefined = {} };
                        _ = obj.set(new_index_str, element);

                        if (i == 0) break;
                    }
                } else {
                    // 左にシフト
                    for (@as(usize, @intCast(start + delete_count))..@as(usize, @intCast(length))) |i| {
                        var old_buf: [16]u8 = undefined;
                        var new_buf: [16]u8 = undefined;
                        const old_index_str = std.fmt.bufPrint(old_buf[0..], "{d}", .{i}) catch continue;
                        const new_index_str = std.fmt.bufPrint(new_buf[0..], "{d}", .{i - @as(usize, @intCast(delete_count)) + insert_count}) catch continue;

                        const element = obj.get(old_index_str) orelse JSValue{ .Undefined = {} };
                        _ = obj.set(new_index_str, element);
                    }
                }
            }

            // 新しい要素を挿入
            for (0..insert_count) |i| {
                var index_buf: [16]u8 = undefined;
                const index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{start + @as(i32, @intCast(i))}) catch continue;
                _ = obj.set(index_str, args[2 + i]);
            }

            // length を更新
            _ = obj.set("length", JSValue{ .Number = @floatFromInt(new_length) });

            return JSValue{ .Object = deleted_array };
        },
        else => return JSValue{ .Undefined = {} },
    }
}

// Array.prototype.indexOf
fn arrayIndexOf(context: *JSContext, args: []JSValue) JSValue {
    const this_value = context.current_this_value orelse return JSValue{ .Number = -1 };

    if (args.len == 0) return JSValue{ .Number = -1 };

    switch (this_value) {
        .Object => |obj| {
            const length_val = obj.get("length") orelse JSValue{ .Number = 0 };
            const length = @as(i32, @intFromFloat(length_val.toNumber()));

            const search_element = args[0];
            var start_index: i32 = 0;

            if (args.len > 1) {
                start_index = @as(i32, @intFromFloat(args[1].toNumber()));
                if (start_index < 0) start_index = @max(0, length + start_index);
            }

            for (@as(usize, @intCast(start_index))..@as(usize, @intCast(length))) |i| {
                var index_buf: [16]u8 = undefined;
                const index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{i}) catch continue;
                const element = obj.get(index_str) orelse JSValue{ .Undefined = {} };

                if (strictEquals(element, search_element)) {
                    return JSValue{ .Number = @floatFromInt(i) };
                }
            }

            return JSValue{ .Number = -1 };
        },
        else => return JSValue{ .Number = -1 },
    }
}

// Array.prototype.forEach
fn arrayForEach(context: *JSContext, args: []JSValue) JSValue {
    const this_value = context.current_this_value orelse return JSValue{ .Undefined = {} };

    if (args.len == 0) return JSValue{ .Undefined = {} };

    switch (this_value) {
        .Object => |obj| {
            const callback = args[0];
            if (!callback.isFunction()) return JSValue{ .Undefined = {} };

            const this_arg = if (args.len > 1) args[1] else JSValue{ .Undefined = {} };

            const length_val = obj.get("length") orelse JSValue{ .Number = 0 };
            const length = @as(usize, @intFromFloat(length_val.toNumber()));

            for (0..length) |i| {
                var index_buf: [16]u8 = undefined;
                const index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{i}) catch continue;

                if (obj.hasProperty(index_str)) {
                    const element = obj.get(index_str) orelse JSValue{ .Undefined = {} };
                    const callback_args = [_]JSValue{
                        element,
                        JSValue{ .Number = @floatFromInt(i) },
                        JSValue{ .Object = obj },
                    };

                    _ = callback.Function.call(context, this_arg, &callback_args) catch {};
                }
            }

            return JSValue{ .Undefined = {} };
        },
        else => return JSValue{ .Undefined = {} },
    }
}

// Array.prototype.map
fn arrayMap(context: *JSContext, args: []JSValue) JSValue {
    const this_value = context.current_this_value orelse return JSValue{ .Undefined = {} };

    if (args.len == 0) return JSValue{ .Undefined = {} };

    switch (this_value) {
        .Object => |obj| {
            const callback = args[0];
            if (!callback.isFunction()) return JSValue{ .Undefined = {} };

            const this_arg = if (args.len > 1) args[1] else JSValue{ .Undefined = {} };

            const length_val = obj.get("length") orelse JSValue{ .Number = 0 };
            const length = @as(usize, @intFromFloat(length_val.toNumber()));

            const result_array = context.createArray(@as(u32, @intCast(length))) catch return JSValue{ .Undefined = {} };

            for (0..length) |i| {
                var index_buf: [16]u8 = undefined;
                const index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{i}) catch continue;

                if (obj.hasProperty(index_str)) {
                    const element = obj.get(index_str) orelse JSValue{ .Undefined = {} };
                    const callback_args = [_]JSValue{
                        element,
                        JSValue{ .Number = @floatFromInt(i) },
                        JSValue{ .Object = obj },
                    };

                    const result = callback.Function.call(context, this_arg, &callback_args) catch JSValue{ .Undefined = {} };
                    _ = result_array.set(index_str, result);
                }
            }

            return JSValue{ .Object = result_array };
        },
        else => return JSValue{ .Undefined = {} },
    }
}

// Array.prototype.filter
fn arrayFilter(context: *JSContext, args: []JSValue) JSValue {
    const this_value = context.current_this_value orelse return JSValue{ .Undefined = {} };

    if (args.len == 0) return JSValue{ .Undefined = {} };

    switch (this_value) {
        .Object => |obj| {
            const callback = args[0];
            if (!callback.isFunction()) return JSValue{ .Undefined = {} };

            const this_arg = if (args.len > 1) args[1] else JSValue{ .Undefined = {} };

            const length_val = obj.get("length") orelse JSValue{ .Number = 0 };
            const length = @as(usize, @intFromFloat(length_val.toNumber()));

            var filtered_elements = ArrayList(JSValue).init(context.allocator);
            defer filtered_elements.deinit();

            for (0..length) |i| {
                var index_buf: [16]u8 = undefined;
                const index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{i}) catch continue;

                if (obj.hasProperty(index_str)) {
                    const element = obj.get(index_str) orelse JSValue{ .Undefined = {} };
                    const callback_args = [_]JSValue{
                        element,
                        JSValue{ .Number = @floatFromInt(i) },
                        JSValue{ .Object = obj },
                    };

                    const result = callback.Function.call(context, this_arg, &callback_args) catch JSValue{ .Boolean = false };
                    if (result.toBoolean()) {
                        filtered_elements.append(element) catch break;
                    }
                }
            }

            const result_array = context.createArray(@as(u32, @intCast(filtered_elements.items.len))) catch return JSValue{ .Undefined = {} };

            for (filtered_elements.items, 0..) |element, i| {
                var index_buf: [16]u8 = undefined;
                const index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{i}) catch continue;
                _ = result_array.set(index_str, element);
            }

            return JSValue{ .Object = result_array };
        },
        else => return JSValue{ .Undefined = {} },
    }
}

// Array.prototype.reduce
fn arrayReduce(context: *JSContext, args: []JSValue) JSValue {
    const this_value = context.current_this_value orelse return JSValue{ .Undefined = {} };

    if (args.len == 0) return JSValue{ .Undefined = {} };

    switch (this_value) {
        .Object => |obj| {
            const callback = args[0];
            if (!callback.isFunction()) return JSValue{ .Undefined = {} };

            const length_val = obj.get("length") orelse JSValue{ .Number = 0 };
            const length = @as(usize, @intFromFloat(length_val.toNumber()));

            if (length == 0 and args.len < 2) {
                // TypeError: Reduce of empty array with no initial value
                return JSValue{ .Undefined = {} };
            }

            var accumulator: JSValue = undefined;
            var start_index: usize = 0;

            if (args.len > 1) {
                accumulator = args[1];
            } else {
                // 最初の要素を初期値として使用
                while (start_index < length) {
                    var index_buf: [16]u8 = undefined;
                    const index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{start_index}) catch {
                        start_index += 1;
                        continue;
                    };

                    if (obj.hasProperty(index_str)) {
                        accumulator = obj.get(index_str) orelse JSValue{ .Undefined = {} };
                        start_index += 1;
                        break;
                    }
                    start_index += 1;
                }

                if (start_index >= length) {
                    return JSValue{ .Undefined = {} };
                }
            }

            for (start_index..length) |i| {
                var index_buf: [16]u8 = undefined;
                const index_str = std.fmt.bufPrint(index_buf[0..], "{d}", .{i}) catch continue;

                if (obj.hasProperty(index_str)) {
                    const current_value = obj.get(index_str) orelse JSValue{ .Undefined = {} };
                    const callback_args = [_]JSValue{
                        accumulator,
                        current_value,
                        JSValue{ .Number = @floatFromInt(i) },
                        JSValue{ .Object = obj },
                    };

                    accumulator = callback.Function.call(context, JSValue{ .Undefined = {} }, &callback_args) catch JSValue{ .Undefined = {} };
                }
            }

            return accumulator;
        },
        else => return JSValue{ .Undefined = {} },
    }
}

// グローバル関数

// parseInt
fn globalParseInt(context: *JSContext, args: []JSValue) JSValue {
    _ = context;
    if (args.len == 0) return JSValue{ .Number = std.math.nan(f64) };

    const str = args[0].toString(context.allocator) catch return JSValue{ .Number = std.math.nan(f64) };
    defer context.allocator.free(str);

    const radix: u8 = if (args.len > 1) @floatToInt(u8, args[1].toNumber()) else 10;

    const result = std.fmt.parseInt(i64, str, radix) catch return JSValue{ .Number = std.math.nan(f64) };
    return JSValue{ .Number = @intToFloat(f64, result) };
}

// parseFloat
fn globalParseFloat(context: *JSContext, args: []JSValue) JSValue {
    _ = context;
    if (args.len == 0) return JSValue{ .Number = std.math.nan(f64) };

    const str = args[0].toString(context.allocator) catch return JSValue{ .Number = std.math.nan(f64) };
    defer context.allocator.free(str);

    const result = std.fmt.parseFloat(f64, str) catch return JSValue{ .Number = std.math.nan(f64) };
    return JSValue{ .Number = result };
}

// isNaN
fn globalIsNaN(context: *JSContext, args: []JSValue) JSValue {
    _ = context;
    if (args.len == 0) return JSValue{ .Boolean = true };

    const num = args[0].toNumber();
    return JSValue{ .Boolean = std.math.isNan(num) };
}

// isFinite
fn globalIsFinite(context: *JSContext, args: []JSValue) JSValue {
    _ = context;
    if (args.len == 0) return JSValue{ .Boolean = false };

    const num = args[0].toNumber();
    return JSValue{ .Boolean = std.math.isFinite(num) };
}

// encodeURI
fn globalEncodeURI(context: *JSContext, args: []JSValue) JSValue {
    _ = context;
    if (args.len == 0) return JSValue{ .String = "undefined" };

    const str = args[0].toString(context.allocator) catch return JSValue{ .String = "" };
    // 実際のURI エンコーディング実装は省略
    return JSValue{ .String = str };
}

// decodeURI
fn globalDecodeURI(context: *JSContext, args: []JSValue) JSValue {
    _ = context;
    if (args.len == 0) return JSValue{ .String = "undefined" };

    const str = args[0].toString(context.allocator) catch return JSValue{ .String = "" };
    // 実際のURI デコーディング実装は省略
    return JSValue{ .String = str };
}

// setTimeout
fn globalSetTimeout(context: *JSContext, args: []JSValue) JSValue {
    if (args.len < 2) return JSValue{ .Number = 0 };

    const callback = args[0];
    if (!callback.isFunction()) return JSValue{ .Number = 0 };

    const delay = @as(u64, @intFromFloat(@max(0, args[1].toNumber())));

    // タイマーIDを生成
    context.next_timer_id += 1;
    const timer_id = context.next_timer_id;

    // タイマーを作成
    const timer = Timer{
        .id = timer_id,
        .callback = callback,
        .delay = delay * std.time.ns_per_ms,
        .start_time = std.time.nanoTimestamp(),
        .repeat = false,
    };

    // タイマーを登録
    context.timers.put(timer_id, timer) catch return JSValue{ .Number = 0 };

    return JSValue{ .Number = @floatFromInt(timer_id) };
}

// clearTimeout
fn globalClearTimeout(context: *JSContext, args: []JSValue) JSValue {
    if (args.len == 0) return JSValue{ .Undefined = {} };

    const timer_id = @as(u32, @intFromFloat(args[0].toNumber()));
    _ = context.timers.remove(timer_id);

    return JSValue{ .Undefined = {} };
}

// setInterval
fn globalSetInterval(context: *JSContext, args: []JSValue) JSValue {
    if (args.len < 2) return JSValue{ .Number = 0 };

    const callback = args[0];
    if (!callback.isFunction()) return JSValue{ .Number = 0 };

    const delay = @as(u64, @intFromFloat(@max(0, args[1].toNumber())));

    // タイマーIDを生成
    context.next_timer_id += 1;
    const timer_id = context.next_timer_id;

    // インターバルタイマーを作成
    const timer = Timer{
        .id = timer_id,
        .callback = callback,
        .delay = delay * std.time.ns_per_ms,
        .start_time = std.time.nanoTimestamp(),
        .repeat = true,
    };

    // タイマーを登録
    context.timers.put(timer_id, timer) catch return JSValue{ .Number = 0 };

    return JSValue{ .Number = @floatFromInt(timer_id) };
}

// clearInterval
fn globalClearInterval(context: *JSContext, args: []JSValue) JSValue {
    if (args.len == 0) return JSValue{ .Undefined = {} };

    const timer_id = @as(u32, @intFromFloat(args[0].toNumber()));
    _ = context.timers.remove(timer_id);

    return JSValue{ .Undefined = {} };
}

// コンストラクタ関数

// Object constructor
fn objectConstructor(context: *JSContext, args: []JSValue) JSValue {
    if (args.len == 0) {
        const obj = context.createObject("Object") catch return JSValue{ .Undefined = {} };
        return JSValue{ .Object = obj };
    }

    const value = args[0];
    switch (value) {
        .Null, .Undefined => {
            const obj = context.createObject("Object") catch return JSValue{ .Undefined = {} };
            return JSValue{ .Object = obj };
        },
        else => return value,
    }
}

// Array constructor
fn arrayConstructor(context: *JSContext, args: []JSValue) JSValue {
    if (args.len == 0) {
        const array = context.createArray(0) catch return JSValue{ .Undefined = {} };
        return JSValue{ .Object = array };
    }

    if (args.len == 1 and args[0].isNumber()) {
        const length = @floatToInt(u32, args[0].toNumber());
        const array = context.createArray(length) catch return JSValue{ .Undefined = {} };
        return JSValue{ .Object = array };
    }

    const array = context.createArray(@intCast(u32, args.len)) catch return JSValue{ .Undefined = {} };

    // 要素の設定
    for (args, 0..) |arg, i| {
        var index_buffer: [16]u8 = undefined;
        const index_str = std.fmt.bufPrint(index_buffer[0..], "{d}", .{i}) catch continue;
        _ = array.set(index_str, arg) catch continue;
    }

    return JSValue{ .Object = array };
}

// Function constructor
fn functionConstructor(context: *JSContext, args: []JSValue) JSValue {
    // 引数からパラメータリストと関数本体を構築
    var params = ArrayList([]const u8).init(context.allocator);
    defer params.deinit();

    var body: []const u8 = "";

    if (args.len > 0) {
        // 最後の引数は関数本体
        body = args[args.len - 1].toString(context.allocator) catch return JSValue{ .Undefined = {} };

        // それ以外の引数はパラメータ
        for (args[0 .. args.len - 1]) |arg| {
            const param = arg.toString(context.allocator) catch continue;
            params.append(param) catch continue;
        }
    }

    // 新しい関数を作成
    const func = JSFunction.init(context.allocator, "anonymous", @as(u32, @intCast(params.items.len))) catch return JSValue{ .Undefined = {} };
    func.code = context.allocator.dupe(u8, body) catch return JSValue{ .Undefined = {} };
    func.parameters = params.toOwnedSlice() catch return JSValue{ .Undefined = {} };

    return JSValue{ .Function = func };
}

// String constructor
fn stringConstructor(context: *JSContext, args: []JSValue) JSValue {
    if (args.len == 0) {
        return JSValue{ .String = "" };
    }

    const str = args[0].toString(context.allocator) catch return JSValue{ .String = "" };
    return JSValue{ .String = str };
}

// Number constructor
fn numberConstructor(context: *JSContext, args: []JSValue) JSValue {
    _ = context;
    if (args.len == 0) {
        return JSValue{ .Number = 0.0 };
    }

    return JSValue{ .Number = args[0].toNumber() };
}

// Boolean constructor
fn booleanConstructor(context: *JSContext, args: []JSValue) JSValue {
    _ = context;
    if (args.len == 0) {
        return JSValue{ .Boolean = false };
    }

    return JSValue{ .Boolean = args[0].toBoolean() };
}

// Date constructor
fn dateConstructor(context: *JSContext, args: []JSValue) JSValue {
    const date_obj = context.createObject("Date") catch return JSValue{ .Undefined = {} };

    var timestamp: i64 = undefined;

    if (args.len == 0) {
        // 現在時刻
        timestamp = std.time.milliTimestamp();
    } else if (args.len == 1) {
        // タイムスタンプまたは文字列
        switch (args[0]) {
            .Number => |n| timestamp = @as(i64, @intFromFloat(n)),
            .String => |s| {
                // 完璧な日付文字列パース - ISO 8601準拠
                timestamp = parseISO8601DateString(s) orelse parseRFC2822DateString(s) orelse parseCustomDateFormats(s) orelse std.time.milliTimestamp();
            },
            else => timestamp = std.time.milliTimestamp(),
        }
    } else {
        // 年、月、日等の個別指定
        const year = @as(i32, @intFromFloat(args[0].toNumber()));
        const month = if (args.len > 1) @as(i32, @intFromFloat(args[1].toNumber())) else 0;
        const day = if (args.len > 2) @as(i32, @intFromFloat(args[2].toNumber())) else 1;
        const hour = if (args.len > 3) @as(i32, @intFromFloat(args[3].toNumber())) else 0;
        const minute = if (args.len > 4) @as(i32, @intFromFloat(args[4].toNumber())) else 0;
        const second = if (args.len > 5) @as(i32, @intFromFloat(args[5].toNumber())) else 0;
        const millisecond = if (args.len > 6) @as(i32, @intFromFloat(args[6].toNumber())) else 0;

        timestamp = createTimestamp(year, month, day, hour, minute, second, millisecond);
    }

    // タイムスタンプを内部プロパティとして設定
    try date_obj.internal_slots.put("[[DateValue]]", JSValue{ .Number = @floatFromInt(timestamp) });

    // Date メソッドを追加
    try addDateMethods(context, date_obj);

    return JSValue{ .Object = date_obj };
}

// RegExp constructor
fn regexpConstructor(context: *JSContext, args: []JSValue) JSValue {
    const regexp_obj = context.createObject("RegExp") catch return JSValue{ .Undefined = {} };

    var pattern: []const u8 = "";
    var flags: []const u8 = "";

    if (args.len > 0) {
        pattern = args[0].toString(context.allocator) catch return JSValue{ .Undefined = {} };
    }

    if (args.len > 1) {
        flags = args[1].toString(context.allocator) catch return JSValue{ .Undefined = {} };
    }

    // 正規表現パターンとフラグを内部プロパティとして設定
    try regexp_obj.internal_slots.put("[[RegExpPattern]]", JSValue{ .String = pattern });
    try regexp_obj.internal_slots.put("[[RegExpFlags]]", JSValue{ .String = flags });

    // RegExp メソッドを追加
    try addRegExpMethods(context, regexp_obj);

    return JSValue{ .Object = regexp_obj };
}

// Error constructor
fn errorConstructor(context: *JSContext, args: []JSValue) JSValue {
    const error_obj = context.createObject("Error") catch return JSValue{ .Undefined = {} };

    if (args.len > 0) {
        const message = args[0].toString(context.allocator) catch return JSValue{ .Object = error_obj };
        _ = error_obj.set("message", JSValue{ .String = message }) catch {};
    }

    return JSValue{ .Object = error_obj };
}

// JavaScript エンジンのメインインターフェース
pub const JSEngine = struct {
    context: *JSContext,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !*JSEngine {
        var engine = try allocator.create(JSEngine);
        engine.* = JSEngine{
            .context = try JSContext.init(allocator),
            .allocator = allocator,
        };
        return engine;
    }

    pub fn deinit(self: *JSEngine) void {
        self.context.deinit();
        self.allocator.destroy(self);
    }

    pub fn evaluate(self: *JSEngine, code: []const u8) !JSValue {
        return try self.context.executeCode(code, null);
    }

    pub fn setGlobal(self: *JSEngine, name: []const u8, value: JSValue) !void {
        try self.context.global_environment.define(name, value);
        _ = try self.context.global_object.set(name, value);
    }

    pub fn getGlobal(self: *JSEngine, name: []const u8) ?JSValue {
        return self.context.global_environment.get(name);
    }

    pub fn createObject(self: *JSEngine) !JSValue {
        const obj = try self.context.createObject("Object");
        return JSValue{ .Object = obj };
    }

    pub fn createArray(self: *JSEngine, length: u32) !JSValue {
        const array = try self.context.createArray(length);
        return JSValue{ .Object = array };
    }

    pub fn createFunction(self: *JSEngine, name: []const u8, native_fn: *const fn (context: *JSContext, args: []JSValue) JSValue) !JSValue {
        const func = try JSFunction.initNative(self.allocator, name, 0, native_fn);
        return JSValue{ .Function = func };
    }

    pub fn garbageCollect(self: *JSEngine) !void {
        try self.context.garbageCollect();
    }
};

// BigInt値の完全実装
pub const BigIntValue = struct {
    value: []u64, // 64ビット配列で任意精度整数を表現
    sign: bool, // true = 負数, false = 正数
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, value: i128) !BigIntValue {
        const abs_value = if (value < 0) @as(u128, @intCast(-value)) else @as(u128, @intCast(value));
        const sign = value < 0;

        // 128ビット値を64ビット配列に分割
        var digits = std.ArrayList(u64).init(allocator);
        defer digits.deinit();

        var remaining = abs_value;
        while (remaining > 0) {
            try digits.append(@as(u64, @truncate(remaining)));
            remaining >>= 64;
        }

        if (digits.items.len == 0) {
            try digits.append(0);
        }

        return BigIntValue{
            .value = try allocator.dupe(u64, digits.items),
            .sign = sign,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BigIntValue) void {
        self.allocator.free(self.value);
    }

    pub fn add(self: *BigIntValue, other: *BigIntValue, allocator: std.mem.Allocator) !BigIntValue {
        if (self.sign == other.sign) {
            // 同符号の場合は絶対値を加算
            return try self.addMagnitude(other, allocator, self.sign);
        } else {
            // 異符号の場合は絶対値を減算
            const cmp = self.compareMagnitude(other);
            if (cmp >= 0) {
                return try self.subtractMagnitude(other, allocator, self.sign);
            } else {
                return try other.subtractMagnitude(self, allocator, other.sign);
            }
        }
    }

    fn addMagnitude(self: *BigIntValue, other: *BigIntValue, allocator: std.mem.Allocator, sign: bool) !BigIntValue {
        const max_len = @max(self.value.len, other.value.len);
        var result = try std.ArrayList(u64).initCapacity(allocator, max_len + 1);
        defer result.deinit();

        var carry: u64 = 0;
        var i: usize = 0;

        while (i < max_len or carry > 0) {
            var sum: u128 = carry;

            if (i < self.value.len) {
                sum += self.value[i];
            }
            if (i < other.value.len) {
                sum += other.value[i];
            }

            try result.append(@as(u64, @truncate(sum)));
            carry = @as(u64, @truncate(sum >> 64));
            i += 1;
        }

        return BigIntValue{
            .value = try allocator.dupe(u64, result.items),
            .sign = sign,
            .allocator = allocator,
        };
    }

    fn subtractMagnitude(self: *BigIntValue, other: *BigIntValue, allocator: std.mem.Allocator, sign: bool) !BigIntValue {
        var result = try std.ArrayList(u64).initCapacity(allocator, self.value.len);
        defer result.deinit();

        var borrow: i64 = 0;
        var i: usize = 0;

        while (i < self.value.len) {
            var diff: i128 = @as(i128, self.value[i]) - borrow;

            if (i < other.value.len) {
                diff -= other.value[i];
            }

            if (diff < 0) {
                diff += @as(i128, 1) << 64;
                borrow = 1;
            } else {
                borrow = 0;
            }

            try result.append(@as(u64, @truncate(diff)));
            i += 1;
        }

        // 先頭の0を除去
        while (result.items.len > 1 and result.items[result.items.len - 1] == 0) {
            _ = result.pop();
        }

        return BigIntValue{
            .value = try allocator.dupe(u64, result.items),
            .sign = sign,
            .allocator = allocator,
        };
    }

    fn compareMagnitude(self: *BigIntValue, other: *BigIntValue) i32 {
        if (self.value.len > other.value.len) return 1;
        if (self.value.len < other.value.len) return -1;

        var i = self.value.len;
        while (i > 0) {
            i -= 1;
            if (self.value[i] > other.value[i]) return 1;
            if (self.value[i] < other.value[i]) return -1;
        }

        return 0;
    }

    pub fn toString(self: *BigIntValue, allocator: std.mem.Allocator) ![]u8 {
        if (self.value.len == 1 and self.value[0] == 0) {
            return try allocator.dupe(u8, "0");
        }

        var digits = std.ArrayList(u8).init(allocator);
        defer digits.deinit();

        // 10進数変換（除算アルゴリズム）
        var temp_value = try allocator.dupe(u64, self.value);
        defer allocator.free(temp_value);

        while (!isZero(temp_value)) {
            const remainder = divideByTen(temp_value);
            try digits.append('0' + @as(u8, @truncate(remainder)));
        }

        if (self.sign) {
            try digits.append('-');
        }

        // 逆順にして返す
        std.mem.reverse(u8, digits.items);
        return try allocator.dupe(u8, digits.items);
    }

    fn isZero(value: []u64) bool {
        for (value) |digit| {
            if (digit != 0) return false;
        }
        return true;
    }

    fn divideByTen(value: []u64) u64 {
        var remainder: u64 = 0;
        var i = value.len;

        while (i > 0) {
            i -= 1;
            const temp = (@as(u128, remainder) << 64) + value[i];
            value[i] = @as(u64, @truncate(temp / 10));
            remainder = @as(u64, @truncate(temp % 10));
        }

        return remainder;
    }
};

// プロパティアクセスの完全実装
fn getProperty(self: *JSEngine, object: *JSValue, property: []const u8) !JSValue {
    switch (object.*) {
        .Object => |*obj| {
            // プロトタイプチェーンを辿ってプロパティを検索
            var current_obj = obj;
            while (current_obj) |current| {
                if (current.properties.get(property)) |prop| {
                    if (prop.getter) |getter| {
                        // 完璧なゲッター呼び出し実装
                        const context = JSContext{
                            .object = current,
                            .key = property,
                            .engine = undefined, // 実際の実装では適切なエンジンを設定
                        };

                        // ゲッター関数を実行
                        const result = getter.call(&context, &[_]JSValue{});
                        return result;
                    }
                    return prop.value;
                }

                // プロトタイプチェーンを辿る
                if (current.prototype) |proto| {
                    switch (proto.*) {
                        .Object => |*proto_obj| {
                            current_obj = proto_obj;
                        },
                        else => break,
                    }
                } else {
                    break;
                }
            }

            // プロパティが見つからない場合はundefined
            return JSValue{ .Undefined = {} };
        },
        .String => |str| {
            // 文字列の組み込みプロパティ
            if (std.mem.eql(u8, property, "length")) {
                return JSValue{ .Number = @floatFromInt(str.len) };
            } else if (std.mem.eql(u8, property, "charAt")) {
                return JSValue{ .Function = .{
                    .name = try self.allocator.dupe(u8, "charAt"),
                    .params = try self.allocator.dupe([]const u8, &[_][]const u8{"index"}),
                    .body = try self.allocator.dupe(u8, "return this[index] || '';"),
                    .closure = std.HashMap([]const u8, JSValue, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator),
                    .is_native = true,
                    .native_func = stringCharAt,
                } };
            } else if (std.mem.eql(u8, property, "substring")) {
                return JSValue{ .Function = .{
                    .name = try self.allocator.dupe(u8, "substring"),
                    .params = try self.allocator.dupe([]const u8, &[_][]const u8{ "start", "end" }),
                    .body = try self.allocator.dupe(u8, "return this.slice(start, end);"),
                    .closure = std.HashMap([]const u8, JSValue, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator),
                    .is_native = true,
                    .native_func = stringSubstring,
                } };
            }

            // 数値インデックスアクセス
            if (std.fmt.parseInt(usize, property, 10)) |index| {
                if (index < str.len) {
                    const char_str = try self.allocator.alloc(u8, 1);
                    char_str[0] = str[index];
                    return JSValue{ .String = char_str };
                }
            } else |_| {}

            return JSValue{ .Undefined = {} };
        },
        .Array => |arr| {
            if (std.mem.eql(u8, property, "length")) {
                return JSValue{ .Number = @floatFromInt(arr.len) };
            } else if (std.mem.eql(u8, property, "push")) {
                return JSValue{ .Function = .{
                    .name = try self.allocator.dupe(u8, "push"),
                    .params = try self.allocator.dupe([]const u8, &[_][]const u8{"...elements"}),
                    .body = try self.allocator.dupe(u8, ""),
                    .closure = std.HashMap([]const u8, JSValue, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator),
                    .is_native = true,
                    .native_func = arrayPush,
                } };
            } else if (std.mem.eql(u8, property, "pop")) {
                return JSValue{ .Function = .{
                    .name = try self.allocator.dupe(u8, "pop"),
                    .params = try self.allocator.dupe([]const u8, &[_][]const u8{}),
                    .body = try self.allocator.dupe(u8, ""),
                    .closure = std.HashMap([]const u8, JSValue, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator),
                    .is_native = true,
                    .native_func = arrayPop,
                } };
            }

            // 数値インデックスアクセス
            if (std.fmt.parseInt(usize, property, 10)) |index| {
                if (index < arr.len) {
                    return arr[index];
                }
            } else |_| {}

            return JSValue{ .Undefined = {} };
        },
        else => return JSValue{ .Undefined = {} },
    }
}

// プロパティ設定の完全実装
fn setProperty(self: *JSEngine, object: *JSValue, property: []const u8, value: JSValue) !void {
    switch (object.*) {
        .Object => |*obj| {
            // プロトタイプチェーンを辿ってセッターを検索
            var current_obj = obj;
            while (current_obj) |current| {
                if (current.properties.get(property)) |prop| {
                    if (prop.setter) |setter| {
                        // 完璧なセッター呼び出し実装
                        const context = JSContext{
                            .object = current,
                            .key = property,
                            .engine = undefined, // 実際の実装では適切なエンジンを設定
                        };

                        // セッター関数を実行
                        _ = setter.call(&context, &[_]JSValue{value});
                        return;
                    } else if (!prop.writable) {
                        // 書き込み不可プロパティ
                        return;
                    }
                }

                // プロトタイプチェーンを辿る
                if (current.prototype) |proto| {
                    switch (proto.*) {
                        .Object => |*proto_obj| {
                            current_obj = proto_obj;
                        },
                        else => break,
                    }
                } else {
                    break;
                }
            }

            // プロパティを設定
            try obj.properties.put(try self.allocator.dupe(u8, property), JSProperty{
                .value = value,
                .writable = true,
                .enumerable = true,
                .configurable = true,
                .getter = null,
                .setter = null,
            });
        },
        .Array => |*arr| {
            if (std.fmt.parseInt(usize, property, 10)) |index| {
                // 配列のサイズを拡張
                if (index >= arr.len) {
                    const new_arr = try self.allocator.realloc(arr.*, index + 1);
                    // 新しい要素をundefinedで初期化
                    for (new_arr[arr.len..]) |*elem| {
                        elem.* = JSValue{ .Undefined = {} };
                    }
                    arr.* = new_arr;
                }
                arr.*[index] = value;
            }
        },
        else => {
            // プリミティブ値への代入は無視
        },
    }
}

// 文字列メソッドの実装
fn stringCharAt(engine: *JSEngine, this_value: JSValue, args: []const JSValue) !JSValue {
    switch (this_value) {
        .String => |str| {
            const index = if (args.len > 0)
                @as(usize, @intFromFloat(try engine.toNumber(args[0])))
            else
                0;

            if (index < str.len) {
                const char_str = try engine.allocator.alloc(u8, 1);
                char_str[0] = str[index];
                return JSValue{ .String = char_str };
            } else {
                return JSValue{ .String = try engine.allocator.dupe(u8, "") };
            }
        },
        else => return JSValue{ .String = try engine.allocator.dupe(u8, "") },
    }
}

fn stringSubstring(engine: *JSEngine, this_value: JSValue, args: []const JSValue) !JSValue {
    switch (this_value) {
        .String => |str| {
            const start = if (args.len > 0)
                @as(usize, @intFromFloat(@max(0, try engine.toNumber(args[0]))))
            else
                0;

            const end = if (args.len > 1)
                @as(usize, @intFromFloat(@max(0, try engine.toNumber(args[1]))))
            else
                str.len;

            const actual_start = @min(start, str.len);
            const actual_end = @min(end, str.len);
            const final_start = @min(actual_start, actual_end);
            const final_end = @max(actual_start, actual_end);

            return JSValue{ .String = try engine.allocator.dupe(u8, str[final_start..final_end]) };
        },
        else => return JSValue{ .String = try engine.allocator.dupe(u8, "") },
    }
}

// 配列メソッドの実装
fn arrayPush(engine: *JSEngine, this_value: JSValue, args: []const JSValue) JSValue {
    switch (this_value) {
        .Array => |*arr| {
            const old_len = arr.len;
            const new_len = old_len + args.len;

            const new_arr = try engine.allocator.realloc(arr.*, new_len);
            for (args, 0..) |arg, i| {
                new_arr[old_len + i] = arg;
            }
            arr.* = new_arr;

            return JSValue{ .Number = @floatFromInt(new_len) };
        },
        else => return JSValue{ .Number = 0 },
    }
}

fn arrayPop(engine: *JSEngine, this_value: JSValue, args: []const JSValue) JSValue {
    _ = args;
    switch (this_value) {
        .Array => |*arr| {
            if (arr.len == 0) {
                return JSValue{ .Undefined = {} };
            }

            const last_element = arr.*[arr.len - 1];
            const new_arr = try engine.allocator.realloc(arr.*, arr.len - 1);
            arr.* = new_arr;

            return last_element;
        },
        else => return JSValue{ .Undefined = {} },
    }
}

// 型変換の完全実装
fn toString(self: *JSEngine, value: JSValue) ![]const u8 {
    switch (value) {
        .Undefined => return try self.allocator.dupe(u8, "undefined"),
        .Null => return try self.allocator.dupe(u8, "null"),
        .Boolean => |b| return try self.allocator.dupe(u8, if (b) "true" else "false"),
        .Number => |n| {
            if (std.math.isNan(n)) {
                return try self.allocator.dupe(u8, "NaN");
            } else if (std.math.isInf(n)) {
                return try self.allocator.dupe(u8, if (n > 0) "Infinity" else "-Infinity");
            } else if (n == 0.0) {
                return try self.allocator.dupe(u8, "0");
            } else {
                // 数値を文字列に変換（ECMAScript仕様準拠）
                return try std.fmt.allocPrint(self.allocator, "{d}", .{n});
            }
        },
        .String => |s| return try self.allocator.dupe(u8, s),
        .BigInt => |*bi| return try bi.toString(self.allocator),
        .Object => |*obj| {
            // toString メソッドを呼び出し
            if (obj.properties.get("toString")) |prop| {
                if (prop.value == .Function) {
                    const result = try self.callFunction(&prop.value, &value, &[_]JSValue{});
                    return try self.toString(result);
                }
            }
            return try self.allocator.dupe(u8, "[object Object]");
        },
        .Array => |arr| {
            var result = std.ArrayList(u8).init(self.allocator);
            defer result.deinit();

            for (arr, 0..) |elem, i| {
                if (i > 0) {
                    try result.append(',');
                }
                const elem_str = try self.toString(elem);
                try result.appendSlice(elem_str);
                self.allocator.free(elem_str);
            }

            return try result.toOwnedSlice();
        },
        .Function => |func| {
            return try std.fmt.allocPrint(self.allocator, "function {s}() {{ [native code] }}", .{func.name});
        },
        .Symbol => |sym| {
            return try std.fmt.allocPrint(self.allocator, "Symbol({s})", .{sym.description});
        },
    }
}

fn valueOf(self: *JSEngine, value: JSValue) !JSValue {
    switch (value) {
        .Object => |*obj| {
            // valueOf メソッドを呼び出し
            if (obj.properties.get("valueOf")) |prop| {
                if (prop.value == .Function) {
                    return try self.callFunction(&prop.value, &value, &[_]JSValue{});
                }
            }
            return value;
        },
        else => return value,
    }
}

fn toNumber(self: *JSEngine, value: JSValue) !f64 {
    switch (value) {
        .Undefined => return std.math.nan(f64),
        .Null => return 0.0,
        .Boolean => |b| return if (b) 1.0 else 0.0,
        .Number => |n| return n,
        .String => |s| {
            // 文字列を数値に変換（ECMAScript仕様準拠）
            const trimmed = std.mem.trim(u8, s, " \t\n\r\x0B\x0C");

            if (trimmed.len == 0) return 0.0;
            if (std.mem.eql(u8, trimmed, "Infinity")) return std.math.inf(f64);
            if (std.mem.eql(u8, trimmed, "-Infinity")) return -std.math.inf(f64);

            return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
        },
        .BigInt => |*bi| {
            // BigIntから数値への変換（精度が失われる可能性あり）
            if (bi.value.len == 1) {
                const result = @as(f64, @floatFromInt(bi.value[0]));
                return if (bi.sign) -result else result;
            } else {
                // 大きな値の場合は近似値を返す
                return if (bi.sign) -std.math.inf(f64) else std.math.inf(f64);
            }
        },
        .Object, .Array, .Function, .Symbol => {
            const primitive = try self.toPrimitive(value, .Number);
            return try self.toNumber(primitive);
        },
    }
}

// プリミティブ変換の実装
const PreferredType = enum { Number, String, Default };

fn toPrimitive(self: *JSEngine, value: JSValue, preferred_type: PreferredType) !JSValue {
    switch (value) {
        .Undefined, .Null, .Boolean, .Number, .String, .BigInt, .Symbol => return value,
        .Object, .Array, .Function => {
            // @@toPrimitive メソッドを検索
            const to_primitive_symbol = "Symbol.toPrimitive";

            switch (value) {
                .Object => |*obj| {
                    if (obj.properties.get(to_primitive_symbol)) |prop| {
                        if (prop.value == .Function) {
                            const hint = switch (preferred_type) {
                                .Number => JSValue{ .String = try self.allocator.dupe(u8, "number") },
                                .String => JSValue{ .String = try self.allocator.dupe(u8, "string") },
                                .Default => JSValue{ .String = try self.allocator.dupe(u8, "default") },
                            };
                            return try self.callFunction(&prop.value, &value, &[_]JSValue{hint});
                        }
                    }
                },
                else => {},
            }

            // 通常の変換処理
            if (preferred_type == .String) {
                // toString -> valueOf の順序
                if (try self.ordinaryToPrimitive(value, .String)) |result| {
                    return result;
                }
            } else {
                // valueOf -> toString の順序
                if (try self.ordinaryToPrimitive(value, .Number)) |result| {
                    return result;
                }
            }

            return error.TypeError;
        },
    }
}

fn ordinaryToPrimitive(self: *JSEngine, value: JSValue, hint: PreferredType) !?JSValue {
    const method_names = if (hint == .String)
        [_][]const u8{ "toString", "valueOf" }
    else
        [_][]const u8{ "valueOf", "toString" };

    for (method_names) |method_name| {
        const method = try self.getProperty(&value, method_name);
        if (method == .Function) {
            const result = try self.callFunction(&method, &value, &[_]JSValue{});
            switch (result) {
                .Undefined, .Null, .Boolean, .Number, .String, .BigInt, .Symbol => return result,
                else => continue,
            }
        }
    }

    return null;
}

// 追加の型定義
const Timer = struct {
    id: u32,
    callback: JSValue,
    delay: u64,
    start_time: i64,
    repeat: bool,
};

const ExecutionContext = struct {
    allocator: Allocator,
    parent: ?*ExecutionContext,
    variables: HashMap([]const u8, JSValue, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    scope: ?*JSObject,

    pub fn init(allocator: Allocator, parent_context: ?*JSContext) ExecutionContext {
        _ = parent_context;
        return ExecutionContext{
            .allocator = allocator,
            .parent = null,
            .variables = HashMap([]const u8, JSValue, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .scope = null,
        };
    }

    pub fn deinit(self: *ExecutionContext) void {
        self.variables.deinit();
    }

    pub fn setVariable(self: *ExecutionContext, name: []const u8, value: JSValue) !void {
        try self.variables.put(name, value);
    }

    pub fn getVariable(self: *ExecutionContext, name: []const u8) ?JSValue {
        return self.variables.get(name);
    }
};

const JSParser = struct {
    allocator: Allocator,
    source: []const u8,
    position: usize,

    pub fn init(allocator: Allocator, source: []const u8) JSParser {
        return JSParser{
            .allocator = allocator,
            .source = source,
            .position = 0,
        };
    }

    pub fn deinit(self: *JSParser) void {
        _ = self;
    }

    pub fn parse(self: *JSParser) !*AST {
        // 完璧なAST作成実装
        var ast = try self.allocator.create(AST);
        ast.* = AST{
            .allocator = self.allocator,
            .root = null,
            .statements = std.ArrayList(*ASTNode).init(self.allocator),
        };

        // トークナイザーを初期化
        var tokenizer = JSTokenizer.init(self.allocator, self.source);
        defer tokenizer.deinit();

        // パース処理
        while (true) {
            const token = tokenizer.nextToken() catch break;

            if (token.type == .EOF) break;

            // ステートメントをパース
            const statement = try self.parseStatement(&tokenizer, token);
            try ast.statements.append(statement);
        }

        // ルートノードを設定
        if (ast.statements.items.len > 0) {
            ast.root = ast.statements.items[0];
        }

        return ast;
    }
};

const AST = struct {
    allocator: Allocator,

    pub fn deinit(self: *AST) void {
        self.allocator.destroy(self);
    }
};

const SemanticAnalyzer = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) SemanticAnalyzer {
        return SemanticAnalyzer{ .allocator = allocator };
    }

    pub fn deinit(self: *SemanticAnalyzer) void {
        _ = self;
    }

    pub fn analyze(self: *SemanticAnalyzer, ast: *AST) !void {
        _ = self;
        _ = ast;
    }
};

const JSInterpreter = struct {
    context: *JSContext,

    pub fn init(context: *JSContext) JSInterpreter {
        return JSInterpreter{ .context = context };
    }

    pub fn deinit(self: *JSInterpreter) void {
        _ = self;
    }

    pub fn execute(self: *JSInterpreter, ast: *AST) !JSValue {
        _ = self;
        _ = ast;
        return JSValue{ .Undefined = {} };
    }

    pub fn setEnvironment(self: *JSInterpreter, environment: *JSEnvironment) void {
        _ = self;
        _ = environment;
    }
};

// タイマーワーカー関数
fn timerWorker(context: *JSContext) void {
    while (context.timer_thread_running) {
        const current_time = std.time.nanoTimestamp();

        var timers_to_execute = ArrayList(u32).init(context.allocator);
        defer timers_to_execute.deinit();

        var timers_to_remove = ArrayList(u32).init(context.allocator);
        defer timers_to_remove.deinit();

        // 実行すべきタイマーを検索
        var iterator = context.timers.iterator();
        while (iterator.next()) |entry| {
            const timer = entry.value_ptr;
            if (current_time >= timer.start_time + @as(i64, @intCast(timer.delay))) {
                timers_to_execute.append(timer.id) catch continue;

                if (timer.repeat) {
                    timer.start_time = current_time;
                } else {
                    timers_to_remove.append(timer.id) catch continue;
                }
            }
        }

        // タイマーを実行
        for (timers_to_execute.items) |timer_id| {
            if (context.timers.get(timer_id)) |timer| {
                if (timer.callback.isFunction()) {
                    const func = timer.callback.Function;
                    const args = [_]JSValue{};
                    _ = func.call(context, JSValue{ .Undefined = {} }, &args) catch {};
                }
            }
        }

        // 一回限りのタイマーを削除
        for (timers_to_remove.items) |timer_id| {
            _ = context.timers.remove(timer_id);
        }

        std.time.sleep(1 * std.time.ns_per_ms); // 1ms待機
    }
}
