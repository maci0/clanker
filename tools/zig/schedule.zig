//! schedule: list and edit recurring agent runs (state/schedule.json).
//! Input:  {"action":"list"}
//!         {"action":"set_enabled","id":"sch-1","enabled":false}
//!         {"action":"add","cron":"0 9 * * 1-5","task":"..."}
//!         {"action":"remove","id":"sch-1"}
//! Output: {"ok":true,"entries":[...],"log":[...]} | {"ok":true,"entry":{...}}
//!
//! The store is the same file `clanker schedule` and `/api/schedule` use.
//! Firing (`run` / `run-due`) stays native: that is an agent run.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("schedule_logic.zig");

const store_path = "state/schedule.json";
const ledger_path = "state/schedule/log.jsonl";

const Entry = struct {
    id: []const u8,
    cron: []const u8,
    task: []const u8,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    tz_offset_minutes: i32 = 0,
    enabled: bool = true,
    created: i64 = 0,
    last_run: i64 = 0,
    last_status: []const u8 = "",
    runs: u32 = 0,
    failures: u32 = 0,
};

const Record = struct {
    ts: i64 = 0,
    id: []const u8 = "",
    cron: []const u8 = "",
    task: []const u8 = "",
    trigger: []const u8 = "",
    ok: bool = false,
    duration_ms: u64 = 0,
    skipped: u32 = 0,
    err: []const u8 = "",
};

const Loaded = struct {
    entries: std.ArrayList(Entry),
    seen_hash: []const u8,
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const req = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const action = lib.optStr(req, "action") orelse "list";
    if (std.mem.eql(u8, action, "list")) return doList(out);
    if (std.mem.eql(u8, action, "set_enabled")) return doSetEnabled(req, out);
    if (std.mem.eql(u8, action, "add")) return doAdd(req, out);
    if (std.mem.eql(u8, action, "remove")) return doRemove(req, out);
    return lib.fail(out, "action must be list, set_enabled, add, or remove");
}

fn doList(out: *lib.Out) !void {
    const loaded = try load();
    return writeList(out, loaded.entries.items);
}

fn doSetEnabled(req: std.json.Value, out: *lib.Out) !void {
    const id = lib.optStr(req, "id") orelse return lib.fail(out, "set_enabled needs an id");
    if (!logic.validId(id)) return lib.fail(out, "bad entry id");
    if (req.object.get("enabled") == null) return lib.fail(out, "set_enabled needs enabled");
    const enabled = lib.optBool(req, "enabled", false);
    const now: i64 = @trunc(lib.nowSeconds());

    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        var loaded = try load();
        const e = find(&loaded, id) orelse return lib.fail(out, "no such entry");
        if (enabled and !e.enabled) e.last_run = now;
        e.enabled = enabled;
        if (try store(loaded)) return writeOne(out, e.*);
    }
    return lib.fail(out, "schedule file kept changing underneath; try again");
}

fn doAdd(req: std.json.Value, out: *lib.Out) !void {
    const cron_text = lib.optStr(req, "cron") orelse return lib.fail(out, "add needs a cron spec");
    const task_raw = lib.optStr(req, "task") orelse return lib.fail(out, "add needs a task");
    const task = logic.validateTask(task_raw) catch |err| return lib.fail(out, switch (err) {
        error.TaskEmpty => "the task is empty",
        error.TaskTooLong => "the task is too long to schedule",
    });
    const tz: i32 = blk: {
        const n_f: f64 = lib.optNum(req, "tz_offset_minutes") orelse break :blk 0;
        break :blk @trunc(n_f);
    };
    const now: i64 = @trunc(lib.nowSeconds());
    if (logic.firstFire(cron_text, now, tz) == null)
        return lib.fail(out, "cron spec parses but never comes around, or is not a usable five-field spec");

    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        var loaded = try load();
        var ids: std.ArrayList([]const u8) = .empty;
        for (loaded.entries.items) |e| ids.append(lib.alloc, e.id) catch continue;
        const id = try logic.nextId(lib.alloc, ids.items);
        const entry = Entry{
            .id = id,
            .cron = cron_text,
            .task = task,
            .provider = lib.optStr(req, "provider"),
            .model = lib.optStr(req, "model"),
            .tz_offset_minutes = tz,
            .created = now,
        };
        try loaded.entries.append(lib.alloc, entry);
        if (try store(loaded)) return writeOne(out, entry);
    }
    return lib.fail(out, "schedule file kept changing underneath; try again");
}

fn doRemove(req: std.json.Value, out: *lib.Out) !void {
    const id = lib.optStr(req, "id") orelse return lib.fail(out, "remove needs an id");
    if (!logic.validId(id)) return lib.fail(out, "bad entry id");

    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        var loaded = try load();
        var found = false;
        var i: usize = 0;
        while (i < loaded.entries.items.len) {
            if (std.mem.eql(u8, loaded.entries.items[i].id, id)) {
                _ = loaded.entries.orderedRemove(i);
                found = true;
            } else i += 1;
        }
        if (!found) return lib.fail(out, "no such entry");
        if (try store(loaded)) return out.writeAll("{\"ok\":true}");
    }
    return lib.fail(out, "schedule file kept changing underneath; try again");
}

fn find(loaded: *Loaded, id: []const u8) ?*Entry {
    for (loaded.entries.items) |*e| {
        if (std.mem.eql(u8, e.id, id)) return e;
    }
    return null;
}

fn load() !Loaded {
    var result: Loaded = .{ .entries = .empty, .seen_hash = "" };
    const raw = lib.fsRead(store_path) catch |err| switch (err) {
        error.NotFound => return result,
        else => return err,
    };
    result.seen_hash = try lib.hash(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return result;
    const parsed = std.json.parseFromSliceLeaky([]Entry, lib.alloc, trimmed, .{ .ignore_unknown_fields = true }) catch
        return result;
    try result.entries.appendSlice(lib.alloc, parsed);
    return result;
}

fn store(loaded: Loaded) !bool {
    var enc: std.Io.Writer.Allocating = .init(lib.alloc);
    // Pretty-printed, no null optionals: the same shape the native store
    // writes, so a hand-edit and a guest write stay interchangeable.
    var s = std.json.Stringify{ .writer = &enc.writer, .options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false } };
    try s.write(loaded.entries.items);
    try enc.writer.writeByte('\n');
    lib.fsWriteIf(store_path, loaded.seen_hash, enc.written()) catch |err| switch (err) {
        error.Mismatch => return false,
        else => return err,
    };
    return true;
}

fn writeList(out: *lib.Out, entries: []const Entry) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("entries");
    try s.beginArray();
    for (entries) |e| try writeEntry(&s, e);
    try s.endArray();
    try s.objectField("log");
    try s.beginArray();
    try writeLog(&s);
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

fn writeOne(out: *lib.Out, e: Entry) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("entry");
    try writeEntry(&s, e);
    try s.endObject();
    lib.commit(out, &w);
}

fn writeEntry(s: *std.json.Stringify, e: Entry) !void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(e.id);
    try s.objectField("cron");
    try s.write(e.cron);
    try s.objectField("task");
    try s.write(e.task);
    if (e.provider) |p| {
        try s.objectField("provider");
        try s.write(p);
    }
    if (e.model) |m| {
        try s.objectField("model");
        try s.write(m);
    }
    try s.objectField("tz_offset_minutes");
    try s.write(e.tz_offset_minutes);
    try s.objectField("enabled");
    try s.write(e.enabled);
    try s.objectField("created");
    try s.write(e.created);
    try s.objectField("last_run");
    try s.write(e.last_run);
    try s.objectField("last_status");
    try s.write(e.last_status);
    try s.objectField("runs");
    try s.write(e.runs);
    try s.objectField("failures");
    try s.write(e.failures);
    if (logic.nextRun(e.enabled, e.cron, e.last_run, e.created, e.tz_offset_minutes)) |next| {
        try s.objectField("next_run");
        try s.write(next);
    }
    try s.endObject();
}

fn writeLog(s: *std.json.Stringify) !void {
    const raw = lib.fsReadTail(ledger_path, 64 * 1024) catch return;
    var recs: std.ArrayList(Record) = .empty;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const rec = std.json.parseFromSliceLeaky(Record, lib.alloc, trimmed, .{ .ignore_unknown_fields = true }) catch continue;
        recs.append(lib.alloc, rec) catch continue;
    }
    std.mem.reverse(Record, recs.items);
    const n = @min(recs.items.len, logic.max_log_records);
    for (recs.items[0..n]) |r| {
        try s.beginObject();
        try s.objectField("ts");
        try s.write(r.ts);
        try s.objectField("id");
        try s.write(r.id);
        try s.objectField("cron");
        try s.write(r.cron);
        try s.objectField("task");
        try s.write(r.task);
        try s.objectField("trigger");
        try s.write(r.trigger);
        try s.objectField("ok");
        try s.write(r.ok);
        try s.objectField("duration_ms");
        try s.write(r.duration_ms);
        if (r.skipped > 0) {
            try s.objectField("skipped");
            try s.write(r.skipped);
        }
        if (r.err.len > 0) {
            try s.objectField("err");
            try s.write(r.err);
        }
        try s.endObject();
    }
}
