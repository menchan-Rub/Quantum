// src/zig/dom/mutations/mutation_observer.zig
// MutationObserver インターフェース
// https://dom.spec.whatwg.org/#interface-mutationobserver

const std = @import("std");
const Node = @import("../node.zig").Node;
const MutationRecord = @import("./mutation_record.zig").MutationRecord;
const MutationObserverInit = @import("./mutation_observer_init.zig").MutationObserverInit;
const errors = @import("../../util/error.zig");

// コールバック関数の型
pub const MutationCallback = fn (records: []*MutationRecord, observer: *MutationObserver) callconv(.C) void;

// 監視対象ノードとオプションを保持する内部構造体
const ObservationTarget = struct {
    target: *Node,
    options: MutationObserverInit,
    // TODO: predecessor observers などの情報 (transient observations)
};

pub const MutationObserver = struct {
    callback: MutationCallback,
    // 監視対象のリスト (Node* をキーとするマップ or リスト)
    // ここでは単純なリストを使用。observe/disconnect で線形探索。
    // パフォーマンスが重要な場合は HashMap<*Node, ObservationTarget> を検討。
    targets: std.ArrayList(ObservationTarget),
    // 配信待ちの MutationRecord のキュー
    recordQueue: std.ArrayList(*MutationRecord),
    allocator: std.mem.Allocator,

    // MutationObserver を作成
    pub fn create(allocator: std.mem.Allocator, callback_fn: MutationCallback) !*MutationObserver {
        const observer = try allocator.create(MutationObserver);
        errdefer allocator.destroy(observer);

        observer.* = MutationObserver{
            .allocator = allocator,
            .callback = callback_fn,
            .targets = std.ArrayList(ObservationTarget).init(allocator),
            .recordQueue = std.ArrayList(*MutationRecord).init(allocator),
        };
        return observer;
    }

    // 監視を開始またはオプションを更新
    pub fn observe(self: *MutationObserver, target_node: *Node, options: MutationObserverInit) !void {
        // Options の検証 (DOM Spec 4.2.1)
        if (!options.childList and !options.attributes and !options.characterData) {
             std.log.err("MutationObserverInit: At least one of childList, attributes, or characterData must be true.", .{});
             return error.TypeError; // 仕様では TypeError
        }
        if ((options.attributeOldValue or options.attributeFilter != null) and !options.attributes) {
             std.log.err("MutationObserverInit: attributeOldValue/attributeFilter requires attributes to be true.", .{});
             return error.TypeError;
        }
        if (options.characterDataOldValue and !options.characterData) {
             std.log.err("MutationObserverInit: characterDataOldValue requires characterData to be true.", .{});
             return error.TypeError;
        }

        // 既存のターゲットを探す
        for (self.targets.items) |*item| {
            if (item.target == target_node) {
                // 既存ターゲットが見つかったらオプションを上書き
                // TODO: attributeFilter のメモリ管理 (古いフィルタを解放、新しいフィルタをコピー)
                item.options = options;
                std.log.debug("MutationObserver: Updated options for existing target node.", .{});
                return;
            }
        }

        // 新しいターゲットを追加
        // TODO: attributeFilter のコピー
        const new_target = ObservationTarget{
            .target = target_node,
            .options = options,
        };
        try self.targets.append(new_target);
        std.log.debug("MutationObserver: Started observing new target node.", .{});
    }

    // 監視を停止
    pub fn disconnect(self: *MutationObserver) void {
        // TODO: 監視ターゲットリストに関連するリソース (attributeFilter など) があれば解放
        self.targets.clearRetainingCapacity(); // リストをクリア
        // キュー内のレコードは破棄しない (takeRecords で取得可能)
        std.log.debug("MutationObserver: Disconnected.", .{});
    }

    // キュー内のレコードを取得し、キューを空にする
    pub fn takeRecords(self: *MutationObserver) ![]*MutationRecord {
        if (self.recordQueue.items.len == 0) {
            return &[_]*MutationRecord{}; // 空のスライスを返す
        }
        // 所有権を呼び出し元に移すスライスを作成
        const records_slice = try self.recordQueue.toOwnedSlice(); 
        // キューをリセット (ArrayList は内部バッファを保持する可能性がある)
        self.recordQueue.clearRetainingCapacity();
        // self.recordQueue = std.ArrayList(*MutationRecord).init(self.allocator); // or re-initialize
        return records_slice;
    }

    // MutationObserver と関連リソースを破棄
    pub fn destroy(self: *MutationObserver) void {
        std.log.debug("Destroying MutationObserver...", .{});
        // キュー内のレコードを破棄
        for (self.recordQueue.items) |record| {
            record.destroy();
        }
        self.recordQueue.deinit();

        // 監視ターゲットリストを破棄
        // TODO: ObservationTarget 内のリソース (attributeFilter) を解放
        self.targets.deinit();

        // オブザーバー自体を破棄
        self.allocator.destroy(self);
    }

    // --- 内部メソッド (キューイング用) ---
    // DOM 操作から呼び出される想定
    pub fn queueRecord(self: *MutationObserver, record: *MutationRecord) !void {
        var interested = false;
        // このオブザーバーが監視しているターゲットの中に、
        // このレコードに関心を持つものがあるかチェック。
        search_targets: for (self.targets.items) |item| {
            const target_node = item.target;
            const options = item.options;

            // レコードのターゲットが監視対象ノード、またはその子孫 (subtree=true の場合) かどうか
            var target_match = (record.target == target_node);
            if (!target_match and options.subtree and record.target.isDescendantOf(target_node)) {
                target_match = true;
            }
            if (!target_match) continue :search_targets; // 関係ないターゲットのレコードは無視

            // レコードタイプに応じたオプションチェック
            switch (record.type) {
                .attributes => {
                    if (!options.attributes) continue :search_targets;
                    // oldValue が要求されているが記録されていない場合は無視
                    if (options.attributeOldValue and record.oldValue == null) continue :search_targets;
                    // attributeFilter のチェック (未実装)
                    // if (options.attributeFilter) |filter| { ... }
                },
                .characterData => {
                    if (!options.characterData) continue :search_targets;
                    // oldValue が要求されているが記録されていない場合は無視
                    if (options.characterDataOldValue and record.oldValue == null) continue :search_targets;
                },
                .childList => {
                    if (!options.childList) continue :search_targets;
                },
            }

            // ここまで到達すれば、このオブザーバーはこのレコードに関心がある
            interested = true;
            break :search_targets;
        }

        // 関心のあるオブザーバーが見つかった場合のみキューに追加
        if (interested) {
            try self.recordQueue.append(record);
        }
    }

    // TODO: 通知メカニズム (マイクロタスク)
    // pub fn scheduleNotification(self: *MutationObserver) void;
};

// --- テスト用 --- 
var records_delivered: [*]MutationRecord = undefined; 
var delivered_count: usize = 0;

fn testMutationCallback(records: []*MutationRecord, observer: *MutationObserver) callconv(.C) void {
    _ = observer;
    std.log.debug("MutationCallback invoked with {d} records", .{records.len});
    // グローバル変数に保存してテストからアクセス (実際には良くない)
    records_delivered = records.ptr;
    delivered_count = records.len;
}

// テスト
test "MutationObserver creation and basic methods" {
    const allocator = std.testing.allocator;
    var observer = try MutationObserver.create(allocator, testMutationCallback);
    defer observer.destroy();

    var dummy_doc_node = try Node.create(allocator, .document_node, null, null);
    defer dummy_doc_node.destroy(allocator);
    var target_node = try Node.create(allocator, .element_node, dummy_doc_node, null);
    defer target_node.destroy(allocator);

    // observe
    const options = MutationObserverInit{ .childList = true, .attributes = true };
    try observer.observe(target_node, options);
    try std.testing.expect(observer.targets.items.len == 1);
    try std.testing.expect(observer.targets.items[0].target == target_node);
    try std.testing.expect(observer.targets.items[0].options.childList == true);

    // observe (update)
    const options_update = MutationObserverInit{ .attributes = true, .attributeOldValue = true };
    try observer.observe(target_node, options_update);
    try std.testing.expect(observer.targets.items.len == 1); // Count doesn't change
    try std.testing.expect(observer.targets.items[0].options.childList == false); // Updated
    try std.testing.expect(observer.targets.items[0].options.attributeOldValue == true); // Updated

    // takeRecords (empty)
    var records = try observer.takeRecords();
    try std.testing.expect(records.len == 0);

    // queueRecord (manually for test)
    var record1 = try MutationRecord.create(allocator, .childList, target_node);
    defer record1.destroy(); // destroy は takeRecords 後に行うべきだが、テストのため defer
    var record2 = try MutationRecord.create(allocator, .attributes, target_node);
    defer record2.destroy();
    try observer.queueRecord(record1);
    try observer.queueRecord(record2);
    try std.testing.expect(observer.recordQueue.items.len == 2);

    // takeRecords (with records)
    records = try observer.takeRecords();
    try std.testing.expect(records.len == 2);
    try std.testing.expect(observer.recordQueue.items.len == 0); // Queue is cleared
    try std.testing.expect(records[0] == record1);
    try std.testing.expect(records[1] == record2);
    // takeRecords は所有権を移すので、呼び出し元が解放する
    allocator.free(records);

    // disconnect
    observer.disconnect();
    try std.testing.expect(observer.targets.items.len == 0);
}

// TODO: Test observation filtering (subtree, attributes, characterData, filters)
// TODO: Test callback invocation (requires microtask simulation or manual trigger) 