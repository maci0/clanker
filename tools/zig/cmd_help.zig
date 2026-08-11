//! cmd_help: slash-command reference for the clanker REPL.
//! Input:  {"args": "..."}
//! Output: {"ok": true, "text": "<command reference>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    _ = parsed;
    return lib.okText(out, help_text);
}

const help_text =
    \\slash commands (most run as WASM tools):
    \\  /help            this reference
    \\  /tools           list registered tools
    \\  /sessions        list saved sessions
    \\  /graph           show the latest execution graph
    \\  /status          show instance + peers
    \\  /goal <intent>   design and persist a goal (runs the agent)
    \\  /quit | /exit | exit
    \\                    leave the REPL
    \\
    \\anything else is sent to the agent as a task.
;
