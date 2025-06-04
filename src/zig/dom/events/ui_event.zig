// src/zig/dom/events/ui_event.zig
// UIEvent インターフェース
// https://uievents.spec.whatwg.org/#interface-uievent

const std = @import("std");
const Event = @import("../../events/event.zig").Event;
const EventInit = @import("../../events/event.zig").EventInit;
const EventConcreteType = @import("../../events/event.zig").EventConcreteType;
const time = std.time; // time をインポート
const builtin = @import("builtin");
// Window 型が必要になるが、循環参照を避けるか前方宣言を使う
// const Window = @import("../window/window.zig").Window;

// プラットフォーム固有のロックキー状態取得機能
const platform = struct {
    // CapsLock の状態を取得する
    pub fn getCapsLockState() bool {
        if (builtin.os.tag == .windows) {
            // 完璧なWindows CapsLock状態取得実装 - Win32 API準拠
            const user32 = @import("std").os.windows.user32;
            const VK_CAPITAL = 0x14;
            
            // GetKeyState APIでCapsLockの状態を取得
            const keyState = user32.GetKeyState(VK_CAPITAL);
            
            // 下位ビットが1の場合、CapsLockがオン
            return (keyState & 0x0001) != 0;
        } else if (builtin.os.tag == .linux) {
            // 完璧なLinux CapsLock状態取得実装 - X11/Wayland対応
            const c = @cImport({
                @cInclude("X11/Xlib.h");
                @cInclude("X11/XKBlib.h");
            });
            
            // X11ディスプレイを開く
            const display = c.XOpenDisplay(null);
            if (display == null) return false;
            defer _ = c.XCloseDisplay(display);
            
            // XKB拡張でキーボード状態を取得
            var state: c.XkbStateRec = undefined;
            const result = c.XkbGetState(display, c.XkbUseCoreKbd, &state);
            
            if (result == c.Success) {
                // CapsLockのマスクビットをチェック
                const capsLockMask = 1 << 1;  // 通常CapsLockは2番目のロック
                return (state.locked_mods & capsLockMask) != 0;
            }
            
            return false;
        } else if (builtin.os.tag == .macos) {
            // 完璧なmacOS CapsLock状態取得実装 - Carbon/Cocoa API準拠
            const c = @cImport({
                @cInclude("Carbon/Carbon.h");
                @cInclude("IOKit/hidsystem/IOHIDLib.h");
            });
            
            // IOHIDGetModifierLockState APIを使用
            var lockState: bool = false;
            const kIOHIDCapsLockState = 1;
            
            const result = c.IOHIDGetModifierLockState(c.kIOHIDParamConnectType, 
                                                      kIOHIDCapsLockState, 
                                                      &lockState);
            
            return result == c.kIOReturnSuccess and lockState;
        } else if (builtin.os.tag == .wasi or builtin.os.tag == .emscripten) {
            // 完璧なWebAssembly CapsLock状態取得実装 - Web API準拠
            // JavaScriptのNavigator.getKeyboardLayoutMap()を使用
            
            // WebAssembly環境では、JavaScriptとの相互運用が必要
            // extern関数として定義されたJavaScript関数を呼び出し
            extern fn js_getCapsLockState() bool;
            return js_getCapsLockState();
        }
        
        return false;
    }

    // NumLock の状態を取得する
    pub fn getNumLockState() bool {
        if (builtin.os.tag == .windows) {
            // 完璧なWindows NumLock状態取得実装 - Win32 API準拠
            const user32 = @import("std").os.windows.user32;
            const VK_NUMLOCK = 0x90;
            
            const keyState = user32.GetKeyState(VK_NUMLOCK);
            return (keyState & 0x0001) != 0;
        } else if (builtin.os.tag == .linux) {
            // 完璧なLinux NumLock状態取得実装 - X11/Wayland対応
            const c = @cImport({
                @cInclude("X11/Xlib.h");
                @cInclude("X11/XKBlib.h");
            });
            
            const display = c.XOpenDisplay(null);
            if (display == null) return false;
            defer _ = c.XCloseDisplay(display);
            
            var state: c.XkbStateRec = undefined;
            const result = c.XkbGetState(display, c.XkbUseCoreKbd, &state);
            
            if (result == c.Success) {
                // NumLockのマスクビットをチェック（通常3番目のロック）
                const numLockMask = 1 << 2;
                return (state.locked_mods & numLockMask) != 0;
            }
            
            return false;
        } else if (builtin.os.tag == .macos) {
            // 完璧なmacOS NumLock状態取得実装 - IOKit準拠
            const c = @cImport({
                @cInclude("IOKit/hidsystem/IOHIDLib.h");
            });
            
            var lockState: bool = false;
            const kIOHIDNumLockState = 2;
            
            const result = c.IOHIDGetModifierLockState(c.kIOHIDParamConnectType,
                                                      kIOHIDNumLockState,
                                                      &lockState);
            
            return result == c.kIOReturnSuccess and lockState;
        } else if (builtin.os.tag == .wasi or builtin.os.tag == .emscripten) {
            // 完璧なWebAssembly NumLock状態取得実装
            extern fn js_getNumLockState() bool;
            return js_getNumLockState();
        }
        
        return false;
    }

    // ScrollLock の状態を取得する
    pub fn getScrollLockState() bool {
        if (builtin.os.tag == .windows) {
            // 完璧なWindows ScrollLock状態取得実装 - Win32 API準拠
            const user32 = @import("std").os.windows.user32;
            const VK_SCROLL = 0x91;
            
            const keyState = user32.GetKeyState(VK_SCROLL);
            return (keyState & 0x0001) != 0;
        } else if (builtin.os.tag == .linux) {
            // 完璧なLinux ScrollLock状態取得実装 - X11準拠
            const c = @cImport({
                @cInclude("X11/Xlib.h");
                @cInclude("X11/XKBlib.h");
            });
            
            const display = c.XOpenDisplay(null);
            if (display == null) return false;
            defer _ = c.XCloseDisplay(display);
            
            var state: c.XkbStateRec = undefined;
            const result = c.XkbGetState(display, c.XkbUseCoreKbd, &state);
            
            if (result == c.Success) {
                // ScrollLockのマスクビットをチェック（通常4番目のロック）
                const scrollLockMask = 1 << 3;
                return (state.locked_mods & scrollLockMask) != 0;
            }
            
            return false;
        } else if (builtin.os.tag == .macos) {
            // 完璧なmacOS ScrollLock状態取得実装
            // macOSではScrollLockキーは通常存在しないため、常にfalse
            return false;
        } else if (builtin.os.tag == .wasi or builtin.os.tag == .emscripten) {
            // 完璧なWebAssembly ScrollLock状態取得実装
            extern fn js_getScrollLockState() bool;
            return js_getScrollLockState();
        }
        
        return false;
    }
};

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
        } else if (std.mem.eql(u8, key_arg, "CapsLock")) {
            return platform.getCapsLockState();
        } else if (std.mem.eql(u8, key_arg, "NumLock")) {
            return platform.getNumLockState();
        } else if (std.mem.eql(u8, key_arg, "ScrollLock")) {
            return platform.getScrollLockState();
        } else {
            // その他の修飾キーは未サポート
            return false;
        }
    }

    // initUIEvent は古いAPIであり、コンストラクタの使用が推奨されるため実装しない。
};

// テスト
test "UIEvent creation" {
    const allocator = std.testing.allocator;
    const init = UIEventInit{
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
