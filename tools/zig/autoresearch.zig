//! autoresearch: list runs, tail a run's ledger, or append a run's ledger
//! entry. `op: "append"` is the ledger write the native engine loop
//! (`src/autoresearch/loop.zig`) calls once per iteration, fs-scoped to
//! state/autoresearch/ like the read ops; the entry shape and the stdout/
//! stderr tail live in autoresearch_logic.zig, shared with the native loop.
const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("autoresearch_logic.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{});
    const obj = if (root == .object) root.object else return lib.fail(out, "expected JSON object");
    const op: []const u8 = blk: {
        if (obj.get("op")) |v| if (v == .string) break :blk v.string;
        break :blk "";
    };
    if (std.mem.eql(u8, op, "append")) return appendEntry(out, obj);
    if (op.len > 0 and !std.mem.eql(u8, op, "list") and !std.mem.eql(u8, op, "tail")) {
        return lib.fail(out, "unknown op");
    }
    return readLedger(out, obj);
}

fn appendEntry(out: *lib.Out, obj: std.json.ObjectMap) !void {
    const alloc = lib.alloc;
    const run_id: []const u8 = blk: {
        if (obj.get("run")) |v| if (v == .string and v.string.len > 0) break :blk v.string;
        break :blk "";
    };
    if (run_id.len == 0) return lib.fail(out, "append needs a run id");
    const metric: ?f64 = blk: {
        if (obj.get("metric")) |v| {
            const f: ?f64 = switch (v) {
                .float => |x| x,
                .integer => |x| @floatFromInt(x),
                .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
                else => null,
            };
            // Keep non-finite values out of the ledger: `1e999` parses to
            // +inf, and a non-finite best can never be beaten, so a run that
            // reads it back wedges on garbage. Mirrors the guard in
            // harness.zig's extractMetric.
            if (f) |m| if (std.math.isFinite(m)) break :blk m;
        }
        break :blk null;
    };
    const entry = logic.Entry{
        .iter = @intCast(@min(jsonUnsigned(obj, "iter"), std.math.maxInt(u32))),
        .ts = jsonInt(obj, "ts"),
        .summary = jsonString(obj, "summary"),
        .ok = jsonBool(obj, "ok"),
        .metric = metric,
        .metric_name = jsonString(obj, "metric_name"),
        .duration_ms = jsonUnsigned(obj, "duration_ms"),
        .detail = jsonString(obj, "detail"),
        .stdout_tail = logic.tail(jsonString(obj, "stdout"), logic.output_tail_bytes),
        .stderr_tail = logic.tail(jsonString(obj, "stderr"), logic.output_tail_bytes),
    };
    const line = try logic.entryLine(alloc, entry);
    const path = try std.fmt.allocPrint(alloc, "state/autoresearch/{s}/ledger.jsonl", .{run_id});
    lib.fsAppend(path, line) catch return lib.fail(out, "append failed");
    return lib.okText(out, "{\"ok\":true}");
}

fn readLedger(out: *lib.Out, obj: std.json.ObjectMap) !void {
    const alloc = lib.alloc;
    var last: usize = 20;
    if (obj.get("last")) |v| if (v == .integer and v.integer > 0) {
        last = @intCast(v.integer);
    };
    const run_id: []const u8 = blk: {
        if (obj.get("run")) |v| if (v == .string) break :blk v.string;
        break :blk "";
    };
    const base: []const u8 = if (run_id.len > 0) try std.fmt.allocPrint(alloc, "state/autoresearch/{s}", .{run_id}) else "state/autoresearch";
    if (run_id.len == 0) {
        const listing = lib.fsList(base) catch return lib.fail(out, "no autoresearch runs yet");
        return lib.okText(out, listing);
    }
    const ledger_path = try std.fmt.allocPrint(alloc, "{s}/ledger.jsonl", .{base});
    const ledger = lib.fsRead(ledger_path) catch return lib.fail(out, "no ledger for that run");
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    var it = std.mem.splitScalar(u8, ledger, '\n');
    while (it.next()) |line| {
        const t2 = std.mem.trim(u8, line, " \t\r");
        if (t2.len > 0) try lines.append(alloc, t2);
    }
    const start: usize = if (lines.items.len > last) lines.items.len - last else 0;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (lines.items[start..]) |line| {
        try buf.appendSlice(alloc, line);
        try buf.append(alloc, '\n');
    }
    if (buf.items.len == 0) return lib.fail(out, "ledger empty");
    return lib.okText(out, buf.items);
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get(key)) |v| if (v == .string) return v.string;
    return "";
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    if (obj.get(key)) |v| if (v == .integer) return v.integer;
    return 0;
}

fn jsonUnsigned(obj: std.json.ObjectMap, key: []const u8) u64 {
    if (obj.get(key)) |v| if (v == .integer) return @intCast(@max(v.integer, 0));
    return 0;
}

fn jsonBool(obj: std.json.ObjectMap, key: []const u8) bool {
    if (obj.get(key)) |v| if (v == .bool) return v.bool;
    return false;
}
