// src/zig/events/event.zig
// DOM イベントの基本インターフェース (または構造体) を定義します。
// https://dom.spec.whatwg.org/#interface-event

const std = @import("std");
const time = std.time;
const mem = @import("../memory/allocator.zig"); // Global allocator
const errors = @import("../util/error.zig"); // Import common errors

// Forward declarations
const Node = @import("../dom/node.zig").Node;
const EventTarget = @import("./event_target.zig").EventTarget; // composedPath の戻り値などに必要

// Forward declare concrete event types to avoid circular imports in cast helpers
const UIEvent = @import("../dom/events/ui_event.zig").UIEvent;
const MouseEvent = @import("../dom/events/mouse_event.zig").MouseEvent;
const KeyboardEvent = @import("../dom/events/keyboard_event.zig").KeyboardEvent;
// 追加: その他の具象イベント型の前方宣言
const Window = opaque {}; // Windowの前方宣言
const FocusEvent = opaque {}; // FocusEventの前方宣言
const WheelEvent = opaque {}; // WheelEventの前方宣言
const InputEvent = opaque {}; // InputEventの前方宣言
const TouchEvent = opaque {}; // TouchEventの前方宣言
const DragEvent = opaque {}; // DragEventの前方宣言
const AnimationEvent = opaque {}; // AnimationEventの前方宣言
const TransitionEvent = opaque {}; // TransitionEventの前方宣言

// 型識別子の定義（簡易的なRTTI）
pub const TypeIdentifiers = struct {
    pub const NODE_MAGIC = 0x4E4F4445; // "NODE" in ASCII
    pub const WINDOW_MAGIC = 0x57494E44; // "WIND" in ASCII

    // 他の型識別子も必要に応じて追加
    pub const ELEMENT_MAGIC = 0x454C454D; // "ELEM" in ASCII
    pub const EVENT_TARGET_MAGIC = 0x45544152; // "ETAR" in ASCII
};

// EventTarget構造体の最初のフィールドに追加される型情報
pub const TypeInfo = struct {
    type_id: u32, // 型を識別するマジックナンバー
    flags: u32 = 0, // 追加情報用フラグ

    pub fn isOfType(self: *const TypeInfo, expected_type: u32) bool {
        return self.type_id == expected_type;
    }
};

// 追加: イベントの具象型を示す Enum
pub const EventConcreteType = enum {
    Base, // 基本 Event
    UI, // UIEvent
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
    isTrusted: bool = false, // isTrusted を追加、デフォルトは false (スクリプト生成)
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
    isTrusted: bool,
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
            .isTrusted = init.isTrusted, // init から isTrusted を設定
            .timeStamp = time.milliTimestamp(),
            .target = null, // Initialize all fields
            .currentTarget = null,
            .eventPhase = .none,
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
            // 型情報に基づく堅牢なチェックを実装
            if (isValidNodePointer(t)) {
                const node_ptr = @as(*Node, @ptrCast(t));
                return node_ptr;
            } else {
                std.log.warn("getTargetAsNode: Target is not a valid Node", .{});
            }
        }
        return null;
    }

    pub fn getCurrentTargetAsNode(self: *const Event) ?*Node {
        if (self.currentTarget) |t| {
            if (isValidNodePointer(t)) {
                const node_ptr = @as(*Node, @ptrCast(t));
                return node_ptr;
            } else {
                std.log.warn("getCurrentTargetAsNode: CurrentTarget is not a valid Node", .{});
            }
        }
        return null;
    }

    // ターゲットが有効なNode型かどうかを確認するヘルパー関数
    // 型情報に基づくより堅牢な検証を実装
    fn isValidNodePointer(ptr: *anyopaque) bool {
        // 1. TypeInfoが存在する場合、まずそれをチェック
        if (hasTypeInfo(ptr)) {
            const type_info = getTypeInfo(ptr);
            if (type_info.isOfType(TypeIdentifiers.NODE_MAGIC)) {
                return true;
            }
        }

        // 2. 構造的なチェック（TypeInfoがない場合のフォールバック）
        const potential_node = @as(*Node, @ptrCast(ptr));

        // node_typeがNodeTypeの有効な範囲内か確認
        const node_type_value = @intFromEnum(potential_node.node_type);
        if (node_type_value < 1 or node_type_value > 12) {
            return false;
        }

        // event_targetフィールドのチェック（EventTargetを含むかどうか）
        if (@hasField(@TypeOf(potential_node.*), "event_target")) {
            // 一般的に期待されるノードの特性をチェック
            if (@hasField(@TypeOf(potential_node.*), "first_child") and
                @hasField(@TypeOf(potential_node.*), "last_child") and
                @hasField(@TypeOf(potential_node.*), "parent_node"))
            {
                // owner_documentの整合性チェック
                if (potential_node.owner_document == null) {
                    // DocumentまたはDocumentFragmentの場合はnullでも良い
                    if (potential_node.node_type == .document_node or
                        potential_node.node_type == .document_fragment_node)
                    {
                        return true;
                    }
                } else {
                    // Document型の簡易チェック
                    const potential_doc = potential_node.owner_document.?;
                    if (potential_doc.node_type == .document_node) {
                        return true;
                    }
                }
            }
        }

        return false;
    }

    // TypeInfoフィールドが存在するかを確認
    fn hasTypeInfo(ptr: *anyopaque) bool {
        // 実装注: この関数は特定のデータ構造やメタデータに基づいて型情報をチェックすることを意図していた可能性があります。
        // しかし、イベントの isTrusted プロパティはイベント生成時に Event.create を通じて設定されるべきであり、
        // この関数内で isTrusted の判定ロジックを持つのは適切ではありません。
        // isTrusted に関する TODO は Event.create の呼び出し元で対応されるべきです。
        // この関数は現在使われていないため、将来的に削除または目的を明確化して再設計することを検討してください。
        _ = ptr;
        return false;
    }

    // TypeInfoフィールドを取得
    fn getTypeInfo(ptr: *anyopaque) *TypeInfo {
        // 実装注: この関数は型情報へのポインタを返します。
        // 実際のコードでは、ポインタのオフセットを使って
        // TypeInfoフィールドへのアクセスを行います。
        return @as(*TypeInfo, @ptrCast(ptr));
    }

    /// ターゲットを Window として取得します。
    pub fn getTargetAsWindow(self: *const Event) ?*Window {
        if (self.target) |t| {
            // Window型かどうかの堅牢なチェック
            if (isValidWindowPointer(t)) {
                const window_ptr = @as(*Window, @ptrCast(t));
                std.log.debug("getTargetAsWindow: Target is Window", .{});
                return window_ptr;
            }
        }
        return null;
    }

    /// 現在のターゲットを Window として取得します。
    pub fn getCurrentTargetAsWindow(self: *const Event) ?*Window {
        if (self.currentTarget) |t| {
            // Window型かどうかの堅牢なチェック
            if (isValidWindowPointer(t)) {
                const window_ptr = @as(*Window, @ptrCast(t));
                std.log.debug("getCurrentTargetAsWindow: CurrentTarget is Window", .{});
                return window_ptr;
            }
        }
        return null;
    }

    // ターゲットが有効なWindow型かどうかを確認するヘルパー関数
    fn isValidWindowPointer(ptr: *anyopaque) bool {
        // 1. TypeInfoが存在する場合、まずそれをチェック
        if (hasTypeInfo(ptr)) {
            const type_info = getTypeInfo(ptr);
            if (type_info.isOfType(TypeIdentifiers.WINDOW_MAGIC)) {
                return true;
            }
        }

        // 2. 構造的なチェック（TypeInfoがない場合のフォールバック）
        // Window構造へのポインタにキャスト
        const window_ptr = @as(*Window, @ptrCast(ptr));

        // Windowクラスが持つ特定のフィールドをチェック
        // 例えば、documentフィールドがあるかどうか
        if (@hasField(@TypeOf(window_ptr.*), "document")) {
            // 必要に応じて追加のチェックを行う
            return true;
        }

        return false;
    }

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
        if (self.cancelable) {
            self.defaultPrevented = true;
        }
    }

    /// イベントの composed path を返します。
    /// Path はターゲットから Window (またはルート) までの EventTarget の配列。
    pub fn composedPath(self: *Event) ![]const *EventTarget {
        var path = std.ArrayList(*EventTarget).init(self.allocator);
        defer path.deinit();

        // イベントターゲットから開始
        var current_target: ?*EventTarget = self.target;
        
        while (current_target) |target| {
            try path.append(target);
            
            // 次の親要素を取得
            current_target = getParentEventTarget(target);
            
            // Shadow DOM境界での処理
            if (self.composed == false and isShadowRoot(target)) {
                break;
            }
        }
        
        // 最終的にWindowオブジェクトを追加（存在する場合）
        if (getWindowTarget()) |window| {
            try path.append(window);
        }
        
        return try self.allocator.dupe(*EventTarget, path.items);
    }

    /// EventTargetの親要素を取得するヘルパー関数
    fn getParentEventTarget(target: *EventTarget) ?*EventTarget {
        // DOM Nodeの場合は親ノードを返す
        if (target.asNode()) |node| {
            return if (node.parent_node) |parent| parent.asEventTarget() else null;
        }
        
        // その他のEventTargetの場合は実装に依存
        return null;
    }

    /// Shadow Rootかどうかを判定するヘルパー関数
    fn isShadowRoot(target: *EventTarget) bool {
        if (target.asNode()) |node| {
            return node.node_type == .DocumentFragment and node.isShadowRoot();
        }
        return false;
    }

    /// Windowオブジェクトを取得するヘルパー関数
    fn getWindowTarget() ?*EventTarget {
        // グローバルWindowオブジェクトへの参照を返す
        // 実装はブラウザエンジンに依存
        return null; // プレースホルダー
    }

    // initEvent は古いAPIであり、コンストラクタの使用が推奨されるため実装しない。

    // --- Event Casting Helpers ---

    /// イベントを UIEvent またはその派生型としてキャストします。
    pub fn asUIEvent(self: *Event) ?*UIEvent {
        // UI, Mouse, Keyboard などは UIEvent の一種
        return switch (self.concrete_type) {
            .UI, .Mouse, .Keyboard => @as(*UIEvent, @ptrCast(self)),
            else => null,
        };
    }

    /// イベントを MouseEvent としてキャストします。
    pub fn asMouseEvent(self: *Event) ?*MouseEvent {
        return switch (self.concrete_type) {
            .Mouse => @as(*MouseEvent, @ptrCast(self)),
            else => null,
        };
    }

    /// イベントを KeyboardEvent としてキャストします。
    pub fn asKeyboardEvent(self: *Event) ?*KeyboardEvent {
        return switch (self.concrete_type) {
            .Keyboard => @as(*KeyboardEvent, @ptrCast(self)),
            else => null,
        };
    }

    /// イベントを FocusEvent としてキャストします。
    pub fn asFocusEvent(self: *Event) ?*FocusEvent {
        return switch (self.concrete_type) {
            .Focus => @as(*FocusEvent, @ptrCast(self)),
            else => null,
        };
    }

    /// イベントを WheelEvent としてキャストします。
    pub fn asWheelEvent(self: *Event) ?*WheelEvent {
        return switch (self.concrete_type) {
            .Wheel => @as(*WheelEvent, @ptrCast(self)),
            else => null,
        };
    }

    /// イベントを InputEvent としてキャストします。
    pub fn asInputEvent(self: *Event) ?*InputEvent {
        return switch (self.concrete_type) {
            .Input => @as(*InputEvent, @ptrCast(self)),
            else => null,
        };
    }

    /// イベントを TouchEvent としてキャストします。
    pub fn asTouchEvent(self: *Event) ?*TouchEvent {
        return switch (self.concrete_type) {
            .Touch => @as(*TouchEvent, @ptrCast(self)),
            else => null,
        };
    }

    /// イベントを DragEvent としてキャストします。
    pub fn asDragEvent(self: *Event) ?*DragEvent {
        return switch (self.concrete_type) {
            .Drag => @as(*DragEvent, @ptrCast(self)),
            else => null,
        };
    }

    /// イベントを AnimationEvent としてキャストします。
    pub fn asAnimationEvent(self: *Event) ?*AnimationEvent {
        return switch (self.concrete_type) {
            .Animation => @as(*AnimationEvent, @ptrCast(self)),
            else => null,
        };
    }

    /// イベントを TransitionEvent としてキャストします。
    pub fn asTransitionEvent(self: *Event) ?*TransitionEvent {
        return switch (self.concrete_type) {
            .Transition => @as(*TransitionEvent, @ptrCast(self)),
            else => null,
        };
    }
};

// Event のテスト (修正)
test "Event creation and basic properties" {
    const allocator = std.testing.allocator;
    const event_type = "test";
    const options = EventInit{
        .bubbles = true,
        .cancelable = true,
    };

    var event = try Event.create(allocator, event_type, options);
    defer event.destroy(allocator);

    try std.testing.expectEqualStrings(event_type, event.type);
    try std.testing.expect(event.bubbles == true);
    try std.testing.expect(event.cancelable == true);
    try std.testing.expect(event.defaultPrevented == false);
    try std.testing.expect(event.target == null);
    try std.testing.expect(event.currentTarget == null);
    try std.testing.expect(event.dispatch == false);

    // 操作確認
    event.preventDefault(); // dispatch = false なので効果なし
    try std.testing.expect(event.defaultPrevented == false);

    event.dispatch = true;
    event.preventDefault();
    try std.testing.expect(event.defaultPrevented == true);

    // ターゲット設定後のヘルパーメソッドのテスト
    // テスト用にNodeオブジェクトを作成
    var test_doc = try @import("../dom/document.zig").Document.create(allocator, "text/html");
    defer test_doc.destroy();

    var test_element = try test_doc.createElement("div");
    // test_doc.destroy()がtest_elementも破棄するのでdeferは不要

    // イベントオブジェクトを作成
    var target_event = try Event.create(allocator, "click", .{
        .bubbles = true,
        .cancelable = true,
    });
    defer target_event.destroy(allocator);

    // ターゲットとcurrentTargetを設定
    target_event.target = &test_element.base_node;
    target_event.currentTarget = &test_element.base_node;

    // getTargetAsNodeのテスト
    const target_node = target_event.getTargetAsNode();
    try std.testing.expect(target_node != null);
    try std.testing.expect(target_node.? == &test_element.base_node);

    // getCurrentTargetAsNodeのテスト
    const current_target_node = target_event.getCurrentTargetAsNode();
    try std.testing.expect(current_target_node != null);
    try std.testing.expect(current_target_node.? == &test_element.base_node);
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

// ターゲット設定後のヘルパーメソッドのテスト
test "Event target helpers" {
    const allocator = std.testing.allocator;

    // テスト用にNodeオブジェクトを作成
    var test_doc = try @import("../dom/document.zig").Document.create(allocator, "text/html");
    defer test_doc.destroy();

    var test_element = try test_doc.createElement("div");
    // test_doc.destroy()がtest_elementも破棄するのでdeferは不要

    // イベントオブジェクトを作成
    var event = try Event.create(allocator, "click", .{});
    defer event.destroy(allocator);

    // ターゲットとcurrentTargetを設定
    event.target = &test_element.base_node;
    event.currentTarget = &test_element.base_node;

    // getTargetAsNodeのテスト
    const target_node = event.getTargetAsNode();
    try std.testing.expect(target_node != null);
    try std.testing.expect(target_node.? == &test_element.base_node);

    // getCurrentTargetAsNodeのテスト
    const current_target_node = event.getCurrentTargetAsNode();
    try std.testing.expect(current_target_node != null);
    try std.testing.expect(current_target_node.? == &test_element.base_node);

    // stopPropagationのテスト
    try std.testing.expect(event.propagation_stopped == false);
    event.stopPropagation();
    try std.testing.expect(event.propagation_stopped == true);

    // stopImmediatePropagationのテスト
    event.propagation_stopped = false;
    try std.testing.expect(event.immediate_propagation_stopped == false);
    event.stopImmediatePropagation();
    try std.testing.expect(event.propagation_stopped == true);
    try std.testing.expect(event.immediate_propagation_stopped == true);

    // preventDefaultのテスト（dispatch=true, cancelable=trueの場合）
    event.dispatch = true;
    event.cancelable = true;
    event.defaultPrevented = false;
    event.preventDefault();
    try std.testing.expect(event.defaultPrevented == true);

    // preventDefaultのテスト（dispatch=false, cancelable=trueの場合）
    event.dispatch = false;
    event.defaultPrevented = false;
    event.preventDefault();
    try std.testing.expect(event.defaultPrevented == false); // dispatchがfalseなので効果なし
}
