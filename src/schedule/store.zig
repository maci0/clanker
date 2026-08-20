//! `state/schedule.json`, the list of scheduled entries, and
//! `state/schedule/log.jsonl`, the append-only record of what actually fired.
//!
//! Persistence follows the discipline the rest of `state/` already uses: a
//! read-modify-write is serialised by `util/file_lock.zig` on a lock file of its
//! own, and the write itself goes through `util/atomic_write.zig` so a process
//! killed mid-write leaves the old list intact rather than a truncated one.
//! Neither is optional here: `clanker schedule run-due` runs from cron, so two
//! invocations overlapping is the normal case rather than the unlucky one.
//!
//! Every path is taken relative to a `std.Io.Dir`, never resolved against the
//! process cwd inside this file, so the tests drive the real code against a
//! temp directory instead of a mock.

const std = @import("std");
const ensure_dir = @import("../util/ensure_dir.zig");
const file_lock = @import("../util/file_lock.zig");
const atomic_write = @import("../util/atomic_write.zig");
const log = @import("../util/log.zig");

pub const state_dir = "state";
pub const store_path = "state/schedule.json";
pub const ledger_dir = "state/schedule";
pub const ledger_path = "state/schedule/log.jsonl";

/// Cap on the store. A schedule is a handful of lines; anything near this is a
/// corrupt or hostile file, and reading it unbounded is how a state directory
/// takes the process down with it.
pub const max_store_bytes: usize = 1 << 20;
/// Cap on the ledger, trimmed oldest-first when exceeded. Same reasoning as
/// `state/notifications.jsonl`: a record nobody will ever read is not worth
/// unbounded disk.
pub const max_ledger_bytes: usize = 4 << 20;

/// Longest task text an entry may carry. The prompt is replayed on every fire,
/// so an unbounded one is an unbounded prompt cost, forever, on a timer.
pub const max_task_bytes: usize = 4000;

pub const Error = error{
    NoSuchEntry,
    TaskTooLong,
    TaskEmpty,
    /// `state/schedule.json` exists but could not be read back as an entry
    /// list. Every mutation rewrites the whole file, so this cannot be
    /// answered with an empty list: doing that turns one unreadable store
    /// into a `schedule add` that deletes every other entry. The operator is
    /// told to fix or move the file instead.
    StoreUnreadable,
};

/// One scheduled entry. Field names are the JSON keys; `state/schedule.json`
/// is a plain array of these and is meant to be readable and hand-editable.
pub const Entry = struct {
    id: []const u8,
    /// The 5-field spec, stored as written so `schedule list` can show the
    /// user their own text rather than a normalised re-rendering of it.
    cron: []const u8,
    /// The prompt handed to the agent, exactly as `clanker run` would take it.
    task: []const u8,
    /// Provider/model overrides, absent meaning "whatever the config says at
    /// fire time" rather than a snapshot of what it said at add time.
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// Minutes east of UTC that the cron fields are read at. See schedule_cron.zig:
    /// fixed, never a DST-aware zone.
    tz_offset_minutes: i32 = 0,
    enabled: bool = true,
    created: i64 = 0,
    /// Wall-clock second of the last fire, scheduled or manual, and the point
    /// the next fire is computed from. Deliberately the moment it ran and not
    /// the slot it ran for: that is what makes a machine that slept through a
    /// day of windows fire once on wake and then resume, instead of working
    /// through the backlog one window per invocation. See the missed-run
    /// policy in docs/prds/0009-schedule.md.
    last_run: i64 = 0,
    /// "", "ok" or "error", the outcome of that last fire.
    last_status: []const u8 = "",
    runs: u32 = 0,
    failures: u32 = 0,
};

/// One line of `state/schedule/log.jsonl`.
pub const Record = struct {
    ts: i64,
    id: []const u8,
    cron: []const u8,
    task: []const u8,
    /// "due" (fired by `run-due`) or "manual" (fired by `schedule run <id>`).
    trigger: []const u8,
    /// The fire window that made it due, or 0 for a manual run. Distinct from
    /// `ts`: cron granularity is a minute and `run-due` may be seconds late.
    due_at: i64 = 0,
    /// Windows that elapsed and were deliberately not backfilled.
    skipped: u32 = 0,
    ok: bool,
    duration_ms: u64 = 0,
    err: []const u8 = "",
};

/// The whole store plus the lock that serialises writing it back. Callers do
/// `var s = try open(...); defer s.close();` and then read `s.entries`,
/// mutate, and `try s.save()`. Holding the lock across the read and the write
/// is the point, a load/save pair that dropped it in between is exactly the
/// lost-update the lock exists to prevent.
pub const Session = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    guard: file_lock.Guard,
    entries: std.ArrayList(Entry),

    pub fn close(self: *Session) void {
        self.guard.release();
        self.entries.deinit(self.arena);
    }

    pub fn find(self: *const Session, id: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.id, id)) return e;
        }
        return null;
    }

    pub fn save(self: *Session) !void {
        try writeEntries(self.io, self.arena, self.base, self.entries.items);
    }
};

/// Takes the lock and reads the store. A *missing* file is an empty schedule
/// rather than a failure: `run-due` runs unattended from cron, and refusing to
/// start because nothing has been scheduled yet would be the wrong call. A
/// file that exists but cannot be read back is `Error.StoreUnreadable` — see
/// `readEntries`, and note that the caller goes on to `save()` over it.
pub fn open(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, base: std.Io.Dir) !Session {
    ensure_dir.ensureDir(base, io, state_dir) catch |err| {
        log.log(.warn, "schedule: could not create {s}: {s}", .{ state_dir, @errorName(err) });
    };
    var guard = file_lock.acquire(io, base, state_dir, "schedule", gpa);
    errdefer guard.release();

    var entries: std.ArrayList(Entry) = .empty;
    if (try readEntries(io, arena, base)) |parsed| try entries.appendSlice(arena, parsed);
    return .{ .io = io, .gpa = gpa, .arena = arena, .base = base, .guard = guard, .entries = entries };
}

/// The store, or null when there is no file yet. Only a missing file is an
/// empty schedule; an I/O error, a store past `max_store_bytes`, or JSON that
/// will not parse is `StoreUnreadable`, because `writeEntries` replaces the
/// whole file and an empty list here is persisted as a deletion of every
/// entry. The ledger append below already draws this line (`FileNotFound` vs
/// everything else, with read headroom over the trim cap); the store used to
/// swallow both and log "treating it as empty".
fn readEntries(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) !?[]Entry {
    const raw = base.readFileAlloc(io, store_path, arena, .limited(max_store_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            log.log(.error_, "schedule: cannot read {s}: {s}", .{ store_path, @errorName(err) });
            return Error.StoreUnreadable;
        },
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.json.parseFromSliceLeaky([]Entry, arena, trimmed, .{ .ignore_unknown_fields = true }) catch {
        log.log(.error_, "schedule: {s} is not a readable entry list; fix or move it", .{store_path});
        return Error.StoreUnreadable;
    };
}

/// Reads the store without taking the lock. For `schedule list` and anything
/// else that only displays: taking a write lock to print a table would block
/// behind a run that may take minutes.
pub fn read(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) ![]Entry {
    return (try readEntries(io, arena, base)) orelse &.{};
}

fn writeEntries(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, entries: []const Entry) !void {
    var enc: std.Io.Writer.Allocating = .init(arena);
    defer enc.deinit();
    // emit_null_optional_fields = false so an entry with no provider override
    // has no "provider" key at all, rather than a null a hand-editor has to
    // decide the meaning of.
    var s = std.json.Stringify{ .writer = &enc.writer, .options = .{ .whitespace = .indent_2, .emit_null_optional_fields = false } };
    try s.write(entries);
    try enc.writer.writeByte('\n');
    try atomic_write.writeFilePerms(io, base, store_path, enc.written(), atomic_write.private_file);
}

/// The next free `sch-N`. Sequential rather than a timestamp because these ids
/// are typed by hand into `schedule remove`/`enable`/`disable`; never reused,
/// because reusing the id of a removed entry would silently re-point a ledger
/// history at a different job.
pub fn nextId(arena: std.mem.Allocator, entries: []const Entry) ![]const u8 {
    var highest: u32 = 0;
    for (entries) |e| {
        if (!std.mem.startsWith(u8, e.id, "sch-")) continue;
        const n = std.fmt.parseInt(u32, e.id["sch-".len..], 10) catch continue;
        if (n > highest) highest = n;
    }
    return std.fmt.allocPrint(arena, "sch-{d}", .{highest + 1});
}

/// Appends one line to the ledger, trimming from the front when it outgrows
/// its cap. Best effort by design: losing the record of a run that happened is
/// bad, and refusing to run because the record could not be written is worse.
pub fn appendRecord(io: std.Io, gpa: std.mem.Allocator, base: std.Io.Dir, rec: Record) void {
    ensure_dir.ensureDir(base, io, ledger_dir) catch |err| {
        log.log(.warn, "schedule: could not create {s}: {s}", .{ ledger_dir, @errorName(err) });
        return;
    };
    var guard = file_lock.acquire(io, base, ledger_dir, "log", gpa);
    defer guard.release();

    var line: std.Io.Writer.Allocating = .init(gpa);
    defer line.deinit();
    var s = std.json.Stringify{ .writer = &line.writer, .options = .{} };
    s.write(rec) catch |err| {
        log.log(.warn, "schedule: could not encode ledger record: {s}", .{@errorName(err)});
        return;
    };

    // Headroom over the cap on purpose: the trim below is what brings an
    // over-cap file back under it, and a read limited to exactly the cap
    // refuses that file instead, so a ledger that ever grew past the cap
    // (an older build's larger cap, a hand-edit) could never be read again.
    //
    // `FileNotFound` is the only error that means "empty ledger". Every other
    // one means the history is on disk and this call cannot see it, and the
    // write below replaces the whole file: treating an unreadable ledger as an
    // absent one silently trades the entire audit trail for one record, and
    // reports success. Best effort is losing *this* record, never the file.
    const existing: ?[]u8 = base.readFileAlloc(io, ledger_path, gpa, .limited(2 * max_ledger_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            log.log(.warn, "schedule: could not read {s} ({s}); dropping this record rather than overwriting the history", .{ ledger_path, @errorName(err) });
            return;
        },
    };
    defer if (existing) |e| gpa.free(e);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (existing) |e| {
        out.appendSlice(gpa, e) catch |err| {
            log.log(.warn, "schedule: could not merge ledger: {s}", .{@errorName(err)});
            return;
        };
        if (e.len > 0 and e[e.len - 1] != '\n') out.append(gpa, '\n') catch |err| {
            log.log(.warn, "schedule: could not merge ledger: {s}", .{@errorName(err)});
            return;
        };
    }
    out.appendSlice(gpa, line.written()) catch |err| {
        log.log(.warn, "schedule: could not append ledger record: {s}", .{@errorName(err)});
        return;
    };
    out.append(gpa, '\n') catch |err| {
        log.log(.warn, "schedule: could not append ledger record: {s}", .{@errorName(err)});
        return;
    };

    if (out.items.len > max_ledger_bytes) {
        const floor = out.items.len - max_ledger_bytes;
        // Cut on a line boundary: half a JSON object is worse than one record
        // fewer, because every reader of this file splits on newlines.
        const newline = std.mem.findScalarPos(u8, out.items, floor, '\n') orelse floor;
        const drop = @min(newline + 1, out.items.len);
        std.mem.copyForwards(u8, out.items[0 .. out.items.len - drop], out.items[drop..]);
        out.shrinkRetainingCapacity(out.items.len - drop);
    }
    // Owner-only like the store itself: ledger records carry the scheduled
    // task text, so a world-readable ledger is the same exposure as a
    // world-readable store.
    atomic_write.writeFilePerms(io, base, ledger_path, out.items, atomic_write.private_file) catch |err| {
        log.log(.warn, "schedule: could not append to {s}: {s}", .{ ledger_path, @errorName(err) });
    };
}

/// The ledger, newest first, capped at `limit` records. Unparseable lines are
/// skipped rather than failing the read: one bad line must not hide the rest
/// of the history.
pub fn readRecords(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, limit: usize) ![]Record {
    const raw = base.readFileAlloc(io, ledger_path, arena, .limited(2 * max_ledger_bytes)) catch return &.{};
    var all: std.ArrayList(Record) = .empty;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const rec = std.json.parseFromSliceLeaky(Record, arena, trimmed, .{ .ignore_unknown_fields = true }) catch continue;
        try all.append(arena, rec);
    }
    std.mem.reverse(Record, all.items);
    if (all.items.len > limit) return all.items[0..limit];
    return all.items;
}

/// Validates the parts of an entry that are the caller's to get wrong, before
/// anything is written. `cron.parse` covers the spec; this covers the rest.
pub fn validateTask(task: []const u8) Error![]const u8 {
    const trimmed = std.mem.trim(u8, task, " \t\r\n");
    if (trimmed.len == 0) return Error.TaskEmpty;
    if (trimmed.len > max_task_bytes) return Error.TaskTooLong;
    return trimmed;
}

// ------------------------------------------------------------------- tests --

const testing = std.testing;

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(testing.allocator, .{});
}

test "an empty state directory reads as an empty schedule, not an error" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var s = try open(io, testing.allocator, arena_state.allocator(), tmp.dir);
    defer s.close();
    try testing.expectEqual(@as(usize, 0), s.entries.items.len);
    try testing.expectEqual(@as(usize, 0), (try read(io, arena_state.allocator(), tmp.dir)).len);
}

test "entries round-trip through the store, keeping absent overrides absent" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        var s = try open(io, testing.allocator, arena, tmp.dir);
        defer s.close();
        try s.entries.append(arena, .{ .id = "sch-1", .cron = "*/5 * * * *", .task = "say hi", .created = 100, .last_run = 100 });
        try s.entries.append(arena, .{ .id = "sch-2", .cron = "0 9 * * 1-5", .task = "standup", .provider = "deepseek", .tz_offset_minutes = 120, .enabled = false, .created = 200 });
        try s.save();
    }

    const raw = try tmp.dir.readFileAlloc(io, store_path, arena, .limited(max_store_bytes));
    // A no-override entry has no key at all, so the file stays hand-editable.
    try testing.expect(std.mem.find(u8, raw, "\"provider\": \"deepseek\"") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, raw, "\"provider\""));

    const back = try read(io, arena, tmp.dir);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("sch-1", back[0].id);
    try testing.expectEqual(@as(?[]const u8, null), back[0].provider);
    try testing.expectEqual(true, back[0].enabled);
    try testing.expectEqualStrings("deepseek", back[1].provider.?);
    try testing.expectEqual(@as(i32, 120), back[1].tz_offset_minutes);
    try testing.expectEqual(false, back[1].enabled);
}

test "the schedule store and its ledger are owner-only (0600)" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    {
        var s = try open(io, testing.allocator, arena, tmp.dir);
        defer s.close();
        try s.entries.append(arena, .{ .id = "sch-1", .cron = "* * * * *", .task = "say hi", .created = 100 });
        try s.save();
    }
    const st_store = try tmp.dir.statFile(io, store_path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), @as(std.posix.mode_t, @intFromEnum(st_store.permissions)) & 0o777);

    appendRecord(io, testing.allocator, tmp.dir, .{ .ts = 100, .id = "sch-1", .cron = "* * * * *", .task = "say hi", .trigger = "due", .ok = true });
    const st_ledger = try tmp.dir.statFile(io, ledger_path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), @as(std.posix.mode_t, @intFromEnum(st_ledger.permissions)) & 0o777);
}

test "a corrupt store refuses the command instead of reading as empty" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try tmp.dir.createDirPath(io, state_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = store_path, .data = "{ not json" });

    // Reading it as empty is not a safe degradation: every mutation rewrites
    // the whole file, so the next `schedule add` would persist the empty list
    // and drop every entry the operator had. Both the write path and the
    // display path say so rather than showing an empty schedule.
    try testing.expectError(Error.StoreUnreadable, open(io, testing.allocator, arena, tmp.dir));
    try testing.expectError(Error.StoreUnreadable, read(io, arena, tmp.dir));

    // And the file the operator has to fix is still there, untouched.
    const raw = try tmp.dir.readFileAlloc(io, store_path, arena, .limited(max_store_bytes));
    try testing.expectEqualStrings("{ not json", raw);
}

test "an empty or missing store is the one read that means no entries" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(@as(usize, 0), (try read(io, arena, tmp.dir)).len);
    try tmp.dir.createDirPath(io, state_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = store_path, .data = "  \n" });
    try testing.expectEqual(@as(usize, 0), (try read(io, arena, tmp.dir)).len);
}

test "ids are sequential and never reuse a removed one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("sch-1", try nextId(arena, &.{}));
    const two = [_]Entry{
        .{ .id = "sch-1", .cron = "* * * * *", .task = "a" },
        .{ .id = "sch-2", .cron = "* * * * *", .task = "b" },
    };
    try testing.expectEqualStrings("sch-3", try nextId(arena, &two));
    // sch-2 removed: the next id is still 3, so the ledger's "sch-2" keeps
    // meaning the job it meant.
    const gap = [_]Entry{two[1]};
    try testing.expectEqualStrings("sch-3", try nextId(arena, &gap));
    // A hand-written id that is not sch-N does not derail the counter.
    const named = [_]Entry{.{ .id = "nightly", .cron = "* * * * *", .task = "a" }};
    try testing.expectEqualStrings("sch-1", try nextId(arena, &named));
}

test "the ledger appends one JSON line per fire and reads back newest first" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    appendRecord(io, testing.allocator, tmp.dir, .{ .ts = 100, .id = "sch-1", .cron = "* * * * *", .task = "a", .trigger = "due", .due_at = 60, .ok = true, .duration_ms = 5 });
    appendRecord(io, testing.allocator, tmp.dir, .{ .ts = 200, .id = "sch-1", .cron = "* * * * *", .task = "a", .trigger = "manual", .ok = false, .err = "provider refused" });

    const raw = try tmp.dir.readFileAlloc(io, ledger_path, arena, .limited(max_ledger_bytes));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, raw, "\n"));

    const recs = try readRecords(io, arena, tmp.dir, 10);
    try testing.expectEqual(@as(usize, 2), recs.len);
    try testing.expectEqual(@as(i64, 200), recs[0].ts);
    try testing.expectEqualStrings("manual", recs[0].trigger);
    try testing.expectEqualStrings("provider refused", recs[0].err);
    try testing.expect(!recs[0].ok);
    try testing.expectEqual(@as(i64, 60), recs[1].due_at);
    try testing.expect(recs[1].ok);

    // A garbage line costs its own record and no more.
    const with_junk = try std.fmt.allocPrint(arena, "{s}not json\n", .{raw});
    try tmp.dir.writeFile(io, .{ .sub_path = ledger_path, .data = with_junk });
    try testing.expectEqual(@as(usize, 2), (try readRecords(io, arena, tmp.dir, 10)).len);
}

test "a ledger already over the cap is trimmed, never replaced by the one new record" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try ensure_dir.ensureDir(tmp.dir, io, ledger_dir);

    // Fill past the cap, then put a recognisable record last so front-trimming
    // keeps it. A read limited to exactly the cap refuses this file, and the
    // append then writes its single line over all of it.
    const filler = "{\"ts\":1,\"id\":\"sch-0\",\"cron\":\"* * * * *\",\"task\":\"old\",\"trigger\":\"due\",\"ok\":true}\n";
    var pre: std.ArrayList(u8) = .empty;
    defer pre.deinit(testing.allocator);
    while (pre.items.len <= max_ledger_bytes) try pre.appendSlice(testing.allocator, filler);
    try pre.appendSlice(testing.allocator, "{\"ts\":999,\"id\":\"sch-9\",\"cron\":\"* * * * *\",\"task\":\"kept\",\"trigger\":\"due\",\"ok\":true}\n");
    try tmp.dir.writeFile(io, .{ .sub_path = ledger_path, .data = pre.items });

    appendRecord(io, testing.allocator, tmp.dir, .{ .ts = 1000, .id = "sch-1", .cron = "* * * * *", .task = "new", .trigger = "due", .ok = true });

    const raw = try tmp.dir.readFileAlloc(io, ledger_path, arena, .limited(2 * max_ledger_bytes));
    try testing.expect(raw.len <= max_ledger_bytes);
    try testing.expect(raw.len > filler.len * 2);

    const recs = try readRecords(io, arena, tmp.dir, 4);
    try testing.expectEqual(@as(i64, 1000), recs[0].ts);
    try testing.expectEqual(@as(i64, 999), recs[1].ts);
}

test "an unreadable ledger costs the new record, not the whole history" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // A directory where the ledger file belongs: readFileAlloc fails with
    // something other than FileNotFound, which must not read as "no history".
    try ensure_dir.ensureDir(tmp.dir, io, ledger_path);
    appendRecord(io, testing.allocator, tmp.dir, .{ .ts = 1, .id = "sch-1", .cron = "* * * * *", .task = "t", .trigger = "due", .ok = true });

    // Still a directory, so nothing was written through it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 0), (try readRecords(io, arena_state.allocator(), tmp.dir, 4)).len);
}

test "a task must be non-empty and bounded" {
    try testing.expectEqualStrings("hi", try validateTask("  hi\n"));
    try testing.expectError(Error.TaskEmpty, validateTask("   "));
    const huge = "x" ** (max_task_bytes + 1);
    try testing.expectError(Error.TaskTooLong, validateTask(huge));
}

test "concurrent writers through the lock do not lose entries" {
    // The failure this pins is silent: without the lock both writers read the
    // same list, and the second write drops the first writer's entry, leaving
    // a well-formed file that is merely short.
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const Worker = struct {
        dir: std.Io.Dir,
        io: std.Io,
        base: usize,
        failures: u32 = 0,
        fn go(self: *@This()) void {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                var a = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer a.deinit();
                const arena = a.allocator();
                var s = open(self.io, std.testing.allocator, arena, self.dir) catch {
                    self.failures += 1;
                    continue;
                };
                defer s.close();
                const id = std.fmt.allocPrint(arena, "sch-{d}", .{self.base + i}) catch {
                    self.failures += 1;
                    continue;
                };
                s.entries.append(arena, .{ .id = id, .cron = "* * * * *", .task = "t" }) catch {
                    self.failures += 1;
                    continue;
                };
                s.save() catch {
                    self.failures += 1;
                };
            }
        }
    };

    var workers: [4]Worker = undefined;
    var threads: [4]std.Thread = undefined;
    for (&workers, 0..) |*w, i| {
        w.* = .{ .dir = tmp.dir, .io = io, .base = 1 + i * 100 };
        threads[i] = try std.Thread.spawn(.{}, Worker.go, .{w});
    }
    for (&threads) |*t| t.join();
    for (&workers) |*w| try testing.expectEqual(@as(u32, 0), w.failures);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const final = try read(io, arena_state.allocator(), tmp.dir);
    try testing.expectEqual(@as(usize, 40), final.len);
}
