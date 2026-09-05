//! Cached GitHub object reads. `read_file` stays network-free; this guest
//! owns `gh://` / `github://` and `api.github.com`. Rendering and error
//! classification live in the host-tested `gh_format.zig`. Cache key,
//! fingerprint, and TTL live in `gh_cache.zig`.

const std = @import("std");
const lib = @import("lib.zig");
const gh_url = @import("gh_url.zig");
const gh_format = @import("gh_format.zig");
const gh_cache = @import("gh_cache.zig");

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

    if (cacheGet(url, token)) |hit| {
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
    // `httpGetFull` (ck_http_ex), not `httpGetHdr`: the reset time PRD 0019 asks
    // for lives in `X-RateLimit-Reset` and nowhere else, so the older channel
    // could not carry it however the guest was written. The status arrives with
    // the response here rather than through a second read of a shared slot, so
    // there is no ordering to get wrong either.
    const resp = lib.httpGetFull(lib.alloc, full, headers) catch |err| {
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
    const body = resp.body;
    // The reset time GitHub sends as a Unix timestamp. Absent on a response
    // that is not rate-limited, and `statusMessage` treats null as "say nothing
    // about when", so a server that omits the header degrades to the message
    // that shipped rather than to a wrong one.
    const reset = resetEpoch(resp);

    if (resp.status >= 400) {
        return lib.fail(out, try gh_format.statusMessage(lib.alloc, url, resp.status, body, reset));
    }
    // Kept as a second line of defence: a rate-limit answer that arrives with a
    // 200 (GitHub has done this behind proxies) is still a rate-limit answer,
    // and caching it would pin the error for the whole TTL. It now names the
    // reset time too, since the header is on this response like any other.
    if (gh_format.looksLikeRateLimit(body)) {
        return lib.fail(out, try gh_format.statusMessage(lib.alloc, url, 429, body, reset));
    }

    cachePut(url, token, body);
    const text = formatBody(ref, body) catch body;
    try lib.okText(out, text);
}

/// `X-RateLimit-Reset` as a Unix timestamp, or null when the header is absent or
/// not an integer. Parsed here rather than host-side because the host's job is
/// to decide *which* headers a guest may see, not to interpret them.
fn resetEpoch(resp: lib.HttpResponse) ?i64 {
    const raw = resp.header("x-ratelimit-reset") orelse return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t"), 10) catch null;
}

fn cacheGet(url: []const u8, token: []const u8) ?[]const u8 {
    var path_buf: [80]u8 = undefined;
    const path = gh_cache.filePath(&path_buf, gh_cache.key(url, token)) catch return null;
    const raw = lib.fsRead(path) catch return null;
    const rec = gh_cache.parse(lib.alloc, raw) orelse {
        // Unreadable or pre-fingerprint: do not serve, and drop the file so
        // a later put is not sitting next to a body we can no longer name.
        lib.fsDelete(path) catch {};
        return null;
    };
    const now: i64 = @trunc(lib.nowSeconds());
    if (gh_cache.shouldDelete(rec, now)) {
        lib.fsDelete(path) catch {};
        return null;
    }
    // The record carries the URL and token fingerprint it was fetched for.
    // Checking both is what makes a 64-bit hash safe as a filename: two
    // (url, token) pairs that collide share a file, and without this the
    // second one is served the first one's body, including across GitHub
    // identities.
    if (!gh_cache.matches(rec, url, token)) return null;
    return rec.body;
}

fn cachePut(url: []const u8, token: []const u8, body: []const u8) void {
    lib.fsMkdir(gh_cache.dir) catch {};
    var path_buf: [80]u8 = undefined;
    const path = gh_cache.filePath(&path_buf, gh_cache.key(url, token)) catch return;
    const now: i64 = @trunc(lib.nowSeconds());
    var req: std.Io.Writer.Allocating = .init(lib.alloc);
    gh_cache.writeRecord(&req.writer, url, token, now, body) catch return;
    lib.fsWrite(path, req.written()) catch {};
    sweepExpired(now);
}

/// Drop expired (and legacy, un-fingerprinted) files. The write that adds a
/// record is what clears the ones past TTL: nothing fires on its own
/// (ADR 0008), and janitor only deletes on `--yes`.
fn sweepExpired(now: i64) void {
    const listing = lib.fsList(gh_cache.dir) catch return;
    const names = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, listing, .{}) catch return;
    if (names != .array) return;
    var deleted: usize = 0;
    for (names.array.items) |item| {
        if (deleted >= gh_cache.max_sweep) return;
        if (item != .string) continue;
        const name = item.string;
        if (!gh_cache.isCacheFileName(name)) continue;
        const path = std.fmt.allocPrint(lib.alloc, "{s}/{s}", .{ gh_cache.dir, name }) catch continue;
        const raw = lib.fsRead(path) catch continue;
        const rec = gh_cache.parse(lib.alloc, raw) orelse {
            lib.fsDelete(path) catch {};
            deleted += 1;
            continue;
        };
        if (!gh_cache.shouldDelete(rec, now)) continue;
        lib.fsDelete(path) catch continue;
        deleted += 1;
    }
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
