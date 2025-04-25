// src/zig/dom/cssselector.zig
// CSS セレクタパーサ／マッチャーのスタブ実装

const std = @import("std");
const Element = @import("./element.zig").Element;

pub const SelectorList = struct {
    pub fn deinit(self: *SelectorList) void {
        _ = self;
    }
    pub fn matches(self: *SelectorList, element: *Element) bool {
        _ = self;
        _ = element;
        // 仮実装: 全要素にマッチ
        return true;
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    selector: []const u8,
    pub fn init(allocator: std.mem.Allocator, selector: []const u8) !*Parser {
        var p = try allocator.create(Parser);
        p.allocator = allocator;
        p.selector = selector;
        return p;
    }
    pub fn deinit(self: *Parser) void {
        self.allocator.destroy(self);
    }
    pub fn parse(self: *Parser) !SelectorList {
        _ = self;
        return SelectorList{};
    }
}; 