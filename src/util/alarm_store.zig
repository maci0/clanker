//! One row of `state/alarms.json`, the alarm tool's reminder store.
//!
//! The `alarm` guest owns the store (set/list/done/cancel) and the system
//! prompt reads the same rows to surface due and pending reminders. Both
//! walk the same shape, so the record is declared here rather than copied:
//! a field added on one side would otherwise silently vanish on the other,
//! the same drift rule that puts glob, tail, and fs_skip in this directory.
//! Reached root-relatively from `src/` and by name (`alarm_store`) from the
//! guest, never both ways in one compilation.

const std = @import("std");
// Relative, like `glob.zig` reaching `fuzz_corpus.zig`: this module is
// compiled twice (root-relatively by `src/main.zig`, and by name from the
// `alarm` guest), and a relative sibling path resolves in both compilations,
// where a named `utf8` import would resolve in only the guest's.
const utf8 = @import("utf8.zig");

/// Declaration order is the on-disk key order; keep it stable so store
/// rewrites stay diff-friendly. Only `every` has a default: it was added
/// after the first files were written, and a row without it is a one-shot.
pub const Alarm = struct {
    id: []const u8,
    ts: i64, // next fire time, epoch seconds
    message: []const u8,
    set_ts: i64,
    every: i64 = 0, // recurrence interval in minutes; 0 means one-shot
};

/// Parse a whole store file. An empty (or whitespace-only) file recovers as
/// an empty list, matching the guest's load(); anything else must parse as
/// an alarm array or this returns error.CorruptAlarmFile and the caller
/// decides what that means: the guest refuses the operation, the system
/// prompt skips the reminders section.
pub fn parseList(alloc: std.mem.Allocator, raw: []const u8) ![]Alarm {
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return &[_]Alarm{};
    return std.json.parseFromSliceLeaky([]Alarm, alloc, raw, .{ .ignore_unknown_fields = true }) catch
        error.CorruptAlarmFile;
}

test "parseList reads rows written by the guest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const raw =
        \\[
        \\  {"id": "a-1-0", "ts": 100, "message": "check CI", "set_ts": 90},
        \\  {"id": "a-2-1", "ts": 200, "message": "stand up", "set_ts": 90, "every": 30}
        \\]
    ;
    const got = try parseList(arena_state.allocator(), raw);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("a-1-0", got[0].id);
    try std.testing.expectEqual(@as(i64, 100), got[0].ts);
    try std.testing.expectEqual(@as(i64, 0), got[0].every);
    try std.testing.expectEqual(@as(i64, 30), got[1].every);
}

test "parseList recovers an empty or blank file as an empty list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try parseList(alloc, "")).len);
    try std.testing.expectEqual(@as(usize, 0), (try parseList(alloc, " \r\n")).len);
}

test "parseList refuses a row missing a required field" {
    // The guest writes every key; a row without one is a hand edit that the
    // store owner must refuse, not silently default.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.CorruptAlarmFile,
        parseList(arena_state.allocator(), "[{\"id\":\"a-1-0\",\"ts\":5,\"message\":\"x\"}]"),
    );
}

test "parseList ignores unknown fields for forward compatibility" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try parseList(arena_state.allocator(), "[{\"id\":\"i\",\"ts\":1,\"message\":\"m\",\"set_ts\":0,\"note\":\"x\"}]");
    try std.testing.expectEqual(@as(usize, 1), got.len);
}

/// The row a `set` would duplicate, or null when the store holds no such
/// reminder. Identity is the reminder itself, not the id: `set` mints a new
/// id every call, so the model repeating a call whose reply it never saw --
/// a retried turn, a resumed session, a second agent reasoning over the
/// same reminder -- appended a second copy of a reminder it had already
/// set, and both copies then surfaced in the system prompt of every later
/// run until each was handled. Same message, same fire time, same interval
/// is the same reminder; anything else is a different one.
///
/// The message is compared under canonical equivalence, not by bytes, because
/// the two sides of this dedup spell the same words two ways: a model repeats
/// "re-read the caf\u{e9} report" from its own context where it was composed,
/// while the row already on disk came off a keyboard, a file, or another model
/// and can be decomposed. Byte equality calls those one reminder and two, and
/// the store then carries the duplicate into every later system prompt --
/// exactly the failure this function exists to prevent, reached by a spelling
/// rather than by a retry. See `utf8.canonicalEqual`.
pub fn findSame(alarms: []const Alarm, message: []const u8, ts: i64, every: i64) ?usize {
    for (alarms, 0..) |a, i| {
        if (a.ts != ts or a.every != every) continue;
        if (!utf8.canonicalEqual(a.message, message)) continue;
        return i;
    }
    return null;
}

test "a repeated set in either spelling of the word finds the reminder" {
    // "café" composed, and "cafe" + combining acute as it comes back off
    // APFS or out of a model that copies the composed text it was shown.
    const composed = "check the caf\xc3\xa9 report";
    const decomposed = "check the cafe\xcc\x81 report";
    try std.testing.expectEqual(@as(?usize, 0), findSame(&[_]Alarm{.{ .id = "a-1-0", .ts = 100, .message = composed, .set_ts = 90 }}, decomposed, 100, 0));
    try std.testing.expectEqual(@as(?usize, 0), findSame(&[_]Alarm{.{ .id = "a-1-0", .ts = 100, .message = decomposed, .set_ts = 90 }}, composed, 100, 0));
    // Still a different reminder: an accent the other message does not carry,
    // and a composed mark vs a different mark on the same base, are the two
    // questions `fold` would answer yes and identity must not.
    try std.testing.expectEqual(@as(?usize, null), findSame(&[_]Alarm{.{ .id = "a-1-0", .ts = 100, .message = composed, .set_ts = 90 }}, "check the cafe report", 100, 0));
    try std.testing.expectEqual(@as(?usize, null), findSame(&[_]Alarm{.{ .id = "a-1-0", .ts = 100, .message = "caf\xc3\xa9", .set_ts = 90 }}, "cafe\xcc\x88", 100, 0));
}

test "an ASCII store is unaffected: same bytes, same answer, nothing allocated" {
    const alarms = [_]Alarm{.{ .id = "a-1-0", .ts = 100, .message = "check CI", .set_ts = 90 }};
    try std.testing.expectEqual(@as(?usize, 0), findSame(&alarms, "check CI", 100, 0));
    try std.testing.expectEqual(@as(?usize, null), findSame(&alarms, "check CD", 100, 0));
}

/// The next fire time for a recurring alarm handled at `now`, or null when
/// handling it changes nothing.
///
/// `done` is the one alarm operation that moves a row rather than setting a
/// field to a fixed value, and it used to move it a whole interval on *every*
/// call: a first `done` put `ts` strictly after `now`, and a repeat of that
/// same `done` -- a retried turn, a model calling it twice, a request whose
/// reply was lost -- read the advanced `ts`, saw it was not yet due, and
/// pushed it a second interval out. A recurring reminder set to come back
/// every 30 minutes came back at 60. What `done` consumes is one fire time,
/// so an alarm that is not due has already been handled for the current
/// window and is left alone; pushing a *pending* reminder out is a different
/// operation from handling the one that just came due.
///
/// A one-shot has no next fire time, so the caller removes it instead.
///
/// The arithmetic is saturating throughout: the store is plain JSON a hand
/// edit can corrupt, and an extreme stored `ts`/`every` must not overflow the
/// guest (a wrapped next fire in the past is an alarm stuck permanently due).
pub fn advanceOnDone(now: i64, ts: i64, every: i64) ?i64 {
    if (every <= 0) return null;
    if (ts > now) return null;
    const step: i64 = @max(60, @max(1, @min(every, std.math.maxInt(i64) / 60)) * 60);
    const behind: i64 = if (now >= 0 and ts < now - std.math.maxInt(i64)) std.math.maxInt(i64) else now -| ts;
    const slots = @divTrunc(behind, step) +| 1;
    // For valid data the advance already lands strictly after `now`; the
    // clamp only rescues the saturated case.
    return @max(ts +| (slots *| step), now +| step);
}

test "parseList rejects non-array JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.CorruptAlarmFile, parseList(arena_state.allocator(), "{}"));
}

test "a repeated set finds the reminder it would duplicate" {
    const alarms = [_]Alarm{
        .{ .id = "a-100-0", .ts = 100, .message = "check CI", .set_ts = 90 },
        .{ .id = "a-200-0", .ts = 200, .message = "check CI", .set_ts = 90, .every = 30 },
    };
    // Exactly the set that is already there: same message, fire time, interval.
    try std.testing.expectEqual(@as(?usize, 0), findSame(&alarms, "check CI", 100, 0));
    try std.testing.expectEqual(@as(?usize, 1), findSame(&alarms, "check CI", 200, 30));
    // A different message, a different fire time, and a different interval
    // are three different reminders, not a match on the message alone.
    try std.testing.expectEqual(@as(?usize, null), findSame(&alarms, "check CD", 100, 0));
    try std.testing.expectEqual(@as(?usize, null), findSame(&alarms, "check CI", 101, 0));
    // A one-shot and a recurring reminder for the same text are distinct:
    // handling the one-shot must not silence the recurring one.
    try std.testing.expectEqual(@as(?usize, null), findSame(&alarms, "check CI", 200, 0));
    try std.testing.expectEqual(@as(?usize, null), findSame(&alarms, "check CI", 100, 30));
}

test "setting the same reminder twice leaves one row" {
    var alarms: std.ArrayList(Alarm) = .empty;
    defer alarms.deinit(std.testing.allocator);
    // The guest's append step, run twice, guarded by findSame.
    for (0..2) |_| {
        if (findSame(alarms.items, "re-poll the peer", 500, 0) == null) {
            try alarms.append(std.testing.allocator, .{ .id = "a-500-0", .ts = 500, .message = "re-poll the peer", .set_ts = 400 });
        }
    }
    try std.testing.expectEqual(@as(usize, 1), alarms.items.len);
}

test "handling the same recurring fire twice advances it once" {
    // Due exactly now, 30-minute recurrence: one interval lands after it.
    const first = advanceOnDone(1000, 1000, 30) orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(i64, 2800), first);
    // The retry of that same `done` reads the row the first call wrote and
    // changes nothing, which is the whole point: before the guard it advanced
    // to 4600 and the reminder came back an interval late.
    try std.testing.expectEqual(@as(?i64, null), advanceOnDone(1000, first, 30));
}

test "a recurring alarm that sat due for three intervals comes back once" {
    // Due at 100, handled at 1000 on a 300s step: 100 + 3*300 is not strictly
    // after now, so the next slot is the fourth, and handling that is a no-op.
    const next = advanceOnDone(1000, 100, 5) orelse return error.TestExpectedResult;
    try std.testing.expect(next > 1000);
    try std.testing.expectEqual(@as(?i64, null), advanceOnDone(1000, next, 5));
}

test "a not-yet-due recurring alarm is already handled for this window" {
    try std.testing.expectEqual(@as(?i64, null), advanceOnDone(1000, 2000, 30));
    // A non-positive stored `every` is a one-shot: no recurrence to advance to.
    try std.testing.expectEqual(@as(?i64, null), advanceOnDone(1000, 100, 0));
    try std.testing.expectEqual(@as(?i64, null), advanceOnDone(1000, 100, -5));
    // A hand-edited interval under the one-minute floor is still a minute,
    // never a sub-minute loop that would keep the alarm permanently due.
    try std.testing.expectEqual(@as(i64, 1060), advanceOnDone(1000, 1000, 1) orelse 0);
}

test "an absurd stored fire time cannot wrap the next fire into the past" {
    // The store is plain JSON a hand edit can corrupt, and the guest ships as
    // ReleaseSmall: a wrapped (negative) next fire is an alarm stuck due.
    const next = advanceOnDone(std.math.maxInt(i64), std.math.minInt(i64) / 2, 30) orelse
        return error.TestExpectedResult;
    try std.testing.expect(next > 0);
}
