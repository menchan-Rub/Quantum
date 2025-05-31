const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Node = @import("node.zig").Node; // ヘルパーメソッドのための前方宣言
const EventTarget = @import("../events/event_target.zig").EventTarget; // ヘルパーメソッドのための前方宣言

/// イベントの伝播フェーズを示す定数
/// @rules https://dom.spec.whatwg.org/#event-phase
pub const PhaseType = enum(u2) {
    NONE = 0,
    CAPTURING_PHASE = 1,
    AT_TARGET = 2,
    BUBBLING_PHASE = 3,
};

/// DOM イベントを表す基本クラス
/// @rules https://dom.spec.whatwg.org/#event
/// @notes 現在は基本的なプロパティのみ実装
pub const Event = extern struct {
    allocator: Allocator,
    type: []const u8, // イベントタイプ名 (例: "click", "load")
    bubbles: bool, // イベントがバブリングするかどうか
    cancelable: bool, // イベントがキャンセル可能か (preventDefault)
    composed: bool, // イベントが Shadow DOM 境界を越えて伝播するかどうか (未実装)

    target_ptr: ?*anyopaque,
    current_target_ptr: ?*anyopaque,

    eventPhase: PhaseType = .NONE, // 現在のイベント伝播フェーズ
    propagationStopped: bool = false, // stopPropagation が呼ばれたか
    immediatePropagationStopped: bool = false, // stopImmediatePropagation が呼ばれたか
    canceled: bool = false, // preventDefault が呼ばれたか
    initialized: bool = false, // イベントが初期化されたか
    dispatching: bool = false, // イベントがディスパッチ中か

    extern fn quantum_Event_getTarget(event_ptr: *anyopaque) ?*anyopaque;
    extern fn quantum_Event_getCurrentTarget(event_ptr: *anyopaque) ?*anyopaque;

    /// @rule コンストラクタ (https://dom.spec.whatwg.org/#dom-event-event)
    /// @param allocator メモリアロケータ
    /// @param event_type イベントタイプ名
    /// @param bubbles イベントがバブリングするか (デフォルト: false)
    /// @param cancelable イベントがキャンセル可能か (デフォルト: false)
    /// @param composed イベントが Shadow DOM 境界を越えて伝播するか (デフォルト: false)
    /// @returns 作成された Event インスタンス、またはメモリエラー
    pub fn create(
        allocator: Allocator,
        event_type: []const u8,
        bubbles: bool,
        cancelable: bool,
        composed: bool,
    ) !*Event {
        const event = try allocator.create(Event);
        event.* = .{
            .allocator = allocator,
            .type = try allocator.dupe(u8, event_type),
            .bubbles = bubbles,
            .cancelable = cancelable,
            .composed = composed,
            .initialized = true, // 作成時に初期化済みとする
            // 以下はデフォルト値で初期化される
            .target_ptr = null,
            .current_target_ptr = null,
            .eventPhase = .NONE,
            .propagationStopped = false,
            .immediatePropagationStopped = false,
            .canceled = false,
            .dispatching = false,
        };
        return event;
    }

    /// Event インスタンスを破棄し、関連メモリを解放します。
    /// @param self イベントインスタンス
    pub fn destroy(self: *Event) void {
        self.allocator.free(self.type);
        self.allocator.destroy(self);
    }

    /// @rule https://dom.spec.whatwg.org/#dom-event-stoppropagation
    pub fn stopPropagation(self: *Event) void {
        self.propagationStopped = true;
    }

    /// @rule https://dom.spec.whatwg.org/#dom-event-stopimmediatepropagation
    pub fn stopImmediatePropagation(self: *Event) void {
        self.propagationStopped = true;
        self.immediatePropagationStopped = true;
    }

    /// @rule https://dom.spec.whatwg.org/#dom-event-preventdefault
    pub fn preventDefault(self: *Event) void {
        if (self.cancelable) {
            self.canceled = true;
        }
    }

    // --- ヘルパーメソッド ---

    /// `target` フィールドを Node 型として取得します。
    /// @returns Node へのポインタ、または target が Node でない場合は null
    pub fn getTarget(self: *const Event) ?*Node {
        const target_ptr = quantum_Event_getTarget(@ptrCast(self));
        if (target_ptr == null) return null;
        // 不透明ポインタを特定の Node ポインタにキャストします。
        // C/Crystal が正しい型のポインタを提供すると仮定します。
        return @ptrCast(target_ptr.?);
    }

    /// `currentTarget` フィールドを Node 型として取得します。
    /// @returns Node へのポインタ、または currentTarget が Node でない場合は null
    pub fn getCurrentTarget(self: *const Event) ?*Node {
        const current_target_ptr = quantum_Event_getCurrentTarget(@ptrCast(self));
        if (current_target_ptr == null) return null;
        // 不透明ポインタを特定の Node ポインタにキャストします。
        return @ptrCast(current_target_ptr.?);
    }

    /// `currentTarget` フィールドを EventTarget 型として取得します。
    /// @returns EventTarget へのポインタ、または currentTarget が EventTarget でない場合は null
    pub fn getCurrentTargetAsTarget(self: *const Event) ?*EventTarget {
        const current_target_ptr = quantum_Event_getCurrentTarget(@ptrCast(self));
        if (current_target_ptr == null) return null;
        // 不透明ポインタを特定の EventTarget ポインタにキャストします。
        return @ptrCast(current_target_ptr.?);
    }
};

test "Event creation and destruction" {
    const allocator = std.testing.allocator;
    const event = try Event.create(allocator, "click", true, true, false);
    defer event.destroy();

    try std.testing.expect(std.mem.eql(u8, event.type, "click"));
    try std.testing.expect(event.bubbles);
    try std.testing.expect(event.cancelable);
    try std.testing.expect(!event.composed);
    try std.testing.expect(event.target_ptr == null);
    try std.testing.expect(event.current_target_ptr == null);
    try std.testing.expect(event.eventPhase == .NONE);
    try std.testing.expect(!event.propagationStopped);
    try std.testing.expect(!event.immediatePropagationStopped);
    try std.testing.expect(!event.canceled);
    try std.testing.expect(event.initialized);
    try std.testing.expect(!event.dispatching);
}

test "Event methods" {
    const allocator = std.testing.allocator;
    var event = try Event.create(allocator, "test", true, true, false);
    defer event.destroy();

    event.stopPropagation();
    try std.testing.expect(event.propagationStopped);
    try std.testing.expect(!event.immediatePropagationStopped);

    event.stopImmediatePropagation();
    try std.testing.expect(event.propagationStopped);
    try std.testing.expect(event.immediatePropagationStopped);

    event.preventDefault();
    try std.testing.expect(event.canceled);

    // キャンセル不可のイベント
    var nonCancelableEvent = try Event.create(allocator, "test2", false, false, false);
    defer nonCancelableEvent.destroy();
    nonCancelableEvent.preventDefault();
    try std.testing.expect(!nonCancelableEvent.canceled);

    // ヘルパーメソッド (ターゲットが null の場合)
    try std.testing.expect(event.getTarget() == null);
    try std.testing.expect(event.getCurrentTarget() == null);
    try std.testing.expect(event.getCurrentTargetAsTarget() == null);

    // ターゲット設定後のヘルパーメソッドのテスト
    const NodeType = @import("node.zig").Node;
    const EventTargetType = @import("../events/event_target.zig").EventTarget;

    // モックターゲットの準備
    // 注: 実際のEventTargetとNodeを使用するより、テストのためのモック実装
    const MockNode = struct {
        node_base: Node = undefined,

        pub fn init(allocator: Allocator) !*@This() {
            var self = try allocator.create(@This());
            self.node_base = Node.init(allocator);
            return self;
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            allocator.destroy(self);
        }
    };

    const MockEventTarget = struct {
        event_target_base: EventTarget = undefined,

        pub fn init(allocator: Allocator) !*@This() {
            var self = try allocator.create(@This());
            self.event_target_base = EventTarget.init();
            return self;
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            allocator.destroy(self);
        }
    };

    // モックオブジェクトの作成
    var mock_node = try MockNode.init(allocator);
    defer mock_node.deinit(allocator);

    var mock_target = try MockEventTarget.init(allocator);
    defer mock_target.deinit(allocator);

    // テスト用イベント
    var target_event = try Event.create(allocator, "target-test", true, true, false);
    defer target_event.destroy();

    // FFI関数の代わりにテスト用の関数を設定
    const original_getTarget = quantum_Event_getTarget;
    const original_getCurrentTarget = quantum_Event_getCurrentTarget;

    // テスト用の一時的な実装
    quantum_Event_getTarget = (struct {
        fn mock(_: *anyopaque) ?*anyopaque {
            return @ptrCast(mock_node);
        }
    }).mock;

    quantum_Event_getCurrentTarget = (struct {
        fn mock(_: *anyopaque) ?*anyopaque {
            return @ptrCast(mock_target);
        }
    }).mock;

    // ヘルパーメソッドのテスト
    const target = target_event.getTarget();
    try std.testing.expect(target != null);
    try std.testing.expectEqual(@ptrCast(mock_node), target.?);

    const current_target_node = target_event.getCurrentTarget();
    try std.testing.expect(current_target_node != null);

    const current_target_event_target = target_event.getCurrentTargetAsTarget();
    try std.testing.expect(current_target_event_target != null);
    try std.testing.expectEqual(@ptrCast(mock_target), current_target_event_target.?);

    // 元のFFI関数を復元
    quantum_Event_getTarget = original_getTarget;
    quantum_Event_getCurrentTarget = original_getCurrentTarget;
}
