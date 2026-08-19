//! calculator: pure arithmetic tool — no host function calls, so it can run
//! even with the most restrictive sandbox policy.
//!
//! Input:  {"a": <number>, "b": <number>, "op": "+" | "-" | "*" | "/" | "%" | "^"}
//!         or {"expr": "2+3*4"} (operators + - * / % ^, parentheses, precedence,
//!         sqrt(x) function)
//! Output: {"ok": true, "result": <number>}

const std = @import("std");
const lib = @import("lib.zig");

// Pure arithmetic — the two-operand apply and the expression parser — lives in
// calculator_logic.zig, listed in build.zig's host_tested_helpers so `zig build
// test` runs its tests (a wasm guest's own test blocks never run).
const calc = @import("calculator_logic.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object with \"expr\" or \"a\"/\"b\"/\"op\"");
    const obj = parsed.object;

    if (obj.get("expr")) |expr_val| {
        const expr = switch (expr_val) {
            .string => |s| s,
            else => return lib.fail(out, "expr must be a string"),
        };
        const result = calc.evalExpr(expr) catch |err| {
            return lib.fail(out, if (err == error.DivisionByZero) "division by zero" else "invalid expression");
        };
        var buf: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"result\":{d}}}", .{result});
        try out.writeAll(body);
        return;
    }

    const a: f64 = switch (obj.get("a") orelse return lib.fail(out, "missing a")) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return lib.fail(out, "a must be a number"),
    };
    const b: f64 = switch (obj.get("b") orelse return lib.fail(out, "missing b")) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return lib.fail(out, "b must be a number"),
    };
    const op = switch (obj.get("op") orelse return lib.fail(out, "missing op")) {
        .string => |s| s,
        else => return lib.fail(out, "op must be a string"),
    };
    const op_enum = calc.opFromStr(op) orelse
        return lib.fail(out, "unknown op; use + - * / % ^");

    const result = calc.applyOp(a, op_enum, b) catch
        return lib.fail(out, "division by zero");

    var buf: [128]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"result\":{d}}}", .{result});
    try out.writeAll(body);
}
