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
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// The next time an entry fires, as a wall-clock second, or null when it
/// never will: disabled, an unparseable spec, or a spec with no future match.
pub fn nextRun(enabled: bool, cron_text: []const u8, last_run: i64, created: i64, tz_offset_minutes: i32) ?i64 {
    if (!enabled) return null;
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

/// Why an entry is not firing, for callers that need to know without parsing
/// cron syntax themselves: disabled by toggle, malformed spec, or a spec that
/// parses but has no future match.
pub const Status = enum(u8) { active, disabled, invalid_cron, never_fires };

pub fn diagnose(enabled: bool, cron_text: []const u8, last_run: i64, created: i64, tz_offset_minutes: i32) Status {
    if (!enabled) return .disabled;
    const spec = cron.parse(cron_text) catch return .invalid_cron;
    const from = if (last_run > 0) last_run else created;
    _ = spec.nextAfter(from, tz_offset_minutes) orelse return .never_fires;
    return .active;
}

/// A spec that parses but can never match (`0 0 30 2 *`) is refused at add
/// time rather than sitting in the list looking scheduled.
pub fn firstFire(cron_text: []const u8, now: i64, tz_offset_minutes: i32) ?i64 {
    if (cron_text.len > max_cron_spec_bytes) return null;
    const spec = cron.parse(cron_text) catch return null;
    return spec.nextAfter(now, tz_offset_minutes);
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
}

test "nextRun omits disabled, junk, and never-firing specs" {
    const created = cron.epochFromCivil(2026, 8, 13, 12, 0, 0);
    try std.testing.expectEqual(@as(?i64, created + 60), nextRun(true, "* * * * *", 0, created, 0));
    try std.testing.expectEqual(@as(?i64, null), nextRun(false, "* * * * *", 0, created, 0));
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

test "diagnose distinguishes disabled, invalid, and never-firing" {
    const now = cron.epochFromCivil(2026, 8, 13, 12, 0, 0);
    try std.testing.expectEqual(@as(Status, .disabled), diagnose(false, "* * * * *", 0, now, 0));
    try std.testing.expectEqual(@as(Status, .invalid_cron), diagnose(true, "not a cron spec", 0, now, 0));
    try std.testing.expectEqual(@as(Status, .never_fires), diagnose(true, "0 0 30 2 *", 0, now, 0));
    try std.testing.expectEqual(@as(Status, .active), diagnose(true, "* * * * *", 0, now, 0));
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
