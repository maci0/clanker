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
/// cannot weaken its own gate: `src/evals/`, `src/improve/`, and
/// `src/tools/builder.zig` are denied in `validatePath` (they sit inside the
/// allowed `src/` prefix).
///
/// `evals/` is allowed but append-only (see `isAppendOnly`): a pass may add a
/// new eval, never touch one that exists. Shutting the directory entirely kept
/// the gate honest and also meant the fitness function could never grow, which
/// is a ceiling on how good self-improvement can get.
///
/// `src/improve/` is open except for this file, so a pass can improve the
/// machinery that improves it. What keeps that honest is that the gates are
/// run by the binary already on disk, not by the patched one, plus the staged
/// invariant check in the engine.
pub const allowed_prefixes = [_][]const u8{
    "src/",
    "evals/",
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

/// Paths that may be created but never modified or deleted. The eval suite is
/// the gate a proposal has to pass, so letting a pass rewrite it would let it
/// grade its own work; letting it add to it only ever raises the bar.
pub fn isAppendOnly(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "evals/");
}

/// True if `path` is absolute or has a `..` component. `validatePath` below
/// only ever does a prefix match against `allowed_prefixes`, so without this
/// check `src/../../../etc/passwd` (which starts with `"src/"`) would pass:
/// the engine joins accepted paths onto the staging dir and, at promotion,
/// onto the live tree's cwd directly, so a path that escapes the prefix
/// escapes the repo entirely.
fn hasUnsafeSegment(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return true;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

pub fn validatePath(path: []const u8) bool {
    if (hasUnsafeSegment(path)) return false;
    for (allowed_prefixes) |p| {
        if (std.mem.startsWith(u8, path, p)) {
            // An eval is a task descriptor and nothing else; the runner loads
            // every *.task.json in the directory and would choke on the rest.
            if (std.mem.startsWith(u8, path, "evals/") and !std.mem.endsWith(u8, path, ".task.json")) return false;
            // Fine-grained denials within allowed prefixes.
            if (std.mem.startsWith(u8, path, "src/evals/")) return false;
            // proposal.zig is where the modifiable surface itself is defined:
            // a pass that could edit it could grant itself anything, and no
            // later check would see a violation because the rule would have
            // moved. The rest of src/improve/ is open, guarded by the staged
            // invariants in gate_invariants.
            if (std.mem.eql(u8, path, "src/improve/proposal.zig")) return false;
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

/// `rejected` receives the offending path when the error is PathNotAllowed, so
/// the caller can tell the model which file it may not touch. Without it every
/// retry re-proposed the same path and the run burned all its attempts.
pub fn parseProposal(
    arena: std.mem.Allocator,
    raw: []const u8,
    max_changes: usize,
    max_change_bytes: usize,
    rejected: ?*?[]const u8,
) !Proposal {
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
                    if (rejected) |r| r.* = file;
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
    // Open, so a pass can improve the machinery that improves it; the staged
    // invariant check in the engine is what keeps that from removing a gate.
    try std.testing.expect(validatePath("src/improve/engine.zig"));
    try std.testing.expect(!validatePath("src/improve/proposal.zig"));
    try std.testing.expect(!validatePath("src/tools/builder.zig"));
    // Add-only rather than forbidden; the existence check that keeps it
    // add-only lives in the engine, which can see the tree.
    try std.testing.expect(validatePath("evals/math.task.json"));
    try std.testing.expect(!validatePath("state/foo"));
    try std.testing.expect(!validatePath("tools/manifests/calculator.wasm"));
    try std.testing.expect(!validatePath("tools/bin/calc_ts.wasm"));
    try std.testing.expect(!validatePath("../etc/passwd"));
    try std.testing.expect(!validatePath("vendor/foo"));
    // A path that starts inside an allowed prefix but climbs out of it via
    // `..` must not pass: the engine joins it onto the staging dir and,
    // at promotion, onto the live tree's cwd directly.
    try std.testing.expect(!validatePath("src/../../../etc/passwd"));
    try std.testing.expect(!validatePath("src/foo/../../../etc/passwd"));
    try std.testing.expect(!validatePath("/etc/passwd"));
    try std.testing.expect(!validatePath(""));
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
    const p = try parseProposal(arena, fenced, 40, 32 * 1024, null);
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
    const p = try parseProposal(arena, text, 10, 4096, null);
    try std.testing.expectEqual(@as(usize, 1), p.changes.len);
    try std.testing.expectEqualStrings("{\"name\": \"x\"}", p.changes[0].old);
    try std.testing.expectEqualStrings("{\"name\": \"y\"}", p.changes[0].new);

    // The plain fields still work, and mixing the two is fine.
    const mixed =
        \\{"summary":"s","rationale":"r","changes":[
        \\{"file":"src/cli.zig","old":"a","new_b64":"Yg=="}]}
    ;
    const m = try parseProposal(arena, mixed, 10, 4096, null);
    try std.testing.expectEqualStrings("a", m.changes[0].old);
    try std.testing.expectEqualStrings("b", m.changes[0].new);

    // Garbage base64 is rejected rather than silently patched with nonsense.
    const bad =
        \\{"summary":"s","rationale":"r","changes":[
        \\{"file":"src/cli.zig","old_b64":"!!!not base64!!!","new":"x"}]}
    ;
    try std.testing.expectError(error.BadBase64, parseProposal(arena, bad, 10, 4096, null));
}

test "the eval suite is add-only: new cases allowed, existing ones off limits" {
    // The suite is what grades a proposal, so a pass that could rewrite it
    // would be grading its own work. Adding to it only ever raises the bar.
    try std.testing.expect(validatePath("evals/read_file_large.task.json"));
    try std.testing.expect(isAppendOnly("evals/read_file_large.task.json"));

    // Only task descriptors: the runner loads the whole directory.
    try std.testing.expect(!validatePath("evals/notes.md"));
    try std.testing.expect(!validatePath("evals/helper.zig"));

    // The machinery behind the suite stays shut, and normal source is not
    // accidentally append-only.
    try std.testing.expect(!validatePath("src/evals/scorers.zig"));
    // Open, so a pass can improve the machinery that improves it; the staged
    // invariant check in the engine is what keeps that from removing a gate.
    try std.testing.expect(validatePath("src/improve/engine.zig"));
    try std.testing.expect(!validatePath("src/improve/proposal.zig"));
    try std.testing.expect(!isAppendOnly("src/agent/loop.zig"));
    try std.testing.expect(validatePath("src/agent/loop.zig"));
}

test "a rejected path is reported back so the retry can move on" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text =
        \\{"summary":"s","changes":[{"file":".git/config","old":"a","new":"b"}]}
    ;
    var rejected: ?[]const u8 = null;
    try std.testing.expectError(error.PathNotAllowed, parseProposal(arena, text, 10, 4096, &rejected));
    try std.testing.expectEqualStrings(".git/config", rejected orelse return error.TestExpectedPath);
}
