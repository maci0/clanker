//! peers: talk to the other clanker instances listed in config.
//!
//! Input:  {"action": "phonebook"}                     scan every peer's card
//!         {"action": "notify", "peer": "<name>", "message": "..."}      one peer
//!         {"action": "notify", "message": "...", "kind": "...", "topic": "..."}  every peer
//!         {"action": "chat_fanout", "room": "...", "text": "...", ...}  deliver a chat
//!                                    message to every peer (the host passes the names
//!                                    in its per-peer backoff window as "skip")
//! Output: {"ok": true, "peers": [...]}  |  {"ok": true, "sent": "<name>"|"all"}
//!         {"ok": true, "results": [{"name","ok"|"error"}]}
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
    /// chat_fanout fields. `from`/`ts`/`id` fall back to this instance's
    /// name, now, and a generated id when the caller leaves them blank.
    room: []const u8 = "",
    from: []const u8 = "",
    text: []const u8 = "",
    ts: i64 = 0,
    thread_ts: ?[]const u8 = null,
    /// Peer names to leave alone (the host's per-peer backoff window).
    skip: []const []const u8 = &.{},
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
    if (std.mem.eql(u8, req.action, "chat_fanout")) return chatFanout(out, alloc, peers, req);
    return lib.fail(out, "action must be \"phonebook\", \"notify\", or \"chat_fanout\"");
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
            // A legible reason per failure shape, so an operator can tell a
            // switched-off LAN peer from a mistyped config URL. The render
            // half (src/peers/phonebook.zig) prints this field in the status
            // column, so this is what both the CLI and the web UI show.
            try s.write(downReason(p.url, err));
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

/// One operator-legible reason per failure shape. The host ABI folds every
/// fetch failure into a single network code, so the URL itself is checked
/// here and the network failure is named for what it can still be.
fn downReason(config_url: []const u8, err: anyerror) []const u8 {
    if (invalidUrl(config_url)) |why| return why;
    return switch (err) {
        error.SandboxDenied => "refused by sandbox policy: the peer host is not in this tool's network allowlist",
        error.NetworkError => "unreachable: connection refused, timed out, or DNS failed",
        error.NoAccess => "no access to the peer host",
        error.TooLarge => "peer answered but the response was too large to return",
        error.InvalidArg => "malformed peer url",
        else => "peer did not respond",
    };
}

/// Returns a reason when `raw` cannot be a usable peer base URL, or null when
/// it can. Checked guest-side so a config typo is named as such instead of
/// surfacing as whatever error the host's URL parser happens to return.
fn invalidUrl(raw: []const u8) ?[]const u8 {
    const url = std.mem.trim(u8, raw, " \t\r\n");
    if (url.len == 0) return "peer url is empty in config";
    const scheme_len: usize = if (std.mem.startsWith(u8, url, "http://"))
        "http://".len
    else if (std.mem.startsWith(u8, url, "https://"))
        "https://".len
    else
        return "malformed peer url: must start with http:// or https://";
    const rest = url[scheme_len..];
    var host_len = rest.len;
    for (rest, 0..) |c, i| {
        if (c <= 0x20 or c == 0x7f) return "malformed peer url: contains whitespace or control characters";
        if (c == '/' or c == ':' or c == '?') {
            host_len = i;
            break;
        }
    }
    if (host_len == 0) return "malformed peer url: no host after the scheme";
    return null;
}

fn notify(out: *lib.Out, alloc: std.mem.Allocator, peers: []const Peer, req: Request) !void {
    if (req.message.len == 0) return lib.fail(out, "notify needs a message");

    var delivery = req;
    if (delivery.id.len == 0) {
        // Stable across a retry of the same send: the previous id mixed in
        // wall-clock seconds, so a lost response followed by a re-run of
        // `clanker notify` (or the agent calling notify again) looked like a
        // new delivery and landed twice. A 60s bucket covers the retry
        // horizon; a deliberate re-send after that is a new notification.
        // The inbox already drops a redelivery of a known id and trims at
        // 1 MiB, so this does not grow unbounded.
        delivery.id = try generatedDeliveryId(alloc, req);
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

fn generatedDeliveryId(alloc: std.mem.Allocator, req: Request) ![]const u8 {
    const now_s: u64 = @trunc(lib.nowSeconds());
    const bucket = now_s / 60;
    var h = std.hash.Wyhash.init(bucket);
    h.update(req.kind);
    h.update(req.topic);
    h.update(req.message);
    return std.fmt.allocPrint(alloc, "{x}-{x}", .{ bucket, h.final() });
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

/// Delivers one chat message to every configured peer's `/api/chat/message`.
/// The host keeps the per-peer backoff table and passes the names it is
/// already cooling down as `skip`; this guest only does the gated network
/// work and reports a per-peer outcome back so the host can move each peer
/// into or out of backoff. Same traffic class as phonebook/notify: every
/// request is confined to the configured peer hosts by
/// `network_from_config`.
fn chatFanout(out: *lib.Out, alloc: std.mem.Allocator, peers: []const Peer, req: Request) !void {
    if (req.room.len == 0 or req.text.len == 0) return lib.fail(out, "chat_fanout needs a room and a text");

    const from = if (req.from.len > 0) req.from else instanceName(alloc);
    const ts = if (req.ts > 0) req.ts else @as(i64, @trunc(lib.nowSeconds()));
    var generated_id: []const u8 = req.id;
    if (generated_id.len == 0) {
        const now_bits: u64 = @trunc(lib.nowSeconds());
        var h = std.hash.Wyhash.init(0);
        h.update(req.room);
        h.update(req.text);
        const content_hash = h.final();
        generated_id = try std.fmt.allocPrint(alloc, "{x}-{x}", .{ now_bits, content_hash });
    }

    var body_buf: [16 * 1024]u8 = undefined;
    var bw: std.Io.Writer = .fixed(&body_buf);
    var bs = std.json.Stringify{ .writer = &bw, .options = .{ .emit_null_optional_fields = false } };
    try bs.beginObject();
    try bs.objectField("room");
    try bs.write(req.room);
    try bs.objectField("from");
    try bs.write(from);
    try bs.objectField("text");
    try bs.write(req.text);
    try bs.objectField("ts");
    try bs.print("{d}", .{ts});
    try bs.objectField("id");
    try bs.write(generated_id);
    if (req.thread_ts) |tts| {
        try bs.objectField("thread_ts");
        try bs.write(tts);
    }
    try bs.endObject();
    const body = body_buf[0..bw.end];

    var out_buf: [48 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("results");
    try s.beginArray();
    for (peers) |p| {
        var skip_peer = false;
        for (req.skip) |skipped| {
            if (std.mem.eql(u8, skipped, p.name)) {
                skip_peer = true;
                break;
            }
        }
        if (skip_peer) continue;
        const url = try std.fmt.allocPrint(alloc, "{s}/api/chat/message", .{std.mem.trimEnd(u8, p.url, "/")});
        const result = lib.httpPost(url, body);
        try s.beginObject();
        try s.objectField("name");
        try s.write(p.name);
        if (result) |_| {
            try s.objectField("ok");
            try s.write(true);
        } else |err| {
            try s.objectField("ok");
            try s.write(false);
            try s.objectField("error");
            try s.write(switch (err) {
                error.SandboxDenied => "refused by sandbox policy",
                error.NetworkError => "the request did not complete",
                error.TooLarge => "too large for one call",
                error.InvalidArg => "the arguments were rejected",
                else => "the request could not be completed",
            });
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try out.writeAll(out_buf[0..w.end]);
}
