//! peers: talk to the other clanker instances listed in config.
//!
//! Input:  {"action": "phonebook"}                     scan every peer's card
//!         {"action": "notify", "peer": "<name>", "message": "..."}
//! Output: {"ok": true, "peers": [...]}  |  {"ok": true, "sent": "<name>"}
//!
//! The peer hosts are not in this descriptor: it sets
//! `"network_from_config": "peers"` and the harness adds whatever is configured
//! to the ck_http allowlist, so adding a peer to config.json is enough.

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
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const req = std.json.parseFromSliceLeaky(Request, alloc, input, .{ .ignore_unknown_fields = true }) catch
        Request{};

    const peers = try loadPeers(alloc);
    if (peers.len == 0) return lib.fail(out, "no peers configured");

    if (std.mem.eql(u8, req.action, "phonebook")) return phonebook(out, alloc, peers);
    if (std.mem.eql(u8, req.action, "notify")) return notify(out, alloc, peers, req);
    return lib.fail(out, "action must be \"phonebook\" or \"notify\"");
}

/// config.local.json wins over config.json, matching the harness's own merge.
fn loadPeers(alloc: std.mem.Allocator) ![]const Peer {
    var peers: []const Peer = &.{};
    for ([_][]const u8{ "config.json", "config.local.json" }) |path| {
        const raw = lib.fsRead(path) catch continue;
        const cfg = std.json.parseFromSliceLeaky(ConfigFile, alloc, raw, .{ .ignore_unknown_fields = true }) catch continue;
        if (cfg.peers.len > 0) peers = cfg.peers;
    }
    return peers;
}

fn instanceName(alloc: std.mem.Allocator) []const u8 {
    for ([_][]const u8{ "config.local.json", "config.json" }) |path| {
        const raw = lib.fsRead(path) catch continue;
        const cfg = std.json.parseFromSliceLeaky(ConfigFile, alloc, raw, .{ .ignore_unknown_fields = true }) catch continue;
        if (cfg.instance) |i| {
            if (i.name.len > 0) return i.name;
        }
    }
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
            try s.write(@errorName(err));
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

fn notify(out: *lib.Out, alloc: std.mem.Allocator, peers: []const Peer, req: Request) !void {
    if (req.peer.len == 0) return lib.fail(out, "notify needs a peer name");
    if (req.message.len == 0) return lib.fail(out, "notify needs a message");

    var target: ?Peer = null;
    for (peers) |p| {
        if (std.mem.eql(u8, p.name, req.peer)) target = p;
    }
    const peer = target orelse return lib.fail(out, "no such peer");

    var body_buf: [16 * 1024]u8 = undefined;
    var bw: std.Io.Writer = .fixed(&body_buf);
    var bs = std.json.Stringify{ .writer = &bw, .options = .{} };
    try bs.beginObject();
    try bs.objectField("from");
    try bs.write(instanceName(alloc));
    try bs.objectField("kind");
    try bs.write("message");
    try bs.objectField("payload");
    try bs.write(req.message);
    try bs.endObject();

    const url = try std.fmt.allocPrint(alloc, "{s}/api/notify", .{std.mem.trimEnd(u8, peer.url, "/")});
    _ = lib.httpPost(url, body_buf[0..bw.end]) catch |err| return lib.fail(out, @errorName(err));

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("sent");
    try s.write(peer.name);
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}
