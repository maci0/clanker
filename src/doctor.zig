//! `clanker doctor` and `clanker setup`.
//!
//! doctor answers "why is it not working" without the user having to know
//! where clanker keeps things. Every check is read-only and offline: the
//! failures it looks for are the ones this project actually produces (a
//! missing `zig build tools`, an unset key env var, a `default_provider`
//! naming nothing), not a generic health checklist. Connectivity needs the
//! network and belongs to `clanker providers check`, which doctor points at
//! rather than doing itself.
//!
//! setup is the guided first run: scaffold what `init` scaffolds, then look
//! at which provider keys are actually in the environment and say which
//! provider that makes usable, finishing with the same checks doctor runs.

const std = @import("std");
const config = @import("config.zig");
const registry = @import("toolhost/registry.zig");
const log = @import("util/log.zig");
const ensure_dir = @import("util/ensure_dir.zig");
const vertex_token = @import("llm/vertex_token.zig");
const llm_registry = @import("llm/registry.zig");
/// For the one list of paths a linked worktree gets as symlinks back to its
/// main checkout. Reading the names from the module that creates the links is
/// what keeps the assertion here from drifting away from the linking there.
const worktree = @import("improve/worktree.zig");
const build_options = @import("build_options");
const plat_os: []const u8 = switch (@import("builtin").os.tag) {
    .linux => "linux",
    .macos => "macos",
    .windows => "windows",
    else => "other",
};
const plat_arch: []const u8 = switch (@import("builtin").cpu.arch) {
    .x86_64 => "x86_64",
    .aarch64 => "aarch64",
    else => "other",
};

const Status = enum {
    ok,
    warn,
    fail,

    fn mark(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok  ",
            .warn => "warn",
            .fail => "FAIL",
        };
    }
};

const Report = struct {
    w: *std.Io.Writer,
    failures: usize = 0,
    warnings: usize = 0,
    default_provider: []const u8 = "",

    fn line(self: *Report, status: Status, label: []const u8, detail: []const u8) void {
        switch (status) {
            .fail => self.failures += 1,
            .warn => self.warnings += 1,
            .ok => {},
        }
        if (detail.len > 0) {
            self.w.print("  [{s}] {s: <26} {s}\n", .{ status.mark(), label, detail }) catch {};
        } else {
            self.w.print("  [{s}] {s}\n", .{ status.mark(), label }) catch {};
        }
    }

    fn section(self: *Report, title: []const u8) void {
        self.w.print("\n{s}\n", .{title}) catch {};
    }
};

fn dirExists(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

fn dirHasEntries(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer d.close(io);
    var it = d.iterate();
    const entry = it.next(io) catch null;
    return entry != null;
}

/// One gitignored path a linked worktree gets as a SYMLINK back to its main
/// checkout, and what a private file in its place costs.
const LinkedPath = struct {
    name: []const u8,
    /// Severity when the name holds a real file instead of the link.
    replaced: Status,
    /// What the detached copy costs, printed after the target.
    cost: []const u8,
};

/// The names come from `improve/worktree.zig`, never a second copy here:
/// `local_config_names` is what `prepareLinked` (and `clanker worktree
/// prepare`) links, `shared_state_link_names` what `linkSharedState` links for
/// an improve run. A list restated here would drift the moment either grows.
///
/// The two halves differ in severity, not in kind. A worktree may legitimately
/// hold its own `config.local.toml` -- `prepareLinked` never overwrites an
/// existing name for exactly that reason -- so a real file there is worth
/// saying and not worth failing over. The shared-state pair has no such
/// reading: a private ledger is silent data loss, which is the defect in
/// docs/reports/bugs/2026-08-17-improve-ledger-written-to-a-worktree-copy.md.
const linked_worktree_paths = blk: {
    var out: [worktree.local_config_names.len + worktree.shared_state_link_names.len]LinkedPath = undefined;
    var i: usize = 0;
    for (worktree.local_config_names) |name| {
        out[i] = .{
            .name = name,
            .replaced = .warn,
            .cost = "edits here never reach the checkout, and its edits never reach this tree",
        };
        i += 1;
    }
    for (worktree.shared_state_link_names) |name| {
        out[i] = .{
            .name = name,
            .replaced = .fail,
            .cost = "every write lands in a copy thrown away with the worktree",
        };
        i += 1;
    }
    break :blk out;
};

/// The main checkout a linked worktree's `.git` FILE points back at, or null
/// when this is not a linked worktree. In an ordinary checkout `.git` is a
/// DIRECTORY, so the read fails and doctor skips the whole section rather than
/// reporting on names that were never meant to be links.
fn worktreeMainCheckout(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir) ?[]const u8 {
    const contents = dir.readFileAlloc(io, ".git", arena, .limited(4096)) catch return null;
    return worktree.mainCheckoutFromGitFile(contents);
}

/// Asserts that the entries a linked worktree is given as symlinks are still
/// symlinks.
///
/// Nothing else checks this. `atomic_write.writeFile` resolves a leaf link
/// before renaming, which is where the defect lived and where its unit tests
/// sit, but any other writer that renames onto one of these names replaces the
/// link with a private regular file and nothing says so: the run keeps working,
/// keeps writing, and its writes stop being visible to anyone else.
fn checkWorktreeLinks(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: std.Io.Dir,
    main_checkout: []const u8,
    rep: *Report,
) !void {
    for (linked_worktree_paths) |entry| {
        const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ main_checkout, entry.name });
        // Nothing in the main checkout to link TO: both linkers skip a name
        // the checkout does not have, so a real file at that name here is the
        // worktree's own and never was a link. Absolute, so the cwd handle is
        // ignored and this asks about the checkout rather than about `dir`.
        std.Io.Dir.cwd().access(io, target, .{}) catch continue;

        var buf: [4096]u8 = undefined;
        const n = dir.readLink(io, entry.name, &buf) catch |err| switch (err) {
            // Never provisioned. A fresh worktree legitimately has neither
            // half of the pair, and `clanker worktree prepare` is the fix for
            // the config half; absent is not detached.
            error.FileNotFound => continue,
            // The whole reason this check exists. A link is replaced by a
            // regular file whenever a writer renames onto the link's own name
            // instead of onto its target, and the run then reads and writes a
            // copy nobody else sees.
            error.NotLink => {
                rep.line(entry.replaced, entry.name, try std.fmt.allocPrint(
                    arena,
                    "a private copy, not a link to {s}: {s}",
                    .{ target, entry.cost },
                ));
                continue;
            },
            else => {
                rep.line(.warn, entry.name, @errorName(err));
                continue;
            },
        };
        // The target is printed, not just "ok": a link pointing at the wrong
        // checkout reads the same as a correct one until you can see where it
        // goes.
        rep.line(.ok, entry.name, try std.fmt.allocPrint(arena, "links to {s}", .{buf[0..n]}));
    }
}

/// Every check doctor runs, so `setup` can end with the same report rather
/// than a second, drifting copy of it.
fn runChecks(
    io: std.Io,
    arena: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    rep: *Report,
) !void {
    rep.section("config");
    if (!fileExists(io, "config.toml")) {
        rep.line(.fail, "config.toml", "missing; run `clanker setup`");
        // Even without config, surface whether tools were ever built so the
        // user knows which half of the problem to tackle first.
        if (dirExists(io, "zig-out/tools"))
            rep.line(.ok, "zig-out/tools/", "present (tools were previously built)")
        else
            rep.line(.warn, "zig-out/tools/", "absent; `zig build tools` has not been run");
        // skills/ and state/ are scaffolded by setup; their absence alongside a
        // missing config.toml means first-run initialization never completed.
        if (!dirExists(io, "skills"))
            rep.line(.warn, "skills/", "absent; run `clanker setup` to scaffold")
        else
            rep.line(.ok, "skills/", "");
        if (!dirExists(io, "state"))
            rep.line(.warn, "state/", "absent; run `clanker setup` to scaffold")
        else
            rep.line(.ok, "state/", "");
        return;
    }
    rep.line(.ok, "config.toml", "");
    if (fileExists(io, "config.local.toml"))
        rep.line(.ok, "config.local.toml", "")
    else
        rep.line(.warn, "config.local.toml", "absent; defaults from config.toml only");
    // TOML is canonical and the loader reads nothing else; a leftover
    // pre-migration file silently does nothing, which is worth saying. The
    // old primary `config.json` is the one most likely to hold settings a
    // person thinks are still in effect, so it gets a check too, not just
    // the local override.
    if (fileExists(io, "config.json"))
        rep.line(.warn, "config.json", "ignored; convert it to config.toml and delete it");
    if (fileExists(io, "config.local.json"))
        rep.line(.warn, "config.local.json", "ignored; convert to config.local.toml and delete it");

    const cfg = config.Config.load(io, arena, std.Io.Dir.cwd(), "config.toml", "config.local.toml") catch |err| {
        rep.line(.fail, "config parses", @errorName(err));
        return;
    };
    rep.line(.ok, "config parses", "");
    rep.default_provider = cfg.default_provider;

    // A default_provider naming nothing is refused at load, so reaching here
    // means it resolves; the useful thing left to say is which one it is, and
    // which of the two files won it.
    rep.line(.ok, "default_provider", if (cfg.default_provider_from) |from|
        try std.fmt.allocPrint(arena, "{s} (from {s})", .{ cfg.default_provider, from })
    else
        cfg.default_provider);

    rep.section("providers and keys");
    var it = cfg.providers.iterator();
    var usable: usize = 0;
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        const is_default = std.mem.eql(u8, p.name, cfg.default_provider);
        const label = if (is_default) try std.fmt.allocPrint(arena, "{s} (default)", .{p.name}) else p.name;
        // A base_url without a scheme produces an opaque runtime connection
        // failure; surface the typo at startup instead.
        if (!std.mem.startsWith(u8, p.base_url, "http://") and !std.mem.startsWith(u8, p.base_url, "https://")) {
            rep.line(
                if (is_default) .fail else .warn,
                label,
                try std.fmt.allocPrint(arena, "{s} lacks http(s):// scheme", .{p.base_url}),
            );
        }
        if (p.api_key_env) |env_name| {
            const set = if (environ_map.get(env_name)) |v| v.len > 0 else false;
            if (set) usable += 1;
            // The value is never printed: doctor output gets pasted into
            // issues. Only whether the variable holds something.
            rep.line(
                if (set) .ok else if (is_default) .fail else .warn,
                label,
                if (set) env_name else try std.fmt.allocPrint(arena, "{s} is not set", .{env_name}),
            );
        } else if (llm_registry.forKind(p.kind).auth.file_credential) {
            // The path is not printed: it is usually under a home directory
            // and its name tends to carry the cloud project.
            if (vertex_token.resolveCredentialsPath(arena, p.service_account_file, environ_map)) |path| {
                const present = fileExists(io, path);
                if (present) usable += 1;
                const kind_label: []const u8 = if (p.service_account_file.len > 0)
                    "service account file"
                else
                    "gcloud ADC";
                rep.line(
                    if (present) .ok else if (is_default) .fail else .warn,
                    label,
                    if (present)
                        try std.fmt.allocPrint(arena, "{s} present", .{kind_label})
                    else
                        try std.fmt.allocPrint(arena, "{s} missing", .{kind_label}),
                );
            } else {
                rep.line(
                    if (is_default) .fail else .warn,
                    label,
                    "no service_account_file or gcloud ADC",
                );
            }
        } else if (p.service_account_file.len > 0) {
            const present = fileExists(io, p.service_account_file);
            if (present) usable += 1;
            // The path itself is not printed: it is usually under a home
            // directory and its name tends to carry the cloud project. Whether
            // the file is there is the whole answer.
            rep.line(
                if (present) .ok else if (is_default) .fail else .warn,
                label,
                if (present) "service account file present" else "service account file missing",
            );
        } else {
            // A local runtime (ollama, vllm) needs no credential.
            usable += 1;
            rep.line(.ok, label, "no credential needed");
        }
    }
    if (cfg.providers.count() == 0) {
        rep.line(.fail, "providers declared", "none; add at least one provider to config.toml or config.local.toml");
    } else if (usable == 0) {
        rep.line(.fail, "any usable provider", "no provider has a credential");
    }

    rep.section("directories");
    for (cfg.agent.tools_dir) |tools_dir| {
        const present = dirExists(io, tools_dir);
        rep.line(
            if (present) .ok else .fail,
            "tools_dir",
            if (present) tools_dir else try std.fmt.allocPrint(arena, "{s} missing; run `clanker setup`", .{tools_dir}),
        );
    }
    const broad_sandbox = std.mem.eql(u8, cfg.agent.sandbox_root, "/") or cfg.agent.sandbox_root.len == 0;
    inline for (.{
        .{ "skills_dir", cfg.agent.skills_dir },
        .{ "state_dir", cfg.agent.state_dir },
        .{ "sandbox_root", cfg.agent.sandbox_root },
    }) |pair| {
        const present = dirExists(io, pair[1]);
        // A sandbox root of "/" or "" grants every tool unrestricted filesystem
        // access; surface that as a warning rather than silently reporting OK.
        const broad_grant = std.mem.eql(u8, pair[0], "sandbox_root") and (std.mem.eql(u8, pair[1], "/") or pair[1].len == 0);
        if (broad_grant and cfg.agent.sandbox_follow_symlinks) {
            rep.line(.fail, "sandbox_root", "unrestricted filesystem access combined with symlink following makes every path on the system reachable");
        } else {
            rep.line(
                if (broad_grant) .warn else if (present) .ok else .fail,
                pair[0],
                if (broad_grant) "grants unrestricted filesystem access to every tool" else if (present) pair[1] else try std.fmt.allocPrint(arena, "{s} missing; run `clanker setup`", .{pair[1]}),
            );
        }
    }
    // sandbox_follow_symlinks lets a link inside a granted prefix reach its
    // target outside the sandbox; surface that at startup rather than letting it
    // silently weaken the boundary. Suppressed when already escalated to FAIL above.
    if (cfg.agent.sandbox_follow_symlinks and !broad_sandbox) {
        rep.line(.warn, "sandbox_follow_symlinks", "enabled: symlinks inside granted prefixes escape the sandbox");
    }
    rep.line(
        if (fileExists(io, cfg.agent.system_prompt_file)) .ok else .warn,
        "system prompt",
        cfg.agent.system_prompt_file,
    );
    if (dirExists(io, cfg.agent.skills_dir) and !dirHasEntries(io, cfg.agent.skills_dir)) {
        rep.line(.warn, "skills", try std.fmt.allocPrint(arena, "{s} is empty; no skill files found", .{cfg.agent.skills_dir}));
    }

    // Only inside a linked worktree, where these names are supposed to be
    // symlinks back to the main checkout. An ordinary checkout has no main
    // checkout and no section.
    if (worktreeMainCheckout(io, arena, std.Io.Dir.cwd())) |main_checkout| {
        rep.section("worktree links");
        rep.line(.ok, "main checkout", main_checkout);
        try checkWorktreeLinks(io, arena, std.Io.Dir.cwd(), main_checkout, rep);
    }

    rep.section("tools");
    const reg = registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir) catch |err| {
        rep.line(.fail, "tool manifests", @errorName(err));
        return;
    };
    var missing: usize = 0;
    var first_missing: []const u8 = "";
    var abs_count: usize = 0;
    var first_abs: []const u8 = "";
    var tools_it = reg.tools.iterator();
    while (tools_it.next()) |entry| {
        if (!fileExists(io, entry.value_ptr.wasm)) {
            missing += 1;
            if (first_missing.len == 0) first_missing = entry.value_ptr.wasm;
        }
        if (std.mem.startsWith(u8, entry.value_ptr.wasm, "/")) {
            abs_count += 1;
            if (first_abs.len == 0) first_abs = entry.value_ptr.wasm;
        }
    }
    const tool_count = reg.tools.count();
    rep.line(
        if (tool_count > 0) .ok else .fail,
        "manifests",
        try std.fmt.allocPrint(arena, "{d} registered", .{tool_count}),
    );
    if (missing == 0) {
        rep.line(.ok, "compiled modules", "every tool has its .wasm");
    } else {
        // The single most common broken state in this project: `zig build`
        // does not compile the guest modules, so a fresh checkout has
        // manifests pointing at files that were never built.
        rep.line(.fail, "compiled modules", try std.fmt.allocPrint(
            arena,
            "{d} missing (e.g. {s}); run `zig build tools`",
            .{ missing, first_missing },
        ));
    }
    if (abs_count > 0) {
        rep.line(.warn, "absolute wasm paths", try std.fmt.allocPrint(
            arena,
            "{d} manifest{s} point outside the project tree (e.g. {s}); another local user could swap the binary",
            .{ abs_count, if (abs_count == 1) "" else "s", first_abs },
        ));
    }

    // A zero-length array means no command can ever execute; an empty-string
    // entry within a non-empty array wildcard-matches every command. Both
    // weaken the exec permission boundary and are surfaced distinctly.
    inline for (.{
        .{ "exec_pattern_allow", cfg.agent.exec_pattern_allow },
        .{ "repl_exec_allow", cfg.agent.repl_exec_allow },
    }) |pair| {
        if (pair[1].len == 0) {
            rep.line(.fail, pair[0], "zero-length array: no command can ever execute");
        } else {
            var wildcard_count: usize = 0;
            for (pair[1]) |p| {
                if (p.len == 0 or std.mem.eql(u8, p, "*")) wildcard_count += 1;
            }
            if (wildcard_count > 0) {
                rep.line(.warn, pair[0], try std.fmt.allocPrint(arena, "{d} entr{s} wildcard-match every command", .{ wildcard_count, if (wildcard_count == 1) "y" else "ies" }));
            }
        }
    }
}

pub fn cmdDoctor(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var out = std.Io.File.stdout().writer(io, &.{});
    var rep = Report{ .w = &out.interface };
    rep.w.print("clanker doctor {s} ({s}/{s})\n", .{ build_options.version, plat_os, plat_arch }) catch {};

    try runChecks(io, arena, init.environ_map, &rep);

    rep.w.print("\n{d} failing, {d} warning\n", .{ rep.failures, rep.warnings }) catch {};
    if (rep.failures > 0) {
        rep.w.writeAll("Fix the failures above, then run `clanker providers check` for connectivity.\n") catch {};
    } else if (rep.warnings > 0) {
        rep.w.writeAll("Warnings are fine if those providers are not needed. Run `clanker providers check` for connectivity.\n") catch {};
    } else {
        rep.w.writeAll("Everything looks good. Run `clanker providers check` for connectivity.\n") catch {};
    }
    // Compact diagnostic line designed for copy-paste into bug reports and
    // support threads: version, platform, and outcome in one string.
    rep.w.print(
        "diagnostic: clanker/{s} {s}/{s} provider={s} failures={d} warnings={d}\n",
        .{ build_options.version, plat_os, plat_arch, rep.default_provider, rep.failures, rep.warnings },
    ) catch {};
    out.interface.flush() catch {};
    // A non-zero exit lets `clanker doctor` guard a script or a CI step.
    if (rep.failures > 0) std.process.exit(1);
}

/// Provider name to the env var it reads, for the "what could I use" hint.
/// Only providers clanker ships in config.toml need an entry; anything else
/// is reported by name from the config itself.
fn wouldWork(io: std.Io, environ_map: *std.process.Environ.Map, cfg: *const config.Config, arena: std.mem.Allocator) !?[]const u8 {
    var it = cfg.providers.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.api_key_env) |env_name| {
            if (environ_map.get(env_name)) |v| {
                if (v.len > 0) return try arena.dupe(u8, p.name);
            }
        } else if (llm_registry.forKind(p.kind).auth.file_credential) {
            if (vertex_token.resolveCredentialsPath(arena, p.service_account_file, environ_map)) |path| {
                if (fileExists(io, path)) return try arena.dupe(u8, p.name);
            }
        } else if (p.service_account_file.len > 0) {
            if (fileExists(io, p.service_account_file)) return try arena.dupe(u8, p.name);
        } else {
            // Local runtime: no credential needed.
            return try arena.dupe(u8, p.name);
        }
    }
    return null;
}

pub fn cmdSetup(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const dir = std.Io.Dir.cwd();

    var out = std.Io.File.stdout().writer(io, &.{});
    const w = &out.interface;
    w.writeAll("clanker setup\n\n") catch {};

    // Scaffolding is what `init` does; setup does it too rather than telling
    // the user to run a second command first.
    // cli.zig scaffolds before calling this, so a missing file here means the
    // write itself failed rather than that it was never attempted.
    if (!fileExists(io, "config.local.toml")) {
        w.writeAll("  config.local.toml could not be written. Check the directory is writable.\n") catch {};
        out.interface.flush() catch {};
        std.process.exit(1);
    }
    ensure_dir.ensureDir(dir, io, "state") catch |err| {
        log.log(.warn, "setup: mkdir 'state' failed: {s}", .{@errorName(err)});
        w.print("  state/ could not be created: {s}. Check the directory is writable.\n", .{@errorName(err)}) catch {};
    };

    const cfg = config.Config.load(io, arena, dir, "config.toml", "config.local.toml") catch |err| {
        w.print("  config does not load: {s}\n", .{@errorName(err)}) catch {};
        out.interface.flush() catch {};
        std.process.exit(1);
    };

    const active = cfg.default_provider;
    const active_ok = blk: {
        const p = cfg.provider(active) catch break :blk false;
        if (p.api_key_env) |env_name| {
            break :blk if (init.environ_map.get(env_name)) |v| v.len > 0 else false;
        }
        if (llm_registry.forKind(p.kind).auth.file_credential) {
            const path = vertex_token.resolveCredentialsPath(arena, p.service_account_file, init.environ_map) orelse break :blk false;
            break :blk fileExists(io, path);
        }
        break :blk true;
    };

    if (active_ok) {
        w.print("  Default provider '{s}' has what it needs.\n", .{active}) catch {};
    } else {
        w.print("  Default provider '{s}' has no credential in this environment.\n", .{active}) catch {};
        if (try wouldWork(io, init.environ_map, &cfg, arena)) |other| {
            w.print("  '{s}' does. Set default_provider = \"{s}\" in config.local.toml to use it.\n", .{ other, other }) catch {};
        } else {
            const p = cfg.provider(active) catch null;
            if (p) |prov| {
                if (prov.api_key_env) |env_name| {
                    w.print("  Export {s}, or point default_provider at a local runtime.\n", .{env_name}) catch {};
                }
            }
        }
    }

    var rep = Report{ .w = w };
    try runChecks(io, arena, init.environ_map, &rep);
    w.print("\n{d} failing, {d} warning\n", .{ rep.failures, rep.warnings }) catch {};
    if (rep.failures == 0) {
        w.writeAll("\nReady. Try: clanker \"summarise this repo\"\n") catch {};
    }
    out.interface.flush() catch {};
    if (rep.failures > 0) std.process.exit(1);
}

test "a report counts what it prints" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var rep = Report{ .w = &w };
    rep.line(.ok, "fine", "");
    rep.line(.warn, "iffy", "detail");
    rep.line(.fail, "broken", "why");
    rep.line(.fail, "also broken", "");
    try std.testing.expectEqual(@as(usize, 2), rep.failures);
    try std.testing.expectEqual(@as(usize, 1), rep.warnings);
    // The detail is printed when there is one, and the label alone otherwise.
    const text = buf[0..w.end];
    try std.testing.expect(std.mem.find(u8, text, "iffy") != null);
    try std.testing.expect(std.mem.find(u8, text, "detail") != null);
    try std.testing.expect(std.mem.find(u8, text, "FAIL") != null);
}

// The shape `linkSharedState` produces, with one entry already detached: a
// worktree whose `state/history` link survived (nothing renames over a
// directory) beside a `state/improvements.jsonl` that a whole-file rewrite
// replaced with a private copy. That is the exact pair the ledger bug found
// in ten worktrees, and it is what this check exists to name.
test "doctor fails a worktree whose linked state entry is a private copy" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "checkout/state/history");
    try tmp.dir.writeFile(io, .{ .sub_path = "checkout/state/improvements.jsonl", .data = "{}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "checkout/config.local.toml", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "checkout/.env", .data = "" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const main_checkout = try std.fmt.allocPrint(arena, "{s}/checkout", .{root});

    try tmp.dir.createDirPath(io, "wt/state");
    try tmp.dir.symLink(
        io,
        try std.fmt.allocPrint(arena, "{s}/state/history", .{main_checkout}),
        "wt/state/history",
        .{ .is_directory = true },
    );
    try tmp.dir.symLink(
        io,
        try std.fmt.allocPrint(arena, "{s}/config.local.toml", .{main_checkout}),
        "wt/config.local.toml",
        .{},
    );
    // The defect: a real file where the link was.
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/state/improvements.jsonl", .data = "{}\n{}\n" });

    var wt = try tmp.dir.openDir(io, "wt", .{});
    defer wt.close(io);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var rep = Report{ .w = &w };
    try checkWorktreeLinks(io, arena, wt, main_checkout, &rep);
    const text = buf[0..w.end];

    // The detached ledger is a failure, and the diagnostic names both the path
    // and the file it should be pointing at.
    try std.testing.expectEqual(@as(usize, 1), rep.failures);
    try std.testing.expectEqual(@as(usize, 0), rep.warnings);
    const expected_target = try std.fmt.allocPrint(arena, "{s}/state/improvements.jsonl", .{main_checkout});
    try std.testing.expect(std.mem.find(u8, text, expected_target) != null);
    try std.testing.expect(std.mem.find(u8, text, "FAIL") != null);
    // The surviving link is reported as fine, with what it points at.
    try std.testing.expect(std.mem.find(u8, text, "state/history") != null);
    // `.env` is in the main checkout but was never given to this worktree.
    // Absent is not detached, so it must produce no line at all.
    try std.testing.expect(std.mem.find(u8, text, ".env") == null);
}

test "doctor passes a worktree whose links are intact" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "checkout/state");
    try tmp.dir.writeFile(io, .{ .sub_path = "checkout/state/improvements.jsonl", .data = "{}\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const main_checkout = try std.fmt.allocPrint(arena, "{s}/checkout", .{root});

    try tmp.dir.createDirPath(io, "wt/state");
    try tmp.dir.symLink(
        io,
        try std.fmt.allocPrint(arena, "{s}/state/improvements.jsonl", .{main_checkout}),
        "wt/state/improvements.jsonl",
        .{},
    );

    var wt = try tmp.dir.openDir(io, "wt", .{});
    defer wt.close(io);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var rep = Report{ .w = &w };
    try checkWorktreeLinks(io, arena, wt, main_checkout, &rep);
    try std.testing.expectEqual(@as(usize, 0), rep.failures);
    try std.testing.expectEqual(@as(usize, 0), rep.warnings);
    try std.testing.expect(std.mem.find(u8, buf[0..w.end], "links to") != null);
}

// An ordinary checkout has no main checkout to link back to: `.git` is a
// directory, so the read fails and doctor prints nothing about links.
test "a checkout that is not a linked worktree has no main checkout" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git");
    try std.testing.expect(worktreeMainCheckout(io, arena_state.allocator(), tmp.dir) == null);
}
