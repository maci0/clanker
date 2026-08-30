//! Deterministic gate checks for the self-improvement loop. This module is
//! deliberately OUTSIDE the protected surface (src/improve/, src/evals/,
//! src/toolhost/builder.zig) so clanker can keep strengthening these checks.
//! The engine in src/improve/engine.zig calls these and promotes only when
//! every check passes.

const std = @import("std");
const build_options = @import("build_options");
const log = @import("../util/log.zig");
const toml_bridge = @import("../util/toml_bridge.zig");
/// For depPatchesGate's tests, which build a synthetic dependency tree.
const ensure_dir = @import("../util/ensure_dir.zig");
const llm_budget = @import("llm_budget");

/// A cold `zig build test` can print more than one MiB while rebuilding its
/// dependency graph. Gate output is retained only until the result is logged
/// or reduced to an error tail, so this ceiling must accommodate a clean
/// checkout instead of making a healthy gate fail with `StreamTooLong`.
const max_captured_gate_output = 16 << 20;

pub const GateResult = struct {
    ok: bool,
    label: []const u8,
    detail: []const u8 = "",
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},

    pub fn deinit(self: *GateResult, gpa: std.mem.Allocator) void {
        if (self.stdout.len > 0) gpa.free(self.stdout);
        if (self.stderr.len > 0) gpa.free(self.stderr);
    }
};

/// Runs `zig build` (plus `build_args`) in `dir`.
pub fn buildGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, build_args: []const []const u8) !GateResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "zig");
    try argv.append(gpa, "build");
    try argv.append(gpa, "--summary");
    try argv.append(gpa, "all");
    for (build_args) |a| try argv.append(gpa, a);
    return runZigArgs(gpa, io, dir, argv.items, "zig build");
}

/// Runs `zig build test` in `dir`. Deliberately no cache-dir override (unlike
/// toolsGate): several sandbox tests place their tmp roots at the literal
/// relative path ".zig-cache/tmp/...", which only resolves when the test
/// binary runs against the default local cache. The tests phase was measured
/// at ~7-10s with a cold local cache anyway (zig's global cache carries the
/// dependency artifacts), so there is little to win and a real assumption to
/// break.
pub fn testGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !GateResult {
    return runZig(gpa, io, dir, &.{ "build", "test", "--summary", "all" }, "zig build test");
}

/// Runs `zig build tools` (plus `extra_args`) in `dir`.
pub fn toolsGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, extra_args: []const []const u8) !GateResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "zig", "build", "tools", "--summary", "all" });
    for (extra_args) |a| try argv.append(gpa, a);
    return runZigArgs(gpa, io, dir, argv.items, "zig build tools");
}

/// Runs `zig fmt --check` on exactly the files changed by a proposal, so
/// pre-existing formatting debt in untouched files cannot block promotion.
pub fn fmtGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, changed_files: []const []const u8) !GateResult {
    if (changed_files.len == 0) return .{ .ok = true, .label = "zig fmt --check" };
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "zig");
    try argv.append(gpa, "fmt");
    try argv.append(gpa, "--check");
    // Only .zig files can be formatted; json/config descriptors are not Zig.
    for (changed_files) |f| {
        if (std.mem.endsWith(u8, f, ".zig")) try argv.append(gpa, f);
    }
    if (argv.items.len == 3) return .{ .ok = true, .label = "zig fmt --check" };
    return runZigArgs(gpa, io, dir, argv.items, "zig fmt --check");
}

/// Runs `zig fmt` (in place) on the changed .zig files in `dir`, so promoted
/// code is always formatted and the fmt check below is deterministic.
pub fn formatFiles(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, changed_files: []const []const u8) !GateResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "zig");
    try argv.append(gpa, "fmt");
    var any = false;
    for (changed_files) |f| {
        if (std.mem.endsWith(u8, f, ".zig")) {
            try argv.append(gpa, f);
            any = true;
        }
    }
    if (!any) return .{ .ok = true, .label = "zig fmt" };
    return runZigArgs(gpa, io, dir, argv.items, "zig fmt");
}

/// Reads a whole file for a whole-file scan. `readFileAlloc`'s
/// `.limited(cap)` answers `error.StreamTooLong` for any file *over* `cap`,
/// so a fixed cap turns "the tree grew past the cap" into a gate failure on
/// a healthy checkout: src/cli.zig crossed 1 MiB and the lint and
/// provider-kind gates failed on it before the scan saw a single byte. Size
/// the limit from the file itself: files up to the cap read under the cap,
/// anything larger reads under its own size. A stat failure means the file
/// is gone or unreadable, which readFileAlloc would report anyway, so fall
/// through to the cap and let its error stand.
fn readWholeFile(dir: std.Io.Dir, io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const cap: usize = 1 << 20;
    const st = dir.statFile(io, path, .{}) catch return dir.readFileAlloc(io, path, gpa, .limited(cap));
    // The limit errors when *reached or exceeded*, so it must sit one past the
    // size, not on it: `.limited(size)` for a file of exactly `size` bytes is
    // the same StreamTooLong the fixed cap produced.
    return dir.readFileAlloc(io, path, gpa, .limited(@max(st.size, cap) + 1));
}

/// Source-hygiene scan of exactly the files changed by a proposal.
pub fn lintGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, changed_files: []const []const u8) !GateResult {
    // Split so this file does not match its own scan: spelled whole, the
    // needles make lintGate fail on checks.zig every single run.
    const forbidden = [_][]const u8{ "TO" ++ "DO", "FIX" ++ "ME", "HA" ++ "CK", "XX" ++ "X" };
    var hits: usize = 0;
    var hit_buf: [2048]u8 = undefined;
    var hit_w: std.Io.Writer = .fixed(&hit_buf);
    for (changed_files) |f| {
        if (!std.mem.endsWith(u8, f, ".zig")) continue;
        const content = readWholeFile(dir, io, gpa, f) catch |err| {
            // A file the scan cannot read must not pass as clean: a proposal
            // could otherwise promote a change whose forbidden-marker check
            // silently never ran.
            log.log(.warn, "lint: could not read {s}: {s}", .{ f, @errorName(err) });
            return .{ .ok = false, .label = "lint", .detail = "a changed file could not be scanned" };
        };
        defer gpa.free(content);
        for (forbidden) |marker| {
            if (std.mem.find(u8, content, marker) != null) {
                log.log(.warn, "lint: {s} found in {s}", .{ marker, f });
                hit_w.print("{s} in {s}; ", .{ marker, f }) catch {};
                hits += 1;
            }
        }
    }
    if (hits > 0) {
        const written = hit_buf[0..hit_w.end];
        const detail_str = if (written.len > 0) written else "forbidden markers found in changed files";
        // hit_buf is this frame's stack. Callers that read `detail` (the gate
        // CLI prints it) would otherwise get whatever reclaimed the frame, so
        // hand back an owned copy under the same "detail aliases stderr"
        // convention runZigArgs uses, letting deinit free it exactly once.
        const owned = try gpa.dupe(u8, detail_str);
        return .{ .ok = false, .label = "lint", .detail = owned, .stderr = owned };
    }
    return .{ .ok = true, .label = "lint" };
}

test "lintGate flags forbidden markers only in changed .zig files" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "dirty.zig", .data = "// TO" ++ "DO: finish this\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "clean.zig", .data = "const x = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dirty.md", .data = "TO" ++ "DO markers in non-zig files don't count" });

    const clean = try lintGate(gpa, io, tmp.dir, &.{ "clean.zig", "dirty.md" });
    try std.testing.expect(clean.ok);

    var dirty = try lintGate(gpa, io, tmp.dir, &.{"dirty.zig"});
    defer dirty.deinit(gpa);
    try std.testing.expect(!dirty.ok);
    try std.testing.expectEqualStrings("lint", dirty.label);
    // The detail must survive the call: it named a stack buffer before.
    try std.testing.expect(std.mem.find(u8, dirty.detail, "dirty.zig") != null);

    // The other two debt markers must trip the gate too. Split the same way
    // as the forbidden array above: spelled whole, they match this file's
    // own bytes and lintGate fails on itself every run.
    try tmp.dir.writeFile(io, .{ .sub_path = "hacky.zig", .data = "// HA" ++ "CK: quick fix\nconst x = 1;\n" });
    var hacky = try lintGate(gpa, io, tmp.dir, &.{"hacky.zig"});
    defer hacky.deinit(gpa);
    try std.testing.expect(!hacky.ok);
    try std.testing.expectEqualStrings("lint", hacky.label);
}

test "lintGate decides files past the 1 MiB scan cap by their content" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file just over the cap: a fixed-cap read answers StreamTooLong for
    // it, which was the failure shape when src/cli.zig crossed 1 MiB. The
    // clean and dirty shapes must both be decided by the scan itself.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendSlice(gpa, "const filler = 1;\n");
    while (big.items.len <= (1 << 20)) try big.appendSlice(gpa, "const filler2 = 2;\n");

    try tmp.dir.writeFile(io, .{ .sub_path = "big_clean.zig", .data = big.items });
    const clean = try lintGate(gpa, io, tmp.dir, &.{"big_clean.zig"});
    try std.testing.expect(clean.ok);

    try big.appendSlice(gpa, "// TO" ++ "DO: past the cap\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "big_dirty.zig", .data = big.items });
    var dirty = try lintGate(gpa, io, tmp.dir, &.{"big_dirty.zig"});
    defer dirty.deinit(gpa);
    try std.testing.expect(!dirty.ok);
    try std.testing.expect(std.mem.find(u8, dirty.detail, "big_dirty.zig") != null);
}

test "providerKindLeakGate reads files past the 1 MiB scan cap" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    try big.appendSlice(gpa, "const filler = 1;\n");
    while (big.items.len <= (1 << 20)) try big.appendSlice(gpa, "const filler2 = 2;\n");
    // No kind reference anywhere: over-cap but clean.
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/big.zig", .data = big.items });
    const clean = try providerKindLeakGate(gpa, io, tmp.dir, &.{"src/big.zig"});
    try std.testing.expect(clean.ok);
}

/// The provider vtable (`src/llm/providers/`) is the one place `provider.kind`
/// may decide behaviour; the registry exists to abolish kind-switches
/// everywhere else, and the audits re-scan for them by hand. This gate makes
/// that scan deterministic for the two shapes the audits search for: a
/// comparison against a kind tag, or a kind-switch on the provider.
///
/// One comparison is legal and is allowed structurally rather than by path:
/// the proxy's Vertex Gemini model-name sniff, which decides on the *model*
/// name (`isAnthropicModel`), not the kind. Any other kind reference that
/// compares (`==`) or sits inside a `switch (` outside `src/llm/providers/`
/// trips the gate. `forKind(...)` lookups and `@tagName(...)` messages are
/// not kind-switches and pass.
///
/// The scan is conservative about what counts as a kind reference so a
/// neighbour does not trip it: the name must be a word start (`provider.kind`
/// or `p.kind`, not a suffix of `exp.kind`), and a comparison must have the
/// `==` immediately after the `kind` token (a vtable call and an unrelated
/// `==` on the same line is not a kind-switch).
fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

pub fn providerKindLeakGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, files: []const []const u8) !GateResult {
    const needles = [_][]const u8{ "provider.kind", "p.kind" };
    var hits: usize = 0;
    var hit_buf: [4096]u8 = undefined;
    var hit_w: std.Io.Writer = .fixed(&hit_buf);
    for (files) |f| {
        if (!std.mem.endsWith(u8, f, ".zig")) continue;
        // providers/ is the vtable's home; its own kind logic is what this
        // gate protects everywhere else.
        if (std.mem.find(u8, f, "src/llm/providers/") != null) continue;
        const content = readWholeFile(dir, io, gpa, f) catch |err| {
            log.log(.warn, "provider-kind: could not read {s}: {s}", .{ f, @errorName(err) });
            return .{ .ok = false, .label = "provider-kind", .detail = "a changed file could not be scanned" };
        };
        defer gpa.free(content);
        var lines = std.mem.splitScalar(u8, content, '\n');
        var line_no: usize = 1;
        while (lines.next()) |line| : (line_no += 1) {
            var idx: usize = 0;
            while (idx < line.len) {
                var found: ?usize = null;
                var used: usize = 0;
                for (needles) |n| {
                    if (std.mem.findPos(u8, line, idx, n)) |pos| {
                        if (found == null or pos < found.?) {
                            found = pos;
                            used = n.len;
                        }
                    }
                }
                const pos = found orelse break;
                // A kind reference must be a word start, not a suffix of
                // another identifier (exp.kind, myprovider.kind).
                if (pos > 0 and isIdentChar(line[pos - 1])) {
                    idx = pos + used;
                    continue;
                }
                const after = std.mem.trimStart(u8, line[pos + used ..], " \t");
                const compares = std.mem.startsWith(u8, after, "==");
                const switches = std.mem.find(u8, line[0..pos], "switch (") != null;
                if (!compares and !switches) {
                    idx = pos + used;
                    continue;
                }
                // The one legal comparison: the Vertex Gemini model-name
                // sniff, which decides on the model name, not the kind.
                if (std.mem.find(u8, line, "isAnthropicModel") != null) break;
                hit_w.print("{s}:{d}: {s}; ", .{ f, line_no, std.mem.trim(u8, line, " \t") }) catch {};
                hits += 1;
                break;
            }
        }
    }
    if (hits > 0) {
        const written = hit_buf[0..hit_w.end];
        // hit_buf is this frame's stack. Same aliasing convention as lintGate:
        // detail and stderr share one owned copy, freed exactly once by deinit.
        const owned = try gpa.dupe(u8, written);
        return .{ .ok = false, .label = "provider-kind", .detail = owned, .stderr = owned };
    }
    return .{ .ok = true, .label = "provider-kind" };
}

test "providerKindLeakGate: vtable, forKind and tagName pass; comparisons and switches leak" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var providers_dir = try tmp.dir.createDirPathOpen(io, "src/llm/providers", .{});
    defer providers_dir.close(io);
    var serve_dir = try tmp.dir.createDirPathOpen(io, "src/serve", .{});
    defer serve_dir.close(io);
    // A switch on provider.kind inside the vtable dir is exactly where kind
    // logic belongs; it must not trip the gate. The pattern is concatenated
    // so checks.zig's own bytes do not match the gate's needles (the lintGate
    // "TO" ++ "DO" precedent).
    try providers_dir.writeFile(io, .{ .sub_path = "openai.zig", .data = "switch (provider." ++ "kind) { .openai => 1 }\n" });
    // Vtable lookups and tagName messages are not kind-switches.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/cli.zig", .data = "const impl = providers.forKind(provider.kind);\nlog(@tagName(provider.kind));\n" });
    // The proxy's Vertex Gemini model-name sniff is the one legal comparison:
    // it decides on the model name, not the kind.
    try serve_dir.writeFile(io, .{ .sub_path = "proxy.zig", .data = "if (resolved.provider." ++ "kind == .vertex and !vertex.isAnthropicModel(resolved.provider.wireModelName())) {}\n" });

    const clean = try providerKindLeakGate(gpa, io, tmp.dir, &.{ "src/llm/providers/openai.zig", "src/cli.zig", "src/serve/proxy.zig" });
    try std.testing.expect(clean.ok);

    // A comparison outside providers/ leaks, in both the full and short name.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/cli.zig", .data = "if (p." ++ "kind == .vertex) {}\n" });
    var dirty = try providerKindLeakGate(gpa, io, tmp.dir, &.{"src/cli.zig"});
    defer dirty.deinit(gpa);
    try std.testing.expect(!dirty.ok);
    try std.testing.expectEqualStrings("provider-kind", dirty.label);
    try std.testing.expect(std.mem.find(u8, dirty.detail, "src/cli.zig") != null);

    // A switch on provider.kind outside providers/ is the worst leak shape.
    try tmp.dir.writeFile(io, .{ .sub_path = "src/cli.zig", .data = "switch (provider." ++ "kind) { else => {} }\n" });
    var dirty_switch = try providerKindLeakGate(gpa, io, tmp.dir, &.{"src/cli.zig"});
    defer dirty_switch.deinit(gpa);
    try std.testing.expect(!dirty_switch.ok);
}

/// Consistency check over the tool manifests in a staged tree.
///
/// The registry (`src/toolhost/registry.zig`) loads `tools/manifests/*.tool.json`
/// at runtime and never compiles source, so nothing but this check catches a
/// proposal that:
///   - duplicates a tool `name` (the registry's insert is last-wins, so one
///     descriptor silently shadows another), or
///   - points a descriptor at a `.wasm` that does not exist (the exact broken
///     state `clanker doctor` flags as the most common one in this repo).
///
/// It is intentionally pure file/JSON inspection, no npm, no zig build, so
/// it is deterministic and cheap to run for every proposal. The engine runs it
/// after `toolsGate`, by which point `zig-out/tools/*.wasm` exist in the
/// staged tree; `tools/ts/dist/*.wasm` are committed and must be present.
pub fn toolDescriptorGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, tools_dir: []const u8) !GateResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const scope = dir.openDir(io, tools_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .ok = true, .label = "tool-descriptor", .detail = "no tools dir (ok on a minimal checkout)" },
        else => return err,
    };
    defer scope.close(io);

    var names: std.array_hash_map.String(void) = .empty;
    var problems: std.ArrayList([]const u8) = .empty;
    defer problems.deinit(gpa);

    var it = scope.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tool.json")) continue;

        const raw = scope.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch |err| {
            try problems.append(gpa, try std.fmt.allocPrint(arena, "cannot read {s}: {s}", .{ entry.name, @errorName(err) }));
            continue;
        };
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch {
            try problems.append(gpa, try std.fmt.allocPrint(arena, "{s} is not valid JSON", .{entry.name}));
            continue;
        };
        const obj = switch (parsed) {
            .object => |o| o,
            else => {
                try problems.append(gpa, try std.fmt.allocPrint(arena, "{s} is not a JSON object", .{entry.name}));
                continue;
            },
        };

        // Duplicate tool names shadow silently in the registry.
        const name = if (obj.get("name")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";
        if (name.len == 0) {
            try problems.append(gpa, try std.fmt.allocPrint(arena, "{s} has no \"name\"", .{entry.name}));
        } else if (names.contains(name)) {
            try problems.append(gpa, try std.fmt.allocPrint(arena, "duplicate tool name \"{s}\" ({s})", .{ name, entry.name }));
        } else {
            try names.put(arena, name, {});
        }

        // A descriptor pointing at a .wasm we never deliver breaks at runtime.
        if (obj.get("wasm")) |v| switch (v) {
            .string => |rel| {
                if (!fileExistsIn(io, dir, rel)) {
                    try problems.append(gpa, try std.fmt.allocPrint(arena, "{s} references missing {s}", .{ entry.name, rel }));
                }
            },
            else => {
                try problems.append(gpa, try std.fmt.allocPrint(arena, "{s} has no \"wasm\" string", .{entry.name}));
            },
        } else {
            try problems.append(gpa, try std.fmt.allocPrint(arena, "{s} has no \"wasm\" key", .{entry.name}));
        }

        // An `"llm": true` descriptor that grants fewer tokens than a model
        // spends reasoning returns empty content on every call, and returns it
        // as a success: HTTP 200, `finish_reason: "length"`, the whole budget
        // in `reasoning_content`. Nothing downstream can tell that apart from
        // a model with nothing to say, which is how the same bug reached both
        // the compaction summary and the autolearn synthesis. The floor is
        // `llm_budget.reasoning_headroom`; a descriptor that omits the key is
        // not claiming a budget and is left alone.
        const grants_llm = if (obj.get("llm")) |v| v == .bool and v.bool else false;
        if (grants_llm) {
            if (obj.get("config")) |cfg| if (cfg == .object) {
                if (cfg.object.get("max_tokens")) |mt| if (mt == .integer and mt.integer < llm_budget.reasoning_headroom) {
                    try problems.append(gpa, try std.fmt.allocPrint(arena, "{s} grants max_tokens {d}, leaving no room to reason (a thinking model spends the grant on reasoning first and answers with empty content; the floor is {d})", .{ entry.name, mt.integer, llm_budget.reasoning_headroom }));
                };
            };
        }
    }

    if (problems.items.len > 0) {
        // Owned by .stdout so GateResult.deinit frees it; .detail aliases it,
        // matching runZigArgs' convention. A `defer gpa.free(detail)` here
        // freed the text on this very return: every caller (the engine's
        // feedback/history, the test's find) then read freed memory.
        const detail = try std.mem.join(gpa, "; ", problems.items);
        return .{ .ok = false, .label = "tool-descriptor", .detail = detail, .stdout = detail };
    }
    return .{ .ok = true, .label = "tool-descriptor" };
}

/// True when `rel` (e.g. "zig-out/tools/x.wasm") resolves to an existing
/// regular file under `dir`. The wasm paths in descriptors are relative to
/// the repository root (`tools/ts/dist/...`, `zig-out/tools/...`), not to the
/// manifests directory they are declared in.
fn fileExistsIn(io: std.Io, dir: std.Io.Dir, rel: []const u8) bool {
    var f = dir.openFile(io, rel, .{}) catch return false;
    f.close(io);
    return true;
}

/// The engine may hand changed paths with a leading "./" (walkers and
/// git-diff paths differ here). The config/git-manifest guards compare
/// exact paths, so a "./config.toml" spelling would silently bypass them.
fn trimDotSlash(path: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
}

fn isLoadedConfigToml(path: []const u8) bool {
    const p = trimDotSlash(path);
    return std.mem.eql(u8, p, "config.toml") or std.mem.eql(u8, p, "config.local.toml");
}

test "toolDescriptorGate rejects duplicate names and missing wasm" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "manifests");
    try tmp.dir.createDirPath(io, "zig-out/tools");
    // A real wasm so the "missing wasm" case is not tripped by the good file.
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/tools/good.wasm", .data = "{}" });

    try tmp.dir.writeFile(io, .{ .sub_path = "manifests/a.tool.json", .data = "{\"name\":\"dup\",\"wasm\":\"zig-out/tools/good.wasm\"}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "manifests/b.tool.json", .data = "{\"name\":\"dup\",\"wasm\":\"zig-out/tools/missing.wasm\"}" });

    var bad = try toolDescriptorGate(gpa, io, tmp.dir, "manifests");
    defer bad.deinit(gpa);
    try std.testing.expect(!bad.ok);
    try std.testing.expect(std.mem.find(u8, bad.detail, "duplicate tool name") != null);
    try std.testing.expect(std.mem.find(u8, bad.detail, "references missing") != null);

    // Fix both: unique name that points at a real wasm.
    try tmp.dir.writeFile(io, .{ .sub_path = "manifests/b.tool.json", .data = "{\"name\":\"b\",\"wasm\":\"zig-out/tools/good.wasm\"}" });
    const ok = try toolDescriptorGate(gpa, io, tmp.dir, "manifests");
    try std.testing.expect(ok.ok);

    // A tree with no tools dir at all passes (minimal checkout).
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    const none = try toolDescriptorGate(gpa, io, tmp2.dir, "manifests");
    try std.testing.expect(none.ok);
}

test "toolDescriptorGate refuses an llm grant with no room to reason" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "manifests");
    try tmp.dir.createDirPath(io, "zig-out/tools");
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/tools/good.wasm", .data = "{}" });

    // A grant sized for the answer alone: the shape that made every guest
    // report an empty completion on a reasoning model.
    try tmp.dir.writeFile(io, .{ .sub_path = "manifests/t.tool.json", .data = "{\"name\":\"t\",\"wasm\":\"zig-out/tools/good.wasm\",\"llm\":true,\"config\":{\"max_tokens\":256}}" });
    var bad = try toolDescriptorGate(gpa, io, tmp.dir, "manifests");
    defer bad.deinit(gpa);
    try std.testing.expect(!bad.ok);
    try std.testing.expect(std.mem.find(u8, bad.detail, "no room to reason") != null);

    // Content plus the headroom passes.
    try tmp.dir.writeFile(io, .{ .sub_path = "manifests/t.tool.json", .data = "{\"name\":\"t\",\"wasm\":\"zig-out/tools/good.wasm\",\"llm\":true,\"config\":{\"max_tokens\":4352}}" });
    const ok = try toolDescriptorGate(gpa, io, tmp.dir, "manifests");
    try std.testing.expect(ok.ok);

    // Omitting the key is not a violation to report here: the descriptor is
    // not claiming a budget, and the tools that do this reach a model through
    // `ck_subagent`/`ck_swarm` (whole agent turns, budgeted by the harness) or
    // ignore the completion entirely, like the `providers` liveness ping.
    try tmp.dir.writeFile(io, .{ .sub_path = "manifests/t.tool.json", .data = "{\"name\":\"t\",\"wasm\":\"zig-out/tools/good.wasm\",\"llm\":true}" });
    const bare = try toolDescriptorGate(gpa, io, tmp.dir, "manifests");
    try std.testing.expect(bare.ok);

    // A budget on a descriptor with no llm grant is some other tool's setting.
    try tmp.dir.writeFile(io, .{ .sub_path = "manifests/t.tool.json", .data = "{\"name\":\"t\",\"wasm\":\"zig-out/tools/good.wasm\",\"config\":{\"max_tokens\":8}}" });
    const unrelated = try toolDescriptorGate(gpa, io, tmp.dir, "manifests");
    try std.testing.expect(unrelated.ok);
}

/// The zig-spawning tests must hand their Io the real process environment:
/// `Threaded.init` defaults to an empty environ, which strips PATH (so a bare
/// "zig" argv[0] cannot be resolved) and HOME (which version-manager shims
/// like anyzig need to locate their installs). The production Io from
/// `std.process.Init` always carries the process environ, so an empty one
/// tests a child environment the gates never actually run with.
fn testProcessEnviron() std.process.Environ {
    const c_environ = std.c.environ;
    var n: usize = 0;
    while (c_environ[n] != null) : (n += 1) {}
    // c_environ is [*:null]?[*:0]u8; Environ.block.slice wants that same
    // sentinel pointer as a slice. The length is the null we just walked to.
    return .{ .block = .{ .slice = @ptrCast(c_environ[0..n :null]) } };
}

test "fmtGate and formatFiles short-circuit when there is nothing to format" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var empty_result = try fmtGate(gpa, io, tmp.dir, &.{});
    defer empty_result.deinit(gpa);
    try std.testing.expect(empty_result.ok);

    var non_zig_result = try fmtGate(gpa, io, tmp.dir, &.{"config.json"});
    defer non_zig_result.deinit(gpa);
    try std.testing.expect(non_zig_result.ok);

    var format_result = try formatFiles(gpa, io, tmp.dir, &.{"config.json"});
    defer format_result.deinit(gpa);
    try std.testing.expect(format_result.ok);
}

test "fmtGate catches unformatted code and formatFiles fixes it" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = testProcessEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Deliberately unformatted: zig fmt would insert a space before `1`.
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.zig", .data = "const x =1;\n" });

    // Needs a spawnable compiler; skip where there is none (see
    // skipIfNoSpawnableZig) rather than failing on every other machine. The
    // later gate calls don't need the guard: if the first spawn worked, so
    // will the rest.
    var check = fmtGate(gpa, io, tmp.dir, &.{"bad.zig"}) catch |err|
        return skipIfNoSpawnableZig(err);
    defer check.deinit(gpa);
    try std.testing.expect(!check.ok);

    var formatted = try formatFiles(gpa, io, tmp.dir, &.{"bad.zig"});
    defer formatted.deinit(gpa);
    try std.testing.expect(formatted.ok);

    var check2 = try fmtGate(gpa, io, tmp.dir, &.{"bad.zig"});
    defer check2.deinit(gpa);
    try std.testing.expect(check2.ok);
}

/// Rejects a proposal that would add a git command to `exec_pattern_allow` in
/// config files. The config loader refuses such patterns at load time, but a
/// proposal that only touches config.json is still allowed into the staged
/// tree; this gate prevents a config change from silently widening the git
/// deny list.
pub fn gitDenyGuardGate(
    gpa: std.mem.Allocator,
    files: []const []const u8,
    new_texts: []const []const u8,
) GateResult {
    if (files.len != new_texts.len) return .{ .ok = false, .label = "git-deny-guard", .detail = "mismatched files/new_text count" };
    for (files, new_texts) |f, new| {
        if (std.mem.eql(u8, trimDotSlash(f), "tools/manifests/git.tool.json")) {
            return .{ .ok = false, .label = "git-deny-guard", .detail = "proposals must not modify the git tool manifest" };
        }
        // TOML is the canonical (and only loaded) config format; the guard
        // has to inspect exactly what the loader would read, or a proposal
        // widening exec_pattern_allow through config.toml walks straight
        // past a guard still watching the retired .json names.
        if (!isLoadedConfigToml(f)) continue;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = toml_bridge.parseToJsonValue(arena, new) catch {
            return .{ .ok = false, .label = "git-deny-guard", .detail = "config change is not valid TOML" };
        };
        const obj = switch (parsed) {
            .object => |o| o,
            else => continue,
        };
        if (obj.get("agent")) |agent_val| {
            switch (agent_val) {
                .object => |agent_obj| {
                    if (hasGitInExecAllow(agent_obj)) |r| return r;
                    if (isTrue(agent_obj.get("git_remote_ops")))
                        return .{ .ok = false, .label = "git-deny-guard", .detail = "proposals must not enable git_remote_ops" };
                },
                else => {},
            }
        }
        // Root-level check: the proposal's "new" text may lack the [agent]
        // header when the replacement targets a single line.
        if (hasGitInExecAllow(obj)) |r| return r;
        if (isTrue(obj.get("git_remote_ops")))
            return .{ .ok = false, .label = "git-deny-guard", .detail = "proposals must not enable git_remote_ops" };
    }
    return .{ .ok = true, .label = "git-deny-guard" };
}

fn hasGitInExecAllow(obj: std.json.ObjectMap) ?GateResult {
    const epa = obj.get("exec_pattern_allow") orelse return null;
    const arr = switch (epa) {
        .array => |a| a,
        else => return null,
    };
    for (arr.items) |item| {
        const s = switch (item) {
            .string => |str| str,
            else => continue,
        };
        if (std.mem.eql(u8, s, "git") or std.mem.startsWith(u8, s, "git ") or std.mem.startsWith(u8, s, "git\t")) {
            return .{ .ok = false, .label = "git-deny-guard", .detail = "exec_pattern_allow must not name git commands" };
        }
    }
    return null;
}

test "gitDenyGuardGate rejects git patterns in exec_pattern_allow" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const new_texts = [_][]const u8{
        \\agent = { exec_pattern_allow = ["gh pr create*", "git checkout*"] }
    };
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("git-deny-guard", result.label);
    try std.testing.expectEqualStrings("exec_pattern_allow must not name git commands", result.detail);
}

test "gitDenyGuardGate allows non-git patterns and non-config files" {
    const gpa = std.testing.allocator;
    // Non-git pattern passes.
    const files = [_][]const u8{"config.toml"};
    const new_texts = [_][]const u8{
        \\agent = { exec_pattern_allow = ["gh pr create*"] }
    };
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(result.ok);

    // A file that is not config is ignored.
    const files2 = [_][]const u8{"src/main.zig"};
    const new_texts2 = [_][]const u8{"const x = 1;"};
    const result2 = gitDenyGuardGate(gpa, &files2, &new_texts2);
    try std.testing.expect(result2.ok);

    // config.local.toml is checked too.
    const files3 = [_][]const u8{"config.local.toml"};
    const new_texts3 = [_][]const u8{
        \\agent = { exec_pattern_allow = ["git push"] }
    };
    const result3 = gitDenyGuardGate(gpa, &files3, &new_texts3);
    try std.testing.expect(!result3.ok);
}

/// The absolute path of the zig binary the gates shell out to, or null to fall
/// back to a bare "zig".
///
/// `build_options.zig_exe`, the interpreter that built this binary, comes
/// first: it is the right version by construction, and it is absolute, which is
/// what matters here. Every gate runs with `cwd` set to a staging or temp
/// directory, and a bare "zig" is not reliably found from there: on macOS the
/// fmt and ast-check gates failed at *spawn*, before zig ever saw the code they
/// were meant to check, and both of this file's tests failed with it.
fn resolveZigBin(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    const zig_exe = build_options.zig_exe;
    if (zig_exe.len > 0 and zig_exe[0] == '/') {
        std.Io.Dir.accessAbsolute(io, zig_exe, .{ .execute = true }) catch return null;
        return gpa.dupe(u8, zig_exe) catch null;
    }
    return null;
}

test "resolveZigBin finds the zig that built this binary" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Something has to be found, or every gate that shells out is running on
    // the bare-"zig" fallback that does not survive a changed cwd, which is
    // the condition skipIfNoSpawnableZig below exists to tolerate, and which
    // this option is meant to stop happening in the first place.
    const bin = resolveZigBin(gpa, io) orelse return error.TestExpectedZigBin;
    defer gpa.free(bin);
    try std.testing.expect(bin[0] == '/');
}

/// Turns "the compiler could not even be spawned" into a test skip. The
/// tests that exercise a real `zig ast-check`/`zig fmt` run can only do so
/// where resolveZigBin finds a binary: everywhere else the bare "zig" argv
/// is not spawnable (std.process.run resolves it against the gate's cwd, a
/// test tmp dir, there is no PATH search), so the gate cannot run at all
/// and the test should skip, not fail the suite on a machine that was never
/// able to run it. Any other error is a real failure and passes through.
///
/// Retained as the backstop it was written to be: with `build_options.zig_exe`
/// in the list above, resolveZigBin now answers on any machine that still has
/// the build's compiler, so these skips stop firing and the gates they cover
/// are actually exercised.
fn skipIfNoSpawnableZig(err: anyerror) anyerror {
    return switch (err) {
        error.FileNotFound, error.AccessDenied => error.SkipZigTest,
        else => err,
    };
}

fn runZig(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, args: []const []const u8, label: []const u8) !GateResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    const zig_bin = resolveZigBin(gpa, io);
    defer if (zig_bin) |p| gpa.free(p);
    try argv.append(gpa, zig_bin orelse "zig");
    for (args) |a| try argv.append(gpa, a);
    return runZigArgs(gpa, io, dir, argv.items, label);
}

fn runZigArgs(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8, label: []const u8) !GateResult {
    var owned_argv: ?[]const []const u8 = null;
    var owned_zig: ?[]u8 = null;
    defer if (owned_zig) |p| gpa.free(p);
    defer if (owned_argv) |a| gpa.free(a);
    var effective_argv = argv;
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "zig")) {
        if (resolveZigBin(gpa, io)) |abs| {
            owned_zig = abs;
            const copy = gpa.dupe([]const u8, argv) catch null;
            if (copy) |c| {
                c[0] = owned_zig.?;
                owned_argv = c;
                effective_argv = c;
            } else {
                effective_argv = argv;
            }
        }
    }
    const result = try std.process.run(gpa, io, .{
        .argv = effective_argv,
        .cwd = .{ .dir = dir },
        .stdout_limit = .limited(max_captured_gate_output),
        .stderr_limit = .limited(max_captured_gate_output),
    });
    const ok = switch (result.term) {
        .exited => |c| c == 0,
        else => false,
    };
    // Ownership: stdout/stderr move into the GateResult; detail aliases stderr.
    const detail: []const u8 = if (ok) "" else if (result.stderr.len > 0) result.stderr else result.stdout;
    return .{ .ok = ok, .label = label, .detail = detail, .stdout = result.stdout, .stderr = result.stderr };
}

test "gitDenyGuardGate rejects changes to the git tool manifest" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"tools/manifests/git.tool.json"};
    const new_texts = [_][]const u8{"{}"};
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("git-deny-guard", result.label);
    try std.testing.expectEqualStrings("proposals must not modify the git tool manifest", result.detail);
}

test "gitDenyGuardGate normalizes a leading ./ on guarded paths" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"./tools/manifests/git.tool.json"};
    const new_texts = [_][]const u8{"{}"};
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("git-deny-guard", result.label);

    const files2 = [_][]const u8{"./config.toml"};
    const new_texts2 = [_][]const u8{"git_remote_ops = true"};
    const result2 = gitDenyGuardGate(gpa, &files2, &new_texts2);
    try std.testing.expect(!result2.ok);
    try std.testing.expectEqualStrings("git-deny-guard", result2.label);
}

test "gitDenyGuardGate catches a fragment without the [agent] header" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const frag = [_][]const u8{"exec_pattern_allow = [\"git push\"]"};
    const result = gitDenyGuardGate(gpa, &files, &frag);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("git-deny-guard", result.label);
    try std.testing.expectEqualStrings("exec_pattern_allow must not name git commands", result.detail);
}

test "gitDenyGuardGate rejects a tab-separated git pattern" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const new_texts = [_][]const u8{"agent = { exec_pattern_allow = [\"git\tcheckout\"] }"};
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("git-deny-guard", result.label);
    try std.testing.expectEqualStrings("exec_pattern_allow must not name git commands", result.detail);
}

test "gitDenyGuardGate allows a git-prefixed tool that is not the git command" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const new_texts = [_][]const u8{
        \\agent = { exec_pattern_allow = ["git-gh pr create*", "git-status"] }
    };
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(result.ok);
}

test "gitDenyGuardGate rejects git_remote_ops = true in agent section" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const new_texts = [_][]const u8{
        \\[agent]
        \\git_remote_ops = true
    };
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("git-deny-guard", result.label);
    try std.testing.expect(std.mem.find(u8, result.detail, "git_remote_ops") != null);
}

test "gitDenyGuardGate rejects a git_remote_ops fragment without [agent] header" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const frag = [_][]const u8{"git_remote_ops = true"};
    const result = gitDenyGuardGate(gpa, &files, &frag);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("git-deny-guard", result.label);
}

test "gitDenyGuardGate allows git_remote_ops = false" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const new_texts = [_][]const u8{
        \\[agent]
        \\git_remote_ops = false
    };
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(result.ok);
}

test "gitDenyGuardGate rejects an unparseable config file" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const new_texts = [_][]const u8{"agent = { unbalanced"};
    const result = gitDenyGuardGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("git-deny-guard", result.label);
    try std.testing.expect(std.mem.find(u8, result.detail, "valid TOML") != null);
}

/// Rejects a proposal that would weaken the improve loop's own gating by
/// flipping safety-critical config booleans off. The config loader has no
/// opinion on these values (they are all ordinary fields), so a proposal
/// setting `capability_gate = false` passes every other check, gets
/// promoted, and the next run loads it and skips the capability eval gate
/// permanently. This is the only thing that catches it.
pub fn configWeakeningGate(
    gpa: std.mem.Allocator,
    files: []const []const u8,
    new_texts: []const []const u8,
) GateResult {
    if (files.len != new_texts.len) return .{ .ok = false, .label = "config-weakening", .detail = "mismatched files/new_text count" };
    for (files, new_texts) |f, new| {
        // config.toml often omits these keys, so the struct defaults in
        // src/config.zig are what the next run actually loads. A fragment
        // that assigns the disabled value is the same weakening as the TOML
        // form; the full-file check (required defaults still present) lives
        // in configSourceWeakeningGate and is run against the staged file.
        if (std.mem.eql(u8, trimDotSlash(f), "src/config.zig")) {
            if (forbiddenImproveDefault(new)) |detail|
                return .{ .ok = false, .label = "config-weakening", .detail = detail };
            continue;
        }
        if (!isLoadedConfigToml(f)) continue;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const parsed = toml_bridge.parseToJsonValue(arena, new) catch {
            return .{ .ok = false, .label = "config-weakening", .detail = "config change is not valid TOML" };
        };
        const obj = switch (parsed) {
            .object => |o| o,
            else => continue,
        };
        if (obj.get("improve")) |imp_val| {
            switch (imp_val) {
                .object => |imp| {
                    if (weakensImprove(imp)) |r| return r;
                },
                else => {},
            }
        }
        if (obj.get("agent")) |agent_val| {
            switch (agent_val) {
                .object => |agent| {
                    if (weakensAgent(agent)) |r| return r;
                },
                else => {},
            }
        }
        // The proposal's "new" text may be a replacement fragment without
        // the section header, so "capability_gate = false" or
        // "git_commit = false" parses as a root-level key. Check here too
        // or the gate is bypassable by keeping the replacement small.
        if (weakensImprove(obj)) |r| return r;
        if (weakensAgent(obj)) |r| return r;
    }
    return .{ .ok = true, .label = "config-weakening" };
}

fn weakensAgent(obj: std.json.ObjectMap) ?GateResult {
    if (isFalse(obj.get("git_commit")))
        return .{ .ok = false, .label = "config-weakening", .detail = "agent.git_commit must not be disabled" };
    return null;
}

/// The largest value of `max_consecutive_test_only` that still means
/// anything. The engine counts the test-only streak over at most 64 accepted
/// improvements, so a cap above 64 can never fire: it is the disabled gate
/// spelled as a number, and the old "must be positive" check waved it through.
pub const max_consecutive_test_only_cap = 64;

fn weakensImprove(obj: std.json.ObjectMap) ?GateResult {
    if (isFalse(obj.get("capability_gate")))
        return .{ .ok = false, .label = "config-weakening", .detail = "capability_gate must not be disabled" };
    if (isFalse(obj.get("inert_gate")))
        return .{ .ok = false, .label = "config-weakening", .detail = "inert_gate must not be disabled" };
    if (obj.get("max_consecutive_test_only")) |v| {
        switch (v) {
            .integer => |n| if (n <= 0 or n > max_consecutive_test_only_cap)
                return .{ .ok = false, .label = "config-weakening", .detail = "max_consecutive_test_only must be between 1 and 64" },
            else => {},
        }
    }
    if (isFalse(obj.get("plan_phase")))
        return .{ .ok = false, .label = "config-weakening", .detail = "plan_phase must not be disabled" };
    return null;
}

/// The improve-gate defaults and their parser live in `src/config.zig`,
/// which is writable. `config.toml` in this repo does not set the keys, so
/// flipping a default (or inverting the bool parse) disables the gate on
/// the next run without ever touching a file `configWeakeningGate` used to
/// inspect. Run this against the staged file, not a replacement fragment:
/// a one-word `true` -> `false` replace has `new == "false"`.
pub fn configSourceWeakeningGate(src: []const u8) GateResult {
    const required = [_][]const u8{
        "capability_gate: bool = true",
        "inert_gate: bool = true",
        "plan_phase: bool = true",
        "git_commit: bool = true",
        "if (obj.get(\"capability_gate\")) |k| im.capability_gate = switch (k)",
        "if (obj.get(\"inert_gate\")) |k| im.inert_gate = switch (k)",
        "if (obj.get(\"plan_phase\")) |k| im.plan_phase = switch (k)",
    };
    for (required) |need| {
        if (std.mem.find(u8, src, need) == null)
            return .{ .ok = false, .label = "config-weakening", .detail = "src/config.zig must keep improve-gate defaults enabled" };
    }
    if (forbiddenImproveDefault(src)) |detail|
        return .{ .ok = false, .label = "config-weakening", .detail = detail };
    return .{ .ok = true, .label = "config-weakening" };
}

fn forbiddenImproveDefault(src: []const u8) ?[]const u8 {
    const forbidden = [_][]const u8{
        "capability_gate: bool = false",
        "inert_gate: bool = false",
        "plan_phase: bool = false",
        "|b| !b",
    };
    for (forbidden) |needle| {
        if (std.mem.find(u8, src, needle) != null) return needle;
    }
    // The exact `= 0` spelling is subsumed by the range scan below, which
    // also refuses any default above the reachable streak window.
    if (improveDefaultOutOfRange(src)) return "max_consecutive_test_only: u32 = ";
    return null;
}

/// True when any `max_consecutive_test_only: u32 = <n>` declaration in `src`
/// carries an n outside `1..=max_consecutive_test_only_cap`. Zero and huge
/// values are the same weakening as the flipped bools above, spelled as a
/// number no existing needle covered.
fn improveDefaultOutOfRange(src: []const u8) bool {
    const marker = "max_consecutive_test_only: u32 = ";
    var rest = src;
    while (std.mem.find(u8, rest, marker)) |at| {
        var n: usize = 0;
        var digits: usize = 0;
        var j = at + marker.len;
        while (j < rest.len and std.ascii.isDigit(rest[j])) : (j += 1) {
            n = n * 10 + (rest[j] - '0');
            digits += 1;
            if (n > max_consecutive_test_only_cap) return true;
        }
        if (digits > 0 and n == 0) return true;
        rest = rest[at + marker.len ..];
    }
    return false;
}

fn isFalse(v: ?std.json.Value) bool {
    const val = v orelse return false;
    return switch (val) {
        .bool => |b| !b,
        else => false,
    };
}

fn isTrue(v: ?std.json.Value) bool {
    const val = v orelse return false;
    return switch (val) {
        .bool => |b| b,
        else => false,
    };
}

test "configWeakeningGate rejects disabling capability_gate" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const new_texts = [_][]const u8{
        \\[improve]
        \\capability_gate = false
    };
    const result = configWeakeningGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("config-weakening", result.label);
    try std.testing.expect(std.mem.find(u8, result.detail, "capability_gate") != null);
}

test "configWeakeningGate rejects disabling inert_gate" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const new_texts = [_][]const u8{
        \\[improve]
        \\inert_gate = false
    };
    const result = configWeakeningGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("config-weakening", result.label);
}

test "configWeakeningGate rejects zeroing max_consecutive_test_only" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const new_texts = [_][]const u8{
        \\[improve]
        \\max_consecutive_test_only = 0
    };
    const result = configWeakeningGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("config-weakening", result.label);
}

test "configWeakeningGate rejects a max_consecutive_test_only above the streak window" {
    // The engine counts the streak over at most 64 accepted improvements, so
    // a cap above 64 never fires: the disabled gate spelled as a number,
    // invisible to every "must be positive" check.
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const huge = [_][]const u8{
        \\[improve]
        \\max_consecutive_test_only = 1000000
    };
    const result = configWeakeningGate(gpa, &files, &huge);
    try std.testing.expect(!result.ok);

    const over_by_one = [_][]const u8{"max_consecutive_test_only = 65"};
    const result2 = configWeakeningGate(gpa, &files, &over_by_one);
    try std.testing.expect(!result2.ok);

    const boundary = [_][]const u8{"max_consecutive_test_only = 64"};
    const result3 = configWeakeningGate(gpa, &files, &boundary);
    try std.testing.expect(result3.ok);
}

test "configWeakeningGate rejects negative max_consecutive_test_only" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const new_texts = [_][]const u8{
        \\[improve]
        \\max_consecutive_test_only = -1
    };
    const result = configWeakeningGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("config-weakening", result.label);
}

test "configWeakeningGate allows a harmless improve config change" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const new_texts = [_][]const u8{
        \\[improve]
        \\capability_gate = true
        \\max_consecutive_test_only = 5
    };
    const result = configWeakeningGate(gpa, &files, &new_texts);
    try std.testing.expect(result.ok);
}

test "configWeakeningGate catches a fragment without the [improve] header" {
    const gpa = std.testing.allocator;
    // A proposal that replaces just the value line produces "new" text
    // without the [improve] section header. Without the root-level check
    // this parses as a top-level key the gate never inspects.
    const files = [_][]const u8{"config.toml"};
    const frag = [_][]const u8{"capability_gate = false"};
    const result = configWeakeningGate(gpa, &files, &frag);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.find(u8, result.detail, "capability_gate") != null);

    const frag2 = [_][]const u8{"inert_gate = false\nplan_phase = true"};
    const result2 = configWeakeningGate(gpa, &files, &frag2);
    try std.testing.expect(!result2.ok);
    try std.testing.expect(std.mem.find(u8, result2.detail, "inert_gate") != null);

    const frag3 = [_][]const u8{"max_consecutive_test_only = 0"};
    const result3 = configWeakeningGate(gpa, &files, &frag3);
    try std.testing.expect(!result3.ok);

    const frag4 = [_][]const u8{"plan_phase = false"};
    const result4 = configWeakeningGate(gpa, &files, &frag4);
    try std.testing.expect(!result4.ok);
}

test "configWeakeningGate rejects disabling agent.git_commit" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const new_texts = [_][]const u8{
        \\[agent]
        \\git_commit = false
    };
    const result = configWeakeningGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("config-weakening", result.label);
    try std.testing.expect(std.mem.find(u8, result.detail, "git_commit") != null);
}

test "configWeakeningGate catches git_commit fragment without [agent] header" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"config.toml"};
    const frag = [_][]const u8{"git_commit = false"};
    const result = configWeakeningGate(gpa, &files, &frag);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.find(u8, result.detail, "git_commit") != null);
}

test "configWeakeningGate ignores non-config files" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"src/main.zig"};
    const new_texts = [_][]const u8{"const x = 1;"};
    const result = configWeakeningGate(gpa, &files, &new_texts);
    try std.testing.expect(result.ok);
}

test "configWeakeningGate rejects flipping improve defaults in src/config.zig" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"src/config.zig"};
    const flipped = [_][]const u8{"capability_gate: bool = false"};
    const result = configWeakeningGate(gpa, &files, &flipped);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("config-weakening", result.label);

    const invert = [_][]const u8{".bool => |b| !b,"};
    const result2 = configWeakeningGate(gpa, &files, &invert);
    try std.testing.expect(!result2.ok);

    const harmless = [_][]const u8{"fn parseImprove(arena: std.mem.Allocator, v: json.Value) !Improve {"};
    const result3 = configWeakeningGate(gpa, &files, &harmless);
    try std.testing.expect(result3.ok);
}

test "configWeakeningGate normalizes a leading ./ on guarded paths" {
    const gpa = std.testing.allocator;
    const files = [_][]const u8{"./src/config.zig"};
    const new_texts = [_][]const u8{"capability_gate: bool = false"};
    const result = configWeakeningGate(gpa, &files, &new_texts);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("config-weakening", result.label);

    const files2 = [_][]const u8{"./config.toml"};
    const new_texts2 = [_][]const u8{"capability_gate = false"};
    const result2 = configWeakeningGate(gpa, &files2, &new_texts2);
    try std.testing.expect(!result2.ok);
    try std.testing.expectEqualStrings("config-weakening", result2.label);
}

test "the live src/config.zig passes configSourceWeakeningGate" {
    try std.testing.expect(configSourceWeakeningGate(@embedFile("../config.zig")).ok);
}

test "configSourceWeakeningGate requires the enabled defaults and rejects a flip" {
    const good =
        \\capability_gate: bool = true
        \\inert_gate: bool = true
        \\plan_phase: bool = true
        \\git_commit: bool = true
        \\if (obj.get("capability_gate")) |k| im.capability_gate = switch (k) {
        \\if (obj.get("inert_gate")) |k| im.inert_gate = switch (k) {
        \\if (obj.get("plan_phase")) |k| im.plan_phase = switch (k) {
    ;
    try std.testing.expect(configSourceWeakeningGate(good).ok);

    const flipped = good ++ "\ncapability_gate: bool = false\n";
    try std.testing.expect(!configSourceWeakeningGate(flipped).ok);

    const missing =
        \\inert_gate: bool = true
        \\plan_phase: bool = true
        \\git_commit: bool = true
        \\if (obj.get("capability_gate")) |k| im.capability_gate = switch (k) {
        \\if (obj.get("inert_gate")) |k| im.inert_gate = switch (k) {
        \\if (obj.get("plan_phase")) |k| im.plan_phase = switch (k) {
    ;
    try std.testing.expect(!configSourceWeakeningGate(missing).ok);

    const zeroed =
        good ++ "\nmax_consecutive_test_only: u32 = 0\n";
    try std.testing.expect(!configSourceWeakeningGate(zeroed).ok);
}

/// Verifies the AssemblyScript toolchain manifest under `tools/ts/`: one
/// dev-only compiler dependency, no install-time lifecycle scripts, and
/// lockfile integrity fields for supply-chain verification. bun runs
/// lifecycle scripts only for packages listed in `trustedDependencies`, so
/// the absence of that key is what keeps `bun install` inert.
pub fn toolsTsToolchainGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !GateResult {
    const pkg_raw = dir.readFileAlloc(io, "tools/ts/package.json", gpa, .limited(1 << 20)) catch |err| {
        const detail = try std.fmt.allocPrint(gpa, "cannot read tools/ts/package.json: {s}", .{@errorName(err)});
        return .{ .ok = false, .label = "tools-ts-toolchain", .detail = detail };
    };
    defer gpa.free(pkg_raw);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pkg = std.json.parseFromSliceLeaky(std.json.Value, arena, pkg_raw, .{ .ignore_unknown_fields = true }) catch {
        return .{ .ok = false, .label = "tools-ts-toolchain", .detail = "tools/ts/package.json is not valid JSON" };
    };
    const root = switch (pkg) {
        .object => |o| o,
        else => return .{ .ok = false, .label = "tools-ts-toolchain", .detail = "tools/ts/package.json is not a JSON object" },
    };
    if (root.get("trustedDependencies")) |_| {
        return .{ .ok = false, .label = "tools-ts-toolchain", .detail = "tools/ts/package.json must not declare trustedDependencies (bun would run their lifecycle scripts)" };
    }
    if (root.get("dependencies")) |_| {
        return .{ .ok = false, .label = "tools-ts-toolchain", .detail = "tools/ts/package.json must not declare production dependencies" };
    }
    const dev = root.get("devDependencies") orelse {
        return .{ .ok = false, .label = "tools-ts-toolchain", .detail = "tools/ts/package.json has no devDependencies" };
    };
    const dev_obj = switch (dev) {
        .object => |o| o,
        else => return .{ .ok = false, .label = "tools-ts-toolchain", .detail = "tools/ts/package.json devDependencies is not an object" },
    };
    if (dev_obj.count() != 1 or dev_obj.get("assemblyscript") == null) {
        return .{ .ok = false, .label = "tools-ts-toolchain", .detail = "tools/ts/package.json must declare only assemblyscript as a devDependency" };
    }

    const lock = dir.readFileAlloc(io, "tools/ts/bun.lock", gpa, .limited(1 << 20)) catch |err| {
        const detail = try std.fmt.allocPrint(gpa, "cannot read tools/ts/bun.lock: {s}", .{@errorName(err)});
        return .{ .ok = false, .label = "tools-ts-toolchain", .detail = detail };
    };
    defer gpa.free(lock);
    if (std.mem.find(u8, lock, "sha512-") == null) {
        return .{ .ok = false, .label = "tools-ts-toolchain", .detail = "tools/ts/bun.lock is missing registry integrity hashes" };
    }

    return .{ .ok = true, .label = "tools-ts-toolchain" };
}

test "toolsTsToolchainGate accepts the live tools/ts manifest" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const result = try toolsTsToolchainGate(gpa, io, std.Io.Dir.cwd());
    try std.testing.expect(result.ok);
}

/// Keep a Changelog section types a version block may contain. RELEASES.md's
/// release gate groups entries under these headings, one block each, so a
/// repeated heading inside one `## [...]` means the grouping drifted.
const changelog_section_types = [_][]const u8{
    "Breaking", "Added", "Changed", "Deprecated", "Removed", "Fixed", "Security",
};

/// Returns an allocated detail string when any standard `### Section` heading
/// appears more than once inside the same `## [version]` block of the
/// changelog, null otherwise.
fn findDuplicateChangelogSection(gpa: std.mem.Allocator, changelog: []const u8) !?[]const u8 {
    var seen: [changelog_section_types.len][]const u8 = undefined;
    var seen_count: usize = 0;
    var in_block = false;

    var it = std.mem.splitScalar(u8, changelog, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "## [")) {
            seen_count = 0;
            in_block = true;
            continue;
        }
        if (!in_block or !std.mem.startsWith(u8, line, "### ")) continue;
        const title = std.mem.trim(u8, line["### ".len..], " ");
        for (changelog_section_types) |known| {
            if (!std.mem.eql(u8, title, known)) continue;
            var duplicate = false;
            for (seen[0..seen_count]) |s| {
                if (std.mem.eql(u8, s, known)) duplicate = true;
            }
            if (duplicate) {
                return try std.fmt.allocPrint(
                    gpa,
                    "CHANGELOG.md repeats '### {s}' inside one version block; group its entries under the first one",
                    .{known},
                );
            }
            seen[seen_count] = known;
            seen_count += 1;
            break;
        }
    }
    return null;
}

/// Validates the consumer-facing release contract files that must stay aligned
/// with `build.zig.zon` and the policy in RELEASES.md.
pub fn releaseContractGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !GateResult {
    _ = std.SemanticVersion.parse(build_options.version) catch {
        return .{ .ok = false, .label = "release-contract", .detail = "build.zig.zon .version is not valid SemVer" };
    };

    const changelog = dir.readFileAlloc(io, "CHANGELOG.md", gpa, .limited(1 << 20)) catch |err| {
        const detail = try std.fmt.allocPrint(gpa, "cannot read CHANGELOG.md: {s}", .{@errorName(err)});
        return .{ .ok = false, .label = "release-contract", .detail = detail };
    };
    defer gpa.free(changelog);
    if (std.mem.find(u8, changelog, "## [Unreleased]") == null) {
        return .{ .ok = false, .label = "release-contract", .detail = "CHANGELOG.md must have a [Unreleased] section" };
    }
    if (try findDuplicateChangelogSection(gpa, changelog)) |detail| {
        return .{ .ok = false, .label = "release-contract", .detail = detail };
    }

    const readme = dir.readFileAlloc(io, "README.md", gpa, .limited(1 << 20)) catch |err| {
        const detail = try std.fmt.allocPrint(gpa, "cannot read README.md: {s}", .{@errorName(err)});
        return .{ .ok = false, .label = "release-contract", .detail = detail };
    };
    defer gpa.free(readme);
    if (std.mem.find(u8, readme, "CHANGELOG.md") == null)
        return .{ .ok = false, .label = "release-contract", .detail = "README.md must link to CHANGELOG.md" };
    if (std.mem.find(u8, readme, "RELEASES.md") == null)
        return .{ .ok = false, .label = "release-contract", .detail = "README.md must link to RELEASES.md" };

    const releases = dir.readFileAlloc(io, "RELEASES.md", gpa, .limited(1 << 20)) catch |err| {
        const detail = try std.fmt.allocPrint(gpa, "cannot read RELEASES.md: {s}", .{@errorName(err)});
        return .{ .ok = false, .label = "release-contract", .detail = detail };
    };
    defer gpa.free(releases);
    if (std.mem.find(u8, releases, "build.zig.zon") == null)
        return .{ .ok = false, .label = "release-contract", .detail = "RELEASES.md must name build.zig.zon as the version source of truth" };

    return .{ .ok = true, .label = "release-contract" };
}

test "releaseContractGate accepts the live release files" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var result = try releaseContractGate(gpa, io, std.Io.Dir.cwd());
    defer result.deinit(gpa);
    try std.testing.expect(result.ok);
}

test "releaseContractGate rejects a changelog without Unreleased" {
    const bad = "# Changelog\n\n## [0.1.0] - 2026-01-01\n";
    try std.testing.expect(std.mem.find(u8, bad, "## [Unreleased]") == null);
}

test "findDuplicateChangelogSection flags a repeated heading in one version block" {
    const gpa = std.testing.allocator;
    const bad = "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- a\n\n### Fixed\n\n- b\n\n### Added\n\n- c\n";
    const detail = (try findDuplicateChangelogSection(gpa, bad)).?;
    defer gpa.free(detail);
    try std.testing.expect(std.mem.find(u8, detail, "Added") != null);
}

test "findDuplicateChangelogSection allows one heading per type across blocks" {
    const gpa = std.testing.allocator;
    const good = "# Changelog\n\n## [Unreleased]\n\n### Added\n\n- a\n\n### Changed\n\n- b\n" ++
        "\n## [0.1.0] - 2026-08-14\n\n### Added\n\n- c\n\n### Changed\n\n- d\n";
    try std.testing.expectEqual(@as(?[]const u8, null), try findDuplicateChangelogSection(gpa, good));
}

// ------------------------------------------------- test-root coverage gate --

/// True when `src` declares at least one top-level `test` block. Test blocks
/// are always at column zero, so an indented `test` inside a string or a
/// comment does not count.
fn hasTopLevelTest(src: []const u8) bool {
    if (std.mem.startsWith(u8, src, "test ")) return true;
    return std.mem.find(u8, src, "\ntest ") != null;
}

/// True when `src/main.zig` references `rel` (a path relative to `src/`) in
/// its comptime import block. The quotes are part of the needle so
/// `agent/loop.zig` cannot be satisfied by `agent/loop.zig.bak`.
fn rootImports(main_src: []const u8, rel: []const u8) bool {
    var buf: [512]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "@import(\"{s}\")", .{rel}) catch return true;
    return std.mem.find(u8, main_src, needle) != null;
}

/// Strips a leading `./` and then a leading `src/`, returning the path
/// relative to `src/`. Null for anything outside `src/`.
fn relativeToSrc(path: []const u8) ?[]const u8 {
    const p = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
    if (!std.mem.startsWith(u8, p, "src/")) return null;
    return p["src/".len..];
}

/// Zig 0.16 runs `test` blocks only in the root source file, so a module
/// under `src/` that `src/main.zig` never references compiles fine and its
/// tests simply never run. `zig build test` stays green either way, which
/// makes this the one gate failure that cannot be found by running the
/// suite: the missing tests are invisible in its output. Enforcing the
/// convention here is what keeps "add a module, add a line to main.zig" from
/// being a rule only the author of the last module remembers.
pub fn testRootCoverageGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, files: []const []const u8) !GateResult {
    const main_src = dir.readFileAlloc(io, "src/main.zig", gpa, .limited(1 << 20)) catch {
        return .{ .ok = false, .label = "test-root-coverage", .detail = "src/main.zig could not be read" };
    };
    defer gpa.free(main_src);
    return scanForUnrootedTests(gpa, io, dir, files, main_src);
}

/// The gate's body with the root source passed in, so a test can pin the
/// failing verdict against a root that references nothing.
fn scanForUnrootedTests(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, files: []const []const u8, main_src: []const u8) !GateResult {
    var misses: usize = 0;
    var miss_buf: [4096]u8 = undefined;
    var miss_w: std.Io.Writer = .fixed(&miss_buf);
    for (files) |f| {
        if (!std.mem.endsWith(u8, f, ".zig")) continue;
        const rel = relativeToSrc(f) orelse continue;
        if (std.mem.eql(u8, rel, "main.zig")) continue;
        const content = readWholeFile(dir, io, gpa, f) catch |err| {
            log.log(.warn, "test-root-coverage: could not read {s}: {s}", .{ f, @errorName(err) });
            return .{ .ok = false, .label = "test-root-coverage", .detail = "a source file could not be scanned" };
        };
        defer gpa.free(content);
        if (!hasTopLevelTest(content)) continue;
        if (rootImports(main_src, rel)) continue;
        misses += 1;
        miss_w.print("{s}; ", .{rel}) catch {};
    }
    if (misses == 0) return .{ .ok = true, .label = "test-root-coverage" };
    // miss_buf is this frame's stack. Same aliasing convention as lintGate
    // and providerKindLeakGate: detail and stderr share one owned copy, freed
    // exactly once by deinit.
    const owned = try std.fmt.allocPrint(
        gpa,
        "these modules have test blocks that never run; add `_ = @import(\"...\")` for each to the comptime block in src/main.zig: {s}",
        .{miss_w.buffered()},
    );
    return .{ .ok = false, .label = "test-root-coverage", .detail = owned, .stderr = owned };
}

test "hasTopLevelTest only counts test blocks at column zero" {
    try std.testing.expect(hasTopLevelTest("test \"a\" {}\n"));
    try std.testing.expect(hasTopLevelTest("const std = @import(\"std\");\ntest \"a\" {}\n"));
    try std.testing.expect(!hasTopLevelTest("fn f() void {\n    // test \"a\"\n}\n"));
    try std.testing.expect(!hasTopLevelTest("const s = \"latest \";\n"));
}

test "rootImports matches the whole quoted path" {
    const root = "comptime {\n    _ = @import(\"agent/loop.zig\");\n}\n";
    try std.testing.expect(rootImports(root, "agent/loop.zig"));
    try std.testing.expect(!rootImports(root, "agent/loop.zig.bak"));
    try std.testing.expect(!rootImports(root, "loop.zig"));
    try std.testing.expect(!rootImports(root, "agent/session.zig"));
}

test "relativeToSrc accepts walker paths and rejects anything outside src" {
    try std.testing.expectEqualStrings("agent/loop.zig", relativeToSrc("./src/agent/loop.zig").?);
    try std.testing.expectEqualStrings("cli.zig", relativeToSrc("src/cli.zig").?);
    try std.testing.expect(relativeToSrc("./tools/zig/adr.zig") == null);
    try std.testing.expect(relativeToSrc("./tests/e2e/main.zig") == null);
}

test "testRootCoverageGate passes on the live checkout" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const files = [_][]const u8{ "./src/gate/checks.zig", "./src/agent/loop.zig", "./src/cli.zig" };
    var result = try testRootCoverageGate(gpa, io, std.Io.Dir.cwd(), &files);
    defer result.deinit(gpa);
    try std.testing.expect(result.ok);
}

test "testRootCoverageGate names a module whose tests would never run" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // A root that references nothing: this file's own tests are then exactly
    // the untested-module case the gate exists to catch.
    const empty_root = "comptime {}\n";
    const files = [_][]const u8{"./src/gate/checks.zig"};
    var result = try scanForUnrootedTests(gpa, io, std.Io.Dir.cwd(), &files, empty_root);
    defer result.deinit(gpa);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.find(u8, result.detail, "gate/checks.zig") != null);
}

// ------------------------------------------------- js-suite coverage gate --

/// True when `build.zig` hands `rel` to a build step. Every node suite is
/// registered as an `addFileArg(b.path("<rel>"))` on a `bun test` system
/// command, so the quoted path is the registration, and the quotes are part
/// of the needle: `ui/app/core/scroll.test.mjs` cannot be satisfied by
/// `ui/app/core/scroll.test.mjs.bak`.
fn buildRegistersJsSuite(build_src: []const u8, rel: []const u8) bool {
    var buf: [512]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "b.path(\"{s}\")", .{rel}) catch return true;
    return std.mem.find(u8, build_src, needle) != null;
}

/// `zig build test` drives the web UI's node suites by name: one
/// `addSystemCommand(&.{ "bun", "test" })` per `.test.mjs`, listed by hand
/// in `build.zig`. A new suite nobody adds a line for is never run, and the
/// suite output cannot show it — the file is simply not in the list, so the
/// run is green on the tests it does not have. The obvious alternative,
/// pointing node at the directory, is not available: `node --test ui/app/`
/// resolves the positional as a *module* path and dies with
/// `MODULE_NOT_FOUND` on the directory itself (verified on node v24.18.1,
/// docs/reports/bugs/2026-08-22-node-test-dir-mode-fails-on-ui-app.md). The
/// hand-written list is therefore the mechanism, and this gate is what keeps
/// it complete.
pub fn jsSuiteCoverageGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !GateResult {
    const build_src = dir.readFileAlloc(io, "build.zig", gpa, .limited(4 << 20)) catch {
        return .{ .ok = false, .label = "js-suite-coverage", .detail = "build.zig could not be read" };
    };
    defer gpa.free(build_src);
    return scanUnrunJsSuites(gpa, io, dir, build_src);
}

/// The gate's body with the build file's text passed in, so a test can pin
/// the failing verdict against a `build.zig` that registers nothing.
fn scanUnrunJsSuites(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, build_src: []const u8) !GateResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var suites: std.ArrayList([]const u8) = .empty;
    collectJsSuites(io, arena, &suites, dir, "ui") catch |err| switch (err) {
        error.FileNotFound => return .{ .ok = true, .label = "js-suite-coverage", .detail = "no ui/ dir (ok on a minimal checkout)" },
        // A walk error is a failure, never a silent truncation: this gate's
        // whole claim is that it saw every suite on disk.
        else => return .{ .ok = false, .label = "js-suite-coverage", .detail = "ui/ could not be walked" },
    };

    var misses: usize = 0;
    var miss_buf: [4096]u8 = undefined;
    var miss_w: std.Io.Writer = .fixed(&miss_buf);
    for (suites.items) |rel| {
        if (buildRegistersJsSuite(build_src, rel)) continue;
        misses += 1;
        miss_w.print("{s}; ", .{rel}) catch {};
    }
    if (misses == 0) return .{ .ok = true, .label = "js-suite-coverage" };
    // miss_buf is this frame's stack. Same aliasing convention as lintGate
    // and testRootCoverageGate: detail and stderr share one owned copy, freed
    // exactly once by deinit.
    const owned = try std.fmt.allocPrint(
        gpa,
        "these JS suites are never run by `zig build test`; register each in build.zig as an addSystemCommand(&.{{ \"bun\", \"test\" }}) with addFileArg(b.path(\"...\")): {s}",
        .{miss_w.buffered()},
    );
    return .{ .ok = false, .label = "js-suite-coverage", .detail = owned, .stderr = owned };
}

/// Collects every `*.test.mjs` under `dir_path`, recursively, as paths
/// relative to `dir`.
fn collectJsSuites(
    io: std.Io,
    arena: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    dir: std.Io.Dir,
    dir_path: []const u8,
) !void {
    const scope = try dir.openDir(io, dir_path, .{ .iterate = true });
    defer scope.close(io);
    var it = scope.iterate();
    while (try it.next(io)) |entry| {
        // Dot-directories and node_modules are not ours to run; ui/vendor is
        // vendored upstream JS kept as close to upstream as possible.
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "node_modules")) continue;
        if (std.mem.eql(u8, entry.name, "vendor")) continue;
        const sub = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => try collectJsSuites(io, arena, list, dir, sub),
            .file => if (std.mem.endsWith(u8, entry.name, ".test.mjs")) try list.append(arena, sub),
            else => {},
        }
    }
}

test "buildRegistersJsSuite matches the whole quoted path" {
    const src = "    scroll_js_test.addFileArg(b.path(\"ui/app/core/scroll.test.mjs\"));\n";
    try std.testing.expect(buildRegistersJsSuite(src, "ui/app/core/scroll.test.mjs"));
    try std.testing.expect(!buildRegistersJsSuite(src, "ui/app/core/scroll.test.mjs.bak"));
    try std.testing.expect(!buildRegistersJsSuite(src, "ui/app/core/theme.test.mjs"));
    try std.testing.expect(!buildRegistersJsSuite(src, "core/scroll.test.mjs"));
}

test "jsSuiteCoverageGate passes on the live checkout" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var result = try jsSuiteCoverageGate(gpa, io, std.Io.Dir.cwd());
    defer result.deinit(gpa);
    try std.testing.expect(result.ok);
}

test "scanUnrunJsSuites names a suite zig build test would never run" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // A build file that registers nothing: every suite on disk is then
    // exactly the never-run case the gate exists to catch.
    var result = try scanUnrunJsSuites(gpa, io, std.Io.Dir.cwd(), "pub fn build(b: *std.Build) void {}\n");
    defer result.deinit(gpa);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.find(u8, result.detail, ".test.mjs") != null);
}

// ---------------------------------------------- reports inventory gate --

/// The states `reports status` writes. One vocabulary on both sides of the
/// comparison; a word outside it does not parse and is skipped rather than
/// failed (legacy records predate some of these).
const report_statuses = [_][]const u8{ "Open", "Investigating", "Resolved", "Reopened", "Closed" };

/// The stores whose records carry a `## Status` section mirrored into the
/// docs/reports/README.md inventory. Runbooks are current or superseded by
/// their own text and their row carries a summary, not a status, so they are
/// not compared here.
const report_record_dirs = [_][]const u8{ "docs/reports/bugs", "docs/reports/investigations" };

/// Between an inventory row's link and its state word.
const status_separator = " — ";

/// A record states its state in two machine-read places: its own `## Status`
/// section and its row in the docs/reports/README.md inventory. The inventory
/// is the half that gets read (`reports list` and `reports search` render it,
/// not the bodies), so a drifted row hands out finished work as live tasks —
/// exactly what happened on 2026-08-24
/// (docs/reports/bugs/2026-08-24-report-inventory-drifts-from-the-record.md).
/// `reports status` writes both sides in one call, but nothing failed when
/// only one side landed; this gate is that missing failure.
pub fn reportsInventoryGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !GateResult {
    const inventory = dir.readFileAlloc(io, "docs/reports/README.md", gpa, .limited(4 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{ .ok = true, .label = "reports-inventory", .detail = "no reports inventory (ok on a minimal checkout)" },
        else => return .{ .ok = false, .label = "reports-inventory", .detail = "docs/reports/README.md could not be read" },
    };
    defer gpa.free(inventory);
    return scanReportsInventory(gpa, io, dir, inventory);
}

/// The gate's body with the inventory text passed in, so a test can pin the
/// failing verdict against a synthetic README.
fn scanReportsInventory(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, inventory: []const u8) !GateResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var drift: usize = 0;
    var miss_buf: [4096]u8 = undefined;
    var miss_w: std.Io.Writer = .fixed(&miss_buf);
    for (report_record_dirs) |kind_dir| {
        var scope = dir.openDir(io, kind_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return .{ .ok = false, .label = "reports-inventory", .detail = "a reports store directory could not be walked" },
        };
        defer scope.close(io);
        var it = scope.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            if (std.mem.eql(u8, entry.name, "TEMPLATE.md")) continue;
            const record = scope.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch {
                return .{ .ok = false, .label = "reports-inventory", .detail = "a report record could not be read" };
            };
            const word = recordStatusWord(record) orelse continue;
            const row = inventoryStatusFor(inventory, kind_dir, entry.name) orelse {
                drift += 1;
                miss_w.print("{s}/{s}: no inventory row; ", .{ kind_dir, entry.name }) catch {};
                continue;
            };
            if (!std.mem.eql(u8, word, row)) {
                drift += 1;
                miss_w.print("{s}/{s}: record says {s}, row says {s}; ", .{ kind_dir, entry.name, word, row }) catch {};
            }
        }
    }
    if (drift == 0) return .{ .ok = true, .label = "reports-inventory" };
    // miss_buf is this frame's stack. Same aliasing convention as lintGate:
    // detail and stderr share one owned copy, freed once by deinit.
    const owned = try std.fmt.allocPrint(
        gpa,
        "these report records disagree with their docs/reports/README.md inventory row (move state with clanker reports status, not by hand): {s}",
        .{miss_w.buffered()},
    );
    return .{ .ok = false, .label = "reports-inventory", .detail = owned, .stderr = owned };
}

/// The state word a record's `## Status` section opens with, or null when the
/// section is absent or opens with something else ("Resolved on <date>. …"
/// and bare "Open." both parse). Null means skip: the gate compares only what
/// it can parse, so legacy records without the section pass untouched.
pub fn recordStatusWord(record: []const u8) ?[]const u8 {
    const marker = "\n## Status\n";
    const at = std.mem.find(u8, record, marker) orelse return null;
    var lines = std.mem.splitScalar(u8, record[at + marker.len ..], '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        return leadingStatusWord(trimmed);
    }
    return null;
}

/// The state word of the README inventory row linking `<leaf>/<slug>`, where
/// leaf is `kind_dir`'s last component ("bugs", "investigations"), or null
/// when no row links it. The row format is `- [Title](path) — Word`; titles
/// may contain an em dash of their own, which is why parsing starts after the
/// link's closing paren and takes the first separator from there.
pub fn inventoryStatusFor(inventory: []const u8, kind_dir: []const u8, slug: []const u8) ?[]const u8 {
    const leaf = if (std.mem.lastIndexOfScalar(u8, kind_dir, '/')) |slash| kind_dir[slash + 1 ..] else kind_dir;
    var needle_buf: [512]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "]({s}/{s})", .{ leaf, slug }) catch return null;
    var lines = std.mem.splitScalar(u8, inventory, '\n');
    while (lines.next()) |line| {
        // Rows only: a reference to the same file elsewhere in the README
        // must not read as the row.
        if (!std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "- [")) continue;
        const at = std.mem.find(u8, line, needle) orelse continue;
        const rest = line[at + needle.len ..];
        // The separator between link and state; without skipping it the word
        // match would see "— Open".
        const sep = std.mem.find(u8, rest, status_separator) orelse continue;
        return leadingStatusWord(std.mem.trim(u8, rest[sep + status_separator.len ..], " \t"));
    }
    return null;
}

/// The vocabulary word `line` opens with, when the boundary after it is not a
/// word byte ("Opened" is not "Open").
fn leadingStatusWord(line: []const u8) ?[]const u8 {
    for (report_statuses) |s| {
        if (!std.mem.startsWith(u8, line, s)) continue;
        const after = line[s.len..];
        if (after.len == 0 or !std.ascii.isAlphanumeric(after[0])) return s;
    }
    return null;
}

test "reportsInventoryGate passes on the live checkout" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var result = try reportsInventoryGate(gpa, io, std.Io.Dir.cwd());
    defer result.deinit(gpa);
    try std.testing.expect(result.ok);
}

test "scanReportsInventory names a drifted row" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs/reports/bugs");
    try tmp.dir.writeFile(io, .{
        .sub_path = "docs/reports/bugs/2026-01-01-fixed-but-listed-open.md",
        .data = "# Bug — x\n\n## TL;DR\n\n- **Resolution:** fixed.\n\n## Status\n\nResolved on 2026-01-01. Done.\n",
    });
    const readme = "- [Fixed but listed open](bugs/2026-01-01-fixed-but-listed-open.md) — Open\n";
    var result = try scanReportsInventory(gpa, io, tmp.dir, readme);
    defer result.deinit(gpa);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.find(u8, result.detail, "record says Resolved") != null);
    try std.testing.expect(std.mem.find(u8, result.detail, "row says Open") != null);

    // Same tree, honest row: green.
    const honest = "- [Fixed but listed open](bugs/2026-01-01-fixed-but-listed-open.md) — Resolved\n";
    var ok = try scanReportsInventory(gpa, io, tmp.dir, honest);
    defer ok.deinit(gpa);
    try std.testing.expect(ok.ok);
}

test "inventoryStatusFor survives an em dash inside the title" {
    const readme = "- [Bug — a run using the debug tool leaks](bugs/2026-08-23-leak.md) — Open\n" ++
        "See also (bugs/2026-08-23-leak.md) elsewhere.\n";
    try std.testing.expectEqualStrings("Open", inventoryStatusFor(readme, "docs/reports/bugs", "2026-08-23-leak.md").?);
    try std.testing.expectEqual(@as(?[]const u8, null), inventoryStatusFor(readme, "docs/reports/bugs", "2026-08-24-absent.md"));
    try std.testing.expectEqualStrings("Investigating", inventoryStatusFor("- [t](investigations/i.md) — Investigating\n", "docs/reports/investigations", "i.md").?);
}

test "recordStatusWord parses dated and bare statuses, skips records without one" {
    try std.testing.expectEqualStrings("Resolved", recordStatusWord("# Bug\n\n## Status\n\nResolved on 2026-08-23. note\n").?);
    try std.testing.expectEqualStrings("Closed", recordStatusWord("# Inv\n\n## Status\n\nClosed on 2026-01-01.\n").?);
    try std.testing.expectEqualStrings("Open", recordStatusWord("# Bug\n\n## Status\n\nOpen.\n").?);
    try std.testing.expectEqual(@as(?[]const u8, null), recordStatusWord("# Legacy\n\nno status section\n"));
    // A non-vocabulary opener is unparseable, not a false match.
    try std.testing.expectEqual(@as(?[]const u8, null), recordStatusWord("# Bug\n\n## Status\n\nOpened by hand\n"));
}

/// One ceiling in the web UI's first-paint budget.
const WebuiCap = struct {
    path: []const u8,
    limit: usize,
};

/// Per-file ceilings for the heavy movers of the page's eager set; everything
/// smaller is covered by the total below, where growth from many small
/// additions shows up without each file needing its own row to maintain.
/// Limits are raw bytes measured on this tree with ~15% headroom:
/// index.html 74382, app.css 168540, views.css 67831, app.js 252003,
/// patternfly.min.css 625202 (vendored), all as of 2026-08-25. Raising one is
/// a deliberate edit to this table, made with a fresh measurement beside it.
const webui_first_paint_caps = [_]WebuiCap{
    .{ .path = "ui/app/index.html", .limit = 88 * 1024 },
    .{ .path = "ui/app/app.css", .limit = 194 * 1024 },
    .{ .path = "ui/app/views.css", .limit = 78 * 1024 },
    .{ .path = "ui/app/app.js", .limit = 290 * 1024 },
    .{ .path = "ui/vendor/patternfly.min.css", .limit = 720 * 1024 },
};

/// Everything every visitor downloads before any interaction: the document
/// itself plus every `/webui/…` URL its head and body pull eagerly (both
/// stylesheets, the modulepreloads, the eager `<script type="module">` list).
/// PatternFly rides `media="print"`, so it is applied late but still fetched
/// by everyone, which is why it counts here. 1388142 bytes measured across 34
/// resources on 2026-08-25; the budget is that plus ~15%.
const webui_eager_budget_bytes: usize = 1_600_000;

/// The web UI's first-paint budget. Nothing else in the repo stated how large
/// the page's eager download may get, so weight accreted silently: each
/// feature added a section to the document or a module to the script list,
/// and no check ever said when enough was enough. This gate is that
/// statement, and the URL set it measures is parsed out of the shipped
/// `ui/app/index.html` rather than hand-listed, for the same reason
/// js-suite-coverage walks `ui/`: two copies of one list drift.
///
/// This is deliberately raw bytes, not gzip: the budget has to be stable
/// across zlib versions and reproducible without compressing anything, and
/// raw size tracks the wire closely enough to catch accretion, which is its
/// whole job. Latency itself is not gated here — no lab machine speaks for a
/// real phone on LTE — only the bytes a real phone would have to download.
pub fn webuiBudgetGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !GateResult {
    const html = dir.readFileAlloc(io, "ui/app/index.html", gpa, .limited(1 << 20)) catch {
        return .{ .ok = false, .label = "webui-budget", .detail = "ui/app/index.html could not be read" };
    };
    defer gpa.free(html);
    return scanWebuiBudget(gpa, io, dir, html);
}

/// The gate's body with the document passed in, so a test can drive it
/// against a synthetic checkout.
fn scanWebuiBudget(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, index_html: []const u8) !GateResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var urls: std.ArrayList([]const u8) = .empty;
    collectEagerWebuiUrls(arena, index_html, &urls) catch {
        return .{ .ok = false, .label = "webui-budget", .detail = "index.html could not be scanned" };
    };
    if (urls.items.len == 0) {
        return .{ .ok = false, .label = "webui-budget", .detail = "index.html names no /webui/ resources" };
    }

    var problems: usize = 0;
    var miss_buf: [4096]u8 = undefined;
    var miss_w: std.Io.Writer = .fixed(&miss_buf);

    // The document is the one byte set no tag references; count it first.
    var total: usize = index_html.len;
    for (urls.items, 0..) |url, i| {
        // The same URL appears under both a modulepreload and its script tag;
        // the browser fetches it once and so does this count. Only entries
        // before i count: comparing against the whole list would make every
        // URL its own duplicate.
        var dup = false;
        for (urls.items[0..i]) |prev| {
            if (std.mem.eql(u8, prev, url)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        const path = webuiUrlToPath(arena, url) catch {
            return .{ .ok = false, .label = "webui-budget", .detail = "out of memory" };
        };
        const st = dir.statFile(io, path, .{}) catch {
            problems += 1;
            miss_w.print("{s} does not exist (referenced as {s}); ", .{ path, url }) catch {};
            continue;
        };
        total += @intCast(st.size);
        if (webuiFirstPaintCap(path)) |cap| {
            if (st.size > cap.limit) {
                problems += 1;
                miss_w.print("{s} is {d} bytes, cap {d}; ", .{ path, st.size, cap.limit }) catch {};
            }
        }
    }
    if (total > webui_eager_budget_bytes) {
        problems += 1;
        miss_w.print("eager total is {d} bytes, budget {d}; ", .{ total, webui_eager_budget_bytes }) catch {};
    }
    if (problems == 0) return .{ .ok = true, .label = "webui-budget" };
    // miss_buf is this frame's stack. Same aliasing convention as lintGate:
    // detail and stderr share one owned copy, freed exactly once by deinit.
    const owned = try gpa.dupe(u8, miss_w.buffered());
    return .{ .ok = false, .label = "webui-budget", .detail = owned, .stderr = owned };
}

/// Every `/webui/…` URL the shipped page pulls eagerly, from exactly three
/// tag shapes: modulepreload links, stylesheet links (both sheets ride
/// `media="print"` with trailing attributes, so anything may sit around the
/// href), and eager module scripts. The `rel=` needles are matched anywhere
/// so attribute order cannot hide a resource. URLs that do not start
/// `/webui/` are skipped: they are not served by the asset layer this budget
/// describes.
fn collectEagerWebuiUrls(arena: std.mem.Allocator, html: []const u8, urls: *std.ArrayList([]const u8)) !void {
    const needles = [_][]const u8{
        "rel=\"modulepreload\" href=\"",
        "rel=\"stylesheet\" href=\"",
        "<script type=\"module\" src=\"",
    };
    for (needles) |needle| {
        var i: usize = 0;
        while (std.mem.find(u8, html[i..], needle)) |at| {
            const start = i + at + needle.len;
            const end_rel = std.mem.findScalar(u8, html[start..], '"') orelse break;
            const url = html[start .. start + end_rel];
            if (std.mem.startsWith(u8, url, "/webui/")) try urls.append(arena, url);
            i = start + end_rel + 1;
        }
    }
}

/// Request path to repo path. Vendored files route differently than
/// first-party ones (`isVendorFile` serves them from `ui/vendor/`), so the
/// mapping mirrors that split.
fn webuiUrlToPath(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    const rest = url["/webui/".len..];
    if (std.mem.startsWith(u8, rest, "vendor/")) return std.fmt.allocPrint(arena, "ui/{s}", .{rest});
    return std.fmt.allocPrint(arena, "ui/app/{s}", .{rest});
}

fn webuiFirstPaintCap(path: []const u8) ?WebuiCap {
    for (webui_first_paint_caps) |cap| {
        if (std.mem.eql(u8, cap.path, path)) return cap;
    }
    return null;
}

test "collectEagerWebuiUrls takes the three tag shapes, dedupes, and skips foreign URLs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var urls: std.ArrayList([]const u8) = .empty;
    const html =
        \\<link rel="modulepreload" href="/webui/app.js">
        \\<link rel="stylesheet" href="/webui/app.css" media="print" data-pf="1">
        \\<noscript><link rel="stylesheet" href="/webui/views.css"></noscript>
        \\<link rel="icon" href="data:image/svg+xml,xxx">
        \\<script type="module" src="/webui/app.js"></script>
        \\<script type="module" src="/webui/core/utils.js"></script>
    ;
    try collectEagerWebuiUrls(arena, html, &urls);
    try std.testing.expectEqual(@as(usize, 5), urls.items.len);
    // app.js appears twice (modulepreload + script tag) and the data: favicon
    // not at all; both folds land in the deduped eager count.
    var unique: usize = 0;
    for (urls.items, 0..) |_, i| {
        var earlier = false;
        for (urls.items[0..i]) |prev| {
            if (std.mem.eql(u8, prev, urls.items[i])) earlier = true;
        }
        if (!earlier) unique += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), unique);
}

test "scanWebuiBudget names an over-cap file and a missing reference" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ui/app");
    // Over the views.css cap (78 KiB) but nowhere near the eager total, so
    // the failure can only be the per-file one.
    const big = try gpa.alloc(u8, 80 * 1024);
    defer gpa.free(big);
    @memset(big, 'a');
    try tmp.dir.writeFile(io, .{ .sub_path = "ui/app/views.css", .data = big });
    const html =
        \\<link rel="stylesheet" href="/webui/views.css">
        \\<script type="module" src="/webui/core/gone.js"></script>
    ;
    var result = try scanWebuiBudget(gpa, io, tmp.dir, html);
    defer result.deinit(gpa);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.find(u8, result.detail, "ui/app/views.css is ") != null);
    try std.testing.expect(std.mem.find(u8, result.detail, "ui/app/core/gone.js does not exist") != null);
}

test "scanWebuiBudget passes a synthetic tree whose every file is tiny" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "ui/app/core");
    try tmp.dir.writeFile(io, .{ .sub_path = "ui/app/core/utils.js", .data = "export {};" });
    const html = "\\<script type=\"module\" src=\"/webui/core/utils.js\"></script>";
    var result = try scanWebuiBudget(gpa, io, tmp.dir, html);
    defer result.deinit(gpa);
    try std.testing.expect(result.ok);
}

test "webuiBudgetGate passes on the live checkout" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var result = try webuiBudgetGate(gpa, io, std.Io.Dir.cwd());
    defer result.deinit(gpa);
    try std.testing.expect(result.ok);
}

/// Every capability a sandboxed WASM guest can reach is a `pub fn ck…` in
/// `src/sandbox/host.zig` that `src/sandbox/runtime.zig` hands to the zwasm
/// linker. A host function nobody registers is not a capability waiting to be
/// granted: it is unreachable. No guest can import it, no descriptor can name
/// it, and nothing compiles it, so it rots against zwasm API changes in
/// silence while reading like a live part of the ABI. `zig build` stays green
/// either way, which is why this is a gate and not something a test can find.
pub fn sandboxAbiGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !GateResult {
    const host_src = dir.readFileAlloc(io, "src/sandbox/host.zig", gpa, .limited(8 << 20)) catch {
        return .{ .ok = false, .label = "sandbox-abi", .detail = "src/sandbox/host.zig could not be read" };
    };
    defer gpa.free(host_src);
    const runtime_src = dir.readFileAlloc(io, "src/sandbox/runtime.zig", gpa, .limited(8 << 20)) catch {
        return .{ .ok = false, .label = "sandbox-abi", .detail = "src/sandbox/runtime.zig could not be read" };
    };
    defer gpa.free(runtime_src);
    return scanUnregisteredHostFns(gpa, host_src, runtime_src);
}

/// The gate's body with both sources passed in, so a test can drive it
/// without a checkout.
fn scanUnregisteredHostFns(gpa: std.mem.Allocator, host_src: []const u8, runtime_src: []const u8) !GateResult {
    const decl = "pub fn ck";
    var misses: usize = 0;
    var miss_buf: [4096]u8 = undefined;
    var miss_w: std.Io.Writer = .fixed(&miss_buf);

    var lines = std.mem.splitScalar(u8, host_src, '\n');
    while (lines.next()) |line| {
        // Column zero only: an indented `pub fn ck…` is a method on some
        // struct, not a host function the linker could ever see.
        if (!std.mem.startsWith(u8, line, decl)) continue;
        const name_start = decl.len - "ck".len;
        const rest = line[name_start..];
        var end: usize = 0;
        while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
        const name = rest[0..end];
        if (name.len == 0) continue;
        if (registeredInRuntime(runtime_src, name)) continue;
        misses += 1;
        miss_w.print("{s}; ", .{name}) catch {};
    }

    if (misses == 0) return .{ .ok = true, .label = "sandbox-abi" };
    // miss_buf is this frame's stack. Same aliasing convention as lintGate
    // and providerKindLeakGate: detail and stderr share one owned copy, freed
    // exactly once by deinit.
    const owned = try std.fmt.allocPrint(
        gpa,
        "these host functions are never registered with the zwasm linker, so no guest can reach them; register them in src/sandbox/runtime.zig or delete them: {s}",
        .{miss_w.buffered()},
    );
    return .{ .ok = false, .label = "sandbox-abi", .detail = owned, .stderr = owned };
}

/// True when `runtime_src` names `host.<name>` as a whole identifier. The
/// trailing-character check is what keeps `host.ckFs` from matching the
/// registration of `host.ckFsRead`.
fn registeredInRuntime(runtime_src: []const u8, name: []const u8) bool {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "host.{s}", .{name}) catch return true;
    var from: usize = 0;
    while (std.mem.find(u8, runtime_src[from..], needle)) |rel| {
        const at = from + rel;
        const after = at + needle.len;
        if (after >= runtime_src.len) return true;
        const c = runtime_src[after];
        if (!std.ascii.isAlphanumeric(c) and c != '_') return true;
        from = at + 1;
    }
    return false;
}

test "registeredInRuntime matches a whole identifier, not a prefix" {
    const src = "&host.ckFsRead);\n&host.ckLog);\n";
    try std.testing.expect(registeredInRuntime(src, "ckFsRead"));
    try std.testing.expect(registeredInRuntime(src, "ckLog"));
    try std.testing.expect(!registeredInRuntime(src, "ckFs"));
    try std.testing.expect(!registeredInRuntime(src, "ckDocker"));
}

test "scanUnregisteredHostFns names an unreachable host function" {
    const gpa = std.testing.allocator;
    const host_src =
        \\pub fn ckLog(caller: *zwasm.Caller) void {}
        \\pub fn ckOrphan(caller: *zwasm.Caller) u32 {}
        \\    pub fn ckNested(self: *Foo) void {}
        \\
    ;
    const runtime_src = "try lk.defineFuncCtx(\"env\", \"ck_log\", h, T, &host.ckLog);\n";

    var result = try scanUnregisteredHostFns(gpa, host_src, runtime_src);
    defer result.deinit(gpa);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("sandbox-abi", result.label);
    try std.testing.expect(std.mem.find(u8, result.detail, "ckOrphan") != null);
    // Indented declarations are struct methods, never linker entries.
    try std.testing.expect(std.mem.find(u8, result.detail, "ckNested") == null);
    try std.testing.expect(std.mem.find(u8, result.detail, "ckLog") == null);
}

test "sandboxAbiGate passes on the live checkout" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var result = try sandboxAbiGate(gpa, io, std.Io.Dir.cwd());
    defer result.deinit(gpa);
    try std.testing.expect(result.ok);
}

/// `patches/` holds four local fixes to the pinned upstream dependencies,
/// applied by hand into `zig-pkg/` -- the per-project package directory
/// `zig` 0.16 extracts dependencies into, and one `.gitignore` lists. So a
/// `git worktree add` starts with no dependency cache at all, `zig build`
/// extracts pristine upstream tarballs, and `scripts/apply-patches.sh` is
/// called by nothing: not by `build.zig`, not by any other gate. The whole
/// suite then went green on pristine vaxis and zwasm without a word, which is
/// strictly less code than the same commit covers in a patched checkout --
/// `sixel_supported` in `src/tui/mascot.zig` compiles the sixel path out, and
/// the REPL services SIGWINCH inside the signal handler, the exact thing
/// `patches/vaxis-winch-self-pipe.patch` and `pty_resize_test` exist to
/// prevent. The repository rules put every agent session in a hand-made
/// worktree, so unpatched is the DEFAULT state for agent work.
///
/// Nothing here applies a patch. Mutating a dependency cache as a side effect
/// of a check trades a visible failure for an invisible one; this only reports.
///
/// The ordering trap is why the failure names the script: on a tree that has
/// never been built there is nothing to patch yet, so the intuitive
/// patch-then-build order reports "0 applied" and leaves the tree pristine.
/// A `zig build` has to extract the dependencies first, and only then does
/// `scripts/apply-patches.sh` do any work.
pub fn depPatchesGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !GateResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zon = dir.readFileAlloc(io, "build.zig.zon", arena, .limited(1 << 20)) catch {
        return .{ .ok = false, .label = "dep-patches", .detail = "build.zig.zon could not be read" };
    };

    var names: std.ArrayList([]const u8) = .empty;
    {
        const patches_dir = dir.openDir(io, dep_patches_dir, .{ .iterate = true }) catch {
            return .{ .ok = false, .label = "dep-patches", .detail = "patches/ could not be opened" };
        };
        defer patches_dir.close(io);
        var it = patches_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".patch")) continue;
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    // Zero is a failure, not a vacuous pass: this check's whole job is to
    // speak about patches, and it cannot do that from an empty directory.
    if (names.items.len == 0) {
        return .{ .ok = false, .label = "dep-patches", .detail = "patches/ holds no .patch files, so this check would verify nothing" };
    }
    // Deterministic order, so the failure message reads the same twice.
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var miss_buf: [4096]u8 = undefined;
    var miss_w: std.Io.Writer = .fixed(&miss_buf);
    var misses: usize = 0;

    for (names.items) |name| {
        const pkg = depPackageOf(name);
        // The extracted tree is named by the `.hash` field verbatim, so
        // reading the pin is what keeps this check right across a version
        // bump -- and what keeps a stale `zwasm-2.4.1-*` tree left behind by
        // an older pin from being mistaken for the current one.
        const hash = depHashFor(zon, pkg) orelse {
            misses += 1;
            miss_w.print("{s} names no dependency in build.zig.zon; ", .{name}) catch {};
            continue;
        };
        const patch_src = dir.readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dep_patches_dir, name }), arena, .limited(8 << 20)) catch {
            misses += 1;
            miss_w.print("{s} could not be read; ", .{name}) catch {};
            continue;
        };
        const markers = try patchMarkers(arena, patch_src);
        if (markers.len == 0) {
            misses += 1;
            miss_w.print("{s} yields no marker long enough to look for, so it cannot be verified; ", .{name}) catch {};
            continue;
        }
        for (markers) |m| {
            const target = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ dep_pkg_dir, hash, m.file });
            const body = dir.readFileAlloc(io, target, arena, .limited(16 << 20)) catch {
                misses += 1;
                miss_w.print("{s} -> {s} is not there to patch; ", .{ name, target }) catch {};
                continue;
            };
            if (std.mem.find(u8, body, m.text) == null) {
                misses += 1;
                miss_w.print("{s} is not applied to {s}; ", .{ name, target }) catch {};
            }
        }
    }

    if (misses == 0) return .{ .ok = true, .label = "dep-patches" };
    // Same aliasing convention as lintGate and sandboxAbiGate: detail and
    // stderr share one owned copy, freed exactly once by deinit.
    const owned = try std.fmt.allocPrint(
        gpa,
        "the dependency trees under {s}/ are missing local patches, so this tree builds and tests against pristine upstream code. Run `zig build` (to extract the dependencies) and then `scripts/apply-patches.sh`: {s}",
        .{ dep_pkg_dir, miss_w.buffered() },
    );
    return .{ .ok = false, .label = "dep-patches", .detail = owned, .stderr = owned };
}

const dep_patches_dir = "patches";

/// Where `zig` 0.16 extracts dependencies for this project. Gitignored, hence
/// per-worktree, hence the whole problem.
const dep_pkg_dir = "zig-pkg";

/// The package a patch belongs to: everything before the first `-` in its
/// file name, so `vaxis-winch-self-pipe.patch` is a vaxis patch. Matches the
/// naming `scripts/apply-patches.sh` and `patches/README.md` already use.
fn depPackageOf(patch_name: []const u8) []const u8 {
    const stem = patch_name[0 .. patch_name.len - ".patch".len];
    const dash = std.mem.find(u8, stem, "-") orelse return stem;
    return stem[0..dash];
}

/// The `.hash` pin whose value names `pkg`, which is verbatim the directory
/// name the package is extracted into.
fn depHashFor(zon: []const u8, pkg: []const u8) ?[]const u8 {
    const key = ".hash = \"";
    var from: usize = 0;
    while (std.mem.find(u8, zon[from..], key)) |rel| {
        const start = from + rel + key.len;
        const end = std.mem.find(u8, zon[start..], "\"") orelse return null;
        const value = zon[start .. start + end];
        from = start + end;
        if (!std.mem.startsWith(u8, value, pkg)) continue;
        if (value.len <= pkg.len or value[pkg.len] != '-') continue;
        return value;
    }
    return null;
}

const PatchMarker = struct { file: []const u8, text: []const u8 };

/// A marker has to be long enough that finding it in a pristine file is not
/// plausible. Short additions (`}`, a blank line, `};`) occur all over every
/// file a patch touches.
const min_patch_marker_len = 24;

/// One marker per file a patch touches: the longest RUN of consecutive lines
/// that patch adds to it, rejoined exactly as they will appear in the patched
/// file (indentation and interior blank lines included), so the check is a
/// plain substring search.
///
/// `apply-patches.sh` decides "already applied" with a reverse dry-run of the
/// whole patch. A gate check cannot shell out to `patch` for that -- it would
/// then be reporting on a tool that need not be installed -- and an added
/// block is the cheapest thing that is present in a patched tree and absent
/// from a pristine one.
///
/// A run rather than the single longest added LINE, which was the first
/// version and was wrong: `patches/vaxis-ss3-keypad-enter.patch`'s longest
/// added line is `const expected_event: Event = .{ .key_press = expected_key
/// };`, a line every other parser test in that file already has, so the check
/// reported that patch applied on a pristine tree. A whole added block can be
/// duplicated in principle too, but a 13-line one is not an accident.
///
/// Files whose longest run is under `min_patch_marker_len` are skipped rather
/// than guessed at; a patch where that leaves NO markers at all is reported by
/// the caller, since a check that silently verifies nothing is the shape of
/// problem this one exists for.
fn patchMarkers(arena: std.mem.Allocator, patch_src: []const u8) ![]PatchMarker {
    var out: std.ArrayList(PatchMarker) = .empty;
    var file: []const u8 = "";
    var best: []const u8 = "";
    var run: std.ArrayList(u8) = .empty;
    defer run.deinit(arena);

    var lines = std.mem.splitScalar(u8, patch_src, '\n');
    while (lines.next()) |line| {
        // `+++ ` opens the next file; `+++` with no path, and any other
        // non-addition, just ends the current run.
        const added: ?[]const u8 = if (line.len >= 1 and line[0] == '+' and !std.mem.startsWith(u8, line, "+++"))
            // Only the trailing CR the '\n' split leaves behind: the leading
            // whitespace IS the indentation the patched file will carry.
            std.mem.trimEnd(u8, line[1..], "\r")
        else
            null;
        if (added) |text| {
            if (run.items.len > 0) try run.append(arena, '\n');
            try run.appendSlice(arena, text);
            continue;
        }
        if (run.items.len > best.len) best = try arena.dupe(u8, run.items);
        run.clearRetainingCapacity();
        if (!std.mem.startsWith(u8, line, "+++ ")) continue;
        if (file.len > 0 and best.len >= min_patch_marker_len) try out.append(arena, .{ .file = file, .text = best });
        file = patchTargetPath(line["+++ ".len..]);
        best = "";
    }
    // Duped, not aliased: `run`'s buffer is freed back to the arena on the
    // way out, and an arena's free of its most recent allocation really does
    // hand those bytes to whatever the CALLER allocates next.
    if (run.items.len > best.len) best = try arena.dupe(u8, run.items);
    if (file.len > 0 and best.len >= min_patch_marker_len) try out.append(arena, .{ .file = file, .text = best });
    return out.toOwnedSlice(arena);
}

/// The path a `+++` header names, relative to the dependency tree root, which
/// is what `patch -p1` strips to. Empty for `/dev/null` (a deletion) and for a
/// header with nothing after the marker, both of which have no file to check.
fn patchTargetPath(rest: []const u8) []const u8 {
    // Trailing tab-separated timestamp, when the diff carries one.
    var path = rest;
    if (std.mem.find(u8, path, "\t")) |tab| path = path[0..tab];
    path = std.mem.trim(u8, path, " \r");
    if (std.mem.eql(u8, path, "/dev/null")) return "";
    const slash = std.mem.find(u8, path, "/") orelse return path;
    return path[slash + 1 ..];
}

test "patchTargetPath strips the -p1 prefix and rejects a deletion" {
    try std.testing.expectEqualStrings("src/tty.zig", patchTargetPath("b/src/tty.zig"));
    try std.testing.expectEqualStrings("src/tty.zig", patchTargetPath("a/src/tty.zig"));
    try std.testing.expectEqualStrings("src/tty.zig", patchTargetPath("b/src/tty.zig\t2026-08-23 12:00:00"));
    try std.testing.expectEqualStrings("", patchTargetPath("/dev/null"));
}

test "depHashFor reads the pin that names a package, not a prefix of one" {
    const zon =
        \\.{
        \\    .dependencies = .{
        \\        .zwasm = .{ .hash = "zwasm-2.5.0-FT1Fv4KPkgCa" },
        \\        .vaxis = .{ .hash = "vaxis-0.6.0-BWNV_KwYCgB" },
        \\    },
        \\}
    ;
    try std.testing.expectEqualStrings("vaxis-0.6.0-BWNV_KwYCgB", depHashFor(zon, "vaxis").?);
    try std.testing.expectEqualStrings("zwasm-2.5.0-FT1Fv4KPkgCa", depHashFor(zon, "zwasm").?);
    // A package name that is only a prefix of a pinned one must not match:
    // `zwas` is not `zwasm`, and answering the zwasm tree for it would check
    // the wrong files.
    try std.testing.expect(depHashFor(zon, "zwas") == null);
    try std.testing.expect(depHashFor(zon, "zigimg") == null);
}

test "depPackageOf takes the package name off a patch file name" {
    try std.testing.expectEqualStrings("vaxis", depPackageOf("vaxis-winch-self-pipe.patch"));
    try std.testing.expectEqualStrings("zwasm", depPackageOf("zwasm-lazy-mem-cksum.patch"));
    try std.testing.expectEqualStrings("solo", depPackageOf("solo.patch"));
}

test "patchMarkers takes the longest added run per file and skips short ones" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const patch =
        \\diff --git a/src/tty.zig b/src/tty.zig
        \\--- a/src/tty.zig
        \\+++ b/src/tty.zig
        \\@@ -1,3 +1,6 @@
        \\ const std = @import("std");
        \\+    a lonely addition that is long on its own
        \\ context breaks the run
        \\+    self.winch_pipe = try std.posix.pipe();
        \\+
        \\+    self.winch_read = self.winch_pipe[0];
        \\-    a removed line that is longer than either added run here is
        \\ trailing context
        \\--- a/src/short.zig
        \\+++ b/src/short.zig
        \\@@ -1,1 +1,2 @@
        \\+}
        \\
    ;
    const markers = try patchMarkers(arena, patch);
    // src/short.zig adds only "}", which is under the minimum, so it is
    // skipped rather than turned into a marker that matches anywhere.
    try std.testing.expectEqual(@as(usize, 1), markers.len);
    try std.testing.expectEqualStrings("src/tty.zig", markers[0].file);
    // The three-line run beats the longer single line, indentation and the
    // interior blank line are kept verbatim (that is what makes the check a
    // substring search), and the removed line -- longer than both -- is no
    // evidence of anything being applied.
    try std.testing.expectEqualStrings(
        "    self.winch_pipe = try std.posix.pipe();\n\n    self.winch_read = self.winch_pipe[0];",
        markers[0].text,
    );
}

test "depPatchesGate fails on a pristine dependency tree and passes on a patched one" {
    // Both directions, because a check that fails on either state is
    // indistinguishable from one that fails on neither until you look.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const hash = "vaxis-0.6.0-BWNV_KwYCgB";
    const marker = "self.winch_pipe = try std.posix.pipe();";
    try tmp.dir.writeFile(io, .{
        .sub_path = "build.zig.zon",
        .data = ".{ .dependencies = .{ .vaxis = .{ .hash = \"" ++ hash ++ "\" } } }\n",
    });
    try ensure_dir.ensureDir(tmp.dir, io, "patches");
    try tmp.dir.writeFile(io, .{
        .sub_path = "patches/vaxis-winch-self-pipe.patch",
        .data = "--- a/src/tty.zig\n+++ b/src/tty.zig\n@@ -1,1 +1,2 @@\n const std = @import(\"std\");\n+    " ++ marker ++ "\n",
    });
    try ensure_dir.ensureDir(tmp.dir, io, dep_pkg_dir ++ "/" ++ hash ++ "/src");

    // Pristine: the extracted tree has the file but not the addition.
    try tmp.dir.writeFile(io, .{ .sub_path = dep_pkg_dir ++ "/" ++ hash ++ "/src/tty.zig", .data = "const std = @import(\"std\");\n" });
    {
        var result = try depPatchesGate(gpa, io, tmp.dir);
        defer result.deinit(gpa);
        try std.testing.expect(!result.ok);
        try std.testing.expectEqualStrings("dep-patches", result.label);
        // The message must name the script: the same missing patch was read
        // as a REPL regression by two sessions because the failure it caused
        // did not say what to run.
        try std.testing.expect(std.mem.find(u8, result.detail, "scripts/apply-patches.sh") != null);
        try std.testing.expect(std.mem.find(u8, result.detail, "vaxis-winch-self-pipe.patch") != null);
    }

    // Patched: same commit, same check, green.
    try tmp.dir.writeFile(io, .{ .sub_path = dep_pkg_dir ++ "/" ++ hash ++ "/src/tty.zig", .data = "const std = @import(\"std\");\n    " ++ marker ++ "\n" });
    {
        var result = try depPatchesGate(gpa, io, tmp.dir);
        defer result.deinit(gpa);
        try std.testing.expect(result.ok);
    }

    // A dependency tree that was never extracted is its own failure, and must
    // say so rather than reading as patched.
    try tmp.dir.deleteFile(io, dep_pkg_dir ++ "/" ++ hash ++ "/src/tty.zig");
    {
        var result = try depPatchesGate(gpa, io, tmp.dir);
        defer result.deinit(gpa);
        try std.testing.expect(!result.ok);
        try std.testing.expect(std.mem.find(u8, result.detail, "not there to patch") != null);
    }
}
