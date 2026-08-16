//! Root file for `zig build e2e`. Zig 0.16 only runs test blocks in the root
//! file of a test binary, so every file with tests must be referenced here —
//! same rule src/main.zig follows for `zig build test`.

comptime {
    _ = @import("mock_llm.zig");
    _ = @import("harness.zig");
    _ = @import("tool_roundtrip_test.zig");
    _ = @import("hooks_test.zig");
    _ = @import("mesh_test.zig");
    _ = @import("journeys_test.zig");
}
