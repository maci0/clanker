//! Cap and normalize provider error text before it reaches logs or telemetry.
//!
//! Provider error bodies can echo prompts, file paths, or credentials. Callers
//! still need a short reason; stderr and token_stats.jsonl must not carry the
//! full upstream payload.

const std = @import("std");

/// Max bytes written to stderr or `token_stats.jsonl` for one error field.
pub const max_log_detail_len: usize = 256;

/// Max bytes of provider error text returned to CLI/HTTP/tool callers.
pub const max_caller_detail_len: usize = 512;

fn normalizeInPlace(buf: []u8) void {
    for (buf) |*b| {
        if (b.* == '\n' or b.* == '\r' or b.* == '\t') b.* = ' ';
    }
}

/// Truncates `detail` into `stack_buf` and flattens whitespace for log lines.
pub fn forLog(stack_buf: []u8, detail: []const u8) []const u8 {
    const n = @min(detail.len, max_log_detail_len);
    @memcpy(stack_buf[0..n], detail[0..n]);
    normalizeInPlace(stack_buf[0..n]);
    return stack_buf[0..n];
}

/// Same cap as `forLog`, for durable token-usage telemetry.
pub fn forStats(stack_buf: []u8, detail: []const u8) []const u8 {
    return forLog(stack_buf, detail);
}

/// Arena-owned copy for operator-facing error strings (`err_detail`, tool JSON).
pub fn forCaller(arena: std.mem.Allocator, detail: []const u8) ![]const u8 {
    const n = @min(detail.len, max_caller_detail_len);
    const out = try arena.alloc(u8, n);
    @memcpy(out, detail[0..n]);
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
