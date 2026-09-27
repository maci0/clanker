//! Pure schedule helpers: next-fire, id check, task validation, sequential
//! ids. Host-tested; the guest and the HTTP bridge share these so a listing
//! and a toggle cannot disagree about when an entry fires or what an id is.

const std = @import("std");
const cron = @import("schedule_cron.zig");

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
    return @intFromFloat(@trunc(f));
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
