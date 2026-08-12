//! Isolates one improve-self run in its own git worktree and branch, so the
//! staging/gate/promote loop never touches a file another process (a human
//! editor, another `clanker` command, another agent working the same repo)
//! has open in the shared working tree. Two improve-self runs already
//! serialize on state/improve.lock; nothing until now protected the tree
//! from everyone else, and running it live against a repo with another
//! active session caught it mid-edit repeatedly — a transient but real
//! build break every time, and once a real collision: both sides proposing
//! content for the same new file.
//!
//! Promotions merge back into the base branch at the ref level: no working
//! tree is touched anywhere, base branch's included, the same way a `git
//! push` advances a remote without touching the pusher's own checkout.
//! `git update-ref <ref> <new> <old>` is a compare-and-swap, so a concurrent
//! commit landing on the base branch between the read and the write just
//! fails the swap; mergeBack re-reads and retries a couple of times before
//! giving up and leaving the commit parked on the isolated branch for the
//! next promotion (or a human) to fold in.

const std = @import("std");
const log = @import("../util/log.zig");

pub const Worktree = struct {
    path: []const u8,
    branch: []const u8,
    base_branch: []const u8,

    pub fn deinit(self: *Worktree, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.branch);
        gpa.free(self.base_branch);
    }

    /// Removes the worktree and its branch. Must be called after chdir-ing
    /// back out of it: git refuses to remove a worktree that is anyone's cwd.
    pub fn cleanup(self: *const Worktree, gpa: std.mem.Allocator, io: std.Io) void {
        {
            const argv = [_][]const u8{ "git", "worktree", "remove", "--force", self.path };
            const res = std.process.run(gpa, io, .{ .argv = &argv }) catch return;
            defer gpa.free(res.stdout);
            defer gpa.free(res.stderr);
            const ok = switch (res.term) {
                .exited => |c| c == 0,
                else => false,
            };
            if (!ok) log.log(.warn, "git worktree remove {s} failed: {s}", .{ self.path, res.stderr });
        }
        // Best-effort: fails harmlessly (still merged in, or has commits
        // ahead) when mergeBack never fully landed the branch.
        {
            const argv = [_][]const u8{ "git", "branch", "-d", self.branch };
            const res = std.process.run(gpa, io, .{ .argv = &argv }) catch return;
            gpa.free(res.stdout);
            gpa.free(res.stderr);
        }
    }

    /// Folds the branch's current tip into `base_branch` without checking
    /// out or touching any working tree. Not fatal on failure (a real
    /// conflict, or losing the CAS race twice) — the commit stays reachable
    /// from the branch either way, so a failed merge-back never loses work,
    /// only delays it.
    pub fn mergeBack(self: *const Worktree, gpa: std.mem.Allocator, io: std.Io, message: []const u8) void {
        var attempt: u32 = 0;
        while (attempt < 3) : (attempt += 1) {
            const base_sha = revParse(gpa, io, self.base_branch) catch {
                log.log(.warn, "improve-self: could not read {s} to merge back", .{self.base_branch});
                return;
            };
            defer gpa.free(base_sha);
            const branch_sha = revParse(gpa, io, self.branch) catch {
                log.log(.warn, "improve-self: could not read {s} to merge back", .{self.branch});
                return;
            };
            defer gpa.free(branch_sha);

            if (std.mem.eql(u8, base_sha, branch_sha)) return; // already even

            const merge_base = mergeBaseOf(gpa, io, base_sha, branch_sha) catch {
                log.log(.warn, "improve-self: could not find a merge base for {s} and {s}", .{ self.base_branch, self.branch });
                return;
            };
            defer gpa.free(merge_base);

            if (std.mem.eql(u8, merge_base, base_sha)) {
                // Fast-forward: base hasn't moved since the branch was cut.
                if (updateRefCas(gpa, io, self.base_branch, branch_sha, base_sha) catch false) {
                    resyncLocalBranch(gpa, io, branch_sha);
                    return;
                }
                continue; // lost the CAS race; retry against the new tip
            }

            const tree = mergeTree(gpa, io, base_sha, branch_sha) catch {
                log.log(.warn, "improve-self: merging {s} into {s} conflicts; leaving it on the branch for manual merge", .{ self.branch, self.base_branch });
                return;
            };
            defer gpa.free(tree);
            const commit = commitTree(gpa, io, tree, base_sha, branch_sha, message) catch {
                log.log(.warn, "improve-self: could not create a merge commit for {s}", .{self.branch});
                return;
            };
            defer gpa.free(commit);
            if (updateRefCas(gpa, io, self.base_branch, commit, base_sha) catch false) {
                resyncLocalBranch(gpa, io, commit);
                return;
            }
            // Someone else moved base_branch between the read and the write;
            // loop and retry against its new tip.
        }
        log.log(.warn, "improve-self: {s} kept losing the race to merge into {s}; leaving it on the branch", .{ self.branch, self.base_branch });
    }

    /// After a successful merge-back, fast-forwards this worktree's own
    /// branch (and its checked-out files) to the commit that just landed on
    /// the base branch, so the two stay in lockstep.
    ///
    /// Without this the branch keeps accumulating its own parallel history
    /// every promotion, diverging a little further from the base branch
    /// each time even though its content already landed there under a
    /// different commit object — confirmed live: the first 7 promotions of
    /// a run merged cleanly, and every one after silently failed once
    /// accumulated drift produced a real conflict neither side could
    /// auto-resolve, with nothing surfacing the growing backlog short of
    /// reading raw logs for "conflicts" by hand.
    fn resyncLocalBranch(gpa: std.mem.Allocator, io: std.Io, new_sha: []const u8) void {
        const argv = [_][]const u8{ "git", "reset", "--hard", new_sha };
        const res = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| {
            log.log(.warn, "improve-self: could not resync the isolated branch after merge-back: {s}", .{@errorName(err)});
            return;
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        const ok = switch (res.term) {
            .exited => |c| c == 0,
            else => false,
        };
        if (!ok) log.log(.warn, "improve-self: git reset --hard after merge-back failed: {s}", .{res.stderr});
    }
};

/// Creates a worktree on a fresh branch cut from `base_branch`'s current
/// tip. Must be called before any chdir into the result: `git worktree add`
/// targets the repo the caller's cwd is already in.
pub fn create(gpa: std.mem.Allocator, io: std.Io, id: []const u8) !Worktree {
    const base_branch = currentBranch(gpa, io) catch try gpa.dupe(u8, "main");
    errdefer gpa.free(base_branch);

    const branch = try std.fmt.allocPrint(gpa, "clanker/improve-self-{s}", .{id});
    errdefer gpa.free(branch);

    // Deliberately outside state/: a worktree under state/ would contain its
    // own state directory inside the runtime state tree. Keeping worktrees in
    // a dedicated ignored directory also lets linkSharedState expose only the
    // few runtime files an isolated run needs.
    const path = try std.fmt.allocPrint(gpa, ".clanker-worktrees/{s}", .{id});
    errdefer gpa.free(path);

    std.Io.Dir.cwd().createDirPath(io, ".clanker-worktrees") catch {};

    const argv = [_][]const u8{ "git", "worktree", "add", "-b", branch, path, base_branch };
    const res = std.process.run(gpa, io, .{ .argv = &argv }) catch return error.WorktreeCreateFailed;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        log.log(.warn, "git worktree add failed: {s}", .{res.stderr});
        return error.WorktreeCreateFailed;
    }

    linkSharedState(gpa, io, path) catch |err|
        log.log(.warn, "improve-self: could not link state/.env/config.local.json into the worktree: {s}", .{@errorName(err)});

    return .{ .path = path, .branch = branch, .base_branch = base_branch };
}

/// Symlinks the runtime paths a fresh worktree checkout doesn't get on its
/// own — they're gitignored, so `git worktree add` never populates them.
/// .env and config.local.json carry the API keys and local overrides
/// nothing else provides. state/improvements.jsonl and state/history/ are
/// the cross-run memory (the dedup log, the revert snapshots) and have to
/// be the same files the main tree uses, or every isolated run starts fresh
/// with no memory of earlier ones.
///
/// state/ itself is deliberately NOT a symlink, and state/staging/ is
/// deliberately not linked at all: patch_apply and friends are sandboxed to
/// fs_prefixes ["state/staging"], and that check walks the path from the
/// root with symlinks left unresolved specifically so one can't be used to
/// step outside the sandbox — a symlinked `state` made every write under
/// state/staging/ look like exactly that and get refused. state/ is a real
/// directory local to the worktree; only the two entries below are linked
/// back in, as leaves the sandboxed tools never traverse through.
fn linkSharedState(gpa: std.mem.Allocator, io: std.Io, worktree_path: []const u8) !void {
    const root = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(root);

    for ([_][]const u8{ ".env", "config.local.toml" }) |name| {
        std.Io.Dir.cwd().access(io, name, .{}) catch continue; // nothing to link
        const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, name });
        defer gpa.free(target);
        const link_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ worktree_path, name });
        defer gpa.free(link_path);
        std.Io.Dir.cwd().symLink(io, target, link_path, .{}) catch |err|
            log.log(.warn, "improve-self: could not link {s} into the worktree: {s}", .{ name, @errorName(err) });
    }

    const state_dir = try std.fmt.allocPrint(gpa, "{s}/state", .{worktree_path});
    defer gpa.free(state_dir);
    try std.Io.Dir.cwd().createDirPath(io, state_dir);

    for ([_][]const u8{ "state/improvements.jsonl", "state/history", "state/learnings.md", "state/autolearn.jsonl" }) |name| {
        std.Io.Dir.cwd().access(io, name, .{}) catch continue; // nothing to link
        const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, name });
        defer gpa.free(target);
        const link_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ worktree_path, name });
        defer gpa.free(link_path);
        std.Io.Dir.cwd().symLink(io, target, link_path, .{}) catch |err|
            log.log(.warn, "improve-self: could not link {s} into the worktree: {s}", .{ name, @errorName(err) });
    }
}

fn run1(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
    const res = try std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) });
    defer gpa.free(res.stderr);
    const ok = switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        gpa.free(res.stdout);
        return error.CommandFailed;
    }
    const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
    if (trimmed.len == res.stdout.len) return res.stdout;
    const out = try gpa.dupe(u8, trimmed);
    gpa.free(res.stdout);
    return out;
}

fn currentBranch(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    return run1(gpa, io, &.{ "git", "symbolic-ref", "--short", "HEAD" });
}

fn revParse(gpa: std.mem.Allocator, io: std.Io, refname: []const u8) ![]u8 {
    return run1(gpa, io, &.{ "git", "rev-parse", refname });
}

fn mergeBaseOf(gpa: std.mem.Allocator, io: std.Io, a: []const u8, b: []const u8) ![]u8 {
    return run1(gpa, io, &.{ "git", "merge-base", a, b });
}

/// Computes the merge without touching any working tree or the index; the
/// returned tree sha is `null` semantically on conflict (surfaced as
/// error.CommandFailed by run1, which the caller treats as "can't merge").
fn mergeTree(gpa: std.mem.Allocator, io: std.Io, ours: []const u8, theirs: []const u8) ![]u8 {
    return run1(gpa, io, &.{ "git", "merge-tree", "--write-tree", "--no-messages", ours, theirs });
}

fn commitTree(gpa: std.mem.Allocator, io: std.Io, tree: []const u8, parent1: []const u8, parent2: []const u8, message: []const u8) ![]u8 {
    return run1(gpa, io, &.{ "git", "commit-tree", tree, "-p", parent1, "-p", parent2, "-m", message });
}

/// `git update-ref`'s three-argument form is itself the compare-and-swap:
/// it fails if the ref's current value isn't `old`, atomically.
fn updateRefCas(gpa: std.mem.Allocator, io: std.Io, branch: []const u8, new_sha: []const u8, old_sha: []const u8) !bool {
    const full_ref = try std.fmt.allocPrint(gpa, "refs/heads/{s}", .{branch});
    defer gpa.free(full_ref);
    const argv = [_][]const u8{ "git", "update-ref", full_ref, new_sha, old_sha };
    const res = try std.process.run(gpa, io, .{ .argv = &argv });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    return switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
}
