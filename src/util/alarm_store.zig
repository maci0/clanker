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

test "parseList rejects non-array JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.CorruptAlarmFile, parseList(arena_state.allocator(), "{}"));
}
