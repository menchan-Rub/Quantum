const std = @import("std");
const html = @import("html/html.zig");
const css = @import("css/css.zig");
const layout = @import("layout/layout.zig");
const render = @import("render/render.zig");

pub fn main() !void {
    std.debug.print("QuantumCore レンダリングエンジンを初期化中...\n", .{});
    
    // メモリアロケータの初期化
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // HTMLパーサーの初期化
    var html_parser = try html.Parser.init(allocator);
    defer html_parser.deinit();
    
    // レンダリングエンジンの初期化
    var renderer = try render.Renderer.init(allocator);
    defer renderer.deinit();
    
    std.debug.print("QuantumCore レンダリングエンジンの初期化が完了しました\n", .{});
}

// Crystal・Nim言語との連携用エクスポート関数
pub export fn parseHtml(html_content: [*:0]const u8, len: usize) callconv(.C) ?*html.Document {
    const allocator = std.heap.c_allocator;
    var parser = html.Parser.init(allocator) catch return null;
    defer parser.deinit();
    
    const html_str = html_content[0..len];
    var document = parser.parse(html_str) catch return null;
    
    return document;
}

pub export fn renderDocument(doc: ?*html.Document, width: u32, height: u32) callconv(.C) void {
    if (doc) |document| {
        const allocator = std.heap.c_allocator;
        var renderer = render.Renderer.init(allocator) catch return;
        defer renderer.deinit();
        
        renderer.renderDocument(document, width, height) catch {};
    }
}

pub export fn cleanupDocument(doc: ?*html.Document) callconv(.C) void {
    if (doc) |document| {
        document.deinit();
    }
} 