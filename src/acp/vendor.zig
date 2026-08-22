//! Named coding-agent backends clanker can drive (ADR 0032 / PRD 0043).
//!
//! The names are the operator-facing selector (`--backend`, `[agent] backend`,
//! `POST /api/run` `backend`). An unknown name is refused. ACP and headless
//! argv templates live here so tests can assert them without spawning a
//! vendor CLI.

const std = @import("std");
const test_env = @import("../util/test_env.zig");

pub const Name = enum {
    grok,
    claude,
    codex,

    pub fn parse(s: []const u8) ?Name {
        if (s.len == 0) return null;
        inline for (std.enums.values(Name)) |n| {
            if (std.mem.eql(u8, s, @tagName(n))) return n;
        }
        return null;
    }

    pub fn cliName(self: Name) []const u8 {
        return @tagName(self);
    }
};

/// Default ACP spawn argv for this vendor. Grok speaks first-party
/// `agent stdio`; Claude and Codex go through the published adapters.
pub fn defaultAcpArgv(name: Name) []const []const u8 {
    return switch (name) {
        .grok => &.{ "grok", "agent", "stdio" },
        .claude => &.{ "npx", "-y", "@agentclientprotocol/claude-agent-acp" },
        .codex => &.{ "npx", "-y", "@agentclientprotocol/codex-acp" },
    };
}

/// First-party headless argv. The prompt is the last argument.
pub fn headlessArgv(alloc: std.mem.Allocator, name: Name, prompt: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (name) {
        .grok => {
            try out.append(alloc, "grok");
            try out.append(alloc, "-p");
        },
        .claude => {
            try out.append(alloc, "claude");
            try out.append(alloc, "-p");
        },
        .codex => {
            try out.append(alloc, "codex");
            try out.append(alloc, "exec");
        },
    }
    try out.append(alloc, prompt);
    return out.toOwnedSlice(alloc);
}

/// Whether `name` is an executable on `path_env` (`:`-separated).
pub fn onPath(io: std.Io, name: []const u8, path_env: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.findScalar(u8, name, '/') != null) {
        std.Io.Dir.cwd().access(io, name, .{}) catch return false;
        return true;
    }
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const joined = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch continue;
        std.Io.Dir.cwd().access(io, joined, .{}) catch continue;
        return true;
    }
    return false;
}

/// A backend is listed when its vendor CLI is on PATH, or when a configured
/// ACP command's argv[0] exists (the configured-command half of PRD 0043).
pub fn installed(io: std.Io, name: Name, path_env: []const u8, configured_argv0: []const u8) bool {
    if (configured_argv0.len > 0) return onPath(io, configured_argv0, path_env);
    return onPath(io, name.cliName(), path_env);
}

/// The argv actually spawned for ACP: a configured override wins, otherwise
/// the vendor default.
pub fn acpArgv(name: Name, configured: []const []const u8) []const []const u8 {
    if (configured.len > 0) return configured;
    return defaultAcpArgv(name);
}

test "parse accepts the three vendor names and refuses anything else" {
    try std.testing.expectEqual(Name.grok, Name.parse("grok").?);
    try std.testing.expectEqual(Name.claude, Name.parse("claude").?);
    try std.testing.expectEqual(Name.codex, Name.parse("codex").?);
    try std.testing.expect(Name.parse("") == null);
    try std.testing.expect(Name.parse("openai") == null);
    try std.testing.expect(Name.parse("Grok") == null);
    try std.testing.expect(Name.parse("claude-code") == null);
}

test "ACP and headless argv match the published vendor interfaces" {
    const grok_acp = defaultAcpArgv(.grok);
    try std.testing.expectEqual(@as(usize, 3), grok_acp.len);
    try std.testing.expectEqualStrings("grok", grok_acp[0]);
    try std.testing.expectEqualStrings("agent", grok_acp[1]);
    try std.testing.expectEqualStrings("stdio", grok_acp[2]);

    const claude_acp = defaultAcpArgv(.claude);
    try std.testing.expectEqualStrings("npx", claude_acp[0]);
    try std.testing.expectEqualStrings("@agentclientprotocol/claude-agent-acp", claude_acp[2]);

    const codex_acp = defaultAcpArgv(.codex);
    try std.testing.expectEqualStrings("npx", codex_acp[0]);
    try std.testing.expectEqualStrings("@agentclientprotocol/codex-acp", codex_acp[2]);

    const grok_h = try headlessArgv(std.testing.allocator, .grok, "do the thing");
    defer std.testing.allocator.free(grok_h);
    try std.testing.expectEqualStrings("grok", grok_h[0]);
    try std.testing.expectEqualStrings("-p", grok_h[1]);
    try std.testing.expectEqualStrings("do the thing", grok_h[2]);

    const claude_h = try headlessArgv(std.testing.allocator, .claude, "x");
    defer std.testing.allocator.free(claude_h);
    try std.testing.expectEqualStrings("claude", claude_h[0]);
    try std.testing.expectEqualStrings("-p", claude_h[1]);

    const codex_h = try headlessArgv(std.testing.allocator, .codex, "x");
    defer std.testing.allocator.free(codex_h);
    try std.testing.expectEqualStrings("codex", codex_h[0]);
    try std.testing.expectEqualStrings("exec", codex_h[1]);
    try std.testing.expectEqualStrings("x", codex_h[2]);
}

test "a configured ACP argv overrides the vendor default" {
    const override = [_][]const u8{ "/tmp/fake-acp", "--stdio" };
    const got = acpArgv(.grok, &override);
    try std.testing.expectEqualStrings("/tmp/fake-acp", got[0]);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    const fallback = acpArgv(.grok, &.{});
    try std.testing.expectEqualStrings("grok", fallback[0]);
}

test "installed is PATH presence, not an API key" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const io = env.io();
    const file = try env.tmp.dir.createFile(io, "grok", .{});
    file.close(io);

    const dir_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{env.tmp.sub_path});
    defer std.testing.allocator.free(dir_path);

    try std.testing.expect(installed(io, .grok, dir_path, ""));
    try std.testing.expect(!installed(io, .claude, dir_path, ""));
    try std.testing.expect(!installed(io, .codex, dir_path, ""));
    try std.testing.expect(!installed(io, .grok, "/no/such/path", ""));
    // A configured command whose argv[0] exists counts as installed even when
    // the vendor CLI name is absent from PATH.
    const grok_bin = try std.fmt.allocPrint(std.testing.allocator, "{s}/grok", .{dir_path});
    defer std.testing.allocator.free(grok_bin);
    try std.testing.expect(installed(io, .claude, "/no/such/path", grok_bin));
}
