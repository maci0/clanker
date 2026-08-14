//! Claude Code hooks.json parsing and deterministic tool matcher semantics.

const std = @import("std");

pub const Event = enum { PreToolUse, PostToolUse, UserPromptSubmit, Stop, SessionStart };

pub const Hook = struct {
    event: Event,
    matcher: []const u8 = "",
    command: []const u8,
    timeout_ms: u32,
};

pub const Config = struct {
    hooks: []const Hook = &.{},

    pub fn forEvent(self: Config, arena: std.mem.Allocator, event: Event, tool_name: []const u8) ![]const Hook {
        var out: std.ArrayList(Hook) = .empty;
        for (self.hooks) |hook| {
            if (hook.event != event) continue;
            if ((event == .PreToolUse or event == .PostToolUse) and !matches(hook.matcher, tool_name)) continue;
            try out.append(arena, hook);
        }
        return out.toOwnedSlice(arena);
    }
};

pub fn load(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, default_timeout_ms: u32) !Config {
    const raw = try dir.readFileAlloc(io, path, arena, .limited(1 << 20));
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    const root_obj = switch (root) {
        .object => |o| o,
        else => return error.HooksRootNotObject,
    };
    const hooks_value = root_obj.get("hooks") orelse root;
    const hooks_obj = switch (hooks_value) {
        .object => |o| o,
        else => return error.HooksNotObject,
    };
    var out: std.ArrayList(Hook) = .empty;
    const events = [_]Event{ .PreToolUse, .PostToolUse, .UserPromptSubmit, .Stop, .SessionStart };
    for (events) |event| {
        const groups_value = hooks_obj.get(@tagName(event)) orelse continue;
        const groups = switch (groups_value) {
            .array => |a| a,
            else => return error.HookEventNotArray,
        };
        for (groups.items) |group_value| {
            const group = switch (group_value) {
                .object => |o| o,
                else => return error.HookGroupNotObject,
            };
            const matcher = if (group.get("matcher")) |v| switch (v) {
                .string => |s| s,
                else => return error.HookMatcherNotString,
            } else "";
            try validateMatcher(matcher);
            const handlers_value = group.get("hooks") orelse return error.HookHandlersMissing;
            const handlers = switch (handlers_value) {
                .array => |a| a,
                else => return error.HookHandlersNotArray,
            };
            for (handlers.items) |handler_value| {
                const handler = switch (handler_value) {
                    .object => |o| o,
                    else => return error.HookHandlerNotObject,
                };
                const kind = if (handler.get("type")) |v| switch (v) {
                    .string => |s| s,
                    else => return error.HookTypeNotString,
                } else "command";
                if (!std.mem.eql(u8, kind, "command")) continue;
                const command = if (handler.get("command")) |v| switch (v) {
                    .string => |s| s,
                    else => return error.HookCommandNotString,
                } else return error.HookCommandMissing;
                var timeout_ms = default_timeout_ms;
                if (handler.get("timeout")) |v| {
                    const seconds: i64 = switch (v) {
                        .integer => |n| n,
                        .number_string => |s| try std.fmt.parseInt(i64, s, 10),
                        else => return error.HookTimeoutNotInteger,
                    };
                    if (seconds < 0 or seconds > std.math.maxInt(u32) / 1000) return error.HookTimeoutInvalid;
                    timeout_ms = @intCast(seconds * 1000);
                }
                try out.append(arena, .{ .event = event, .matcher = matcher, .command = command, .timeout_ms = timeout_ms });
            }
        }
    }
    return .{ .hooks = try out.toOwnedSlice(arena) };
}

/// Claude treats simple word/pipe matchers as literal alternation. Regex-like
/// matchers use the common hook patterns: anchors, `.`, `*`, `+`, `?`, outer
/// grouping, alternation, escapes and character classes.
pub fn matches(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0 or std.mem.eql(u8, pattern, "*")) return true;
    if (isLiteralAlternation(pattern)) {
        var parts = std.mem.splitScalar(u8, pattern, '|');
        while (parts.next()) |part| if (std.mem.eql(u8, part, text)) return true;
        return false;
    }
    return regexMatches(pattern, text);
}

fn isLiteralAlternation(pattern: []const u8) bool {
    for (pattern) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '|') return false;
    return true;
}

fn validateMatcher(pattern: []const u8) !void {
    if (pattern.len == 0 or isLiteralAlternation(pattern) or std.mem.eql(u8, pattern, "*")) return;
    var brackets: usize = 0;
    var parens: usize = 0;
    var escaped = false;
    for (pattern) |c| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') escaped = true else if (c == '[') brackets += 1 else if (c == ']') {
            if (brackets == 0) return error.InvalidHookMatcher;
            brackets -= 1;
        } else if (c == '(') parens += 1 else if (c == ')') {
            if (parens == 0) return error.InvalidHookMatcher;
            parens -= 1;
        }
    }
    if (escaped or brackets != 0 or parens != 0) return error.InvalidHookMatcher;
}

fn regexMatches(raw: []const u8, text: []const u8) bool {
    var pattern = raw;
    const anchored_start = pattern.len > 0 and pattern[0] == '^';
    if (anchored_start) pattern = pattern[1..];
    const anchored_end = pattern.len > 0 and pattern[pattern.len - 1] == '$' and (pattern.len < 2 or pattern[pattern.len - 2] != '\\');
    if (anchored_end) pattern = pattern[0 .. pattern.len - 1];
    if (pattern.len >= 2 and pattern[0] == '(' and pattern[pattern.len - 1] == ')') pattern = pattern[1 .. pattern.len - 1];
    var alternatives = std.mem.splitScalar(u8, pattern, '|');
    while (alternatives.next()) |branch| {
        if (anchored_start) {
            if (matchSeq(branch, text, 0, anchored_end)) return true;
        } else {
            for (0..text.len + 1) |start| if (matchSeq(branch, text, start, anchored_end)) return true;
        }
    }
    return false;
}

fn matchSeq(pattern: []const u8, text: []const u8, start: usize, anchored_end: bool) bool {
    return matchFrom(pattern, 0, text, start, anchored_end);
}

fn matchFrom(pattern: []const u8, pi: usize, text: []const u8, ti: usize, anchored_end: bool) bool {
    if (pi >= pattern.len) return !anchored_end or ti == text.len;
    var atom_end = pi + 1;
    if (pattern[pi] == '\\') {
        if (atom_end >= pattern.len) return false;
        atom_end += 1;
    } else if (pattern[pi] == '[') {
        atom_end = (std.mem.findScalarPos(u8, pattern, atom_end, ']') orelse return false) + 1;
    }
    const quantifier: u8 = if (atom_end < pattern.len and (pattern[atom_end] == '*' or pattern[atom_end] == '+' or pattern[atom_end] == '?')) pattern[atom_end] else 0;
    const next = atom_end + @intFromBool(quantifier != 0);
    if (quantifier == 0) return ti < text.len and atomMatches(pattern[pi..atom_end], text[ti]) and matchFrom(pattern, next, text, ti + 1, anchored_end);
    const min: usize = if (quantifier == '+') 1 else 0;
    const max: usize = if (quantifier == '?') 1 else text.len - ti;
    var count: usize = 0;
    while (count < max and ti + count < text.len and atomMatches(pattern[pi..atom_end], text[ti + count])) count += 1;
    if (count < min) return false;
    var use = count + 1;
    while (use > min) {
        use -= 1;
        if (matchFrom(pattern, next, text, ti + use, anchored_end)) return true;
    }
    return false;
}

fn atomMatches(atom: []const u8, c: u8) bool {
    if (atom.len == 1) return atom[0] == '.' or atom[0] == c;
    if (atom[0] == '\\') return atom.len == 2 and atom[1] == c;
    if (atom[0] != '[' or atom[atom.len - 1] != ']') return false;
    var i: usize = 1;
    const negated = i < atom.len - 1 and atom[i] == '^';
    if (negated) i += 1;
    var found = false;
    while (i < atom.len - 1) {
        if (i + 2 < atom.len - 1 and atom[i + 1] == '-') {
            found = found or (c >= atom[i] and c <= atom[i + 2]);
            i += 3;
        } else {
            found = found or c == atom[i];
            i += 1;
        }
    }
    return if (negated) !found else found;
}

test "matcher supports Claude literal alternation and regex forms" {
    try std.testing.expect(matches("Write|Edit", "Write"));
    try std.testing.expect(!matches("Write|Edit", "Read"));
    try std.testing.expect(matches("^mcp__.*_write$", "mcp__files_write"));
    try std.testing.expect(matches("^(Write|Edit|NotebookEdit)$", "NotebookEdit"));
    try std.testing.expect(matches("[Rr]ead.*", "read_file"));
    try std.testing.expect(!matches("^Read$", "ReadFile"));
}

test "loader preserves hook order and converts timeout seconds" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hooks.json", .data =
        \\{"hooks":{"PreToolUse":[{"matcher":"Write|Edit","hooks":[{"type":"command","command":"check one","timeout":2},{"type":"prompt","prompt":"skip"},{"type":"command","command":"check two"}]}]}}
    });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg = try load(io, arena_state.allocator(), tmp.dir, "hooks.json", 60000);
    try std.testing.expectEqual(@as(usize, 2), cfg.hooks.len);
    try std.testing.expectEqualStrings("check one", cfg.hooks[0].command);
    try std.testing.expectEqual(@as(u32, 2000), cfg.hooks[0].timeout_ms);
    try std.testing.expectEqualStrings("check two", cfg.hooks[1].command);
    try std.testing.expectEqual(@as(u32, 60000), cfg.hooks[1].timeout_ms);
}
