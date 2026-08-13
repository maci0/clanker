//! Deciding what is due and firing it. The half of `clanker schedule` that has
//! a clock but still no opinion about what a "run" is: the caller passes a
//! `Fire` callback, so the tests drive the real due/claim/ledger logic with a
//! stub that records what it was asked to run instead of spending a provider
//! call to find out.
//!
//! **Missed runs fire once, never backfilled.** A machine that slept through a
//! day of a `*/5` entry's windows fires that entry exactly once on wake and
//! then resumes on the normal grid; the 287 windows it slept through are
//! counted into the ledger's `skipped` and otherwise discarded. Backfilling
//! them would mean 288 agent runs, most of them answering a question that
//! stopped being interesting hours ago, on a bill that is real. The mechanism
//! is `Entry.last_run` holding the moment the entry *ran* rather than the slot
//! it ran *for*, so the next window is computed from wake time.
//!
//! **A claimed window is not re-fired.** `run-due` writes the claim to
//! `state/schedule.json` before it calls the model, not after, so a run killed
//! halfway leaves the entry looking like it fired. At-most-once beats
//! at-least-once here for the same reason as above: the failure mode of the
//! other choice is a crash loop that bills per iteration.

const std = @import("std");
const cron = @import("cron.zig");
const store = @import("store.zig");
const filelock = @import("../util/filelock.zig");
const log = @import("../util/log.zig");

/// Held for the whole of one `run-due`, so a cron that fires every minute
/// cannot start a second sweep on top of a first one still waiting on a model.
/// Non-blocking: a second invocation reports that it is already running and
/// exits, rather than queueing up behind it until the machine is full of them.
pub const run_lock_path = store.ledger_dir ++ "/run-due.lock";

/// How many elapsed windows `skipped` will count before it gives up and
/// reports the cap. The number exists for the operator's benefit ("this slept
/// through a lot"); counting a year of `* * * * *` exactly is half a million
/// steps for a digit nobody reads.
pub const max_skipped_count: u32 = 500;

/// What the caller does when an entry fires. `ctx` is the caller's own state
/// (in the CLI: the process init and the parsed options); the runner never
/// looks inside it.
pub const Fire = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, entry: *const store.Entry) anyerror!void,
};

pub const Outcome = struct {
    id: []const u8,
    /// The window that made it due, or 0 for a manual run.
    due_at: i64,
    skipped: u32,
    ok: bool,
    err: []const u8,
    duration_ms: u64,
};

pub const Summary = struct {
    /// Another `run-due` holds the lock; nothing was inspected or fired.
    busy: bool = false,
    /// Entries in the store, whether due or not.
    considered: usize = 0,
    outcomes: []const Outcome = &.{},
};

pub const Error = error{Busy};

/// The window that makes `entry` due at `now`, or null when it is not due.
/// Pure apart from the warning: a disabled entry, an unparseable spec, and a
/// spec whose next window is still ahead all answer the same way.
pub fn dueAt(entry: store.Entry, now: i64) ?i64 {
    if (!entry.enabled) return null;
    const spec = cron.parse(entry.cron) catch {
        // Hand-edited into the file, most likely. Warn every sweep rather
        // than once: an entry that silently never fires is the failure this
        // whole subsystem exists to prevent.
        log.log(.warn, "schedule: entry {s} has an unusable spec '{s}'; it will never fire", .{ entry.id, entry.cron });
        return null;
    };
    // An entry that has never run counts from when it was added, so adding one
    // at 12:03 does not fire it instantly, the first run is the first real
    // window after the add.
    const from = if (entry.last_run > 0) entry.last_run else entry.created;
    const next = spec.nextAfter(from, entry.tz_offset_minutes) orelse return null;
    if (next > now) return null;
    return next;
}

/// Windows that elapsed between the one being fired and now, and are being
/// dropped rather than backfilled.
///
/// Open at both ends. `due` itself is the window this fire serves, and a
/// window landing exactly on `now` is served by it too: the claim sets
/// `last_run = now` and the next fire is computed strictly after that, so
/// nothing is left owing. Counting `now` would make an every-minute entry
/// fired by an every-minute cron report one skipped window on every single
/// run, which is a number that means nothing.
pub fn skippedSince(entry: store.Entry, due: i64, now: i64) u32 {
    const spec = cron.parse(entry.cron) catch return 0;
    return cron.countBetween(spec, due, now - 1, entry.tz_offset_minutes, max_skipped_count);
}

/// Fires every entry whose window has passed. One sweep: claim, run, record.
pub fn runDue(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    now: i64,
    fire: Fire,
) !Summary {
    var lock = acquireRunLock(io, base) catch |err| switch (err) {
        Error.Busy => {
            log.log(.info, "schedule: another run-due is still working; nothing started", .{});
            return .{ .busy = true };
        },
        else => return err,
    };
    defer lock.close(io);

    // Phase one: claim. The store lock is taken, the due set is decided and
    // written back as already-run, and the lock is dropped, all before the
    // first model call. Holding it across a run that takes minutes would block
    // `schedule add` for those minutes, and dropping the claim until after the
    // run would let a killed sweep fire the same window twice.
    const Claim = struct { entry: store.Entry, due_at: i64, skipped: u32 };
    var claims: std.ArrayList(Claim) = .empty;
    var considered: usize = 0;
    {
        var s = try store.open(io, gpa, arena, base);
        defer s.close();
        considered = s.entries.items.len;
        for (s.entries.items) |*e| {
            const due = dueAt(e.*, now) orelse continue;
            try claims.append(arena, .{ .entry = e.*, .due_at = due, .skipped = skippedSince(e.*, due, now) });
            e.last_run = now;
            e.runs += 1;
            e.last_status = "running";
        }
        if (claims.items.len > 0) try s.save();
    }
    if (claims.items.len == 0) return .{ .considered = considered };
    log.log(.info, "schedule: firing {d} due entr{s} ({d} scheduled)", .{
        claims.items.len,
        if (claims.items.len == 1) "y" else "ies",
        considered,
    });

    var outcomes: std.ArrayList(Outcome) = .empty;
    for (claims.items) |c| {
        const out = fireOne(io, gpa, base, c.entry, c.due_at, c.skipped, "due", fire);
        try outcomes.append(arena, out);
    }

    // Phase two: record the outcome. Re-opened rather than kept from phase
    // one, because an `enable`/`disable` that landed while the model was
    // working is a decision that must survive this write.
    {
        var s = try store.open(io, gpa, arena, base);
        defer s.close();
        for (outcomes.items) |o| {
            const e = s.find(o.id) orelse continue;
            e.last_status = if (o.ok) "ok" else "error";
            if (!o.ok) e.failures += 1;
        }
        try s.save();
    }

    return .{ .considered = considered, .outcomes = outcomes.items };
}

/// Fires one entry by id right now, whatever its schedule says. What `schedule
/// run <id>` is for: proving an entry works without waiting for its window.
/// It counts as a real run, it updates `last_run` and lands in the ledger;
/// because pretending it did not would leave the next window computed from a
/// run that visibly happened.
pub fn runOne(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    base: std.Io.Dir,
    id: []const u8,
    now: i64,
    fire: Fire,
) !Outcome {
    var entry: store.Entry = undefined;
    {
        var s = try store.open(io, gpa, arena, base);
        defer s.close();
        const e = s.find(id) orelse return store.Error.NoSuchEntry;
        entry = e.*;
        e.last_run = now;
        e.runs += 1;
        e.last_status = "running";
        try s.save();
    }

    const out = fireOne(io, gpa, base, entry, 0, 0, "manual", fire);

    {
        var s = try store.open(io, gpa, arena, base);
        defer s.close();
        if (s.find(id)) |e| {
            e.last_status = if (out.ok) "ok" else "error";
            if (!out.ok) e.failures += 1;
        }
        try s.save();
    }
    return out;
}

fn fireOne(
    io: std.Io,
    gpa: std.mem.Allocator,
    base: std.Io.Dir,
    entry: store.Entry,
    due_at: i64,
    skipped: u32,
    trigger: []const u8,
    fire: Fire,
) Outcome {
    const started = std.Io.Timestamp.now(io, .awake);
    var err_name: []const u8 = "";
    var ok = true;
    fire.call(fire.ctx, &entry) catch |err| {
        // One entry failing is not the sweep failing: the next entry's window
        // has also passed, and skipping it because an earlier one errored
        // would make one broken schedule silently stop every other.
        ok = false;
        err_name = @errorName(err);
        log.log(.warn, "schedule: entry {s} failed: {s} (trigger={s})", .{ entry.id, err_name, trigger });
    };
    const elapsed_ns = started.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    const duration_ms: u64 = @intCast(@max(0, @divTrunc(elapsed_ns, std.time.ns_per_ms)));
    if (ok) log.log(.info, "schedule: entry {s} ok in {d}ms (trigger={s})", .{ entry.id, duration_ms, trigger });

    const ts: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    store.appendRecord(io, gpa, base, .{
        .ts = ts,
        .id = entry.id,
        .cron = entry.cron,
        .task = entry.task,
        .trigger = trigger,
        .due_at = due_at,
        .skipped = skipped,
        .ok = ok,
        .duration_ms = duration_ms,
        .err = err_name,
    });
    return .{ .id = entry.id, .due_at = due_at, .skipped = skipped, .ok = ok, .err = err_name, .duration_ms = duration_ms };
}

/// An advisory exclusive lock on a file of its own, taken without waiting.
/// Not `util/runlock.zig`: that one decides whether a lock is stale by looking
/// the owning pid up in `/proc`, which does not exist on macOS, so every lock
/// there reads as abandoned and gets taken over. A kernel-held flock needs no
/// liveness check, it is released when the process dies, however it dies.
fn acquireRunLock(io: std.Io, base: std.Io.Dir) !std.Io.File {
    base.createDirPath(io, store.ledger_dir) catch {};
    return filelock.createFileRetry(io, base, run_lock_path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => Error.Busy,
        else => err,
    };
}

// ------------------------------------------------------------------- tests --

const testing = std.testing;

/// A `Fire` that records what it was handed and can be told to fail, so the
/// claim/ledger/missed-run logic is tested without a provider.
const Recorder = struct {
    calls: std.ArrayList([]const u8) = .empty,
    alloc: std.mem.Allocator,
    fail_with: ?anyerror = null,

    fn fire(self: *Recorder) Fire {
        return .{ .ctx = self, .call = call };
    }

    fn call(ctx: *anyopaque, entry: *const store.Entry) anyerror!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        try self.calls.append(self.alloc, entry.id);
        if (self.fail_with) |e| return e;
    }
};

const Fixture = struct {
    threaded: std.Io.Threaded,
    tmp: std.testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,

    fn init() Fixture {
        return .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .tmp = testing.tmpDir(.{}),
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }
    fn deinit(self: *Fixture) void {
        self.arena_state.deinit();
        self.tmp.cleanup();
        self.threaded.deinit();
    }
    fn io(self: *Fixture) std.Io {
        return self.threaded.io();
    }
    fn arena(self: *Fixture) std.mem.Allocator {
        return self.arena_state.allocator();
    }
    fn put(self: *Fixture, entries: []const store.Entry) !void {
        var s = try store.open(self.io(), testing.allocator, self.arena(), self.tmp.dir);
        defer s.close();
        try s.entries.appendSlice(self.arena(), entries);
        try s.save();
    }
};

const t0 = cron.epochFromCivil(2026, 8, 13, 12, 0, 0);

test "an entry added mid-window waits for the next one instead of firing now" {
    var f = Fixture.init();
    defer f.deinit();
    const e = store.Entry{ .id = "sch-1", .cron = "0 * * * *", .task = "t", .created = t0 };
    // 12:00:00 created, hourly on the hour: nothing until 13:00.
    try testing.expectEqual(@as(?i64, null), dueAt(e, t0 + 60));
    try testing.expectEqual(@as(?i64, null), dueAt(e, t0 + 3599));
    try testing.expectEqual(@as(?i64, t0 + 3600), dueAt(e, t0 + 3600));
}

test "a disabled entry and an unparseable spec are never due" {
    const off = store.Entry{ .id = "sch-1", .cron = "* * * * *", .task = "t", .created = t0, .enabled = false };
    try testing.expectEqual(@as(?i64, null), dueAt(off, t0 + 86400));
    const bad = store.Entry{ .id = "sch-2", .cron = "every tuesday", .task = "t", .created = t0 };
    try testing.expectEqual(@as(?i64, null), dueAt(bad, t0 + 86400));
    // And a spec that parses but can never match.
    const impossible = store.Entry{ .id = "sch-3", .cron = "0 0 30 2 *", .task = "t", .created = t0 };
    try testing.expectEqual(@as(?i64, null), dueAt(impossible, t0 + 86400 * 400));
}

test "run-due fires a due entry once, and a second sweep does not re-fire it" {
    var f = Fixture.init();
    defer f.deinit();
    try f.put(&.{.{ .id = "sch-1", .cron = "* * * * *", .task = "hello", .created = t0 }});

    var rec = Recorder{ .alloc = testing.allocator };
    defer rec.calls.deinit(testing.allocator);

    const first = try runDue(f.io(), testing.allocator, f.arena(), f.tmp.dir, t0 + 120, rec.fire());
    try testing.expectEqual(@as(usize, 1), first.considered);
    try testing.expectEqual(@as(usize, 1), first.outcomes.len);
    try testing.expect(first.outcomes[0].ok);
    try testing.expectEqual(@as(usize, 1), rec.calls.items.len);
    // A punctual sweep reports no skipped windows. The window it is standing
    // on is the one it is serving, so counting it would make every ordinary
    // run of an every-minute entry look like it had fallen behind.
    try testing.expectEqual(@as(u32, 0), first.outcomes[0].skipped);

    // Immediately again, same second: the claim already moved last_run to
    // now, and "strictly after" means the current minute is spent.
    const second = try runDue(f.io(), testing.allocator, f.arena(), f.tmp.dir, t0 + 120, rec.fire());
    try testing.expectEqual(@as(usize, 0), second.outcomes.len);
    try testing.expectEqual(@as(usize, 1), rec.calls.items.len);

    // The store records the run, and the ledger has exactly one line for it.
    const entries = try store.read(f.io(), f.arena(), f.tmp.dir);
    try testing.expectEqual(@as(i64, t0 + 120), entries[0].last_run);
    try testing.expectEqual(@as(u32, 1), entries[0].runs);
    try testing.expectEqual(@as(u32, 0), entries[0].failures);
    try testing.expectEqualStrings("ok", entries[0].last_status);

    const recs = try store.readRecords(f.io(), f.arena(), f.tmp.dir, 10);
    try testing.expectEqual(@as(usize, 1), recs.len);
    try testing.expectEqualStrings("due", recs[0].trigger);
    try testing.expectEqualStrings("hello", recs[0].task);
    try testing.expect(recs[0].ok);
}

test "a day of downtime fires a */5 entry once, not 288 times" {
    // The whole missed-run policy, as the case that motivated it.
    var f = Fixture.init();
    defer f.deinit();
    try f.put(&.{.{ .id = "sch-1", .cron = "*/5 * * * *", .task = "t", .created = t0, .last_run = t0 }});

    var rec = Recorder{ .alloc = testing.allocator };
    defer rec.calls.deinit(testing.allocator);

    const wake = t0 + std.time.s_per_day;
    const s = try runDue(f.io(), testing.allocator, f.arena(), f.tmp.dir, wake, rec.fire());
    try testing.expectEqual(@as(usize, 1), s.outcomes.len);
    try testing.expectEqual(@as(usize, 1), rec.calls.items.len);
    // 288 windows elapsed. The first (12:05) is the one that fired and the
    // last (12:00 on the second day) lands exactly on wake, so 286 are
    // reported as dropped rather than silently discarded.
    try testing.expectEqual(@as(u32, 286), s.outcomes[0].skipped);
    try testing.expectEqual(@as(i64, t0 + 5 * 60), s.outcomes[0].due_at);

    const recs = try store.readRecords(f.io(), f.arena(), f.tmp.dir, 10);
    try testing.expectEqual(@as(u32, 286), recs[0].skipped);

    // And it resumes on the normal grid from wake time, not from the backlog:
    // the next window is five minutes after waking.
    const entries = try store.read(f.io(), f.arena(), f.tmp.dir);
    try testing.expectEqual(@as(?i64, null), dueAt(entries[0], wake + 60));
    try testing.expect(dueAt(entries[0], wake + 5 * 60) != null);
}

test "a failing entry is recorded as failed and does not stop the others" {
    var f = Fixture.init();
    defer f.deinit();
    try f.put(&.{
        .{ .id = "sch-1", .cron = "* * * * *", .task = "a", .created = t0 },
        .{ .id = "sch-2", .cron = "* * * * *", .task = "b", .created = t0 },
    });

    var rec = Recorder{ .alloc = testing.allocator, .fail_with = error.ProviderRefused };
    defer rec.calls.deinit(testing.allocator);

    const s = try runDue(f.io(), testing.allocator, f.arena(), f.tmp.dir, t0 + 120, rec.fire());
    try testing.expectEqual(@as(usize, 2), s.outcomes.len);
    try testing.expectEqual(@as(usize, 2), rec.calls.items.len);
    for (s.outcomes) |o| {
        try testing.expect(!o.ok);
        try testing.expectEqualStrings("ProviderRefused", o.err);
    }

    const entries = try store.read(f.io(), f.arena(), f.tmp.dir);
    for (entries) |e| {
        try testing.expectEqualStrings("error", e.last_status);
        try testing.expectEqual(@as(u32, 1), e.failures);
        // A failure still counts as a run and still advances the window: a
        // provider that is down must not turn into a fire on every sweep.
        try testing.expectEqual(@as(i64, t0 + 120), e.last_run);
    }
    const recs = try store.readRecords(f.io(), f.arena(), f.tmp.dir, 10);
    try testing.expectEqual(@as(usize, 2), recs.len);
    try testing.expectEqualStrings("ProviderRefused", recs[0].err);
}

test "run-due with nothing scheduled, and with nothing due, both do nothing quietly" {
    var f = Fixture.init();
    defer f.deinit();
    var rec = Recorder{ .alloc = testing.allocator };
    defer rec.calls.deinit(testing.allocator);

    const empty = try runDue(f.io(), testing.allocator, f.arena(), f.tmp.dir, t0, rec.fire());
    try testing.expectEqual(@as(usize, 0), empty.considered);
    try testing.expect(!empty.busy);

    try f.put(&.{.{ .id = "sch-1", .cron = "0 3 * * *", .task = "t", .created = t0 }});
    const early = try runDue(f.io(), testing.allocator, f.arena(), f.tmp.dir, t0 + 60, rec.fire());
    try testing.expectEqual(@as(usize, 1), early.considered);
    try testing.expectEqual(@as(usize, 0), early.outcomes.len);
    try testing.expectEqual(@as(usize, 0), rec.calls.items.len);
    // Nothing fired means nothing written: no ledger file appears.
    try testing.expectEqual(@as(usize, 0), (try store.readRecords(f.io(), f.arena(), f.tmp.dir, 10)).len);
}

test "a second run-due reports busy instead of firing on top of the first" {
    var f = Fixture.init();
    defer f.deinit();
    try f.put(&.{.{ .id = "sch-1", .cron = "* * * * *", .task = "t", .created = t0 }});

    // Standing in for a sweep already in flight: the same flock the runner
    // takes, held by this test for the duration.
    try f.tmp.dir.createDirPath(f.io(), store.ledger_dir);
    var held = try filelock.createFileRetry(f.io(), f.tmp.dir, run_lock_path, .{ .truncate = false, .lock = .exclusive });

    var rec = Recorder{ .alloc = testing.allocator };
    defer rec.calls.deinit(testing.allocator);
    const s = try runDue(f.io(), testing.allocator, f.arena(), f.tmp.dir, t0 + 120, rec.fire());
    try testing.expect(s.busy);
    try testing.expectEqual(@as(usize, 0), rec.calls.items.len);

    // Released, and the sweep goes through.
    held.close(f.io());
    const after = try runDue(f.io(), testing.allocator, f.arena(), f.tmp.dir, t0 + 120, rec.fire());
    try testing.expect(!after.busy);
    try testing.expectEqual(@as(usize, 1), rec.calls.items.len);
}

test "schedule run fires one entry regardless of its window, and says so in the ledger" {
    var f = Fixture.init();
    defer f.deinit();
    // Yearly, so nothing about this is due.
    try f.put(&.{.{ .id = "sch-1", .cron = "0 0 1 1 *", .task = "t", .created = t0 }});

    var rec = Recorder{ .alloc = testing.allocator };
    defer rec.calls.deinit(testing.allocator);

    const out = try runOne(f.io(), testing.allocator, f.arena(), f.tmp.dir, "sch-1", t0 + 60, rec.fire());
    try testing.expect(out.ok);
    try testing.expectEqual(@as(i64, 0), out.due_at);
    try testing.expectEqual(@as(usize, 1), rec.calls.items.len);

    const recs = try store.readRecords(f.io(), f.arena(), f.tmp.dir, 10);
    try testing.expectEqualStrings("manual", recs[0].trigger);

    // A manual run of a disabled entry still runs, the operator asked for it
    // by id, but an unknown id is an error rather than a silent no-op.
    try testing.expectError(store.Error.NoSuchEntry, runOne(f.io(), testing.allocator, f.arena(), f.tmp.dir, "sch-9", t0, rec.fire()));
}

test "an entry whose window passes while an earlier one runs is picked up by the same sweep" {
    // Both are due at claim time; the sweep decides the due set up front, so a
    // long first run cannot starve the second.
    var f = Fixture.init();
    defer f.deinit();
    try f.put(&.{
        .{ .id = "sch-1", .cron = "*/5 * * * *", .task = "a", .created = t0 },
        .{ .id = "sch-2", .cron = "0 * * * *", .task = "b", .created = t0 - 7200 },
    });
    var rec = Recorder{ .alloc = testing.allocator };
    defer rec.calls.deinit(testing.allocator);
    const s = try runDue(f.io(), testing.allocator, f.arena(), f.tmp.dir, t0 + 600, rec.fire());
    try testing.expectEqual(@as(usize, 2), s.outcomes.len);
    try testing.expectEqualStrings("sch-1", rec.calls.items[0]);
    try testing.expectEqualStrings("sch-2", rec.calls.items[1]);
}

test "an entry disabled while its run was in flight keeps the disable" {
    // Phase two re-reads the store rather than writing back the copy it took
    // in phase one, so a decision made during the run is not clobbered by it.
    var f = Fixture.init();
    defer f.deinit();
    try f.put(&.{.{ .id = "sch-1", .cron = "* * * * *", .task = "t", .created = t0 }});

    const Disabler = struct {
        dir: std.Io.Dir,
        io: std.Io,
        fn fire(self: *@This()) Fire {
            return .{ .ctx = self, .call = call };
        }
        fn call(ctx: *anyopaque, _: *const store.Entry) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            var a = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer a.deinit();
            var s = try store.open(self.io, std.testing.allocator, a.allocator(), self.dir);
            defer s.close();
            s.find("sch-1").?.enabled = false;
            try s.save();
        }
    };
    var d = Disabler{ .dir = f.tmp.dir, .io = f.io() };
    _ = try runDue(f.io(), testing.allocator, f.arena(), f.tmp.dir, t0 + 120, d.fire());

    const entries = try store.read(f.io(), f.arena(), f.tmp.dir);
    try testing.expectEqual(false, entries[0].enabled);
    try testing.expectEqualStrings("ok", entries[0].last_status);
}
