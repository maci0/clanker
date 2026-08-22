//! Patch-proposal model: the agent proposes edits as exact-match replaces.
//! Only files inside the modifiable surface are accepted.

const std = @import("std");
const json = std.json;
const log = @import("../util/log.zig");
const strField = @import("../util/json.zig").strField;
const config = @import("../config.zig");
const registry = @import("../toolhost/registry.zig");
const runtime = @import("../sandbox/runtime.zig");

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
/// `src/toolhost/builder.zig` are denied in `validatePath` (they sit inside the
/// allowed `src/` prefix).
///
/// `evals/` is allowed but append-only (see `isAppendOnly`): a pass may add a
/// new eval, never touch one that exists. Shutting the directory entirely kept
/// the gate honest and also meant the fitness function could never grow, which
/// is a ceiling on how good self-improvement can get.
///
/// `src/improve/` is fully excluded. A finite set of textual invariants cannot
/// protect every control-flow edge in the machinery that decides whether a
/// patch is promoted, so that machinery cannot rewrite itself in the same
/// pass it is grading.
pub const allowed_prefixes = [_][]const u8{
    "src/",
    "evals/",
    "tools/",
    "ui/",
    "skills/",
    "tests/",
    "docs/",
    "README.md",
    "AGENTS.md",
    "build.zig",
    "build.zig.zon",
    "config.toml",
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
        // A `.` segment resolves to the same directory on the filesystem but
        // is a different string, so `src/./improve/engine.zig` would pass
        // the `src/improve/` deny check while still writing to the denied
        // path. Empty segments (from `//`) have the same property.
        if (std.mem.eql(u8, part, ".")) return true;
        if (part.len == 0) return true;
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
            if (std.mem.startsWith(u8, path, "src/improve/")) return false;
            if (std.mem.eql(u8, path, "src/toolhost/builder.zig")) return false;
            // Descriptors are editable, but only as descriptors: a stray write
            // into tools/manifests/ must not drop a .wasm or anything else the
            // registry would then try to load.
            if (std.mem.startsWith(u8, path, "tools/manifests/") and !std.mem.endsWith(u8, path, ".tool.json")) return false;
            // tools/ts/dist holds committed AssemblyScript build output; it is
            // produced by the TS toolchain, never hand-patched.
            if (std.mem.startsWith(u8, path, "tools/ts/dist/")) return false;
            // ui/vendor/ holds committed third-party JS; never hand-patched.
            // ui/vendor.zig embeds it and is generated — patch ui/vendor.zig only
            // if the vendor file set changes.
            if (std.mem.startsWith(u8, path, "ui/vendor/")) return false;
            return true;
        }
    }
    return false;
}

/// Prefixes a path must match to be *readable* into the improve prompt.
///
/// Wider than the writable surface on purpose: the gate machinery, the roadmap
/// and the ADRs are all worth reading and none of them may be patched. Still a
/// closed list, because a granted path is echoed back into a model request:
/// `.env`, `config.local.*`, `state/` and `.git/` hold API keys, session
/// transcripts and credentials, and none of them match anything here.
/// Repository roots safe to place in an improve prompt. The staging gate uses
/// the same roots, so an allowed proposal and the checks judging it always see
/// the same project inputs.
pub const readable_roots = [_][]const u8{
    "src/",
    "evals/",
    "tools/",
    "ui/",
    "skills/",
    "tests/",
    "docs/",
    // Web-UI data the ui/app/core/*.test.mjs suites read from the repo root:
    // the named-palette tokens (theme/layout) and the slash catalog. These are
    // read + staged but deliberately absent from allowed_prefixes, so the
    // improve loop can judge UI work against the real data without being able
    // to patch it.
    "themes/",
    "commands/",
    "README.md",
    "AGENTS.md",
    "CHANGELOG.md",
    "RELEASES.md",
    "build.zig",
    "build.zig.zon",
    "config.toml",
};

/// Extensions that are text a model can act on. The prefix list alone would
/// admit `tools/manifests/x.wasm` and every other build artifact under an
/// allowed directory.
const readable_extensions = [_][]const u8{ ".zig", ".zon", ".json", ".toml", ".md", ".html", ".js", ".mjs", ".css", ".sh", ".yml" };

/// True when `path` may be read into the improve prompt. Reading is not
/// writing: `validatePath` governs what a patch may change, this governs what
/// the model may ask to see.
pub fn validateReadPath(path: []const u8) bool {
    if (hasUnsafeSegment(path)) return false;
    // Committed build output: bytes, not source, and megabytes of it.
    if (std.mem.startsWith(u8, path, "tools/ts/dist/")) return false;
    var ext_ok = false;
    for (readable_extensions) |e| {
        if (std.mem.endsWith(u8, path, e)) ext_ok = true;
    }
    if (!ext_ok) return false;
    for (readable_roots) |p| {
        if (std.mem.startsWith(u8, path, p)) return true;
    }
    return false;
}

/// The paths a response asks to be shown, when it asks for files instead of
/// proposing a patch: `{"need": ["src/cli.zig"], "reason": "..."}`.
///
/// improve-self shows the model a byte-budgeted slice of a ~3 MB tree and
/// gives it no tools, so the alternative to asking is guessing: an exact-match
/// patch against text it never saw, which fails the match gate every time.
///
/// Returns null unless the response carries a non-empty `need` array *and* no
/// changes, a response that patches and asks is a patch, and answering the
/// question instead would throw the patch away. Paths outside the readable
/// surface are dropped rather than failing the whole request, so the useful
/// ones still get through; `refused` names the first one dropped so the caller
/// can say why.
pub fn parseFileRequest(
    arena: std.mem.Allocator,
    raw: []const u8,
    max_paths: usize,
    refused: ?*?[]const u8,
) !?[]const []const u8 {
    const cleaned = stripMarkdownFence(raw);
    const v = json.parseFromSliceLeaky(json.Value, arena, cleaned, .{ .ignore_unknown_fields = true }) catch return null;
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    if (obj.get("changes")) |c| switch (c) {
        .array => |arr| if (arr.items.len > 0) return null,
        else => {},
    };
    const arr = switch (obj.get("need") orelse return null) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len == 0) return null;

    var out: std.ArrayList([]const u8) = .empty;
    for (arr.items) |item| {
        const p = switch (item) {
            .string => |s| s,
            else => continue,
        };
        if (!validateReadPath(p)) {
            log.log(.warn, "file request: '{s}' is outside the readable surface", .{p});
            if (refused) |r| {
                if (r.* == null) r.* = p;
            }
            continue;
        }
        var seen = false;
        for (out.items) |have| {
            if (std.mem.eql(u8, have, p)) seen = true;
        }
        if (seen) continue;
        try out.append(arena, p);
        if (out.items.len >= max_paths) break;
    }
    return try out.toOwnedSlice(arena);
}

/// Some local models wrap the requested JSON in a markdown code fence
/// (```json ... ```) despite being told not to. Strip an outer fence and any
/// leading/trailing whitespace so the JSON parser sees a bare object.
pub fn stripMarkdownFence(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len >= 3 and std.mem.eql(u8, s[0..3], "```")) {
        if (std.mem.findScalar(u8, s, '\n')) |nl| {
            s = std.mem.trim(u8, s[nl + 1 ..], " \t\r\n");
        }
    }
    if (s.len >= 3 and std.mem.endsWith(u8, s, "```")) {
        s = std.mem.trim(u8, s[0 .. s.len - 3], " \t\r\n");
    }
    return s;
}

/// A summary becomes the improvement commit's subject, and `reverts.git_log_args`
/// hands subjects back to `reverts.parseCommits`, which splits records on 0x1e
/// and fields on 0x1f. Either byte inside a model-written summary (valid JSON as
/// `\u001e`) splits one commit into forged log records: a forged
/// `(revert of <sha>)` record flips another accepted improvement to "reverted"
/// in history, so every later run refuses to rebuild it, and a forged record
/// whose first field is a hex run also corrupts `improvementCommits`. Newlines
/// were already refused because they shift text into the %b body; refuse every
/// control byte for the same reason. A one-line printable subject has no such
/// ambiguity.
fn summaryIsLogSafe(s: []const u8) bool {
    for (s) |c| {
        if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
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
    const summary = try strField(obj, "summary");
    if (summary.len == 0 or !summaryIsLogSafe(summary)) return error.InvalidSummary;
    var p = Proposal{ .summary = summary };
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

// ------------------------------------------------------------------- tests --

/// Applies `changes` under `staging` through the sandboxed `patch_apply` WASM
/// tool (fs_prefixes: ["state/staging"]) instead of a native file-write path.
/// The tool only performs the text edits; the decision to gate and promote the
/// result stays with the caller, native. Shared by the improve engine and the
/// autoresearch loop: both apply this same proposal shape to a staging tree,
/// and a second copy of the encoding is a second thing to keep in step with
/// the tool's input schema.
pub fn applyPatchViaTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    cfg: *const config.Config,
    staging: []const u8,
    changes: []const Change,
) !void {
    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const mod = try runtime.loadNamedTool(gpa, io, arena, environ_map, cfg, &reg, "patch_apply", null);
    defer mod.deinit();

    var enc: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &enc.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("changes");
    try s.beginArray();
    for (changes) |c| {
        const rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ staging, c.file });
        try s.beginObject();
        try s.objectField("file");
        try s.write(rel);
        try s.objectField("old");
        try s.write(c.old);
        try s.objectField("new");
        try s.write(c.new);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();

    const raw = try mod.executeTool(enc.written());
    defer gpa.free(raw);
    const resp = std.json.parseFromSliceLeaky(struct { ok: bool = false, @"error": []const u8 = "" }, arena, raw, .{ .ignore_unknown_fields = true }) catch
        return error.PatchApplyFailed;
    if (!resp.ok) {
        log.log(.error_, "patch_apply tool: {s}", .{resp.@"error"});
        return error.PatchApplyFailed;
    }
}

test "validatePath" {
    try std.testing.expect(validatePath("src/main.zig"));
    try std.testing.expect(validatePath("src/agent/loop.zig"));
    try std.testing.expect(validatePath("tools/zig/calculator.zig"));
    try std.testing.expect(validatePath("skills/SYSTEM.md"));
    try std.testing.expect(validatePath("tools/manifests/calculator.tool.json"));
    try std.testing.expect(validatePath("build.zig"));
    try std.testing.expect(!validatePath("src/evals/runner.zig"));
    try std.testing.expect(!validatePath("src/improve/engine.zig"));
    try std.testing.expect(!validatePath("src/improve/worktree.zig"));
    try std.testing.expect(!validatePath("src/improve/proposal.zig"));
    try std.testing.expect(!validatePath("src/toolhost/builder.zig"));
    // Add-only rather than forbidden; the existence check that keeps it
    // add-only lives in the engine, which can see the tree.
    try std.testing.expect(validatePath("evals/math.task.json"));
    try std.testing.expect(!validatePath("state/foo"));
    try std.testing.expect(!validatePath("tools/manifests/calculator.wasm"));
    try std.testing.expect(!validatePath("tools/ts/dist/calc_ts.wasm"));
    try std.testing.expect(!validatePath("../etc/passwd"));
    try std.testing.expect(!validatePath("vendor/foo"));
    // A path that starts inside an allowed prefix but climbs out of it via
    // `..` must not pass: the engine joins it onto the staging dir and,
    // at promotion, onto the live tree's cwd directly.
    try std.testing.expect(!validatePath("src/../../../etc/passwd"));
    try std.testing.expect(!validatePath("src/foo/../../../etc/passwd"));
    try std.testing.expect(!validatePath("/etc/passwd"));
    try std.testing.expect(!validatePath(""));
    // A `.` segment resolves to the same directory on the filesystem but
    // bypasses the string-prefix deny checks that protect src/improve/ etc.
    try std.testing.expect(!validatePath("src/./improve/engine.zig"));
    try std.testing.expect(!validatePath("src/./evals/runner.zig"));
    try std.testing.expect(!validatePath("src/./gate/checks.zig"));
    try std.testing.expect(!validatePath("tools/./manifests/x.tool.json"));
    // Double-slash produces an empty segment with the same bypass.
    try std.testing.expect(!validatePath("src//improve/engine.zig"));
    try std.testing.expect(!validatePath("src//gate/checks.zig"));
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

test "proposal summary must stay on one line for the improvement commit tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const newline =
        \\{"summary":"safe subject\nbody without tag","changes":[
        \\{"file":"src/cli.zig","old":"a","new":"b"}]}
    ;
    try std.testing.expectError(error.InvalidSummary, parseProposal(arena, newline, 10, 4096, null));

    const empty =
        \\{"summary":"","changes":[
        \\{"file":"src/cli.zig","old":"a","new":"b"}]}
    ;
    try std.testing.expectError(error.InvalidSummary, parseProposal(arena, empty, 10, 4096, null));
}

test "a proposal summary cannot forge git log records" {
    // reverts.parseCommits splits the git-log stream on 0x1e (records) and
    // 0x1f (fields), and both bytes are writable in a JSON string as \uNNNN
    // escapes. A summary carrying either would let one promoted commit pose
    // as several log records, including a fake "(revert of <sha>)" that flips
    // another accepted improvement to reverted in history.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const record_sep =
        \\{"summary":"fine\u001erevert of abc1234def5678","changes":[
        \\{"file":"src/cli.zig","old":"a","new":"b"}]}
    ;
    try std.testing.expectError(error.InvalidSummary, parseProposal(arena, record_sep, 10, 4096, null));

    const field_sep =
        \\{"summary":"ok\u001fdeadbeef1234567","changes":[
        \\{"file":"src/cli.zig","old":"a","new":"b"}]}
    ;
    try std.testing.expectError(error.InvalidSummary, parseProposal(arena, field_sep, 10, 4096, null));

    // Any other control byte is refused too; a one-line subject never needs one.
    const ctrl =
        \\{"summary":"a\u0016b","changes":[
        \\{"file":"src/cli.zig","old":"a","new":"b"}]}
    ;
    try std.testing.expectError(error.InvalidSummary, parseProposal(arena, ctrl, 10, 4096, null));

    // Ordinary printable text, brackets included, still parses: impTag reads
    // the LAST [imp-...] tag, so an earlier bracket pair in a legit summary
    // cannot misdirect it.
    const brackets =
        \\{"summary":"tune [imp-999] thresholds [see docs]","changes":[
        \\{"file":"src/cli.zig","old":"a","new":"b"}]}
    ;
    const ok = try parseProposal(arena, brackets, 10, 4096, null);
    try std.testing.expectEqualStrings("tune [imp-999] thresholds [see docs]", ok.summary);
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
    try std.testing.expect(!validatePath("src/improve/engine.zig"));
    try std.testing.expect(!validatePath("src/improve/worktree.zig"));
    try std.testing.expect(!validatePath("src/improve/proposal.zig"));
    try std.testing.expect(!isAppendOnly("src/agent/loop.zig"));
    try std.testing.expect(validatePath("src/agent/loop.zig"));
}

test "the readable surface is wider than the writable one, and still closed" {
    // Readable but not writable: the gate machinery and the roadmap are what
    // the model most needs to read before changing anything.
    try std.testing.expect(validateReadPath("src/evals/scorers.zig"));
    try std.testing.expect(validateReadPath("src/improve/proposal.zig"));
    try std.testing.expect(validateReadPath("src/toolhost/builder.zig"));
    try std.testing.expect(validateReadPath("docs/ROADMAP.md"));
    try std.testing.expect(validateReadPath("docs/adrs/0003-autoresearch.md"));
    try std.testing.expect(validateReadPath("AGENTS.md"));
    try std.testing.expect(validateReadPath("CHANGELOG.md"));
    try std.testing.expect(validateReadPath("RELEASES.md"));
    try std.testing.expect(validateReadPath("src/cli.zig"));
    try std.testing.expect(validateReadPath("ui/app/index.html"));
    // ES module (.mjs) sources live under ui/ and are writable (ui/ is an
    // allowed_prefix), so the readable surface must admit them too or the
    // model cannot be shown a file it is allowed to patch.
    try std.testing.expect(validateReadPath("ui/app/core/scroll.test.mjs"));
    try std.testing.expect(validateReadPath("ui/app/features/models.test.mjs"));
    try std.testing.expect(validateReadPath("ui/plugins/music/music.test.mjs"));
    try std.testing.expect(validatePath("ui/app/core/scroll.test.mjs"));
    try std.testing.expect(validatePath("ui/app/core/scroll.mjs"));
    try std.testing.expect(validateReadPath("config.toml"));

    // The ui/app/core/*.test.mjs suites read repo-root data (the named
    // palettes, the slash catalog) relative to their own directory. Those
    // roots are readable + staged so the improve loop can judge UI work
    // against the real data, but they are not writable prefixes: data the
    // loop must never hand-patch stays that way.
    try std.testing.expect(validateReadPath("themes/dark.json"));
    try std.testing.expect(validateReadPath("commands/slash.json"));
    try std.testing.expect(!validatePath("themes/dark.json"));
    try std.testing.expect(!validatePath("commands/slash.json"));

    // A granted path is read and echoed straight back into a model request, so
    // the secrets and the run state have to stay out however they are spelled.
    try std.testing.expect(!validateReadPath(".env"));
    try std.testing.expect(!validateReadPath("config.local.toml"));
    try std.testing.expect(!validateReadPath("config.local.json"));
    try std.testing.expect(!validateReadPath("state/token_stats.jsonl"));
    try std.testing.expect(!validateReadPath("state/sessions/a.json"));
    try std.testing.expect(!validateReadPath(".git/config"));
    try std.testing.expect(!validateReadPath("src/../.env"));
    try std.testing.expect(!validateReadPath("/etc/passwd"));
    try std.testing.expect(!validateReadPath(""));

    // Not text, or not source.
    try std.testing.expect(!validateReadPath("tools/manifests/calculator.wasm"));
    try std.testing.expect(!validateReadPath("tools/ts/dist/calc_ts.wasm"));
    try std.testing.expect(!validateReadPath("tools/ts/dist/calc_ts.json"));
    try std.testing.expect(!validateReadPath("vendor/toml/src/root.zig"));
}

test "a response may ask for files instead of proposing a patch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const asked =
        \\{"need":["src/cli.zig","docs/ROADMAP.md"],"reason":"neither is in context"}
    ;
    const want = (try parseFileRequest(arena, asked, 6, null)) orelse return error.TestExpectedRequest;
    try std.testing.expectEqual(@as(usize, 2), want.len);
    try std.testing.expectEqualStrings("src/cli.zig", want[0]);
    try std.testing.expectEqualStrings("docs/ROADMAP.md", want[1]);

    // Fenced, like every other response this loop has to survive.
    const fenced =
        \\```json
        \\{"need":["src/cli.zig"]}
        \\```
    ;
    const f = (try parseFileRequest(arena, fenced, 6, null)) orelse return error.TestExpectedRequest;
    try std.testing.expectEqual(@as(usize, 1), f.len);
}

test "a patch that also asks for files is a patch" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Answering the question would throw the patch away, and the patch is the
    // thing the run exists to produce.
    const both =
        \\{"summary":"s","need":["src/cli.zig"],"changes":[{"file":"src/main.zig","old":"a","new":"b"}]}
    ;
    try std.testing.expect((try parseFileRequest(arena, both, 6, null)) == null);

    // No "need" key at all, an empty one, and a plain patch are all "not a
    // request" rather than an error: this runs before the proposal parser on
    // every single response.
    try std.testing.expect((try parseFileRequest(arena, "{\"need\":[]}", 6, null)) == null);
    try std.testing.expect((try parseFileRequest(arena, "{\"summary\":\"s\",\"changes\":[]}", 6, null)) == null);
    try std.testing.expect((try parseFileRequest(arena, "not json at all", 6, null)) == null);
}

test "a file request is filtered, deduplicated and capped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One path outside the surface must not cost the model the whole request:
    // the good ones still land, and the refusal is reported so the retry knows
    // which one it may not have.
    var refused: ?[]const u8 = null;
    const mixed =
        \\{"need":["src/cli.zig",".env","src/cli.zig","docs/ROADMAP.md"]}
    ;
    const want = (try parseFileRequest(arena, mixed, 6, &refused)) orelse return error.TestExpectedRequest;
    try std.testing.expectEqual(@as(usize, 2), want.len);
    try std.testing.expectEqualStrings("src/cli.zig", want[0]);
    try std.testing.expectEqualStrings("docs/ROADMAP.md", want[1]);
    try std.testing.expectEqualStrings(".env", refused orelse return error.TestExpectedRefusal);

    // A request for everything is capped, not honoured: each granted file is
    // billed on every later call of the run.
    const greedy =
        \\{"need":["src/a.zig","src/b.zig","src/c.zig","src/d.zig","src/e.zig"]}
    ;
    const capped = (try parseFileRequest(arena, greedy, 2, null)) orelse return error.TestExpectedRequest;
    try std.testing.expectEqual(@as(usize, 2), capped.len);

    // Every path refused leaves an empty grant, which is not the same as "not
    // a request": the engine has to answer it rather than parse it as a patch.
    var all_bad: ?[]const u8 = null;
    const bad =
        \\{"need":[".env","state/x.json"]}
    ;
    const none = (try parseFileRequest(arena, bad, 6, &all_bad)) orelse return error.TestExpectedRequest;
    try std.testing.expectEqual(@as(usize, 0), none.len);
    try std.testing.expectEqualStrings(".env", all_bad orelse return error.TestExpectedRefusal);
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

test "fuzz: no byte sequence crashes parseProposal" {
    // The improve loop feeds model output straight into parseProposal: JSON,
    // markdown fences, base64 blobs, and path strings. The property under
    // test is that nothing panics or allocates without bound.
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);
            const input = buf[0..len];

            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            _ = parseProposal(arena_state.allocator(), input, 40, 32 * 1024, null) catch return;
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{});
}
