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
    if (std.mem.eql(u8, action, "list")) {
        const has_filter = req.object.get("enabled") != null;
        if (has_filter) return doList(out, lib.optBool(req, "enabled", true));
        return doList(out, null);
    }
    if (std.mem.eql(u8, action, "set_enabled")) return doSetEnabled(req, out);
    if (std.mem.eql(u8, action, "add")) return doAdd(req, out);
    if (std.mem.eql(u8, action, "remove")) return doRemove(req, out);
    if (std.mem.eql(u8, action, "update")) return doUpdate(req, out);
    return lib.fail(out, "action must be list, set_enabled, add, remove, or update");
}

fn doList(out: *lib.Out, enabled_filter: ?bool) !void {
    const loaded = try load();
    if (enabled_filter) |f| {
        var filtered: std.ArrayList(Entry) = .empty;
        defer filtered.deinit(lib.alloc);
        for (loaded.entries.items) |e| {
            if (e.enabled == f) filtered.append(lib.alloc, e) catch continue;
        }
        return writeList(out, filtered.items);
    }
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
        var removed_entry: ?Entry = null;
        var i: usize = 0;
        while (i < loaded.entries.items.len) {
            if (std.mem.eql(u8, loaded.entries.items[i].id, id)) {
                removed_entry = loaded.entries.items[i];
                _ = loaded.entries.orderedRemove(i);
                break;
            } else i += 1;
        }
        const entry_val = removed_entry orelse return lib.fail(out, "no such entry");
        if (try store(loaded)) return writeOne(out, entry_val);
    }
    return lib.fail(out, "schedule file kept changing underneath; try again");
}

/// Modify fields of an existing entry without losing its identity (id,
/// created timestamp, run/failure counters). At least one mutable field must
/// be supplied; omitted fields are left untouched.
fn doUpdate(req: std.json.Value, out: *lib.Out) !void {
    const id = lib.optStr(req, "id") orelse return lib.fail(out, "update needs an id");
    if (!logic.validId(id)) return lib.fail(out, "bad entry id");

    const has_cron = req.object.get("cron") != null;
    const has_task = req.object.get("task") != null;
    const has_provider = req.object.get("provider") != null;
    const has_model = req.object.get("model") != null;
    const has_tz = req.object.get("tz_offset_minutes") != null;
    if (!has_cron and !has_task and !has_provider and !has_model and !has_tz)
        return lib.fail(out, "update needs at least one of: cron, task, provider, model, tz_offset_minutes");

    // Resolve the effective tz before validating the cron so firstFire sees
    // the correct offset.
    var new_tz: i32 = 0;
    if (has_tz) {
        const n_f: f64 = lib.optNum(req, "tz_offset_minutes") orelse return lib.fail(out, "tz_offset_minutes must be numeric");
        new_tz = @trunc(n_f);
    }

    var cron_text: []const u8 = "";
    if (has_cron) {
        cron_text = lib.optStr(req, "cron") orelse return lib.fail(out, "cron must be a string");
        const now: i64 = @trunc(lib.nowSeconds());
        if (logic.firstFire(cron_text, now, new_tz) == null)
            return lib.fail(out, "cron spec parses but never comes around, or is not a usable five-field spec");
    }

    var task_val: []const u8 = "";
    if (has_task) {
        const raw = lib.optStr(req, "task") orelse return lib.fail(out, "task must be a string");
        task_val = logic.validateTask(raw) catch |err| return lib.fail(out, switch (err) {
            error.TaskEmpty => "the task is empty",
            error.TaskTooLong => "the task is too long to schedule",
        });
    }

    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        var loaded = try load();
        const e = find(&loaded, id) orelse return lib.fail(out, "no such entry");
        if (has_cron) e.cron = cron_text;
        if (has_task) e.task = task_val;
        if (has_provider) e.provider = lib.optStr(req, "provider");
        if (has_model) e.model = lib.optStr(req, "model");
        if (has_tz) e.tz_offset_minutes = new_tz;
        if (try store(loaded)) return writeOne(out, e.*);
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
