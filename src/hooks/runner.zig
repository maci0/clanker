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
        // The config validator rejects a blank command, but the logs below must
        // not depend on it: an empty argv used to be indexed as `argv[0]`, which
        // panics in Debug and reads a garbage pointer in ReleaseFast. Name the
        // command instead of indexing.
        const argv0 = if (argv.len > 0) argv[0] else "";
        const attempt = host.execUnderPolicyInput(sb, argv, payload, 64 * 1024, 64 * 1024, hook.timeout_ms, sb.root_dir);
        switch (attempt) {
            .not_allowed => log.log(.warn, "hook {s}: command '{s}' is outside exec_allow", .{ @tagName(event), argv0 }),
            .denied => log.log(.warn, "hook {s}: command '{s}' was denied by exec policy", .{ @tagName(event), argv0 }),
            .failed => |err| log.log(.warn, "hook {s}: command '{s}' failed: {s}", .{ @tagName(event), argv0, @errorName(err) }),
            .ran => |outcome| {
                defer outcome.deinit(sb.gpa);
                // A hook that wrote output the runner cannot read is a
                // misconfigured security control, and reading it as "allow"
                // is how a deny hook silently stops denying. Say so against
                // the command that misbehaved; the decision itself stays
                // `.allow`, because unreadable output is not evidence of a
                // verdict, and turning it into a block would let one garbled
                // hook strand every turn.
                if (unreadableHookOutput(outcome.stdout)) |why| {
                    log.log(.warn, "hook {s}: command '{s}' wrote output the runner could not read ({s}); treating the hook as having no verdict", .{ @tagName(event), argv0, why });
                }
                var decoded = decode(arena, outcome.stdout);
                if (outcome.code == 2) {
                    decoded.decision = .deny;
                    decoded.reason = try arena.dupe(u8, std.mem.trim(u8, outcome.stderr, " \t\r\n"));
                }
                // Copy decoded strings out of outcome.stdout before the
                // outcome is deinitialized below; decode's reason/context
                // slices point into that buffer.
                if (decoded.reason.len > 0) decoded.reason = try arena.dupe(u8, decoded.reason);
                if (decoded.context.len > 0) decoded.context = try arena.dupe(u8, decoded.context);
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
                if (d == .string) {
                    const nested = parseDecision(d.string);
                    // A run of hooks folds to the most restrictive verdict;
                    // one payload that carries both the flat and the nested
                    // Claude shapes must do the same, not let a nested
                    // "allow" soften a top-level "deny" (or vice versa).
                    if (@intFromEnum(nested) > @intFromEnum(result.decision)) {
                        result.decision = nested;
                        // The stricter verdict replaces the less strict
                        // one's reason; otherwise the reply can pair a deny
                        // with "allowed because...".
                        result.reason = "";
                        if (specific.get("permissionDecisionReason")) |r| {
                            if (r == .string and r.string.len > 0) result.reason = r.string;
                        }
                    }
                }
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

/// Why a hook's stdout is not a usable reply, or null when it is fine.
///
/// A hook that says nothing at all is a hook with no verdict, which is
/// legal: a `PreToolUse` script that only inspects and exits 0 is the
/// ordinary case. Anything it *did* write counts, because `decode` reads a
/// verdict out of stdout or nothing, and a `deny` its author wrote but did not
/// encode is a security control that reads as an `allow`. The exit code is
/// still authoritative on its own: code 2 denies regardless of what is here.
fn unreadableHookOutput(stdout: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed[0] != '{') return "stdout is not a JSON object";
    // `validate` parses without building a value tree, so a hook reply up to
    // the 64 KiB exec cap costs no allocation to check.
    const valid = std.json.validate(std.heap.page_allocator, trimmed) catch return "the reply could not be read (out of memory)";
    if (!valid) return "stdout is not valid JSON";
    return null;
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

test "nested permissionDecision cannot soften a top-level deny" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = decode(arena,
        \\{"decision":"deny","reason":"top","hookSpecificOutput":{"permissionDecision":"allow","permissionDecisionReason":"nested"}}
    );
    try std.testing.expectEqual(Decision.deny, result.decision);
    try std.testing.expectEqualStrings("top", result.reason);
}

test "nested deny hardens a top-level allow and takes the nested reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = decode(arena,
        \\{"decision":"allow","reason":"looks safe","hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"policy"}}
    );
    try std.testing.expectEqual(Decision.deny, result.decision);
    try std.testing.expectEqualStrings("policy", result.reason);
}

test "a blank command warns instead of indexing an empty argv" {
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
    // The loader refuses this shape now, but the runner must survive it on its
    // own: `splitCommand` returns a zero-length argv and the `.not_allowed`
    // branch used to format `argv[0]`.
    const cfg = hook_config.Config{ .hooks = &.{
        .{ .event = .PreToolUse, .matcher = "Write", .command = "\t", .timeout_ms = 1000 },
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try run(arena_state.allocator(), cfg, &sb, .PreToolUse, "Write", "{}");
    try std.testing.expectEqual(Decision.allow, result.decision);
    try std.testing.expectEqualStrings("", result.context);
}

test "hook stdout that cannot be read is named, and a well-formed reply is not" {
    // A hook is a security control, so a `deny` whose JSON is garbled must
    // not read as a silent `allow` with no trace anywhere. The decision
    // stays `allow` (unreadable output is not a verdict) but the runner says
    // which command and why.
    try std.testing.expect(unreadableHookOutput("") == null);
    try std.testing.expect(unreadableHookOutput("   \n") == null);
    try std.testing.expect(unreadableHookOutput("{\"decision\":\"deny\",\"reason\":\"no\"}") == null);
    try std.testing.expect(unreadableHookOutput("{\"nested\":{\"decision\":\"ask\"}}") == null);
    // A well-formed object whose values are the wrong shape is still a reply
    // the decoder reads, so it is not reported here.
    try std.testing.expect(unreadableHookOutput("{\"decision\":42}") == null);

    try std.testing.expectEqualStrings("stdout is not a JSON object", unreadableHookOutput("42") orelse unreachable);
    // Prose on stdout is the same fault: `decode` reads no verdict out of it,
    // so a hook whose author meant it to deny has said nothing at all.
    try std.testing.expectEqualStrings("stdout is not a JSON object", unreadableHookOutput("checked the path, all good") orelse unreachable);
    try std.testing.expectEqualStrings("stdout is not a JSON object", unreadableHookOutput("[1,2]") orelse unreachable);
    try std.testing.expectEqualStrings("stdout is not valid JSON", unreadableHookOutput("{\"decision\":") orelse unreachable);
    try std.testing.expectEqualStrings("stdout is not valid JSON", unreadableHookOutput("{\"a\":1,}") orelse unreachable);
}

test "a hook whose deny is garbled is reported by the runner, not swallowed" {
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
    // Exits 0 and writes the opening of a deny object. `decode` has nothing
    // to read, so the hook contributes no verdict -- the same decision a
    // silent hook reaches, now on a path that says why.
    const cfg = hook_config.Config{ .hooks = &.{
        .{ .event = .PreToolUse, .matcher = "Write", .command = "printf '{\"decision\":'", .timeout_ms = 1000 },
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const result = try run(arena_state.allocator(), cfg, &sb, .PreToolUse, "Write", "{}");
    try std.testing.expectEqual(Decision.allow, result.decision);
    try std.testing.expectEqualStrings("", result.reason);
}
