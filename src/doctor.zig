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
        return;
    }
    rep.line(.ok, "config.toml", "");
    if (fileExists(io, "config.local.toml"))
        rep.line(.ok, "config.local.toml", "")
    else
        rep.line(.warn, "config.local.toml", "absent; defaults from config.toml only");
    // TOML is canonical and the loader reads nothing else; a leftover
    // pre-migration file silently does nothing, which is worth saying.
    if (fileExists(io, "config.local.json"))
        rep.line(.warn, "config.local.json", "ignored; convert to config.local.toml and delete it");

    const cfg = config.Config.load(io, arena, std.Io.Dir.cwd(), "config.toml", "config.local.toml") catch |err| {
        rep.line(.fail, "config parses", @errorName(err));
        return;
    };
    rep.line(.ok, "config parses", "");

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
    if (usable == 0) rep.line(.fail, "any usable provider", "no provider has a credential");

    rep.section("directories");
    for (cfg.agent.tools_dir) |tools_dir| {
        const present = dirExists(io, tools_dir);
        rep.line(
            if (present) .ok else .fail,
            "tools_dir",
            if (present) tools_dir else try std.fmt.allocPrint(arena, "{s} missing; run `clanker setup`", .{tools_dir}),
        );
    }
    inline for (.{
        .{ "skills_dir", cfg.agent.skills_dir },
        .{ "state_dir", cfg.agent.state_dir },
        .{ "sandbox_root", cfg.agent.sandbox_root },
    }) |pair| {
        const present = dirExists(io, pair[1]);
        rep.line(
            if (present) .ok else .fail,
            pair[0],
            if (present) pair[1] else try std.fmt.allocPrint(arena, "{s} missing; run `clanker setup`", .{pair[1]}),
        );
    }
    rep.line(
        if (fileExists(io, cfg.agent.system_prompt_file)) .ok else .warn,
        "system prompt",
        cfg.agent.system_prompt_file,
    );
    if (dirExists(io, cfg.agent.skills_dir) and !dirHasEntries(io, cfg.agent.skills_dir)) {
        rep.line(.warn, "skills", try std.fmt.allocPrint(arena, "{s} is empty; no skill files found", .{cfg.agent.skills_dir}));
    }

    rep.section("tools");
    const reg = registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir) catch |err| {
        rep.line(.fail, "tool manifests", @errorName(err));
        return;
    };
    var missing: usize = 0;
    var first_missing: []const u8 = "";
    var tools_it = reg.tools.iterator();
    while (tools_it.next()) |entry| {
        if (!fileExists(io, entry.value_ptr.wasm)) {
            missing += 1;
            if (first_missing.len == 0) first_missing = entry.value_ptr.wasm;
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
