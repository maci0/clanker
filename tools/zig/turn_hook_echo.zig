//! turn_hook_echo: demo `turn_hook: true` plugin — prints a line into the
//! transcript after every REPL turn. Proves out the general REPL-behavior
//! WASM plugin surface (registry.zig's `turn_hook` descriptor field, read by
//! `runTurnHooks` in src/cli.zig), distinct from `statusline` (which only
//! contributes a status-bar segment, not transcript content).
//! Disabled by default, and (like every `internal: true` tool) exempt from
//! the `/plugins` runtime toggle — try it by flipping `enabled` to `true` in
//! this tool's manifest.
//! Input:  {}
//! Output: {"ok": true, "text": "..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    _ = parsed;
    return lib.okText(out, "↳ turn_hook_echo: a turn just finished");
}
