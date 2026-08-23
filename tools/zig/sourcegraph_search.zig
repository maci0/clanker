//! sourcegraph_search: search open-source code via Sourcegraph's public search API
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
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const query = switch (obj.get("query") orelse return lib.fail(out, "missing query")) {
        .string => |s| s,
        else => return lib.fail(out, "query must be a string"),
    };
    var lang: []const u8 = "";
    if (obj.get("lang")) |l| {
        if (l == .string) lang = l.string;
    }
    var max: usize = 10;
    if (obj.get("max")) |m| {
        if (m == .integer and m.integer > 0) max = std.math.lossyCast(usize, m.integer);
    }

    const q = try encodeQuery(query);
    defer lib.alloc.free(q);
    const url = if (lang.len > 0)
        try std.fmt.allocPrint(lib.alloc, "https://sourcegraph.com/.api/search/stream?q=context:global+{s}+lang:{s}+count:{d}&display={d}", .{ q, lang, max, max })
    else
        try std.fmt.allocPrint(lib.alloc, "https://sourcegraph.com/.api/search/stream?q=context:global+{s}+count:{d}&display={d}", .{ q, max, max });
    defer lib.alloc.free(url);

    const body = lib.httpGet(url) catch |err| return lib.failErr(out, err, "querying the code search service");

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(lib.alloc);
    // SSE: lines of "event: matches" followed by "data: [<json array>]".
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (std.mem.find(u8, line, "event: matches") != null) {
            const data_line = lines.next() orelse continue;
            if (std.mem.find(u8, data_line, "data: ")) |d| {
                const arr = std.json.parseFromSliceLeaky([]const Match, lib.alloc, data_line[d + 6 ..], .{ .ignore_unknown_fields = true }) catch continue;
                for (arr) |m| {
                    for (m.lineMatches) |lm| {
                        if (text.items.len > 0) try text.append(lib.alloc, '\n');
                        try text.appendSlice(lib.alloc, m.repository);
                        try text.append(lib.alloc, ' ');
                        try text.appendSlice(lib.alloc, m.path);
                        try text.append(lib.alloc, ':');
                        const ln = try std.fmt.allocPrint(lib.alloc, "{d}", .{lm.lineNumber + 1});
                        defer lib.alloc.free(ln);
                        try text.appendSlice(lib.alloc, ln);
                        try text.appendSlice(lib.alloc, " — ");
                        try text.appendSlice(lib.alloc, lm.line);
                    }
                }
            }
        }
    }
    if (text.items.len == 0) try text.appendSlice(lib.alloc, "(no matches)");

    return lib.okText(out, text.items);
}

fn encodeQuery(q: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(lib.alloc);
    for (q) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') {
            try out.append(lib.alloc, c);
        } else if (c == ' ') {
            try out.appendSlice(lib.alloc, "+");
        } else {
            try out.append(lib.alloc, c);
        }
    }
    return out.toOwnedSlice(lib.alloc);
}
