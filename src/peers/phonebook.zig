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

/// Normalizes a peer URL for identity comparison: surrounding whitespace is
/// not part of the URL, and `http://a:7777`, `http://a:7777/` describe the
/// same base, so configured and discovered duplicates compare equal.
fn normalizedUrl(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var end = trimmed.len;
    while (end > 0 and trimmed[end - 1] == '/') end -= 1;
    return trimmed[0..end];
}

fn statusRank(status: []const u8) u8 {
    return if (std.mem.eql(u8, status, "up")) 0 else 1;
}

/// Deterministic peer order: normalized URL, then reachable before
/// unreachable (so dedup keeps the `up` record when two sources disagree),
/// then display name, then remaining fields for a total order.
fn peerLessThan(_: void, a: PhonebookPeer, b: PhonebookPeer) bool {
    const an = normalizedUrl(a.url);
    const bn = normalizedUrl(b.url);
    const url_order = std.mem.order(u8, an, bn);
    if (url_order == .lt) return true;
    if (url_order == .gt) return false;

    const ar = statusRank(a.status);
    const br = statusRank(b.status);
    if (ar != br) return ar < br;

    const a_name = a.card_name orelse a.name;
    const b_name = b.card_name orelse b.name;
    if (!std.mem.eql(u8, a_name, b_name)) return std.mem.lessThan(u8, a_name, b_name);
    if (!std.mem.eql(u8, a.status, b.status)) return std.mem.lessThan(u8, a.status, b.status);
    return std.mem.lessThan(u8, a.@"error" orelse "", b.@"error" orelse "");
}

/// Sorts and deduplicates the guest's peer list by normalized URL. A peer
/// that appears both as a configured [[peers]] entry and as a discovered
/// agent card is one row; because `up` sorts before any other status within
/// the same URL, that row is the reachable record when the two disagree.
fn dedupePeers(arena: std.mem.Allocator, peers: []const PhonebookPeer) ![]const PhonebookPeer {
    if (peers.len < 2) return peers;
    var sorted: std.ArrayList(PhonebookPeer) = .empty;
    try sorted.appendSlice(arena, peers);
    std.mem.sort(PhonebookPeer, sorted.items, {}, peerLessThan);
    var unique: std.ArrayList(PhonebookPeer) = .empty;
    for (sorted.items) |p| {
        if (unique.items.len > 0) {
            const prev = unique.items[unique.items.len - 1];
            if (std.mem.eql(u8, normalizedUrl(prev.url), normalizedUrl(p.url))) continue;
        }
        try unique.append(arena, p);
    }
    return unique.toOwnedSlice(arena);
}

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
    const peers = try dedupePeers(arena, result.peers);
    for (peers) |p| {
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

test "dedupePeers sorts by URL and keeps the up record for duplicate normalized URLs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const peers = [_]PhonebookPeer{
        .{ .name = "zeta", .url = "http://z:7777", .status = "down" },
        .{ .name = "cfg-a", .url = "http://a:7777/", .status = "down", .@"error" = "connection refused" },
        .{ .name = "card-a", .url = "http://a:7777", .status = "up", .card_name = "alpha" },
    };
    const deduped = try dedupePeers(arena, &peers);
    try std.testing.expectEqual(@as(usize, 2), deduped.len);
    try std.testing.expectEqualStrings("alpha", deduped[0].card_name.?);
    try std.testing.expectEqualStrings("zeta", deduped[1].name);
}
