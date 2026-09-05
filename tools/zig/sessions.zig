//! sessions: list saved conversations through the host session store
//! (ck_session, SQLite). Input: {} | {"format":"json"} | {"q":"..."}
//! Output: {"ok": true, "text": "<id>  <title>  <age>  per line, newest last>"}
//!         {"ok": true, "sessions": [...]} (format=json)
//!         {"ok": true, "query": ..., "truncated": bool, "hits": [...]} (search)

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("sessions_logic.zig");

const Listing = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
    workspace: []const u8 = "",
    archived: bool = false,
    messages: usize = 0,
    bytes: usize = 0,
};

const ListResponse = struct { sessions: []const Listing = &.{} };

const SearchHit = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    updated: i64 = 0,
    archived: bool = false,
    turn: usize = 0,
    role: []const u8 = "",
    snippet: []const u8 = "",
    more: usize = 0,
};

const SearchResponse = struct {
    ok: bool = true,
    query: []const u8 = "",
    truncated: bool = false,
    hits: []const SearchHit = &.{},
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const q = blk: {
        const raw_q = lib.optStr(req, "q") orelse lib.optStr(req, "args") orelse break :blk null;
        const trimmed = std.mem.trim(u8, raw_q, " \t\r\n");
        break :blk if (trimmed.len == 0) null else trimmed;
    };
    if (q) |query| {
        if (query.len < logic.search_min_len) return lib.fail(out, "query must be at least 3 characters");
        return searchSessions(out, query);
    }
    const as_json = if (lib.optStr(req, "format")) |fmt| std.mem.eql(u8, fmt, "json") else false;

    const raw: []const u8 = lib.sessionCall("{\"op\":\"list\"}") catch |err| switch (err) {
        error.NoAccess => "{\"sessions\":[]}",
        else => return lib.failErr(out, err, "listing sessions"),
    };
    const parsed = std.json.parseFromSliceLeaky(ListResponse, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "host listing unreadable");

    var metas: std.ArrayList(logic.Listing) = .empty;
    defer metas.deinit(lib.alloc);
    for (parsed.sessions) |row| {
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
    var wb: std.Io.Writer.Allocating = .init(lib.alloc);
    defer wb.deinit();
    var sj = std.json.Stringify{ .writer = &wb.writer, .options = .{} };
    try sj.beginObject();
    try sj.objectField("op");
    try sj.write("search");
    try sj.objectField("q");
    try sj.write(query);
    try sj.endObject();
    const raw = lib.sessionCall(wb.written()) catch |err| switch (err) {
        error.NoAccess => null,
        else => return lib.failErr(out, err, "searching sessions"),
    };
    const parsed = std.json.parseFromSliceLeaky(SearchResponse, lib.alloc, raw orelse "{\"hits\":[]}", .{ .ignore_unknown_fields = true }) catch
        return lib.fail(out, "host search unreadable");
    var hits: std.ArrayList(logic.SearchHit) = .empty;
    defer hits.deinit(lib.alloc);
    for (parsed.hits) |hit| {
        try hits.append(lib.alloc, .{
            .id = hit.id,
            .title = hit.title,
            .updated = hit.updated,
            .archived = hit.archived,
            .turn = hit.turn,
            .role = hit.role,
            .snippet = hit.snippet,
            .more = hit.more,
        });
    }
    var w2 = lib.writer(out);
    try logic.writeSearchJson(&w2, query, hits.items, parsed.truncated);
    lib.commit(out, &w2);
}
