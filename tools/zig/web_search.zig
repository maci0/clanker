//! web_search: multi-backend web search implemented as one WASM tool.
//!
//! Attempts DuckDuckGo Lite first (server-rendered, no key, richer snippets);
//! if that page is unreachable, is DDG's anti-bot challenge page, or yields no
//! results, it transparently falls back to Bing Search's RSS 2.0 endpoint
//! (also no key, and deliberately machine-shaped — no HTML to scrape). The
//! chosen backend is named in the response so callers know the provenance.
//!
//! Input:  {"query": "...", "max_results": <1..20, default 8>,
//!          "region": "<optional, e.g. en-US>"}
//! Output: {"ok": true, "backend": "duckduckgo"|"bing", "query": "...",
//!          "count": N, "results": [{"title", "url", "snippet"}, ...]}
//! or     {"ok": false, "error": "..."} with an actionable message.

const std = @import("std");
const lib = @import("lib.zig");
const parse = @import("search_parse.zig");

const default_max = 8;
const max_results_cap = 20;

/// Copies `raw` into `buf`, cleaning markup/entities, truncating at a UTF-8
/// boundary so the result is always valid JSON text. Never allocates.
fn cleanBuf(raw: []const u8, buf: []u8) []const u8 {
    var n = @min(raw.len, buf.len);
    if (n < raw.len) {
        // Do not split a UTF-8 sequence at the cut: back off past any trailing
        // continuation bytes so the JSON string stays valid.
        while (n > 0 and n <= raw.len and (raw[n - 1] & 0xC0) == 0x80) n -= 1;
    }
    return parse.cleanInto(raw[0..n], buf[0..n]);
}

/// The URL a caller should actually open. DuckDuckGo wraps every result in a
/// `//duckduckgo.com/l/?uddg=<percent-encoded>` redirect; Bing links are
/// already the real URL. Both are copied into `dst` so the slice is stable.
fn resolvedUrl(raw: []const u8, backend: []const u8, dst: []u8) []const u8 {
    if (std.mem.eql(u8, backend, "duckduckgo")) {
        if (parse.uddgValue(raw)) |enc| {
            return parse.percentDecode(enc, dst);
        }
    }
    const n = @min(raw.len, dst.len);
    @memcpy(dst[0..n], raw[0..n]);
    return dst[0..n];
}

fn langFromRegion(region: []const u8) []const u8 {
    if (region.len == 0) return "en";
    if (std.mem.indexOfScalar(u8, region, '-')) |dash| {
        if (dash > 0) return region[0..dash];
    }
    return region;
}

/// Appends `src` to `dst` starting at `at`, never writing past the buffer
/// (long inputs are truncated, never a trap). Returns the new length.
fn appendAt(dst: []u8, at: usize, src: []const u8) usize {
    const n = @min(src.len, dst.len -| at);
    @memcpy(dst[at..][0..n], src[0..n]);
    return at + n;
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    var arena_state = std.heap.ArenaAllocator.init(lib.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const obj = std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{}) catch {
        return lib.fail(out, "input must be a JSON object with a \"query\" string");
    };
    const query = lib.str(obj, "query") catch return lib.fail(out, "missing query");
    var max_f = lib.optNum(obj, "max_results") orelse default_max;
    if (max_f < 1) max_f = 1;
    if (max_f > max_results_cap) max_f = max_results_cap;
    const want: usize = @intFromFloat(max_f);
    const region = lib.optStr(obj, "region") orelse "";

    var encbuf: [4096]u8 = undefined;
    const enc = parse.percentEncode(query, &encbuf);
    var urlbuf: [8192]u8 = undefined;
    var results: [max_results_cap]parse.WebResult = undefined;

    // ---- attempt 1: DuckDuckGo Lite --------------------------------------
    var backend: []const u8 = "duckduckgo";
    var count: usize = 0;
    {
        var l = appendAt(&urlbuf, 0, "https://lite.duckduckgo.com/lite/?q=");
        l = appendAt(&urlbuf, l, enc);
        if (region.len > 0) {
            l = appendAt(&urlbuf, l, "&kl=");
            l = appendAt(&urlbuf, l, region);
        }
        const body = lib.httpGet(urlbuf[0..l]) catch null;
        if (body) |b| {
            // DDG serves its bot-challenge page as a 200; treat that (and an
            // empty page) as "no usable results" and fall back.
            if (!parse.isBotChallenge(b)) {
                count = parse.parseDdgLite(b, &results, want);
            }
        }
    }

    // ---- attempt 2: Bing RSS (no key, machine-shaped) ---------------------
    if (count == 0) {
        backend = "bing";
        const mkt = if (region.len > 0) region else "en-US";
        const lang = langFromRegion(region);
        var l = appendAt(&urlbuf, 0, "https://www.bing.com/search?q=");
        l = appendAt(&urlbuf, l, enc);
        l = appendAt(&urlbuf, l, "&format=rss&mkt=");
        l = appendAt(&urlbuf, l, mkt);
        l = appendAt(&urlbuf, l, "&setlang=");
        l = appendAt(&urlbuf, l, lang);

        const body = lib.httpGet(urlbuf[0..l]) catch |err| {
            return lib.failErr(out, err, "searching Bing (DuckDuckGo Lite was also unavailable or returned nothing)");
        };
        count = parse.parseBing(body, &results, want);
        if (count == 0) {
            return lib.fail(out, "both search backends returned no results — DuckDuckGo Lite and Bing were reachable but empty for this query");
        }
    }

    // ---- respond ----------------------------------------------------------
    var w = lib.writer(out);
    var s = lib.json(&w);
    var title_buf: [4096]u8 = undefined;
    var url_buf: [4096]u8 = undefined;
    var snip_buf: [4096]u8 = undefined;
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("backend");
    try s.write(backend);
    try s.objectField("query");
    try s.write(query);
    try s.objectField("count");
    try s.write(@as(u64, count));
    try s.objectField("results");
    try s.beginArray();
    for (results[0..count]) |r| {
        try s.beginObject();
        try s.objectField("title");
        try s.write(cleanBuf(r.title, &title_buf));
        try s.objectField("url");
        try s.write(cleanBuf(resolvedUrl(r.url, backend, &url_buf), &url_buf));
        try s.objectField("snippet");
        try s.write(cleanBuf(r.snippet, &snip_buf));
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}
