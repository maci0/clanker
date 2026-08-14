//! Opt-in per-turn classifier that selects a sampling-profile
//! `reasoning_effort` row. Fail-open: any error leaves the provider default.

const std = @import("std");
const config = @import("../config.zig");
const types = @import("../llm/types.zig");
const client = @import("../llm/client.zig");
const log = @import("../util/log.zig");

pub const system_prompt =
    \\Classify the complexity of this user message for an AI coding agent.
    \\Reply with exactly one word: low, medium, high, or xhigh.
    \\
    \\low:   Lookup, clarification, simple file read, "what is X?"
    \\medium: Standard coding task, single file edit, known pattern
    \\high:  Multi-file refactor, design decision, debugging complex issue
    \\xhigh: Architecture redesign, cross-system analysis, novel problem
    \\
    \\Message:
;

pub const Level = enum { low, medium, high, xhigh };

pub const Classification = struct {
    level: Level,
    duration_ms: u64,
};

pub fn parseLevel(raw: []const u8) Level {
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n`\"'.");
    const word = it.next() orelse return .medium;
    var buf: [8]u8 = undefined;
    if (word.len > buf.len) return .medium;
    const lower = std.ascii.lowerString(&buf, word);
    return std.meta.stringToEnum(Level, lower) orelse .medium;
}

pub fn effortFor(level: Level) []const u8 {
    return switch (level) {
        .low => "low",
        .medium => "medium",
        .high, .xhigh => "high",
    };
}

/// Cheapest configured provider by `cost_per_1m_input`, then first name.
pub fn cheapestProvider(cfg: *const config.Config) ?*const config.Provider {
    var best: ?*const config.Provider = null;
    var best_cost: f64 = std.math.inf(f64);
    var best_name: []const u8 = "";
    var it = cfg.providers.iterator();
    while (it.next()) |kv| {
        const p = kv.value_ptr;
        const cost = p.activeModel().cost_per_1m_input orelse std.math.inf(f64);
        if (best == null or cost < best_cost or (cost == best_cost and std.mem.lessThan(u8, p.name, best_name))) {
            best = p;
            best_cost = cost;
            best_name = p.name;
        }
    }
    return best;
}

pub fn resolveClassifier(cfg: *const config.Config) ?*const config.Provider {
    const spec = cfg.agent.thinking_classifier_model;
    if (spec.len > 0) {
        const slash = std.mem.findScalar(u8, spec, '/');
        const name = if (slash) |i| spec[0..i] else spec;
        return cfg.providers.getPtr(name);
    }
    return cheapestProvider(cfg);
}

/// Fail-open classifier. Returns null when disabled or on any error.
pub fn classify(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    cfg: *const config.Config,
    user_text: []const u8,
) ?Classification {
    if (!cfg.agent.auto_thinking) return null;
    const provider = resolveClassifier(cfg) orelse {
        log.log(.debug, "auto-thinking skipped: no classifier provider", .{});
        return null;
    };
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prompt = std.fmt.allocPrint(arena, "{s}{s}", .{ system_prompt, user_text }) catch return null;
    var ctx = client.Ctx{
        .io = io,
        .gpa = gpa,
        .environ_map = environ_map,
        .cfg = cfg,
    };
    const msgs = [_]types.Message{.{ .role = .user, .content = prompt }};
    var err_detail: ?[]const u8 = null;
    const started = std.Io.Timestamp.now(io, .awake);
    const resp = client.chatWithTimeout(&ctx, arena, .{
        .provider = provider,
        .messages = &msgs,
        .max_tokens = 5,
        .temperature = 0,
    }, &err_detail, cfg.agent.thinking_classifier_timeout_ms) catch |err| {
        log.log(.debug, "auto-thinking failed: {s}", .{@errorName(err)});
        return null;
    };
    const elapsed = started.durationTo(std.Io.Timestamp.now(io, .awake));
    return .{
        .level = parseLevel(resp.message.content orelse ""),
        .duration_ms = @intCast(@max(0, @divTrunc(elapsed.nanoseconds, std.time.ns_per_ms))),
    };
}

test "parseLevel accepts the four words and falls back to medium" {
    try std.testing.expectEqual(Level.low, parseLevel("low"));
    try std.testing.expectEqual(Level.high, parseLevel("High\n"));
    try std.testing.expectEqual(Level.xhigh, parseLevel("`xhigh`"));
    try std.testing.expectEqual(Level.medium, parseLevel("maybe high?"));
    try std.testing.expectEqual(Level.medium, parseLevel(""));
}

test "effortFor maps xhigh onto high" {
    try std.testing.expectEqualStrings("high", effortFor(.xhigh));
    try std.testing.expectEqualStrings("low", effortFor(.low));
}

test "auto_thinking is off by default" {
    try std.testing.expect(!(config.Agent{}).auto_thinking);
}
