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
/// Deliberately excludes the evaluation machinery (evals/, improve/,
/// tools/builder.zig) so a single improvement pass cannot weaken its own gate.
pub const allowed_prefixes = [_][]const u8{
    "src/",
    "tools-src/",
    "skills/",
    "tests/",
    "tools/",
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
            if (std.mem.startsWith(u8, path, "evals/")) return false;
            if (std.mem.startsWith(u8, path, "tools/") and !std.mem.endsWith(u8, path, ".tool.json")) return false;
            return true;
        }
    }
    return false;
}

pub fn parseProposal(arena: std.mem.Allocator, raw: []const u8, max_changes: usize, max_change_bytes: usize) !Proposal {
    const v = try json.parseFromSliceLeaky(json.Value, arena, raw, .{ .ignore_unknown_fields = true });
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
                const old = try strField(co, "old");
                const new = try strField(co, "new");
                if (old.len + new.len > max_change_bytes) return error.ChangeTooLarge;
                try list.append(arena, .{ .file = file, .old = old, .new = new });
            }
            p.changes = try list.toOwnedSlice(arena);
        },
        else => return error.ChangesNotArray,
    }
    return p;
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
    try std.testing.expect(validatePath("tools-src/calculator.zig"));
    try std.testing.expect(validatePath("skills/SYSTEM.md"));
    try std.testing.expect(validatePath("tools/calculator.tool.json"));
    try std.testing.expect(validatePath("build.zig"));
    try std.testing.expect(!validatePath("src/evals/runner.zig"));
    try std.testing.expect(!validatePath("src/improve/engine.zig"));
    try std.testing.expect(!validatePath("src/tools/builder.zig"));
    try std.testing.expect(!validatePath("evals/math.task.json"));
    try std.testing.expect(!validatePath("state/foo"));
    try std.testing.expect(!validatePath("tools/calculator.wasm"));
    try std.testing.expect(!validatePath("../etc/passwd"));
    try std.testing.expect(!validatePath("vendor/foo"));
}
