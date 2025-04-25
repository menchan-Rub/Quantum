// src/zig/dom/events/mouse_event.zig
// MouseEvent インターフェース
// https://w3c.github.io/uievents/#interface-mouseevent

const std = @import("std");
const UIEvent = @import("./ui_event.zig").UIEvent;
const UIEventInit = @import("./ui_event.zig").UIEventInit;
const EventTarget = @import("../../events/event_target.zig").EventTarget;
const Event = @import("../../events/event.zig").Event; // Base Event アクセスに必要
const EventConcreteType = @import("../../events/event.zig").EventConcreteType;
const time = std.time; // timestamp に必要

// Modifier keys
// https://w3c.github.io/uievents/#idl-mouseevent-modifier-keys
const ModifierKeys = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    meta: bool = false,
};

// MouseEventInit ディクショナリ
// https://w3c.github.io/uievents/#dictdef-mouseeventinit
pub const MouseEventInit = struct {
    // UIEventInit のフィールドをインポート
    usingnamespace UIEventInit{};

    // MouseEvent 固有
    screenX: f64 = 0,
    screenY: f64 = 0,
    clientX: f64 = 0,
    clientY: f64 = 0,
    button: i16 = 0,
    buttons: u16 = 0,
    relatedTarget: ?*EventTarget = null,
};

pub const MouseEvent = struct {
    // UIEvent を最初のフィールドとして埋め込む
    base: UIEvent,

    screenX: f64,
    screenY: f64,
    clientX: f64,
    clientY: f64,
    // ctrlKey などは base (UIEvent) が持つ
    button: i16,
    buttons: u16,
    relatedTarget: ?*EventTarget,

    pub fn create(allocator: std.mem.Allocator, comptime event_type: []const u8, init: MouseEventInit) !*MouseEvent {
        const mouse_event = try allocator.create(MouseEvent);
        errdefer allocator.destroy(mouse_event);

        // base (UIEvent) 部分を初期化
        mouse_event.base = UIEvent{
            // base.base (Event) 部分
            .base = Event{
                .type = event_type,
                .bubbles = init.bubbles,
                .cancelable = init.cancelable,
                .composed = init.composed,
                .timeStamp = time.milliTimestamp(),
                .concrete_type = .Mouse, // 型タグを設定
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
            // base (UIEvent) 固有部分
            .view = init.view,
            .detail = init.detail,
            .ctrlKey = init.ctrlKey,
            .shiftKey = init.shiftKey,
            .altKey = init.altKey,
            .metaKey = init.metaKey,
        };

        // MouseEvent 固有のフィールドを初期化
        mouse_event.screenX = init.screenX;
        mouse_event.screenY = init.screenY;
        mouse_event.clientX = init.clientX;
        mouse_event.clientY = init.clientY;
        mouse_event.button = init.button;
        mouse_event.buttons = init.buttons;
        mouse_event.relatedTarget = init.relatedTarget;

        std.log.debug("Created MouseEvent (type: {s})", .{event_type});
        return mouse_event;
    }

    pub fn destroy(self: *MouseEvent, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying MouseEvent (type: {s})", .{self.base.base.type});
        // Base UIEvent/Event は内包されているため、MouseEvent の destroy で一緒に解放される。
        allocator.destroy(self);
    }

    // getModifierState は base (UIEvent) に移譲

    // TODO: initMouseEvent メソッド
};

// テスト (修正)
test "MouseEvent creation" {
    const allocator = std.testing.allocator;
    const init = MouseEventInit {
        .bubbles = true,
        .cancelable = true,
        .clientX = 100.5,
        .clientY = 200.0,
        .button = 1, // Middle button
        .ctrlKey = true,
        .shiftKey = false,
    };
    var event = try MouseEvent.create(allocator, "click", init);
    defer event.destroy(allocator);

    // Base Event プロパティ
    try std.testing.expectEqualStrings("click", event.base.base.type);
    try std.testing.expect(event.base.base.bubbles == true);
    try std.testing.expect(event.base.base.concrete_type == .Mouse); // 型タグ

    // UIEvent プロパティ (base 経由)
    try std.testing.expect(event.base.view == null);
    try std.testing.expect(event.base.ctrlKey == true);
    try std.testing.expect(event.base.shiftKey == false);

    // MouseEvent プロパティ
    try std.testing.expect(event.clientX == 100.5);
    try std.testing.expect(event.clientY == 200.0);
    try std.testing.expect(event.button == 1);
    try std.testing.expect(event.relatedTarget == null);

    // getModifierState (UIEvent のメソッドを使う)
    try std.testing.expect(event.base.getModifierState("Control"));
    try std.testing.expect(!event.base.getModifierState("Shift"));
} 