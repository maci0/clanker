const std = @import("std");
pub const HarnessResult = struct {
    ok: bool,
    timed_out: bool = false,
    metric: ?f64 = null,
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},
    detail: []const u8 = "",
    duration_ms: u64 = 0,
    pub fn deinit(self: *HarnessResult, gpa: std.mem.Allocator) void {
        if (self.stdout.len > 0) gpa.free(self.stdout);
        if (self.stderr.len > 0) gpa.free(self.stderr);
    }
};
fn parseFirstFloat(text: []const u8) ?f64 {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '-' or c == '+' or (c >= '0' and c <= '9') or c == '.') {
            var end = i + 1;
            var seen_e = false;
            while (end < text.len) : (end += 1) {
                const d = text[end];
                if (d >= '0' and d <= '9') continue;
                if (d == '.' and !seen_e) continue;
                if ((d == 'e' or d == 'E') and !seen_e) {
                    seen_e = true;
                    continue;
                }
                if ((d == '+' or d == '-') and seen_e and end > 0 and (text[end - 1] == 'e' or text[end - 1] == 'E')) continue;
                break;
            }
            const slice = text[i..end];
            if (std.fmt.parseFloat(f64, slice)) |v| {
                if (slice.len > 1 or (slice[0] >= '0' and slice[0] <= '9')) return v;
            } else |_| {}
        }
    }
    return null;
}
pub fn extractMetric(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, stdout: []const u8, stderr: []const u8, metric_name: []const u8, pattern: []const u8) ?f64 {
    if (dir.readFileAlloc(io, "metric.json", gpa, .limited(64 * 1024)) catch null) |raw| {
        defer gpa.free(raw);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{})) |v| {
            if (v == .object) {
                if (v.object.get(metric_name)) |mv| {
                    const f: ?f64 = switch (mv) {
                        .float => |x| x,
                        .integer => |x| @floatFromInt(x),
                        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
                        else => null,
                    };
                    if (f) |val| return val;
                }
            }
        } else |_| {}
    }
    const haystacks = [_][]const u8{ stdout, stderr };
    for (haystacks) |hay| {
        if (pattern.len == 0) {
            if (parseFirstFloat(hay)) |v| return v;
            continue;
        }
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, hay, search, pattern)) |pos| {
            const after = hay[pos + pattern.len ..];
            if (parseFirstFloat(after)) |v| return v;
            search = pos + pattern.len;
        }
    }
    return null;
}
pub fn runHarness(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8, metric_name: []const u8, pattern: []const u8) !HarnessResult {
    const t0 = std.Io.Timestamp.now(io, .awake);
    const result = std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .dir = dir }, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(64 * 1024) }) catch |err| {
        return HarnessResult{ .ok = false, .detail = @errorName(err) };
    };
    var res = HarnessResult{ .ok = switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    }, .stdout = result.stdout, .stderr = result.stderr, .detail = if (result.term == .exited and result.term.exited == 0) "" else "non-zero exit", .duration_ms = @intCast(@divTrunc(t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds, std.time.ns_per_ms)) };
    res.metric = extractMetric(gpa, io, dir, res.stdout, res.stderr, metric_name, pattern);
    return res;
}
test "extractMetric from stdout substring" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const m = extractMetric(gpa, io, tmp.dir, "val_bpb: 1.23 ok", "", "val_bpb", "val_bpb:");
    try std.testing.expect(m != null and @abs(m.? - 1.23) < 1e-9);
}
test "extractMetric from metric.json" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "metric.json", .data = "{\"score\": 42.5}" });
    const m = extractMetric(gpa, io, tmp.dir, "no metric here", "", "score", "score:");
    try std.testing.expect(m != null and m.? == 42.5);
}
test "runHarness captures output" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runHarness(gpa, io, tmp.dir, &.{ "sh", "-c", "echo score: 3.14" }, "score", "score:");
    defer res.deinit(gpa);
    try std.testing.expect(res.ok);
    try std.testing.expect(res.metric != null and @abs(res.metric.? - 3.14) < 1e-9);
}
