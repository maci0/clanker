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
pub fn looksLikeBrokenJson(allocator: std.mem.Allocator, out: []const u8) bool {
    const text = std.mem.trimStart(u8, out, " \t\r\n");
    if (text.len == 0) return false;
    if (text[0] != '{' and text[0] != '[') return false;
    return !(std.json.validate(allocator, text) catch return true);
}

/// Says so, once, naming the tool. Validation only allocates for extreme JSON
/// nesting and releases that temporary storage before returning.
pub fn warnIfMalformed(allocator: std.mem.Allocator, name: []const u8, out: []const u8) void {
    if (looksLikeBrokenJson(allocator, out)) {
        log.log(.warn, "tool '{s}' returned malformed JSON; the caller will see it as written", .{name});
    }
}

/// Separator spliced into an over-long tool result when the agent prunes it
/// down to head/tail. Lives here (a leaf) so `config.zig` validation can
/// account for its length without depending on `agent/prune.zig`.
pub const prune_marker = "\n\n[... tool result middle pruned ...]\n\n";

/// How much of a tool call's arguments a human is shown when judging it:
/// the shared budget for the confirm prompt, the TUI card body, and the web
/// stream's per-call row (card_preview_cap in tui/transcript.zig). Lives
/// here (a leaf) so the transcript does not depend on `agent/loop.zig` to
/// size its cards.
pub const args_preview_cap: usize = 400;

test "output that opens like JSON and does not parse is reported" {
    // The exact shapes two tools shipped, both from writing a value with
    // print, which emits raw text and quotes nothing.
    try std.testing.expect(looksLikeBrokenJson(std.testing.allocator, "{\"ok\":true,\"note\":the file has 125 lines}"));
    try std.testing.expect(looksLikeBrokenJson(std.testing.allocator, "{\"ok\":true,\"stat\",{\"kind\":\"file\"}}"));
    try std.testing.expect(looksLikeBrokenJson(std.testing.allocator, "[1,2,"));

    // Valid JSON, and output that never claimed to be JSON, are both fine.
    try std.testing.expect(!looksLikeBrokenJson(std.testing.allocator, "{\"ok\":true,\"note\":\"past the end\"}"));
    try std.testing.expect(!looksLikeBrokenJson(std.testing.allocator, "  {\"a\":[1,2,3]}  "));
    try std.testing.expect(!looksLikeBrokenJson(std.testing.allocator, "plain text answer"));
    try std.testing.expect(!looksLikeBrokenJson(std.testing.allocator, ""));
}
