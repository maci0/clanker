//! webui: serves the clanker web UI — a single self-contained page with no
//! external scripts, styles, or fonts, so it works on an offline host
//! (webui/index.html, embedded at comptime via @embedFile) — from the sandbox.
//! Internal tool: it is never offered to the LLM; the `clanker serve` HTTP
//! server calls it to render GET / and /webui.
//! Input:  {"path": "/"}
//! Output: {"ok": true, "content_type": "text/html", "body": "..."}

const std = @import("std");
const lib = @import("lib.zig");

/// The page is kept as a separate asset (webui/index.html) so it can be
/// edited independently of the tool code; embedded at comptime.
const page = @embedFile("webui/index.html");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    _ = parsed;
    // Any path serves the single-page app (client-side routing is handled in JS).
    var buf: [128 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("content_type");
    try s.write("text/html");
    try s.objectField("body");
    try s.write(page);
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}
