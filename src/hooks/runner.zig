//! Serial lifecycle-hook execution over the shared subprocess policy gate.

const std = @import("std");
const hook_config = @import("config.zig");
const host = @import("../sandbox/host.zig");
const log = @import("../util/log.zig");

pub const Decision = enum(u8) { allow, ask, deny };

pub const Result = struct {
    decision: Decision = .allow,
    reason: []const u8 = "",
    context: []const u8 = "",
};

pub fn run(
    arena: std.mem.Allocator,
    cfg: hook_config.Config,
    sb: *const host.Sandbox,
    event: hook_config.Event,
    tool_name: []const u8,
    payload: []const u8,
) !Result {
    const selected = try cfg.forEvent(arena, event, tool_name);
    var result: Result = .{};
    var contexts: std.ArrayList([]const u8) = .empty;
    for (selected) |hook| {
        var argv_buffer: [64][]const u8 = undefined;
        const argv = splitCommand(hook.command, &argv_buffer) catch |err| {
            log.log(.warn, "hook {s}: invalid command: {s}", .{ @tagName(event), @errorName(err) });
            continue;
        };
        const attempt = host.execUnderPolicyInput(sb, argv, payload, 64 * 1024, 64 * 1024, hook.timeout_ms, sb.root_dir);
        switch (attempt) {
            .not_allowed => log.log(.warn, "hook {s}: command '{s}' is outside exec_allow", .{ @tagName(event), argv[0] }),
            .denied => log.log(.warn, "hook {s}: command '{s}' was denied by exec policy", .{ @tagName(event), argv[0] }),
            .failed => |err| log.log(.warn, "hook {s}: command '{s}' failed: {s}", .{ @tagName(event), argv[0], @errorName(err) }),
            .ran => |outcome| {
                defer outcome.deinit(sb.gpa);
                var decoded = decode(arena, outcome.stdout);
                if (outcome.code == 2) {
                    decoded.decision = .deny;
                    decoded.reason = try arena.dupe(u8, std.mem.trim(u8, outcome.stderr, " \t\r\n"));
                }
                if (@intFromEnum(decoded.decision) > @intFromEnum(result.decision)) {
                    result.decision = decoded.decision;
                    result.reason = decoded.reason;
                } else if (decoded.decision == result.decision and result.reason.len == 0) {
                    result.reason = decoded.reason;
                }
                if (decoded.context.len > 0) try contexts.append(arena, decoded.context);
            },
        }
    }
    if (contexts.items.len > 0) result.context = try std.mem.join(arena, "\n", contexts.items);
    return result;
}

fn decode(arena: std.mem.Allocator, stdout: []const u8) Result {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return .{};
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{}) catch return .{};
    const object = switch (value) {
        .object => |o| o,
        else => return .{},
    };
    var result: Result = .{};
    if (object.get("decision")) |v| {
        if (v == .string) result.decision = parseDecision(v.string);
    }
    if (object.get("reason")) |v| {
        if (v == .string) result.reason = v.string;
    }
    if (object.get("additionalContext")) |v| {
        if (v == .string) result.context = v.string;
    }
    if (object.get("hookSpecificOutput")) |v| {
        if (v == .object) {
            const specific = v.object;
            if (specific.get("permissionDecision")) |d| {
                if (d == .string) result.decision = parseDecision(d.string);
            }
            if (specific.get("permissionDecisionReason")) |r| {
                if (r == .string and result.reason.len == 0) result.reason = r.string;
            }
            if (specific.get("additionalContext")) |c| {
                if (c == .string) result.context = c.string;
            }
        }
    }
    return result;
}

fn parseDecision(value: []const u8) Decision {
    if (std.ascii.eqlIgnoreCase(value, "deny") or std.ascii.eqlIgnoreCase(value, "block")) return .deny;
    if (std.ascii.eqlIgnoreCase(value, "ask")) return .ask;
    return .allow;
}

const SplitError = error{ TooManyArgs, UnterminatedQuote };

fn splitCommand(line: []const u8, out: *[64][]const u8) SplitError![]const []const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i == line.len) break;
        if (count == out.len) return error.TooManyArgs;
        if (line[i] == '\'' or line[i] == '"') {
            const quote = line[i];
            i += 1;
            const end = std.mem.findScalarPos(u8, line, i, quote) orelse return error.UnterminatedQuote;
            out[count] = line[i..end];
            i = end + 1;
        } else {
            const start = i;
            while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
            out[count] = line[start..i];
        }
        count += 1;
    }
    return out[0..count];
}

test "Claude output decoding uses most restrictive vocabulary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = decode(arena,
        \\{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"policy","additionalContext":"remember this"}}
    );
    try std.testing.expectEqual(Decision.deny, result.decision);
    try std.testing.expectEqualStrings("policy", result.reason);
    try std.testing.expectEqualStrings("remember this", result.context);
}

test "matching hooks run serially and fold deny over context" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = ".",
        .network_allow = &.{},
        .environ_map = &env,
        .exec_allow = &.{"printf"},
    };
    const cfg = hook_config.Config{ .hooks = &.{
        .{ .event = .PreToolUse, .matcher = "Write", .command = "printf '{\"additionalContext\":\"checked\"}'", .timeout_ms = 1000 },
        .{ .event = .PreToolUse, .matcher = "Write", .command = "printf '{\"decision\":\"deny\",\"reason\":\"policy\"}'", .timeout_ms = 1000 },
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try run(arena_state.allocator(), cfg, &sb, .PreToolUse, "Write", "{}");
    try std.testing.expectEqual(Decision.deny, result.decision);
    try std.testing.expectEqualStrings("policy", result.reason);
    try std.testing.expectEqualStrings("checked", result.context);
}
