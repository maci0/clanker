//! symbolic_regression: search for a closed-form expression that fits
//! numeric data. Pure compute, no host calls.
//!
//! Input:  {"x":[...],"y":[...]} | {"x":[[...],...],"y":[...]} |
//!         {"rows":[[x1,...,y],...]} | {"csv":"x,y\\n1,3"}
//!         optional: iterations, seed, operators, variables
//! Output: {"ok":true,"equations":[{"expr","complexity","mse"},...]}
//!
//! This is the same *job* as astroautomata/symbolic_regression.rs
//! (Miles Cranmer / PySR lineage): a Pareto front of expressions.
//! Their published wasm is wasm-bindgen + rayon and cannot load as a
//! clanker guest, so the search runs here.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("symbolic_regression_logic.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{}) catch
        return lib.fail(out, "input must be a JSON object with x/y, rows, or csv");
    if (parsed != .object) return lib.fail(out, "input must be a JSON object with x/y, rows, or csv");

    const data = logic.parseOwned(lib.alloc, parsed.object) catch |err| return lib.fail(out, switch (err) {
        error.Empty => "need at least one (x, y) row",
        error.TooManyRows => "at most 200 rows",
        error.TooManyFeatures => "at most 6 input columns (plus y)",
        error.LengthMismatch => "x and y must be the same length; every row the same width",
        error.OutOfMemory => "out of memory",
        error.BadInput => "need {x,y}, {rows} (last column is y), or {csv}",
    });

    var gens: u16 = logic.default_generations;
    if (parsed.object.get("iterations")) |v| {
        const n = logic.asNumber(v) orelse return lib.fail(out, "iterations must be a number");
        if (n < 1 or n != @floor(n)) return lib.fail(out, "iterations must be a positive integer");
        const as_f: f64 = @min(n, 65535);
        gens = logic.clampGenerations(@as(u16, @intFromFloat(@trunc(as_f))));
    }

    var seed: u64 = 1;
    if (parsed.object.get("seed")) |v| {
        const n = logic.asNumber(v) orelse return lib.fail(out, "seed must be a number");
        if (n < 0 or n != @floor(n)) return lib.fail(out, "seed must be a non-negative integer");
        const cap: f64 = @floatFromInt(std.math.maxInt(u32));
        seed = @as(u64, @intFromFloat(@trunc(@min(n, cap))));
    }

    var opbuf: [10]logic.Op = undefined;
    var nops: usize = 0;
    if (parsed.object.get("operators")) |v| {
        if (v != .array) return lib.fail(out, "operators must be an array of names");
        for (v.array.items) |item| {
            if (item != .string) return lib.fail(out, "operators must be strings");
            const op = logic.parseOpName(item.string) orelse
                return lib.fail(out, "unknown operator; use + - * / neg sin cos exp log");
            if (nops < opbuf.len) {
                opbuf[nops] = op;
                nops += 1;
            }
        }
    }
    const ops: []const logic.Op = if (nops == 0) logic.default_ops[0..] else opbuf[0..nops];

    var names: [logic.max_features][]const u8 = undefined;
    var nnames: usize = 0;
    if (parsed.object.get("variables")) |v| {
        if (v != .array) return lib.fail(out, "variables must be an array of names");
        for (v.array.items) |item| {
            if (item != .string) return lib.fail(out, "variables must be strings");
            if (nnames < names.len) {
                names[nnames] = item.string;
                nnames += 1;
            }
        }
    }

    const found = logic.search(data.dataset(), .{
        .generations = gens,
        .seed = seed,
        .ops = ops,
    });

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("n_rows");
    try s.write(data.n_rows);
    try s.objectField("n_features");
    try s.write(data.n_features);
    try s.objectField("equations");
    try s.beginArray();
    var i: u8 = 0;
    while (i < found.len) : (i += 1) {
        var ebuf: [160]u8 = undefined;
        const expr = logic.formatTree(&found.items[i].t, names[0..nnames], &ebuf);
        try s.beginObject();
        try s.objectField("expr");
        try s.write(expr);
        try s.objectField("complexity");
        try s.write(found.items[i].c);
        try s.objectField("mse");
        try s.write(found.items[i].mse);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}
