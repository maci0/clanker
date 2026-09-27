//! The direct-message room name: `dm:<a>|<b>`, both participants sorted.
//!
//! A direct message is an ordinary chatroom, so the *name* is the identity:
//! both sides must spell the same room or each writes its own log. That makes
//! the name a composite key, and a composite key written by joining a
//! separator drawn from an unvalidated alphabet is not injective: with `|` as
//! the separator, the pairs `("a", "b|c")` and `("a|b", "c")` both spell
//! `dm:a|b|c`, so two unrelated conversations share one log, one subscription
//! and one mesh edge. The alphabet is therefore closed here, and the two
//! spellings of a key (the sort, the split) live beside the rule that governs
//! them, so the reader of a name cannot drift from the writer of one.
//!
//! One definition, reached by name from every caller: the `ck_chat` host
//! function builds a name with it, the mesh map splits one back apart with it,
//! and the manifests document the same shape.

const std = @import("std");

pub const prefix = "dm:";
pub const separator: u8 = '|';

/// The two participants of a `dm:` room name.
pub const Pair = struct { a: []const u8, b: []const u8 };

/// True when `name` can be one half of a direct-message room name. Trimming
/// happens in `roomName`; this is the alphabet check, which is what keeps the
/// key injective.
pub fn validParticipantName(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfScalar(u8, name, separator) == null;
}

/// The room name for the conversation between `from` and `to`, identical
/// whichever side asks. Refuses an empty name, the two halves being equal (no
/// conversation with yourself), and a name carrying the separator, whose room
/// could not be split back apart.
pub fn roomName(arena: std.mem.Allocator, from_raw: []const u8, to_raw: []const u8) ![]const u8 {
    const from = std.mem.trim(u8, from_raw, " \t\r\n");
    const to = std.mem.trim(u8, to_raw, " \t\r\n");
    if (!validParticipantName(from) or !validParticipantName(to)) return error.InvalidParticipantName;
    if (std.mem.eql(u8, from, to)) return error.SelfDirectMessage;
    const pair: Pair = if (std.mem.lessThan(u8, from, to)) .{ .a = from, .b = to } else .{ .a = to, .b = from };
    return std.fmt.allocPrint(arena, "{s}{s}{c}{s}", .{ prefix, pair.a, separator, pair.b });
}

/// The participants of a `dm:` room name, or null when `name` is not one this
/// module could have written: a different prefix, no separator, an empty half,
/// or a second separator (which is a name whose halves the alphabet forbids).
pub fn parse(name: []const u8) ?Pair {
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const rest = name[prefix.len..];
    const bar = std.mem.indexOfScalar(u8, rest, separator) orelse return null;
    const a = rest[0..bar];
    const b = rest[bar + 1 ..];
    if (!validParticipantName(a) or !validParticipantName(b)) return null;
    return .{ .a = a, .b = b };
}

const testing = std.testing;

test "the room name is the same whichever side asks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a_b = try roomName(arena, "alice", "bob");
    const b_a = try roomName(arena, "bob", "alice");
    try testing.expectEqualStrings("dm:alice|bob", a_b);
    try testing.expectEqualStrings(a_b, b_a);

    // Surrounding whitespace is a transport artefact, not part of the name.
    try testing.expectEqualStrings(a_b, try roomName(arena, " alice ", "bob\n"));
}

test "a participant name carrying the separator is refused" {
    const arena = testing.allocator;
    // The collision the rule exists for: these two pairs are different
    // conversations and must not share a room.
    try testing.expectError(error.InvalidParticipantName, roomName(arena, "a", "b|c"));
    try testing.expectError(error.InvalidParticipantName, roomName(arena, "a|b", "c"));
    try testing.expectError(error.InvalidParticipantName, roomName(arena, "alice|bob", "carol"));
    try testing.expectError(error.InvalidParticipantName, roomName(arena, "alice", ""));
    try testing.expectError(error.SelfDirectMessage, roomName(arena, "alice", "alice"));
    try testing.expectError(error.SelfDirectMessage, roomName(arena, "alice", " alice "));
}

test "parse reads back exactly what roomName writes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const name = try roomName(arena, "bob", "alice");
    const pair = parse(name) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("alice", pair.a);
    try testing.expectEqualStrings("bob", pair.b);
    // Round trip: the split halves rebuild the same name.
    try testing.expectEqualStrings(name, try roomName(arena, pair.a, pair.b));
}

test "parse refuses what it could not have written" {
    try testing.expect(parse("ops") == null);
    try testing.expect(parse("dm:alice") == null);
    try testing.expect(parse("dm:|bob") == null);
    try testing.expect(parse("dm:alice|") == null);
    try testing.expect(parse("dm:a|b|c") == null);
}
