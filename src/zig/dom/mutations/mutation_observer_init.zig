// src/zig/dom/mutations/mutation_observer_init.zig
// MutationObserverInit ディクショナリ
// https://dom.spec.whatwg.org/#dictdef-mutationobserverinit

const std = @import("std");

pub const MutationObserverInit = struct {
    childList: bool = false,
    attributes: bool = false,
    characterData: bool = false,
    subtree: bool = false,
    attributeOldValue: bool = false,
    characterDataOldValue: bool = false,
    attributeFilter: ?[]const []const u8 = null, // Array of attribute names

    // 文字列配列 attributeFilter の所有権管理のため、
    // create/destroy を用意するか、呼び出し元が管理する。
    // ここでは呼び出し元管理とする。
};

// テスト
test "MutationObserverInit defaults" {
    const init = MutationObserverInit{};
    try std.testing.expect(init.childList == false);
    try std.testing.expect(init.attributes == false);
    try std.testing.expect(init.characterData == false);
    try std.testing.expect(init.subtree == false);
    try std.testing.expect(init.attributeOldValue == false);
    try std.testing.expect(init.characterDataOldValue == false);
    try std.testing.expect(init.attributeFilter == null);
} 