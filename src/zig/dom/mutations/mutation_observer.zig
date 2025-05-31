// src/zig/dom/mutations/mutation_observer.zig
// MutationObserver インターフェース
// https://dom.spec.whatwg.org/#interface-mutationobserver

const std = @import("std");
const dom = @import("../elements/node.zig");
const NodeType = @import("../elements/node_types.zig").NodeType;

/// MutationObserver インターフェースは、DOM ツリーに加えられた変更を監視するための機能を提供します。
/// 設計は Web の MutationObserver API に基づいています。
pub const MutationObserver = struct {
    /// オブザーバーで一意の ID
    id: u32,

    /// コールバック関数
    callback: MutationCallback,

    /// 観察対象のノード
    targets: std.ArrayList(*dom.Node),

    /// 変異レコードのキュー
    records: std.ArrayList(MutationRecord),

    /// オブザーバーが処理中かどうか
    processing: bool = false,

    /// アロケータ
    allocator: std.mem.Allocator,

    /// 監視中のターゲットとそのオプション
    observed_targets: std.ArrayList(TargetInfo),

    /// コールバック関数の型定義
    pub const MutationCallback = *const fn (records: []MutationRecord, observer: *MutationObserver) void;

    /// 変異レコードの型
    pub const MutationRecord = struct {
        /// 変異の種類
        type: MutationType,

        /// 変異が発生したノード
        target: *dom.Node,

        /// 追加されたノード
        addedNodes: ?std.ArrayList(*dom.Node) = null,

        /// 削除されたノード
        removedNodes: ?std.ArrayList(*dom.Node) = null,

        /// 前のシブリングノード
        previousSibling: ?*dom.Node = null,

        /// 次のシブリングノード
        nextSibling: ?*dom.Node = null,

        /// 変更された属性の名前（attributes 変異の場合）
        attributeName: ?[]const u8 = null,

        /// 変更された属性の名前空間（attributes 変異の場合）
        attributeNamespace: ?[]const u8 = null,

        /// 変更前の値
        oldValue: ?[]const u8 = null,
    };

    /// 変異の種類
    pub const MutationType = enum {
        attributes,
        characterData,
        childList,
    };

    /// 観測オプション
    pub const MutationObserverInit = struct {
        childList: bool = false,
        attributes: bool = false,
        characterData: bool = false,
        subtree: bool = false,
        attributeOldValue: bool = false,
        characterDataOldValue: bool = false,
        attributeFilter: ?[][]const u8 = null,
    };

    /// ターゲットとオプションのペア
    const TargetInfo = struct {
        target: *dom.Node,
        options: MutationObserverInit,
    };

    /// グローバルリスト（DOM全体でアクティブなオブザーバー）
    var active_observers = std.ArrayList(*MutationObserver).init(std.heap.page_allocator);
    var next_observer_id: u32 = 1;

    /// 静的初期化
    pub fn initialize() !void {
        active_observers = std.ArrayList(*MutationObserver).init(std.heap.page_allocator);
    }

    /// 静的クリーンアップ
    pub fn deinitialize() void {
        active_observers.deinit();
    }

    /// 新しい MutationObserver を作成します。
    pub fn init(allocator: std.mem.Allocator, callback: MutationCallback) !*MutationObserver {
        var observer = try allocator.create(MutationObserver);
        observer.* = MutationObserver{
            .id = next_observer_id,
            .callback = callback,
            .targets = std.ArrayList(*dom.Node).init(allocator),
            .records = std.ArrayList(MutationRecord).init(allocator),
            .allocator = allocator,
            .observed_targets = std.ArrayList(TargetInfo).init(allocator),
        };

        next_observer_id += 1;
        try active_observers.append(observer);

        return observer;
    }

    /// MutationObserver を破棄します。
    pub fn deinit(self: *MutationObserver) void {
        // 監視を停止
        self.disconnect();

        // 各変異レコードのメモリを解放
        for (self.records.items) |*record| {
            if (record.addedNodes) |*nodes| {
                nodes.deinit();
            }
            if (record.removedNodes) |*nodes| {
                nodes.deinit();
            }
        }

        // アクティブなオブザーバーのリストから削除
        for (active_observers.items, 0..) |observer, i| {
            if (observer.id == self.id) {
                _ = active_observers.orderedRemove(i);
                break;
            }
        }

        // データ構造を解放
        self.targets.deinit();
        self.records.deinit();
        self.observed_targets.deinit();

        // 自身を解放
        self.allocator.destroy(self);
    }

    /// 指定されたターゲット要素の変更を監視します。
    pub fn observe(self: *MutationObserver, target: *dom.Node, options: MutationObserverInit) !void {
        // すでに観察されているかチェック
        for (self.observed_targets.items) |target_info| {
            if (target_info.target == target) {
                // すでに観察されている場合は設定を更新
                try self.observed_targets.append(TargetInfo{
                    .target = target,
                    .options = options,
                });
                return;
            }
        }

        // 新しいターゲットとして追加
        try self.observed_targets.append(TargetInfo{
            .target = target,
            .options = options,
        });

        // ターゲットリストにも追加
        try self.targets.append(target);
    }

    /// 監視を停止します。
    pub fn disconnect(self: *MutationObserver) void {
        self.targets.clearRetainingCapacity();
        self.observed_targets.clearRetainingCapacity();
    }

    /// 監視されている変更に関する変異レコードを返し、キューをクリアします。
    pub fn takeRecords(self: *MutationObserver) []MutationRecord {
        var records = self.records.toOwnedSlice();
        return records;
    }

    /// 変異レコードをキューに追加します（内部メソッド）
    fn queueRecord(self: *MutationObserver, record: MutationRecord) !void {
        try self.records.append(record);
    }

    /// 変異が発生したことを通知（内部メソッド）
    fn notifyMutation(target: *dom.Node, mutation_type: MutationType, data: anytype) !void {
        // アクティブなすべてのオブザーバーに通知
        for (active_observers.items) |observer| {
            // このターゲットまたはその祖先を監視しているかチェック
            var relevant_observer = false;
            var relevant_options: ?MutationObserverInit = null;

            for (observer.observed_targets.items) |target_info| {
                if (target_info.target == target) {
                    // 直接のターゲット
                    relevant_observer = true;
                    relevant_options = target_info.options;
                    break;
                } else if (target_info.options.subtree) {
                    // サブツリーを監視しているなら、ターゲットがこの監視対象の子孫かチェック
                    var current = target;
                    while (current.parentNode) |parent| {
                        if (parent == target_info.target) {
                            relevant_observer = true;
                            relevant_options = target_info.options;
                            break;
                        }
                        current = parent;
                    }

                    if (relevant_observer) {
                        break;
                    }
                }
            }

            if (!relevant_observer or relevant_options == null) {
                continue;
            }

            const options = relevant_options.?;

            // 変異タイプに応じたフィルタリング
            switch (mutation_type) {
                .attributes => {
                    if (!options.attributes) {
                        continue;
                    }

                    // 属性フィルターがある場合は属性名をチェック
                    if (options.attributeFilter) |filter| {
                        if (data.attributeName) |attr_name| {
                            var found = false;
                            for (filter) |filtered_name| {
                                if (std.mem.eql(u8, filtered_name, attr_name)) {
                                    found = true;
                                    break;
                                }
                            }

                            if (!found) {
                                continue;
                            }
                        }
                    }
                },
                .characterData => {
                    if (!options.characterData) {
                        continue;
                    }
                },
                .childList => {
                    if (!options.childList) {
                        continue;
                    }
                },
            }

            // 変異レコードを作成
            var record = MutationRecord{
                .type = mutation_type,
                .target = target,
                .previousSibling = null,
                .nextSibling = null,
                .addedNodes = null,
                .removedNodes = null,
                .attributeName = null,
                .attributeNamespace = null,
                .oldValue = null,
            };

            // 変異タイプに応じたデータを設定
            switch (mutation_type) {
                .attributes => {
                    record.attributeName = if (data.attributeName) |name| try observer.allocator.dupe(u8, name) else null;
                    record.attributeNamespace = if (data.attributeNamespace) |ns| try observer.allocator.dupe(u8, ns) else null;

                    if (options.attributeOldValue and data.oldValue != null) {
                        record.oldValue = try observer.allocator.dupe(u8, data.oldValue.?);
                    }
                },
                .characterData => {
                    if (options.characterDataOldValue and data.oldValue != null) {
                        record.oldValue = try observer.allocator.dupe(u8, data.oldValue.?);
                    }
                },
                .childList => {
                    if (data.addedNodes) |nodes| {
                        var added_nodes = std.ArrayList(*dom.Node).init(observer.allocator);
                        for (nodes) |node| {
                            try added_nodes.append(node);
                        }
                        record.addedNodes = added_nodes;
                    }

                    if (data.removedNodes) |nodes| {
                        var removed_nodes = std.ArrayList(*dom.Node).init(observer.allocator);
                        for (nodes) |node| {
                            try removed_nodes.append(node);
                        }
                        record.removedNodes = removed_nodes;
                    }

                    record.previousSibling = data.previousSibling;
                    record.nextSibling = data.nextSibling;
                },
            }

            // 変異レコードをキューに追加
            try observer.queueRecord(record);

            // コールバックを呼び出し待ちとしてマーク
            try scheduleMicrotask(observer);
        }
    }
};

/// マイクロタスクをスケジュールするためのグローバルキュー
var microtask_queue = std.ArrayList(*MutationObserver).init(std.heap.page_allocator);
var is_dispatching = false;

/// マイクロタスクキューを初期化
pub fn initializeMicrotaskQueue() !void {
    microtask_queue = std.ArrayList(*MutationObserver).init(std.heap.page_allocator);
}

/// マイクロタスクキューを解放
pub fn deinitializeMicrotaskQueue() void {
    microtask_queue.deinit();
}

/// マイクロタスクをスケジュールする（内部関数）
fn scheduleMicrotask(observer: *MutationObserver) !void {
    // すでにキューに入っているかチェック
    for (microtask_queue.items) |queued| {
        if (queued.id == observer.id) {
            return;
        }
    }

    try microtask_queue.append(observer);

    // まだディスパッチしていなければ開始
    if (!is_dispatching) {
        try dispatchMicrotasks();
    }
}

/// マイクロタスクキューを実行する
fn dispatchMicrotasks() !void {
    if (is_dispatching) {
        return;
    }

    is_dispatching = true;
    defer is_dispatching = false;

    while (microtask_queue.items.len > 0) {
        var observer = microtask_queue.orderedRemove(0);

        if (observer.records.items.len > 0) {
            var records = observer.takeRecords();
            defer observer.allocator.free(records);

            observer.callback(records, observer);
        }
    }
}

/// 属性変更通知用のデータ構造
pub const AttributeChangeData = struct {
    attributeName: []const u8,
    attributeNamespace: ?[]const u8 = null,
    oldValue: ?[]const u8 = null,
};

/// テキスト変更通知用のデータ構造
pub const CharacterDataChangeData = struct {
    oldValue: ?[]const u8 = null,
};

/// 子要素変更通知用のデータ構造
pub const ChildListChangeData = struct {
    addedNodes: ?[]*dom.Node = null,
    removedNodes: ?[]*dom.Node = null,
    previousSibling: ?*dom.Node = null,
    nextSibling: ?*dom.Node = null,
};

/// 属性変更通知 (DOM実装から呼び出される)
pub fn notifyAttributeChanged(target: *dom.Node, name: []const u8, namespace: ?[]const u8, old_value: ?[]const u8) !void {
    const data = AttributeChangeData{
        .attributeName = name,
        .attributeNamespace = namespace,
        .oldValue = old_value,
    };

    try MutationObserver.notifyMutation(target, .attributes, data);
}

/// テキスト変更通知 (DOM実装から呼び出される)
pub fn notifyCharacterDataChanged(target: *dom.Node, old_value: ?[]const u8) !void {
    const data = CharacterDataChangeData{
        .oldValue = old_value,
    };

    try MutationObserver.notifyMutation(target, .characterData, data);
}

/// 子要素変更通知 (DOM実装から呼び出される)
pub fn notifyChildListChanged(target: *dom.Node, added_nodes: ?[]*dom.Node, removed_nodes: ?[]*dom.Node, previous_sibling: ?*dom.Node, next_sibling: ?*dom.Node) !void {
    const data = ChildListChangeData{
        .addedNodes = added_nodes,
        .removedNodes = removed_nodes,
        .previousSibling = previous_sibling,
        .nextSibling = next_sibling,
    };

    try MutationObserver.notifyMutation(target, .childList, data);
}
