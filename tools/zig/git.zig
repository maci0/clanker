//! git: sandboxed git operations via ck_exec.
//! Input:  {"args": ["status", "--porcelain"]}
//! Output: {"ok": bool, "code": int, "stdout": "...", "stderr": "..."}
//! Destructive commands (push/reset/rebase/checkout/...) are denied by the
//! sandbox. This tool mirrors the host's deny list so a destructive verb gets
//! a clear in-tool message naming the verb and the allowed set, instead of the
//! generic "refused by this tool's sandbox policy" the host would produce.
//! The host still enforces the deny; this list never widens it.

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

/// Verbs a caller may legitimately invoke through this tool. Read-only
/// inspection and local staging only; anything that mutates remote state or
/// rewrites history is left to a human via a real terminal.
///
/// `worktree` is allowed so a caller can inspect and manage worktrees, and
/// because it is not in the host's deny list either: this entry only makes the
/// deny message truthful, it never widens the sandbox, which stays the final
/// word.
///
/// It is NOT a hook for isolating your own work, and `.local/worktrees/<wt>`,
/// which earlier versions of this comment and the manifest both described as
/// where "each task runs", was never created by anything. Isolation is the
/// harness's job and it works by moving the whole run (`clanker run
/// --worktree`, improve-self by default): the process chdirs in, so the
/// worktree is simply where every relative path already points and where this
/// tool already runs. A worktree the AGENT adds by hand is the case that does
/// not work, because nothing moves into it — the file tools keep resolving
/// against the run's root, so edits land there while `git -C <wt> status`
/// reports on an empty worktree, and both halves look successful.
const allowed_verbs = [_][]const u8{
    "status", "diff", "log", "show", "add", "commit", "ls-files", "rev-parse", "branch", "worktree",
};

/// Mirror of the host's exec_deny_tokens (src/sandbox/host.zig): verbs and
/// flags the sandbox refuses for git. Kept in step so the in-tool message
/// names the same verbs the host denies. If a verb is not here and not in
/// `allowed_verbs` the host's deny list is still the final word.
const denied_tokens = [_][]const u8{
    "push",   "reset",  "rebase",    "checkout", "clean",   "rm",            "fetch",
    "merge",  "revert", "stash",     "remote",   "tag",     "filter-branch", "gc",
    "repack", "prune",  "submodule", "-f",       "--force", "--exec",
};

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
}

/// Whole-arg / flag-prefix / word-boundary match, the same shape the host uses
/// in argDenied.
fn argDenied(arg: []const u8, t: []const u8) bool {
    if (t.len == 0) return false;
    if (std.mem.eql(u8, arg, t)) return true;
    if (t[0] == '-') return std.mem.startsWith(u8, arg, t);
    var i: usize = 0;
    while (std.mem.findPos(u8, arg, i, t)) |p| {
        const before = p == 0 or !isWordChar(arg[p - 1]);
        const after = p + t.len >= arg.len or !isWordChar(arg[p + t.len]);
        if (before and after) return true;
        i = p + 1;
    }
    return false;
}

/// Git global options that take a value in the next argument (or the same one
/// via `=`). Mirrors the host's list in src/sandbox/host.zig so the in-tool
/// deny message names the right verb when the value would otherwise be read
/// as the subcommand (e.g. `git -C <worktree> status`).
const git_value_options = [_][]const u8{
    "-C", "--git-dir",   "--work-tree", "--git-common-dir",
    "-c", "--namespace", "--exec-path", "--config-env",
};

/// The first argument of the given args, i.e. the git verb. Args that start
/// with "-" (flags before the subcommand, like `git --version`) are skipped,
/// and so is the value of a value-taking global option — the worktree path
/// after `-C` must not be read as the verb.
fn gitVerb(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len == 0) continue;
        if (a[0] == '-') {
            for (git_value_options) |o| {
                if (std.mem.eql(u8, a, o)) {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        return a;
    }
    return null;
}

/// If the args include a verb the sandbox denies, returns that token; else
/// null. The verb is what names the refusal; flags are caught too so `-f`
/// isn't reported as a clean run. When `git_remote_ops` is set, the PR-lifecycle
/// verbs git_remote_ops grants (`push`, `merge`, `checkout`) are skipped, the
/// same lift the host applies — the deny message must not pre-empt the config.
fn deniedVerb(args: []const []const u8, git_remote_ops: bool) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len == 0) continue;
        if (a[0] == '-') {
            for (git_value_options) |o| {
                if (std.mem.eql(u8, a, o)) {
                    i += 1; // option value is data, not a command token
                    break;
                }
            }
        }
        for (denied_tokens) |t| {
            if (git_remote_ops and isGitRemoteOpToken(t)) continue;
            if (argDenied(a, t)) return t;
        }
    }
    return null;
}

fn isGitRemoteOpToken(t: []const u8) bool {
    return std.mem.eql(u8, t, "push") or std.mem.eql(u8, t, "merge") or std.mem.eql(u8, t, "checkout");
}

/// Classic `*` glob, mirroring src/sandbox/host.zig's globMatch so the guest
/// makes the same match the host does. `*` matches any run of non-'/' chars
/// (which for an argv joined with spaces includes the spaces), `?` one.
fn globMatch(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (ni < name.len or pi < pattern.len) {
        if (pi < pattern.len and pattern[pi] == '*') {
            star_p = pi;
            star_n = ni;
            pi += 1;
            continue;
        }
        if (ni < name.len and pi < pattern.len) {
            if (pattern[pi] == '?' and name[ni] != '/') {
                pi += 1;
                ni += 1;
                continue;
            }
            if (pattern[pi] == name[ni]) {
                pi += 1;
                ni += 1;
                continue;
            }
        }
        if (star_p) |sp| {
            pi = sp + 1;
            star_n += 1;
            if (star_n > name.len) return false;
            ni = star_n;
            continue;
        }
        return false;
    }
    return true;
}

/// Whether `pattern`'s first whitespace-delimited token is exactly `cmd`.
fn patternNamesCmd(pattern: []const u8, cmd: []const u8) bool {
    var i: usize = 0;
    while (i < pattern.len and pattern[i] != ' ') : (i += 1) {}
    return std.mem.eql(u8, pattern[0..i], cmd);
}

const ExecPolicy = struct {
    git_remote_ops: bool = false,
    patterns: []const []const u8 = &.{},
};

/// The harness injects the agent's exec policy (git_remote_ops,
/// exec_pattern_allow) into this tool's `config` (see execPolicyConfig in
/// src/sandbox/host.zig); read it so the in-tool deny mirrors the host.
fn readPolicy() ExecPolicy {
    var p = ExecPolicy{};
    const cfg_json = lib.config();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, cfg_json, .{}) catch return p;
    if (parsed != .object) return p;
    const obj = parsed.object;
    if (obj.get("git_remote_ops")) |v| {
        if (v == .bool) p.git_remote_ops = v.bool;
    }
    if (obj.get("exec_pattern_allow")) |v| {
        if (v == .array) {
            var list: std.ArrayList([]const u8) = .empty;
            for (v.array.items) |item| {
                if (item == .string) list.append(lib.alloc, item.string) catch {};
            }
            p.patterns = list.toOwnedSlice(lib.alloc) catch &.{};
        }
    }
    return p;
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object with an \"args\" array");
    const obj = parsed.object;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(lib.alloc);
    // git with nothing to do prints its usage to stderr and exits 1, which
    // reads as a tool failure with no explanation of what the caller did wrong.
    if (obj.get("args") == null) {
        return lib.fail(out, "git needs \"args\", e.g. {\"args\": [\"status\", \"--porcelain\"]}");
    }
    if (obj.get("args")) |a| {
        switch (a) {
            .array => |arr| for (arr.items) |item| switch (item) {
                .string => |s| try args.append(lib.alloc, s),
                else => return lib.fail(out, "args must be strings"),
            },
            else => return lib.fail(out, "args must be an array"),
        }
    }

    // A clear in-tool denial, before the host is even reached: the model
    // should see "push is refused — allowed: status, diff, ...", not a
    // generic sandbox policy error with no pointer at what to change.
    const policy = readPolicy();

    // exec_pattern_allow: when a pattern names git, git is strict — only an
    // argv matching one of its patterns runs, and a match also overrides the
    // deny tokens for the args it grants. This mirrors the host.
    var governed = false;
    var allowed = false;
    if (policy.patterns.len > 0) {
        var join_buf: [2048]u8 = undefined;
        var w: std.Io.Writer = .fixed(&join_buf);
        // Fail-closed: never make a pattern-allow decision from argv data that does not fit.
        var needed: usize = "git".len;
        for (args.items) |a| needed += 1 + a.len;
        if (needed <= join_buf.len) {
            w.writeAll("git") catch {};
            for (args.items) |a| {
                w.writeByte(' ') catch {};
                w.writeAll(a) catch {};
            }
        }
        const joined = join_buf[0..w.end];
        for (policy.patterns) |pat| {
            if (!patternNamesCmd(pat, "git")) continue; // only git-scoped patterns may authorize or lift the deny list
            governed = true;
            if (globMatch(pat, joined)) allowed = true;
        }
    }

    if (governed) {
        if (!allowed) {
            return lib.fail(out, "git is governed by exec_pattern_allow and this invocation matches no pattern");
        }
        // allowed: skip the deny-list; the matching pattern grants the argv.
    } else if (deniedVerb(args.items, policy.git_remote_ops)) |denied| {
        const verb = gitVerb(args.items);
        var msg_buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&msg_buf);
        w.writeAll("git '") catch {};
        if (verb) |v| w.writeAll(v) catch {} else w.writeAll(denied) catch {};
        w.writeAll("' is refused by the sandbox (denied token '") catch {};
        w.writeAll(denied) catch {};
        w.writeAll("'). Allowed: ") catch {};
        for (allowed_verbs, 0..) |v, i| {
            if (i > 0) w.writeAll(", ") catch {};
            w.writeAll(v) catch {};
        }
        w.writeAll(". Remote/history-rewriting verbs need a human at a real terminal.") catch {};
        return lib.fail(out, msg_buf[0..w.end]);
    }

    const result = lib.exec("git", args.items) catch |err| {
        return lib.failErr(out, err, "running git");
    };
    try out.writeAll(result);
}
