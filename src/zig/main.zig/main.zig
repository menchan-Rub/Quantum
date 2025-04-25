// src/zig/main.zig/main.zig
// Zig 共有ライブラリのエントリーポイント (または主要モジュール)。
// build.zig で root_source_file として指定されています。

const std = @import("std");

// bindings モジュールを定義して、FFI 関数をカプセル化します。
pub const bindings = @import("../bindings/ffi.zig");

// bindings 内の公開シンボルをこのファイルのトップレベルスコープに持ち込みます。
// これにより、quantum_zig_initialize などが直接呼び出せるようになります (FFI用)。
pub usingnamespace bindings;

// 必要に応じて、ライブラリ内部で使用する他のモジュールもここでインポートします。
// const engine = @import("../engine/core.zig");
// const dom = @import("../dom/node.zig");
// ... など

// ライブラリがロードされたときなどに初期化処理が必要な場合は、
// init 関数や他のメカニズムを使用できますが、FFI 経由での明示的な
// 初期化呼び出し (quantum_zig_initialize) が一般的です。

// このファイル自体に他のロジックを追加することも可能です。
// 例えば、Zig 内部向けの API やテストなど。

test "simple test" {
    // 簡単なテスト (例)
    // テストブロック内からは、モジュール名を付けてアクセスします。
    std.testing.expect(bindings.quantum_zig_add(2, 3) == 5);
} 