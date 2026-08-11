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
const allowed_verbs = [_][]const u8{
    "status", "diff", "log", "show", "add", "commit", "ls-files", "rev-parse", "branch",
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
    while (std.mem.indexOfPos(u8, arg, i, t)) |p| {
        const before = p == 0 or !isWordChar(arg[p - 1]);
        const after = p + t.len >= arg.len or !isWordChar(arg[p + t.len]);
        if (before and after) return true;
        i = p + 1;
    }
    return false;
}

/// The first argument of the given args, i.e. the git verb. Args that start
/// with "-" (flags before the subcommand, like `git --version`) are skipped.
fn gitVerb(args: []const []const u8) ?[]const u8 {
    for (args) |a| {
        if (a.len == 0 or a[0] == '-') continue;
        return a;
    }
    return null;
}

/// If the args include a verb the sandbox denies, returns that token; else
/// null. The verb is what names the refusal; flags are caught too so `-f`
/// isn't reported as a clean run.
fn deniedVerb(args: []const []const u8) ?[]const u8 {
    for (args) |a| {
        for (denied_tokens) |t| {
            if (argDenied(a, t)) return t;
        }
    }
    return null;
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
    if (deniedVerb(args.items)) |denied| {
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
