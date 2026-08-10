//! cmd_help: slash-command reference for the clanker REPL.
//! Input:  {"args": "..."}
//! Output: {"ok": true, "text": "<command reference>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    _ = parsed;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(help_text);
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

const help_text =
    \\slash commands (most run as WASM tools):
    \\  /help            this reference
    \\  /tools           list registered tools
    \\  /sessions        list saved sessions
    \\  /graph           show the latest execution graph
    \\  /status          show instance + peers
    \\  /goal <intent>   design and persist a goal (runs the agent)
    \\  /quit | /exit    leave the REPL
    \\
    \\anything else is sent to the agent as a task.
;
