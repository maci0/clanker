//! Pure query planning and result-normalizing logic for the `research` guest.
//!
//! Imports nothing from the guest ABI, so `zig build test` runs these tests on
//! the host (registered in build.zig's pure-tool list).
//!
//! The angles below are the whole reason a research sweep beats a single
//! search: one query returns what a topic's marketing says about itself, while
//! the failure, production, and built-in angles return what it costs. The
//! out-of-the-box angles exist because the option that wins is often the one
//! no keyword search surfaces — something already in the tree, a standard
//! library primitive, or not doing the thing at all.

const std = @import("std");

/// One search angle. `template` is filled by `renderQuery`; `{topic}` is the
/// caller's topic and `{year}` the current year, so a recency-sensitive angle
/// does not rot into a hardcoded date.
pub const Angle = struct {
    name: []const u8,
    template: []const u8,
    why: []const u8,
};

/// Ordered by value, because `depth` takes a prefix of this list. The first
/// four have to be enough to answer "what exists and what breaks".
pub const angles = [_]Angle{
    .{
        .name = "baseline",
        .template = "{topic}",
        .why = "What the topic calls itself, and the vocabulary the rest of the search needs",
    },
    .{
        .name = "options",
        .template = "{topic} alternatives comparison",
        .why = "The candidate set, including the ones the first result does not mention",
    },
    .{
        .name = "libraries",
        .template = "{topic} open source library github",
        .why = "Implementations that already exist, with a repository to judge them by",
    },
    .{
        .name = "failures",
        .template = "{topic} problems limitations pitfalls postmortem",
        .why = "What it costs after adoption — the half a vendor page never covers",
    },
    .{
        .name = "production",
        .template = "{topic} production experience lessons learned",
        .why = "Reports from people who ran it, not people who announced it",
    },
    .{
        .name = "builtin",
        .template = "{topic} without a library standard library built-in",
        .why = "The out-of-the-box answer: a primitive or an existing dependency instead of a new one",
    },
    .{
        .name = "benchmarks",
        .template = "{topic} benchmark performance comparison",
        .why = "Numbers to check a claimed advantage against",
    },
    .{
        .name = "awesome",
        .template = "awesome {topic} list",
        .why = "Curated lists surface the long tail a ranked search buries",
    },
    .{
        .name = "discussion",
        .template = "{topic} hacker news reddit discussion",
        .why = "Where the trade-offs are argued rather than announced",
    },
    .{
        .name = "standards",
        .template = "{topic} specification standard rfc",
        .why = "A spec makes options interchangeable and outlives any one of them",
    },
    .{
        .name = "adjacent",
        .template = "{topic} unconventional approach alternative design",
        .why = "How a neighbouring field solves the same shape of problem",
    },
    .{
        .name = "recent",
        .template = "{topic} {year}",
        .why = "Catches a change that ranked pages have not caught up with",
    },
};

pub const Depth = enum {
    quick,
    standard,
    deep,

    pub fn parse(name: []const u8) ?Depth {
        if (std.mem.eql(u8, name, "quick")) return .quick;
        if (std.mem.eql(u8, name, "standard")) return .standard;
        if (std.mem.eql(u8, name, "deep")) return .deep;
        return null;
    }

    /// How many angles this depth uses. A deep sweep costs one HTTP round trip
    /// per angle per backend, so the ceiling is a time budget, not a taste.
    pub fn angleCount(self: Depth) usize {
        return switch (self) {
            .quick => 4,
            .standard => 8,
            .deep => angles.len,
        };
    }
};

/// Fills `{topic}` and `{year}` in an angle template. Truncates rather than
/// failing: a query is a hint to a search engine, not a contract.
pub fn renderQuery(template: []const u8, topic: []const u8, year: i64, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    var year_buf: [8]u8 = undefined;
    const year_text = std.fmt.bufPrint(&year_buf, "{d}", .{year}) catch "";
    while (i < template.len) {
        if (template[i] == '{') {
            if (std.mem.startsWith(u8, template[i..], "{topic}")) {
                n += copyInto(buf[n..], topic);
                i += "{topic}".len;
                continue;
            }
            if (std.mem.startsWith(u8, template[i..], "{year}")) {
                n += copyInto(buf[n..], year_text);
                i += "{year}".len;
                continue;
            }
        }
        if (n >= buf.len) break;
        buf[n] = template[i];
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

fn copyInto(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// The comparison key for "same page, different link": scheme, `www.`, a
/// trailing slash, and any query or fragment are all noise when the question is
/// whether two results are the same source. Lowercased into `buf`.
pub fn dedupeKey(url: []const u8, buf: []u8) []const u8 {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest["https://".len..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest["http://".len..];
    }
    if (std.mem.startsWith(u8, rest, "www.")) rest = rest["www.".len..];
    if (std.mem.findScalar(u8, rest, '#')) |h| rest = rest[0..h];
    if (std.mem.findScalar(u8, rest, '?')) |q| rest = rest[0..q];
    while (rest.len > 1 and rest[rest.len - 1] == '/') rest = rest[0 .. rest.len - 1];
    const n = @min(rest.len, buf.len);
    for (rest[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..n];
}

/// The host part of a URL, for grouping results by where they came from.
pub fn hostOf(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.find(u8, rest, "://")) |s| rest = rest[s + 3 ..];
    if (std.mem.findScalar(u8, rest, '/')) |slash| rest = rest[0..slash];
    if (std.mem.findScalar(u8, rest, '?')) |q| rest = rest[0..q];
    if (std.mem.startsWith(u8, rest, "www.")) rest = rest["www.".len..];
    return rest;
}

/// Body of the first `<name>…</name>` at or after `from`, plus the offset just
/// past its closing tag. Enough for the Atom feed arXiv serves; deliberately
/// not a general XML parser.
pub const Tag = struct { body: []const u8, end: usize };

pub fn findTag(document: []const u8, name: []const u8, from: usize) ?Tag {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{name}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{name}) catch return null;
    const s = std.mem.findPos(u8, document, from, open) orelse return null;
    const body_start = s + open.len;
    const e = std.mem.findPos(u8, document, body_start, close) orelse return null;
    return .{ .body = document[body_start..e], .end = e + close.len };
}

/// Collapses runs of whitespace so a multi-line XML or HTML fragment becomes
/// one readable line, and decodes the five XML entities that survive in feed
/// text. Truncates on a UTF-8 boundary so the result is always valid JSON text.
pub fn oneLine(text: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    var pending_space = false;
    while (i < text.len and n < buf.len) {
        const c = text[i];
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t') {
            if (n > 0) pending_space = true;
            i += 1;
            continue;
        }
        if (pending_space) {
            buf[n] = ' ';
            n += 1;
            pending_space = false;
            if (n >= buf.len) break;
        }
        if (c == '&') {
            if (entityAt(text[i..])) |ent| {
                buf[n] = ent.ch;
                n += 1;
                i += ent.len;
                continue;
            }
        }
        buf[n] = c;
        n += 1;
        i += 1;
    }
    while (n > 0 and (buf[n - 1] & 0xC0) == 0x80) n -= 1;
    if (n > 0 and (buf[n - 1] & 0x80) != 0) n -= 1;
    return buf[0..n];
}

const Entity = struct { ch: u8, len: usize };

fn entityAt(text: []const u8) ?Entity {
    const table = [_]struct { name: []const u8, ch: u8 }{
        .{ .name = "&amp;", .ch = '&' },
        .{ .name = "&lt;", .ch = '<' },
        .{ .name = "&gt;", .ch = '>' },
        .{ .name = "&quot;", .ch = '"' },
        .{ .name = "&apos;", .ch = '\'' },
        .{ .name = "&#39;", .ch = '\'' },
    };
    for (table) |e| {
        if (std.mem.startsWith(u8, text, e.name)) return .{ .ch = e.ch, .len = e.name.len };
    }
    return null;
}

// URL percent-encoding is deliberately absent here: `search_parse.zig` already
// has one, and two encoders that disagree about a single character produce a
// query that quietly matches nothing. The research guest imports both modules
// and uses that one.

// ------------------------------------------------------------------ tests

test "every angle template names the topic" {
    for (angles) |a| {
        try std.testing.expect(std.mem.find(u8, a.template, "{topic}") != null);
        try std.testing.expect(a.why.len > 0);
    }
}

test "depths take a growing prefix of the angle list" {
    try std.testing.expect(Depth.quick.angleCount() < Depth.standard.angleCount());
    try std.testing.expect(Depth.standard.angleCount() < Depth.deep.angleCount());
    try std.testing.expectEqual(angles.len, Depth.deep.angleCount());
    try std.testing.expectEqual(@as(?Depth, .deep), Depth.parse("deep"));
    try std.testing.expectEqual(@as(?Depth, null), Depth.parse("thorough"));
}

test "a quick sweep still covers the failure angle" {
    // The point of a sweep is not to find the topic; it is to find what the
    // topic costs. Dropping that from the cheapest depth would make the
    // cheapest depth useless.
    var found = false;
    for (angles[0..Depth.quick.angleCount()]) |a| {
        if (std.mem.eql(u8, a.name, "failures")) found = true;
    }
    try std.testing.expect(found);
}

test "an out-of-the-box angle is reached by a standard sweep" {
    var found = false;
    for (angles[0..Depth.standard.angleCount()]) |a| {
        if (std.mem.eql(u8, a.name, "builtin")) found = true;
    }
    try std.testing.expect(found);
}

test "renderQuery fills topic and year" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "zig http client alternatives comparison",
        renderQuery("{topic} alternatives comparison", "zig http client", 2026, &buf),
    );
    try std.testing.expectEqualStrings("wasm runtimes 2026", renderQuery("{topic} {year}", "wasm runtimes", 2026, &buf));
}

test "renderQuery truncates instead of overflowing" {
    var buf: [8]u8 = undefined;
    const q = renderQuery("{topic} alternatives", "abcdefghijkl", 2026, &buf);
    try std.testing.expectEqual(@as(usize, 8), q.len);
}

test "dedupeKey collapses the ways one page is linked" {
    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        dedupeKey("https://www.Example.com/docs/", &a),
        dedupeKey("http://example.com/docs?utm_source=x#frag", &b),
    );
    try std.testing.expect(!std.mem.eql(u8, dedupeKey("https://example.com/a", &a), dedupeKey("https://example.com/b", &b)));
}

test "hostOf extracts the host for grouping" {
    try std.testing.expectEqualStrings("github.com", hostOf("https://github.com/ziglang/zig"));
    try std.testing.expectEqualStrings("example.com", hostOf("http://www.example.com"));
    try std.testing.expectEqualStrings("news.ycombinator.com", hostOf("https://news.ycombinator.com/item?id=1"));
}

test "findTag reads a body and reports where to continue" {
    const doc = "<feed><entry><title>First</title></entry><entry><title>Second</title></entry></feed>";
    const first = findTag(doc, "title", 0).?;
    try std.testing.expectEqualStrings("First", first.body);
    const second = findTag(doc, "title", first.end).?;
    try std.testing.expectEqualStrings("Second", second.body);
    try std.testing.expect(findTag(doc, "title", second.end) == null);
}

test "oneLine collapses whitespace and decodes feed entities" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "a & b < c",
        oneLine("  a\n  &amp;\tb &lt; c\n", &buf),
    );
}

test "oneLine never cuts a UTF-8 sequence in half" {
    var buf: [4]u8 = undefined;
    const out = oneLine("abc\u{2014}def", &buf);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
}
