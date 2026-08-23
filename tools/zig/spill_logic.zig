//! Pure helpers for the spill id format, shared by the `spill` guest and the
//! harness: the guest reads spilled results back through them, and the agent
//! loop derives the ids and builds the locator lines through the same
//! functions, so the format has one host-tested home. Host-tested.

const std = @import("std");

pub const locator_prefix = "[spill id=";

pub fn parseId(text: []const u8) ?[]const u8 {
    const at = std.mem.find(u8, text, locator_prefix) orelse return null;
    const start = at + locator_prefix.len;
    if (start + 8 > text.len) return null;
    const id = text[start .. start + 8];
    for (id) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!hex) return null;
    }
    return id;
}

/// One-line locator the model can hand to the `spill` guest.
pub fn locatorLine(id: []const u8) [locator_prefix.len + 8 + 1]u8 {
    var out: [locator_prefix.len + 8 + 1]u8 = undefined;
    @memcpy(out[0..locator_prefix.len], locator_prefix);
    @memcpy(out[locator_prefix.len..][0..8], id[0..8]);
    out[out.len - 1] = ']';
    return out;
}

/// 8 lowercase hex chars from a 32-bit FNV of the bytes plus a salt.
pub fn idFor(content: []const u8, salt: u64) [8]u8 {
    var h: u32 = 2166136261;
    for (content) |c| {
        h ^= c;
        h *%= 16777619;
    }
    // Mix in the low 32 bits of the salt; the high half is dropped on purpose.
    h ^= @truncate(salt);
    h *%= 16777619;
    var out: [8]u8 = undefined;
    const hex = "0123456789abcdef";
    var i: usize = 8;
    var n = h;
    while (i > 0) {
        i -= 1;
        out[i] = hex[n & 0xf];
        n >>= 4;
    }
    return out;
}

pub fn validId(id: []const u8) bool {
    if (id.len != 8) return false;
    for (id) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!hex) return false;
    }
    return true;
}

pub fn pathFor(session_id: []const u8, id: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "state/spills/{s}/{s}.txt", .{ session_id, id });
}

/// The directory holding one session's spills, which is what erasing that
/// session has to remove: a spill file is the verbatim middle of a tool result
/// from that conversation, so deleting only `state/sessions/<id>.json` leaves
/// the same content readable under this path.
pub fn dirFor(session_id: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "state/spills/{s}", .{session_id});
}

/// How long a spilled tool result is kept after it was last written.
///
/// A spill is run-scoped scratch, not history. The locator that names one is
/// written onto the *request* copy of a message, which is rebuilt from the
/// saved transcript every iteration and thrown away after the request; a saved
/// session never contains a locator. So once the run that spilled it is over,
/// nothing can ask for the file again.
///
/// Twelve hours is therefore already generous — it is a margin for a long run,
/// not a retention policy — and it matches `janitor`'s lock-file window so
/// there is one number to remember rather than two.
pub const keep_spill_ms: i64 = 12 * 60 * 60 * 1000;

/// A file under `state/spills/<session>/` written by the `spill` guest:
/// `<8 lowercase hex>.txt`. Checking the shape rather than just the suffix
/// keeps the delete path off anything else that lands in the directory.
pub fn isSpillFileName(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".txt")) return false;
    return validId(name[0 .. name.len - ".txt".len]);
}

/// Whether a spill written at `mtime_ms` has aged out by `now_ms`.
///
/// The id is a content hash, so spill file names carry no order at all and a
/// newest-N rule has nothing to sort by; the timestamp is the only signal that
/// separates a live run's spill from a dead one's. A file dated in the future
/// (clock skew, a restored backup) is left alone rather than swept.
pub fn spillAgedOut(now_ms: i64, mtime_ms: i64, keep_ms: i64) bool {
    if (mtime_ms > now_ms) return false;
    return now_ms - mtime_ms >= keep_ms;
}

test "dirFor names the session directory pathFor writes into" {
    var dir_buf: [96]u8 = undefined;
    var path_buf: [96]u8 = undefined;
    const dir = try dirFor("sess01ab", &dir_buf);
    const path = try pathFor("sess01ab", "deadbeef", &path_buf);
    try std.testing.expectEqualStrings("state/spills/sess01ab", dir);
    try std.testing.expect(std.mem.startsWith(u8, path, dir));
    try std.testing.expectEqual(@as(u8, '/'), path[dir.len]);
}

test "only 8-hex .txt names under a spill directory are sweepable" {
    try std.testing.expect(isSpillFileName("deadbeef.txt"));
    try std.testing.expect(!isSpillFileName("DEADBEEF.txt"));
    try std.testing.expect(!isSpillFileName("deadbeef"));
    try std.testing.expect(!isSpillFileName("notes.txt"));
    try std.testing.expect(!isSpillFileName("deadbee.txt"));
    try std.testing.expect(!isSpillFileName(".txt"));
    // The id a live run just derived is by construction a sweepable name.
    const id = idFor("some oversized tool result", 7);
    var buf: [16]u8 = undefined;
    try std.testing.expect(isSpillFileName(try std.fmt.bufPrint(&buf, "{s}.txt", .{&id})));
}

test "a spill ages out only once it is older than the window" {
    const now: i64 = 1_000_000_000;
    try std.testing.expect(!spillAgedOut(now, now, keep_spill_ms));
    try std.testing.expect(!spillAgedOut(now, now - keep_spill_ms + 1, keep_spill_ms));
    try std.testing.expect(spillAgedOut(now, now - keep_spill_ms, keep_spill_ms));
    try std.testing.expect(spillAgedOut(now, 0, keep_spill_ms));
    // Skewed into the future: not aged, and not swept.
    try std.testing.expect(!spillAgedOut(now, now + keep_spill_ms, keep_spill_ms));
}

test "parseId accepts only 8 lowercase hex" {
    try std.testing.expectEqualStrings("deadbeef", parseId("head\n[spill id=deadbeef]\n") orelse "");
    try std.testing.expect(parseId("[spill id=DEADBEEF]") == null);
    try std.testing.expect(parseId("[spill id=short]") == null);
    try std.testing.expect(validId("cafebabe"));
    try std.testing.expect(!validId("cafe"));
}

test "locator is 8 hex and round-trips" {
    const id = idFor("hello tool output", 3);
    try std.testing.expectEqual(@as(usize, 8), id.len);
    const line = locatorLine(&id);
    const parsed = parseId(&line) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(&id, parsed);
    try std.testing.expect(parseId("no locator here") == null);
    try std.testing.expect(parseId("[spill id=nothex!!]") == null);
}
