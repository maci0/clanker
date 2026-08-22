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
    _ = @import("records_api_test.zig");
    _ = @import("live_sse_test.zig");
    _ = @import("webui_assets_test.zig");
    _ = @import("commit_apply_test.zig");
    _ = @import("fallback_graph_test.zig");
    _ = @import("run_stream_llm_start_test.zig");
    _ = @import("steer_nonstreaming_test.zig");
    _ = @import("improve_fallback_test.zig");
    _ = @import("pty_resize_test.zig");
    _ = @import("pty.zig");
    _ = @import("pty_preview_test.zig");
}
