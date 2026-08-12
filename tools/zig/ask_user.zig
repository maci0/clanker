//! ask_user: put a decision to the human and wait for their pick.
//!
//! For the moments where guessing is worse than asking: which of two designs
//! to build, which file to change, whether to widen the scope. The harness
//! renders the options and returns the chosen one verbatim.
//!
//! Input:  {"question": "Which first?", "options": ["fix the eval", "add the tool"]}
//!         {"question": "...", "options": [...], "peer": "clanker-ember-raven"}
//!         {"question": "...", "options": [...], "parent": true}
//! Output: {"ok": true, "answer": "fix the eval", "answered_by": "user"}
//!         {"ok": false, "error": "..."} when nobody is attached to answer.
//!
//! With `peer`, the question goes to another clanker instead of the human:
//! same question, same options, answered by a peer that has its own tools and
//! its own view of the work. With `parent` (sub-agent runs only), it goes to
//! the agent that spawned this run — the one holding the context the brief
//! left out.

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{}) catch
        return lib.fail(out, "input must be a JSON object");
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");

    const q = parsed.object.get("question") orelse return lib.fail(out, "missing required field: question");
    if (q != .string or q.string.len == 0) return lib.fail(out, "question must be a non-empty string");

    var options: std.ArrayList([]const u8) = .empty;
    defer options.deinit(lib.alloc);
    if (parsed.object.get("options")) |o| {
        if (o == .array) {
            for (o.array.items) |item| {
                if (item == .string and item.string.len > 0) try options.append(lib.alloc, item.string);
            }
        }
    }
    if (options.items.len < 2) return lib.fail(out, "give at least two options; ask in your answer instead when the question is open-ended");

    const wants_parent = if (parsed.object.get("parent")) |p| p == .bool and p.bool else false;
    if (wants_parent and parsed.object.get("peer") != null)
        return lib.fail(out, "pick one target: either \"parent\" or \"peer\", not both");

    var answered_by: []const u8 = "user";
    var answer: []const u8 = undefined;
    if (wants_parent) {
        answered_by = "parent";
        answer = lib.askTarget(q.string, options.items, "parent") catch |err| return lib.fail(out, switch (err) {
            error.NotFound => "you are not running as a sub-agent, so there is no parent to ask; decide yourself and say which option you took and why",
            else => "the parent did not answer",
        });
    } else if (parsed.object.get("peer")) |p| {
        if (p != .string or p.string.len == 0) return lib.fail(out, "peer must be a peer instance name");
        answered_by = p.string;
        answer = askPeer(p.string, q.string, options.items) catch |err| return lib.fail(out, switch (err) {
            error.NoSuchPeer => "no peer by that name in config; call peers to see who is reachable",
            error.SandboxDenied => "that peer's host is not allowlisted for this tool",
            else => "the peer did not answer",
        });
    } else {
        answer = lib.ask(q.string, options.items) catch |err| return lib.fail(out, switch (err) {
            // Scripted runs have no human: say so plainly so the model picks.
            error.NotFound => "no interactive user is attached; decide yourself and say which option you took and why, or ask a peer with {\"peer\": \"<name>\"}",
            else => "could not ask the user",
        });
    }

    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("answer");
    try s.write(answer);
    try s.objectField("answered_by");
    try s.write(answered_by);
    try s.endObject();
    try out.writeAll(buf[0..w.end]);
}

const PeerError = error{ NoSuchPeer, SandboxDenied, NoAnswer, IoError };

/// Puts the same question to a peer clanker over its HTTP API and returns the
/// answer text. The peer runs it as a normal task, so it answers with its own
/// tools and its own state rather than mirroring this instance.
fn askPeer(name: []const u8, question: []const u8, options: []const []const u8) PeerError![]const u8 {
    const url = peerUrl(name) orelse return error.NoSuchPeer;

    var body_buf: [8192]u8 = undefined;
    var bw: std.Io.Writer = .fixed(&body_buf);
    var task_buf: [4096]u8 = undefined;
    var tw: std.Io.Writer = .fixed(&task_buf);
    tw.print("{s}\n\nAnswer with exactly one of these options, verbatim, and nothing else:\n", .{question}) catch return error.IoError;
    for (options) |o| tw.print("- {s}\n", .{o}) catch return error.IoError;

    var s = std.json.Stringify{ .writer = &bw, .options = .{} };
    s.beginObject() catch return error.IoError;
    s.objectField("task") catch return error.IoError;
    s.write(task_buf[0..tw.end]) catch return error.IoError;
    s.endObject() catch return error.IoError;

    var endpoint_buf: [512]u8 = undefined;
    const endpoint = std.fmt.bufPrint(&endpoint_buf, "{s}/api/run", .{std.mem.trimEnd(u8, url, "/")}) catch return error.IoError;

    const raw = lib.httpPost(endpoint, body_buf[0..bw.end]) catch |err| return switch (err) {
        error.SandboxDenied => error.SandboxDenied,
        else => error.NoAnswer,
    };
    const reply = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch return error.NoAnswer;
    if (reply != .object) return error.NoAnswer;
    // /api/run answers in "content"; the other two are accepted so a peer
    // running an older build still gets understood.
    const answer = reply.object.get("content") orelse reply.object.get("answer") orelse reply.object.get("text") orelse return error.NoAnswer;
    if (answer != .string or answer.string.len == 0) return error.NoAnswer;
    return std.mem.trim(u8, answer.string, " \t\r\n");
}

/// The configured URL of a peer by name.
///
/// The peers live in the harness config, not in `lib.config()` — that
/// returns this plugin's own settings — so they are read the same way the
/// peers tool reads them, through the host's already-merged config.
const ConfigFile = struct {
    peers: []const struct {
        name: []const u8 = "",
        url: []const u8 = "",
    } = &.{},
};

fn peerUrl(name: []const u8) ?[]const u8 {
    const cfg = std.json.parseFromSliceLeaky(ConfigFile, lib.alloc, lib.harnessConfig(), .{ .ignore_unknown_fields = true }) catch return null;
    for (cfg.peers) |peer| {
        if (std.mem.eql(u8, peer.name, name) and peer.url.len > 0) return peer.url;
    }
    return null;
}
