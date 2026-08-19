//! Executes autoresearch harness commands and extracts their numeric metrics.

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
                // A measurement must be finite: `1e999` parses to +inf, and a
                // non-finite "best" is unbeatable (NaN/Inf comparisons are all
                // false), which wedges the loop and can promote a patch on
                // garbage. Same guard as extractMetric below.
                if (std.math.isFinite(v) and (slice.len > 1 or (slice[0] >= '0' and slice[0] <= '9'))) return v;
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
                    // Non-finite values are "no metric", not a measurement:
                    // once inf or NaN is adopted as best, no real value ever
                    // beats it, so the run would promote on garbage and then
                    // refuse every honest improvement. Fall through to the
                    // stdout/stderr scan like any other absent value.
                    if (f) |val| if (std.math.isFinite(val)) return val;
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
        while (std.mem.findPos(u8, hay, search, pattern)) |pos| {
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
test "extractMetric handles negatives and scientific notation" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const neg = extractMetric(gpa, io, tmp.dir, "score: -0.5 done", "", "score", "score:");
    try std.testing.expect(neg != null and @abs(neg.? - (-0.5)) < 1e-9);
    const sci = extractMetric(gpa, io, tmp.dir, "score: 1.2e3 end", "", "score", "score:");
    try std.testing.expect(sci != null and @abs(sci.? - 1200.0) < 1e-9);
    const none = extractMetric(gpa, io, tmp.dir, "no numbers", "", "x", "");
    try std.testing.expect(none == null);
}
test "extractMetric rejects non-finite values instead of adopting them as best" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // metric.json overflow: 1e999 parses to +inf. It must not become the best
    // (an inf best can never be beaten), so extraction falls through to stdout.
    try tmp.dir.writeFile(io, .{ .sub_path = "metric.json", .data = "{\"score\": 1e999}" });
    const m = extractMetric(gpa, io, tmp.dir, "score: 0.5", "", "score", "score:");
    try std.testing.expect(m != null and @abs(m.? - 0.5) < 1e-9);
    // A non-finite metric.json alone reads as no metric at all.
    try std.testing.expect(extractMetric(gpa, io, tmp.dir, "no numbers here", "", "score", "score:") == null);
    // A non-finite literal on stdout never escapes as the metric: extraction
    // either keeps scanning (the exponent's digits re-scan as a finite "999")
    // or yields nothing, so the promote decision never sees inf/NaN.
    const after = extractMetric(gpa, io, tmp.dir, "score: 1e999 and 2.5", "", "score", "score:");
    try std.testing.expect(after != null and std.math.isFinite(after.?));
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
