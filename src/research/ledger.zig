//! Persists autoresearch iteration results and compares recorded metrics.

const std = @import("std");
const atomic_write = @import("../util/atomic_write.zig");
const filelock = @import("../util/filelock.zig");
pub const Entry = struct { iter: u32, ts: i64, summary: []const u8 = "", ok: bool = false, metric: ?f64 = null, metric_name: []const u8 = "", duration_ms: u64 = 0, detail: []const u8 = "", stdout_tail: []const u8 = "", stderr_tail: []const u8 = "" };
fn tail(text: []const u8, keep: usize) []const u8 {
    if (text.len <= keep) return text;
    const head = text[text.len - keep ..];
    if (std.mem.findScalar(u8, head, '\n')) |nl| return head[nl + 1 ..];
    return head;
}
pub fn appendEntry(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, entry: Entry) !void {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
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
        try s.write(tail(entry.stdout_tail, 2000));
    }
    if (entry.stderr_tail.len > 0) {
        try s.objectField("stderr_tail");
        try s.write(tail(entry.stderr_tail, 2000));
    }
    try s.endObject();
    w.writeAll("\n") catch return error.WriteFailed;
    const line = buf[0..w.end];
    const lock = filelock.createFileRetry(io, dir, "ledger.lock", .{ .truncate = false, .lock = .exclusive }) catch null;
    defer if (lock) |f| f.close(io);
    const existing = dir.readFileAlloc(io, "ledger.jsonl", gpa, .limited(10 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |e| gpa.free(e);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (existing) |e| try out.appendSlice(gpa, e);
    try out.appendSlice(gpa, line);
    try atomic_write.writeFile(io, dir, "ledger.jsonl", out.items);
}
pub fn bestMetric(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, direction: []const u8) !?f64 {
    const raw = dir.readFileAlloc(io, "ledger.jsonl", gpa, .limited(10 << 20)) catch return null;
    defer gpa.free(raw);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
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
pub fn isBetter(new_val: f64, best_val: ?f64, direction: []const u8) bool {
    if (best_val == null) return true;
    if (std.mem.eql(u8, direction, "max")) return new_val > best_val.?;
    return new_val < best_val.?;
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
    try std.testing.expectEqualStrings("f", tail("a\nb\nc\nd\ne\nf", 4));
    try std.testing.expectEqualStrings("e\nf", tail("a\nb\nc\nd\ne\nf", 5));
}
test "bestMetric reads ledger" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try appendEntry(gpa, io, tmp.dir, .{ .iter = 0, .ts = 1, .ok = true, .metric = 2.0, .metric_name = "x" });
    try appendEntry(gpa, io, tmp.dir, .{ .iter = 1, .ts = 2, .ok = true, .metric = 1.0, .metric_name = "x" });
    try appendEntry(gpa, io, tmp.dir, .{ .iter = 2, .ts = 3, .ok = false, .metric = 0.1, .metric_name = "x" });
    const best_min = try bestMetric(gpa, io, tmp.dir, "min");
    try std.testing.expect(best_min != null and best_min.? == 1.0);
    const best_max = try bestMetric(gpa, io, tmp.dir, "max");
    try std.testing.expect(best_max != null and best_max.? == 2.0);
}

test "appendEntry preserves an oversized ledger" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const oversized = try gpa.alloc(u8, (10 << 20) + 1);
    defer gpa.free(oversized);
    @memset(oversized, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "ledger.jsonl", .data = oversized });

    try std.testing.expectError(error.StreamTooLong, appendEntry(gpa, io, tmp.dir, .{ .iter = 1, .ts = 1 }));
    const stat = try tmp.dir.statFile(io, "ledger.jsonl", .{});
    try std.testing.expectEqual(@as(u64, oversized.len), stat.size);
}
