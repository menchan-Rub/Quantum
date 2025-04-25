// src/zig/events/event_listener.zig
// DOM イベントリスナーのコールバック関数とオプションを定義します。
// https://dom.spec.whatwg.org/#callbackdef-eventlistener
// https://dom.spec.whatwg.org/#dictdef-eventlisteneroptions
// https://dom.spec.whatwg.org/#dictdef-addeventlisteneroptions

const std = @import("std");
const Event = @import("./event.zig").Event;

// handleEvent メソッドを持つリスナーオブジェクトのインターフェース
pub const EventListenerHandler = struct {
    // opaque ポインタと、handleEvent を呼び出す関数ポインタを保持
    ptr: *anyopaque,
    handleEventFn: fn(self_ptr: *anyopaque, event: *Event) callconv(.C) void,

    // オブジェクトの handleEvent を呼び出す
    pub fn handleEvent(self: EventListenerHandler, event: *Event) void {
        self.handleEventFn(self.ptr, event);
    }

    // 特定の型から EventListenerHandler を作成するヘルパー
    pub fn init(comptime T: type, obj_ptr: *T) EventListenerHandler {
        // T が handleEvent メソッドを持っているか確認 (コンパイル時)
        if (!@hasDecl(T, "handleEvent")) {
            @compileError("Type " ++ @typeName(T) ++ " does not have a handleEvent method");
        }
        // 型が handleEvent(self: *T, event: *Event) void のシグネチャを持つか確認
        // (これは静的には難しい場合がある)

        return EventListenerHandler{
            .ptr = @ptrCast(obj_ptr),
            .handleEventFn = struct {
                fn wrapper(self_ptr: *anyopaque, event: *Event) callconv(.C) void {
                    const typed_ptr: *T = @ptrCast(@alignCast(self_ptr));
                    typed_ptr.handleEvent(event);
                }
            }.wrapper,
        };
    }
};

// EventListener コールバック関数の型シグネチャ
pub const EventListenerCallback = fn (event: *Event, user_data: ?*anyopaque) callconv(.C) void;

// EventListener 型 (関数またはオブジェクト) - Union に変更
pub const EventListener = union(enum) {
    fn_ptr: struct {
        callback: EventListenerCallback,
        user_data: ?*anyopaque = null,
    },
    handler_obj: EventListenerHandler,

    // イベントを処理する (内部で型を判別)
    pub fn call(self: EventListener, event: *Event) void {
        switch (self) {
            .fn_ptr => |f| f.callback(event, f.user_data),
            .handler_obj => |h| h.handleEvent(event),
        }
    }

    // 比較関数 (リスナーの同一性チェック用)
    pub fn eql(a: EventListener, b: EventListener) bool {
        return switch (a) {
            .fn_ptr => |fa| switch (b) {
                .fn_ptr => |fb| fa.callback == fb.callback and fa.user_data == fb.user_data,
                else => false,
            },
            .handler_obj => |ha| switch (b) {
                .handler_obj => |hb| ha.ptr == hb.ptr and ha.handleEventFn == hb.handleEventFn,
                else => false,
            },
        };
    }
};

// EventListenerOptions ディクショナリに対応する構造体。
// removeEventListener で使用される。
pub const EventListenerOptions = struct {
    capture: bool = false,
};

// AddEventListenerOptions ディクショナリに対応する構造体。
// EventListenerOptions を継承する。
pub const AddEventListenerOptions = struct {
    capture: bool = false,
    once: bool = false,
    passive: bool = false,
    // signal: ?AbortSignal = null, // AbortSignal の実装が必要

    // EventListenerOptions から変換
    pub fn fromEventListenerOptions(options: EventListenerOptions) AddEventListenerOptions {
        return .{ .capture = options.capture };
    }
};

// イベントターゲットに登録されるリスナー情報を保持する内部構造体。
pub const RegisteredEventListener = struct {
    listener: EventListener, // Union 型に変更
    options: AddEventListenerOptions,
    // リスナーが削除されたかどうかを示すフラグ (反復中に安全に削除するため)
    removed: bool = false,

    pub fn create(
        listener: EventListener, // Union 型に変更
        options: AddEventListenerOptions,
    ) RegisteredEventListener {
        return .{ .listener = listener, .options = options };
    }

    // 同一性チェック (listener と capture フラグで判断)
    pub fn matches(self: RegisteredEventListener, other_listener: EventListener, use_capture: bool) bool {
        return self.listener.eql(other_listener) and self.options.capture == use_capture;
    }
};

// --- テスト用のスタブ関数とデータ ---
fn dummyCallback1(event: *Event, data: ?*anyopaque) callconv(.C) void {
    _ = event;
    if (data) |d| {
        const counter: *u32 = @ptrCast(@alignCast(d));
        counter.* += 1;
    }
    std.log.debug("dummyCallback1 executed", .{});
}

fn dummyCallback2(event: *Event, data: ?*anyopaque) callconv(.C) void {
    _ = event;
    _ = data;
    std.log.debug("dummyCallback2 executed", .{});
}

// handleEvent を持つテスト用構造体
const TestHandler = struct {
    counter: u32 = 0,

    pub fn handleEvent(self: *TestHandler, event: *Event) void {
        _ = event;
        self.counter += 1;
        std.log.debug("TestHandler.handleEvent executed", .{});
    }
};

// --- テスト ---
test "EventListener equality" {
    var counter: u32 = 0;
    const listener_fn_a = EventListener{ .fn_ptr = .{ .callback = dummyCallback1, .user_data = &counter } };
    const listener_fn_b = EventListener{ .fn_ptr = .{ .callback = dummyCallback1, .user_data = &counter } };
    const listener_fn_c = EventListener{ .fn_ptr = .{ .callback = dummyCallback1, .user_data = null } };
    const listener_fn_d = EventListener{ .fn_ptr = .{ .callback = dummyCallback2, .user_data = &counter } };

    var handler_obj_a = TestHandler{};
    var handler_obj_b = TestHandler{};
    const listener_obj_a = EventListener{ .handler_obj = EventListenerHandler.init(TestHandler, &handler_obj_a) };
    const listener_obj_a_dup = EventListener{ .handler_obj = EventListenerHandler.init(TestHandler, &handler_obj_a) };
    const listener_obj_b = EventListener{ .handler_obj = EventListenerHandler.init(TestHandler, &handler_obj_b) };

    // 関数ポインタリスナーの比較
    try std.testing.expect(listener_fn_a.eql(listener_fn_b));
    try std.testing.expect(!listener_fn_a.eql(listener_fn_c));
    try std.testing.expect(!listener_fn_a.eql(listener_fn_d));

    // オブジェクトリスナーの比較
    try std.testing.expect(listener_obj_a.eql(listener_obj_a_dup));
    try std.testing.expect(!listener_obj_a.eql(listener_obj_b));

    // 関数 vs オブジェクト
    try std.testing.expect(!listener_fn_a.eql(listener_obj_a));
}

test "AddEventListenerOptions defaults" {
    const default_options = AddEventListenerOptions{};
    try std.testing.expect(default_options.capture == false);
    try std.testing.expect(default_options.once == false);
    try std.testing.expect(default_options.passive == false);
}

test "RegisteredEventListener creation and matching" {
    const listener_fn = EventListener{ .fn_ptr = .{ .callback = dummyCallback1 } };
    var handler_obj = TestHandler{};
    const listener_obj = EventListener{ .handler_obj = EventListenerHandler.init(TestHandler, &handler_obj) };

    const reg1_capture = RegisteredEventListener.create(listener_fn, .{ .capture = true });
    const reg1_bubble = RegisteredEventListener.create(listener_fn, .{ .capture = false });
    const reg2_capture = RegisteredEventListener.create(listener_obj, .{ .capture = true });

    // Function listener matching
    try std.testing.expect(reg1_capture.matches(listener_fn, true));
    try std.testing.expect(!reg1_capture.matches(listener_fn, false));
    try std.testing.expect(!reg1_capture.matches(listener_obj, true)); // Different listener type

    // Object listener matching
    try std.testing.expect(reg2_capture.matches(listener_obj, true));
    try std.testing.expect(!reg2_capture.matches(listener_obj, false));
    try std.testing.expect(!reg2_capture.matches(listener_fn, true)); // Different listener type

    // Use reg1_bubble (Re-adding assertions for unused constant)
    try std.testing.expect(reg1_bubble.matches(listener_fn, false));
    try std.testing.expect(!reg1_bubble.matches(listener_fn, true));
} 