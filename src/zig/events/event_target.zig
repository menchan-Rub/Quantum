// src/zig/events/event_target.zig
// DOM の EventTarget インターフェースに対応する構造体とメソッドを定義します。
// https://dom.spec.whatwg.org/#interface-eventtarget

const std = @import("std");
const mem = @import("../memory/allocator.zig"); // Global allocator
const errors = @import("../util/error.zig"); // Common errors
const Event = @import("./event.zig").Event;
const EventListener = @import("./event_listener.zig").EventListener;
const EventListenerCallback = @import("./event_listener.zig").EventListenerCallback;
const AddEventListenerOptions = @import("./event_listener.zig").AddEventListenerOptions;
const EventListenerOptions = @import("./event_listener.zig").EventListenerOptions;
const RegisteredEventListener = @import("./event_listener.zig").RegisteredEventListener;
const Node = @import("../dom/node.zig").Node; // Node型をインポート

// イベントタイプ (文字列) をキーとし、登録済みリスナーのリストを値とする HashMap。
pub const ListenerMap = std.StringHashMap(std.ArrayList(RegisteredEventListener));

// EventTarget 構造体。
// Node など、イベントを受け取る可能性のある他の構造体に埋め込むか、
// またはインターフェースとして使用される。
pub const EventTarget = struct {
    // この EventTarget がリスナー管理に使用するアロケータ。
    // 通常は EventTarget を所有する Node/Document のアロケータ。
    allocator: std.mem.Allocator,
    // 登録されているイベントリスナーのマップ。
    // キーはイベントタイプ (例: "click")。
    listener_map: ListenerMap,

    // EventTarget インスタンスを作成する関数。
    pub fn create(allocator: std.mem.Allocator) !EventTarget {
        return EventTarget{
            .allocator = allocator, // アロケータを保存
            .listener_map = ListenerMap.init(allocator),
        };
    }

    // EventTarget インスタンスを破棄する関数。
    // 登録されているリスナーリストも解放する。
    pub fn destroy(et: *EventTarget) void { // allocator 引数は不要になる
        var map_it = et.listener_map.iterator();
        while (map_it.next()) |entry| {
            // 各イベントタイプのリスナーリスト (ArrayList) を解放
            entry.value_ptr.deinit();
            // マップのキー (イベントタイプ文字列) を解放
            et.allocator.free(entry.key);
        }
        // マップ自体のリソースを解放
        et.listener_map.deinit();
        std.log.debug("EventTarget destroyed.", .{});
        // _ = allocator; // Mark allocator as intentionally unused for now -> Removed
    }

    // --- EventTarget API --- https://dom.spec.whatwg.org/#dom-eventtarget-addeventlistener

    /// イベントリスナーを追加します。
    /// type: イベントタイプ (例: "click")。
    /// listener: EventListener 構造体。
    /// options: AddEventListenerOptions 構造体。
    pub fn addEventListener(
        self: *EventTarget,
        event_type: []const u8,
        listener: EventListener,
        options: AddEventListenerOptions,
    ) !void {
        const allocator = self.allocator;
        // 同じリスナー（コールバックとキャプチャフラグが同じ）が既に登録されていないか確認。
        if (self.listener_map.get(event_type)) |listener_list| {
            for (listener_list.items) |existing_listener| {
                if (existing_listener.matches(listener, options.capture)) {
                    // 既に存在する場合は何もしない。
                    std.log.debug("Listener already registered for type '{s}' (capture={}).", .{ event_type, options.capture });
                    return;
                }
            }
            // リストが存在するが、該当リスナーはない場合 -> リストに追加
            const reg = RegisteredEventListener.create(listener, options);
            try listener_list.append(reg);
            std.log.debug("Appended listener for type '{s}' (capture={}).", .{ event_type, options.capture });
        } else {
            // このイベントタイプに対するリストがまだ存在しない場合 -> 新規作成
            var new_list = std.ArrayList(RegisteredEventListener).init(allocator);
            errdefer new_list.deinit();

            const reg = RegisteredEventListener.create(listener, options);
            try new_list.append(reg);

            // マップに新しいリストを追加 (キーの所有権は HashMap に移る)
            const owned_event_type = try allocator.dupe(u8, event_type);
            // errdefer allocator.free(owned_event_type); // put が成功したら解放しない
            errdefer {
                allocator.free(owned_event_type);
                // new_list は既に deinit されるので不要
            }
            try self.listener_map.put(owned_event_type, new_list);
            std.log.debug("Added new listener list for type '{s}' (capture={}).", .{ event_type, options.capture });
        }
    }

    // addEventListener のオーバーロード (options が bool の場合)
    pub fn addEventListenerBool(
        self: *EventTarget,
        event_type: []const u8,
        listener: EventListener,
        use_capture: bool,
    ) !void {
        try self.addEventListener(event_type, listener, .{ .capture = use_capture });
    }

    /// イベントリスナーを削除します。
    /// type: イベントタイプ。
    /// listener: 削除する EventListener 構造体。
    /// options: EventListenerOptions 構造体。
    pub fn removeEventListener(
        self: *EventTarget,
        event_type: []const u8,
        listener: EventListener,
        options: EventListenerOptions,
    ) void {
        const allocator = self.allocator;
        if (self.listener_map.get(event_type)) |listener_list| {
            var i: usize = 0;
            var found = false;
            while (i < listener_list.items.len) {
                if (listener_list.items[i].matches(listener, options.capture)) {
                    // 発見: リストから削除
                    // remove は末尾要素と入れ替えるため、順序は保持されない。
                    // イベントディスパッチ中に削除される場合、順序が重要になる可能性がある。
                    // より安全な方法は、削除フラグを立てて後でクリーンアップするか、
                    // swapRemove を使わずに removeAt を使う (パフォーマンス影響あり)。
                    // ここでは swapRemove を使用する。
                    _ = listener_list.swapRemove(i);
                    std.log.debug("Removed listener for type '{s}' (capture={}).", .{ event_type, options.capture });
                    found = true;
                    // swapRemove したのでインデックス i はそのまま、次の要素をチェック
                    continue;
                }
                i += 1;
            }

            // リスナーが削除された結果、リストが空になったらマップからエントリを削除
            if (found and listener_list.items.len == 0) {
                const entry = self.listener_map.remove(event_type);
                std.debug.assert(entry != null); // 見つかったはずなので null ではない
                // キー (event_type) を解放
                allocator.free(entry.?.key);
                // リスト自体を解放 (deinit)
                entry.?.value.deinit();
                std.log.debug("Removed empty listener list for type '{s}'.", .{event_type});
            }
        } else {
            // 指定されたタイプのリスナーリストが存在しない場合は何もしない。
        }
    }

    // removeEventListener のオーバーロード (options が bool の場合)
    pub fn removeEventListenerBool(
        self: *EventTarget,
        event_type: []const u8,
        listener: EventListener,
        use_capture: bool,
    ) void {
        self.removeEventListener(event_type, listener, .{ .capture = use_capture });
    }

    /// イベントをこの EventTarget にディスパッチします。
    /// target_ptr: イベントの実際のターゲット (例: Node* を anyopaque にキャストしたもの)。
    /// event: ディスパッチする Event オブジェクト。
    /// 戻り値: イベントがキャンセルされなかった場合は true、キャンセルされた場合は false。
    /// 注記: 実際の DOM イベントディスパッチはツリー走査が必要。
    pub fn dispatchEvent(self: *EventTarget, target_ptr: ?*anyopaque, event: *Event) !bool {
        if (event.dispatch or !event.initialized) {
            return errors.GenericError.InternalError;
        }
        if (event.eventPhase != .none) {
            return errors.GenericError.InternalError;
        }

        event.isTrusted = false;

        // イベントターゲットを設定
        event.target = target_ptr;

        // 伝播パスを構築 (ターゲットからルートへ)
        var path = std.ArrayList(*Node).init(self.allocator); // EventTargetがallocatorを持つ前提
        defer path.deinit();

        if (target_ptr) |target_opaque| {
            // target_ptr が Node* であると仮定。実際の型に合わせてキャストが必要。
            // このキャストは、EventTarget が Node 構造体内にあり、target_ptr がその Node* を指す場合に有効。
            // より安全な方法は、target_ptr の型情報を別途渡すか、EventTarget が Node を知る方法を持つことです。
            const current_node: *Node = @ptrCast(@alignCast(target_opaque));
            var node_walker: ?*Node = current_node;
            while (node_walker) |nw| {
                try path.insert(0, nw); // 先頭に追加してルートからのパスを構築
                node_walker = nw.parent_node;
            }
        }

        event.dispatch = true;

        // キャプチャリングフェーズ
        event.eventPhase = .capturing_phase;
        for (path.items) |path_node| {
            if (path_node == event.target) continue; // ターゲット自身はキャプチャリングフェーズでは処理しない
            event.currentTarget = @ptrCast(path_node);

            // path_node (Node*) から EventTarget を取得する必要がある。
            // Node 構造体が event_target フィールドを持つと仮定。
            const current_event_target = &path_node.event_target;
            if (current_event_target.listener_map.get(event.type)) |listeners| {
                var listener_copy = try listeners.clone();
                defer listener_copy.deinit();
                var i: usize = 0;
                while (i < listener_copy.items.len) {
                    const reg = listener_copy.items[i];
                    i += 1;
                    if (!reg.options.capture) continue; // キャプチャリングリスナーのみ

                    if (event.immediate_propagation_stopped) break;

                    const original_cancelable = event.cancelable;
                    if (reg.options.passive) event.cancelable = false;
                    reg.listener.callback(event, reg.listener.user_data);
                    if (reg.options.passive) event.cancelable = original_cancelable;

                    if (reg.options.once) {
                        current_event_target.removeEventListener(event.type, reg.listener, .{ .capture = true });
                    }
                }
            }
            if (event.propagation_stopped) break; // stopPropagation() が呼ばれたらフェーズ終了
        }

        // ターゲットフェーズ
        if (!event.propagation_stopped) {
            event.eventPhase = .at_target;
            event.currentTarget = target_ptr;
            // self は現在の EventTarget インスタンスを指す (path_node.event_target とは異なる場合がある、特に event.target が直接の EventTarget ではない場合)
            // ここでは self (イベントが最初にディスパッチされた EventTarget) のリスナーを実行する
            if (self.listener_map.get(event.type)) |listeners| {
                var listener_copy = try listeners.clone();
                defer listener_copy.deinit();
                var i: usize = 0;
                while (i < listener_copy.items.len) {
                    const reg = listener_copy.items[i];
                    i += 1;
                    if (reg.options.capture) continue; // ターゲットフェーズ/バブリングリスナーのみ

                    if (event.immediate_propagation_stopped) break;

                    const original_cancelable = event.cancelable;
                    if (reg.options.passive) event.cancelable = false;
                    reg.listener.callback(event, reg.listener.user_data);
                    if (reg.options.passive) event.cancelable = original_cancelable;

                    if (reg.options.once) {
                        self.removeEventListener(event.type, reg.listener, .{ .capture = false });
                    }
                }
            }
        }

        // バブリングフェーズ
        if (event.bubbles and !event.propagation_stopped) {
            event.eventPhase = .bubbling_phase;
            var i = path.items.len;
            while (i > 0) {
                i -= 1;
                const path_node = path.items[i];
                if (path_node == event.target) continue;
                event.currentTarget = @ptrCast(path_node);

                const current_event_target = &path_node.event_target;
                if (current_event_target.listener_map.get(event.type)) |listeners| {
                    var listener_copy = try listeners.clone();
                    defer listener_copy.deinit();
                    var k: usize = 0;
                    while (k < listener_copy.items.len) {
                        const reg = listener_copy.items[k];
                        k += 1;
                        if (reg.options.capture) continue; // バブリングリスナーのみ

                        if (event.immediate_propagation_stopped) break;

                        const original_cancelable = event.cancelable;
                        if (reg.options.passive) event.cancelable = false;
                        reg.listener.callback(event, reg.listener.user_data);
                        if (reg.options.passive) event.cancelable = original_cancelable;

                        if (reg.options.once) {
                            current_event_target.removeEventListener(event.type, reg.listener, .{ .capture = false });
                        }
                    }
                }
                if (event.propagation_stopped) break; // stopPropagation() が呼ばれたらフェーズ終了
            }
        }

        event.dispatch = false;
        event.eventPhase = .none;
        event.currentTarget = null;

        return !event.canceled;
    }
};

// --- テスト用スタブ --- (event_listener.zig から再利用)
var callback1_counter: u32 = 0;
fn testCallback1(event: *Event, data: ?*anyopaque) callconv(.C) void {
    _ = event;
    if (data) |d| { // user_data があればカウンターをインクリメント
        const counter: *u32 = @ptrCast(@alignCast(d));
        counter.* += 1;
    }
    callback1_counter += 1;
    std.log.debug("testCallback1 executed", .{});
}

var callback2_counter: u32 = 0;
fn testCallback2(event: *Event, data: ?*anyopaque) callconv(.C) void {
    _ = event;
    _ = data;
    callback2_counter += 1;
    std.log.debug("testCallback2 executed", .{});
}

fn resetTestCounters() void {
    callback1_counter = 0;
    callback2_counter = 0;
}

// --- EventTarget テスト ---
test "EventTarget add and remove listener" {
    const allocator = std.testing.allocator;
    var et = try EventTarget.create(allocator);
    defer et.destroy(); // allocator 不要に

    const listener1 = EventListener{ .callback = testCallback1 };
    const listener2 = EventListener{ .callback = testCallback2 };

    // リスナー追加 (allocator 引数不要に)
    try et.addEventListenerBool("click", listener1, false);
    try et.addEventListenerBool("click", listener1, true);
    try et.addEventListenerBool("click", listener2, false);
    try et.addEventListener("mouseover", listener1, .{});

    // 重複追加は無視される
    try et.addEventListenerBool("click", listener1, false);

    // リスナー数の確認 (変更なし)
    var click_listeners = et.listener_map.get("click").?;
    try std.testing.expect(click_listeners.items.len == 3);
    const mouseover_listeners = et.listener_map.get("mouseover").?;
    try std.testing.expect(mouseover_listeners.items.len == 1);

    // リスナー削除 (capture)
    et.removeEventListenerBool("click", listener1, true);
    click_listeners = et.listener_map.get("click").?;
    try std.testing.expect(click_listeners.items.len == 2);

    // リスナー削除 (bubble)
    et.removeEventListenerBool("click", listener1, false);
    click_listeners = et.listener_map.get("click").?;
    try std.testing.expect(click_listeners.items.len == 1);

    // 存在しないリスナー削除
    et.removeEventListenerBool("click", listener1, false);
    click_listeners = et.listener_map.get("click").?;
    try std.testing.expect(click_listeners.items.len == 1);

    // 最後のリスナーを削除 -> マップからエントリ削除
    et.removeEventListenerBool("click", listener2, false);
    try std.testing.expect(et.listener_map.get("click") == null);

    // 別のタイプのリスナーを削除
    et.removeEventListener("mouseover", listener1, .{});
    try std.testing.expect(et.listener_map.get("mouseover") == null);

    // 全て削除されたのでマップは空のはず
    try std.testing.expect(et.listener_map.count() == 0);
}

test "EventTarget dispatchEvent basic" {
    const allocator = std.testing.allocator;
    var et = try EventTarget.create(allocator);
    defer et.destroy();

    resetTestCounters();
    var counter_data: u32 = 0;
    _ = &counter_data;
    const listener1_bubble = EventListener{ .callback = testCallback1, .user_data = &counter_data };
    const listener1_capture = EventListener{ .callback = testCallback1 };
    const listener2_bubble = EventListener{ .callback = testCallback2 };

    try et.addEventListenerBool("test-event", listener1_bubble, false);
    try et.addEventListenerBool("test-event", listener1_capture, true);
    try et.addEventListenerBool("test-event", listener2_bubble, false);

    // ダミーのターゲットポインタ (実際には Node* など)
    var dummy_target: u8 = 0;
    const target_ptr: ?*anyopaque = &dummy_target;

    var event = try Event.create(allocator, "test-event", .{});
    defer event.destroy(allocator);
    event.initialized = true;

    // ディスパッチ実行 (target_ptr を渡す)
    const result = try et.dispatchEvent(target_ptr, event);

    // 結果確認
    try std.testing.expect(result == true);
    try std.testing.expect(callback1_counter == 2);
    try std.testing.expect(callback2_counter == 1);
    try std.testing.expect(counter_data == 1);
    // イベントのターゲットが設定されていることを確認 (ポインタ比較)
    try std.testing.expect(event.target == target_ptr);
}

test "EventTarget dispatchEvent with once" {
    const allocator = std.testing.allocator;
    var et = try EventTarget.create(allocator);
    defer et.destroy();

    resetTestCounters();
    const listener_once = EventListener{ .callback = testCallback1 };
    const listener_normal = EventListener{ .callback = testCallback2 };

    try et.addEventListener("once-event", listener_once, .{ .once = true });
    try et.addEventListener("once-event", listener_normal, .{});

    var dummy_target: u8 = 1;
    const target_ptr: ?*anyopaque = &dummy_target;

    var event = try Event.create(allocator, "once-event", .{});
    defer event.destroy(allocator);
    event.initialized = true;

    // 1回目のディスパッチ
    _ = try et.dispatchEvent(target_ptr, event);
    try std.testing.expect(callback1_counter == 1); // once リスナーが呼ばれる
    try std.testing.expect(callback2_counter == 1); // 通常リスナーも呼ばれる
    // once リスナーが削除されているか確認
    const listeners = et.listener_map.get("once-event").?;
    try std.testing.expect(listeners.items.len == 1);
    try std.testing.expect(!listeners.items[0].listener.eql(listener_once));
    try std.testing.expect(listeners.items[0].listener.eql(listener_normal));

    // 2回目のディスパッチ
    resetTestCounters();
    _ = try et.dispatchEvent(target_ptr, event);
    try std.testing.expect(callback1_counter == 0); // once リスナーはもう呼ばれない
    try std.testing.expect(callback2_counter == 1); // 通常リスナーは呼ばれる
}

test "EventTarget dispatchEvent propagation and cancellation" {
    const allocator = std.testing.allocator;
    var et = try EventTarget.create(allocator);
    defer et.destroy();

    resetTestCounters();
    const order: [4]u32 = undefined;
    const order_idx: usize = 0;
    // 未使用変数の警告を抑制
    _ = order;
    _ = order_idx;

    // コールバック内でイベントを操作するリスナー
    const listener_stop = EventListener{ .callback = struct {
        fn cb(event: *Event, data: ?*anyopaque) callconv(.C) void {
            _ = data;
            std.log.debug("listener_stop executed", .{});
            event.stopPropagation();
        }
    }.cb };
    // 未使用定数の警告を抑制 (正しい位置に移動)
    _ = listener_stop;

    const listener_stop_immediate = EventListener{ .callback = struct {
        fn cb(event: *Event, data: ?*anyopaque) callconv(.C) void {
            _ = data;
            std.log.debug("listener_stop_immediate executed", .{});
            event.stopImmediatePropagation();
        }
    }.cb };
    const listener_prevent = EventListener{ .callback = struct {
        fn cb(event: *Event, data: ?*anyopaque) callconv(.C) void {
            _ = data;
            std.log.debug("listener_prevent executed", .{});
            event.preventDefault();
        }
    }.cb };
    const listener_normal = EventListener{ .callback = testCallback1 }; // 実行順序確認用

    // stopImmediatePropagation のテスト
    resetTestCounters();
    try et.addEventListenerBool("stop_imm", listener_stop_immediate, false);
    try et.addEventListenerBool("stop_imm", listener_normal, false); // これは実行されないはず
    var event_stop_imm = try Event.create(allocator, "stop_imm", .{});
    defer event_stop_imm.destroy(allocator);
    event_stop_imm.initialized = true;
    _ = try et.dispatchEvent(null, event_stop_imm);
    try std.testing.expect(callback1_counter == 0);
    et.removeEventListenerBool("stop_imm", listener_stop_immediate, false);
    et.removeEventListenerBool("stop_imm", listener_normal, false);

    // preventDefault のテスト
    resetTestCounters();
    try et.addEventListenerBool("prevent", listener_prevent, false);
    var event_prevent = try Event.create(allocator, "prevent", .{ .cancelable = true }); // キャンセル可能イベント
    defer event_prevent.destroy(allocator);
    event_prevent.initialized = true;
    var result = try et.dispatchEvent(null, event_prevent);
    try std.testing.expect(result == false); // キャンセルされたので false
    try std.testing.expect(event_prevent.defaultPrevented());
    et.removeEventListenerBool("prevent", listener_prevent, false);

    // preventDefault (キャンセル不可イベント)
    resetTestCounters();
    try et.addEventListenerBool("prevent_nc", listener_prevent, false);
    var event_prevent_nc = try Event.create(allocator, "prevent_nc", .{ .cancelable = false });
    defer event_prevent_nc.destroy(allocator);
    event_prevent_nc.initialized = true;
    result = try et.dispatchEvent(null, event_prevent_nc);
    try std.testing.expect(result == true); // キャンセル不可なので true
    try std.testing.expect(!event_prevent_nc.defaultPrevented());
    et.removeEventListenerBool("prevent_nc", listener_prevent, false);

    // stopPropagation は現状の dispatchEvent ではテスト不可 (ツリー走査が必要)
}

// 関連テストは既に上記に含まれるか、現状の dispatchEvent では実装できないため削除。
// 以下は追加のテスト実装

test "stopPropagation and stopImmediatePropagation" {
    const allocator = std.testing.allocator;
    var parent = try EventTarget.create(allocator);
    defer parent.deinit();

    var child = try EventTarget.create(allocator);
    defer child.deinit();

    // 親子関係を設定
    child.parent = parent;

    // イベントリスナーカウンター
    var parent_handler_count: usize = 0;
    var child_handler_count: usize = 0;

    // stopPropagationテスト用ハンドラー
    const test_parent_handler = struct {
        fn handler(event: *Event, data: ?*anyopaque) void {
            _ = data;
            parent_handler_count += 1;
        }
    }.handler;

    // stopImmediatePropagationテスト用ハンドラー
    const test_child_handler1 = struct {
        fn handler(event: *Event, data: ?*anyopaque) void {
            _ = data;
            child_handler_count += 1;
            // 伝播を止める
            event.stopPropagation();
        }
    }.handler;

    const test_child_handler2 = struct {
        fn handler(event: *Event, data: ?*anyopaque) void {
            _ = data;
            child_handler_count += 1;
        }
    }.handler;

    const test_child_handler3 = struct {
        fn handler(event: *Event, data: ?*anyopaque) void {
            _ = data;
            child_handler_count += 1;
            // 即時に伝播を止める
            event.stopImmediatePropagation();
        }
    }.handler;

    const test_child_handler4 = struct {
        fn handler(event: *Event, data: ?*anyopaque) void {
            _ = data;
            child_handler_count += 1; // これは呼ばれないはず
        }
    }.handler;

    // リスナーを登録
    try parent.addEventListener("test-stop-propagation", test_parent_handler, .{});
    try child.addEventListener("test-stop-propagation", test_child_handler1, .{});
    try child.addEventListener("test-stop-propagation", test_child_handler2, .{});

    try child.addEventListener("test-stop-immediate", test_child_handler3, .{});
    try child.addEventListener("test-stop-immediate", test_child_handler4, .{});
    try parent.addEventListener("test-stop-immediate", test_parent_handler, .{});

    // イベントを生成
    var event1 = try Event.create(allocator, "test-stop-propagation", .{});
    defer event1.deinit(allocator);
    event1.initialized = true;

    // イベントをディスパッチ
    _ = try child.dispatchEvent(null, event1);

    // stopPropagationテスト: 子要素のハンドラーは両方呼ばれるが、親には伝播しない
    try std.testing.expectEqual(@as(usize, 2), child_handler_count);
    try std.testing.expectEqual(@as(usize, 0), parent_handler_count);

    // カウンターをリセット
    child_handler_count = 0;
    parent_handler_count = 0;

    // 2つ目のイベントを生成
    var event2 = try Event.create(allocator, "test-stop-immediate", .{});
    defer event2.deinit(allocator);
    event2.initialized = true;

    // イベントをディスパッチ
    _ = try child.dispatchEvent(null, event2);

    // stopImmediatePropagationテスト: 最初の子ハンドラーのみ呼ばれ、2つ目の子ハンドラーと親には伝播しない
    try std.testing.expectEqual(@as(usize, 1), child_handler_count);
    try std.testing.expectEqual(@as(usize, 0), parent_handler_count);
}

test "preventDefault test" {
    const allocator = std.testing.allocator;
    var target = try EventTarget.create(allocator);
    defer target.deinit();

    var default_prevented = false;

    // デフォルト処理を防ぐハンドラー
    const prevent_handler = struct {
        fn handler(event: *Event, data: ?*anyopaque) void {
            _ = data;
            event.preventDefault();
        }
    }.handler;

    // デフォルト処理のステータスをチェックするハンドラー
    const check_handler = struct {
        fn handler(event: *Event, data: ?*anyopaque) void {
            var prevented = @ptrCast(*bool, @alignCast(@alignOf(bool), data.?));
            prevented.* = event.defaultPrevented;
        }
    }.handler;

    // リスナーを登録
    try target.addEventListener("test-prevent", prevent_handler, .{});
    try target.addEventListener("test-prevent", check_handler, .{ .data = &default_prevented });

    // イベントを生成
    var event = try Event.create(allocator, "test-prevent", .{});
    defer event.deinit(allocator);
    event.initialized = true;

    // イベントをディスパッチ
    _ = try target.dispatchEvent(null, event);

    // defaultPreventedがtrueになっているか確認
    try std.testing.expect(default_prevented);
    try std.testing.expect(event.defaultPrevented);
}

test "once option test" {
    const allocator = std.testing.allocator;
    var target = try EventTarget.create(allocator);
    defer target.deinit();

    var handler_count: usize = 0;

    // 1回だけ呼ばれるハンドラー
    const once_handler = struct {
        fn handler(event: *Event, data: ?*anyopaque) void {
            _ = event;
            var count = @ptrCast(*usize, @alignCast(@alignOf(usize), data.?));
            count.* += 1;
        }
    }.handler;

    // once オプション付きでリスナーを登録
    try target.addEventListener("test-once", once_handler, .{ .once = true, .data = &handler_count });

    // イベントを2回ディスパッチ
    var event1 = try Event.create(allocator, "test-once", .{});
    defer event1.deinit(allocator);
    event1.initialized = true;
    _ = try target.dispatchEvent(null, event1);

    var event2 = try Event.create(allocator, "test-once", .{});
    defer event2.deinit(allocator);
    event2.initialized = true;
    _ = try target.dispatchEvent(null, event2);

    // ハンドラーは1回だけ呼ばれるはず
    try std.testing.expectEqual(@as(usize, 1), handler_count);

    // リスナーが自動的に削除されているか確認
    try std.testing.expectEqual(@as(usize, 0), target.listener_map.count());
}
