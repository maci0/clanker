//! prompts: CRUD over state/prompts.json (saved prompt templates).
//! Moved from src/prompts/store.zig to the WASM sandbox so the harness
//! enforces fs_prefixes rather than granting whole-process access.
//!
//! Actions:
//!   list                         -> {ok, prompts:[{id,title,content,created,updated}]}
//!   create {title, content}      -> {ok, id}
//!   update {id, title?, content?} -> {ok, id}
//!   delete {id}                  -> {ok}

const std = @import("std");
const lib = @import("lib.zig");

extern fn ck_random() u64;

const store_path = "state/prompts.json";

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const obj = try lib.object(input);
    const action = lib.optStr(obj, "action") orelse "list";

    if (std.mem.eql(u8, action, "list")) return actionList(out);
    if (std.mem.eql(u8, action, "create")) return actionCreate(obj, out);
    if (std.mem.eql(u8, action, "update")) return actionUpdate(obj, out);
    if (std.mem.eql(u8, action, "delete")) return actionDelete(obj, out);
    try lib.fail(out, "unknown action");
}

// ----------------------------------------------------------------- helpers ---

const StoredPrompt = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    content: []const u8 = "",
    created: i64 = 0,
    updated: i64 = 0,
};

fn newId() []const u8 {
    const r = ck_random();
    return std.fmt.allocPrint(lib.alloc, "pr-{x}", .{r & 0xffffffffffff}) catch "pr-0";
}

fn nowSec() i64 {
    return @intFromFloat(lib.nowSeconds());
}

fn isSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

fn loadAll() []StoredPrompt {
    const raw = lib.fsRead(store_path) catch return &.{};
    return std.json.parseFromSliceLeaky([]StoredPrompt, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch &.{};
}

fn saveAll(prompts: []const StoredPrompt) !void {
    var buf: std.Io.Writer.Allocating = .init(lib.alloc);
    defer buf.deinit();
    var s = std.json.Stringify{ .writer = &buf.writer, .options = .{} };
    try s.beginArray();
    for (prompts) |p| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(p.id);
        try s.objectField("title");
        try s.write(p.title);
        try s.objectField("content");
        try s.write(p.content);
        try s.objectField("created");
        try s.write(p.created);
        try s.objectField("updated");
        try s.write(p.updated);
        try s.endObject();
    }
    try s.endArray();
    try lib.fsWrite(store_path, buf.written());
}

// ----------------------------------------------------------------- actions ---

fn actionList(out: *lib.Out) !void {
    const all = loadAll();
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("prompts");
    try s.beginArray();
    for (all) |p| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(p.id);
        try s.objectField("title");
        try s.write(p.title);
        try s.objectField("content");
        try s.write(p.content);
        try s.objectField("created");
        try s.write(p.created);
        try s.objectField("updated");
        try s.write(p.updated);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

fn actionCreate(obj: std.json.Value, out: *lib.Out) !void {
    const title = lib.optStr(obj, "title") orelse return lib.fail(out, "create needs title");
    const content = lib.optStr(obj, "content") orelse return lib.fail(out, "create needs content");
    if (title.len == 0 or title.len > 200) return lib.fail(out, "title required (1-200)");
    if (content.len == 0 or content.len > 20000) return lib.fail(out, "content required (1-20000)");

    const all = loadAll();
    const t = nowSec();
    const id = newId();
    var list: std.ArrayList(StoredPrompt) = .empty;
    list.appendSlice(lib.alloc, all) catch return lib.fail(out, "alloc");
    list.append(lib.alloc, .{ .id = id, .title = title, .content = content, .created = t, .updated = t }) catch return lib.fail(out, "alloc");
    saveAll(list.items) catch return lib.fail(out, "save failed");

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("id");
    try s.write(id);
    try s.endObject();
    lib.commit(out, &w);
}

fn actionUpdate(obj: std.json.Value, out: *lib.Out) !void {
    const id = lib.optStr(obj, "id") orelse return lib.fail(out, "update needs id");
    if (!isSlug(id)) return lib.fail(out, "bad id");
    const title = lib.optStr(obj, "title");
    const content = lib.optStr(obj, "content");

    const all = loadAll();
    var found = false;
    for (all) |*p| {
        if (std.mem.eql(u8, p.id, id)) {
            if (title) |t| p.title = t;
            if (content) |c| p.content = c;
            p.updated = nowSec();
            found = true;
            break;
        }
    }
    if (!found) return lib.fail(out, "no such prompt");
    saveAll(all) catch return lib.fail(out, "save failed");

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("id");
    try s.write(id);
    try s.endObject();
    lib.commit(out, &w);
}

fn actionDelete(obj: std.json.Value, out: *lib.Out) !void {
    const id = lib.optStr(obj, "id") orelse return lib.fail(out, "delete needs id");
    if (!isSlug(id)) return lib.fail(out, "bad id");

    const all = loadAll();
    var kept: std.ArrayList(StoredPrompt) = .empty;
    var found = false;
    for (all) |p| {
        if (std.mem.eql(u8, p.id, id)) {
            found = true;
        } else {
            kept.append(lib.alloc, p) catch continue;
        }
    }
    if (!found) return lib.fail(out, "no such prompt");
    saveAll(kept.items) catch return lib.fail(out, "save failed");

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.endObject();
    lib.commit(out, &w);
}
