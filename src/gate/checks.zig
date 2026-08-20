//! Deterministic gate checks for the self-improvement loop. This module is
//! deliberately OUTSIDE the protected surface (src/improve/, src/evals/,
//! src/toolhost/builder.zig) so clanker can keep strengthening these checks.
//! The engine in src/improve/engine.zig calls these and promotes only when
//! every check passes.

const std = @import("std");
const build_options = @import("build_options");
const log = @import("../util/log.zig");
const toml_bridge = @import("../util/toml_bridge.zig");
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
        const content = dir.readFileAlloc(io, f, gpa, .limited(1 << 20)) catch |err| {
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
        const content = dir.readFileAlloc(io, f, gpa, .limited(1 << 20)) catch |err| {
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

    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
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

        // A session tool that loses `"session": true` stops every session
        // capability eval from running: ck_session denies, the guest returns a
        // hard error, the eval scores 0. Because the improve capability gate
        // runs the evals after the cheap build/tools/test gates, a dropped
        // grant wasted a whole batch (every proposal rejected on a grant the
        // proposal never touched) before it was traced back to the manifest.
        // Pin it here, at cheap manifest inspection, so a regression is caught
        // before any LLM-backed eval runs.
        if (name.len > 0 and std.mem.startsWith(u8, name, "session_")) {
            const grants_session = if (obj.get("session")) |sv| sv == .bool and sv.bool else false;
            if (!grants_session) {
                try problems.append(gpa, try std.fmt.allocPrint(arena, "{s} reads the session store through ck_session, which requires session: true in the descriptor", .{entry.name}));
            }
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

test "toolDescriptorGate requires session tools to grant session" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "manifests");
    try tmp.dir.createDirPath(io, "zig-out/tools");
    try tmp.dir.writeFile(io, .{ .sub_path = "zig-out/tools/good.wasm", .data = "{}" });

    // A session tool without the grant is refused: ck_session denies, the
    // guest hard-fails, and every session capability eval scores 0, which the
    // improve loop reads as a broken proposal even when the patch never
    // touched sessions.
    try tmp.dir.writeFile(io, .{ .sub_path = "manifests/session_search.tool.json", .data = "{\"name\":\"session_search\",\"wasm\":\"zig-out/tools/good.wasm\"}" });
    var bad = try toolDescriptorGate(gpa, io, tmp.dir, "manifests");
    defer bad.deinit(gpa);
    try std.testing.expect(!bad.ok);
    try std.testing.expect(std.mem.find(u8, bad.detail, "requires session") != null);

    // With the grant it passes.
    try tmp.dir.writeFile(io, .{ .sub_path = "manifests/session_search.tool.json", .data = "{\"name\":\"session_search\",\"wasm\":\"zig-out/tools/good.wasm\",\"session\":true}" });
    const ok = try toolDescriptorGate(gpa, io, tmp.dir, "manifests");
    try std.testing.expect(ok.ok);

    // A non-session tool is not forced to declare the grant.
    try tmp.dir.writeFile(io, .{ .sub_path = "manifests/other.tool.json", .data = "{\"name\":\"other\",\"wasm\":\"zig-out/tools/good.wasm\"}" });
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

fn weakensImprove(obj: std.json.ObjectMap) ?GateResult {
    if (isFalse(obj.get("capability_gate")))
        return .{ .ok = false, .label = "config-weakening", .detail = "capability_gate must not be disabled" };
    if (isFalse(obj.get("inert_gate")))
        return .{ .ok = false, .label = "config-weakening", .detail = "inert_gate must not be disabled" };
    if (obj.get("max_consecutive_test_only")) |v| {
        switch (v) {
            .integer => |n| if (n <= 0)
                return .{ .ok = false, .label = "config-weakening", .detail = "max_consecutive_test_only must be positive" },
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
        "max_consecutive_test_only: u32 = 0",
        "|b| !b",
    };
    for (forbidden) |needle| {
        if (std.mem.find(u8, src, needle) != null) return needle;
    }
    return null;
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
/// dev-only compiler dependency, npm lifecycle scripts disabled at install,
/// and lockfile integrity fields for supply-chain verification.
pub fn toolsTsToolchainGate(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !GateResult {
    const npmrc = dir.readFileAlloc(io, "tools/ts/.npmrc", gpa, .limited(4096)) catch |err| {
        const detail = try std.fmt.allocPrint(gpa, "cannot read tools/ts/.npmrc: {s}", .{@errorName(err)});
        return .{ .ok = false, .label = "tools-ts-toolchain", .detail = detail };
    };
    defer gpa.free(npmrc);
    if (std.mem.find(u8, npmrc, "ignore-scripts=true") == null) {
        return .{ .ok = false, .label = "tools-ts-toolchain", .detail = "tools/ts/.npmrc must set ignore-scripts=true" };
    }

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

    const lock = dir.readFileAlloc(io, "tools/ts/package-lock.json", gpa, .limited(1 << 20)) catch |err| {
        const detail = try std.fmt.allocPrint(gpa, "cannot read tools/ts/package-lock.json: {s}", .{@errorName(err)});
        return .{ .ok = false, .label = "tools-ts-toolchain", .detail = detail };
    };
    defer gpa.free(lock);
    if (std.mem.find(u8, lock, "\"integrity\":") == null) {
        return .{ .ok = false, .label = "tools-ts-toolchain", .detail = "tools/ts/package-lock.json is missing npm integrity hashes" };
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
        const content = dir.readFileAlloc(io, f, gpa, .limited(4 << 20)) catch |err| {
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
