//! learnings: read the persisted learnings file (state/learnings.md) so the
//! agent can recall what it already learned (note_write is write-only today).
//! Input:  {}
//! Output: {"ok": true, "text": "<learnings>"}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    _ = input;
    const raw = lib.fsRead("state/learnings.md") catch return lib.fail(out, "no learnings yet");
    return lib.okText(out, raw);
}
