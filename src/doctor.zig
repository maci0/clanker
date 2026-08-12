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
const registry = @import("tools/registry.zig");
const log = @import("util/log.zig");
const atomic_write = @import("util/atomic_write.zig");

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

/// Every check doctor runs, so `setup` can end with the same report rather
/// than a second, drifting copy of it.
fn runChecks(
    io: std.Io,
    arena: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    rep: *Report,
) !void {
    rep.section("config");
    if (!fileExists(io, "config.json")) {
        rep.line(.fail, "config.json", "missing; run `clanker setup`");
        return;
    }
    rep.line(.ok, "config.json", "");
    rep.line(if (fileExists(io, "config.local.json")) .ok else .warn, "config.local.json", if (fileExists(io, "config.local.json")) "" else "absent; defaults from config.json only");

    const cfg = config.Config.load(io, arena, std.Io.Dir.cwd(), "config.json", "config.local.json") catch |err| {
        rep.line(.fail, "config parses", @errorName(err));
        return;
    };
    rep.line(.ok, "config parses", "");

    // A default_provider naming nothing is refused at load, so reaching here
    // means it resolves; the useful thing left to say is which one it is.
    rep.line(.ok, "default_provider", cfg.default_provider);

    rep.section("providers and keys");
    var it = cfg.providers.iterator();
    var usable: usize = 0;
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        const is_default = std.mem.eql(u8, p.name, cfg.default_provider);
        if (p.api_key_env) |env_name| {
            const set = if (environ_map.get(env_name)) |v| v.len > 0 else false;
            if (set) usable += 1;
            // The value is never printed: doctor output gets pasted into
            // issues. Only whether the variable holds something.
            rep.line(
                if (set) .ok else if (is_default) .fail else .warn,
                p.name,
                if (set) env_name else try std.fmt.allocPrint(arena, "{s} is not set", .{env_name}),
            );
        } else if (p.service_account_file.len > 0) {
            const present = fileExists(io, p.service_account_file);
            if (present) usable += 1;
            // The path itself is not printed: it is usually under a home
            // directory and its name tends to carry the cloud project. Whether
            // the file is there is the whole answer.
            rep.line(
                if (present) .ok else if (is_default) .fail else .warn,
                p.name,
                if (present) "service account file present" else "service account file missing",
            );
        } else {
            // A local runtime (ollama, vllm) needs no credential.
            usable += 1;
            rep.line(.ok, p.name, "no credential needed");
        }
    }
    if (usable == 0) rep.line(.fail, "any usable provider", "no provider has a credential");

    rep.section("directories");
    inline for (.{
        .{ "tools_dir", cfg.agent.tools_dir },
        .{ "skills_dir", cfg.agent.skills_dir },
        .{ "state_dir", cfg.agent.state_dir },
        .{ "sandbox_root", cfg.agent.sandbox_root },
    }) |pair| {
        const present = dirExists(io, pair[1]);
        rep.line(if (present) .ok else .fail, pair[0], pair[1]);
    }
    rep.line(
        if (fileExists(io, cfg.agent.system_prompt_file)) .ok else .warn,
        "system prompt",
        cfg.agent.system_prompt_file,
    );

    rep.section("worktrees");
    if (dirExists(io, ".clanker-worktrees")) {
        var wt_count: usize = 0;
        var wt_dir = std.Io.Dir.cwd().openDir(io, ".clanker-worktrees", .{ .iterate = true }) catch null;
        if (wt_dir) |*d| {
            defer d.close(io);
            var wt_it = d.iterate();
            while (wt_it.next(io) catch null) |wt_entry| {
                if (wt_entry.kind == .directory) wt_count += 1;
            }
        }
        if (wt_count > 0) {
            rep.line(.warn, ".clanker-worktrees", try std.fmt.allocPrint(arena, "{d} worktree(s) present; a killed improve-self run leaves these behind. Run `clanker prune` to clean up.", .{wt_count}));
        } else {
            rep.line(.ok, ".clanker-worktrees", "empty");
        }
    } else {
        rep.line(.ok, ".clanker-worktrees", "none (clean)");
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
    rep.line(.ok, "manifests", try std.fmt.allocPrint(arena, "{d} registered", .{reg.tools.count()}));
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
    rep.w.writeAll("clanker doctor\n") catch {};

    try runChecks(io, arena, init.environ_map, &rep);

    rep.w.print("\n{d} failing, {d} warning\n", .{ rep.failures, rep.warnings }) catch {};
    if (rep.failures == 0) {
        rep.w.writeAll("Connectivity is not checked here: run `clanker providers check`.\n") catch {};
    }
    out.interface.flush() catch {};
    // A non-zero exit lets `clanker doctor` guard a script or a CI step.
    if (rep.failures > 0) std.process.exit(1);
}

/// Provider name to the env var it reads, for the "what could I use" hint.
/// Only providers clanker ships in config.json need an entry; anything else
/// is reported by name from the config itself.
fn wouldWork(environ_map: *std.process.Environ.Map, cfg: *const config.Config, arena: std.mem.Allocator) !?[]const u8 {
    var it = cfg.providers.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        if (p.api_key_env) |env_name| {
            if (environ_map.get(env_name)) |v| {
                if (v.len > 0) return try arena.dupe(u8, p.name);
            }
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
    if (!fileExists(io, "config.local.json")) {
        w.writeAll("  config.local.json could not be written. Check the directory is writable.\n") catch {};
        out.interface.flush() catch {};
        std.process.exit(1);
    }
    dir.createDirPath(io, "state") catch |err| {
        log.log(.warn, "setup: mkdir 'state' failed: {s}", .{@errorName(err)});
        w.print("  state/ could not be created: {s}. Check the directory is writable.\n", .{@errorName(err)}) catch {};
    };

    const cfg = config.Config.load(io, arena, dir, "config.json", "config.local.json") catch |err| {
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
        break :blk true;
    };

    if (active_ok) {
        w.print("  Default provider '{s}' has what it needs.\n", .{active}) catch {};
    } else {
        w.print("  Default provider '{s}' has no credential in this environment.\n", .{active}) catch {};
        if (try wouldWork(init.environ_map, &cfg, arena)) |other| {
            w.print("  '{s}' does. Set \"default_provider\": \"{s}\" in config.local.json to use it.\n", .{ other, other }) catch {};
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
    try std.testing.expect(std.mem.indexOf(u8, text, "iffy") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "detail") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "FAIL") != null);
}
