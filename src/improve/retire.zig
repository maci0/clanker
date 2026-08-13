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
//! `state/goals.json` has more than one writer: the web UI's PATCH, the `goal`
//! wasm tool, and `setGoalStatusIf` when a run completes. A wasm tool cannot
//! run `git worktree remove` at all. Reading the current state and acting on
//! the difference works for every writer, including a status changed by hand in
//! an editor, and is safe to run twice.

const std = @import("std");
const log = @import("../util/log.zig");
const atomic_write = @import("../util/atomic_write.zig");
const ensuredir = @import("../util/ensuredir.zig");

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

pub fn read(io: std.Io, dir: std.Io.Dir, arena: std.mem.Allocator) []Entry {
    const raw = dir.readFileAlloc(io, registry_path, arena, .limited(1 << 20)) catch return &.{};
    return std.json.parseFromSliceLeaky([]Entry, arena, raw, .{ .ignore_unknown_fields = true }) catch &.{};
}

fn write(io: std.Io, dir: std.Io.Dir, arena: std.mem.Allocator, entries: []const Entry) !void {
    // `state/` may be a symlink into the checkout for an isolated run, and
    // createDirPath fails NotDir on one; ensureDir is the form that tolerates it.
    try ensuredir.ensureDir(dir, io, "state");
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

    var list: std.ArrayList(Entry) = .empty;
    for (read(io, dir, arena)) |e| {
        // Re-registering a path replaces it rather than appending: the ids are
        // timestamps, but a re-run against a reused path should not leave two
        // rows disagreeing about which goal owns it.
        if (std.mem.eql(u8, e.path, entry.path)) continue;
        list.append(arena, e) catch return;
    }
    list.append(arena, entry) catch return;
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

/// True when every commit on `branch` is already an ancestor of `base`, which
/// is what makes removing the branch lossless. `--is-ancestor` answers exactly
/// that and says so in its exit code.
fn branchMerged(gpa: std.mem.Allocator, io: std.Io, branch: []const u8, base: []const u8) bool {
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

    const entries = read(io, dir, arena);
    if (entries.len == 0) return .{};

    var statuses: std.StringHashMapUnmanaged([]const u8) = .empty;
    if (dir.readFileAlloc(io, goals_path, arena, .limited(1 << 20)) catch null) |raw| {
        if (std.json.parseFromSliceLeaky([]GoalStatus, arena, raw, .{ .ignore_unknown_fields = true }) catch null) |goals| {
            for (goals) |g| statuses.put(arena, g.id, g.status) catch {};
        }
    }

    var out: Outcome = .{};
    var kept: std.ArrayList(Entry) = .empty;
    for (entries) |e| {
        // Gone from disk: someone removed it by hand, which is allowed and
        // needs no complaint, only the row dropped.
        dir.access(io, e.path, .{}) catch {
            out.stale_rows += 1;
            continue;
        };
        if (e.goal_id.len == 0) {
            out.unlinked += 1;
            kept.append(arena, e) catch {};
            continue;
        }
        // A goal that is gone from goals.json entirely is treated as live, not
        // as retired. Deleting a goal row is not a statement about the commits
        // its run produced, and guessing the other way loses them.
        const status = statuses.get(e.goal_id) orelse {
            out.live += 1;
            kept.append(arena, e) catch {};
            continue;
        };
        if (!statusRetires(status)) {
            out.live += 1;
            kept.append(arena, e) catch {};
            continue;
        }
        if (!branchMerged(gpa, io, e.branch, e.base_branch)) {
            out.kept_unmerged += 1;
            log.log(.warn, "worktree {s} (goal {s}, {s}) still has commits {s} does not: keeping it and branch {s}", .{ e.path, e.goal_id, status, e.base_branch, e.branch });
            kept.append(arena, e) catch {};
            continue;
        }
        if (!apply) {
            out.removed += 1;
            kept.append(arena, e) catch {};
            continue;
        }
        if (!gitOk(gpa, io, &.{ "git", "worktree", "remove", "--force", e.path })) {
            log.log(.warn, "could not remove worktree {s}; leaving it registered", .{e.path});
            kept.append(arena, e) catch {};
            continue;
        }
        // -d, not -D: the merged check above already passed, so a refusal here
        // would mean the two disagree, and git's answer is the one to trust.
        _ = gitOk(gpa, io, &.{ "git", "branch", "-d", e.branch });
        out.removed += 1;
        log.log(.info, "retired worktree {s} and branch {s} (goal {s} is {s}, merged into {s})", .{ e.path, e.branch, e.goal_id, status, e.base_branch });
    }

    if (kept.items.len != entries.len)
        write(io, dir, arena, kept.items) catch |err|
            log.log(.warn, "could not rewrite {s}: {s}", .{ registry_path, @errorName(err) });

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

    const rows = read(io, dir, arena);
    var n: usize = 0;
    var it = d.iterate();
    while (it.next(io) catch null) |ent| {
        if (ent.kind != .directory) continue;
        var claimed = false;
        for (rows) |r| {
            // Rows store the absolute path; compare on the final component,
            // which is the worktree id and unique within the container.
            const base = if (std.mem.lastIndexOfScalar(u8, r.path, '/')) |i| r.path[i + 1 ..] else r.path;
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

test "register replaces a row for the same path instead of appending" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    register(std.testing.allocator, io, tmp.dir, .{
        .path = "/wt/1", .branch = "clanker/run-1", .base_branch = "main", .goal_id = "g1", .created = 1,
    });
    register(std.testing.allocator, io, tmp.dir, .{
        .path = "/wt/2", .branch = "clanker/run-2", .base_branch = "main", .goal_id = "g2", .created = 2,
    });
    register(std.testing.allocator, io, tmp.dir, .{
        .path = "/wt/1", .branch = "clanker/run-1b", .base_branch = "main", .goal_id = "g3", .created = 3,
    });

    const rows = read(io, tmp.dir, arena);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    // Order is preserved apart from the replaced row, which moves to the end.
    try std.testing.expectEqualStrings("/wt/2", rows[0].path);
    try std.testing.expectEqualStrings("/wt/1", rows[1].path);
    try std.testing.expectEqualStrings("g3", rows[1].goal_id);
}

test "reconcile classifies by goal status and drops rows whose worktree is gone" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Four rows: a live goal, an unlinked run, a goal that is gone from the
    // file, and a row whose directory does not exist.
    try tmp.dir.createDirPath(io, "live");
    try tmp.dir.createDirPath(io, "none");
    try tmp.dir.createDirPath(io, "missing-goal");
    try ensuredir.ensureDir(tmp.dir, io, "state");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/goals.json", .data =
        \\[{"id":"g-live","status":"active"},{"id":"g-arch","status":"archived"}]
    });
    try tmp.dir.writeFile(io, .{ .sub_path = registry_path, .data =
        \\[{"path":"live","branch":"b1","base_branch":"main","goal_id":"g-live"},
        \\ {"path":"none","branch":"b2","base_branch":"main","goal_id":""},
        \\ {"path":"missing-goal","branch":"b3","base_branch":"main","goal_id":"g-deleted"},
        \\ {"path":"vanished","branch":"b4","base_branch":"main","goal_id":"g-arch"}]
    });

    const out = reconcile(std.testing.allocator, io, tmp.dir, false);
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
    const rows = read(io, tmp.dir, arena);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
}
