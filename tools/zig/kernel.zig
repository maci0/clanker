//! Persistent eval kernels. Off by default (`kernel.enabled = false`): a
//! kernel is an unsandboxed subprocess. This guest refuses when disabled
//! and reports a missing runtime clearly. The host registry (PRD 0016/0017)
//! owns process lifetime.

const std = @import("std");
const lib = @import("lib.zig");
const magic = @import("kernel_magic.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const cfg = lib.parseHarnessConfig();
    if (!cfg.kernel.enabled) {
        return lib.fail(out, "kernel is disabled (kernel.enabled = false); this is an unsandboxed subprocess and stays opt-in");
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
    _ = reset;

    const parsed_cell = magic.parse(cell);
    switch (parsed_cell.kind) {
        .bash, .bang => {
            return lib.fail(out, "%%bash / !cmd require ck_exec wiring; not started because kernel.enabled is a host-side spawn");
        },
        .pip, .time, .cell => {},
    }

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
    try s.objectField("cell");
    try s.write(parsed_cell.rest);
    try s.endObject();
    const raw = lib.kernelEval(req.written()) catch |err| {
        return lib.failErr(out, err, "ck_kernel");
    };
    try out.writeAll(raw);
}
