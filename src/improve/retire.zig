//! When an isolated run's worktree stops being worth keeping, and who decides.
//!
//! `clanker run --worktree` keeps its worktree and branch on purpose: the
//! commits are the deliverable, and the run ends long before anyone has looked
//! at them. So cleanup cannot be tied to the run finishing, and it cannot be
//! tied to age either -- an old worktree holding unmerged commits is exactly
//! the one not to delete.
//!
//! What it is tied to is the goal's own lifecycle. `state/goals.json` already
//! carries `archived` and `abandoned`, and those two mean the same thing for
//! this purpose: nobody is coming back for the tree. Runs are registered here
//! against the goal that steered them (`state/worktrees.json`), and
//! `reconcile` retires the ones whose goal has reached one of those states.
//!
//! Unmerged commits are never deleted, whichever state the goal is in.
//! `reconcile` reports them and moves on, the same rule `Worktree.cleanup`
//! already applies to improve-self: `--force` on the worktree removal only
//! ever follows a proven-merged check, so the force flag disposes of a dirty
//! working tree, never of history.
//!
//! Reconciliation rather than a hook on the status write, because
//! `state/goals.json` has more than one writer: the web UI's PATCH and the
//! `goal_update` guest (board, run-completion, loop outcome). A wasm tool
//! cannot run `git worktree remove` at all. Reading the current state and
//! acting on the difference works for every writer, including a status
//! changed by hand in an editor, and is safe to run twice.

const std = @import("std");
const log = @import("../util/log.zig");
const atomic_write = @import("../util/atomic_write.zig");
const ensure_dir = @import("../util/ensure_dir.zig");
const test_env = @import("../util/test_env.zig");

pub const registry_path = "state/worktrees.json";
const goals_path = "state/goals.json";

/// The container `createOn` puts worktrees in, relative to the checkout.
pub const container = ".clanker-worktrees";

/// One isolated run's worktree, as recorded when it was created.
///
/// `base_branch` is here because "merged" is only meaningful against something:
/// retirement asks whether every commit on `branch` is already an ancestor of
/// the branch it was cut from. Storing it avoids guessing "main" later, which
/// would strand work cut from anything else.
pub const Entry = struct {
    path: []const u8,
    branch: []const u8,
    base_branch: []const u8,
    /// The goal this run was steering, or "" for a run started without one.
    /// Empty is not a defect: `clanker run --worktree "..."` with no goal is a
    /// legitimate call, and its worktree simply has no lifecycle to follow.
    /// `reconcile` leaves those alone and reports them as unlinked, so the
    /// janitor can offer them rather than this function deleting them on a
    /// rule nobody stated.
    goal_id: []const u8 = "",
    created: i64 = 0,
};

/// Only the two fields retirement depends on, so this module does not have an
/// opinion on the goal schema and `ignore_unknown_fields` carries the rest.
const GoalStatus = struct {
    id: []const u8,
    status: []const u8 = "active",
};

/// The two statuses that mean nobody is coming back for the worktree.
/// `done` and `review` deliberately do NOT: those are the states where someone
/// is about to read the diff, which is the moment the tree is most useful.
fn statusRetires(status: []const u8) bool {
    return std.mem.eql(u8, status, "archived") or std.mem.eql(u8, status, "abandoned");
}

/// The registry as it stands. A missing file is a registry with no rows, which
/// is what a first run has; every other failure (unreadable, past the cap, not
/// JSON) is returned as the error it is, so a caller that rewrites the file
/// can refuse instead of writing an empty registry over rows it never read.
/// Both used to answer `&.{}`, and `register`'s
/// read-modify-write plus `reconcile`'s rewrite each replaced a corrupt or
/// momentarily-unreadable registry with a one-row file: every other
/// worktree's row gone, with the loss reported as nothing at all.
pub fn read(io: std.Io, dir: std.Io.Dir, arena: std.mem.Allocator) ![]Entry {
    const raw = dir.readFileAlloc(io, registry_path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky([]Entry, arena, raw, .{ .ignore_unknown_fields = true });
}

/// `read` for the callers that only render, where a registry that cannot be
/// read is no rows plus a line naming the file, not a wrong answer.
fn readBestEffort(io: std.Io, dir: std.Io.Dir, arena: std.mem.Allocator) []Entry {
    return read(io, dir, arena) catch |err| {
        log.log(.warn, "could not read {s} ({s}); reporting no worktrees", .{ registry_path, @errorName(err) });
        return &.{};
    };
}

fn write(io: std.Io, dir: std.Io.Dir, arena: std.mem.Allocator, entries: []const Entry) !void {
    // `state/` may be a symlink into the checkout for an isolated run, and
    // createDirPath fails NotDir on one; ensureDir is the form that tolerates it.
    try ensure_dir.ensureDir(dir, io, "state");
    var enc: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(entries, .{}, &enc.writer);
    try atomic_write.writeFile(io, dir, registry_path, enc.written());
}

/// Records a worktree so `reconcile` can find it later. Best-effort: a run
/// whose registration fails still works, it just leaves an unlinked worktree
/// for the janitor rather than one that retires on its own.
pub fn register(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, entry: Entry) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The write below is read-modify-write over every row, so a failed read is
    // not "there was nothing registered": it would drop every other worktree's
    // row. Refuse, and say the row is unregistered.
    const existing = read(io, dir, arena) catch |err| return log.log(.warn, "worktree {s} could not be recorded: {s} could not be read ({s}), and writing over it would drop the rows it holds", .{ entry.path, registry_path, @errorName(err) });
    var list: std.ArrayList(Entry) = .empty;
    for (existing) |e| {
        // Re-registering a path replaces it rather than appending: the ids are
        // timestamps, but a re-run against a reused path should not leave two
        // rows disagreeing about which goal owns it.
        if (std.mem.eql(u8, e.path, entry.path)) continue;
        list.append(arena, e) catch |err| return log.log(.warn, "worktree {s} could not be recorded in {s}: {s} (it will show up as unlinked)", .{ entry.path, registry_path, @errorName(err) });
    }
    list.append(arena, entry) catch |err|
        return log.log(.warn, "worktree {s} could not be recorded in {s}: {s} (it will show up as unlinked)", .{ entry.path, registry_path, @errorName(err) });
    write(io, dir, arena, list.items) catch |err|
        log.log(.warn, "worktree {s} could not be recorded in {s}: {s} (it will show up as unlinked)", .{ entry.path, registry_path, @errorName(err) });
}

/// What one `reconcile` pass found. Counts rather than lists because both
/// callers (the end-of-run notice and the janitor) report a summary; the
/// per-worktree detail goes to the log as it happens.
pub const Outcome = struct {
    /// Retired and removed, worktree and branch.
    removed: usize = 0,
    /// Goal is archived/abandoned but the branch still holds commits the base
    /// does not. Kept, and named in the log.
    kept_unmerged: usize = 0,
    /// Registered, goal still live. Nothing to do yet.
    live: usize = 0,
    /// Registered against no goal, so no lifecycle to follow.
    unlinked: usize = 0,
    /// Registered but gone from disk; the row is dropped.
    stale_rows: usize = 0,

    /// Whether a `.retired = false` pass found anything a `true` pass would act
    /// on, i.e. whether it is worth telling the operator to run the janitor.
    pub fn actionable(self: Outcome) usize {
        return self.removed + self.kept_unmerged;
    }
};

fn gitOk(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const res = std.process.run(gpa, io, .{ .argv = argv }) catch return false;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    return switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// A ref name is safe to hand `git` as an argument: non-empty, no leading
/// `-` (git would read it as a flag, so `--force` in a stored row would turn
/// `branch -d` into something else), and no whitespace, control byte, or the
/// ref-spellings git itself refuses (`..`, leading/trailing `/`, `@{`).
fn validBranchName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (name[0] == '-' or name[0] == '/' or name[name.len - 1] == '/') return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOf(u8, name, "@{") != null) return false;
    for (name) |c| {
        if (c <= 0x20 or c == 0x7f) return false;
    }
    return true;
}

/// True when every commit on `branch` is already an ancestor of `base`, which
/// is what makes removing the branch lossless. `--is-ancestor` answers exactly
/// that and says so in its exit code.
///
/// The registry is `state/worktrees.json`, inside the granted `fs_prefixes`
/// of the ordinary file tools, so both ref names are guest-writable and the
/// check is only meaningful when the two are distinct: with `branch ==
/// base_branch` `--is-ancestor` is trivially true for any ref that exists
/// (including the base branch itself), which is exactly how the check that
/// protects unmerged commits gets talked out of the room.
fn branchMerged(gpa: std.mem.Allocator, io: std.Io, branch: []const u8, base: []const u8) bool {
    if (!validBranchName(branch) or !validBranchName(base)) return false;
    if (std.mem.eql(u8, branch, base)) return false;
    return gitOk(gpa, io, &.{ "git", "merge-base", "--is-ancestor", branch, base });
}

/// Retires the worktrees whose goal has been archived or abandoned.
///
/// `apply = false` changes nothing and only counts, which is what the
/// end-of-run notice and `clanker janitor` (without `--yes`) use. The registry
/// itself is still rewritten in that case when rows are stale, since dropping
/// a row for a directory that no longer exists is bookkeeping, not deletion.
pub fn reconcile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, apply: bool) Outcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A registry that cannot be read is not one with no rows: the rewrite at
    // the end would replace every row it holds with a partial one. Report
    // nothing retired and leave the file alone.
    const entries = read(io, dir, arena) catch |err| {
        log.log(.warn, "could not read {s} ({s}); no worktree was retired and the registry was left untouched", .{ registry_path, @errorName(err) });
        return .{};
    };
    if (entries.len == 0) return .{};

    var statuses: std.StringHashMapUnmanaged([]const u8) = .empty;
    if (dir.readFileAlloc(io, goals_path, arena, .limited(1 << 20)) catch null) |raw| {
        if (std.json.parseFromSliceLeaky([]GoalStatus, arena, raw, .{ .ignore_unknown_fields = true }) catch null) |goals| {
            for (goals) |g| statuses.put(arena, g.id, g.status) catch {};
        }
    }

    var out: Outcome = .{};
    var kept: std.ArrayList(Entry) = .empty;
    // A row that fails to make it into `kept` would be dropped by the rewrite
    // below, de-registering a worktree whose commits are still the deliverable.
    // The registry is left exactly as it was instead.
    var keep_failed = false;
    for (entries) |e| {
        // Gone from disk: someone removed it by hand, which is allowed and
        // needs no complaint, only the row dropped.
        dir.access(io, e.path, .{}) catch {
            out.stale_rows += 1;
            continue;
        };
        if (e.goal_id.len == 0) {
            out.unlinked += 1;
            kept.append(arena, e) catch {
                keep_failed = true;
            };
            continue;
        }
        // A goal that is gone from goals.json entirely is treated as live, not
        // as retired. Deleting a goal row is not a statement about the commits
        // its run produced, and guessing the other way loses them.
        const status = statuses.get(e.goal_id) orelse {
            out.live += 1;
            kept.append(arena, e) catch {
                keep_failed = true;
            };
            continue;
        };
        if (!statusRetires(status)) {
            out.live += 1;
            kept.append(arena, e) catch {
                keep_failed = true;
            };
            continue;
        }
        if (!branchMerged(gpa, io, e.branch, e.base_branch)) {
            out.kept_unmerged += 1;
            log.log(.warn, "worktree {s} (goal {s}, {s}) still has commits {s} does not: keeping it and branch {s}", .{ e.path, e.goal_id, status, e.base_branch, e.branch });
            kept.append(arena, e) catch {
                keep_failed = true;
            };
            continue;
        }
        if (!apply) {
            out.removed += 1;
            kept.append(arena, e) catch {
                keep_failed = true;
            };
            continue;
        }
        if (!gitOk(gpa, io, &.{ "git", "worktree", "remove", "--force", e.path })) {
            log.log(.warn, "could not remove worktree {s}; leaving it registered", .{e.path});
            kept.append(arena, e) catch {
                keep_failed = true;
            };
            continue;
        }
        // -d, not -D: the merged check above already passed, so a refusal here
        // would mean the two disagree, and git's answer is the one to trust.
        _ = gitOk(gpa, io, &.{ "git", "branch", "-d", e.branch });
        out.removed += 1;
        log.log(.info, "retired worktree {s} and branch {s} (goal {s} is {s}, merged into {s})", .{ e.path, e.branch, e.goal_id, status, e.base_branch });
    }

    if (keep_failed) {
        log.log(.warn, "could not hold every worktree row in memory; leaving {s} untouched so no live worktree is de-registered", .{registry_path});
    } else if (kept.items.len != entries.len) {
        write(io, dir, arena, kept.items) catch |err|
            log.log(.warn, "could not rewrite {s}: {s}", .{ registry_path, @errorName(err) });
    }

    return out;
}

/// Directories in the container that no registry row claims.
///
/// Reported, never removed, and that asymmetry is deliberate. Three different
/// things land here and only one of them is litter: a `run --worktree` that
/// died before it could register, an improve-self worktree that is *in use
/// right now* (the loop creates its worktrees in this same container and does
/// not use this registry at all), and a worktree a human made by hand. Nothing
/// on disk distinguishes them, and removing an improve run's tree mid-flight
/// would take out live work.
///
/// So the janitor prints the count and the paths and stops there. Someone who
/// knows which is which can run `git worktree remove`.
pub fn countUnregistered(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) usize {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d = dir.openDir(io, container, .{ .iterate = true }) catch return 0;
    defer d.close(io);

    const rows = readBestEffort(io, dir, arena);
    var n: usize = 0;
    var it = d.iterate();
    while (it.next(io) catch null) |ent| {
        if (ent.kind != .directory) continue;
        var claimed = false;
        for (rows) |r| {
            // Rows store the absolute path; compare on the final component,
            // which is the worktree id and unique within the container.
            const base = if (std.mem.findScalarLast(u8, r.path, '/')) |i| r.path[i + 1 ..] else r.path;
            if (std.mem.eql(u8, base, ent.name)) {
                claimed = true;
                break;
            }
        }
        if (!claimed) n += 1;
    }
    return n;
}

test "statusRetires covers archived and abandoned, and nothing a reviewer still needs" {
    try std.testing.expect(statusRetires("archived"));
    try std.testing.expect(statusRetires("abandoned"));
    // `review` and `done` are when someone is about to read the diff.
    try std.testing.expect(!statusRetires("review"));
    try std.testing.expect(!statusRetires("done"));
    try std.testing.expect(!statusRetires("active"));
    try std.testing.expect(!statusRetires(""));
}

test "validBranchName refuses what git would read as a flag or a bad ref" {
    try std.testing.expect(validBranchName("clanker/run-1"));
    try std.testing.expect(validBranchName("main"));
    try std.testing.expect(!validBranchName(""));
    try std.testing.expect(!validBranchName("--force"));
    try std.testing.expect(!validBranchName("-D"));
    try std.testing.expect(!validBranchName("a b"));
    try std.testing.expect(!validBranchName("a\nb"));
    try std.testing.expect(!validBranchName("a..b"));
    try std.testing.expect(!validBranchName("a@{0}"));
    try std.testing.expect(!validBranchName("/a"));
    try std.testing.expect(!validBranchName("a/"));
}

test "a registry that cannot be read is never rewritten over" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const arena = env.arena();

    register(std.testing.allocator, io, env.tmp.dir, .{
        .path = "/wt/1",
        .branch = "clanker/run-1",
        .base_branch = "main",
        .goal_id = "g1",
        .created = 1,
    });
    try std.testing.expectEqual(@as(usize, 1), (try read(io, env.tmp.dir, arena)).len);

    // A directory where the registry is: present, unreadable as a file, and
    // not the missing file that legitimately reads as no rows.
    try env.tmp.dir.deleteFile(io, registry_path);
    try env.tmp.dir.createDirPath(io, registry_path);
    try std.testing.expectError(error.IsDir, read(io, env.tmp.dir, arena));

    // Both read-modify-write paths refuse rather than replacing the rows they
    // could not read with their own view of an empty registry.
    register(std.testing.allocator, io, env.tmp.dir, .{
        .path = "/wt/2",
        .branch = "clanker/run-2",
        .base_branch = "main",
        .goal_id = "g2",
        .created = 2,
    });
    const out = reconcile(std.testing.allocator, io, env.tmp.dir, true);
    try std.testing.expectEqual(@as(usize, 0), out.actionable());

    // And a registry that will not parse is refused the same way, so a
    // half-written file is repaired by a human rather than overwritten.
    try env.tmp.dir.deleteTree(io, registry_path);
    try env.tmp.dir.writeFile(io, .{ .sub_path = registry_path, .data = "{not json" });
    try std.testing.expectError(error.UnexpectedToken, read(io, env.tmp.dir, arena));
    register(std.testing.allocator, io, env.tmp.dir, .{
        .path = "/wt/3",
        .branch = "clanker/run-3",
        .base_branch = "main",
        .goal_id = "g3",
        .created = 3,
    });
    const after = try env.tmp.dir.readFileAlloc(io, registry_path, arena, .limited(4096));
    try std.testing.expectEqualStrings("{not json", after);
}

test "register replaces a row for the same path instead of appending" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();

    const arena = env.arena();

    register(std.testing.allocator, io, env.tmp.dir, .{
        .path = "/wt/1",
        .branch = "clanker/run-1",
        .base_branch = "main",
        .goal_id = "g1",
        .created = 1,
    });
    register(std.testing.allocator, io, env.tmp.dir, .{
        .path = "/wt/2",
        .branch = "clanker/run-2",
        .base_branch = "main",
        .goal_id = "g2",
        .created = 2,
    });
    register(std.testing.allocator, io, env.tmp.dir, .{
        .path = "/wt/1",
        .branch = "clanker/run-1b",
        .base_branch = "main",
        .goal_id = "g3",
        .created = 3,
    });

    const rows = try read(io, env.tmp.dir, arena);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    // Order is preserved apart from the replaced row, which moves to the end.
    try std.testing.expectEqualStrings("/wt/2", rows[0].path);
    try std.testing.expectEqualStrings("/wt/1", rows[1].path);
    try std.testing.expectEqualStrings("g3", rows[1].goal_id);
}

test "reconcile classifies by goal status and drops rows whose worktree is gone" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();

    const arena = env.arena();

    // Four rows: a live goal, an unlinked run, a goal that is gone from the
    // file, and a row whose directory does not exist.
    try env.tmp.dir.createDirPath(io, "live");
    try env.tmp.dir.createDirPath(io, "none");
    try env.tmp.dir.createDirPath(io, "missing-goal");
    try ensure_dir.ensureDir(env.tmp.dir, io, "state");
    try env.tmp.dir.writeFile(io, .{ .sub_path = "state/goals.json", .data =
        \\[{"id":"g-live","status":"active"},{"id":"g-arch","status":"archived"}]
    });
    try env.tmp.dir.writeFile(io, .{ .sub_path = registry_path, .data =
        \\[{"path":"live","branch":"b1","base_branch":"main","goal_id":"g-live"},
        \\ {"path":"none","branch":"b2","base_branch":"main","goal_id":""},
        \\ {"path":"missing-goal","branch":"b3","base_branch":"main","goal_id":"g-deleted"},
        \\ {"path":"vanished","branch":"b4","base_branch":"main","goal_id":"g-arch"}]
    });

    const out = reconcile(std.testing.allocator, io, env.tmp.dir, false);
    // `live` is 2: the active goal, plus the row whose goal is gone from the
    // file. A deleted goal row says nothing about the commits its run
    // produced, and the other reading of it loses them.
    try std.testing.expectEqual(@as(usize, 2), out.live);
    try std.testing.expectEqual(@as(usize, 1), out.unlinked);
    try std.testing.expectEqual(@as(usize, 1), out.stale_rows);
    // Nothing here is retirable: the only archived goal is the row whose
    // directory is already gone.
    try std.testing.expectEqual(@as(usize, 0), out.removed);
    try std.testing.expectEqual(@as(usize, 0), out.kept_unmerged);
    try std.testing.expectEqual(@as(usize, 0), out.actionable());

    // The vanished row is dropped; the other three survive the rewrite.
    const rows = try read(io, env.tmp.dir, arena);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
}

test "reconcile never de-registers a live worktree when an allocation fails" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "live");
    try tmp.dir.createDirPath(io, "none");
    try tmp.dir.createDirPath(io, "missing-goal");
    try ensure_dir.ensureDir(tmp.dir, io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/goals.json", .data =
        \\[{"id":"g-live","status":"active"},{"id":"g-arch","status":"archived"}]
    });
    const registry =
        \\[{"path":"live","branch":"b1","base_branch":"main","goal_id":"g-live"},
        \\ {"path":"none","branch":"b2","base_branch":"main","goal_id":""},
        \\ {"path":"missing-goal","branch":"b3","base_branch":"main","goal_id":"g-deleted"},
        \\ {"path":"vanished","branch":"b4","base_branch":"main","goal_id":"g-arch"}]
    ;

    // Fail every allocation point in turn. Whichever one gives out, a row whose
    // directory is still on disk must survive: the rewrite is what would drop
    // it, and dropping it strands the commits the run produced.
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        try tmp.dir.writeFile(io, .{ .sub_path = registry_path, .data = registry });

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        _ = reconcile(failing.allocator(), io, tmp.dir, false);

        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        for ([_][]const u8{ "live", "none", "missing-goal" }) |path| {
            var found = false;
            for (try read(io, tmp.dir, arena_state.allocator())) |row|
                if (std.mem.eql(u8, row.path, path)) {
                    found = true;
                };
            if (!found) {
                std.debug.print("row '{s}' lost with fail_index={d}\n", .{ path, fail_index });
                return error.LiveWorktreeDeregistered;
            }
        }
    }
}
