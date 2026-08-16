//! Pure ledger logic for the autoresearch engine, shared between the native
//! loop (`src/research/auto_research.zig`) and the `autoresearch` WASM tool
//! (`tools/zig/autoresearch.zig`). The tool owns the ledger write
//! (`op: "append"`, fs-scoped to state/autoresearch/); the loop imports the
//! same module for the per-iteration compare and for the stdout/stderr tails
//! it must cap before sending them through the guest arena.
//!
//! Host-tested: pure `std` logic, no guest ABI, no filesystem.

const std = @import("std");

pub const Entry = struct {
    iter: u32,
    ts: i64,
    summary: []const u8 = "",
    ok: bool = false,
    metric: ?f64 = null,
    metric_name: []const u8 = "",
    duration_ms: u64 = 0,
    detail: []const u8 = "",
    stdout_tail: []const u8 = "",
    stderr_tail: []const u8 = "",
};

/// Bytes of harness output kept in a ledger entry: enough to re-read what the
/// harness printed without bloating the run record.
pub const output_tail_bytes = 2000;

pub fn tail(text: []const u8, keep: usize) []const u8 {
    if (text.len <= keep) return text;
    const head = text[text.len - keep ..];
    if (std.mem.findScalar(u8, head, '\n')) |nl| return head[nl + 1 ..];
    return head;
}

/// Renders one ledger line, the exact shape the loop used to write natively:
///   {"iter":N,"ts":N,"summary":"...","ok":true,"metric":1.0,"metric_name":"x",
///    "duration_ms":N,"detail":"..."[,"stdout_tail":"..."][,"stderr_tail":"..."]}
pub fn entryLine(arena: std.mem.Allocator, entry: Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("iter");
    try s.print("{d}", .{entry.iter});
    try s.objectField("ts");
    try s.print("{d}", .{entry.ts});
    try s.objectField("summary");
    try s.write(entry.summary);
    try s.objectField("ok");
    try s.write(entry.ok);
    if (entry.metric) |m| {
        try s.objectField("metric");
        try s.print("{d}", .{m});
        try s.objectField("metric_name");
        try s.write(entry.metric_name);
    }
    try s.objectField("duration_ms");
    try s.print("{d}", .{entry.duration_ms});
    if (entry.detail.len > 0) {
        try s.objectField("detail");
        try s.write(entry.detail);
    }
    if (entry.stdout_tail.len > 0) {
        try s.objectField("stdout_tail");
        try s.write(entry.stdout_tail);
    }
    if (entry.stderr_tail.len > 0) {
        try s.objectField("stderr_tail");
        try s.write(entry.stderr_tail);
    }
    try s.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn isBetter(new_val: f64, best_val: ?f64, direction: []const u8) bool {
    if (best_val == null) return true;
    if (std.mem.eql(u8, direction, "max")) return new_val > best_val.?;
    return new_val < best_val.?;
}

/// Best metric among the `ok: true` entries of a raw ledger dump. Pure over
/// the ledger text so the same scan serves host code and (if ever needed) a
/// guest op without an fs dependency.
pub fn bestMetricOf(arena: std.mem.Allocator, raw: []const u8, direction: []const u8) ?f64 {
    var best: ?f64 = null;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch continue;
        if (v != .object) continue;
        const ok_val = v.object.get("ok") orelse continue;
        if (ok_val != .bool or !ok_val.bool) continue;
        const m_val = v.object.get("metric") orelse continue;
        const m: f64 = switch (m_val) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            .number_string => |str| std.fmt.parseFloat(f64, str) catch continue,
            else => continue,
        };
        if (best == null) {
            best = m;
        } else if (std.mem.eql(u8, direction, "max")) {
            if (m > best.?) best = m;
        } else {
            if (m < best.?) best = m;
        }
    }
    return best;
}

test "isBetter respects direction" {
    try std.testing.expect(isBetter(1.0, null, "min"));
    try std.testing.expect(isBetter(0.5, 1.0, "min"));
    try std.testing.expect(!isBetter(2.0, 1.0, "min"));
    try std.testing.expect(isBetter(2.0, 1.0, "max"));
    try std.testing.expect(!isBetter(0.5, 1.0, "max"));
    // equal values are not better in either direction
    try std.testing.expect(!isBetter(1.0, 1.0, "min"));
    try std.testing.expect(!isBetter(1.0, 1.0, "max"));
}

test "tail keeps last lines" {
    try std.testing.expectEqualStrings("hello", tail("hello", 10));
    // The last `keep` bytes, minus the partial line they start inside. For
    // "a\nb\nc\nd\ne\nf" (11 bytes) the last 3 are "e\nf", whose first line is
    // the partial "e", so only "f" survives; the last 4 are "\ne\nf", where the
    // partial line is empty and "e\nf" survives whole. 5 lands mid-"d" and so
    // keeps the same two lines as 4.
    try std.testing.expectEqualStrings("f", tail("a\nb\nc\nd\ne\nf", 3));
    try std.testing.expectEqualStrings("e\nf", tail("a\nb\nc\nd\ne\nf", 4));
    try std.testing.expectEqualStrings("e\nf", tail("a\nb\nc\nd\ne\nf", 5));
    try std.testing.expectEqualStrings("d\ne\nf", tail("a\nb\nc\nd\ne\nf", 7));
}

test "entryLine renders the ledger shape" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const line = try entryLine(arena_state.allocator(), .{
        .iter = 0,
        .ts = 1,
        .summary = "s",
        .ok = true,
        .metric = 2.0,
        .metric_name = "x",
        .duration_ms = 3,
        .detail = "d",
        .stdout_tail = "out",
        .stderr_tail = "err",
    });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), line, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(i64, 0), parsed.object.get("iter").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed.object.get("ts").?.integer);
    try std.testing.expectEqualStrings("s", parsed.object.get("summary").?.string);
    try std.testing.expect(parsed.object.get("ok").?.bool);
    // `{d}` renders 2.0 as "2", so the metric round-trips as integer.
    const mv = parsed.object.get("metric").?;
    const m: f64 = switch (mv) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return error.UnexpectedMetricType,
    };
    try std.testing.expect(m == 2.0);
    try std.testing.expectEqualStrings("x", parsed.object.get("metric_name").?.string);
    try std.testing.expectEqual(@as(i64, 3), parsed.object.get("duration_ms").?.integer);
    try std.testing.expectEqualStrings("d", parsed.object.get("detail").?.string);
    try std.testing.expectEqualStrings("out", parsed.object.get("stdout_tail").?.string);
    try std.testing.expectEqualStrings("err", parsed.object.get("stderr_tail").?.string);
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
}

test "bestMetricOf reads a ledger dump" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const raw = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{
        try entryLine(arena, .{ .iter = 0, .ts = 1, .ok = true, .metric = 2.0, .metric_name = "x" }),
        try entryLine(arena, .{ .iter = 1, .ts = 2, .ok = true, .metric = 1.0, .metric_name = "x" }),
        try entryLine(arena, .{ .iter = 2, .ts = 3, .ok = false, .metric = 0.1, .metric_name = "x" }),
    });
    const best_min = bestMetricOf(arena, raw, "min");
    try std.testing.expect(best_min != null and best_min.? == 1.0);
    const best_max = bestMetricOf(arena, raw, "max");
    try std.testing.expect(best_max != null and best_max.? == 2.0);
}
