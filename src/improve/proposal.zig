//! Patch-proposal model: the agent proposes edits as exact-match replaces.
//! Only files inside the modifiable surface are accepted.

const std = @import("std");
const json = std.json;
const log = @import("../util/log.zig");

pub const Change = struct {
    file: []const u8,
    /// Exact text to find; empty means append at end of file.
    old: []const u8,
    new: []const u8,
};

pub const Proposal = struct {
    summary: []const u8,
    rationale: []const u8 = "",
    changes: []const Change = &.{},
};

/// Prefixes a file path must match to be part of the modifiable surface.
/// Deliberately excludes the evaluation machinery so a single improvement pass
/// cannot weaken its own gate: `evals/` by being absent from this list,
/// `src/evals/`, `src/improve/`, and `src/tools/builder.zig` by the denials in
/// `validatePath` (they sit inside the allowed `src/` prefix).
pub const allowed_prefixes = [_][]const u8{
    "src/",
    "tools/",
    "skills/",
    "tests/",
    "docs/",
    "README.md",
    "AGENTS.md",
    "build.zig",
    "build.zig.zon",
    "config.json",
};

pub fn validatePath(path: []const u8) bool {
    for (allowed_prefixes) |p| {
        if (std.mem.startsWith(u8, path, p)) {
            // Fine-grained denials within allowed prefixes.
            if (std.mem.startsWith(u8, path, "src/evals/")) return false;
            if (std.mem.startsWith(u8, path, "src/improve/")) return false;
            if (std.mem.eql(u8, path, "src/tools/builder.zig")) return false;
            // Descriptors are editable, but only as descriptors: a stray write
            // into tools/manifests/ must not drop a .wasm or anything else the
            // registry would then try to load.
            if (std.mem.startsWith(u8, path, "tools/manifests/") and !std.mem.endsWith(u8, path, ".tool.json")) return false;
            // tools/bin holds committed AssemblyScript build output; it is
            // produced by the TS toolchain, never hand-patched.
            if (std.mem.startsWith(u8, path, "tools/bin/")) return false;
            return true;
        }
    }
    return false;
}

/// Some local models wrap the requested JSON in a markdown code fence
/// (```json ... ```) despite being told not to. Strip an outer fence and any
/// leading/trailing whitespace so the JSON parser sees a bare object.
fn stripMarkdownFence(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len >= 3 and std.mem.eql(u8, s[0..3], "```")) {
        if (std.mem.indexOfScalar(u8, s, '\n')) |nl| {
            s = std.mem.trim(u8, s[nl + 1 ..], " \t\r\n");
        }
    }
    if (s.len >= 3 and std.mem.endsWith(u8, s, "```")) {
        s = std.mem.trim(u8, s[0 .. s.len - 3], " \t\r\n");
    }
    return s;
}

pub fn parseProposal(arena: std.mem.Allocator, raw: []const u8, max_changes: usize, max_change_bytes: usize) !Proposal {
    const cleaned = stripMarkdownFence(raw);
    const v = try json.parseFromSliceLeaky(json.Value, arena, cleaned, .{ .ignore_unknown_fields = true });
    const obj = switch (v) {
        .object => |o| o,
        else => return error.ProposalNotObject,
    };
    var p = Proposal{ .summary = try strField(obj, "summary") };
    if (obj.get("rationale")) |r| p.rationale = switch (r) {
        .string => |x| x,
        else => return error.FieldNotString,
    };
    const changes_val = obj.get("changes") orelse return error.MissingChanges;
    switch (changes_val) {
        .array => |arr| {
            if (arr.items.len == 0) return error.NoChanges;
            if (arr.items.len > max_changes) return error.TooManyChanges;
            var list: std.ArrayList(Change) = .empty;
            for (arr.items) |item| {
                const co = switch (item) {
                    .object => |o| o,
                    else => return error.ChangeNotObject,
                };
                const file = try strField(co, "file");
                if (!validatePath(file)) {
                    log.log(.warn, "proposal rejected: '{s}' is outside the modifiable surface", .{file});
                    return error.PathNotAllowed;
                }
                // A descriptor or JSON file is mostly quotes, and escaping it
                // into this proposal is where models reliably fail: the whole
                // patch comes back as a SyntaxError with nothing salvageable.
                // Either field may instead arrive base64-encoded, which has no
                // characters to escape.
                const old = try textField(arena, co, "old");
                const new = try textField(arena, co, "new");
                if (old.len + new.len > max_change_bytes) return error.ChangeTooLarge;
                try list.append(arena, .{ .file = file, .old = old, .new = new });
            }
            p.changes = try list.toOwnedSlice(arena);
        },
        else => return error.ChangesNotArray,
    }
    return p;
}

/// A change's text, taken from `<key>` or, when that is absent, decoded from
/// `<key>_b64`. Exactly one of the two must be present.
fn textField(arena: std.mem.Allocator, obj: json.ObjectMap, key: []const u8) ![]const u8 {
    if (obj.get(key)) |v| {
        return switch (v) {
            .string => |str| str,
            else => error.FieldNotString,
        };
    }
    var b64_key_buf: [32]u8 = undefined;
    const b64_key = std.fmt.bufPrint(&b64_key_buf, "{s}_b64", .{key}) catch return error.MissingField;
    const encoded = switch (obj.get(b64_key) orelse return error.MissingField) {
        .string => |str| str,
        else => return error.FieldNotString,
    };
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(encoded) catch return error.BadBase64;
    const out = try arena.alloc(u8, len);
    decoder.decode(out, encoded) catch return error.BadBase64;
    return out;
}

fn strField(obj: json.ObjectMap, key: []const u8) ![]const u8 {
    const v = obj.get(key) orelse return error.MissingField;
    return switch (v) {
        .string => |s| s,
        else => error.FieldNotString,
    };
}

// ------------------------------------------------------------------- tests --

test "validatePath" {
    try std.testing.expect(validatePath("src/main.zig"));
    try std.testing.expect(validatePath("src/agent/loop.zig"));
    try std.testing.expect(validatePath("tools/zig/calculator.zig"));
    try std.testing.expect(validatePath("skills/SYSTEM.md"));
    try std.testing.expect(validatePath("tools/manifests/calculator.tool.json"));
    try std.testing.expect(validatePath("build.zig"));
    try std.testing.expect(!validatePath("src/evals/runner.zig"));
    try std.testing.expect(!validatePath("src/improve/engine.zig"));
    try std.testing.expect(!validatePath("src/tools/builder.zig"));
    try std.testing.expect(!validatePath("evals/math.task.json"));
    try std.testing.expect(!validatePath("state/foo"));
    try std.testing.expect(!validatePath("tools/manifests/calculator.wasm"));
    try std.testing.expect(!validatePath("tools/bin/calc_ts.wasm"));
    try std.testing.expect(!validatePath("../etc/passwd"));
    try std.testing.expect(!validatePath("vendor/foo"));
}

test "stripMarkdownFence and parse fenced proposal" {
    const fenced =
        \\```json
        \\{"summary":"s","rationale":"r","changes":[{"file":"skills/SYSTEM.md","old":"old","new":"new"}]}
        \\```
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try parseProposal(arena, fenced, 40, 32 * 1024);
    try std.testing.expectEqualStrings("s", p.summary);
    try std.testing.expectEqual(@as(usize, 1), p.changes.len);
    try std.testing.expectEqualStrings("skills/SYSTEM.md", p.changes[0].file);
}

test "a change may carry its text base64-encoded" {
    // Escaping a quote-heavy descriptor into the proposal JSON is where model
    // patches reliably died as an unsalvageable SyntaxError; base64 has
    // nothing to escape.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // {"name": "x"}  ->  eyJuYW1lIjogIngifQ==
    const text =
        \\{"summary":"s","rationale":"r","changes":[
        \\{"file":"tools/manifests/x.tool.json","old_b64":"eyJuYW1lIjogIngifQ==","new_b64":"eyJuYW1lIjogInkifQ=="}]}
    ;
    const p = try parseProposal(arena, text, 10, 4096);
    try std.testing.expectEqual(@as(usize, 1), p.changes.len);
    try std.testing.expectEqualStrings("{\"name\": \"x\"}", p.changes[0].old);
    try std.testing.expectEqualStrings("{\"name\": \"y\"}", p.changes[0].new);

    // The plain fields still work, and mixing the two is fine.
    const mixed =
        \\{"summary":"s","rationale":"r","changes":[
        \\{"file":"src/cli.zig","old":"a","new_b64":"Yg=="}]}
    ;
    const m = try parseProposal(arena, mixed, 10, 4096);
    try std.testing.expectEqualStrings("a", m.changes[0].old);
    try std.testing.expectEqualStrings("b", m.changes[0].new);

    // Garbage base64 is rejected rather than silently patched with nonsense.
    const bad =
        \\{"summary":"s","rationale":"r","changes":[
        \\{"file":"src/cli.zig","old_b64":"!!!not base64!!!","new":"x"}]}
    ;
    try std.testing.expectError(error.BadBase64, parseProposal(arena, bad, 10, 4096));
}
