//! Cached GitHub object reads. `read_file` stays network-free; this guest
//! owns `gh://` / `github://` and `api.github.com`.

const std = @import("std");
const lib = @import("lib.zig");
const gh_url = @import("gh_url.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");
    const url = switch (parsed.object.get("url") orelse parsed.object.get("path") orelse
        return lib.fail(out, "missing url")) {
        .string => |s| s,
        else => return lib.fail(out, "url must be a string"),
    };
    const ref = gh_url.parse(url) orelse
        return lib.fail(out, "not a gh:// or github:// URL (issue|pr)");

    const token = lib.getenv("GITHUB_TOKEN") orelse
        return lib.fail(out, "GITHUB_TOKEN not set; export it or set gh.token in config");

    if (cacheGet(url)) |hit| {
        const text = formatBody(ref, hit) catch hit;
        try lib.okText(out, text);
        return;
    }

    const api = try gh_url.apiPath(lib.alloc, ref);
    const full = try std.fmt.allocPrint(lib.alloc, "https://api.github.com{s}", .{api});
    const headers = try std.fmt.allocPrint(
        lib.alloc,
        "{{\"Authorization\":\"Bearer {s}\",\"Accept\":\"application/vnd.github+json\",\"User-Agent\":\"clanker\"}}",
        .{token},
    );
    const body = lib.httpGetHdr(full, headers) catch |err| {
        return lib.failErr(out, err, url);
    };
    if (looksLikeRateLimit(body)) {
        return lib.fail(out, "GitHub rate limit exhausted");
    }
    if (looksLikeNotFound(body)) {
        return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "not found: {s}", .{url}));
    }

    cachePut(url, body);
    const text = formatBody(ref, body) catch body;
    try lib.okText(out, text);
}

fn cacheKey(url: []const u8) u64 {
    return std.hash.Wyhash.hash(0, url);
}

fn cacheGet(url: []const u8) ?[]const u8 {
    var path_buf: [80]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "state/gh_cache/{x}.json", .{cacheKey(url)}) catch return null;
    const raw = lib.fsRead(path) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch return null;
    if (parsed != .object) return null;
    const fetched = switch (parsed.object.get("fetched") orelse return null) {
        .integer => |n| n,
        else => return null,
    };
    const now: i64 = @intFromFloat(lib.nowSeconds());
    if (now - fetched > 300) return null;
    return switch (parsed.object.get("body") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn cachePut(url: []const u8, body: []const u8) void {
    lib.fsMkdir("state/gh_cache") catch {};
    var path_buf: [80]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "state/gh_cache/{x}.json", .{cacheKey(url)}) catch return;
    const now: i64 = @intFromFloat(lib.nowSeconds());
    var req: std.Io.Writer.Allocating = .init(lib.alloc);
    var s = std.json.Stringify{ .writer = &req.writer };
    s.beginObject() catch return;
    s.objectField("url") catch return;
    s.write(url) catch return;
    s.objectField("fetched") catch return;
    s.write(now) catch return;
    s.objectField("body") catch return;
    s.write(body) catch return;
    s.endObject() catch return;
    lib.fsWrite(path, req.written()) catch {};
}

fn looksLikeRateLimit(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "API rate limit exceeded") != null or
        std.mem.indexOf(u8, body, "\"message\":\"You have exceeded a secondary rate limit") != null;
}

fn looksLikeNotFound(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "\"message\":\"Not Found\"") != null;
}

fn formatBody(ref: gh_url.Ref, body: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, body, .{}) catch return body;
    return switch (ref.kind) {
        .issue => formatIssue(parsed),
        .pr => formatPr(parsed),
        .issue_list => formatList(parsed),
        .pr_diff, .pr_file => formatFiles(parsed, ref.subpath),
    };
}

fn strField(v: std.json.Value, name: []const u8) []const u8 {
    if (v != .object) return "";
    return switch (v.object.get(name) orelse return "") {
        .string => |s| s,
        else => "",
    };
}

fn formatIssue(v: std.json.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const num = switch (if (v == .object) v.object.get("number") orelse .null else .null) {
        .integer => |n| n,
        else => @as(i64, 0),
    };
    try append(&out, "Issue #");
    var nbuf: [16]u8 = undefined;
    try append(&out, std.fmt.bufPrint(&nbuf, "{d}", .{num}) catch "?");
    try append(&out, ": ");
    try append(&out, strField(v, "title"));
    try append(&out, " (");
    try append(&out, strField(v, "state"));
    try append(&out, ")\n");
    if (v == .object) {
        if (v.object.get("labels")) |labs| {
            if (labs == .array and labs.array.items.len > 0) {
                try append(&out, "Labels: ");
                for (labs.array.items, 0..) |lab, i| {
                    if (i > 0) try append(&out, ", ");
                    try append(&out, strField(lab, "name"));
                }
                try append(&out, "\n");
            }
        }
    }
    try append(&out, "\n");
    try append(&out, strField(v, "body"));
    try append(&out, "\n");
    return out.toOwnedSlice(lib.alloc);
}

fn formatPr(v: std.json.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try append(&out, "PR #");
    const num = switch (if (v == .object) v.object.get("number") orelse .null else .null) {
        .integer => |n| n,
        else => @as(i64, 0),
    };
    var nbuf: [16]u8 = undefined;
    try append(&out, std.fmt.bufPrint(&nbuf, "{d}", .{num}) catch "?");
    try append(&out, ": ");
    try append(&out, strField(v, "title"));
    try append(&out, " (");
    try append(&out, strField(v, "state"));
    try append(&out, ")\n\n");
    try append(&out, strField(v, "body"));
    try append(&out, "\n");
    return out.toOwnedSlice(lib.alloc);
}

fn formatList(v: std.json.Value) ![]const u8 {
    if (v != .array) return "[]";
    var out: std.ArrayList(u8) = .empty;
    for (v.array.items) |item| {
        const num = switch (if (item == .object) item.object.get("number") orelse .null else .null) {
            .integer => |n| n,
            else => continue,
        };
        var nbuf: [16]u8 = undefined;
        try append(&out, "#");
        try append(&out, std.fmt.bufPrint(&nbuf, "{d}", .{num}) catch "?");
        try append(&out, " ");
        try append(&out, strField(item, "state"));
        try append(&out, " ");
        try append(&out, strField(item, "title"));
        try append(&out, "\n");
    }
    return out.toOwnedSlice(lib.alloc);
}

fn formatFiles(v: std.json.Value, want: []const u8) ![]const u8 {
    if (v != .array) return "";
    var out: std.ArrayList(u8) = .empty;
    for (v.array.items) |item| {
        const name = strField(item, "filename");
        if (want.len > 0 and !std.mem.eql(u8, name, want)) continue;
        const patch = strField(item, "patch");
        if (patch.len == 0) continue;
        try append(&out, patch);
        try append(&out, "\n");
    }
    return out.toOwnedSlice(lib.alloc);
}

fn append(out: *std.ArrayList(u8), s: []const u8) !void {
    try out.appendSlice(lib.alloc, s);
}
