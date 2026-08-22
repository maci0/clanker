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
    if (!std.mem.eql(u8, scope, "staged") and !std.mem.eql(u8, scope, "all"))
        return lib.fail(out, "scope must be \"staged\" or \"all\"");
    const max_commits: usize = switch (obj.get("max_commits") orelse std.json.Value{ .integer = 10 }) {
        .integer => |n| if (n < 1) 1 else @as(usize, @intCast(n)),
        else => 10,
    };

    var files: std.ArrayList([]const u8) = .empty;
    var excluded: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, scope, "all")) {
        // `git diff --name-only` is worktree against index, so it can never
        // name a new file: an untracked one is not in any diff, and one that
        // was `git add`ed is identical in index and worktree. Scope "all"
        // therefore unions the worktree diff with `--staged` (already added)
        // and `ls-files --others --exclude-standard` (untracked, honouring
        // .gitignore), or --all silently drops every new file while
        // reporting success.
        const listings = [_][]const u8{
            gitOut(&.{ "diff", "--name-only" }) catch
                return lib.fail(out, "git diff failed"),
            gitOut(&.{ "diff", "--name-only", "--staged" }) catch
                return lib.fail(out, "git diff failed"),
            gitOut(&.{ "ls-files", "--others", "--exclude-standard" }) catch
                return lib.fail(out, "git ls-files failed"),
        };
        try logic.collectFiles(lib.alloc, &listings, &files, &excluded);
    } else {
        const names = gitOut(&.{ "diff", "--name-only", "--staged" }) catch
            return lib.fail(out, "git diff failed");
        try logic.collectFiles(lib.alloc, &.{names}, &files, &excluded);
    }
    if (files.items.len == 0) {
        return writeEmpty(out, excluded.items);
    }

    // A `commits` array in the input is a plan that has already been made and
    // shown to whoever is about to have it written. Replaying it is the only
    // way the write can be the plan that was confirmed: asking a sampling model
    // for the grouping a second time answers a second time.
    const given = planFromInput(obj) catch
        return lib.fail(out, "commits must be a list of {message, files: [path, ...]}");
    var note: []const u8 = "";
    var degraded = false;
    var ordered: []logic.Group = undefined;
    if (given) |g| {
        if (unstagedPlanFile(g, files.items)) |path| {
            return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "the plan names {s}, which is not in this diff; re-run the preview", .{path}));
        }
        // Ordering is not redone: the plan carries the order it was shown in.
        ordered = g;
    } else {
        const diff_args: []const []const u8 = if (std.mem.eql(u8, scope, "all"))
            &.{"diff"}
        else
            &.{ "diff", "--staged" };
        const diff = gitOut(diff_args) catch "";
        const plan = try groupViaLlm(files.items, diff, max_commits);
        const groups = plan.groups;
        note = plan.note;
        degraded = plan.degraded;
        ordered = groups;
        if (orderGroups(groups)) |ord| {
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
    }
    for (ordered) |g| {
        if (!logic.validMessage(g.message)) {
            return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "invalid conventional commit message: {s}", .{g.message}));
        }
    }
    for (ordered) |*g| {
        const copy = try lib.alloc.dupe([]const u8, g.files);
        logic.sortFiles(copy);
        g.files = copy;
    }

    if (!dry) {
        if (std.mem.eql(u8, scope, "all")) {
            for (ordered) |g| {
                var detail: []const u8 = "";
                gitRun(try prepend("add", "--", g.files), &detail) catch |err| {
                    return lib.failErr(out, err, "git add");
                };
                if (detail.len > 0) return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "git add: {s}", .{detail}));
                // Pathspec, not a bare `git commit`: a bare one commits the
                // whole index, so anything staged before this tool ran was
                // swept into the first group's commit and every later group
                // found nothing left to commit -- while the reply still listed
                // them all as written. A pathspec commit takes the working-tree
                // copy of the named paths and disregards what is staged for
                // any other path, which is exactly scope "all".
                gitRun(try commitArgs(g.message, g.files), &detail) catch |err| {
                    return lib.failErr(out, err, "git commit");
                };
                if (detail.len > 0) return lib.fail(out, try std.fmt.allocPrint(lib.alloc, "git commit: {s}", .{detail}));
            }
            // Every planned path was committed by pathspec, so a path git
            // still reports as changed or untracked did not reach any commit. Reporting success there would repeat the silent
            // omission this scope exists to prevent.
            const left = uncommittedAmong(ordered) catch
                return lib.fail(out, "the commits were written but the post-commit check could not run (git status failed)");
            if (left.len > 0) {
                return lib.fail(out, try std.fmt.allocPrint(
                    lib.alloc,
                    "{d} planned path(s) did not reach any commit: {s}",
                    .{ left.len, joinLines(left) },
                ));
            }
        } else {
            const problem = try commitGroupsFromIndex(ordered);
            if (problem.len > 0) return lib.fail(out, problem);
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
    if (degraded) {
        // The plan below is a fallback, not the model's grouping. A caller
        // writing without a human in the loop must not treat it as approved.
        try s.objectField("degraded");
        try s.write(true);
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

/// Runs git and reports a non-zero exit through `detail` rather than letting it
/// pass for success. `lib.exec` puts the process status in its JSON reply, not
/// in a Zig error, so the old discarded result meant a `git commit` that had
/// nothing to commit was still counted in the "committed N commit(s)" line.
/// `detail` is set to git's stderr (or a stand-in) on failure and left alone
/// otherwise, so one buffer can be reused across calls.
fn gitRun(args: []const []const u8, detail: *[]const u8) !void {
    const raw = try lib.exec("git", args);
    const v = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch return;
    if (v != .object) return;
    const code: i64 = switch (v.object.get("code") orelse return) {
        .integer => |i| i,
        else => return,
    };
    if (code == 0) return;
    const stderr = switch (v.object.get("stderr") orelse std.json.Value{ .string = "" }) {
        .string => |s| std.mem.trim(u8, s, " \t\r\n"),
        else => "",
    };
    detail.* = if (stderr.len > 0) stderr else try std.fmt.allocPrint(lib.alloc, "exited {d}", .{code});
}

/// Paths from the plan that git still holds outside HEAD. One
/// `git status --porcelain -uall -- <paths>` over every planned path; a path
/// listed back in the output is one no commit collected.
fn uncommittedAmong(groups: []const logic.Group) ![]const []const u8 {
    var want: std.ArrayList([]const u8) = .empty;
    for (groups) |g| try want.appendSlice(lib.alloc, g.files);
    var args = try lib.alloc.alloc([]const u8, want.items.len + 4);
    args[0] = "status";
    args[1] = "--porcelain";
    // Untracked directories otherwise collapse to `dir/`, hiding the exact
    // file this check exists to catch.
    args[2] = "-uall";
    args[3] = "--";
    @memcpy(args[4..], want.items);
    const raw = try gitOut(args);
    var left: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, raw, " \t\r\n"), '\n');
    while (it.next()) |line| {
        if (line.len < 4) continue;
        const reported = porcelainPath(line);
        for (want.items) |w| {
            if (std.mem.eql(u8, w, reported)) {
                try left.append(lib.alloc, w);
                break;
            }
        }
    }
    return left.items;
}

/// `git status --porcelain` line to path: two status bytes, one space, then
/// the path; a rename line carries `old -> new` and only the new side is
/// ours.
fn porcelainPath(line: []const u8) []const u8 {
    const rest = line[3..];
    if (std.mem.indexOf(u8, rest, " -> ")) |arrow| return rest[arrow + 4 ..];
    return rest;
}

/// The plan carried in the input, if there is one. Absent or empty means
/// "group this diff yourself"; anything else present but malformed is an error
/// rather than a silent fallback to a second grouping call.
fn planFromInput(obj: std.json.ObjectMap) !?[]logic.Group {
    const v = obj.get("commits") orelse return null;
    if (v != .array) return error.InvalidArg;
    if (v.array.items.len == 0) return null;
    var out: std.ArrayList(logic.Group) = .empty;
    for (v.array.items) |item| {
        if (item != .object) return error.InvalidArg;
        const message = switch (item.object.get("message") orelse return error.InvalidArg) {
            .string => |s| s,
            else => return error.InvalidArg,
        };
        const raw_files = switch (item.object.get("files") orelse return error.InvalidArg) {
            .array => |a| a,
            else => return error.InvalidArg,
        };
        var files: std.ArrayList([]const u8) = .empty;
        for (raw_files.items) |p| {
            switch (p) {
                .string => |s| try files.append(lib.alloc, s),
                else => return error.InvalidArg,
            }
        }
        if (files.items.len == 0) return error.InvalidArg;
        try out.append(lib.alloc, .{ .message = message, .files = files.items });
    }
    return out.items;
}

/// The first file a replayed plan names that this diff does not hold, if any.
/// The tree can move between the plan and the write -- another session stages
/// something, or the operator does -- and committing a path this run never
/// looked at is exactly the widening this tool is supposed to avoid.
fn unstagedPlanFile(groups: []const logic.Group, staged: []const []const u8) ?[]const u8 {
    for (groups) |g| {
        for (g.files) |f| {
            var found = false;
            for (staged) |s| {
                if (std.mem.eql(u8, s, f)) {
                    found = true;
                    break;
                }
            }
            if (!found) return f;
        }
    }
    return null;
}

/// Commits each group in scope "staged" from the index, so the content that
/// lands is the content the groups were computed from.
///
/// Neither obvious route can do this. `git add -- <files>` replaces the staged
/// copy with the working-tree copy, and `git commit -- <files>` commits the
/// working-tree copy of those paths outright -- so an index a session narrowed
/// to its own hunks (the route in
/// docs/runbooks/concurrent-agent-sessions-on-one-checkout.md) was widened with
/// whatever else was in the file, including another session's half-finished
/// edits.
///
/// The route that does work builds each commit in the index: save the full
/// staged state as a tree, then per group reset the index to the base commit,
/// restore that group's entries from the saved tree, and commit the index. No
/// step writes the working tree, so unstaged edits are still unstaged
/// afterwards. The index is put back from the saved tree at the end -- also
/// after a failure, since a half-built index would look like lost work.
fn commitGroupsFromIndex(groups: []const logic.Group) ![]const u8 {
    const tree_raw = gitOut(&.{"write-tree"}) catch return "git write-tree failed";
    const tree = std.mem.trim(u8, tree_raw, " \t\r\n");
    if (tree.len == 0) return "git write-tree wrote no tree; is this a git repository?";

    const problem = commitEachFromIndex(tree, groups) catch |err|
        try std.fmt.allocPrint(lib.alloc, "committing from the index failed: {s}", .{@errorName(err)});

    var detail: []const u8 = "";
    // A failed restore is reported whether or not the commits themselves went
    // through, and the error from the call itself counts as a failure: it used
    // to be discarded, so a read-tree that never ran left `detail` empty and
    // the half-built index -- the thing this whole routine exists to avoid --
    // was reported as a clean success.
    gitRun(&.{ "read-tree", tree }, &detail) catch |err| {
        if (detail.len == 0) detail = @errorName(err);
    };
    if (detail.len == 0) return problem;

    const restore = try std.fmt.allocPrint(lib.alloc, "the index could not be restored: {s} (git read-tree {s} restores it)", .{ detail, tree });
    if (problem.len == 0)
        return try std.fmt.allocPrint(lib.alloc, "commits were written but {s}", .{restore});
    return try std.fmt.allocPrint(lib.alloc, "{s}; {s}", .{ problem, restore });
}

/// One commit per group, each built in the index. Returns "" when every group
/// committed; the caller restores the index either way.
fn commitEachFromIndex(tree: []const u8, groups: []const logic.Group) ![]const u8 {
    var detail: []const u8 = "";
    // An empty repository has no HEAD to reset the index to.
    gitRun(&.{ "rev-parse", "--verify", "--quiet", "HEAD" }, &detail) catch {};
    const base: []const []const u8 = if (detail.len == 0)
        &.{ "read-tree", "HEAD" }
    else
        &.{ "read-tree", "--empty" };

    for (groups) |g| {
        detail = "";
        gitRun(base, &detail) catch |err| return try std.fmt.allocPrint(lib.alloc, "git read-tree: {s}", .{@errorName(err)});
        if (detail.len > 0) return try std.fmt.allocPrint(lib.alloc, "git read-tree: {s}", .{detail});

        gitRun(try restoreArgs(tree, g.files), &detail) catch |err| return try std.fmt.allocPrint(lib.alloc, "git restore: {s}", .{@errorName(err)});
        if (detail.len > 0) return try std.fmt.allocPrint(lib.alloc, "git restore: {s}", .{detail});

        // Bare on purpose here: the index was just built to hold this group and
        // nothing else, so there is no wider index left for it to sweep.
        gitRun(&.{ "commit", "-m", g.message }, &detail) catch |err| return try std.fmt.allocPrint(lib.alloc, "git commit: {s}", .{@errorName(err)});
        if (detail.len > 0) return try std.fmt.allocPrint(lib.alloc, "git commit: {s}", .{detail});
    }
    return "";
}

/// `git restore --source=<tree> --staged -- <files>`: index only, never the
/// working tree.
fn restoreArgs(tree: []const u8, files: []const []const u8) ![]const []const u8 {
    var out = try lib.alloc.alloc([]const u8, files.len + 4);
    out[0] = "restore";
    out[1] = try std.fmt.allocPrint(lib.alloc, "--source={s}", .{tree});
    out[2] = "--staged";
    out[3] = "--";
    @memcpy(out[4..], files);
    return out;
}

/// `git commit -m <message> -- <files>`.
fn commitArgs(message: []const u8, files: []const []const u8) ![]const []const u8 {
    var out = try lib.alloc.alloc([]const u8, files.len + 4);
    out[0] = "commit";
    out[1] = "-m";
    out[2] = message;
    out[3] = "--";
    @memcpy(out[4..], files);
    return out;
}

fn prepend(a: []const u8, b: []const u8, rest: []const []const u8) ![]const []const u8 {
    var out = try lib.alloc.alloc([]const u8, rest.len + 2);
    out[0] = a;
    out[1] = b;
    @memcpy(out[2..], rest);
    return out;
}

const GroupPlan = struct { groups: []logic.Group, note: []const u8, degraded: bool = false };

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
        .degraded = true,
    };
    const groups = parseGroups(reply, files, max_commits) catch return .{
        .groups = try oneGroup(files, "chore: update working tree"),
        .note = "llm reply held no usable grouping (possibly truncated by the max_tokens grant); fell back to one generic commit",
        .degraded = true,
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
