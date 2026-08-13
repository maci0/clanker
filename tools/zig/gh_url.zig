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

pub fn apiPath(arena: std.mem.Allocator, ref: Ref) ![]const u8 {
    return switch (ref.kind) {
        .issue => std.fmt.allocPrint(arena, "/repos/{s}/{s}/issues/{d}", .{ ref.owner, ref.repo, ref.number }),
        .pr => std.fmt.allocPrint(arena, "/repos/{s}/{s}/pulls/{d}", .{ ref.owner, ref.repo, ref.number }),
        .pr_diff, .pr_file => std.fmt.allocPrint(arena, "/repos/{s}/{s}/pulls/{d}/files", .{ ref.owner, ref.repo, ref.number }),
        .issue_list => blk: {
            if (ref.query.len > 0) {
                break :blk std.fmt.allocPrint(arena, "/repos/{s}/{s}/issues?{s}", .{ ref.owner, ref.repo, ref.query });
            }
            break :blk std.fmt.allocPrint(arena, "/repos/{s}/{s}/issues", .{ ref.owner, ref.repo });
        },
    };
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
