//! gh: sandboxed GitHub CLI operations via ck_exec.
//! Input:  {"args": ["pr", "create", "--base", "main"]}
//! Output: {"ok": bool, "code": int, "stdout": "...", "stderr": "..."}
//! gh is a brand-new, high-privilege command, so it is strict by default: this
//! tool runs *only* an argv that matches one of the agent's exec_pattern_allow
//! patterns (e.g. "gh pr create*", "gh pr merge*"). No patterns configured =
//! gh does nothing. The harness injects the patterns into this tool's `config`
//! (see execPolicyConfig in src/sandbox/host.zig); the host's ck_exec enforces
//! the same strictness for a governed command, so this mirror keeps the in-tool
//! message clear without being the only gate.

const std = @import("std");
const lib = @import("lib.zig");
const glob = @import("glob");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

/// The exec_pattern_allow patterns the harness injected into this tool's
/// `config`. Empty means gh is locked down entirely.
fn allowedPatterns() []const []const u8 {
    const cfg_json = lib.config();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, cfg_json, .{}) catch return &.{};
    if (parsed != .object) return &.{};
    const v = parsed.object.get("exec_pattern_allow") orelse return &.{};
    if (v != .array) return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |item| {
        if (item == .string) list.append(lib.alloc, item.string) catch {};
    }
    return list.toOwnedSlice(lib.alloc) catch &.{};
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object with an \"args\" array");
    const obj = parsed.object;
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(lib.alloc);
    if (obj.get("args") == null) {
        return lib.fail(out, "gh needs \"args\", e.g. {\"args\": [\"pr\", \"create\", \"--base\", \"main\"]}");
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

    const patterns = allowedPatterns();
    if (patterns.len == 0) {
        return lib.fail(out, "gh is disabled: no exec_pattern_allow patterns are configured. Add e.g. \"gh pr create*\" / \"gh pr merge*\" under agent.exec_pattern_allow.");
    }

    // Join argv = "gh" + args for the glob match so `*` spans arguments.
    var join_buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&join_buf);
    w.writeAll("gh") catch {};
    for (args.items) |a| {
        w.writeByte(' ') catch {};
        w.writeAll(a) catch {};
    }
    const joined = join_buf[0..w.end];

    var matched = false;
    for (patterns) |pat| {
        if (glob.match(pat, joined)) {
            matched = true;
            break;
        }
    }
    if (!matched) {
        var msg_buf: [512]u8 = undefined;
        var mw: std.Io.Writer = .fixed(&msg_buf);
        mw.writeAll("gh is governed by exec_pattern_allow and '") catch {};
        mw.writeAll(joined) catch {};
        mw.writeAll("' matches no pattern. Allowed: ") catch {};
        for (patterns, 0..) |p, i| {
            if (i > 0) mw.writeAll(", ") catch {};
            mw.writeAll(p) catch {};
        }
        return lib.fail(out, msg_buf[0..mw.end]);
    }

    const result = lib.exec("gh", args.items) catch |err| {
        return lib.failErr(out, err, "running gh");
    };
    try out.writeAll(result);
}
