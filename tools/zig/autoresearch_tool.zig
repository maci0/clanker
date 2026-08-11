//! autoresearch: list runs or tail a run's ledger.
//! Input:  {"run": "<id>", "last": 20}  — no id lists runs.
const std = @import("std");
const lib = @import("lib.zig");
export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}
fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{});
    const obj = if (root == .object) root.object else return lib.fail(out, "expected JSON object");
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
