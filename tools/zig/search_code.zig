//! search_code: search the project with ripgrep / ast-grep / semcode.
//! Input:  {"engine": "rg"|"ast-grep"|"semcode", "query": "...", "path": "."}
//! Output: {"ok": bool, "code": int, "stdout": "...", "stderr": "..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const engine = switch (obj.get("engine") orelse return lib.fail(out, "missing engine")) {
        .string => |s| s,
        else => return lib.fail(out, "engine must be a string"),
    };
    const query = switch (obj.get("query") orelse return lib.fail(out, "missing query")) {
        .string => |s| s,
        else => return lib.fail(out, "query must be a string"),
    };
    const path = if (obj.get("path")) |p| switch (p) {
        .string => |s| s,
        else => ".",
    } else ".";

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(lib.alloc);

    if (std.mem.eql(u8, engine, "rg")) {
        try args.append(lib.alloc, "--json");
        try args.append(lib.alloc, "-n");
        try args.append(lib.alloc, query);
        try args.append(lib.alloc, path);
    } else if (std.mem.eql(u8, engine, "ast-grep")) {
        try args.append(lib.alloc, "run");
        // ast-grep ships no Zig parser; sgconfig.yml registers one built by
        // tools/grammars/build.sh. Passing the config always (not only for
        // .zig) also picks up any rules the project defines.
        try args.append(lib.alloc, "--config");
        try args.append(lib.alloc, "sgconfig.yml");
        if (std.mem.endsWith(u8, path, ".zig") or std.mem.indexOf(u8, path, ".") == null) {
            // The Zig grammar is a custom language, so it has to be named:
            // ast-grep will not infer it from the extension alone.
            try args.append(lib.alloc, "-l");
            try args.append(lib.alloc, "zig");
        }
        try args.append(lib.alloc, "-p");
        try args.append(lib.alloc, query);
        try args.append(lib.alloc, path);
    } else if (std.mem.eql(u8, engine, "semcode")) {
        try args.append(lib.alloc, "-q");
        try args.append(lib.alloc, query);
    } else {
        return lib.fail(out, "engine must be rg | ast-grep | semcode");
    }

    const result = lib.exec(engine, args.items) catch |err| {
        return lib.fail(out, @errorName(err));
    };
    try out.writeAll(result);
}
