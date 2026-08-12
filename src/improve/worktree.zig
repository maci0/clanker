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
    }

    /// Removes the worktree and its branch. Must be called after chdir-ing
    /// back out of it: git refuses to remove a worktree that is anyone's cwd.
    /// When the branch was never merged back, the worktree and branch are
    /// kept so the stranded work remains reachable (`git worktree list`
    /// shows it, `git log <branch>` has the commits).
    pub fn cleanup(self: *const Worktree, gpa: std.mem.Allocator, io: std.Io) void {
        if (!self.merged) {
            log.log(.warn, "improve-self: worktree {s} was not merged; keeping it and branch {s} for manual recovery", .{ self.path, self.branch });
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
        // The branch was successfully merged, so -d (which refuses to
        // delete unmerged branches) is safe and will succeed.
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

            if (std.mem.eql(u8, base_sha, branch_sha)) return; // already even

            const merge_base = mergeBaseOf(gpa, io, base_sha, branch_sha) catch {
                log.log(.warn, "improve-self: could not find a merge base for {s} and {s}", .{ self.base_branch, self.branch });
                return;
            };
            defer gpa.free(merge_base);

            if (std.mem.eql(u8, merge_base, base_sha)) {
                // Fast-forward: base hasn't moved since the branch was cut.
                if (updateRefCas(gpa, io, self.base_branch, branch_sha, base_sha) catch false) {
                    log.log(.info, "improve-self: fast-forwarded {s} to {s}", .{ self.base_branch, branch_sha });
                    self.resyncLocalBranch(gpa, io, branch_sha);
                    self.merged = true;
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
                log.log(.info, "improve-self: merge commit {s} landed on {s} (merged {s})", .{ commit, self.base_branch, self.branch });
                self.resyncLocalBranch(gpa, io, commit);
                self.merged = true;
                return;
            }
            // Someone else moved base_branch between the read and the write;
            // loop and retry against its new tip.
        }
        log.log(.warn, "improve-self: {s} kept losing the race to merge into {s}; leaving it on the branch", .{ self.branch, self.base_branch });
    }

    /// After a successful merge-back, fast-forwards this worktree's own
    /// branch ref to the commit that just landed on the base branch, so
    /// the two stay in lockstep.
    ///
    /// Without this the branch keeps accumulating its own parallel history
    /// every promotion, diverging a little further from the base branch
    /// each time even though its content already landed there under a
    /// different commit object — confirmed live: the first 7 promotions of
    /// a run merged cleanly, and every one after silently failed once
    /// accumulated drift produced a real conflict neither side could
    /// auto-resolve, with nothing surfacing the growing backlog short of
    /// reading raw logs for "conflicts" by hand.
    ///
    /// `git -C <worktree> reset --hard`: pinned to the worktree path so a
    /// caller whose cwd has drifted (chdir'd back to the main tree) can
    /// never reset the user's checkout — the concern that briefly moved
    /// this to a bare `git update-ref` on the branch ref. That variant kept
    /// the ref in lockstep but left the worktree's checked-out FILES at the
    /// pre-merge content, and those files are what the next iteration's
    /// context and staging copy from: proposals then build on a tree
    /// missing everything the merge just folded in, re-introducing on the
    /// next merge exactly what someone else had fixed. Both halves matter:
    /// ref moved AND files synced.
    fn resyncLocalBranch(self: *const Worktree, gpa: std.mem.Allocator, io: std.Io, new_sha: []const u8) void {
        const argv = [_][]const u8{ "git", "-C", self.path, "reset", "--hard", new_sha };
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
    //
    // Absolute, because the engine chdirs INTO the worktree for the whole
    // run: any later use of this path (resyncLocalBranch's `git -C`,
    // cleanup's `git worktree remove`) resolves from a cwd where the
    // relative form does not exist. Observed live: `git -C
    // '.clanker-worktrees/<id>'` failing with "No such file or directory"
    // from inside that very worktree, silently skipping the post-merge
    // resync.
    const cwd_path = std.process.currentPathAlloc(io, gpa) catch try gpa.dupe(u8, ".");
    defer gpa.free(cwd_path);
    const path = try std.fmt.allocPrint(gpa, "{s}/.clanker-worktrees/{s}", .{ cwd_path, id });
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
        log.log(.warn, "improve-self: could not link state/.env/config.local.toml into the worktree: {s}", .{@errorName(err)});

    return .{ .path = path, .branch = branch, .base_branch = base_branch };
}

/// Symlinks the runtime paths a fresh worktree checkout doesn't get on its
/// own — they're gitignored, so `git worktree add` never populates them.
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
/// step outside the sandbox — a symlinked `state` made every write under
/// state/staging/ look like exactly that and get refused. state/ is a real
/// directory local to the worktree; only the two entries below are linked
/// back in, as leaves the sandboxed tools never traverse through.
fn linkSharedState(gpa: std.mem.Allocator, io: std.Io, worktree_path: []const u8) !void {
    const root = try std.process.currentPathAlloc(io, gpa);
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

    // The dividing line for everything under state/ is WHO reads the path.
    //
    // Symlinks work only for paths read by the HOST (native I/O follows
    // links): improvements.jsonl and history/ are read/written by the
    // engine's History, never by a sandboxed tool. Every path a sandboxed
    // tool traverses is off-limits as a link, because safeJoinSecure's
    // no-follow walk (correctly) refuses symlinked components: linked
    // state/runs broke cmd_graph's write test in every worktree (baseline
    // gate 2/3, observed live), linked state/sessions breaks cmd_sessions
    // the same way, and a linked learnings.md/reasoning.jsonl leaf denies
    // the learnings/reasoning tools. Staged capability evals never catch
    // any of this because staging COPIES (dereferencing links); only the
    // worktree, where baseline/final gates run, has the links.
    //
    // Ensure host-side link targets exist before the access check: on a
    // fresh checkout state/history/ is absent and the symlink is silently
    // skipped, losing the cross-run dedup memory for the entire session.
    std.Io.Dir.cwd().createDirPath(io, "state/history") catch {};
    for ([_][]const u8{ "state/improvements.jsonl", "state/history" }) |name| {
        std.Io.Dir.cwd().access(io, name, .{}) catch continue; // nothing to link
        const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, name });
        defer gpa.free(target);
        const link_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ worktree_path, name });
        defer gpa.free(link_path);
        const is_dir = std.mem.endsWith(u8, name, "history");
        std.Io.Dir.cwd().symLink(io, target, link_path, .{ .is_directory = is_dir }) catch |err| {
            log.log(.warn, "improve-self: could not link {s} into the worktree: {s}; falling back to copy", .{ name, @errorName(err) });
            // Symlinks can fail on filesystems that don't support them.
            // Fall back to copying so the worktree still has cross-run
            // memory even when linking is impossible.
            if (std.mem.eql(u8, name, "state/improvements.jsonl")) {
                const data = std.Io.Dir.cwd().readFileAlloc(io, name, gpa, .limited(1 << 24)) catch continue;
                defer gpa.free(data);
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = link_path, .data = data }) catch |werr|
                    log.log(.warn, "improve-self: copy fallback for {s} also failed: {s}", .{ name, @errorName(werr) });
            }
        };
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
        std.Io.Dir.cwd().symLink(io, target, link_path, .{ .is_directory = true }) catch |err|
            log.log(.warn, "improve-self: could not link {s} into the worktree: {s}", .{ name, @errorName(err) });
    }

    for ([_][]const u8{ "state/learnings.md", "state/autolearn.jsonl", "state/plugin_config.json", "state/token_stats.jsonl", "state/reasoning.jsonl" }) |name| {
        // 16 MiB: autolearn's own log cap is 8 MiB (max_log_bytes,
        // src/agent/autolearn.zig) and the trim triggers only past it, so a
        // 4 MiB read limit here didn't truncate -- readFileAlloc errors on
        // oversize and the catch skipped the copy entirely, silently
        // dropping the shared memory exactly when it had grown most useful.
        const data = std.Io.Dir.cwd().readFileAlloc(io, name, gpa, .limited(1 << 24)) catch continue;
        defer gpa.free(data);
        const dst = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ worktree_path, name });
        defer gpa.free(dst);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = data }) catch |err|
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
