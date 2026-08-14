//! Clanker mesh (PRD 0011) Phase 1 core: length-prefixed frames, admission,
//! leave-vs-unreachable, simultaneous-open tie-break. Pure functions so
//! `zig build test` needs no NIC. Serve-owned sockets come next.

const std = @import("std");

pub const protocol_version = "1.0";
pub const default_max_frame_bytes: u32 = 1 << 20;
pub const max_members: u16 = 32;

pub const Kind = enum {
    join,
    join_ack,
    leave,
    ping,
    pong,
    chat,
    chat_sync,

    pub fn fromStr(s: []const u8) ?Kind {
        const map = std.StaticStringMap(Kind).initComptime(.{
            .{ "JOIN", .join },
            .{ "JOIN_ACK", .join_ack },
            .{ "LEAVE", .leave },
            .{ "PING", .ping },
            .{ "PONG", .pong },
            .{ "CHAT", .chat },
            .{ "CHAT_SYNC", .chat_sync },
        });
        return map.get(s);
    }

    pub fn asStr(self: Kind) []const u8 {
        return switch (self) {
            .join => "JOIN",
            .join_ack => "JOIN_ACK",
            .leave => "LEAVE",
            .ping => "PING",
            .pong => "PONG",
            .chat => "CHAT",
            .chat_sync => "CHAT_SYNC",
        };
    }
};

pub fn encodeFrame(alloc: std.mem.Allocator, payload: []const u8) ![]u8 {
    if (payload.len > std.math.maxInt(u32)) return error.FrameTooLarge;
    const out = try alloc.alloc(u8, 4 + payload.len);
    std.mem.writeInt(u32, out[0..4], @intCast(payload.len), .big);
    @memcpy(out[4..], payload);
    return out;
}

pub const Decoded = struct {
    payload: []const u8,
    consumed: usize,
};

pub fn decodeFrame(buf: []const u8, max_frame_bytes: u32) !?Decoded {
    if (buf.len < 4) return null;
    const n = std.mem.readInt(u32, buf[0..4], .big);
    if (n > max_frame_bytes) return error.FrameTooLarge;
    if (buf.len < 4 + n) return null;
    return .{ .payload = buf[4 .. 4 + n], .consumed = 4 + n };
}

pub const Header = struct {
    version: []const u8,
    kind: Kind,
    id: []const u8,
    from: []const u8,
    to: ?[]const u8 = null,
};

pub fn parseHeader(arena: std.mem.Allocator, payload: []const u8) !Header {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{});
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.InvalidFrame,
    };
    const version = switch (obj.get("version") orelse return error.InvalidFrame) {
        .string => |s| s,
        else => return error.InvalidFrame,
    };
    if (!compatibleVersion(version)) return error.VersionMismatch;
    const kind_s = switch (obj.get("kind") orelse return error.InvalidFrame) {
        .string => |s| s,
        else => return error.InvalidFrame,
    };
    const kind = Kind.fromStr(kind_s) orelse return error.UnknownKind;
    const id = switch (obj.get("id") orelse return error.InvalidFrame) {
        .string => |s| s,
        else => return error.InvalidFrame,
    };
    const from = switch (obj.get("from") orelse return error.InvalidFrame) {
        .string => |s| s,
        else => return error.InvalidFrame,
    };
    const to: ?[]const u8 = switch (obj.get("to") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => null,
    };
    return .{ .version = version, .kind = kind, .id = id, .from = from, .to = to };
}

/// Major must match. Minor may advance; unknown optional fields are ignored.
pub fn compatibleVersion(v: []const u8) bool {
    if (v.len == 0) return false;
    const dot = std.mem.indexOfScalar(u8, v, '.') orelse return false;
    const major = v[0..dot];
    return std.mem.eql(u8, major, "1");
}

/// Receiver overwrites `from` with the JOIN-bound id. A member cannot spoof.
pub fn boundFrom(join_id: []const u8, _: []const u8) []const u8 {
    return join_id;
}

pub const Admission = enum { allowlist, prompt, open };

pub const PeerSeed = struct {
    name: []const u8,
    id: []const u8 = "",
};

pub const Decision = enum { accept, refuse, pending };

pub fn admit(
    mode: Admission,
    our_id: []const u8,
    join_id: []const u8,
    join_name: []const u8,
    seeds: []const PeerSeed,
) Decision {
    if (join_id.len == 0) return .refuse;
    if (std.mem.eql(u8, join_id, our_id)) return .refuse;
    if (matchesSeed(join_id, join_name, seeds)) return .accept;
    return switch (mode) {
        .allowlist => .refuse,
        .prompt => .pending,
        .open => .accept,
    };
}

fn matchesSeed(join_id: []const u8, join_name: []const u8, seeds: []const PeerSeed) bool {
    for (seeds) |s| {
        if (s.id.len > 0) {
            if (std.mem.eql(u8, s.id, join_id)) return true;
        } else if (std.mem.eql(u8, s.name, join_name)) return true;
    }
    return false;
}

pub const Drop = enum { remove, mark_unreachable };

/// Explicit LEAVE removes the row. TCP drop / timeout keeps it for redial.
pub fn onDisconnect(explicit_leave: bool) Drop {
    return if (explicit_leave) .remove else .mark_unreachable;
}

/// Keep the connection on which the lexicographically smaller id is the dialer.
pub fn keepSimultaneous(our_id: []const u8, peer_id: []const u8, we_dialed: bool) bool {
    const we_are_smaller = std.mem.lessThan(u8, our_id, peer_id);
    return we_dialed == we_are_smaller;
}

/// CHAT_SYNC / chat id-dedup: keep messages whose id is not already seen.
pub fn unseenIds(seen: []const []const u8, incoming: []const []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    for (incoming) |id| {
        var have = false;
        for (seen) |s| {
            if (std.mem.eql(u8, s, id)) {
                have = true;
                break;
            }
        }
        if (have) continue;
        if (n >= out.len) break;
        out[n] = id;
        n += 1;
    }
    return n;
}

test "frame encode/decode is length-prefixed and rejects oversized" {
    const payload = "{\"kind\":\"PING\"}";
    const frame = try encodeFrame(std.testing.allocator, payload);
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqual(@as(usize, 4 + payload.len), frame.len);
    try std.testing.expectEqual(@as(u32, @intCast(payload.len)), std.mem.readInt(u32, frame[0..4], .big));

    const dec = (try decodeFrame(frame, default_max_frame_bytes)).?;
    try std.testing.expectEqualStrings(payload, dec.payload);
    try std.testing.expectEqual(frame.len, dec.consumed);

    try std.testing.expect((try decodeFrame(frame[0..3], default_max_frame_bytes)) == null);
    try std.testing.expectError(error.FrameTooLarge, decodeFrame(frame, 1));
}

test "header parse binds version and known kinds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const h = try parseHeader(arena,
        \\{"version":"1.0","kind":"JOIN","id":"f1","from":"aaa","to":"bbb"}
    );
    try std.testing.expectEqual(Kind.join, h.kind);
    try std.testing.expectEqualStrings("aaa", h.from);
    try std.testing.expectError(error.VersionMismatch, parseHeader(arena,
        \\{"version":"2.0","kind":"PING","id":"x","from":"a"}
    ));
    try std.testing.expectError(error.UnknownKind, parseHeader(arena,
        \\{"version":"1.0","kind":"FILE_OFFER","id":"x","from":"a"}
    ));
    try std.testing.expect(compatibleVersion("1.3"));
    try std.testing.expect(!compatibleVersion("0.9"));
}

test "from on the wire is overwritten by the JOIN-bound id" {
    try std.testing.expectEqualStrings("real-id", boundFrom("real-id", "spoofed"));
}

test "admission: allowlist / prompt / open / self / empty" {
    const seeds = [_]PeerSeed{
        .{ .name = "alice", .id = "aaa" },
        .{ .name = "bob" },
    };
    try std.testing.expectEqual(Decision.refuse, admit(.allowlist, "me", "", "x", &seeds));
    try std.testing.expectEqual(Decision.refuse, admit(.open, "me", "me", "me", &seeds));
    try std.testing.expectEqual(Decision.accept, admit(.allowlist, "me", "aaa", "alice", &seeds));
    try std.testing.expectEqual(Decision.accept, admit(.allowlist, "me", "zzz", "bob", &seeds));
    try std.testing.expectEqual(Decision.refuse, admit(.allowlist, "me", "zzz", "carol", &seeds));
    try std.testing.expectEqual(Decision.pending, admit(.prompt, "me", "zzz", "carol", &seeds));
    try std.testing.expectEqual(Decision.accept, admit(.open, "me", "zzz", "carol", &seeds));
}

test "LEAVE removes; TCP drop keeps the row for redial" {
    try std.testing.expectEqual(Drop.remove, onDisconnect(true));
    try std.testing.expectEqual(Drop.mark_unreachable, onDisconnect(false));
}

test "simultaneous open keeps the smaller-id dialer" {
    // "aaa" < "bbb": keep the connection where aaa dialed.
    try std.testing.expect(keepSimultaneous("aaa", "bbb", true));
    try std.testing.expect(!keepSimultaneous("aaa", "bbb", false));
    try std.testing.expect(!keepSimultaneous("bbb", "aaa", true));
    try std.testing.expect(keepSimultaneous("bbb", "aaa", false));
}

test "CHAT_SYNC id-dedup keeps only unseen ids" {
    const seen = [_][]const u8{ "m1", "m2" };
    const incoming = [_][]const u8{ "m2", "m3", "m1", "m4" };
    var out: [4][]const u8 = undefined;
    const n = unseenIds(&seen, &incoming, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("m3", out[0]);
    try std.testing.expectEqualStrings("m4", out[1]);
}
