// src/zig/dom/events/keyboard_event.zig
// KeyboardEvent インターフェース
// https://w3c.github.io/uievents/#interface-keyboardevent

const std = @import("std");
const UIEvent = @import("./ui_event.zig").UIEvent;
const UIEventInit = @import("./ui_event.zig").UIEventInit;
const Event = @import("../../events/event.zig").Event; // Base Event アクセスに必要
const EventConcreteType = @import("../../events/event.zig").EventConcreteType;
const time = std.time; // timestamp に必要

// KeyLocationCode Enum
// https://w3c.github.io/uievents/#dom-keyboardevent-location
pub const KeyLocation = enum(u32) {
    standard = 0,
    left = 1,
    right = 2,
    numpad = 3,
};

// KeyboardEventInit ディクショナリ
// https://w3c.github.io/uievents/#dictdef-keyboardeventinit
pub const KeyboardEventInit = struct {
    // UIEventInit のフィールドをインポート
    usingnamespace UIEventInit{};

    // KeyboardEvent 固有
    key: []const u8 = "",
    code: []const u8 = "",
    location: KeyLocation = .standard,
    repeat: bool = false,
    isComposing: bool = false,
};

pub const KeyboardEvent = struct {
    // UIEvent を最初のフィールドとして埋め込む
    base: UIEvent,

    key: []const u8, // 所有権を持つ
    code: []const u8, // 所有権を持つ
    location: KeyLocation,
    // ctrlKey などは base (UIEvent) が持つ
    repeat: bool,
    isComposing: bool,

    pub fn create(allocator: std.mem.Allocator, comptime event_type: []const u8, init: KeyboardEventInit) !*KeyboardEvent {
        const keyboard_event = try allocator.create(KeyboardEvent);
        errdefer allocator.destroy(keyboard_event);

        // base (UIEvent) 部分を初期化
        keyboard_event.base = UIEvent{
            .base = Event{
                .type = event_type,
                .bubbles = init.bubbles,
                .cancelable = init.cancelable,
                .composed = init.composed,
                .timeStamp = time.milliTimestamp(),
                .concrete_type = .Keyboard, // 型タグを設定
                .initialized = true,
                .target = null,
                .currentTarget = null,
                .eventPhase = .none,
                .isTrusted = false,
                .defaultPrevented = false,
                .propagation_stopped = false,
                .immediate_propagation_stopped = false,
                .dispatch = false,
            },
            .view = init.view,
            .detail = init.detail,
            .ctrlKey = init.ctrlKey,
            .shiftKey = init.shiftKey,
            .altKey = init.altKey,
            .metaKey = init.metaKey,
        };
        
        // key と code を複製して所有権を持つ (errdefer が必要)
        var owned_key: []const u8 = undefined;
        var owned_code: []const u8 = undefined;
        owned_key = try allocator.dupe(u8, init.key);
        errdefer allocator.free(owned_key);
        owned_code = try allocator.dupe(u8, init.code);
        errdefer allocator.free(owned_code); // code 確保失敗時に key を解放
        // 成功した場合、errdefer を解除するか、destroy で解放する。
        // -> KeyboardEvent の errdefer で destroy を呼ぶのが自然か？
        //    しかし、destroy は KeyboardEvent* を取る。初期化前に呼べない。
        // -> destroy で解放するので、ここでは errdefer のみ。
        
        // KeyboardEvent 固有のフィールドを初期化
        keyboard_event.key = owned_key;
        keyboard_event.code = owned_code;
        keyboard_event.location = init.location;
        keyboard_event.repeat = init.repeat;
        keyboard_event.isComposing = init.isComposing;

        std.log.debug("Created KeyboardEvent (type: {s})", .{event_type});
        return keyboard_event;
    }

    pub fn destroy(self: *KeyboardEvent, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying KeyboardEvent (type: {s})", .{self.base.base.type});
        // key と code のメモリを解放
        allocator.free(self.key);
        allocator.free(self.code);
        // Base UIEvent/Event は内包されているため、KeyboardEvent の destroy で一緒に解放される。
        allocator.destroy(self);
    }

    // getModifierState は base (UIEvent) に移譲

    // initKeyboardEvent は古いAPIであり、コンストラクタの使用が推奨されるため実装しない。
};

// テスト (修正)
test "KeyboardEvent creation" {
    const allocator = std.testing.allocator;
    const init = KeyboardEventInit {
        .bubbles = true,
        .cancelable = true,
        .key = "a",
        .code = "KeyA",
        .location = .standard,
        .ctrlKey = false,
        .shiftKey = true,
        .repeat = false,
    };
    var event = try KeyboardEvent.create(allocator, "keydown", init);
    defer event.destroy(allocator);

    // Base Event プロパティ
    try std.testing.expectEqualStrings("keydown", event.base.base.type);
    try std.testing.expect(event.base.base.bubbles == true);
    try std.testing.expect(event.base.base.concrete_type == .Keyboard); // 型タグ

    // UIEvent プロパティ (base 経由)
    try std.testing.expect(event.base.view == null);
    try std.testing.expect(event.base.ctrlKey == false);
    try std.testing.expect(event.base.shiftKey == true);

    // KeyboardEvent プロパティ
    try std.testing.expectEqualStrings("a", event.key);
    try std.testing.expectEqualStrings("KeyA", event.code);
    try std.testing.expect(event.location == .standard);
    try std.testing.expect(event.repeat == false);

    // getModifierState (UIEvent のメソッドを使う)
    try std.testing.expect(event.base.getModifierState("Shift"));
    try std.testing.expect(!event.base.getModifierState("Control"));
} 