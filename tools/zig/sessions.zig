//! sessions: list saved conversations (state/sessions/*.json).
//! Input:  {} | {"format":"json"}
//! Output: {"ok": true, "text": "<id>  <title>  <age>  per line, newest last>"}
//!         {"ok": true, "sessions": [{id,title,created,updated,workspace,archived,messages,bytes}]}
//!
//! `GET /api/sessions` relays `format=json`. Mutations (fork/branch/rename/
//! delete) stay native: they write the session store.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("sessions_logic.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const q = lib.optStr(req, "q") orelse lib.optStr(req, "args");
    if (q) |query| {
        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len < 3) return lib.fail(out, "query must be at least 3 characters");
        return searchSessions(out, trimmed);
    }
    const as_json = if (lib.optStr(req, "format")) |fmt| std.mem.eql(u8, fmt, "json") else false;

    // state/ is gitignored and every directory under it is created lazily on
    // first write, so a checkout that has never saved a session has no
    // state/sessions at all. That is zero sessions, not a failure — fall
    // through to the empty-list message below.
    const raw: []const u8 = lib.fsList("state/sessions") catch |err| switch (err) {
        error.NotFound => "[]",
        else => return lib.failErr(out, err, "listing state/sessions"),
    };
    const names = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{});

    var metas: std.ArrayList(logic.Listing) = .empty;
    defer metas.deinit(lib.alloc);
    if (names == .array) {
        for (names.array.items) |item| {
            if (item != .string) continue;
            const fname = item.string;
            if (!std.mem.endsWith(u8, fname, ".json")) continue;
            const path = try std.fmt.allocPrint(lib.alloc, "state/sessions/{s}", .{fname});
            defer lib.alloc.free(path);
            // Title/updated/counters sit in front of the transcript. A full
            // ck_fs_read of every file both costs up to 1 MiB apiece (the
            // host cap, max_fs_bytes) and burns the 1 MiB host arena, so
            // later sessions vanished from the list.
            const content = lib.fsReadRange(path, 0, 4096) catch continue;
            const row = logic.listingFromPrefix(lib.alloc, content) orelse continue;
            try metas.append(lib.alloc, .{
                .id = try lib.alloc.dupe(u8, row.id),
                .title = try lib.alloc.dupe(u8, row.title),
                .created = row.created,
                .updated = row.updated,
                .workspace = try lib.alloc.dupe(u8, row.workspace),
                .archived = row.archived,
                .messages = row.messages,
                .bytes = row.bytes,
            });
        }
    }

    if (as_json) {
        logic.sortNewestFirst(metas.items);
        var w = lib.writer(out);
        try logic.writeJson(&w, metas.items);
        lib.commit(out, &w);
        return;
    }

    if (metas.items.len == 0) {
        return lib.okText(out, "No saved conversations yet. Start one with `clanker repl` or `clanker run \"<task>\"`.");
    }

    logic.sortOldestFirst(metas.items);
    const now_s: i64 = @trunc(lib.nowSeconds());
    const text = try logic.writeText(lib.alloc, metas.items, now_s);
    return lib.okText(out, text);
}

fn searchSessions(out: *lib.Out, query: []const u8) !void {
    // Always a structured {"ok":true,"query":...,"hits":[...]} so callers can
    // machine-consume the result. An empty store (state/sessions/ missing or
    // no match) is a valid empty hit list, not a failure.
    const raw = lib.fsGrep("state/sessions", query) catch |err| switch (err) {
        error.NotFound => null,
        else => return lib.failErr(out, err, "searching sessions"),
    };
    var w = lib.writer(out);
    try w.writeAll("{\"ok\":true,\"query\":");
    try std.json.Stringify.value(query, .{}, &w);
    try w.writeAll(",\"hits\":");
    try w.writeAll(raw orelse "[]");
    try w.writeAll("}");
    lib.commit(out, &w);
}
