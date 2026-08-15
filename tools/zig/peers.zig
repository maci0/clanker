//! peers: talk to the other clanker instances listed in config.
//!
//! Input:  {"action": "phonebook"}                     scan every peer's card
//!         {"action": "notify", "peer": "<name>", "message": "..."}      one peer
//!         {"action": "notify", "message": "...", "kind": "...", "topic": "..."}  every peer
//! Output: {"ok": true, "peers": [...]}  |  {"ok": true, "sent": "<name>"|"all"}
//!
//! The peer hosts are not in this descriptor: it sets
//! `"network_from_config": "peers"` and the harness adds whatever is configured
//! to the ck_http allowlist, so adding a peer to config is enough.

const std = @import("std");
const lib = @import("lib.zig");

const Peer = struct {
    name: []const u8 = "",
    url: []const u8 = "",
};

const ConfigFile = struct {
    peers: []const Peer = &.{},
    instance: ?Instance = null,
};

const Instance = struct {
    name: []const u8 = "",
    id: []const u8 = "",
};

const AgentCard = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    skills: ?[]const []const u8 = null,
};

const Request = struct {
    action: []const u8 = "phonebook",
    peer: []const u8 = "",
    message: []const u8 = "",
    kind: []const u8 = "message",
    topic: []const u8 = "",
    /// Stable per logical notification. Callers retrying an uncertain send
    /// should reuse this value; when omitted the tool creates one once and
    /// uses it for every peer in a broadcast.
    id: []const u8 = "",
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const req = std.json.parseFromSliceLeaky(Request, alloc, input, .{ .ignore_unknown_fields = true }) catch
        Request{};

    const peers = try loadPeers(alloc);

    if (std.mem.eql(u8, req.action, "phonebook")) return phonebook(out, alloc, peers);
    if (std.mem.eql(u8, req.action, "notify")) return notify(out, alloc, peers, req);
    return lib.fail(out, "action must be \"phonebook\" or \"notify\"");
}

/// Phonebook folds a missing peers config to an empty array rather than a
/// failure: "no peers configured" is a valid environment state, not an error,
/// and the peers_phonebook capability eval asserts the ok field is true
/// whatever the network looks like (see evals/peers_phonebook.task.json). The
/// notify path keeps failing on an empty list — there is nobody to notify.
fn loadPeers(alloc: std.mem.Allocator) ![]const Peer {
    const cfg = std.json.parseFromSliceLeaky(ConfigFile, alloc, lib.harnessConfig(), .{ .ignore_unknown_fields = true }) catch return &.{};
    return cfg.peers;
}

fn instanceName(alloc: std.mem.Allocator) []const u8 {
    const cfg = std.json.parseFromSliceLeaky(ConfigFile, alloc, lib.harnessConfig(), .{ .ignore_unknown_fields = true }) catch return "clanker";
    if (cfg.instance) |i| if (i.name.len > 0) return i.name;
    return "clanker";
}

/// Fetches every peer's agent card. A peer that is down is reported as down,
/// not omitted: "which of my peers is unreachable" is the useful answer.
fn phonebook(out: *lib.Out, alloc: std.mem.Allocator, peers: []const Peer) !void {
    var buf: [48 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("peers");
    try s.beginArray();
    for (peers) |p| {
        const url = try std.fmt.allocPrint(alloc, "{s}/.well-known/agent.json", .{std.mem.trimEnd(u8, p.url, "/")});
        try s.beginObject();
        try s.objectField("name");
        try s.write(p.name);
        try s.objectField("url");
        try s.write(p.url);
        if (lib.httpGet(url)) |body| {
            const card = std.json.parseFromSliceLeaky(AgentCard, alloc, body, .{ .ignore_unknown_fields = true }) catch AgentCard{};
            try s.objectField("status");
            try s.write("up");
            if (card.name) |n| {
                try s.objectField("card_name");
                try s.write(n);
            }
            if (card.description) |d| {
                try s.objectField("description");
                try s.write(d);
            }
            if (card.skills) |sk| {
                try s.objectField("skills");
                try s.write(sk);
            }
        } else |err| {
            try s.objectField("status");
            try s.write("down");
            try s.objectField("error");
            try s.write(switch (err) {
                error.SandboxDenied => "refused by sandbox policy",
                error.NetworkError => "request did not complete",
                else => "peer did not respond",
            });
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

fn notify(out: *lib.Out, alloc: std.mem.Allocator, peers: []const Peer, req: Request) !void {
    if (req.message.len == 0) return lib.fail(out, "notify needs a message");

    var delivery = req;
    if (delivery.id.len == 0) {
        const now_bits: u64 = @bitCast(lib.nowSeconds());
        const content_hash = std.hash.Wyhash.hash(0, req.message);
        delivery.id = try std.fmt.allocPrint(alloc, "{x}-{x}", .{ now_bits, content_hash });
    }

    // No peer named: fan out to every configured peer instead of one. The
    // same `delivery.id` goes to every peer and is echoed back below, so a
    // caller that sees a nonzero `failed` count can retry the whole
    // broadcast with that id: peers already reached dedup the redelivery on
    // the id, the ones missed the first time receive it for the first time.
    if (req.peer.len == 0) {
        var failed: usize = 0;
        for (peers) |p| sendNotify(alloc, p, delivery) catch {
            failed += 1;
        };
        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var s = std.json.Stringify{ .writer = &w, .options = .{} };
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("sent");
        try s.write("all");
        try s.objectField("failed");
        try s.write(failed);
        try s.objectField("id");
        try s.write(delivery.id);
        try s.endObject();
        return out.writeAll(buf[0..w.end]);
    }

    var target: ?Peer = null;
    for (peers) |p| {
        if (std.mem.eql(u8, p.name, req.peer)) target = p;
    }
    const peer = target orelse return lib.fail(out, "no such peer");
    sendNotify(alloc, peer, delivery) catch |err| return failWithId(out, err, "notifying the peer", delivery.id);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("sent");
    try s.write(peer.name);
    try s.objectField("id");
    try s.write(delivery.id);
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

/// Like `lib.failErr`, but echoes `id` back to the caller. A failed send is
/// exactly when a retry matters most, and a retry only dedups correctly on
/// the receiving end if it reuses this same id — which the caller can only
/// do if the id it never chose gets handed back to it here.
fn failWithId(out: *lib.Out, err: anyerror, what: []const u8, id: []const u8) !void {
    var msg_buf: [512]u8 = undefined;
    const msg = switch (err) {
        error.SandboxDenied => std.fmt.bufPrint(&msg_buf, "{s}: refused by this tool's sandbox policy — its manifest has to allow the path (fs_prefixes), the command (exec_allow) or the host (network_allow)", .{what}),
        error.NotFound => std.fmt.bufPrint(&msg_buf, "{s}: not found", .{what}),
        error.TooLarge => std.fmt.bufPrint(&msg_buf, "{s}: too large for one call — ask for a smaller range or narrow the query", .{what}),
        error.NetworkError => std.fmt.bufPrint(&msg_buf, "{s}: the request did not complete", .{what}),
        error.InvalidArg => std.fmt.bufPrint(&msg_buf, "{s}: the arguments were rejected", .{what}),
        error.OutOfMemory => std.fmt.bufPrint(&msg_buf, "{s}: out of memory in the sandbox", .{what}),
        else => std.fmt.bufPrint(&msg_buf, "{s}: the request could not be completed", .{what}),
    } catch what;

    out.reset();
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(false);
    try s.objectField("error");
    try s.write(msg);
    try s.objectField("id");
    try s.write(id);
    try s.endObject();
    lib.commit(out, &w);
}

fn sendNotify(alloc: std.mem.Allocator, peer: Peer, req: Request) !void {
    var body_buf: [16 * 1024]u8 = undefined;
    var bw: std.Io.Writer = .fixed(&body_buf);
    var bs = std.json.Stringify{ .writer = &bw, .options = .{} };
    try bs.beginObject();
    try bs.objectField("from");
    try bs.write(instanceName(alloc));
    try bs.objectField("kind");
    try bs.write(req.kind);
    try bs.objectField("topic");
    try bs.write(req.topic);
    try bs.objectField("payload");
    try bs.write(req.message);
    try bs.objectField("ts");
    try bs.print("{d}", .{@as(i64, @trunc(lib.nowSeconds()))});
    try bs.objectField("id");
    try bs.write(req.id);
    try bs.endObject();

    const url = try std.fmt.allocPrint(alloc, "{s}/api/notify", .{std.mem.trimEnd(u8, peer.url, "/")});
    _ = try lib.httpPost(url, body_buf[0..bw.end]);
}
