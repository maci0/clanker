//! advisor: fail-open post-turn critique. One prompt, one parsed note.
//!
//! Input:  {"summary":"...","provider":"<optional>"}
//! Output: {"ok":true,"severity":"note|concern|blocker","text":"..."}
//!
//! The native loop still owns injection and the blocker ask (session write
//! path). This guest owns the completion and the note dialect so a CLI or
//! hook can run the same review without a second parser.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("advisor_logic.zig");

const Request = struct {
    summary: []const u8 = "",
    provider: []const u8 = "",
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = std.json.parseFromSliceLeaky(Request, lib.alloc, input, .{ .ignore_unknown_fields = true }) catch Request{};
    const summary = std.mem.trim(u8, req.summary, " \t\r\n");
    if (summary.len == 0) return lib.fail(out, "summary is empty");

    const provider: ?[]const u8 = if (req.provider.len > 0) req.provider else null;
    // 0 keeps the descriptor's grant (`tools/manifests/advisor.tool.json`),
    // which carries the reasoning headroom this call needs. The old 256 was
    // sized for the note alone — a <150-word JSON object — so on a reasoning
    // model the trace consumed it and `parseNote` saw an empty string.
    const raw = lib.llmSystem(logic.system_prompt, summary, provider, 0) catch |err| {
        return lib.fail(out, switch (err) {
            error.SandboxDenied => "refused by sandbox policy",
            error.NetworkError => "advisor request did not complete",
            error.InvalidArg => "arguments rejected",
            else => "advisor did not respond",
        });
    };
    const note = logic.parseNote(lib.alloc, raw) orelse return lib.fail(out, "reply was not a note");

    var buf: [4 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("severity");
    try s.write(@tagName(note.severity));
    try s.objectField("text");
    try s.write(note.text);
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}
