//! Rendering for the `gh_read` guest: GitHub REST JSON to the plain text the
//! model reads (PRD 0019). Host-tested helper -- no `lib.zig`, no host calls,
//! every allocation through the caller's allocator, so the shapes the API
//! actually returns can be pinned without a network.

const std = @import("std");
const gh_url = @import("gh_url.zig");

/// Appended when a response came back holding exactly one page. GitHub reports
/// the rest only through a `Link: rel="next"` header, and a full page is the
/// signal used in its place. Saying so is the point: the shipped tool returned a
/// short list and a partial diff with nothing to distinguish them from a
/// complete one.
///
/// This is now an inference the transport no longer forces. `ck_http_ex` carries
/// `Link` (ADR 0049), so the exact fact is available and a page of exactly
/// `page_size` items no longer has to be read as "there is more" -- which is
/// wrong for a final page that happens to be full. Replacing it is PRD 0019
/// work: it changes a shipped output that the tool's own `llm_description`
/// describes, so it does not ride along with the transport change.
pub const truncation_note = "\n[truncated: only the first page was fetched; more items exist]\n";

fn append(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.appendSlice(gpa, s);
}

fn appendInt(out: *std.ArrayList(u8), gpa: std.mem.Allocator, n: i64) !void {
    var buf: [24]u8 = undefined;
    try append(out, gpa, std.fmt.bufPrint(&buf, "{d}", .{n}) catch "?");
}

/// A string field, or "" for absent, null, or a non-string.
pub fn strField(v: std.json.Value, name: []const u8) []const u8 {
    if (v != .object) return "";
    return switch (v.object.get(name) orelse return "") {
        .string => |s| s,
        else => "",
    };
}

fn intField(v: std.json.Value, name: []const u8) ?i64 {
    if (v != .object) return null;
    return switch (v.object.get(name) orelse return null) {
        .integer => |n| n,
        else => null,
    };
}

fn boolField(v: std.json.Value, name: []const u8) ?bool {
    if (v != .object) return null;
    return switch (v.object.get(name) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

/// `head`/`base` are objects; the human-readable name is their `label`
/// (`owner:branch`), falling back to `ref` when a fork has been deleted.
fn refName(v: std.json.Value, name: []const u8) []const u8 {
    if (v != .object) return "";
    const side = v.object.get(name) orelse return "";
    const label = strField(side, "label");
    if (label.len > 0) return label;
    return strField(side, "ref");
}

pub fn issue(gpa: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try append(&out, gpa, "Issue #");
    try appendInt(&out, gpa, intField(v, "number") orelse 0);
    try append(&out, gpa, ": ");
    try append(&out, gpa, strField(v, "title"));
    try append(&out, gpa, " (");
    try append(&out, gpa, strField(v, "state"));
    try append(&out, gpa, ")\n");
    try appendLabels(&out, gpa, v);
    try append(&out, gpa, "\n");
    try append(&out, gpa, strField(v, "body"));
    try append(&out, gpa, "\n");
    return out.toOwnedSlice(gpa);
}

fn appendLabels(out: *std.ArrayList(u8), gpa: std.mem.Allocator, v: std.json.Value) !void {
    if (v != .object) return;
    const labs = v.object.get("labels") orelse return;
    if (labs != .array or labs.array.items.len == 0) return;
    try append(out, gpa, "Labels: ");
    for (labs.array.items, 0..) |lab, i| {
        if (i > 0) try append(out, gpa, ", ");
        try append(out, gpa, strField(lab, "name"));
    }
    try append(out, gpa, "\n");
}

/// A PR view. Carries the review summary a `gh://pr/o/r/n` read exists for:
/// without head/base and the merge state the output was an issue view under a
/// different heading, and the model had to fetch the diff to learn anything
/// about the change.
pub fn pullRequest(gpa: std.mem.Allocator, v: std.json.Value) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try append(&out, gpa, "PR #");
    try appendInt(&out, gpa, intField(v, "number") orelse 0);
    try append(&out, gpa, ": ");
    try append(&out, gpa, strField(v, "title"));
    try append(&out, gpa, " (");
    try append(&out, gpa, strField(v, "state"));
    if (boolField(v, "draft") orelse false) try append(&out, gpa, ", draft");
    if (boolField(v, "merged") orelse false) try append(&out, gpa, ", merged");
    try append(&out, gpa, ")\n");

    const head = refName(v, "head");
    const base = refName(v, "base");
    if (head.len > 0 or base.len > 0) {
        try append(&out, gpa, head);
        try append(&out, gpa, " -> ");
        try append(&out, gpa, base);
        try append(&out, gpa, "\n");
    }

    // `mergeable` is null while GitHub is still computing it, and that is worth
    // saying rather than reporting "not mergeable" for a PR that is fine.
    try append(&out, gpa, "Mergeable: ");
    if (boolField(v, "mergeable")) |m| {
        try append(&out, gpa, if (m) "yes" else "no");
    } else {
        try append(&out, gpa, "unknown");
    }
    const state = strField(v, "mergeable_state");
    if (state.len > 0) {
        try append(&out, gpa, " (");
        try append(&out, gpa, state);
        try append(&out, gpa, ")");
    }
    try append(&out, gpa, "\n");

    if (intField(v, "changed_files")) |n| {
        try append(&out, gpa, "Files: ");
        try appendInt(&out, gpa, n);
        if (intField(v, "additions")) |a| {
            try append(&out, gpa, " (+");
            try appendInt(&out, gpa, a);
            try append(&out, gpa, " -");
            try appendInt(&out, gpa, intField(v, "deletions") orelse 0);
            try append(&out, gpa, ")");
        }
        try append(&out, gpa, "\n");
    }
    try appendLabels(&out, gpa, v);
    try append(&out, gpa, "\n");
    try append(&out, gpa, strField(v, "body"));
    try append(&out, gpa, "\n");
    return out.toOwnedSlice(gpa);
}

pub fn issueList(gpa: std.mem.Allocator, v: std.json.Value) ![]u8 {
    if (v != .array) return gpa.dupe(u8, "[]");
    var out: std.ArrayList(u8) = .empty;
    for (v.array.items) |item| {
        const num = intField(item, "number") orelse continue;
        try append(&out, gpa, "#");
        try appendInt(&out, gpa, num);
        try append(&out, gpa, " ");
        try append(&out, gpa, strField(item, "state"));
        try append(&out, gpa, " ");
        try append(&out, gpa, strField(item, "title"));
        try append(&out, gpa, "\n");
    }
    if (v.array.items.len >= gh_url.page_size) try append(&out, gpa, truncation_note);
    return out.toOwnedSlice(gpa);
}

/// The concatenated patches of a PR, or of one file in it when `want` is set.
///
/// Each patch gets the `--- a/<path>` / `+++ b/<path>` header pair a unified
/// diff carries. GitHub's `patch` field starts at the first `@@` hunk and names
/// no file, so concatenating patches straight from the response -- what shipped
/// -- produced a run of hunks that could not be attributed to any file as soon
/// as a PR touched more than one.
pub fn files(gpa: std.mem.Allocator, v: std.json.Value, want: []const u8) ![]u8 {
    if (v != .array) return gpa.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    var matched: usize = 0;
    for (v.array.items) |item| {
        const name = strField(item, "filename");
        if (want.len > 0 and !std.mem.eql(u8, name, want)) continue;
        matched += 1;
        const patch = strField(item, "patch");
        if (patch.len == 0) {
            // Binary files, and files over GitHub's per-file diff limit, come
            // back with no `patch`. Silently skipping them made a renamed
            // binary look like it was not in the PR at all.
            try append(&out, gpa, "--- a/");
            try append(&out, gpa, name);
            try append(&out, gpa, "\n+++ b/");
            try append(&out, gpa, name);
            try append(&out, gpa, "\n[no patch: ");
            const status = strField(item, "status");
            try append(&out, gpa, if (status.len > 0) status else "binary or too large");
            try append(&out, gpa, "]\n");
            continue;
        }
        try append(&out, gpa, "--- a/");
        try append(&out, gpa, name);
        try append(&out, gpa, "\n+++ b/");
        try append(&out, gpa, name);
        try append(&out, gpa, "\n");
        try append(&out, gpa, patch);
        try append(&out, gpa, "\n");
    }
    if (want.len > 0 and matched == 0) {
        // An empty ok reply read as "this file has no changes". It is far more
        // often a typo in the path, and the two need different fixes.
        try append(&out, gpa, "no file named '");
        try append(&out, gpa, want);
        try append(&out, gpa, "' in this pull request\n");
    }
    if (v.array.items.len >= gh_url.page_size) try append(&out, gpa, truncation_note);
    return out.toOwnedSlice(gpa);
}

/// The message for a >= 400 response, given the status and whatever the server
/// put in the body.
///
/// `ck_http` reports every error status as `error.NetworkError`, the same error
/// a DNS failure gives, so before the host started parking the status in the
/// result slot the two documented messages below could not fire: the body scans
/// they were written around were reading a body that had already been dropped.
/// `X-RateLimit-Reset` as `YYYY-MM-DDTHH:MM:SSZ`, or null when there is nothing
/// usable to render.
///
/// GitHub sends the reset as a Unix timestamp, which is not something to put in
/// front of a model: "resets at 1787571816" is a number it has to be told how to
/// read, where an ISO 8601 instant is self-describing. UTC with an explicit `Z`
/// rather than local time -- the header is UTC, and quietly converting it would
/// make the message depend on the machine that printed it.
pub fn isoFromUnix(buf: *[20]u8, secs: i64) ?[]const u8 {
    // A zero or negative stamp is a header that did not parse, not the epoch.
    if (secs <= 0) return null;
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(secs) };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch null;
}

/// `reset_epoch` is `X-RateLimit-Reset` when the caller could read it, and null
/// otherwise. It stays optional rather than becoming required because the header
/// is only reachable through `ck_http_ex`: a caller on the older `ck_http`
/// channel has no way to supply it, and the message without a reset time is
/// still the message that shipped.
pub fn statusMessage(gpa: std.mem.Allocator, url: []const u8, status: u16, body: []const u8, reset_epoch: ?i64) ![]u8 {
    if (looksLikeRateLimit(body) or status == 429) {
        if (reset_epoch) |secs| {
            var buf: [20]u8 = undefined;
            if (isoFromUnix(&buf, secs)) |iso| {
                return std.fmt.allocPrint(gpa, "GitHub rate limit exhausted; resets at {s}", .{iso});
            }
        }
        return gpa.dupe(u8, "GitHub rate limit exhausted");
    }
    return switch (status) {
        404 => std.fmt.allocPrint(gpa, "not found: {s}", .{url}),
        401 => gpa.dupe(u8, "GITHUB_TOKEN rejected by GitHub (401); the token is invalid or expired"),
        // A 403 without a rate-limit body is a permission answer: a private
        // repository the token cannot see, or SAML/SSO not authorized.
        403 => std.fmt.allocPrint(gpa, "forbidden: {s} (token lacks access, or SSO is not authorized)", .{url}),
        else => blk: {
            const msg = apiMessage(body);
            if (msg.len > 0) {
                break :blk std.fmt.allocPrint(gpa, "{s}: HTTP {d}: {s}", .{ url, status, msg });
            }
            break :blk std.fmt.allocPrint(gpa, "{s}: HTTP {d}", .{ url, status });
        },
    };
}

pub fn looksLikeRateLimit(body: []const u8) bool {
    return std.mem.find(u8, body, "API rate limit exceeded") != null or
        std.mem.find(u8, body, "secondary rate limit") != null;
}

/// The `message` of a GitHub error object, without parsing: this runs on a body
/// that may be HTML from a proxy rather than the JSON the API promises.
fn apiMessage(body: []const u8) []const u8 {
    const key = "\"message\":";
    const at = std.mem.find(u8, body, key) orelse return "";
    var i = at + key.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
    if (i >= body.len or body[i] != '"') return "";
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') {
        if (body[i] == '\\') i += 1;
        i += 1;
    }
    if (i > body.len) return "";
    return body[start..@min(i, body.len)];
}

// --------------------------------------------------------------------- tests --

fn parse(arena: std.mem.Allocator, src: []const u8) std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{}) catch unreachable;
}

test "a PR view reports head, base and merge state, not just title and body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try pullRequest(arena, parse(arena,
        \\{"number":7,"title":"Widen the gate","state":"open","draft":false,
        \\ "head":{"label":"acme:fix-gate","ref":"fix-gate"},
        \\ "base":{"label":"acme:main","ref":"main"},
        \\ "mergeable":true,"mergeable_state":"clean",
        \\ "changed_files":3,"additions":40,"deletions":2,"body":"why"}
    ));
    try std.testing.expectEqualStrings(
        \\PR #7: Widen the gate (open)
        \\acme:fix-gate -> acme:main
        \\Mergeable: yes (clean)
        \\Files: 3 (+40 -2)
        \\
        \\why
        \\
    , text);
}

test "a PR whose mergeability GitHub has not computed says unknown, not no" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try pullRequest(arena, parse(arena,
        \\{"number":9,"title":"t","state":"open","draft":true,"mergeable":null,"body":""}
    ));
    try std.testing.expect(std.mem.find(u8, text, "Mergeable: unknown") != null);
    try std.testing.expect(std.mem.find(u8, text, "(open, draft)") != null);
}

test "every hunk in a multi-file diff names its file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Shape taken from a real /pulls/{n}/files response: `patch` begins at the
    // first `@@` and names no file anywhere.
    const resp = parse(arena,
        \\[{"filename":"src/a.zig","status":"modified","patch":"@@ -1,2 +1,3 @@\n+one"},
        \\ {"filename":"src/b.zig","status":"modified","patch":"@@ -9,1 +9,2 @@\n+two"}]
    );
    const text = try files(arena, resp, "");
    try std.testing.expectEqualStrings(
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -1,2 +1,3 @@
        \\+one
        \\--- a/src/b.zig
        \\+++ b/src/b.zig
        \\@@ -9,1 +9,2 @@
        \\+two
        \\
    , text);
}

test "a file with no patch is reported, not dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try files(arena, parse(arena,
        \\[{"filename":"logo.png","status":"added"}]
    ), "");
    try std.testing.expect(std.mem.find(u8, text, "--- a/logo.png") != null);
    try std.testing.expect(std.mem.find(u8, text, "[no patch: added]") != null);
}

test "a diff path that matches nothing says so instead of returning empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resp = parse(arena,
        \\[{"filename":"src/a.zig","patch":"@@ -1 +1 @@\n+x"}]
    );
    const missing = try files(arena, resp, "src/typo.zig");
    try std.testing.expectEqualStrings("no file named 'src/typo.zig' in this pull request\n", missing);

    const hit = try files(arena, resp, "src/a.zig");
    try std.testing.expect(std.mem.find(u8, hit, "+++ b/src/a.zig") != null);
    try std.testing.expect(std.mem.find(u8, hit, "no file named") == null);
}

test "a full page of results carries a truncation note; a short page does not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "[");
    for (0..gh_url.page_size) |i| {
        if (i > 0) try buf.appendSlice(arena, ",");
        try buf.print(arena, "{{\"number\":{d},\"state\":\"open\",\"title\":\"t\"}}", .{i + 1});
    }
    try buf.appendSlice(arena, "]");

    const full = try issueList(arena, parse(arena, buf.items));
    try std.testing.expect(std.mem.find(u8, full, "truncated") != null);

    const short = try issueList(arena, parse(arena,
        \\[{"number":1,"state":"open","title":"t"}]
    ));
    try std.testing.expect(std.mem.find(u8, short, "truncated") == null);
}

test "a 404 and a rate limit produce their documented messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "not found: gh://issue/acme/widget/999",
        try statusMessage(arena, "gh://issue/acme/widget/999", 404,
            \\{"message":"Not Found","status":"404"}
        , null),
    );
    // Primary rate limit: GitHub answers 403 with the message in the body.
    try std.testing.expectEqualStrings(
        "GitHub rate limit exhausted",
        try statusMessage(arena, "gh://issue/a/b", 403,
            \\{"message":"API rate limit exceeded for user ID 1."}
        , null),
    );
    // Secondary rate limit: 403 too, with a different message.
    try std.testing.expectEqualStrings(
        "GitHub rate limit exhausted",
        try statusMessage(arena, "gh://issue/a/b", 403,
            \\{"message":"You have exceeded a secondary rate limit."}
        , null),
    );
    // 429 is always a rate limit, whatever the body says.
    try std.testing.expectEqualStrings(
        "GitHub rate limit exhausted",
        try statusMessage(arena, "gh://issue/a/b", 429, "", null),
    );
}

test "a rate limit names when it resets, once the reset header is reachable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // PRD 0019 asks for "the rate-limit error includes a reset time (resets at
    // <ISO8601>)". It was unshippable rather than unbuilt: `X-RateLimit-Reset`
    // exists nowhere but the response head, and `ck_http` had no channel for a
    // header, so no amount of body parsing could recover it. `ck_http_ex` is
    // that channel (ADR 0049).
    try std.testing.expectEqualStrings(
        "GitHub rate limit exhausted; resets at 2026-08-24T11:43:36Z",
        try statusMessage(arena, "gh://issue/a/b", 403,
            \\{"message":"API rate limit exceeded for user ID 1."}
        , 1787571816),
    );
    // 429 with no body still gets the time.
    try std.testing.expectEqualStrings(
        "GitHub rate limit exhausted; resets at 2026-08-24T11:43:36Z",
        try statusMessage(arena, "gh://issue/a/b", 429, "", 1787571816),
    );
    // A header that did not parse must not turn into a date in 1970: the
    // message falls back to the one that shipped rather than inventing a time.
    try std.testing.expectEqualStrings(
        "GitHub rate limit exhausted",
        try statusMessage(arena, "gh://issue/a/b", 429, "", 0),
    );
    try std.testing.expectEqualStrings(
        "GitHub rate limit exhausted",
        try statusMessage(arena, "gh://issue/a/b", 429, "", -5),
    );
    // A reset time on a non-rate-limit status changes nothing: the header rides
    // along on every response and must not leak into unrelated messages.
    try std.testing.expectEqualStrings(
        "not found: gh://issue/a/b",
        try statusMessage(arena, "gh://issue/a/b", 404,
            \\{"message":"Not Found"}
        , 1787571816),
    );
}

test "isoFromUnix renders UTC, and refuses a stamp that is not one" {
    var buf: [20]u8 = undefined;
    // The value measured live from api.github.com's X-RateLimit-Reset.
    try std.testing.expectEqualStrings("2026-08-24T11:43:36Z", isoFromUnix(&buf, 1787571816).?);
    // A leap-year end-of-day, since the month/day arithmetic is the part with
    // an off-by-one waiting in it (`day_index` is 0-based).
    try std.testing.expectEqualStrings("2024-02-29T23:59:59Z", isoFromUnix(&buf, 1709251199).?);
    try std.testing.expectEqualStrings("2000-03-01T00:00:00Z", isoFromUnix(&buf, 951868800).?);
    try std.testing.expect(isoFromUnix(&buf, 0) == null);
    try std.testing.expect(isoFromUnix(&buf, -1) == null);
}

test "a 403 that is not a rate limit is not reported as one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try statusMessage(arena, "gh://issue/acme/private", 403,
        \\{"message":"Must have admin rights to Repository."}
    , null);
    try std.testing.expect(std.mem.find(u8, text, "forbidden") != null);
    try std.testing.expect(std.mem.find(u8, text, "rate limit") == null);
}

test "an unclassified status carries the server's own message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "gh://issue/a/b: HTTP 422: Validation Failed",
        try statusMessage(arena, "gh://issue/a/b", 422,
            \\{"message":"Validation Failed","errors":[]}
        , null),
    );
    // A body that is not the JSON the API promises must not invent a message.
    try std.testing.expectEqualStrings(
        "gh://issue/a/b: HTTP 502",
        try statusMessage(arena, "gh://issue/a/b", 502, "<html>bad gateway</html>", null),
    );
}

test "an issue view keeps title, state, labels and body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try issue(arena, parse(arena,
        \\{"number":42,"title":"It breaks","state":"open",
        \\ "labels":[{"name":"bug"},{"name":"p1"}],"body":"steps"}
    ));
    try std.testing.expectEqualStrings(
        \\Issue #42: It breaks (open)
        \\Labels: bug, p1
        \\
        \\steps
        \\
    , text);
}
