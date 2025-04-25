// src/zig/events/event.zig
// DOM イベントの基本インターフェース (または構造体) を定義します。
// https://dom.spec.whatwg.org/#interface-event

const std = @import("std");
const time = std.time;
const mem = @import("../memory/allocator.zig"); // Global allocator
const errors = @import("../util/error.zig");   // Import common errors

// Forward declarations
const Node = @import("../dom/node.zig").Node;
const EventTarget = @import("./event_target.zig").EventTarget; // composedPath の戻り値などに必要

// Forward declare concrete event types to avoid circular imports in cast helpers
const UIEvent = @import("../dom/events/ui_event.zig").UIEvent;
const MouseEvent = @import("../dom/events/mouse_event.zig").MouseEvent;
const KeyboardEvent = @import("../dom/events/keyboard_event.zig").KeyboardEvent;

// 追加: イベントの具象型を示す Enum
pub const EventConcreteType = enum {
    Base, // 基本 Event
    UI,   // UIEvent
    Mouse, // MouseEvent
    Keyboard, // KeyboardEvent
    Focus, // FocusEvent (将来用)
    Wheel, // WheelEvent (将来用)
    // ... 他のイベントタイプ
};

// イベントフェーズ定数
// https://dom.spec.whatwg.org/#dom-event-eventphase
pub const EventPhase = enum(u8) {
    none = 0,
    capturing_phase = 1,
    at_target = 2,
    bubbling_phase = 3,
};

// EventInit ディクショナリに対応する構造体
// https://dom.spec.whatwg.org/#dictdef-eventinit
pub const EventInit = struct {
    bubbles: bool = false,
    cancelable: bool = false,
    composed: bool = false,
};

// イベントの基本構造体
pub const Event = struct {
    // --- Public API (Read-only properties) ---
    /// イベントのタイプ (例: "click", "load")。
    type: []const u8,
    /// イベントの元のターゲット。
    /// 様々な型 (Node, Window など) がターゲットになりうるため anyopaque を使用。
    target: ?*anyopaque = null,
    /// イベントが現在処理されているターゲット。
    currentTarget: ?*anyopaque = null,
    /// イベントフローの現在のフェーズ。
    eventPhase: EventPhase = .none,
    /// イベントがバブリングするかどうか。
    bubbles: bool,
    /// イベントがキャンセル可能かどうか。
    cancelable: bool,
    /// イベントが Shadow DOM 境界を越えて伝播するかどうか。
    composed: bool,
    /// イベントが信頼されているか (ユーザー操作によるか)。
    isTrusted: bool = false, // デフォルトは false
    /// イベント作成時のタイムスタンプ (ミリ秒)。
    timeStamp: time.timestamp_ms_t,
    /// preventDefault が呼ばれたか。
    defaultPrevented: bool = false,
    /// 追加: イベントの具象型タグ
    concrete_type: EventConcreteType = .Base,

    // --- Internal State ---
    /// 内部フラグ: stopPropagation が呼ばれたか。
    propagation_stopped: bool = false,
    /// 内部フラグ: stopImmediatePropagation が呼ばれたか。
    immediate_propagation_stopped: bool = false,
    /// 内部フラグ: イベントがディスパッチ中か。
    dispatch: bool = false,
    /// 内部フラグ: composed path が計算されたか。
    initialized: bool = false, // path 計算済みフラグから初期化済みフラグに変更

    // イベントを作成する関数。
    pub fn create(allocator: std.mem.Allocator, comptime event_type: []const u8, init: EventInit) !*Event {
        const event = try allocator.create(Event);
        errdefer allocator.destroy(event);

        event.* = Event{
            .concrete_type = .Base, // デフォルトは Base
            .type = event_type,
            .bubbles = init.bubbles,
            .cancelable = init.cancelable,
            .composed = init.composed,
            .timeStamp = time.milliTimestamp(),
            .target = null, // Initialize all fields
            .currentTarget = null,
            .eventPhase = .none,
            .isTrusted = false,
            .defaultPrevented = false,
            .propagation_stopped = false,
            .immediate_propagation_stopped = false,
            .dispatch = false,
            .initialized = true, // Create sets it to initialized
        };
        std.log.debug("Created Event (type: {s})", .{event_type});
        return event;
    }

    // イベントインスタンスを破棄する関数。
    pub fn destroy(event: *Event, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying Event (type: {s})", .{event.type});
        allocator.destroy(event);
    }

    // --- Type-safe target accessors ---
    // ターゲットを Node として取得 (より安全なチェックを追加)
    pub fn getTargetAsNode(self: *const Event) ?*Node {
        if (self.target) |t| {
            // TODO: より堅牢な RTTI やインターフェースベースのチェックが望ましい
            //       ここでは EventTarget* へのキャストを試み、Node かどうかを判定する
            const target_et: *EventTarget = @ptrCast(@alignCast(t));
            // EventTarget が Node* を保持しているか、
            // または EventTarget が Node の一部であるかを判定する必要がある。
            // 現状では Node.event_target という構成なので、
            // EventTarget から Node* を取得するヘルパーが必要か？
            // 一旦、anyopaque のまま Node* にキャストしてみる。
            _ = target_et; // 未使用警告を抑制
            const node_ptr: *Node = @ptrCast(@alignCast(t));
            // 簡易チェック: node_type が存在するか
            // これだけでは不十分だが、最低限の確認
            if (comptime std.meta.hasField(Node, "node_type")) {
                // @field はインスタンスが必要なので使えない
                // ポインタの先に node_type があると仮定してアクセスは危険。
                // -> 現状の Node* キャスト & ログで対応
                 std.log.debug("getTargetAsNode: Assuming target is Node", .{});
                 return node_ptr;
            }
        }
        return null;
    }

    pub fn getCurrentTargetAsNode(self: *const Event) ?*Node {
         if (self.currentTarget) |t| {
             const node_ptr: *Node = @ptrCast(@alignCast(t));
             std.log.debug("getCurrentTargetAsNode: Assuming currentTarget is Node", .{});
             return node_ptr;
         }
         return null;
    }

    // TODO: getTargetAsWindow など、他のターゲットタイプ用のアクセサ

    // --- Public API (Methods) ---

    /// イベントの伝播を停止します。
    pub fn stopPropagation(self: *Event) void {
        self.propagation_stopped = true;
    }

    /// イベントの即時伝播を停止します (同じレベルの他のリスナーも実行されない)。
    pub fn stopImmediatePropagation(self: *Event) void {
        self.propagation_stopped = true;
        self.immediate_propagation_stopped = true;
    }

    /// イベントのデフォルトアクションをキャンセルします (cancelable な場合)。
    pub fn preventDefault(self: *Event) void {
        // dispatch フラグが立っている間（ディスパッチ中）のみキャンセル可能
        if (self.cancelable and self.dispatch) {
            self.defaultPrevented = true;
        } else if (!self.dispatch) {
            std.log.warn("preventDefault() called outside dispatch phase for event type {s}", .{self.type});
        } else if (!self.cancelable) {
             std.log.warn("preventDefault() called for non-cancelable event type {s}", .{self.type});
        }
    }

    /// イベントの composed path を返します (未実装)。
    /// Path はターゲットから Window (またはルート) までの EventTarget の配列。
    pub fn composedPath() ![]*EventTarget {
        return error.NotImplemented;
    }

    // initEvent は古いAPIであり、コンストラクタの使用が推奨されるため実装しない。

    // --- Event Casting Helpers ---

    /// イベントを UIEvent またはその派生型としてキャストします。
    pub fn asUIEvent(self: *Event) ?*UIEvent {
        // UI, Mouse, Keyboard などは UIEvent の一種
        return switch (self.concrete_type) {
            .UI, .Mouse, .Keyboard => @ptrCast(UIEvent, self),
            else => null,
        };
    }

    /// イベントを MouseEvent としてキャストします。
    pub fn asMouseEvent(self: *Event) ?*MouseEvent {
        return switch (self.concrete_type) {
            .Mouse => @ptrCast(MouseEvent, self),
            else => null,
        };
    }

    /// イベントを KeyboardEvent としてキャストします。
    pub fn asKeyboardEvent(self: *Event) ?*KeyboardEvent {
         return switch (self.concrete_type) {
            .Keyboard => @ptrCast(KeyboardEvent, self),
            else => null,
        };
    }

    // TODO: 他のキャストヘルパー (FocusEvent, WheelEvent など)

};

// Event のテスト (修正)
test "Event creation and basic properties" {
    const allocator = std.testing.allocator;
    const event_type = "click";
    const init = EventInit{
        .bubbles = true,
        .cancelable = true,
        .composed = false,
    };

    var event = try Event.create(allocator, event_type, init);
    defer event.destroy(allocator);

    try std.testing.expectEqualStrings(event_type, event.type);
    try std.testing.expect(event.concrete_type == .Base); // 型タグを確認
    try std.testing.expect(event.target == null);
    try std.testing.expect(event.currentTarget == null);
    try std.testing.expect(event.eventPhase == .none);
    try std.testing.expect(event.bubbles == true);
    try std.testing.expect(event.cancelable == true);
    try std.testing.expect(event.composed == false);
    try std.testing.expect(event.isTrusted == false);
    try std.testing.expect(event.timeStamp > 0);

    try std.testing.expect(event.propagation_stopped == false);
    try std.testing.expect(event.immediate_propagation_stopped == false);
    try std.testing.expect(event.defaultPrevented == false); // canceled を defaultPrevented に変更
}

// Cast helper tests
test "Event casting helpers" {
    const allocator = std.testing.allocator;
    
    // Base Event
    var base_event = try Event.create(allocator, "custom", .{});
    defer base_event.destroy(allocator);
    try std.testing.expect(base_event.asUIEvent() == null);
    try std.testing.expect(base_event.asMouseEvent() == null);
    try std.testing.expect(base_event.asKeyboardEvent() == null);

    // UIEvent
    var ui_event_ptr = try UIEvent.create(allocator, "scroll", .{});
    defer ui_event_ptr.destroy(allocator);
    var ui_event_base: *Event = &ui_event_ptr.base; // Get base Event* pointer
    try std.testing.expect(ui_event_base.asUIEvent() == ui_event_ptr);
    try std.testing.expect(ui_event_base.asMouseEvent() == null);
    try std.testing.expect(ui_event_base.asKeyboardEvent() == null);

    // MouseEvent
    var mouse_event_ptr = try MouseEvent.create(allocator, "click", .{});
    defer mouse_event_ptr.destroy(allocator);
    var mouse_event_base: *Event = &mouse_event_ptr.base.base; // Get base Event* pointer
    try std.testing.expect(mouse_event_base.asUIEvent() == &mouse_event_ptr.base);
    try std.testing.expect(mouse_event_base.asMouseEvent() == mouse_event_ptr);
    try std.testing.expect(mouse_event_base.asKeyboardEvent() == null);

    // KeyboardEvent
    var kbd_event_ptr = try KeyboardEvent.create(allocator, "keydown", .{});
    defer kbd_event_ptr.destroy(allocator);
    var kbd_event_base: *Event = &kbd_event_ptr.base.base; // Get base Event* pointer
    try std.testing.expect(kbd_event_base.asUIEvent() == &kbd_event_ptr.base);
    try std.testing.expect(kbd_event_base.asMouseEvent() == null);
    try std.testing.expect(kbd_event_base.asKeyboardEvent() == kbd_event_ptr);
}

test "Event methods" {
    const allocator = std.testing.allocator;
    var event_cancelable = try Event.create(allocator, "submit", .{ .cancelable = true });
    defer event_cancelable.destroy(allocator);

    var event_not_cancelable = try Event.create(allocator, "load", .{ .cancelable = false });
    defer event_not_cancelable.destroy(allocator);

    // stopPropagation
    try std.testing.expect(!event_cancelable.propagation_stopped);
    event_cancelable.stopPropagation();
    try std.testing.expect(event_cancelable.propagation_stopped);
    try std.testing.expect(!event_cancelable.immediate_propagation_stopped);

    // stopImmediatePropagation
    try std.testing.expect(!event_not_cancelable.immediate_propagation_stopped);
    event_not_cancelable.stopImmediatePropagation();
    try std.testing.expect(event_not_cancelable.propagation_stopped);
    try std.testing.expect(event_not_cancelable.immediate_propagation_stopped);

    // preventDefault (dispatch フラグがないとキャンセルされない)
    try std.testing.expect(!event_cancelable.defaultPrevented);
    event_cancelable.preventDefault(); // dispatch 外なので効果なし (ログが出るはず)
    try std.testing.expect(!event_cancelable.defaultPrevented);
    // dispatch 中だと仮定してフラグを立てるテスト
    event_cancelable.dispatch = true;
    event_cancelable.preventDefault();
    try std.testing.expect(event_cancelable.defaultPrevented);
    event_cancelable.dispatch = false; // Reset flag

    // cancelable = false の場合
    try std.testing.expect(!event_not_cancelable.defaultPrevented);
    event_not_cancelable.dispatch = true;
    event_not_cancelable.preventDefault(); // cancelable=false なので効果なし (ログが出るはず)
    try std.testing.expect(!event_not_cancelable.defaultPrevented);
    event_not_cancelable.dispatch = false;
} 