//! Pure schedule helpers: next-fire, id check, task validation, sequential
//! ids. Host-tested; the guest and the HTTP bridge share these so a listing
//! and a toggle cannot disagree about when an entry fires or what an id is.
//! The cron parser arrives as the `schedule_cron` module, not by path: this
//! file is linked into the host, where a path import would put
//! `schedule_cron.zig` in two modules at once and the compiler refuses it.

const std = @import("std");
const cron = @import("schedule_cron");

pub const max_task_bytes: usize = 4000;
/// Upper bound on a cron spec's byte length. The longest legitimate five-field
/// spec is well under 100 bytes; anything longer is pathological and is refused
/// before the parser tokenizes it, saving CPU on the schedule-add path.
pub const max_cron_spec_bytes: usize = 256;
pub const max_log_records: usize = 20;

pub const TaskError = error{
    TaskEmpty,
    TaskTooLong,
};

/// One scheduled entry: the record shape of `state/schedule.json`, which is a
/// plain array of these and is meant to stay hand-editable.
///
/// It lives here because the file has two writers and each rewrites all of it:
/// the `schedule` guest edits it through `ck_fs_write_if`, and the native
/// store rewrites the whole list every time a job fires. A field only one of
/// them names is dropped by the other, silently, because both sides parse
/// with `ignore_unknown_fields`; a field the guest writes and the fire path
/// does not know is erased from the operator's schedule the first night cron
/// runs. The same argument the writable rules (`nextId`, `validateTask`) make
/// for being here rather than in `store.zig`, applied to the shape itself.
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
    /// Minutes east of UTC that the cron fields are read at. See
    /// `schedule_cron.zig`: fixed, never a DST-aware zone.
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

/// One line of `state/schedule/log.jsonl`. Every field defaults, so a line
/// written by an older build (or a hand-edit) still reads back instead of
/// being skipped as malformed, which is how one fire loses its record.
pub const Record = struct {
    ts: i64 = 0,
    id: []const u8 = "",
    cron: []const u8 = "",
    task: []const u8 = "",
    /// "due" (fired by `run-due`) or "manual" (fired by `schedule run <id>`).
    trigger: []const u8 = "",
    /// The fire window that made it due, or 0 for a manual run. Distinct from
    /// `ts`: cron granularity is a minute and `run-due` may be seconds late.
    due_at: i64 = 0,
    /// Windows that elapsed and were deliberately not backfilled.
    skipped: u32 = 0,
    ok: bool = false,
    duration_ms: u64 = 0,
    err: []const u8 = "",
};

/// Same alphabet `session.validSessionId` uses: schedule ids are typed into
/// `schedule remove`/`enable` and into `/api/schedule/<id>`, so they stay
/// path-safe and short.
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    if (id[0] == '-') return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// The next time an entry fires, as a wall-clock second, or null when it
/// never will: disabled, an unparseable spec, or a spec with no future match.
pub fn nextRun(enabled: bool, cron_text: []const u8, last_run: i64, created: i64, tz_offset_minutes: i32) ?i64 {
    if (!enabled) return null;
    if (!validTzOffset(tz_offset_minutes)) return null;
    const spec = cron.parse(cron_text) catch return null;
    const from = if (last_run > 0) last_run else created;
    return spec.nextAfter(from, tz_offset_minutes);
}

pub fn validateTask(task: []const u8) TaskError![]const u8 {
    const trimmed = std.mem.trim(u8, task, " \t\r\n");
    if (trimmed.len == 0) return TaskError.TaskEmpty;
    if (trimmed.len > max_task_bytes) return TaskError.TaskTooLong;
    return trimmed;
}

/// Timezone offsets are whole minutes from UTC, and the bound is the cron's
/// own `max_tz_offset_minutes` rather than a second number written here: the
/// CLI's `--tz-offset` goes through `cron.parseOffset`, so a second limit in
/// this file let the native side store an offset the guest then refused to
/// schedule ("never fires" for an entry the CLI had just accepted).
pub fn validTzOffset(minutes: i32) bool {
    return minutes >= -cron.max_tz_offset_minutes and minutes <= cron.max_tz_offset_minutes;
}

/// The accepted range as text, so the refusal names the bound that is in force
/// instead of a hand-copied one.
pub fn tzOffsetRangeMessage(gpa: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(gpa, "tz_offset_minutes out of range (-{d}..+{d})", .{
        cron.max_tz_offset_minutes, cron.max_tz_offset_minutes,
    });
}

pub const TzOffsetError = error{TzOffsetOutOfRange};

/// A model-supplied `tz_offset_minutes` as an offset. The range check runs
/// before the conversion, not after: a JSON number reaches the guest as an
/// `f64`, and `@trunc` of `1e30` to `i32` is undefined behaviour in the
/// `ReleaseSmall` build this guest ships as, so a `validTzOffset` test on the
/// already-converted value comes too late to help. Comparing in float space
/// against the same constant `validTzOffset` uses leaves `@trunc` with a value
/// it is defined on. Both writers of the store (the `add` and `update`
/// actions) read the field through here, so neither can be the one that
/// converts first and validates second.
pub fn parseTzOffset(f: f64) TzOffsetError!i32 {
    const bound: f64 = @floatFromInt(cron.max_tz_offset_minutes);
    if (!std.math.isFinite(f) or f < -bound or f > bound) return error.TzOffsetOutOfRange;
    return @trunc(f);
}

/// The next free `sch-N`. Sequential, never reused, so a removed id keeps
/// meaning the job the ledger already recorded.
pub fn nextId(arena: std.mem.Allocator, ids: []const []const u8) ![]const u8 {
    var highest: u32 = 0;
    for (ids) |id| {
        if (!std.mem.startsWith(u8, id, "sch-")) continue;
        const n = std.fmt.parseInt(u32, id["sch-".len..], 10) catch continue;
        if (n > highest) highest = n;
    }
    return std.fmt.allocPrint(arena, "sch-{d}", .{highest + 1});
}

/// A spec that parses but can never match (`0 0 30 2 *`) is refused at add
/// time rather than sitting in the list looking scheduled.
pub fn firstFire(cron_text: []const u8, now: i64, tz_offset_minutes: i32) ?i64 {
    if (cron_text.len > max_cron_spec_bytes) return null;
    if (!validTzOffset(tz_offset_minutes)) return null;
    const spec = cron.parse(cron_text) catch return null;
    return spec.nextAfter(now, tz_offset_minutes);
}

/// Distinct failure modes for cron validation at add/update time so an
/// operator gets an actionable diagnostic rather than a conflated message.
pub const CronValidationError = error{
    ParseFailed,
    NeverFires,
};

pub fn validateCron(cron_text: []const u8, now: i64, tz_offset_minutes: i32) CronValidationError!void {
    if (cron_text.len > max_cron_spec_bytes) return CronValidationError.ParseFailed;
    if (!validTzOffset(tz_offset_minutes)) return CronValidationError.ParseFailed;
    const spec = cron.parse(cron_text) catch return CronValidationError.ParseFailed;
    _ = spec.nextAfter(now, tz_offset_minutes) orelse return CronValidationError.NeverFires;
}

test "the shared record shapes carry the fields both writers of the files need" {
    // The field lists are pinned, not just exercised: a second copy of this
    // shape is what let the guest's ledger reader go without `due_at` while
    // the runner wrote one on every line.
    const entry_fields = [_][]const u8{
        "id",       "cron",              "task",    "provider",
        "model",    "tz_offset_minutes", "enabled", "created",
        "last_run", "last_status",       "runs",    "failures",
    };
    const record_fields = [_][]const u8{
        "ts",      "id", "cron",        "task", "trigger", "due_at",
        "skipped", "ok", "duration_ms", "err",
    };
    try std.testing.expectEqual(entry_fields.len, @typeInfo(Entry).@"struct".fields.len);
    inline for (entry_fields, @typeInfo(Entry).@"struct".fields) |want, field| {
        try std.testing.expectEqualStrings(want, field.name);
    }
    try std.testing.expectEqual(record_fields.len, @typeInfo(Record).@"struct".fields.len);
    inline for (record_fields, @typeInfo(Record).@"struct".fields) |want, field| {
        try std.testing.expectEqualStrings(want, field.name);
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An entry with no override keeps the key out of the file entirely, so
    // the store stays hand-editable (`emit_null_optional_fields = false` is
    // what the native writer relies on; a null would force a hand-editor to
    // decide its meaning).
    var enc: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &enc.writer, .options = .{ .emit_null_optional_fields = false } };
    try s.write([_]Entry{.{ .id = "sch-1", .cron = "* * * * *", .task = "say hi" }});
    const raw = enc.written();
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"provider\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"model\"") == null);
    const back = try std.json.parseFromSliceLeaky([]Entry, arena, raw, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(?[]const u8, null), back[0].provider);
    try std.testing.expectEqualStrings("sch-1", back[0].id);

    // A ledger line the runner wrote reads back whole, `due_at` included: a
    // fire that ran late still says which window it answered.
    const line = "{\"ts\":200,\"id\":\"sch-1\",\"cron\":\"* * * * *\",\"task\":\"t\"," ++
        "\"trigger\":\"due\",\"due_at\":60,\"skipped\":0,\"ok\":true,\"duration_ms\":5,\"err\":\"\"}";
    const rec = try std.json.parseFromSliceLeaky(Record, arena, line, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(i64, 200), rec.ts);
    try std.testing.expectEqual(@as(i64, 60), rec.due_at);
    try std.testing.expect(rec.ok);

    // A short line from an older build still reads, rather than costing its
    // fire: every field defaults.
    const partial = try std.json.parseFromSliceLeaky(Record, arena, "{\"ts\":1,\"id\":\"sch-1\"}", .{});
    try std.testing.expectEqual(@as(i64, 0), partial.due_at);
    try std.testing.expectEqualStrings("", partial.trigger);
}

test "validId matches the session-id alphabet" {
    try std.testing.expect(validId("sch-1"));
    try std.testing.expect(validId("nightly"));
    try std.testing.expect(validId("a_b-C9"));
    try std.testing.expect(!validId(""));
    try std.testing.expect(!validId("../etc"));
    try std.testing.expect(!validId("sch/1"));
    try std.testing.expect(!validId("sch 1"));
    try std.testing.expect(!validId("x" ** 65));
    try std.testing.expect(!validId("-foo"));
}

test "parseTzOffset refuses a float too large for i32 before converting" {
    try std.testing.expectEqual(@as(i32, 0), try parseTzOffset(0));
    try std.testing.expectEqual(@as(i32, -330), try parseTzOffset(-330));
    try std.testing.expectEqual(@as(i32, cron.max_tz_offset_minutes), try parseTzOffset(cron.max_tz_offset_minutes));
    try std.testing.expectEqual(@as(i32, -cron.max_tz_offset_minutes), try parseTzOffset(-cron.max_tz_offset_minutes));
    // Out of the offset range, which is also the range the conversion is
    // defined over: `1e30` reaches here as ordinary model output, and
    // `@trunc` of it to i32 is undefined in the build the guest ships as.
    try std.testing.expectError(error.TzOffsetOutOfRange, parseTzOffset(1e30));
    try std.testing.expectError(error.TzOffsetOutOfRange, parseTzOffset(-1e30));
    try std.testing.expectError(error.TzOffsetOutOfRange, parseTzOffset(1e400));
    try std.testing.expectError(error.TzOffsetOutOfRange, parseTzOffset(-std.math.inf(f64)));
    try std.testing.expectError(error.TzOffsetOutOfRange, parseTzOffset(std.math.nan(f64)));
    try std.testing.expectError(error.TzOffsetOutOfRange, parseTzOffset(cron.max_tz_offset_minutes + 1));
    try std.testing.expectError(error.TzOffsetOutOfRange, parseTzOffset(-cron.max_tz_offset_minutes - 1));
}

test "the tz offset bound is the cron's, so both writers of the store agree" {
    // `schedule add --tz-offset +26:00` is accepted by the CLI (it parses
    // through `cron.parseOffset`), so an entry carrying that offset has to
    // schedule rather than read back as "never fires".
    try std.testing.expect(validTzOffset(cron.max_tz_offset_minutes));
    try std.testing.expect(validTzOffset(-cron.max_tz_offset_minutes));
    try std.testing.expect(!validTzOffset(cron.max_tz_offset_minutes + 1));
    try std.testing.expect(!validTzOffset(-cron.max_tz_offset_minutes - 1));
    try std.testing.expectEqual(
        @as(?i64, null),
        nextRun(true, "* * * * *", 0, cron.epochFromCivil(2026, 8, 13, 12, 0, 0), cron.max_tz_offset_minutes + 1),
    );
}

test "the range message names the bound in force" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [64]u8 = undefined;
    const msg = try tzOffsetRangeMessage(arena_state.allocator());
    const want = try std.fmt.bufPrint(&buf, "-{d}..+{d}", .{ cron.max_tz_offset_minutes, cron.max_tz_offset_minutes });
    try std.testing.expect(std.mem.indexOf(u8, msg, want) != null);
}

test "nextRun omits disabled, junk, and never-firing specs" {
    const created = cron.epochFromCivil(2026, 8, 13, 12, 0, 0);
    try std.testing.expectEqual(@as(?i64, created + 60), nextRun(true, "* * * * *", 0, created, 0));
    try std.testing.expectEqual(@as(?i64, null), nextRun(false, "* * * * *", 0, created, 0));
    // An out-of-range tz offset yields null rather than a nonsensical fire time.
    try std.testing.expectEqual(@as(?i64, null), nextRun(true, "* * * * *", 0, created, 9999));
    try std.testing.expectEqual(@as(?i64, null), nextRun(true, "* * * * *", 0, created, -9999));
    try std.testing.expectEqual(@as(?i64, null), nextRun(true, "not a cron spec", 0, created, 0));
    try std.testing.expectEqual(@as(?i64, null), nextRun(true, "0 0 30 2 *", 0, created, 0));
    // last_run, not created, is the origin once the entry has fired.
    try std.testing.expectEqual(@as(?i64, created + 120), nextRun(true, "* * * * *", created + 60, created, 0));
}

test "validateTask trims, refuses empty, and caps length" {
    try std.testing.expectEqualStrings("hi", try validateTask("  hi\n"));
    try std.testing.expectError(TaskError.TaskEmpty, validateTask("   "));
    const huge = "x" ** (max_task_bytes + 1);
    try std.testing.expectError(TaskError.TaskTooLong, validateTask(huge));
}

test "ids are sequential and never reuse a removed one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("sch-1", try nextId(arena, &.{}));
    const two = [_][]const u8{ "sch-1", "sch-2" };
    try std.testing.expectEqualStrings("sch-3", try nextId(arena, &two));
    const gap = [_][]const u8{"sch-2"};
    try std.testing.expectEqualStrings("sch-3", try nextId(arena, &gap));
    const named = [_][]const u8{"nightly"};
    try std.testing.expectEqualStrings("sch-1", try nextId(arena, &named));
}

test "validateCron distinguishes parse failure from impossible dates" {
    const now = cron.epochFromCivil(2026, 8, 13, 12, 0, 0);
    _ = try validateCron("* * * * *", now, 0);
    try std.testing.expectError(CronValidationError.ParseFailed, validateCron("not a spec", now, 0));
    try std.testing.expectError(CronValidationError.NeverFires, validateCron("0 0 30 2 *", now, 0));
    try std.testing.expectError(CronValidationError.ParseFailed, validateCron("", now, 0));
}

test "firstFire refuses a spec that never comes around" {
    const now = cron.epochFromCivil(2026, 8, 13, 12, 0, 0);
    try std.testing.expect(firstFire("* * * * *", now, 0) != null);
    try std.testing.expectEqual(@as(?i64, null), firstFire("0 0 30 2 *", now, 0));
    try std.testing.expectEqual(@as(?i64, null), firstFire("not a spec", now, 0));
    // A pathologically long spec is rejected before the parser sees it.
    const too_long = "*" ++ "x" ** (max_cron_spec_bytes + 1);
    try std.testing.expectEqual(@as(?i64, null), firstFire(too_long, now, 0));
}
