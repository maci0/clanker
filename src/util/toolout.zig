//! Sanity check on what a tool hands back.
//!
//! Every tool here answers with a JSON object, and both callers pass that text
//! on untouched: the agent puts it in the conversation, the MCP server returns
//! it to whatever is driving. A tool that emits something almost-JSON is
//! therefore invisible. The reader does its best with a broken object and
//! nothing says the tool was at fault.
//!
//! A warning rather than an error, because a tool is free to answer with plain
//! text. It only fires when the output opens like JSON, where the intent is not
//! in doubt.

const std = @import("std");
const log = @import("log.zig");

/// True when `out` opens like JSON and does not parse.
pub fn looksLikeBrokenJson(arena: std.mem.Allocator, out: []const u8) bool {
    const text = std.mem.trimStart(u8, out, " \t\r\n");
    if (text.len == 0) return false;
    if (text[0] != '{' and text[0] != '[') return false;
    _ = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return true;
    return false;
}

/// Says so, once, naming the tool.
pub fn warnIfMalformed(arena: std.mem.Allocator, name: []const u8, out: []const u8) void {
    if (looksLikeBrokenJson(arena, out)) {
        log.log(.warn, "tool '{s}' returned malformed JSON; the caller will see it as written", .{name});
    }
}

/// Same, for a caller that has no arena to spare.
pub fn warnIfMalformedAlloc(gpa: std.mem.Allocator, name: []const u8, out: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    warnIfMalformed(arena_state.allocator(), name, out);
}

test "output that opens like JSON and does not parse is reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The exact shapes two tools shipped, both from writing a value with
    // print, which emits raw text and quotes nothing.
    try std.testing.expect(looksLikeBrokenJson(arena, "{\"ok\":true,\"note\":the file has 125 lines}"));
    try std.testing.expect(looksLikeBrokenJson(arena, "{\"ok\":true,\"stat\",{\"kind\":\"file\"}}"));
    try std.testing.expect(looksLikeBrokenJson(arena, "[1,2,"));

    // Valid JSON, and output that never claimed to be JSON, are both fine.
    try std.testing.expect(!looksLikeBrokenJson(arena, "{\"ok\":true,\"note\":\"past the end\"}"));
    try std.testing.expect(!looksLikeBrokenJson(arena, "  {\"a\":[1,2,3]}  "));
    try std.testing.expect(!looksLikeBrokenJson(arena, "plain text answer"));
    try std.testing.expect(!looksLikeBrokenJson(arena, ""));
}
