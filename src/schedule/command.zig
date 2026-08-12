//! `clanker schedule <sub>` — the operator surface over `state/schedule.json`.
//!
//! Lives here rather than in `cli.zig` for the same reason `doctor.zig` and
//! `peers/phonebook.zig` do: `cli.zig` owns argument parsing and dispatch, and
//! a subsystem's own printing is not argument parsing. What `cli.zig` keeps is
//! the flag table, one dispatch arm, and the `Fire` callback that turns an
//! entry into an actual agent run — the one piece that has to reach back into
//! the run path.

const std = @import("std");
const cron = @import("cron.zig");
const store = @import("store.zig");
const runner = @import("runner.zig");
const log = @import("../util/log.zig");

pub const Options = struct {
    /// "list" (default), "add", "remove", "enable", "disable", "run-due",
    /// "run" or "log".
    sub: []const u8 = "list",
    /// `add`: the cron spec. Everything else: the entry id (or, for `log`, an
    /// optional record count).
    arg1: ?[]const u8 = null,
    /// `add`: the task text.
    arg2: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// `--tz-offset`, as accepted by `cron.parseOffset`.
    tz_offset: ?[]const u8 = null,
};

pub const Error = error{
    BadSubcommand,
    MissingArg,
    BadCron,
    NeverFires,
    /// At least one entry `run-due` fired came back an error. Distinct from
    /// the command itself failing: everything was recorded, and the non-zero
    /// exit is what tells the cron that invoked it to look.
    ScheduledRunFailed,
};

/// Records kept by the default `schedule log`.
const default_log_limit: usize = 20;
/// Task text is a prompt; a table is not the place to print all of it.
const task_column_bytes: usize = 44;

pub fn cmd(init: std.process.Init, opts: Options, fire: runner.Fire) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const base = std.Io.Dir.cwd();
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));

    const sub = opts.sub;
    if (std.mem.eql(u8, sub, "list")) return list(io, arena, base, now);
    if (std.mem.eql(u8, sub, "log")) return showLog(io, arena, base);
    if (std.mem.eql(u8, sub, "add")) return add(io, gpa, arena, base, opts, now);
    if (std.mem.eql(u8, sub, "remove")) return remove(io, gpa, arena, base, opts);
    if (std.mem.eql(u8, sub, "enable")) return setEnabled(io, gpa, arena, base, opts, true);
    if (std.mem.eql(u8, sub, "disable")) return setEnabled(io, gpa, arena, base, opts, false);
    if (std.mem.eql(u8, sub, "run-due")) return runDue(io, gpa, arena, base, now, fire);
    if (std.mem.eql(u8, sub, "run")) return runNow(io, gpa, arena, base, opts, now, fire);

    log.log(.error_, "unknown schedule subcommand '{s}' (expected list, add, remove, enable, disable, run, run-due or log)", .{sub});
    return Error.BadSubcommand;
}

// ------------------------------------------------------------------ reading --

fn list(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, now: i64) !void {
    const entries = try store.read(io, arena, base);
    if (entries.len == 0) {
        try out(io, "no scheduled entries. Add one with:\n  clanker schedule add \"*/30 * * * *\" \"summarize today's commits\"\n");
        return;
    }

    var w: std.Io.Writer.Allocating = .init(arena);
    defer w.deinit();
    try w.writer.print("{s: <8}{s: <6}{s: <16}{s: <18}{s: <13}{s: <7}{s}\n", .{ "ID", "STATE", "CRON", "NEXT", "LAST", "RUNS", "TASK" });
    for (entries) |e| {
        var next_buf: [32]u8 = undefined;
        var last_buf: [32]u8 = undefined;
        const next = nextText(&next_buf, e, now);
        const last = if (e.last_run > 0)
            cron.formatStamp(&last_buf, e.last_run, e.tz_offset_minutes)[5..]
        else
            "-";
        var runs_buf: [16]u8 = undefined;
        const runs = if (e.failures > 0)
            std.fmt.bufPrint(&runs_buf, "{d}/{d}!", .{ e.runs, e.failures }) catch "?"
        else
            std.fmt.bufPrint(&runs_buf, "{d}", .{e.runs}) catch "?";
        try w.writer.print("{s: <8}{s: <6}{s: <16}{s: <18}{s: <13}{s: <7}{s}\n", .{
            e.id,
            if (e.enabled) "on" else "off",
            e.cron,
            next,
            last,
            runs,
            ellipsize(e.task, task_column_bytes),
        });
    }

    // The offsets are per entry, so the table cannot carry one time zone in
    // its header; say it once here instead of on every row.
    var any_offset = false;
    for (entries) |e| {
        if (e.tz_offset_minutes != 0) any_offset = true;
    }
    try w.writer.writeAll(if (any_offset)
        "\nTimes are each entry's own --tz-offset. Fire the due ones with `clanker schedule run-due`.\n"
    else
        "\nTimes are UTC. Fire the due ones with `clanker schedule run-due`.\n");
    try out(io, w.written());
}

fn nextText(buf: []u8, e: store.Entry, now: i64) []const u8 {
    if (!e.enabled) return "(disabled)";
    const spec = cron.parse(e.cron) catch return "(bad spec)";
    const from = if (e.last_run > 0) e.last_run else e.created;
    const next = spec.nextAfter(from, e.tz_offset_minutes) orelse return "(never)";
    if (next <= now) return "due now";
    return cron.formatStamp(buf, next, e.tz_offset_minutes);
}

fn showLog(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) !void {
    const recs = try store.readRecords(io, arena, base, default_log_limit);
    if (recs.len == 0) {
        try out(io, "no scheduled runs recorded yet (" ++ store.ledger_path ++ ")\n");
        return;
    }
    var w: std.Io.Writer.Allocating = .init(arena);
    defer w.deinit();
    for (recs) |r| {
        var when: [32]u8 = undefined;
        try w.writer.print("{s}  {s: <8}{s: <8}{s: <7}{d: >6}ms  {s}", .{
            cron.formatStamp(&when, r.ts, 0),
            r.id,
            r.trigger,
            if (r.ok) "ok" else "FAILED",
            r.duration_ms,
            ellipsize(r.task, task_column_bytes),
        });
        if (r.skipped > 0) try w.writer.print("  (+{d} windows skipped)", .{r.skipped});
        if (r.err.len > 0) try w.writer.print("  [{s}]", .{r.err});
        try w.writer.writeByte('\n');
    }
    try w.writer.writeAll("\nTimes are UTC, newest first.\n");
    try out(io, w.written());
}

// ------------------------------------------------------------------ writing --

fn add(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, opts: Options, now: i64) !void {
    const spec_text = opts.arg1 orelse {
        log.log(.error_, "schedule add needs a cron spec and a task: clanker schedule add \"0 9 * * 1-5\" \"review yesterday's runs\"", .{});
        return Error.MissingArg;
    };
    const task_raw = opts.arg2 orelse {
        log.log(.error_, "schedule add needs a task after the cron spec", .{});
        return Error.MissingArg;
    };
    const task = store.validateTask(task_raw) catch |err| {
        log.log(.error_, "schedule add: {s}", .{switch (err) {
            store.Error.TaskEmpty => "the task is empty",
            store.Error.TaskTooLong => "the task is too long to schedule",
            else => @errorName(err),
        }});
        return err;
    };

    const spec = cron.parse(spec_text) catch |err| {
        log.log(.error_, "'{s}' is not a usable cron spec ({s}). Five fields: minute hour day-of-month month day-of-week, each `*`, a number, `a-b`, `*/n` or a comma-separated list", .{ spec_text, @errorName(err) });
        return Error.BadCron;
    };
    const offset = if (opts.tz_offset) |t| cron.parseOffset(t) catch {
        log.log(.error_, "--tz-offset wants something like +02:00, -05:00, UTC, or a number of minutes; got '{s}'", .{t});
        return Error.BadCron;
    } else 0;

    // A spec that parses but can never match (`0 0 30 2 *`) would sit in the
    // list forever looking scheduled. Refuse it at the point the mistake was
    // made rather than at the fire that never comes.
    const first = spec.nextAfter(now, offset) orelse {
        log.log(.error_, "'{s}' parses but never comes around (a date that does not exist, like February 30th)", .{spec_text});
        return Error.NeverFires;
    };

    var s = try store.open(io, gpa, arena, base);
    defer s.close();
    const id = try store.nextId(arena, s.entries.items);
    try s.entries.append(arena, .{
        .id = id,
        .cron = spec_text,
        .task = task,
        .provider = opts.provider,
        .model = opts.model,
        .tz_offset_minutes = offset,
        .created = now,
    });
    try s.save();

    var buf: [32]u8 = undefined;
    var line: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&line, "added {s}: {s} — first run {s}{s}\n", .{
        id,
        spec_text,
        cron.formatStamp(&buf, first, offset),
        if (offset == 0) " UTC" else "",
    }) catch "added\n";
    try out(io, msg);
    try out(io, "Nothing fires on its own: have cron (or a timer) call `clanker schedule run-due`.\n");
}

fn remove(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, opts: Options) !void {
    const id = try requireId(opts, "remove");
    var s = try store.open(io, gpa, arena, base);
    defer s.close();

    var kept: std.ArrayList(store.Entry) = .empty;
    var hit = false;
    for (s.entries.items) |e| {
        if (std.mem.eql(u8, e.id, id)) {
            hit = true;
            continue;
        }
        try kept.append(arena, e);
    }
    if (!hit) return noSuchEntry(id);
    s.entries = kept;
    try s.save();
    // The ledger keeps the removed entry's history on purpose: what ran is a
    // fact about the past, and deleting the schedule does not unmake it.
    var line: [128]u8 = undefined;
    try out(io, std.fmt.bufPrint(&line, "removed {s} (its ledger history stays in {s})\n", .{ id, store.ledger_path }) catch "removed\n");
}

fn setEnabled(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, opts: Options, on: bool) !void {
    const id = try requireId(opts, if (on) "enable" else "disable");
    var s = try store.open(io, gpa, arena, base);
    defer s.close();
    const e = s.find(id) orelse return noSuchEntry(id);
    // Re-enabling counts the window from now, not from whenever it was last
    // switched off: an entry parked for a month must not come back owing a run.
    if (on and !e.enabled) e.last_run = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    e.enabled = on;
    try s.save();
    var line: [128]u8 = undefined;
    try out(io, std.fmt.bufPrint(&line, "{s} is now {s}\n", .{ id, if (on) "enabled" else "disabled" }) catch "done\n");
}

// ------------------------------------------------------------------ running --

fn runDue(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, now: i64, fire: runner.Fire) !void {
    const summary = try runner.runDue(io, gpa, arena, base, now, fire);
    if (summary.busy) {
        // Not an error: a minute-by-minute cron overlapping a run that takes
        // longer than a minute is the expected shape, and exiting non-zero
        // would mail the operator about it every time.
        try out(io, "another `schedule run-due` is still working; nothing started\n");
        return;
    }
    if (summary.outcomes.len == 0) {
        var line: [128]u8 = undefined;
        try out(io, std.fmt.bufPrint(&line, "nothing due ({d} entr{s} scheduled)\n", .{ summary.considered, if (summary.considered == 1) "y" else "ies" }) catch "nothing due\n");
        return;
    }
    var failed: usize = 0;
    for (summary.outcomes) |o| {
        if (!o.ok) failed += 1;
        var line: [256]u8 = undefined;
        try out(io, std.fmt.bufPrint(&line, "{s}: {s} in {d}ms{s}\n", .{
            o.id,
            if (o.ok) "ok" else o.err,
            o.duration_ms,
            if (o.skipped > 0) " (skipped windows, see the ledger)" else "",
        }) catch "ran\n");
    }
    if (failed > 0) return Error.ScheduledRunFailed;
}

fn runNow(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir, opts: Options, now: i64, fire: runner.Fire) !void {
    const id = try requireId(opts, "run");
    const out_rec = runner.runOne(io, gpa, arena, base, id, now, fire) catch |err| switch (err) {
        store.Error.NoSuchEntry => return noSuchEntry(id),
        else => return err,
    };
    var line: [256]u8 = undefined;
    try out(io, std.fmt.bufPrint(&line, "{s}: {s} in {d}ms\n", .{ id, if (out_rec.ok) "ok" else out_rec.err, out_rec.duration_ms }) catch "ran\n");
    if (!out_rec.ok) return Error.ScheduledRunFailed;
}

// ------------------------------------------------------------------ helpers --

fn requireId(opts: Options, verb: []const u8) Error![]const u8 {
    const id = opts.arg1 orelse {
        log.log(.error_, "schedule {s} needs an entry id — `clanker schedule list` shows them", .{verb});
        return Error.MissingArg;
    };
    if (id.len == 0) return Error.MissingArg;
    return id;
}

fn noSuchEntry(id: []const u8) store.Error {
    log.log(.error_, "no scheduled entry '{s}' — `clanker schedule list` shows them", .{id});
    return store.Error.NoSuchEntry;
}

fn out(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

/// Truncates to `max` bytes on a UTF-8 boundary, with an ellipsis when it had
/// to cut. Byte-wise so a multibyte character in a prompt cannot leave a
/// dangling continuation byte in the table.
fn ellipsize(s: []const u8, max: usize) []const u8 {
    const flat = std.mem.trim(u8, s, " \t\r\n");
    // A newline in a prompt would break the row apart; cut at the first one.
    const first_line = flat[0..(std.mem.findScalar(u8, flat, '\n') orelse flat.len)];
    if (first_line.len <= max) return first_line;
    var end = max;
    while (end > 0 and (first_line[end] & 0xC0) == 0x80) end -= 1;
    return first_line[0..end];
}

// ------------------------------------------------------------------- tests --

const testing = std.testing;

test "ellipsize keeps a row on one line and never splits a codepoint" {
    try testing.expectEqualStrings("short", ellipsize("  short\n", 20));
    try testing.expectEqualStrings("first", ellipsize("first\nsecond", 20));
    try testing.expectEqualStrings("abcde", ellipsize("abcdefgh", 5));
    // "é" is two bytes; cutting at 3 must back up to 2 rather than leave half.
    try testing.expectEqualStrings("aé", ellipsize("aéb", 3));
    try testing.expectEqualStrings("", ellipsize("é", 1));
}

test "nextText says which kind of not-scheduled an entry is" {
    var buf: [32]u8 = undefined;
    const now = cron.epochFromCivil(2026, 8, 13, 12, 0, 0);
    try testing.expectEqualStrings("(disabled)", nextText(&buf, .{ .id = "a", .cron = "* * * * *", .task = "t", .enabled = false }, now));
    try testing.expectEqualStrings("(bad spec)", nextText(&buf, .{ .id = "a", .cron = "nope", .task = "t", .created = now }, now));
    try testing.expectEqualStrings("(never)", nextText(&buf, .{ .id = "a", .cron = "0 0 30 2 *", .task = "t", .created = now }, now));
    try testing.expectEqualStrings("due now", nextText(&buf, .{ .id = "a", .cron = "* * * * *", .task = "t", .created = now - 600 }, now));
    try testing.expectEqualStrings("2026-08-13 13:00", nextText(&buf, .{ .id = "a", .cron = "0 * * * *", .task = "t", .created = now }, now));
    // The stamp is rendered at the entry's own offset, so a UTC+2 entry shows
    // the local hour its spec was written in.
    try testing.expectEqualStrings("2026-08-13 15:00", nextText(&buf, .{ .id = "a", .cron = "0 * * * *", .task = "t", .created = now, .tz_offset_minutes = 120 }, now));
}
