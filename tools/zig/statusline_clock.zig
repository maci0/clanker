//! statusline_clock: demo `statusline: true` plugin — contributes the
//! current wall-clock time as a status-bar segment. Proves out the WASM
//! statusbar plugin surface (registry.zig's `statusline` descriptor field,
//! read by `refreshStatusline`/`statuslineSegments` in src/cli.zig).
//! Disabled by default so it doesn't clutter the status line unasked. It's
//! `internal: true` (required for any statusline plugin — otherwise the LLM
//! would see it as a callable tool), and internal tools are exempt from the
//! `/plugins` runtime toggle by design (Registry.Tool.toggleable), so
//! turning it on means flipping `enabled` to `true` in this tool's manifest
//! (tools/manifests/statusline_clock.tool.json), not a `/plugins` command.
//! Input:  {"args": ""}
//! Output: {"ok": true, "text": "13:04:22 UTC"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    _ = parsed;

    const secs: u64 = @intFromFloat(lib.nowSeconds());
    const day_secs = secs % 86400;
    const h = day_secs / 3600;
    const m = (day_secs % 3600) / 60;
    const s = day_secs % 60;
    var buf: [16]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2} UTC", .{ h, m, s });
    return lib.okText(out, text);
}
