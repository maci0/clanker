//! zig_test: run one Zig test file (optionally filtered), skipping the full gate.
//! Input:  {"file": "src/foo.zig", "filter": "test name"}
//! Output: {"ok": true, "code": 0, "stdout": "...", "stderr": "..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const file = switch (obj.get("file") orelse return lib.fail(out, "missing file")) {
        .string => |s| s,
        else => return lib.fail(out, "file must be a string"),
    };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(lib.alloc);
    try argv.append(lib.alloc, "test");
    try argv.append(lib.alloc, file);
    if (obj.get("filter")) |f| {
        if (f == .string and f.string.len > 0) {
            try argv.append(lib.alloc, "--test-filter");
            try argv.append(lib.alloc, f.string);
        }
    }
    const raw = lib.exec("zig", argv.items) catch |err| return lib.failErr(out, err, "running zig test");

    const exec_parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{ .ignore_unknown_fields = true }) catch {
        return out.writeAll(raw);
    };
    if (exec_parsed != .object) return out.writeAll(raw);
    const exec_obj = exec_parsed.object;

    const code: i64 = if (exec_obj.get("code")) |c| switch (c) {
        .integer => |i| i,
        else => 1,
    } else 1;
    const ok = code == 0;

    const stdout_str = lib.jsonStrField(exec_obj, "stdout");
    const stderr_str = lib.jsonStrField(exec_obj, "stderr");

    const tail_cap: usize = 6 * 1024;
    const summary_cap: usize = 2 * 1024;

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(ok);
    try s.objectField("code");
    try s.print("{d}", .{code});
    if (ok) {
        // On success, include a short tail of stdout so the agent sees which tests ran.
        try s.objectField("output");
        if (stdout_str.len > summary_cap) {
            try s.write(stdout_str[stdout_str.len - summary_cap ..]);
        } else {
            try s.write(stdout_str);
        }
    } else {
        // On failure, keep the tail of stderr where the actual error message lives.
        try s.objectField("error_tail");
        const detail = if (stderr_str.len > 0) stderr_str else stdout_str;
        if (detail.len > tail_cap) {
            try s.write(detail[detail.len - tail_cap ..]);
        } else {
            try s.write(detail);
        }
    }
    try s.endObject();
    lib.commit(out, &w);
}
