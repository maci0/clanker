//! Cap and normalize provider error text before it reaches logs or telemetry.
//!
//! Provider error bodies can echo prompts, file paths, or credentials. Callers
//! still need a short reason; stderr and token_stats.jsonl must not carry the
//! full upstream payload.

const std = @import("std");
const utf8 = @import("utf8.zig");

/// Max bytes written to stderr or `token_stats.jsonl` for one error field.
pub const max_log_detail_len: usize = 256;

/// Max bytes of provider error text returned to CLI/HTTP/tool callers.
pub const max_caller_detail_len: usize = 512;

fn normalizeInPlace(buf: []u8) void {
    for (buf) |*b| {
        if (b.* == '\n' or b.* == '\r' or b.* == '\t') b.* = ' ';
    }
}

/// Cuts `detail` at `max_bytes`, never through a UTF-8 sequence: a raw byte
/// cut lands mid-codepoint and hands the caller invalid UTF-8, which then
/// reaches stderr and, via `forStats`, the JSON of a `token_stats.jsonl`
/// record the reader cannot parse. Returns `detail` unchanged when it fits.
fn capped(detail: []const u8, max_bytes: usize) []const u8 {
    return utf8.cap(detail, @min(detail.len, max_bytes));
}

/// Truncates `detail` into `stack_buf` and flattens whitespace for log lines.
pub fn forLog(stack_buf: []u8, detail: []const u8) []const u8 {
    const cut = capped(detail, max_log_detail_len);
    @memcpy(stack_buf[0..cut.len], cut);
    normalizeInPlace(stack_buf[0..cut.len]);
    return stack_buf[0..cut.len];
}

/// Same cap as `forLog`, for durable token-usage telemetry.
pub fn forStats(stack_buf: []u8, detail: []const u8) []const u8 {
    return forLog(stack_buf, detail);
}

/// Arena-owned copy for operator-facing error strings (`err_detail`, tool JSON).
pub fn forCaller(arena: std.mem.Allocator, detail: []const u8) ![]const u8 {
    const cut = capped(detail, max_caller_detail_len);
    const out = try arena.alloc(u8, cut.len);
    @memcpy(out, cut);
    normalizeInPlace(out);
    return out;
}

test "forLog truncates and flattens whitespace" {
    var buf: [max_log_detail_len]u8 = undefined;
    var long: [max_log_detail_len + 32]u8 = undefined;
    @memset(long[0..], 'x');
    long[10] = '\n';
    const out = forLog(&buf, long[0..]);
    try std.testing.expectEqual(@as(usize, max_log_detail_len), out.len);
    try std.testing.expectEqual(@as(u8, ' '), out[10]);
}

test "forCaller caps arena copies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var long: [max_caller_detail_len + 16]u8 = undefined;
    @memset(long[0..], 'y');
    const out = try forCaller(arena, long[0..]);
    try std.testing.expectEqual(@as(usize, max_caller_detail_len), out.len);
}

test "caps never cut through a multibyte character" {
    // A valid UTF-8 message longer than the cap where a 2-byte "é" straddles
    // the 256-byte cut. A raw byte cut emits a dangling continuation byte,
    // which std.json.Stringify silently degrades to a byte-number array when
    // serializing the token_stats.jsonl record (and stderr gets the raw
    // split bytes); the cap must back up to the previous codepoint boundary.
    const msg = "x" ** 255 ++ "\u{E9}" ++ "y";
    try std.testing.expect(msg.len > max_log_detail_len);
    var log_buf: [max_log_detail_len]u8 = undefined;
    const log_out = forLog(&log_buf, msg);
    try std.testing.expect(std.unicode.utf8ValidateSlice(log_out));
    try std.testing.expectEqual(@as(usize, 255), log_out.len);
    try std.testing.expectEqualStrings("x" ** 255, log_out);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // forCaller's cap is 512: a 2-byte char straddling that cut backs up too.
    const caller_msg = "x" ** 511 ++ "\u{E9}" ++ "y";
    const caller_out = try forCaller(arena, caller_msg);
    try std.testing.expect(std.unicode.utf8ValidateSlice(caller_out));
    try std.testing.expectEqual(@as(usize, 511), caller_out.len);
    try std.testing.expectEqualStrings("x" ** 511, caller_out);

    // A 3-byte char straddling the cut backs up over its lead byte too.
    const wide = "x" ** 255 ++ "\u{4E2D}" ++ "y"; // 中
    const wide_out = forLog(&log_buf, wide);
    try std.testing.expect(std.unicode.utf8ValidateSlice(wide_out));
    try std.testing.expectEqual(@as(usize, 255), wide_out.len);

    // A message that fits passes through byte-identical.
    const short = "caf\u{E9}";
    try std.testing.expectEqualStrings(short, forLog(&log_buf, short));
}
