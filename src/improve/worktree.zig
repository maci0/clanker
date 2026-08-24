//! Isolates one improve-self run in its own git worktree and branch, so the
//! staging/gate/promote loop never touches a file another process (a human
//! editor, another `clanker` command, another agent working the same repo)
//! has open in the shared working tree. Two improve-self runs already
//! serialize on state/improve.lock; nothing until now protected the tree
//! from everyone else, and running it live against a repo with another
//! active session caught it mid-edit repeatedly, a transient but real
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
const ensure_dir = @import("../util/ensure_dir.zig");
const atomic_write = @import("../util/atomic_write.zig");
/// For `shared_prefixes`: the list of untracked, checkout-wide paths is one
/// list, shared with the sandbox that routes them, so the links here and the
/// routing there cannot drift into disagreeing about what is shared.
const host = @import("../sandbox/host.zig");
/// For `prepareLinked`'s test and the `worktree_link_local_config` flag: the
/// hand-made-worktree path is judged by whether `Config.load` in the worktree
/// answers with the operator's provider, which is the defect it fixes.
const config = @import("../config.zig");

/// Absolute path to the cwd as a plain (non-sentinel) owned slice.
/// std.process.currentPathAlloc returns a [:0]u8 whose allocation is one byte
/// larger than its .len (the sentinel). Freeing that slice with gpa.free
/// loses the sentinel byte; in the debug allocator the shorter length can
/// land in a different size bucket and panic "Invalid free". Dupe into an
/// exactly-sized slice so the caller's gpa.free is correct.
fn currentPath(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const z = std.process.currentPathAlloc(io, gpa) catch return try gpa.dupe(u8, ".");
    defer gpa.free(z);
    return gpa.dupe(u8, z);
}

pub const Worktree = struct {
    path: []const u8,
    branch: []const u8,
    base_branch: []const u8,
    /// The commit this branch's un-merged work starts from: the base tip at
    /// creation, advanced to each landed merge commit afterwards. mergeBack
    /// pins `git merge-tree --merge-base` to it so only the branch's OWN
    /// commits count as its delta. Letting git compute the merge base
    /// instead resurrects history: when a human rewrites the base branch to
    /// drop promoted commits (observed three times in one afternoon), the
    /// computed base predates the rewrite and the next merge-back re-lands
    /// everything the human just removed.
    created_from: []const u8,
    /// Set to true by mergeBack when it successfully lands the branch's
    /// tip onto the base branch. cleanup uses this to decide whether to
    /// force-remove the worktree: an unmerged worktree is kept so the
    /// developer (or a later run) can inspect and land the stranded work
    /// manually.
    merged: bool = false,

    pub fn deinit(self: *Worktree, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.branch);
        gpa.free(self.base_branch);
        gpa.free(self.created_from);
    }

    /// Whether the branch holds commits the base branch does not, asked of git
    /// rather than inferred from `merged`.
    ///
    /// `merged` only ever becomes true inside `mergeBack`, whose sole caller is
    /// the promotion path, so it answers "did a promotion land?" and not "is
    /// there anything here to lose". Those differ in both directions: a run
    /// that promotes nothing never commits either, leaving a branch identical
    /// to its base that `cleanup` used to keep forever; and an agent that
    /// commits inside the worktree outside the promotion path strands real
    /// work that `merged` knows nothing about.
    ///
    /// Fails safe: an unreadable repository answers "yes, stranded", because
    /// keeping a worktree costs disk and deleting one can cost work.
    pub fn hasStrandedCommits(self: *const Worktree, gpa: std.mem.Allocator, io: std.Io) bool {
        const range = std.fmt.allocPrint(gpa, "{s}..{s}", .{ self.base_branch, self.branch }) catch return true;
        defer gpa.free(range);
        // `-C self.path` rather than the caller's cwd: cleanup runs after the
        // chdir back out of the worktree, and a later caller's cwd is not
        // guaranteed to be inside this repository at all.
        const argv = [_][]const u8{ "git", "-C", self.path, "rev-list", "--count", range };
        const res = std.process.run(gpa, io, .{ .argv = &argv }) catch return true;
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        switch (res.term) {
            .exited => |c| if (c != 0) return true,
            else => return true,
        }
        const count = std.fmt.parseInt(u32, std.mem.trim(u8, res.stdout, " \t\r\n"), 10) catch return true;
        return count > 0;
    }

    /// Removes the worktree and its branch. Must be called after chdir-ing
    /// back out of it: git refuses to remove a worktree that is anyone's cwd.
    /// A worktree is kept only when it still holds commits the base branch
    /// lacks, so the stranded work stays reachable (`git worktree list` shows
    /// it, `git log <branch>` has the commits).
    pub fn cleanup(self: *const Worktree, gpa: std.mem.Allocator, io: std.Io) void {
        // Not `if (!self.merged)`: a run that promoted nothing never called
        // mergeBack, so `merged` is false on a branch that is byte-identical
        // to its base. Keeping those accumulated 38 empty worktrees in four
        // days, each logging "for manual recovery" with nothing to recover.
        if (!self.merged and self.hasStrandedCommits(gpa, io)) {
            log.log(.warn, "improve-self: worktree {s} still holds commits {s} does not; keeping it and branch {s}. Land them with: git merge {s}", .{ self.path, self.base_branch, self.branch, self.branch });
            return;
        }
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
        // Either the branch merged back or it holds nothing the base lacks, so
        // -d (which refuses to delete unmerged branches) is safe and succeeds
        // in both cases. It stays -d rather than -D so that a race that lands
        // a commit between the check and here still refuses to drop it.
        {
            const argv = [_][]const u8{ "git", "branch", "-d", self.branch };
            const res = std.process.run(gpa, io, .{ .argv = &argv }) catch return;
            gpa.free(res.stdout);
            gpa.free(res.stderr);
        }
    }

    /// Folds the branch's current tip into `base_branch` without checking
    /// out or touching any working tree. Not fatal on failure (a real
    /// conflict, or losing the CAS race twice), the commit stays reachable
    /// from the branch either way, so a failed merge-back never loses work,
    /// only delays it.
    pub fn mergeBack(self: *Worktree, gpa: std.mem.Allocator, io: std.Io, message: []const u8) void {
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

            // Already even: nothing to fold in, which is the successful
            // outcome and not a failed merge. Returning without setting
            // `merged` left an end-of-run merge attempt unable to ever
            // reclaim a worktree whose run promoted nothing.
            if (std.mem.eql(u8, base_sha, branch_sha)) {
                self.merged = true;
                return;
            }

            const merge_base = mergeBaseOf(gpa, io, base_sha, branch_sha) catch {
                log.log(.warn, "improve-self: could not find a merge base for {s} and {s}", .{ self.base_branch, self.branch });
                return;
            };
            defer gpa.free(merge_base);

            if (std.mem.eql(u8, merge_base, base_sha)) {
                // Fast-forward: base hasn't moved since the branch was cut.
                if (updateRefCas(gpa, io, self.base_branch, branch_sha, base_sha) catch false) {
                    log.log(.info, "improve-self: fast-forwarded {s} to {s}", .{ self.base_branch, branch_sha });
                    self.afterLanded(gpa, io, branch_sha, base_sha);
                    self.merged = true;
                    return;
                }
                continue; // lost the CAS race; retry against the new tip
            }

            const tree = mergeTree(gpa, io, self.created_from, base_sha, branch_sha) catch {
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
                log.log(.info, "improve-self: merge commit {s} landed on {s} (merged {s})", .{ commit, self.base_branch, self.branch });
                self.afterLanded(gpa, io, commit, base_sha);
                self.merged = true;
                return;
            }
            // Someone else moved base_branch between the read and the write;
            // loop and retry against its new tip.
        }
        log.log(.warn, "improve-self: {s} kept losing the race to merge into {s}; leaving it on the branch", .{ self.branch, self.base_branch });
    }

    /// The bookkeeping every landed merge owes, in the one order that is safe.
    /// Both merge paths above (fast-forward and merge commit) go through here
    /// so the order cannot be right in one of them and wrong in the other.
    ///
    /// `resyncLocalBranch` FIRST, and `advanceCreatedFrom` only if it
    /// succeeded. `created_from` is an assertion about where the branch ref
    /// is, not a wish: it is the merge base the *next* promotion pins
    /// `mergeTree` to. Advancing it before the reset that moves the ref (the
    /// original order) meant a failed reset -- a locked index, a read-only
    /// worktree, a concurrent git operation, all of which `resyncLocalBranch`
    /// only warns about -- left the pin claiming the branch was at `landed`
    /// while the ref still sat at its pre-merge tip. The next `merge-tree`
    /// then computes the branch side as a diff *from* `landed`, which reads
    /// as a deletion of everything this merge folded in from the other side,
    /// and CASes that onto the base branch.
    ///
    /// Leaving the pin where it was is the safe direction: the next
    /// `merge-tree` recomputes from the older base, which over-reports the
    /// branch's delta (at worst a conflict a human resolves) rather than
    /// under-reporting it (silently deleting promoted work).
    fn afterLanded(self: *Worktree, gpa: std.mem.Allocator, io: std.Io, landed: []const u8, old_base_sha: []const u8) void {
        if (self.resyncLocalBranch(gpa, io, landed)) {
            self.advanceCreatedFrom(gpa, landed);
        } else {
            log.log(.warn, "improve-self: {s} could not be resynced to {s}, so its pinned merge base stays at {s}; the next merge-back re-computes the branch delta from there. Land it by hand with: git -C {s} reset --hard {s}", .{ self.branch, landed, self.created_from, self.path, landed });
        }
        self.resyncBaseCheckout(gpa, io, old_base_sha);
    }

    /// After a successful merge-back the branch ref is fast-forwarded to the
    /// landed commit (resyncLocalBranch below), so the branch's next delta
    /// starts there too: advance the pinned merge base with it, or the next
    /// merge would re-count (and re-land) work that is already on the base
    /// branch, including work a human removed from it in the meantime.
    ///
    /// Called only from `afterLanded`, and only once the resync it asserts
    /// has reported success. Never call it on its own.
    fn advanceCreatedFrom(self: *Worktree, gpa: std.mem.Allocator, landed: []const u8) void {
        const next = gpa.dupe(u8, landed) catch return; // keep the old pin on OOM
        gpa.free(self.created_from);
        self.created_from = next;
    }

    /// After a successful merge-back, fast-forwards this worktree's own
    /// branch ref to the commit that just landed on the base branch, so
    /// the two stay in lockstep.
    ///
    /// Without this the branch keeps accumulating its own parallel history
    /// every promotion, diverging a little further from the base branch
    /// each time even though its content already landed there under a
    /// different commit object, confirmed live: the first 7 promotions of
    /// a run merged cleanly, and every one after silently failed once
    /// accumulated drift produced a real conflict neither side could
    /// auto-resolve, with nothing surfacing the growing backlog short of
    /// reading raw logs for "conflicts" by hand.
    ///
    /// `git -C <worktree> reset --hard`: pinned to the worktree path so a
    /// caller whose cwd has drifted (chdir'd back to the main tree) can
    /// never reset the user's checkout, the concern that briefly moved
    /// this to a bare `git update-ref` on the branch ref. That variant kept
    /// the ref in lockstep but left the worktree's checked-out FILES at the
    /// pre-merge content, and those files are what the next iteration's
    /// context and staging copy from: proposals then build on a tree
    /// missing everything the merge just folded in, re-introducing on the
    /// next merge exactly what someone else had fixed. Both halves matter:
    /// ref moved AND files synced.
    ///
    /// Returns whether the reset landed. It used to return `void`, with both
    /// the spawn failure and a non-zero git exit demoted to a warning, while
    /// its caller had already advanced `created_from` on the assumption it
    /// worked -- see `afterLanded` for what that cost.
    fn resyncLocalBranch(self: *const Worktree, gpa: std.mem.Allocator, io: std.Io, new_sha: []const u8) bool {
        const argv = [_][]const u8{ "git", "-C", self.path, "reset", "--hard", new_sha };
        const res = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| {
            log.log(.warn, "improve-self: could not resync the isolated branch after merge-back: {s}", .{@errorName(err)});
            return false;
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        const ok = switch (res.term) {
            .exited => |c| c == 0,
            else => false,
        };
        if (!ok) log.log(.warn, "improve-self: git reset --hard after merge-back failed: {s}", .{res.stderr});
        return ok;
    }

    /// After the base branch's ref moves, the checkout that has it checked
    /// out — usually the one improve-self was invoked from — still holds the
    /// pre-promotion index and files, so `git status` there presents the
    /// promotion's exact inverse as a staged change. Committing that state
    /// as-is has already deleted promoted work from origin once (124d592e,
    /// report 2026-08-19-improve-self-merge-leaves-worktree-reverted).
    ///
    /// Resync it only when its index and files are both byte-identical to the
    /// pre-merge base commit, so real work-in-progress is never destroyed;
    /// otherwise name the checkout and warn against committing the inverse.
    /// The reset is deliberately bare (`reset --hard`, no sha): HEAD already
    /// points at the moved branch ref, and a no-argument reset can never move
    /// the ref itself, so a concurrent commit that advances the branch
    /// between the CAS and here is not rewound.
    fn resyncBaseCheckout(self: *const Worktree, gpa: std.mem.Allocator, io: std.Io, old_sha: []const u8) void {
        const listing = run1(gpa, io, &.{ "git", "-C", self.path, "worktree", "list", "--porcelain" }) catch return;
        defer gpa.free(listing);
        const checkout = checkoutOf(listing, self.base_branch) orelse return;
        if (std.mem.eql(u8, checkout, self.path)) return;
        if (!matchesCommit(gpa, io, checkout, old_sha)) {
            log.log(.warn, "improve-self: {s} has {s} checked out with its own local changes, so its files were left showing pre-promotion content. Do not commit that diff — it reverts the promotion. Once your own work is committed or stashed, run: git -C {s} reset --hard", .{ checkout, self.base_branch, checkout });
            return;
        }
        const argv = [_][]const u8{ "git", "-C", checkout, "reset", "--hard" };
        const res = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| {
            log.log(.warn, "improve-self: could not resync {s} after merge-back: {s}", .{ checkout, @errorName(err) });
            return;
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        const ok = switch (res.term) {
            .exited => |c| c == 0,
            else => false,
        };
        if (ok)
            log.log(.info, "improve-self: resynced {s} to the promoted {s}", .{ checkout, self.base_branch })
        else
            log.log(.warn, "improve-self: git reset --hard in {s} after merge-back failed: {s}", .{ checkout, res.stderr });
    }
};

/// Path of the checkout that has `branch` checked out, from
/// `git worktree list --porcelain` output. Pure so it is testable without a
/// repository. A branch can be checked out in at most one worktree; it may
/// also be checked out nowhere (a detached or bare invocation), which is null
/// rather than an error.
fn checkoutOf(porcelain: []const u8, branch: []const u8) ?[]const u8 {
    var path: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, porcelain, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) {
            path = line["worktree ".len..];
        } else if (std.mem.startsWith(u8, line, "branch refs/heads/")) {
            if (std.mem.eql(u8, line["branch refs/heads/".len..], branch)) return path;
        }
    }
    return null;
}

/// Whether `repo`'s index and working tree are both byte-identical to
/// `sha`'s tree. Untracked files are ignored on purpose: `reset --hard`
/// leaves them alone, so they are not at risk.
fn matchesCommit(gpa: std.mem.Allocator, io: std.Io, repo: []const u8, sha: []const u8) bool {
    return gitQuiet(gpa, io, &.{ "git", "-C", repo, "diff", "--cached", "--quiet", sha, "--" }) and
        gitQuiet(gpa, io, &.{ "git", "-C", repo, "diff", "--quiet", sha, "--" });
}

/// True only on a clean zero exit; any failure to run reads as "does not
/// match", which fails safe into the warn-and-leave-it path.
fn gitQuiet(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) bool {
    const res = std.process.run(gpa, io, .{ .argv = argv }) catch return false;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    return switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

/// Sanitized instance identity for a branch name, so two instances sharing one
/// checkout with distinct worktrees cannot generate the same branch (RFC 0001
/// hazard 3). Git branch names forbid spaces and most punctuation; everything
/// outside `[A-Za-z0-9_-]` folds to `-`. An empty id folds to "self".
pub fn branchInstanceTag(out: []u8, instance_id: []const u8) []const u8 {
    const src = if (instance_id.len == 0) "self" else instance_id;
    const n = @min(src.len, out.len);
    for (src[0..n], 0..) |c, i| {
        out[i] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '-';
    }
    return out[0..n];
}

test "branchInstanceTag folds disallowed chars and defaults empty" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("self", branchInstanceTag(&buf, ""));
    try std.testing.expectEqualStrings("clanker-robot", branchInstanceTag(&buf, "clanker-robot"));
    try std.testing.expectEqualStrings("a-b-c", branchInstanceTag(&buf, "a b:c"));
    try std.testing.expectEqualStrings("under_score", branchInstanceTag(&buf, "under_score"));
}

/// Creates a worktree on a fresh branch cut from `base_branch`'s current
/// tip. Must be called before any chdir into the result: `git worktree add`
/// targets the repo the caller's cwd is already in.
pub fn create(gpa: std.mem.Allocator, io: std.Io, id: []const u8) !Worktree {
    return createOn(gpa, io, id, "clanker/improve-self-", .improve);
}

/// How the worktree reaches the checkout's untracked, shared paths.
pub const Sharing = enum {
    /// improve-self: a real local `state/`, with the few entries the loop
    /// depends on linked or copied in one at a time (`linkSharedState`). Its
    /// staging directory has to be the run's own, and the copies are what keep
    /// a proposal's learnings from escaping before it is promoted.
    improve,
    /// A plain agent run: every untracked path is a symlink to the checkout's,
    /// so the run reads and writes the same state it would have without
    /// isolation (`linkCheckoutState`). Only git-tracked source is private to
    /// the worktree, which is the only thing isolation is for here.
    run,
};

/// `create` with the branch prefix and sharing mode chosen by the caller, so a
/// plain agent run gets a branch that reads as one (`clanker/run-<id>`) and the
/// checkout-wide state it expects, without changing what improve-self does.
pub fn createOn(gpa: std.mem.Allocator, io: std.Io, id: []const u8, branch_prefix: []const u8, sharing: Sharing) !Worktree {
    const base_branch = currentBranch(gpa, io) catch try gpa.dupe(u8, "main");
    errdefer gpa.free(base_branch);

    const branch = try std.fmt.allocPrint(gpa, "{s}{s}", .{ branch_prefix, id });
    errdefer gpa.free(branch);

    // The ref the worktree is cut from. An improve-self run must be cut from
    // the latest code, not the possibly-stale local branch tip: a local `main`
    // that has not yet merged origin's fixes would make the loop stage and
    // gate its proposals against pre-fix code even after a fix landed
    // remotely, so every capability eval fails for a reason already fixed on
    // the remote (the 2026-08-21 batch kept failing session_search because
    // its worktree was cut from a local main that predated PR #291). Prefer
    // `origin/<base_branch>` when that ref exists; fall back to the local
    // branch when there is no remote tracking ref or the run is a plain agent
    // run (.run), which is cut from the checkout's own working state.
    var origin_ref: ?[]u8 = null;
    defer if (origin_ref) |r| gpa.free(r);
    const base_ref: []const u8 = if (sharing == .improve) blk: {
        const r = try std.fmt.allocPrint(gpa, "origin/{s}", .{base_branch});
        if (refExists(gpa, io, r)) {
            origin_ref = r;
            break :blk r;
        }
        gpa.free(r);
        break :blk base_branch;
    } else base_branch;

    // Deliberately outside state/: a worktree under state/ would contain its
    // own state directory inside the runtime state tree. Keeping worktrees in
    // a dedicated ignored directory also lets linkSharedState expose only the
    // few runtime files an isolated run needs.
    //
    // Absolute, because the engine chdirs INTO the worktree for the whole
    // run: any later use of this path (resyncLocalBranch's `git -C`,
    // cleanup's `git worktree remove`) resolves from a cwd where the
    // relative form does not exist. Observed live: `git -C
    // '.clanker-worktrees/<id>'` failing with "No such file or directory"
    // from inside that very worktree, silently skipping the post-merge
    // resync.
    const cwd_path = try currentPath(gpa, io);
    defer gpa.free(cwd_path);
    const path = try std.fmt.allocPrint(gpa, "{s}/.clanker-worktrees/{s}", .{ cwd_path, id });
    errdefer gpa.free(path);

    std.Io.Dir.cwd().createDirPath(io, ".clanker-worktrees") catch {};

    const argv = [_][]const u8{ "git", "worktree", "add", "-b", branch, path, base_ref };
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

    switch (sharing) {
        .improve => linkSharedState(gpa, io, path) catch |err|
            log.log(.warn, "isolated run: could not link state/.env/config.local.toml into the worktree: {s}", .{@errorName(err)}),
        .run => linkCheckoutState(gpa, io, path) catch |err|
            log.log(.warn, "isolated run: could not link the checkout's shared paths into the worktree: {s}", .{@errorName(err)}),
    }

    // The fresh branch's tip IS the base commit the branch was cut at;
    // record it as the pinned merge base (see `created_from`).
    const created_from = revParse(gpa, io, branch) catch return error.WorktreeCreateFailed;
    errdefer gpa.free(created_from);

    return .{ .path = path, .branch = branch, .base_branch = base_branch, .created_from = created_from };
}

/// Points every untracked, checkout-wide path at the checkout's own copy, for a
/// plain agent run isolated in a worktree.
///
/// The rule: git-tracked files are the run's own (isolating those is the point);
/// everything git does not track belongs to the checkout and must be reachable
/// exactly as it would be without isolation. A run that gets a snapshot instead
/// is quietly crippled -- no goal to be steered by, no session to resume, its
/// notes and token accounting written somewhere nobody reads -- and every
/// symptom looks like a broken tool rather than a missing directory.
///
/// One symlink per entry, which works because the SANDBOX never traverses
/// these: `Sandbox.shared_root` resolves the same prefixes against the checkout
/// directly (see `shared_prefixes` in src/sandbox/host.zig), so safeJoinSecure's
/// no-follow walk never meets the link and its refusal to cross one stays
/// intact. The links are for the HOST half, the ~44 hardcoded relative
/// "state/..." paths in src/ that resolve against the process cwd; native I/O
/// follows links, so those reach the checkout with no call sites changed.
///
/// Both halves are needed and they are not redundant: without the links the
/// host writes a worktree-local state/ nobody reads, and without the routing
/// every sandboxed tool is denied the moment it touches a linked component.
///
/// `zig-out` and `.zig-cache` are untracked too and deliberately excluded, for
/// the write-collision reasons in linkSharedState below; guest wasm is pinned to
/// the harness's build instead (Registry.rebaseWasmPaths).
fn linkCheckoutState(gpa: std.mem.Allocator, io: std.Io, worktree_path: []const u8) !void {
    const root = try currentPath(gpa, io);
    defer gpa.free(root);

    try linkCheckoutStateAt(gpa, io, std.Io.Dir.cwd(), root, worktree_path);
}

fn linkCheckoutStateAt(
    gpa: std.mem.Allocator,
    io: std.Io,
    checkout: std.Io.Dir,
    root: []const u8,
    worktree_path: []const u8,
) !void {
    try provisionSharedDirectories(checkout, io);
    for (host.shared_prefixes) |name| {
        // `state/`, `.local/`, `.agents/`, and `.claude/` are directories the harness
        // creates into. They must be real in the checkout before the link is
        // made: otherwise a fresh checkout skips the link, a guest's first
        // write is routed to the checkout by Sandbox.shared_root, and native
        // session/run writes later create a private state/ in the worktree.
        // The two readers then disagree about the same run.
        // Optional files (.env and config.local.*) are not created merely to
        // make a worktree. Link them only when the checkout already has one.
        checkout.access(io, name, .{}) catch continue;
        const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, name });
        defer gpa.free(target);
        const link_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ worktree_path, name });
        defer gpa.free(link_path);
        const is_dir = sharedDirectory(name) or isDir(checkout, io, name);
        checkout.symLink(io, target, link_path, .{ .is_directory = is_dir }) catch |err| switch (err) {
            // Tracked, so `git worktree add` already checked it out and the
            // worktree's own copy is the right one to use.
            error.PathAlreadyExists => {},
            else => log.log(.warn, "isolated run: could not link {s} into the worktree: {s}", .{ name, @errorName(err) }),
        };
    }
}

/// Creates the checkout-wide directories before a run worktree points at them.
/// `state/` can itself be a symlink to durable shared storage, so this must
/// follow the final component rather than treating the link as `NotDir`.
fn provisionSharedDirectories(base: std.Io.Dir, io: std.Io) !void {
    for (host.shared_prefixes) |name| {
        if (sharedDirectory(name)) try ensure_dir.ensureDir(base, io, name);
    }
}

fn sharedDirectory(name: []const u8) bool {
    return std.mem.eql(u8, name, "state") or
        std.mem.eql(u8, name, ".local") or
        std.mem.eql(u8, name, ".agents") or
        std.mem.eql(u8, name, ".claude");
}

test "a branch holding no commits the base lacks is not stranded work" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    // A real repository: the question `hasStrandedCommits` answers is a git
    // one, and a stub would only re-assert the rev-list arguments back at us.
    try gitOk(gpa, io, root, &.{ "init", "-q", "-b", "main" });
    try gitOk(gpa, io, root, &.{ "config", "user.email", "t@example.invalid" });
    try gitOk(gpa, io, root, &.{ "config", "user.name", "test" });
    try tmp.dir.writeFile(io, .{ .sub_path = "seed.txt", .data = "seed\n" });
    try gitOk(gpa, io, root, &.{ "add", "seed.txt" });
    try gitOk(gpa, io, root, &.{ "commit", "-qm", "seed" });
    try gitOk(gpa, io, root, &.{ "branch", "topic" });

    var wt: Worktree = .{
        .path = root,
        .branch = "topic",
        .base_branch = "main",
        .created_from = "",
    };

    // Freshly cut: identical to the base, so there is nothing to recover and
    // the worktree must not be kept. This is the shape ~three quarters of a
    // four-day pile of leftover improve-self worktrees had.
    try std.testing.expect(!wt.hasStrandedCommits(gpa, io));

    // A commit the base does not have IS stranded work, and outlives the run
    // whether or not a promotion ever merged it.
    try tmp.dir.writeFile(io, .{ .sub_path = "topic.txt", .data = "work\n" });
    try gitOk(gpa, io, root, &.{ "add", "topic.txt" });
    try gitOk(gpa, io, root, &.{ "commit", "-qm", "stranded" });
    try gitOk(gpa, io, root, &.{ "branch", "-f", "topic", "HEAD" });
    try gitOk(gpa, io, root, &.{ "update-ref", "refs/heads/main", "HEAD~1" });
    try std.testing.expect(wt.hasStrandedCommits(gpa, io));

    // Once the base carries it, it is no longer stranded.
    try gitOk(gpa, io, root, &.{ "update-ref", "refs/heads/main", "topic" });
    try std.testing.expect(!wt.hasStrandedCommits(gpa, io));
}

test "checkoutOf finds the one worktree holding a branch" {
    const porcelain =
        "worktree /home/u/clanker\nHEAD 1111111111111111111111111111111111111111\nbranch refs/heads/main\n\n" ++
        "worktree /home/u/clanker/.clanker-worktrees/42\nHEAD 2222222222222222222222222222222222222222\nbranch refs/heads/clanker/improve-self-42\n\n" ++
        "worktree /home/u/scratch\nHEAD 3333333333333333333333333333333333333333\ndetached\n";
    try std.testing.expectEqualStrings("/home/u/clanker", checkoutOf(porcelain, "main").?);
    try std.testing.expectEqualStrings(
        "/home/u/clanker/.clanker-worktrees/42",
        checkoutOf(porcelain, "clanker/improve-self-42").?,
    );
    // A prefix of a held branch is not that branch, and a branch checked out
    // nowhere is null, not the detached entry.
    try std.testing.expect(checkoutOf(porcelain, "clanker/improve-self-4") == null);
    try std.testing.expect(checkoutOf(porcelain, "topic") == null);
}

test "mergeBack's resync reaches the invoking checkout only when it is clean" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    // A real primary checkout on main plus a linked worktree on the improve
    // branch: the question is what a ref move leaves behind in the checkout
    // that was NOT the one merging, and a stub cannot answer it.
    try gitOk(gpa, io, root, &.{ "init", "-q", "-b", "main" });
    try gitOk(gpa, io, root, &.{ "config", "user.email", "t@example.invalid" });
    try gitOk(gpa, io, root, &.{ "config", "user.name", "test" });
    try tmp.dir.writeFile(io, .{ .sub_path = "code.txt", .data = "before\n" });
    try gitOk(gpa, io, root, &.{ "add", "code.txt" });
    try gitOk(gpa, io, root, &.{ "commit", "-qm", "seed" });
    const old_sha = try run1(gpa, io, &.{ "git", "-C", root, "rev-parse", "HEAD" });
    defer gpa.free(old_sha);

    const wt_path = try std.fmt.allocPrint(gpa, "{s}/improve-wt", .{root});
    defer gpa.free(wt_path);
    try gitOk(gpa, io, root, &.{ "worktree", "add", "-q", "-b", "improve", wt_path });
    var wt_dir = try std.Io.Dir.cwd().openDir(io, wt_path, .{});
    defer wt_dir.close(io);
    try wt_dir.writeFile(io, .{ .sub_path = "code.txt", .data = "after\n" });
    try gitOk(gpa, io, wt_path, &.{ "commit", "-aqm", "promoted" });
    const new_sha = try run1(gpa, io, &.{ "git", "-C", wt_path, "rev-parse", "HEAD" });
    defer gpa.free(new_sha);

    var wt: Worktree = .{
        .path = wt_path,
        .branch = "improve",
        .base_branch = "main",
        .created_from = "",
    };

    // The fast-forward as mergeBack performs it: the shared ref moves, no
    // checkout is touched. The primary now shows the promotion's inverse.
    try gitOk(gpa, io, root, &.{ "update-ref", "refs/heads/main", new_sha });
    wt.resyncBaseCheckout(gpa, io, old_sha);
    const synced = try tmp.dir.readFileAlloc(io, "code.txt", gpa, .limited(1 << 10));
    defer gpa.free(synced);
    try std.testing.expectEqualStrings("after\n", synced);
    // -uno: the linked worktree lives inside the primary as an untracked
    // directory, which is layout noise; the claim is that no *tracked* file
    // disagrees with the moved ref any more.
    const clean = try run1(gpa, io, &.{ "git", "-C", root, "status", "--porcelain", "-uno" });
    defer gpa.free(clean);
    try std.testing.expectEqualStrings("", clean);

    // With real work in progress in the primary, the resync must refuse:
    // move the ref back and dirty the checkout, then resync again.
    try gitOk(gpa, io, root, &.{ "reset", "-q", "--hard", old_sha });
    try gitOk(gpa, io, root, &.{ "update-ref", "refs/heads/main", new_sha });
    try tmp.dir.writeFile(io, .{ .sub_path = "code.txt", .data = "operator work\n" });
    wt.resyncBaseCheckout(gpa, io, old_sha);
    const kept = try tmp.dir.readFileAlloc(io, "code.txt", gpa, .limited(1 << 10));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("operator work\n", kept);
}

test "a failed branch resync leaves the pinned merge base where it was" {
    // `created_from` is the merge base the NEXT promotion pins `merge-tree`
    // to, so it must never claim a branch position the ref did not reach.
    // The reset that moves the ref can fail (a locked index, a read-only
    // worktree, a concurrent git operation) and only warns, so the fault is
    // injected here by pointing the worktree at a path git cannot reset.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    try gitOk(gpa, io, root, &.{ "init", "-q", "-b", "main" });
    try gitOk(gpa, io, root, &.{ "config", "user.email", "t@example.invalid" });
    try gitOk(gpa, io, root, &.{ "config", "user.name", "test" });
    try tmp.dir.writeFile(io, .{ .sub_path = "code.txt", .data = "before\n" });
    try gitOk(gpa, io, root, &.{ "add", "code.txt" });
    try gitOk(gpa, io, root, &.{ "commit", "-qm", "seed" });
    const old_sha = try run1(gpa, io, &.{ "git", "-C", root, "rev-parse", "HEAD" });
    defer gpa.free(old_sha);

    const wt_path = try std.fmt.allocPrint(gpa, "{s}/improve-wt", .{root});
    defer gpa.free(wt_path);
    try gitOk(gpa, io, root, &.{ "worktree", "add", "-q", "-b", "improve", wt_path });
    var wt_dir = try std.Io.Dir.cwd().openDir(io, wt_path, .{});
    defer wt_dir.close(io);
    try wt_dir.writeFile(io, .{ .sub_path = "code.txt", .data = "after\n" });
    try gitOk(gpa, io, wt_path, &.{ "commit", "-aqm", "promoted" });
    const new_sha = try run1(gpa, io, &.{ "git", "-C", wt_path, "rev-parse", "HEAD" });
    defer gpa.free(new_sha);

    // The fault: a path git cannot chdir into, so `git -C <path> reset
    // --hard` exits non-zero however the index and the refs look. It has to
    // be a path that does not exist rather than a plain directory -- a
    // directory INSIDE the repository still resets it, since git discovers
    // the repo from the parent.
    const nowhere = try std.fmt.allocPrint(gpa, "{s}/absent-worktree", .{root});
    defer gpa.free(nowhere);

    {
        var wt: Worktree = .{
            .path = nowhere,
            .branch = "improve",
            .base_branch = "main",
            .created_from = try gpa.dupe(u8, old_sha),
        };
        defer gpa.free(wt.created_from);
        try std.testing.expect(!wt.resyncLocalBranch(gpa, io, new_sha));
        wt.afterLanded(gpa, io, new_sha, old_sha);
        // The pin must still name the pre-merge base. Advancing it here is
        // what made the next merge-tree read the branch side as a deletion
        // of everything this merge folded in.
        try std.testing.expectEqualStrings(old_sha, wt.created_from);
    }

    // Control, or the assertion above passes on a pin that never moves: with
    // a worktree git CAN reset, the resync succeeds and the pin advances.
    {
        var wt: Worktree = .{
            .path = wt_path,
            .branch = "improve",
            .base_branch = "main",
            .created_from = try gpa.dupe(u8, old_sha),
        };
        defer gpa.free(wt.created_from);
        try gitOk(gpa, io, root, &.{ "update-ref", "refs/heads/main", new_sha });
        wt.afterLanded(gpa, io, new_sha, old_sha);
        try std.testing.expectEqualStrings(new_sha, wt.created_from);
    }
}

test "refExists tells a present ref from a missing one" {
    // Regression for the stale worktree-base fix: `createOn` now cuts an
    // improve-self worktree from `origin/<base>` when that ref exists, so a
    // local `main` that has not yet merged a fix landed on origin no longer
    // makes the loop stage and gate proposals against pre-fix code. The
    // decision hinges on `refExists`, so it must answer a present ref true and
    // a missing one false, without erroring on an empty or unborn repo.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    try gitOk(gpa, io, root, &.{ "init", "-q", "-b", "main" });
    try gitOk(gpa, io, root, &.{ "config", "user.email", "t@example.invalid" });
    try gitOk(gpa, io, root, &.{ "config", "user.name", "test" });
    try tmp.dir.writeFile(io, .{ .sub_path = "code.txt", .data = "before\n" });
    try gitOk(gpa, io, root, &.{ "add", "code.txt" });
    try gitOk(gpa, io, root, &.{ "commit", "-qm", "seed" });

    // A branch named `origin/main` stands in for the fetched remote tracking
    // ref (creating a true `refs/remotes/origin/main` needs a remote config
    // that `git update-ref` does not require).
    try gitOk(gpa, io, root, &.{ "branch", "origin/main" });

    try std.testing.expect(refExists(gpa, io, "origin/main"));
    try std.testing.expect(refExists(gpa, io, "main"));
    try std.testing.expect(!refExists(gpa, io, "origin/nope"));
    try std.testing.expect(!refExists(gpa, io, "nope"));
}

/// Runs one git command in `repo` and fails the test unless it exits 0.
fn gitOk(gpa: std.mem.Allocator, io: std.Io, repo: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "-C", repo });
    try argv.appendSlice(gpa, args);
    const res = try std.process.run(gpa, io, .{ .argv = argv.items });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    switch (res.term) {
        .exited => |c| if (c != 0) {
            std.debug.print("git {s} failed: {s}\n", .{ args[0], res.stderr });
            return error.GitCommandFailed;
        },
        else => return error.GitCommandFailed,
    }
}

test "every shared directory is provisioned for native worktree I/O" {
    // `linkCheckoutState` creates these before linking them into a worktree.
    // Keep this list in lockstep with host.shared_prefixes: a directory routed
    // only by the sandbox recreates the fresh-checkout split this protects.
    const expected = [_][]const u8{ "state", ".local", ".agents", ".claude" };
    for (expected) |name| {
        try std.testing.expect(sharedDirectory(name));
        var found = false;
        for (host.shared_prefixes) |prefix| {
            if (std.mem.eql(u8, prefix, name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    for (host.shared_prefixes) |prefix| {
        if (sharedDirectory(prefix)) {
            var expected_here = false;
            for (expected) |name| {
                if (std.mem.eql(u8, name, prefix)) {
                    expected_here = true;
                    break;
                }
            }
            try std.testing.expect(expected_here);
        }
    }
}

test "shared worktree provisioning links a symlinked state directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "durable-state", .default_dir);
    try tmp.dir.symLink(io, "durable-state", "state", .{ .is_directory = true });
    try std.testing.expectError(error.NotDir, tmp.dir.createDirPath(io, "state"));
    try tmp.dir.createDir(io, "worktree", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "KEY=value\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "config.local.toml", .data = "[agent]\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const worktree_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/worktree", .{root_buf[0..root_len]});
    defer std.testing.allocator.free(worktree_path);

    try linkCheckoutStateAt(
        std.testing.allocator,
        io,
        tmp.dir,
        root_buf[0..root_len],
        worktree_path,
    );

    for ([_][]const u8{ "state", ".local", ".agents", ".claude" }) |name| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "worktree/{s}", .{name});
        defer std.testing.allocator.free(path);
        const st = try tmp.dir.statFile(io, path, .{});
        try std.testing.expectEqual(std.Io.File.Kind.directory, st.kind);
    }

    const env = try tmp.dir.readFileAlloc(io, "worktree/.env", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(env);
    try std.testing.expectEqualStrings("KEY=value\n", env);

    const local_config = try tmp.dir.readFileAlloc(io, "worktree/config.local.toml", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(local_config);
    try std.testing.expectEqualStrings("[agent]\n", local_config);
}

fn isDir(base: std.Io.Dir, io: std.Io, path: []const u8) bool {
    const st = base.statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

/// Symlinks the runtime paths a fresh worktree checkout doesn't get on its
/// own, they're gitignored, so `git worktree add` never populates them.
/// .env and config.local.toml carry the API keys and local overrides
/// nothing else provides. state/improvements.jsonl and state/history/ are
/// the cross-run memory (the dedup log, the revert snapshots) and have to
/// be the same files the main tree uses, or every isolated run starts fresh
/// with no memory of earlier ones.
///
/// state/ itself is deliberately NOT a symlink, and state/staging/ is
/// deliberately not linked at all: patch_apply and friends are sandboxed to
/// fs_prefixes ["state/staging"], and that check walks the path from the
/// root with symlinks left unresolved specifically so one can't be used to
/// step outside the sandbox, a symlinked `state` made every write under
/// state/staging/ look like exactly that and get refused. state/ is a real
/// directory local to the worktree; only the two entries below are linked
/// back in, as leaves the sandboxed tools never traverse through.
/// The two entries `linkSharedState` links back into a worktree's own `state/`.
/// Both are read only by the HOST (the engine's `History`), never traversed by
/// a sandboxed tool, which is what makes a link safe here and nowhere else
/// under `state/` -- see the long note inside `linkSharedState`.
///
/// One list, so the linking there and `clanker doctor`'s assertion that the
/// links are still links cannot drift into disagreeing about what is linked.
pub const shared_state_link_names = [_][]const u8{ "state/improvements.jsonl", "state/history" };

fn linkSharedState(gpa: std.mem.Allocator, io: std.Io, worktree_path: []const u8) !void {
    const root = try currentPath(gpa, io);
    defer gpa.free(root);

    // .zig-cache deliberately NOT linked: several sandbox tests place their
    // tmp roots at the literal path ".zig-cache/tmp/...", and the sandbox's
    // no-follow safeJoinSecure walk (correctly) refuses to traverse a
    // symlinked component -- a linked cache broke 3 tests in every worktree,
    // failing the baseline gate of every subsequent run (verified in a
    // scratch worktree; same collision as the staging-side attempt, which is
    // why staging shares the cache via --cache-dir args instead).
    // zig-out deliberately NOT linked (tried in ad47225's promotion): builds
    // WRITE into zig-out, so a linked one means the worktree's own baseline
    // `zig build`/`zig build tools` clobber the main tree's binaries through
    // the link -- including the clanker binary the main tree is actively
    // running -- and two trees installing into one zig-out concurrently made
    // the worktree's baseline gate flaky (observed live: baseline 2/3 in a
    // fresh worktree). The worktree builds its own zig-out once at run start;
    // staging already reuses the build cache via --cache-dir, so the link
    // bought nothing there anyway.
    for (local_config_names) |name| {
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

    // Runtime state stays empty in a fresh worktree (see the note below on why
    // it is neither linked nor copied), but the DIRECTORIES have to exist: the
    // writers here create a file inside them, not the path to them, so an
    // absent state/runs made every run-graph write fail ("graph write failed:
    // FileNotFound", once per isolated run). Empty is the intended starting
    // state; missing is just a write error.
    for ([_][]const u8{ "runs", "sessions" }) |leaf| {
        const dir = try std.fmt.allocPrint(gpa, "{s}/state/{s}", .{ worktree_path, leaf });
        defer gpa.free(dir);
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err|
            log.log(.warn, "isolated run: could not create state/{s} in the worktree: {s}", .{ leaf, @errorName(err) });
    }

    // The dividing line for everything under state/ is WHO reads the path.
    //
    // Symlinks work only for paths read by the HOST (native I/O follows
    // links): improvements.jsonl and history/ are read/written by the
    // engine's History, never by a sandboxed tool.
    //
    // That last clause is a requirement, not an observation, and it was once
    // false: `improve_history` was granted `fs_prefixes:
    // ["state/improvements.jsonl"]` and read the link itself, which
    // safeJoinSecure refused as a symlinked leaf. Because the guest reported
    // any read failure as an empty history, every improve run was told it had
    // never attempted anything. The tool now takes the ledger over
    // `ck_improve_history` (src/sandbox/host.zig) and has no fs grant at all.
    // Do not add a guest grant for anything in the list below; give it a host
    // channel instead. Every path a sandboxed
    // tool traverses is off-limits as a link, because safeJoinSecure's
    // no-follow walk (correctly) refuses symlinked components: linked
    // state/runs broke graph's write test in every worktree (baseline
    // gate 2/3, observed live), linked state/sessions breaks sessions
    // the same way, and a linked learnings.md/reasoning.jsonl leaf denies
    // the learnings/reasoning tools. Staged capability evals never catch
    // any of this because staging COPIES (dereferencing links); only the
    // worktree, where baseline/final gates run, has the links.
    //
    // Ensure host-side link targets exist before the access check: on a
    // fresh checkout state/history/ is absent and the symlink is silently
    // skipped, losing the cross-run dedup memory for the entire session.
    std.Io.Dir.cwd().createDirPath(io, "state/history") catch {};
    for (shared_state_link_names) |name| {
        std.Io.Dir.cwd().access(io, name, .{}) catch continue; // nothing to link
        const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, name });
        defer gpa.free(target);
        const link_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ worktree_path, name });
        defer gpa.free(link_path);
        std.Io.Dir.cwd().symLink(io, target, link_path, .{}) catch |err|
            log.log(.warn, "improve-self: could not link {s} into the worktree: {s}", .{ name, @errorName(err) });
    }

    // Sandbox-readable cross-run memory is COPIED instead: real files, so
    // the no-follow walk sees nothing to refuse. One-way by design -- a
    // run's own learnings stay isolated until promoted, the same isolation
    // rule as every other write. Runtime state (runs, sessions, stats,
    // reasoning traces, plugin toggles) is deliberately neither linked nor
    // copied: a fresh worktree legitimately starts empty and every tool
    // already answers "(nothing yet)" for that case.
    // Symlink directories that are read-only during an improve run: chain
    // pipelines and workflow templates. These are never written by improve-self
    // (the agent reads them via the chain/workflows tools), so a symlink is
    // safe and avoids duplicating potentially large directories.
    for ([_][]const u8{ "chains", "workflows" }) |name| {
        std.Io.Dir.cwd().access(io, name, .{}) catch continue;
        const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, name });
        defer gpa.free(target);
        const link_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ worktree_path, name });
        defer gpa.free(link_path);
        std.Io.Dir.cwd().symLink(io, target, link_path, .{ .is_directory = true }) catch |err| switch (err) {
            // Both directories are tracked, so `git worktree add` has already
            // checked them out and there is nothing to link: the worktree's own
            // copy is the same content at the same commit. Warning about it
            // meant two alarming lines at the head of every isolated run's
            // output for the one case that is entirely fine.
            error.PathAlreadyExists => {},
            else => log.log(.warn, "isolated run: could not link {s} into the worktree: {s}", .{ name, @errorName(err) }),
        };
    }

    for ([_][]const u8{ "state/learnings.md", "state/autolearn.jsonl", "state/plugin_config.json", "state/token_stats.jsonl", "state/reasoning.jsonl" }) |name| {
        // 16 MiB: autolearn's own log cap is 8 MiB (max_log_bytes,
        // src/agent/auto_learn.zig) and the trim triggers only past it, so a
        // 4 MiB read limit here didn't truncate -- readFileAlloc errors on
        // oversize and the catch skipped the copy entirely, silently
        // dropping the shared memory exactly when it had grown most useful.
        const data = std.Io.Dir.cwd().readFileAlloc(io, name, gpa, .limited(1 << 24)) catch continue;
        defer gpa.free(data);
        const dst = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ worktree_path, name });
        defer gpa.free(dst);
        // Owner-only: the copied files are the user's own shared memory
        // (learnings, autolearn events, token stats, reasoning traces), and a
        // default-mode copy would land world-readable inside the worktree.
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = data, .flags = .{ .permissions = atomic_write.private_file } }) catch |err|
            log.log(.warn, "improve-self: could not copy {s} into the worktree: {s}", .{ name, @errorName(err) });
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

/// Whether `refname` resolves (e.g. `origin/main` exists as a fetched remote
/// tracking ref). Used by `createOn` to cut an improve-self worktree from the
/// latest remote code instead of a possibly-stale local branch tip.
fn refExists(gpa: std.mem.Allocator, io: std.Io, refname: []const u8) bool {
    const argv = [_][]const u8{ "git", "rev-parse", "--verify", "--quiet", refname };
    const res = std.process.run(gpa, io, .{ .argv = &argv }) catch return false;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    return switch (res.term) {
        .exited => |c| c == 0,
        else => false,
    };
}

fn mergeBaseOf(gpa: std.mem.Allocator, io: std.Io, a: []const u8, b: []const u8) ![]u8 {
    return run1(gpa, io, &.{ "git", "merge-base", a, b });
}

/// Computes the merge without touching any working tree or the index; the
/// returned tree sha is `null` semantically on conflict (surfaced as
/// error.CommandFailed by run1, which the caller treats as "can't merge").
fn mergeTree(gpa: std.mem.Allocator, io: std.Io, base: []const u8, ours: []const u8, theirs: []const u8) ![]u8 {
    // Explicit --merge-base: the branch's delta is measured from the commit
    // it was actually cut at (Worktree.created_from), not from whatever
    // ancestor git can still find after a history rewrite of the base branch.
    const base_arg = try std.fmt.allocPrint(gpa, "--merge-base={s}", .{base});
    defer gpa.free(base_arg);
    return run1(gpa, io, &.{ "git", "merge-tree", "--write-tree", "--no-messages", base_arg, ours, theirs });
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

// ---------------------------------------------------------------------------
// Preparing a HAND-MADE worktree (`clanker worktree prepare`).
//
// Everything above prepares the worktrees clanker creates for itself. The
// repository rules make every agent session create its own with `git worktree
// add` instead, and that path had no preparation step at all: `git worktree
// add` checks out TRACKED files only, so a hand-made worktree has neither
// `.env` nor `config.local.toml` (both gitignored) and every verb there
// resolves the committed `config.toml` default with no key behind it -- see
// docs/reports/bugs/2026-08-22-hand-made-worktree-falls-back-to-committed-provider.md.
//
// The two names live in one list, shared with `linkSharedState` above, so the
// hand-made path and clanker's own cannot drift into linking different files.
// ---------------------------------------------------------------------------

/// The gitignored files that carry the operator's provider choice and its key.
/// Nothing else provides them, and `git worktree add` never will.
pub const local_config_names = [_][]const u8{ ".env", "config.local.toml" };

pub const PrepareOptions = struct {
    /// `agent.worktree_link_local_config`, read from the MAIN CHECKOUT's
    /// config rather than the worktree's: the worktree cannot yet see the
    /// operator's `config.local.toml`, which is the whole defect, so asking it
    /// would answer from the committed defaults every time.
    ///
    /// On by default. Off is for a checkout whose worktrees must not reach the
    /// main tree's credentials at all; `prepare` then reports each name as
    /// `skipped` rather than silently doing nothing.
    link_local_config: bool = true,
};

pub const LinkOutcome = enum {
    /// The link was created by this call.
    linked,
    /// A file (or link) of that name was already in the worktree; left alone.
    already_present,
    /// The main checkout has no such file, so there is nothing to link.
    absent_in_checkout,
    /// `agent.worktree_link_local_config = false`.
    skipped,
};

pub const LinkResult = struct {
    name: []const u8,
    outcome: LinkOutcome,
};

/// The main checkout a linked worktree's `.git` FILE points back at.
///
/// `git worktree add` writes `gitdir: <main>/.git/worktrees/<name>` into the
/// worktree's `.git`, so the main checkout is the text before `/.git/worktrees/`.
/// Returns null when the contents are not that shape: a normal checkout (where
/// `.git` is a directory and this is never read), a bare repo, or a submodule
/// pointer -- none of which have a main checkout to link from.
pub fn mainCheckoutFromGitFile(contents: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "gitdir:")) return null;
    const gitdir = std.mem.trim(u8, trimmed["gitdir:".len..], " \t\r\n");
    const marker = "/.git/worktrees/";
    const at = std.mem.findLast(u8, gitdir, marker) orelse return null;
    if (at == 0) return null;
    return gitdir[0..at];
}

/// Links the two gitignored local-config files from `main_checkout` into
/// `worktree_path`, and reports what happened to each.
///
/// Leaf symlinks, matching `linkSharedState`: both files are read by the HOST
/// (native I/O follows links) and `atomic_write.writeFile` resolves a leaf link
/// before renaming, so an edit made in the worktree lands in the main
/// checkout's file instead of detaching from it. Both names are gitignored, so
/// the links can never enter a commit.
pub fn prepareLinked(
    gpa: std.mem.Allocator,
    io: std.Io,
    main_checkout: []const u8,
    worktree_path: []const u8,
    opts: PrepareOptions,
) ![local_config_names.len]LinkResult {
    var out: [local_config_names.len]LinkResult = undefined;
    for (local_config_names, 0..) |name, i| {
        out[i] = .{ .name = name, .outcome = .skipped };
        if (!opts.link_local_config) continue;

        const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ main_checkout, name });
        defer gpa.free(target);
        const link_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ worktree_path, name });
        defer gpa.free(link_path);

        // Nothing to link is not a failure: a checkout with no `.env` (keys in
        // the environment instead) is an ordinary setup, and creating a
        // dangling link there would break every later read.
        std.Io.Dir.cwd().access(io, target, .{}) catch {
            out[i].outcome = .absent_in_checkout;
            continue;
        };

        std.Io.Dir.cwd().symLink(io, target, link_path, .{}) catch |err| switch (err) {
            // Never overwrite: the name may hold the worktree's own deliberate
            // copy, or the link this call already made on an earlier run.
            error.PathAlreadyExists => {
                out[i].outcome = .already_present;
                continue;
            },
            else => return err,
        };
        out[i].outcome = .linked;
    }
    return out;
}

/// The committed `config.toml` as this repository actually ships it: a
/// default_provider nobody has a key for, and an `[instance]` table. The
/// instance name matters to the test -- without one, `Config.load` persists a
/// generated name into `config.local.toml` (`persistInstanceName`) and the
/// worktree ends up with a file of that name before `prepare` ever runs.
const committed_config =
    \\default_provider = "moonshotai"
    \\
    \\[instance]
    \\name = "clanker"
    \\id = "main"
    \\
;

test "a hand-made worktree resolves the checkout's default_provider once prepared" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The main checkout: the committed default nobody has a key for, and the
    // operator's own choice beside it in the gitignored file.
    try tmp.dir.createDir(io, "main", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "main/config.toml", .data = committed_config });
    try tmp.dir.writeFile(io, .{ .sub_path = "main/config.local.toml", .data = "default_provider = \"deepseek\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main/.env", .data = "DEEPSEEK_API_KEY=sk-test\n" });

    // The worktree as `git worktree add` leaves it: tracked files only, plus
    // the `.git` file pointing back at the main checkout.
    try tmp.dir.createDir(io, "wt", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/config.toml", .data = committed_config });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    const gitfile = try std.fmt.allocPrint(gpa, "gitdir: {s}/main/.git/worktrees/wt\n", .{root});
    defer gpa.free(gitfile);
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/.git", .data = gitfile });

    // The defect, asserted before the fix runs: the worktree sees only the
    // committed default.
    {
        var wt_dir = try tmp.dir.openDir(io, "wt", .{});
        defer wt_dir.close(io);
        const before = try config.Config.load(io, arena, wt_dir, "config.toml", "config.local.toml");
        try std.testing.expectEqualStrings("moonshotai", before.default_provider);
    }

    // The `.git` file is the only thing naming the main checkout.
    const contents = try tmp.dir.readFileAlloc(io, "wt/.git", gpa, .limited(4096));
    defer gpa.free(contents);
    const main_checkout = mainCheckoutFromGitFile(contents) orelse
        return error.MainCheckoutNotFound;
    const expected_main = try std.fmt.allocPrint(gpa, "{s}/main", .{root});
    defer gpa.free(expected_main);
    try std.testing.expectEqualStrings(expected_main, main_checkout);

    const worktree_path = try std.fmt.allocPrint(gpa, "{s}/wt", .{root});
    defer gpa.free(worktree_path);
    const results = try prepareLinked(gpa, io, main_checkout, worktree_path, .{});
    for (results) |r| try std.testing.expectEqual(LinkOutcome.linked, r.outcome);

    // The point of the whole change: the same load now answers with the
    // operator's provider, read through the link.
    {
        var wt_dir = try tmp.dir.openDir(io, "wt", .{});
        defer wt_dir.close(io);
        const after = try config.Config.load(io, arena, wt_dir, "config.toml", "config.local.toml");
        try std.testing.expectEqualStrings("deepseek", after.default_provider);
    }

    const env = try tmp.dir.readFileAlloc(io, "wt/.env", gpa, .limited(128));
    defer gpa.free(env);
    try std.testing.expectEqualStrings("DEEPSEEK_API_KEY=sk-test\n", env);
}

test "preparing a worktree leaves an existing file alone and reports what is absent" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A main checkout with no .env at all, and a worktree that already has its
    // own config.local.toml.
    try tmp.dir.createDir(io, "main", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "main/config.local.toml", .data = "default_provider = \"deepseek\"\n" });
    try tmp.dir.createDir(io, "wt", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/config.local.toml", .data = "default_provider = \"zai\"\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const main_checkout = try std.fmt.allocPrint(gpa, "{s}/main", .{root});
    defer gpa.free(main_checkout);
    const worktree_path = try std.fmt.allocPrint(gpa, "{s}/wt", .{root});
    defer gpa.free(worktree_path);

    const results = try prepareLinked(gpa, io, main_checkout, worktree_path, .{});
    try std.testing.expectEqualStrings(".env", results[0].name);
    try std.testing.expectEqual(LinkOutcome.absent_in_checkout, results[0].outcome);
    try std.testing.expectEqualStrings("config.local.toml", results[1].name);
    try std.testing.expectEqual(LinkOutcome.already_present, results[1].outcome);

    // The worktree's own file must survive untouched.
    const kept = try tmp.dir.readFileAlloc(io, "wt/config.local.toml", gpa, .limited(128));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("default_provider = \"zai\"\n", kept);
}

test "worktree_link_local_config off leaves the worktree alone" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "main", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "main/.env", .data = "K=v\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main/config.local.toml", .data = "default_provider = \"deepseek\"\n" });
    try tmp.dir.createDir(io, "wt", .default_dir);

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const main_checkout = try std.fmt.allocPrint(gpa, "{s}/main", .{root});
    defer gpa.free(main_checkout);
    const worktree_path = try std.fmt.allocPrint(gpa, "{s}/wt", .{root});
    defer gpa.free(worktree_path);

    const results = try prepareLinked(gpa, io, main_checkout, worktree_path, .{ .link_local_config = false });
    for (results) |r| try std.testing.expectEqual(LinkOutcome.skipped, r.outcome);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "wt/.env", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "wt/config.local.toml", .{}));
}

test "a git file that names no worktree has no main checkout" {
    try std.testing.expect(mainCheckoutFromGitFile("ref: refs/heads/main\n") == null);
    try std.testing.expect(mainCheckoutFromGitFile("gitdir: /srv/repo.git\n") == null);
    try std.testing.expectEqualStrings(
        "/home/y/code/clanker",
        mainCheckoutFromGitFile("gitdir: /home/y/code/clanker/.git/worktrees/fix\n").?,
    );
}
