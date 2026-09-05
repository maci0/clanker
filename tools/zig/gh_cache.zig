//! Disk cache records for `gh_read` (PRD 0019).
//!
//! One file per (url, token) pair under `state/gh_cache/`. The token is mixed
//! into the filename and a fingerprint is stored in the record so a different
//! GitHub identity cannot be served a previous identity's body. The token
//! itself is never written. Host-tested helper: no `lib.zig`, no host calls.

const std = @import("std");

/// Fixed TTL, in seconds. Soft/hard split is still open (PRD 0019).
pub const ttl_s: i64 = 300;

/// Directory the guest is granted. Keep in lockstep with the manifest.
pub const dir = "state/gh_cache";

/// Ceiling on expired files deleted in one put. The sandbox list is itself
/// capped at 200, so this is "a handful of the names we can see", not a
/// full drain of a huge directory.
pub const max_sweep: usize = 64;

pub const Record = struct {
    url: []const u8,
    /// Null on a pre-fingerprint record (`{"url","fetched","body"}` only).
    /// Those are never served: the body was fetched under an unknown token.
    token_fp: ?u64,
    fetched: i64,
    body: []const u8,
};

/// Filename stem: Wyhash of url, a NUL, then the token. A 64-bit collision
/// shares a file; `matches` is what makes that safe.
pub fn key(url: []const u8, token: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(url);
    h.update(&[_]u8{0});
    h.update(token);
    return h.final();
}

pub fn tokenFp(token: []const u8) u64 {
    return std.hash.Wyhash.hash(0x9E3779B97F4A7C15, token);
}

pub fn filePath(buf: []u8, k: u64) ![]u8 {
    return std.fmt.bufPrint(buf, dir ++ "/{x}.json", .{k});
}

pub fn isCacheFileName(name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, ".json")) return false;
    const stem = name[0 .. name.len - ".json".len];
    if (stem.len == 0 or stem.len > 16) return false;
    for (stem) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

pub fn fresh(fetched: i64, now: i64) bool {
    if (now < fetched) return false;
    return now - fetched <= ttl_s;
}

/// True when this record is the one `url`/`token` asked for.
/// A legacy record (no fingerprint) never matches: we cannot tell whose
/// token fetched it.
pub fn matches(rec: Record, url: []const u8, token: []const u8) bool {
    const fp = rec.token_fp orelse return false;
    return std.mem.eql(u8, rec.url, url) and fp == tokenFp(token);
}

/// Expired, or written before the token fingerprint existed. Both are safe
/// to delete: the first is past TTL, the second must not be served.
pub fn shouldDelete(rec: Record, now: i64) bool {
    if (rec.token_fp == null) return true;
    return !fresh(rec.fetched, now);
}

pub fn parse(alloc: std.mem.Allocator, raw: []const u8) ?Record {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch return null;
    if (parsed != .object) return null;
    const url = switch (parsed.object.get("url") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const fetched = switch (parsed.object.get("fetched") orelse return null) {
        .integer => |n| n,
        else => return null,
    };
    const body = switch (parsed.object.get("body") orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const token_fp: ?u64 = if (parsed.object.get("token_fp")) |v| switch (v) {
        .string => |s| std.fmt.parseInt(u64, s, 16) catch return null,
        else => return null,
    } else null;
    return .{ .url = url, .token_fp = token_fp, .fetched = fetched, .body = body };
}

pub fn writeRecord(
    writer: *std.Io.Writer,
    url: []const u8,
    token: []const u8,
    fetched: i64,
    body: []const u8,
) !void {
    var s = std.json.Stringify{ .writer = writer };
    try s.beginObject();
    try s.objectField("url");
    try s.write(url);
    try s.objectField("token_fp");
    var fp_buf: [16]u8 = undefined;
    const fp_hex = std.fmt.bufPrint(&fp_buf, "{x}", .{tokenFp(token)}) catch unreachable;
    try s.write(fp_hex);
    try s.objectField("fetched");
    try s.write(fetched);
    try s.objectField("body");
    try s.write(body);
    try s.endObject();
}

test "key differs across tokens for the same URL" {
    const url = "gh://issue/acme/widget/1";
    try std.testing.expect(key(url, "token-a") != key(url, "token-b"));
    try std.testing.expectEqual(key(url, "token-a"), key(url, "token-a"));
}

test "key differs across URLs for the same token" {
    const token = "token-a";
    try std.testing.expect(key("gh://issue/acme/widget/1", token) != key("gh://issue/acme/widget/2", token));
}

test "a delimiter inside the URL cannot collide with another URL plus token" {
    // url + NUL + token, so "ab"/"c" and "a"/"bc" cannot hash the same input.
    try std.testing.expect(key("ab", "c") != key("a", "bc"));
}

test "matches requires both the URL and the token fingerprint" {
    const rec = Record{
        .url = "gh://issue/acme/widget/1",
        .token_fp = tokenFp("token-a"),
        .fetched = 100,
        .body = "{}",
    };
    try std.testing.expect(matches(rec, rec.url, "token-a"));
    try std.testing.expect(!matches(rec, rec.url, "token-b"));
    try std.testing.expect(!matches(rec, "gh://issue/acme/widget/2", "token-a"));
}

test "a legacy record without a token fingerprint is never a hit" {
    const rec = Record{
        .url = "gh://issue/acme/widget/1",
        .token_fp = null,
        .fetched = 100,
        .body = "{}",
    };
    try std.testing.expect(!matches(rec, rec.url, "token-a"));
    try std.testing.expect(shouldDelete(rec, 100));
}

test "fresh is inclusive at the TTL and cold after" {
    try std.testing.expect(fresh(1_000, 1_000));
    try std.testing.expect(fresh(1_000, 1_000 + ttl_s));
    try std.testing.expect(!fresh(1_000, 1_000 + ttl_s + 1));
    try std.testing.expect(!fresh(1_000, 999));
}

test "shouldDelete is the inverse of fresh once a fingerprint is present" {
    const rec = Record{
        .url = "u",
        .token_fp = 1,
        .fetched = 50,
        .body = "{}",
    };
    try std.testing.expect(!shouldDelete(rec, 50));
    try std.testing.expect(shouldDelete(rec, 50 + ttl_s + 1));
}

test "parse round-trips a fingerprinted record and rejects a missing body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: std.Io.Writer.Allocating = .init(arena);
    try writeRecord(&buf.writer, "gh://issue/acme/widget/1", "token-a", 42, "{\"n\":1}");
    const rec = parse(arena, buf.written()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("gh://issue/acme/widget/1", rec.url);
    try std.testing.expectEqual(@as(?u64, tokenFp("token-a")), rec.token_fp);
    try std.testing.expectEqual(@as(i64, 42), rec.fetched);
    try std.testing.expectEqualStrings("{\"n\":1}", rec.body);
    try std.testing.expect(matches(rec, rec.url, "token-a"));
    try std.testing.expect(!matches(rec, rec.url, "token-b"));

    try std.testing.expect(parse(arena, "{\"url\":\"u\",\"fetched\":1}") == null);
}

test "parse reads a legacy record as unmatched and deletable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw =
        \\{"url":"gh://issue/acme/widget/1","fetched":10,"body":"{}"}
    ;
    const rec = parse(arena, raw) orelse return error.TestUnexpectedResult;
    try std.testing.expect(rec.token_fp == null);
    try std.testing.expect(!matches(rec, rec.url, "token-a"));
    try std.testing.expect(shouldDelete(rec, 10));
}

test "isCacheFileName accepts lowercase hex stems only" {
    try std.testing.expect(isCacheFileName("a1b2.json"));
    try std.testing.expect(isCacheFileName("0.json"));
    try std.testing.expect(!isCacheFileName("not-hex.json"));
    try std.testing.expect(!isCacheFileName("a1b2.txt"));
    try std.testing.expect(!isCacheFileName(".json"));
}

test "filePath stays under the granted prefix" {
    var buf: [80]u8 = undefined;
    const path = try filePath(&buf, 0xabc);
    try std.testing.expectEqualStrings("state/gh_cache/abc.json", path);
}
