//! code_search: search open-source code via Sourcegraph's public search API
//! (grep.app's API is Vercel-blocked for non-browser clients; Sourcegraph is
//! the working equivalent). Returns matching repo/path/line snippets.
//! Input:  {"query": "readSliceShort", "lang": "zig", "max": 10}
//! Output: {"ok": true, "text": "<repo path:line — line>"}

const std = @import("std");
const lib = @import("lib.zig");

const Match = struct {
    type: []const u8 = "",
    path: []const u8 = "",
    repository: []const u8 = "",
    lineMatches: []const struct {
        line: []const u8 = "",
        lineNumber: i64 = 0,
    } = &.{},
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, std.heap.wasm_allocator, input, .{});
    const obj = parsed.object;
    const query = switch (obj.get("query") orelse return errJson(out, "missing query")) {
        .string => |s| s,
        else => return errJson(out, "query must be a string"),
    };
    var lang: []const u8 = "";
    if (obj.get("lang")) |l| {
        if (l == .string) lang = l.string;
    }
    var max: usize = 10;
    if (obj.get("max")) |m| {
        if (m == .integer) max = @intCast(m.integer);
    }

    const q = try encodeQuery(query);
    defer std.heap.wasm_allocator.free(q);
    const url = if (lang.len > 0)
        try std.fmt.allocPrint(std.heap.wasm_allocator, "https://sourcegraph.com/.api/search/stream?q=context:global+{s}+lang:{s}+count:{d}&display={d}", .{ q, lang, max, max })
    else
        try std.fmt.allocPrint(std.heap.wasm_allocator, "https://sourcegraph.com/.api/search/stream?q=context:global+{s}+count:{d}&display={d}", .{ q, max, max });
    defer std.heap.wasm_allocator.free(url);

    const body = lib.httpGet(url) catch |err| return errJson(out, @errorName(err));

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.heap.wasm_allocator);
    // SSE: lines of "event: matches" followed by "data: [<json array>]".
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "event: matches") != null) {
            const data_line = lines.next() orelse continue;
            if (std.mem.indexOf(u8, data_line, "data: ")) |d| {
                const arr = std.json.parseFromSliceLeaky([]const Match, std.heap.wasm_allocator, data_line[d + 6 ..], .{ .ignore_unknown_fields = true }) catch continue;
                for (arr) |m| {
                    for (m.lineMatches) |lm| {
                        if (text.items.len > 0) try text.append(std.heap.wasm_allocator, '\n');
                        try text.appendSlice(std.heap.wasm_allocator, m.repository);
                        try text.append(std.heap.wasm_allocator, ' ');
                        try text.appendSlice(std.heap.wasm_allocator, m.path);
                        try text.append(std.heap.wasm_allocator, ':');
                        const ln = try std.fmt.allocPrint(std.heap.wasm_allocator, "{d}", .{lm.lineNumber + 1});
                        defer std.heap.wasm_allocator.free(ln);
                        try text.appendSlice(std.heap.wasm_allocator, ln);
                        try text.appendSlice(std.heap.wasm_allocator, " — ");
                        try text.appendSlice(std.heap.wasm_allocator, lm.line);
                    }
                }
            }
        }
    }
    if (text.items.len == 0) try text.appendSlice(std.heap.wasm_allocator, "(no matches)");

    var rbuf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&rbuf);
    var s = std.json.Stringify{ .writer = &w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(text.items);
    try s.endObject();
    try out.writeAll(rbuf[0..w.end]);
}

fn encodeQuery(q: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.wasm_allocator);
    for (q) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') {
            try out.append(std.heap.wasm_allocator, c);
        } else if (c == ' ') {
            try out.appendSlice(std.heap.wasm_allocator, "+");
        } else {
            try out.append(std.heap.wasm_allocator, c);
        }
    }
    return out.toOwnedSlice(std.heap.wasm_allocator);
}

fn errJson(out: *lib.Out, msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    try out.writeAll(body);
}
