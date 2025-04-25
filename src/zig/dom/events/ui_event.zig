// src/zig/dom/events/ui_event.zig
// UIEvent インターフェース
// https://uievents.spec.whatwg.org/#interface-uievent

const std = @import("std");
const Event = @import("../../events/event.zig").Event;
const EventInit = @import("../../events/event.zig").EventInit;
const EventConcreteType = @import("../../events/event.zig").EventConcreteType;
const time = std.time; // time をインポート
// Window 型が必要になるが、循環参照を避けるか前方宣言を使う
// const Window = @import("../window/window.zig").Window;

// UIEventInit ディクショナリ
// https://uievents.spec.whatwg.org/#dictdef-uieventinit
pub const UIEventInit = struct {
    // EventInit を継承
    bubbles: bool = false,
    cancelable: bool = false,
    composed: bool = false,

    view: ?*anyopaque = null, // Window へのポインタ (本来は *Window)
    detail: i32 = 0,
    ctrlKey: bool = false,
    shiftKey: bool = false,
    altKey: bool = false,
    metaKey: bool = false,
};

pub const UIEvent = struct {
    // Event を最初のフィールドとして埋め込む
    base: Event,
    view: ?*anyopaque, // Window Proxy
    detail: i32,
    // 修飾キーの状態 (UIEventInit から取得するためフィールドは不要に)
    // ctrlKey: bool,
    // shiftKey: bool,
    // altKey: bool,
    // metaKey: bool,

    pub fn create(allocator: std.mem.Allocator, comptime event_type: []const u8, init: UIEventInit) !*UIEvent {
        const ui_event = try allocator.create(UIEvent);
        errdefer allocator.destroy(ui_event);

        // base (Event) 部分を初期化
        ui_event.base = Event{
            .type = event_type,
            .bubbles = init.bubbles,
            .cancelable = init.cancelable,
            .composed = init.composed,
            .timeStamp = time.milliTimestamp(),
            .concrete_type = .UI, // 型タグを設定
            .initialized = true, // 初期化済み
            // 他の Event フィールドはデフォルト値
            .target = null,
            .currentTarget = null,
            .eventPhase = .none,
            .isTrusted = false, // 通常 false
            .defaultPrevented = false,
            .propagation_stopped = false,
            .immediate_propagation_stopped = false,
            .dispatch = false,
        };

        // UIEvent 固有のフィールドを初期化
        ui_event.view = init.view;
        ui_event.detail = init.detail;
        // 修飾キーは init から取得するが、フィールドとしては持たない。
        // getModifierState は base.ctrlKey などにアクセスできない。
        // -> やはり UIEvent に修飾キーフィールドを持たせる必要がある。
        //    base (Event) には修飾キーフィールドがないため。
        //    -> Event に追加するか、UIEvent に追加するか？
        //       MouseEvent/KeyboardEvent Init で定義されるため、UIEvent が持つのが自然。

        // --- 再修正: UIEvent に修飾キーフィールドを追加 --- 
        // (フィールド定義を元に戻す)
        ui_event.ctrlKey = init.ctrlKey;
        ui_event.shiftKey = init.shiftKey;
        ui_event.altKey = init.altKey;
        ui_event.metaKey = init.metaKey;

        std.log.debug("Created UIEvent (type: {s})", .{event_type});
        return ui_event;
    }

    pub fn destroy(self: *UIEvent, allocator: std.mem.Allocator) void {
        std.log.debug("Destroying UIEvent (type: {s})", .{self.base.type});
        // Base Event は内包されているため、UIEvent の destroy で一緒に解放される。
        allocator.destroy(self);
    }

    /// 指定された修飾キーがアクティブだったかどうかを返します。
    pub fn getModifierState(self: *const UIEvent, key_arg: []const u8) bool {
        // フィールド定義を戻したので、再度フィールドを追加
        if (std.mem.eql(u8, key_arg, "Alt")) {
            return self.altKey;
        } else if (std.mem.eql(u8, key_arg, "Control")) {
            return self.ctrlKey;
        } else if (std.mem.eql(u8, key_arg, "Shift")) {
            return self.shiftKey;
        } else if (std.mem.eql(u8, key_arg, "Meta")) {
            return self.metaKey;
        } else {
            // TODO: CapsLock, NumLock, ScrollLock など
            // これらのキーの状態はプラットフォーム固有の方法で取得する必要がある。
            // 例: if (std.mem.eql(u8, key_arg, "CapsLock")) { return platform.getCapsLockState(); }
            return false; 
        }
    }

    // initUIEvent は古いAPIであり、コンストラクタの使用が推奨されるため実装しない。
};

// テスト
test "UIEvent creation" {
    const allocator = std.testing.allocator;
    const init = UIEventInit {
        .bubbles = true,
        .cancelable = false,
        .detail = 2,
        .ctrlKey = true,
        .metaKey = false,
    };
    var event = try UIEvent.create(allocator, "dblclick", init);
    defer event.destroy(allocator);

    // Base Event のプロパティを確認
    try std.testing.expectEqualStrings("dblclick", event.base.type);
    try std.testing.expect(event.base.bubbles == true);
    try std.testing.expect(event.base.concrete_type == .UI); // 型タグを確認
    
    // UIEvent 固有のプロパティを確認
    try std.testing.expect(event.view == null);
    try std.testing.expect(event.detail == 2);
    try std.testing.expect(event.ctrlKey == true); 
    try std.testing.expect(event.metaKey == false);

    // getModifierState のテスト
    try std.testing.expect(event.getModifierState("Control"));
    try std.testing.expect(!event.getModifierState("Meta"));
} 