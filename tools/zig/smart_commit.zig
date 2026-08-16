//! Group a working-tree diff into conventional commits.

const std = @import("std");
const lib = @import("lib.zig");
const logic = @import("commit_logic.zig");
const utf8 = @import("utf8");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object");
    const obj = parsed.object;
    const dry = switch (obj.get("dry_run") orelse std.json.Value{ .bool = true }) {
        .bool => |b| b,
        else => true,
    };
    const scope = switch (obj.get("scope") orelse std.json.Value{ .string = "staged" }) {
        .string => |s| s,
        else => "staged",
    };
    const max_commits: usize = switch (obj.get("max_commits") orelse std.json.Value{ .integer = 10 }) {
        .integer => |n| if (n < 1) 1 else @as(usize, @intCast(n)),
        else => 10,
    };

    const names = (if (std.mem.eql(u8, scope, "all"))
        gitOut(&.{ "diff", "--name-only" })
    else
        gitOut(&.{ "diff", "--name-only", "--staged" })) catch
        return lib.fail(out, "git diff failed");
    var files: std.ArrayList([]const u8) = .empty;
    var excluded: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, names, " \t\r\n"), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (logic.isLockFile(line)) {
            try excluded.append(lib.alloc, line);
            continue;
        }
        try files.append(lib.alloc, line);
    }
    if (files.items.len == 0) {
        return writeEmpty(out, excluded.items);
    }

    const diff_args: []const []const u8 = if (std.mem.eql(u8, scope, "all"))
        &.{"diff"}
    else
        &.{ "diff", "--staged" };
    const diff = gitOut(diff_args) catch "";
    const plan = try groupViaLlm(files.items, diff, max_commits);
    const groups = plan.groups;
    for (groups) |g| {
        if (!logic.validMessage(g.message)) {
            return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "invalid conventional commit message: {s}", .{g.message}));
        }
    }

    const order_or = orderGroups(groups);
    var note: []const u8 = plan.note;
    var ordered = groups;
    if (order_or) |ord| {
        var rearranged = try lib.alloc.alloc(logic.Group, groups.len);
        for (ord, 0..) |idx, i| rearranged[i] = groups[idx];
        ordered = rearranged;
    } else |err| switch (err) {
        error.DegenerateCycle => {
            note = "dependency cycle spanned every group; merged into one commit";
            ordered = try mergeAll(groups);
        },
        error.PartialCycle => return lib.fail(out, "dependency cycle between some groups; revise the grouping"),
        else => return err,
    }
    for (ordered) |*g| {
        const copy = try lib.alloc.dupe([]const u8, g.files);
        logic.sortFiles(copy);
        g.files = copy;
    }

    if (!dry) {
        for (ordered) |g| {
            gitRun(try prepend("add", "--", g.files)) catch |err| {
                return lib.failErr(out, err, "git add");
            };
            gitRun(&.{ "commit", "-m", g.message }) catch |err| {
                return lib.failErr(out, err, "git commit");
            };
        }
    }

    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("dry_run");
    try s.write(dry);
    if (note.len > 0) {
        try s.objectField("note");
        try s.write(note);
    }
    if (excluded.items.len > 0) {
        try s.objectField("excluded");
        try s.write(excluded.items);
    }
    try s.objectField("commits");
    try s.beginArray();
    for (ordered) |g| {
        try s.beginObject();
        try s.objectField("message");
        try s.write(g.message);
        try s.objectField("files");
        try s.write(g.files);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}

fn writeEmpty(out: *lib.Out, excluded: []const []const u8) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("commits");
    try s.beginArray();
    try s.endArray();
    try s.objectField("message");
    try s.write("nothing to commit");
    if (excluded.len > 0) {
        try s.objectField("excluded");
        try s.write(excluded);
    }
    try s.endObject();
    lib.commit(out, &w);
}

fn gitOut(args: []const []const u8) ![]const u8 {
    const raw = try lib.exec("git", args);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{});
    if (v != .object) return error.InvalidArg;
    return switch (v.object.get("stdout") orelse return "") {
        .string => |s| s,
        else => "",
    };
}

fn gitRun(args: []const []const u8) !void {
    _ = try lib.exec("git", args);
}

fn prepend(a: []const u8, b: []const u8, rest: []const []const u8) ![]const []const u8 {
    var out = try lib.alloc.alloc([]const u8, rest.len + 2);
    out[0] = a;
    out[1] = b;
    @memcpy(out[2..], rest);
    return out;
}

const GroupPlan = struct { groups: []logic.Group, note: []const u8 };

fn groupViaLlm(files: []const []const u8, diff: []const u8, max_commits: usize) !GroupPlan {
    const prompt = try std.fmt.allocPrint(lib.alloc,
        \\You are grouping a git diff into atomic commits. Group files by logical concern.
        \\Reply with JSON only:
        \\{{"commits": [{{"message": "<conventional commit message>", "files": ["path", ...]}}]}}
        \\Use types: feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert
        \\Files:
        \\{s}
        \\
        \\Diff:
        \\{s}
    , .{ joinLines(files), utf8.cap(diff, 12000) });
    const reply = lib.llm(prompt) catch return .{
        .groups = try oneGroup(files, "chore: update working tree"),
        .note = "llm call failed; fell back to one generic commit",
    };
    const groups = parseGroups(reply, files, max_commits) catch return .{
        .groups = try oneGroup(files, "chore: update working tree"),
        .note = "llm reply held no usable grouping (possibly truncated by the max_tokens grant); fell back to one generic commit",
    };
    return .{ .groups = groups, .note = "" };
}

fn joinLines(files: []const []const u8) []const u8 {
    return std.mem.join(lib.alloc, "\n", files) catch "";
}

fn oneGroup(files: []const []const u8, message: []const u8) ![]logic.Group {
    const g = try lib.alloc.alloc(logic.Group, 1);
    g[0] = .{ .message = message, .files = files };
    return g;
}

fn mergeAll(groups: []const logic.Group) ![]logic.Group {
    var files: std.ArrayList([]const u8) = .empty;
    for (groups) |g| try files.appendSlice(lib.alloc, g.files);
    return oneGroup(files.items, groups[0].message);
}

fn parseGroups(raw: []const u8, all_files: []const []const u8, max_commits: usize) ![]logic.Group {
    const start = std.mem.findScalar(u8, raw, '{') orelse return error.InvalidArg;
    const end = std.mem.lastIndexOfScalar(u8, raw, '}') orelse return error.InvalidArg;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw[start .. end + 1], .{});
    if (v != .object) return error.InvalidArg;
    const arr = switch (v.object.get("commits") orelse return error.InvalidArg) {
        .array => |a| a,
        else => return error.InvalidArg,
    };
    var out: std.ArrayList(logic.Group) = .empty;
    for (arr.items) |item| {
        if (item != .object) continue;
        const msg = switch (item.object.get("message") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        const fl = switch (item.object.get("files") orelse continue) {
            .array => |a| a,
            else => continue,
        };
        var files: std.ArrayList([]const u8) = .empty;
        for (fl.items) |f| {
            const name = switch (f) {
                .string => |s| s,
                else => continue,
            };
            if (inList(name, all_files)) try files.append(lib.alloc, name);
        }
        if (files.items.len == 0) continue;
        try out.append(lib.alloc, .{ .message = msg, .files = files.items });
    }
    if (out.items.len == 0) return error.InvalidArg;
    if (out.items.len > max_commits) {
        var extra: std.ArrayList([]const u8) = .empty;
        for (out.items[max_commits - 1 ..]) |g| try extra.appendSlice(lib.alloc, g.files);
        out.items[max_commits - 1].files = extra.items;
        out.shrinkRetainingCapacity(max_commits);
    }
    return out.toOwnedSlice(lib.alloc);
}

fn inList(name: []const u8, files: []const []const u8) bool {
    for (files) |f| if (std.mem.eql(u8, f, name)) return true;
    return false;
}

fn orderGroups(groups: []const logic.Group) ![]usize {
    const n = groups.len;
    var deps = try lib.alloc.alloc([]usize, n);
    for (0..n) |i| {
        var ds: std.ArrayList(usize) = .empty;
        for (0..n) |j| {
            if (i == j) continue;
            if (groupDepends(groups[i], groups[j])) try ds.append(lib.alloc, j);
        }
        deps[i] = ds.items;
    }
    return logic.topoSort(lib.alloc, n, deps);
}

fn groupDepends(a: logic.Group, b: logic.Group) bool {
    for (a.files) |af| {
        for (b.files) |bf| {
            const base = std.fs.path.basename(bf);
            const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
            if (logic.isTestPath(af) and std.mem.find(u8, af, stem) != null)
                return true;
            if (logic.references(af, bf)) return true;
        }
    }
    return false;
}
