//! Pure, allocation-free parsers for the web_search tool's backends.
//!
//! This module imports nothing from the guest ABI (lib.zig), so it stays
//! compilable on the host and its `test` blocks actually run in
//! `zig build test` — the pure-tool list in build.zig is what registers it.
//! Everything here slices into the caller's source buffer; only the URL
//! decoders and the text cleaner write into an explicit output buffer. No
//! allocator is touched.
//!
//! The two backends are deliberately different shapes:
//!   - DuckDuckGo Lite returns HTML; a result title is an
//!     `<a rel="nofollow" href="...">Title</a>` anchor with a
//!     `result-snippet` cell nearby. The `rel="nofollow"` marker has been
//!     stable across Lite's layout churn, so that is the semantic anchor.
//!   - Bing returns an RSS 2.0 document; a result is an `<item>` with
//!     `<title>`, `<link>` and `<description>` children.

const std = @import("std");

pub const WebResult = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
};

fn indexOfPos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (start > haystack.len) return null;
    return std.mem.indexOfPos(u8, haystack, start, needle);
}

/// DDG serves a "Unfortunately, bots use DuckDuckGo too" anti-bot page from
/// some networks and for non-browser user agents. Its marker is stable.
pub fn isBotChallenge(page: []const u8) bool {
    return std.mem.indexOf(u8, page, "anomaly-modal") != null;
}

/// Fantasy-land checks are untestable here; only pure logic lives in this
/// module. The network watchers (Bing serving poisoned results, DDG serving a
/// challenge) land in web_search.zig where the live fetch happens.

/// Extracts the first `<name>...</name>` region, slicing into `region`.
fn extractTag(comptime name: []const u8, region: []const u8) ?[]const u8 {
    const open_tag = "<" ++ name ++ ">";
    const close_tag = "</" ++ name ++ ">";
    const s = std.mem.indexOf(u8, region, open_tag) orelse return null;
    const content = s + open_tag.len;
    const e_rel = std.mem.indexOfPos(u8, region, content, close_tag) orelse return null;
    return region[content..e_rel];
}

/// Parses a Bing RSS 2.0 document. Extracts title/link/description from every
/// `<item>`; items missing a title or link are skipped, not fatal. Returns the
/// number of results written to `out` (capped by `max`).
pub fn parseBing(document: []const u8, out: []WebResult, max: usize) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (count < max) {
        const item = indexOfPos(document, pos, "<item>") orelse break;
        const close = indexOfPos(document, item, "</item>") orelse break;
        const item_body = document[item .. close + "</item>".len];
        pos = item + item_body.len;

        const title = extractTag("title", item_body) orelse continue;
        const link = extractTag("link", item_body) orelse continue;
        out[count] = .{
            .title = title,
            .url = link,
            .snippet = extractTag("description", item_body) orelse "",
        };
        count += 1;
    }
    return count;
}

fn lastIndexOfSlice(haystack: []const u8, before: usize, needle: []const u8) ?usize {
    var from: usize = 0;
    var found: ?usize = null;
    while (indexOfPos(haystack, from, needle)) |i| {
        if (i >= before) break;
        found = i;
        from = i + needle.len;
    }
    return found;
}

/// Value of `name=` inside an HTML tag, respecting single/double quotes.
fn extractAttr(comptime name: []const u8, tag: []const u8) ?[]const u8 {
    const n = name ++ "=";
    const p = std.mem.indexOf(u8, tag, n) orelse return null;
    const v = p + n.len;
    if (v >= tag.len) return null;
    if (tag[v] == '"' or tag[v] == '\'') {
        const q = tag[v];
        const e = std.mem.indexOfPos(u8, tag, v + 1, &.{q}) orelse return null;
        return tag[v + 1 .. e];
    }
    const e = std.mem.indexOfPos(u8, tag, v + 1, " >") orelse tag.len;
    return tag[v..e];
}

fn trim(s: []const u8) []const u8 {
    var a: usize = 0;
    while (a < s.len and (s[a] == ' ' or s[a] == '\t' or s[a] == '\n' or s[a] == '\r')) a += 1;
    var b = s.len;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t' or s[b - 1] == '\n' or s[b - 1] == '\r')) b -= 1;
    return s[a..b];
}

/// Parses DuckDuckGo Lite HTML. Result rows are located by their
/// `rel="nofollow"` title anchors; the snippet is the nearest following
/// `result-snippet` cell. Malformed rows are skipped. Returns the number of
/// results written to `out` (capped by `max`).
pub fn parseDdgLite(html: []const u8, out: []WebResult, max: usize) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (count < max) {
        const nf = indexOfPos(html, pos, "nofollow") orelse break;
        const a_open = lastIndexOfSlice(html, nf, "<a") orelse break;
        const tag_end = indexOfPos(html, a_open, ">") orelse break;
        // The nofollow marker must belong to this anchor, not a later tag.
        if (tag_end < nf) break;

        const href = extractAttr("href", html[a_open..tag_end]) orelse "";
        const title = trim(std.mem.trim(u8, html[tag_end + 1 .. indexOfPos(html, tag_end, "</a>") orelse tag_end], " "));

        // Snippet: nearest result-snippet cell after the title within the row.
        var snippet: []const u8 = "";
        if (indexOfPos(html, tag_end, "result-snippet")) |s_start| {
            if (indexOfPos(html, s_start, ">")) |s_tag_end| {
                const text_start = s_tag_end + 1;
                const text_end = indexOfPos(html, text_start, "<") orelse html.len;
                snippet = html[text_start..text_end];
            }
        }

        if (href.len > 0 and title.len > 0) {
            out[count] = .{ .title = title, .url = href, .snippet = snippet };
            count += 1;
        }
        pos = if (indexOfPos(html, tag_end, "</a>")) |te| te + "</a>".len else tag_end + 1;
    }
    return count;
}

// ------------------------------------------------------------ URL decoding --

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Percent-decodes `s` into `dst` (must hold >= s.len bytes; decoded output is
/// never larger than its input). '+' is left as-is, since these are URL values,
/// not form bodies. Returns the filled slice.
pub fn percentDecode(s: []const u8, dst: []u8) []const u8 {
    var j: usize = 0;
    var i: usize = 0;
    while (i < s.len and j < dst.len) {
        if (s[i] == '%' and i + 2 < s.len + 1 and hexVal(s[i + 1]) != null and hexVal(s[i + 2]) != null and j + 1 <= dst.len) {
            dst[j] = (hexVal(s[i + 1]).? << 4) | hexVal(s[i + 2]).?;
            j += 1;
            i += 3;
        } else if (i + 1 <= dst.len) {
            dst[j] = s[i];
            j += 1;
            i += 1;
        } else break;
    }
    return dst[0..j];
}

/// Percent-encodes `s` for use in a URL query value, leaving the unreserved
/// set alone. `dst` must hold >= 3 * s.len bytes. Returns the filled slice.
pub fn percentEncode(s: []const u8, dst: []u8) []const u8 {
    const hex = "0123456789ABCDEF";
    var j: usize = 0;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (ok) {
            if (j >= dst.len) break;
            dst[j] = c;
            j += 1;
        } else {
            if (j + 2 >= dst.len) break;
            dst[j] = '%';
            dst[j + 1] = hex[c >> 4];
            dst[j + 2] = hex[c & 0xF];
            j += 3;
        }
    }
    return dst[0..j];
}

/// Value of the `uddg` query parameter ("//duckduckgo.com/l/?uddg=<enc>&rut="),
/// sliced out of the raw redirect URL. Returns null when absent.
pub fn uddgValue(redirect: []const u8) ?[]const u8 {
    const marker = "uddg=";
    const p = std.mem.indexOf(u8, redirect, marker) orelse return null;
    const v = p + marker.len;
    const e = std.mem.indexOfPos(u8, redirect, v, "&") orelse redirect.len;
    if (e <= v) return null;
    return redirect[v..e];
}

// ------------------------------------------------------------- text cleanup --

fn encodeUtf8(cp: u32, dst: []u8) usize {
    if (cp < 0x80) {
        dst[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        dst[0] = @intCast(0xC0 | (cp >> 6));
        dst[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        dst[0] = @intCast(0xE0 | (cp >> 12));
        dst[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        dst[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    }
    dst[0] = @intCast(0xF0 | (cp >> 18));
    dst[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
    dst[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
    dst[3] = @intCast(0x80 | (cp & 0x3F));
    return 4;
}

const EntityDecode = struct { src_consumed: usize, dst_produced: usize };

/// Decodes one character reference at `src` ("&amp;", "&#39;", "&#x41;", ...)
/// into `dst`, returning how many source bytes were consumed and how many were
/// written, or null if it is not a reference we recognize. `dst` must hold at
/// least 4 bytes.
fn decodeEntity(src: []const u8, dst: []u8) ?EntityDecode {
    if (src.len < 2 or src[0] != '&') return null;
    const semi = std.mem.indexOfPos(u8, src, 1, ";") orelse return null;
    if (semi > 12) return null;
    const body = src[1..semi];
    if (body.len == 0) return null;
    const entity_len = semi + 1;

    var codepoint: u32 = undefined;
    if (body[0] == '#') {
        if (body.len < 2) return null;
        if (body[1] == 'x' or body[1] == 'X') {
            if (body.len < 3) return null;
            var v: u32 = 0;
            for (body[2..]) |h| {
                const d = hexVal(h) orelse return null;
                v = v * 16 + d;
            }
            codepoint = v;
        } else {
            var v: u32 = 0;
            for (body[1..]) |d| {
                if (d < '0' or d > '9') return null;
                v = v * 10 + (d - '0');
            }
            codepoint = v;
        }
        if (codepoint == 0 or codepoint > 0x10FFFF) return null;
    } else {
        codepoint = if (std.mem.eql(u8, body, "amp")) 0x26 else
            if (std.mem.eql(u8, body, "lt")) 0x3C else
            if (std.mem.eql(u8, body, "gt")) 0x3E else
            if (std.mem.eql(u8, body, "quot")) 0x22 else
            if (std.mem.eql(u8, body, "apos") or std.mem.eql(u8, body, "#39")) 0x27 else
            if (std.mem.eql(u8, body, "nbsp")) 0xA0 else
            return null;
    }
    const produced = encodeUtf8(codepoint, dst[0..4]);
    return .{ .src_consumed = entity_len, .dst_produced = produced };
}

/// Cleans a raw HTML/XML text field into `dst` (which must hold >= src.len
/// bytes): strips `<...>` markup and unescapes the common character
/// references. Never grows its input, so dst of src.len bytes is always enough.
pub fn cleanInto(src: []const u8, dst: []u8) []const u8 {
    var j: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '<') {
            const close = std.mem.indexOfPos(u8, src, i + 1, ">") orelse src.len;
            i = close + 1;
            continue;
        }
        if (c == '&') {
            var ebuf: [4]u8 = undefined;
            if (decodeEntity(src[i..], &ebuf)) |ent| {
                if (j + ent.dst_produced > dst.len) break;
                @memcpy(dst[j .. j + ent.dst_produced], ebuf[0..ent.dst_produced]);
                j += ent.dst_produced;
                i += ent.src_consumed;
                continue;
            }
            dst[j] = '&';
            j += 1;
            i += 1;
            continue;
        }
        if (j >= dst.len) break;
        dst[j] = c;
        j += 1;
        i += 1;
    }
    return dst[0..j];
}

// ------------------------------------------------------------------ testing --

const bing_fixture =
    \\<?xml version="1.0" encoding="utf-8" ?><rss version="2.0"><channel>
    \\<title>Bing: zig programming language</title><link>https://www.bing.com</link>
    \\<description>Search results</description>
    \\<item><title>Home ⚡ Zig Programming Language</title><link>https://ziglang.org/</link><description>Zig is a general-purpose programming language and toolchain for maintaining robust, optimal and reusable software.</description><pubDate>Tue, 11 Aug 2026 14:09:00 GMT</pubDate></item>
    \\<item><title>Zig (programming language) - Wikipedia</title><link>https://en.wikipedia.org/wiki/Zig_(programming_language)</link><description>Zig is a system programming language designed to be a general-purpose improvement to the C programming language.</description><pubDate>Tue, 11 Aug 2026 09:15:00 GMT</pubDate></item>
    \\<item><link>https://example.com/no-title</link><description>missing title is skipped</description></item>
    \\</channel></rss>
;

test "parseBing extracts items and skips malformed ones" {
    var results: [8]WebResult = undefined;
    const n = parseBing(bing_fixture, &results, 8);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("Home ⚡ Zig Programming Language", results[0].title);
    try std.testing.expectEqualStrings("https://ziglang.org/", results[0].url);
    try std.testing.expect(std.mem.indexOf(u8, results[0].snippet, "general-purpose") != null);
    try std.testing.expectEqualStrings("Zig (programming language) - Wikipedia", results[1].title);
}

test "parseBing honors max" {
    var results: [4]WebResult = undefined;
    const n = parseBing(bing_fixture, &results, 1);
    try std.testing.expectEqual(@as(usize, 1), n);
}

const ddg_lite_fixture =
    \\<div class='result results_links results_links_deep web-result '>
    \\<table><tr class='result'>
    \\<td nowrap='nowrap' class='result__td'>a</td>
    \\<td valign='top'>
    \\<a rel='nofollow' class='result-link' href='//duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org%2F&amp;rut=abc'>Home ⚡ Zig Programming Language</a>
    \\<div class='result-link'>ziglang.org</div>
    \\<td class='result-snippet'>Zig is a general-purpose programming <b>language</b> and toolchain.</td>
    \\</td></tr></table></div>
;

test "parseDdgLite extracts title, uddg url and skips none" {
    var results: [4]WebResult = undefined;
    const n = parseDdgLite(ddg_lite_fixture, &results, 4);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("Home ⚡ Zig Programming Language", results[0].title);
    try std.testing.expect(std.mem.indexOf(u8, results[0].url, "uddg=") != null);
    // snippet stops at the first inner tag as a safe, if cut, boundary
    try std.testing.expect(std.mem.eql(u8, results[0].snippet, "Zig is a general-purpose programming "));
}

test "uddgValue extracts and percentDecode recovers the real url" {
    const raw = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org%2Fnews%2F&rut=abc123";
    const v = uddgValue(raw).?;
    try std.testing.expectEqualStrings("https%3A%2F%2Fziglang.org%2Fnews%2F", v);
    var buf: [256]u8 = undefined;
    const decoded = percentDecode(v, &buf);
    try std.testing.expectEqualStrings("https://ziglang.org/news/", decoded);
}

test "isBotChallenge detects the anomaly page" {
    try std.testing.expect(isBotChallenge(
        "Unfortunately, bots use DuckDuckGo too.<div class=\"anomaly-modal\">",
    ));
    try std.testing.expect(!isBotChallenge("<html><body>real results here</body></html>"));
}

test "percentEncode encodes reserved, leaves unreserved" {
    var buf: [128]u8 = undefined;
    const enc = percentEncode("zig st. +lang", &buf);
    try std.testing.expectEqualStrings("zig%20st.%20%2Blang", enc);
    const back = percentDecode(enc, &buf);
    try std.testing.expectEqualStrings("zig st. +lang", back);
}

test "cleanInto strips tags and unescapes entities" {
    var buf: [128]u8 = undefined;
    const out = cleanInto("Tom &amp; Jerry <b>said</b> &quot;hi&quot; &#x41; &#39;x&#39; &nbsp;end", &buf);
    try std.testing.expectEqualStrings("Tom & Jerry said \"hi\" A 'x' \xc2\xa0end", out);
}
