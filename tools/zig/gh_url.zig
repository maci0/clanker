//! Parse `gh://` / `github://` URLs for the `gh_read` guest.

const std = @import("std");

pub const Kind = enum { issue, pr, pr_diff, pr_file, issue_list };

pub const Ref = struct {
    kind: Kind,
    owner: []const u8,
    repo: []const u8,
    number: u32 = 0,
    subpath: []const u8 = "",
    query: []const u8 = "",
};

pub fn parse(url: []const u8) ?Ref {
    const rest = if (std.mem.startsWith(u8, url, "gh://"))
        url["gh://".len..]
    else if (std.mem.startsWith(u8, url, "github://"))
        url["github://".len..]
    else
        return null;

    const qpos = std.mem.findScalar(u8, rest, '?');
    const path = if (qpos) |i| rest[0..i] else rest;
    const query = if (qpos) |i| rest[i + 1 ..] else "";

    var it = std.mem.splitScalar(u8, path, '/');
    const resource = it.next() orelse return null;
    const owner = it.next() orelse return null;
    const repo = it.next() orelse return null;
    if (owner.len == 0 or repo.len == 0) return null;

    if (std.mem.eql(u8, resource, "issue")) {
        if (it.next()) |num_s| {
            const n = std.fmt.parseInt(u32, num_s, 10) catch return null;
            if (it.next() != null) return null;
            return .{ .kind = .issue, .owner = owner, .repo = repo, .number = n, .query = query };
        }
        return .{ .kind = .issue_list, .owner = owner, .repo = repo, .query = query };
    }
    if (std.mem.eql(u8, resource, "pr")) {
        const num_s = it.next() orelse return null;
        const n = std.fmt.parseInt(u32, num_s, 10) catch return null;
        if (it.next()) |sub| {
            if (!std.mem.eql(u8, sub, "diff")) return null;
            const file = it.rest();
            if (file.len > 0) {
                return .{ .kind = .pr_file, .owner = owner, .repo = repo, .number = n, .subpath = file };
            }
            return .{ .kind = .pr_diff, .owner = owner, .repo = repo, .number = n };
        }
        return .{ .kind = .pr, .owner = owner, .repo = repo, .number = n };
    }
    return null;
}

/// Items asked for on every list endpoint, and GitHub's documented maximum.
///
/// Sending no `per_page` gets GitHub's default of 30 with the rest behind a
/// `Link: rel="next"` header the guest never sees, so a 40-file PR diff came
/// back silently missing ten files and a repository with 200 open issues listed
/// 30 of them with nothing saying so. Asking for the maximum does not make the
/// result complete -- it makes the truncation visible, because a response
/// holding exactly this many items is the signal that a next page exists.
pub const page_size: u32 = 100;

pub fn apiPath(arena: std.mem.Allocator, ref: Ref) ![]const u8 {
    return switch (ref.kind) {
        .issue => std.fmt.allocPrint(arena, "/repos/{s}/{s}/issues/{d}", .{ ref.owner, ref.repo, ref.number }),
        .pr => std.fmt.allocPrint(arena, "/repos/{s}/{s}/pulls/{d}", .{ ref.owner, ref.repo, ref.number }),
        .pr_diff, .pr_file => std.fmt.allocPrint(
            arena,
            "/repos/{s}/{s}/pulls/{d}/files?per_page={d}",
            .{ ref.owner, ref.repo, ref.number, page_size },
        ),
        .issue_list => blk: {
            if (ref.query.len == 0) {
                break :blk std.fmt.allocPrint(
                    arena,
                    "/repos/{s}/{s}/issues?per_page={d}",
                    .{ ref.owner, ref.repo, page_size },
                );
            }
            // A caller who named `per_page` themselves keeps it: the point is
            // that a page size is always stated, not that this one wins.
            if (hasParam(ref.query, "per_page")) {
                break :blk std.fmt.allocPrint(arena, "/repos/{s}/{s}/issues?{s}", .{ ref.owner, ref.repo, ref.query });
            }
            break :blk std.fmt.allocPrint(
                arena,
                "/repos/{s}/{s}/issues?{s}&per_page={d}",
                .{ ref.owner, ref.repo, ref.query, page_size },
            );
        },
    };
}

/// Whether `query` (a raw `a=1&b=2` string) already carries `name`.
fn hasParam(query: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.findScalar(u8, pair, '=') orelse pair.len;
        if (std.mem.eql(u8, pair[0..eq], name)) return true;
    }
    return false;
}

test "parses issue, pr, diff, list" {
    const issue = parse("gh://issue/acme/widget/42").?;
    try std.testing.expectEqual(Kind.issue, issue.kind);
    try std.testing.expectEqualStrings("acme", issue.owner);
    try std.testing.expectEqual(@as(u32, 42), issue.number);

    const pr = parse("github://pr/acme/widget/7").?;
    try std.testing.expectEqual(Kind.pr, pr.kind);

    const diff = parse("gh://pr/acme/widget/7/diff").?;
    try std.testing.expectEqual(Kind.pr_diff, diff.kind);

    const file = parse("gh://pr/acme/widget/7/diff/src/widget.zig").?;
    try std.testing.expectEqual(Kind.pr_file, file.kind);
    try std.testing.expectEqualStrings("src/widget.zig", file.subpath);

    const list = parse("gh://issue/acme/widget?state=open&label=bug").?;
    try std.testing.expectEqual(Kind.issue_list, list.kind);
    try std.testing.expectEqualStrings("state=open&label=bug", list.query);
}

test "rejects missing owner and non-numeric numbers" {
    try std.testing.expect(parse("gh://issue/acme") == null);
    try std.testing.expect(parse("gh://pr/acme/widget/abc") == null);
    try std.testing.expect(parse("/local/path") == null);
}

test "apiPath maps every ref kind to its REST endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "/repos/acme/widget/issues/42",
        try apiPath(arena, parse("gh://issue/acme/widget/42").?),
    );
    try std.testing.expectEqualStrings(
        "/repos/acme/widget/pulls/7",
        try apiPath(arena, parse("gh://pr/acme/widget/7").?),
    );
    // A PR view and a PR *diff* are different endpoints: /pulls/{n} carries the
    // review metadata, /pulls/{n}/files carries the patches.
    try std.testing.expectEqualStrings(
        "/repos/acme/widget/pulls/7/files?per_page=100",
        try apiPath(arena, parse("gh://pr/acme/widget/7/diff").?),
    );
    // A single-file diff narrows host-side, not in the request: the same
    // endpoint is fetched and `subpath` filters the response, so one cached
    // fetch serves both the whole diff and any file in it.
    try std.testing.expectEqualStrings(
        "/repos/acme/widget/pulls/7/files?per_page=100",
        try apiPath(arena, parse("gh://pr/acme/widget/7/diff/src/widget.zig").?),
    );
    try std.testing.expectEqualStrings(
        "/repos/acme/widget/issues?per_page=100",
        try apiPath(arena, parse("gh://issue/acme/widget").?),
    );
}

test "apiPath always states a page size, and never twice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The defect this pins: with no per_page GitHub answers 30 items and hides
    // the rest behind a Link header no guest can read, so a list silently lost
    // everything past the first page.
    try std.testing.expectEqualStrings(
        "/repos/acme/widget/issues?state=open&label=bug&per_page=100",
        try apiPath(arena, parse("gh://issue/acme/widget?state=open&label=bug").?),
    );
    // A caller's own per_page is not doubled -- GitHub takes the last value,
    // so appending ours would have quietly overridden theirs.
    try std.testing.expectEqualStrings(
        "/repos/acme/widget/issues?per_page=5&state=open",
        try apiPath(arena, parse("gh://issue/acme/widget?per_page=5&state=open").?),
    );
    // `per_page_extra` starts with the same bytes and is not the same key.
    try std.testing.expect(std.mem.endsWith(
        u8,
        try apiPath(arena, parse("gh://issue/acme/widget?per_pageish=5").?),
        "&per_page=100",
    ));
}
