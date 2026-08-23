//! Cached GitHub object reads. `read_file` stays network-free; this guest
//! owns `gh://` / `github://` and `api.github.com`. Rendering and error
//! classification live in the host-tested `gh_format.zig`.

const std = @import("std");
const lib = @import("lib.zig");
const gh_url = @import("gh_url.zig");
const gh_format = @import("gh_format.zig");

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
        // Every >= 400 response arrives as `error.NetworkError`, so the status
        // has to be read out of the failure envelope before anything else is
        // called -- the result slot it lives in is shared and never cleared.
        if (err == error.NetworkError) {
            if (lib.httpLastFailure(lib.alloc)) |fail| {
                return lib.fail(out, try gh_format.statusMessage(lib.alloc, url, fail.status, fail.body));
            }
        }
        if (err == error.TooLarge) {
            // A list is fetched at the maximum page size, so the way to make it
            // fit is a smaller one. Naming the knob matters: the generic
            // "narrow the query" leaves the model guessing at a parameter that
            // is not in the tool's schema.
            const sep: []const u8 = if (ref.query.len > 0) "&" else "?";
            return lib.fail(out, try std.fmt.allocPrint(
                lib.alloc,
                "{s}: the response is larger than one call allows; retry with a smaller page, e.g. {s}{s}per_page=20",
                .{ url, url, sep },
            ));
        }
        return lib.failErr(out, err, url);
    };
    // Kept as a second line of defence: a rate-limit answer that arrives with a
    // 200 (GitHub has done this behind proxies) is still a rate-limit answer,
    // and caching it would pin the error for the whole TTL.
    if (gh_format.looksLikeRateLimit(body)) {
        return lib.fail(out, "GitHub rate limit exhausted");
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
    // The record carries the URL it was fetched for, and checking it is what
    // makes a 64-bit hash safe as a filename: two URLs that collide share a
    // file, and without this the second one is served the first one's body.
    switch (parsed.object.get("url") orelse return null) {
        .string => |s| if (!std.mem.eql(u8, s, url)) return null,
        else => return null,
    }
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

fn formatBody(ref: gh_url.Ref, body: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, body, .{}) catch return body;
    return switch (ref.kind) {
        .issue => gh_format.issue(lib.alloc, parsed),
        .pr => gh_format.pullRequest(lib.alloc, parsed),
        .issue_list => gh_format.issueList(lib.alloc, parsed),
        .pr_diff, .pr_file => gh_format.files(lib.alloc, parsed, ref.subpath),
    };
}
