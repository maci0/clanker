//! symbols: find where a Zig symbol is DECLARED (fn/const/var/struct/enum/union)
//! across the project, vs. the search_code tool which matches any occurrence.
//! Input:  {"name": "executeTool", "path": "src"}
//! Output: {"ok": true, "code": 0, "stdout": "...", "stderr": "..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const alloc = lib.alloc;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{});
    const obj = parsed.object;
    const name = switch (obj.get("name") orelse return lib.fail(out, "missing name")) {
        .string => |s| s,
        else => return lib.fail(out, "name must be a string"),
    };
    const path = if (obj.get("path")) |p| switch (p) {
        .string => |s| s,
        else => ".",
    } else ".";
    const kinds = [_][]const u8{ "fn", "const", "var", "struct", "enum", "union" };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, "-n");
    try argv.append(alloc, "-g");
    try argv.append(alloc, "*.zig");
    for (kinds) |k| {
        const e = try std.fmt.allocPrint(alloc, "^[[:space:]]*(pub[[:space:]]+)?{s}[[:space:]]+{s}\\b", .{ k, name });
        try argv.append(alloc, "-e");
        try argv.append(alloc, e);
    }
    try argv.append(alloc, path);
    const raw = lib.exec("rg", argv.items) catch |err| return lib.failErr(out, err, "running rg");

    // Parse the exec result to extract stdout.
    const exec_result = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{ .ignore_unknown_fields = true }) catch return lib.fail(out, "could not parse exec result");
    if (exec_result != .object) return lib.fail(out, "unexpected exec result");
    const stdout = if (exec_result.object.get("stdout")) |v| (if (v == .string) v.string else "") else "";

    // Parse ripgrep lines (file:line:text) into structured matches.
    var matches: std.ArrayList(struct { file: []const u8, line_no: u32, text: []const u8 }) = .empty;
    defer matches.deinit(alloc);
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon1 = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const rest1 = line[colon1 + 1 ..];
        const colon2 = std.mem.indexOfScalar(u8, rest1, ':') orelse continue;
        const file = line[0..colon1];
        const line_str = rest1[0..colon2];
        const text = rest1[colon2 + 1 ..];
        const line_no = std.fmt.parseInt(u32, line_str, 10) catch continue;
        try matches.append(alloc, .{ .file = file, .line_no = line_no, .text = std.mem.trim(u8, text, " \t") });
    }

    var w = out.writer();
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("matches");
    try s.beginArray();
    for (matches.items) |m| {
        try s.beginObject();
        try s.objectField("file");
        try s.write(m.file);
        try s.objectField("line");
        try s.write(m.line_no);
        try s.objectField("text");
        try s.write(m.text);
        try s.endObject();
    }
    try s.endArray();
    if (matches.items.len == 0) {
        try s.objectField("note");
        const note = try std.fmt.allocPrint(alloc, "no declarations of '{s}' found under '{s}'; try a broader path (e.g. \".\") or check spelling. This tool matches fn/const/var/struct/enum/union declarations only, not call sites (use search_code for those).", .{ name, path });
        try s.write(note);
    }
    try s.endObject();
    lib.commit(out, &w);
}
