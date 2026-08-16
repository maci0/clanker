//! Persistent eval kernels. Off by default (`kernel.enabled = false`).
//! Python cells run WASI-sandboxed when the vendored interpreter is present
//! (ADR 0010); without it the host falls back to a deprecated unsandboxed
//! `python3` subprocess. This guest refuses when disabled and reports a
//! missing runtime clearly. The host registry (PRD 0016/0017) owns process
//! lifetime.

const std = @import("std");
const lib = @import("lib.zig");
const magic = @import("kernel_magic.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const cfg = lib.parseHarnessConfig();
    if (!cfg.kernel.enabled) {
        return lib.fail(out, "kernel is disabled (kernel.enabled = false); enable it in config.toml to run Python/JS cells");
    }

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");
    const obj = parsed.object;
    const kind = switch (obj.get("kernel") orelse std.json.Value{ .string = "python" }) {
        .string => |s| s,
        else => "python",
    };
    const cell = switch (obj.get("cell") orelse return lib.fail(out, "missing cell")) {
        .string => |s| s,
        else => return lib.fail(out, "cell must be a string"),
    };
    const reset = switch (obj.get("reset") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };
    const timeout: i64 = switch (obj.get("timeout_ms") orelse std.json.Value{ .integer = 10000 }) {
        .integer => |n| n,
        else => 10000,
    };
    const timeout_ms: u32 = if (timeout <= 0) 10000 else @intCast(@min(timeout, std.math.maxInt(u32)));

    const parsed_cell = magic.parse(cell);
    if (std.mem.eql(u8, kind, "js")) {
        return lib.fail(out, "js kernel not started: bun worker is still landing");
    }
    if (!std.mem.eql(u8, kind, "python")) {
        return lib.fail(out, "kernel must be \"python\" or \"js\"");
    }

    var req: std.Io.Writer.Allocating = .init(lib.alloc);
    var s = std.json.Stringify{ .writer = &req.writer };
    try s.beginObject();
    try s.objectField("kernel");
    try s.write("python");
    try s.objectField("reset");
    try s.write(reset);
    try s.objectField("timeout_ms");
    try s.write(timeout_ms);
    switch (parsed_cell.kind) {
        .pip => {
            try s.objectField("pip");
            try s.write(parsed_cell.rest);
        },
        .bash, .bang => {
            try s.objectField("bash");
            try s.write(parsed_cell.rest);
        },
        .time, .cell => {
            try s.objectField("cell");
            try s.write(parsed_cell.rest);
        },
    }
    try s.endObject();
    const raw = lib.kernelEval(req.written()) catch |err| {
        return lib.failErr(out, err, "ck_kernel");
    };
    if (parsed_cell.kind == .time) {
        try out.writeAll(raw);
        try out.writeAll("\nWall time: see duration_ms");
        return;
    }
    try out.writeAll(raw);
}
