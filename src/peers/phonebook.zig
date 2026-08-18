//! Rendering half of `clanker phonebook`: turns the sandboxed `peers` guest's
//! `action:"phonebook"` reply into the operator's name/url/skills/status
//! table. Read-only probing of other clankers, distinct from chatrooms.zig's
//! message fan-out.
//!
//! The scan itself is the guest's (its `network_from_config` allowlist is
//! what gates peer traffic, so this is never a native HTTP call), and loading
//! that guest is the CLI's, through `toolJson` — the one call site the web
//! UI's `/api/peers` route shares. Keeping this file to rendering is also
//! what stops `peers` from importing `sandbox`, the cycle chatrooms.zig
//! avoids with an injected runner.

const std = @import("std");
const log = @import("../util/log.zig");

const PhonebookPeer = struct {
    name: []const u8 = "",
    url: []const u8 = "",
    status: []const u8 = "down",
    card_name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    skills: ?[]const []const u8 = null,
    @"error": ?[]const u8 = null,
};

const PhonebookResult = struct {
    ok: bool = false,
    @"error": ?[]const u8 = null,
    peers: []const PhonebookPeer = &.{},
};

/// The table `clanker phonebook` prints, trailing newline included. A reply
/// the guest itself marked failed is an error, not an empty table: "no peers
/// answered" and "the scan never ran" must not read the same.
pub fn render(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const result = std.json.parseFromSliceLeaky(PhonebookResult, arena, raw, .{ .ignore_unknown_fields = true }) catch PhonebookResult{};
    if (!result.ok) {
        log.log(.error_, "phonebook failed: {s}", .{result.@"error" orelse "unknown error"});
        return error.ToolFailed;
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "name\turl\tskills\tstatus\n");
    for (result.peers) |p| {
        const name = p.card_name orelse p.name;
        try out.appendSlice(arena, name);
        try out.append(arena, '\t');
        try out.appendSlice(arena, p.url);
        try out.append(arena, '\t');
        if (p.skills) |skills| {
            for (skills, 0..) |s, i| {
                if (i > 0) try out.append(arena, ',');
                try out.appendSlice(arena, s);
            }
        }
        try out.append(arena, '\t');
        // A peer that answered has nothing to explain; anything else shows
        // why, falling back to the bare status when the guest gave no reason.
        try out.appendSlice(arena, if (std.mem.eql(u8, p.status, "up")) p.status else (p.@"error" orelse p.status));
        try out.append(arena, '\n');
    }
    return out.toOwnedSlice(arena);
}

test "render lays out a peer row per card, error text standing in for a down status" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{"ok":true,"peers":[
        \\{"name":"a","url":"http://a:7777","status":"up","card_name":"alpha","skills":["code","chat"]},
        \\{"name":"b","url":"http://b:7777","status":"down","error":"connection refused"},
        \\{"name":"c","url":"http://c:7777","status":"down"}]}
    ;
    try std.testing.expectEqualStrings(
        "name\turl\tskills\tstatus\n" ++
            "alpha\thttp://a:7777\tcode,chat\tup\n" ++
            "b\thttp://b:7777\t\tconnection refused\n" ++
            "c\thttp://c:7777\t\tdown\n",
        try render(arena, raw),
    );
}

test "render refuses a reply the guest marked failed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // Malformed JSON lands on the same branch: a reply we cannot read is not
    // a peerless fleet.
    try std.testing.expectError(error.ToolFailed, render(arena_state.allocator(), "{\"ok\":false,\"error\":\"peers module is off\"}"));
    try std.testing.expectError(error.ToolFailed, render(arena_state.allocator(), "{\"ok\":true,\"peers\":["));
}
