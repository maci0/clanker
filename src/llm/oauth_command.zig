//! Operator-facing native OAuth lifecycle. Provider differences live in the
//! plugin's flow tag and metadata; this command never shells out to a vendor
//! CLI and never reads another application's credential store.

const std = @import("std");
const config = @import("../config.zig");
const native = @import("oauth_native.zig");
const plugins = @import("oauth_plugins/registry.zig");
const store = @import("oauth_store.zig");

pub fn status(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, cfg: *const config.Config, provider_name: ?[]const u8, environ: *const std.process.Environ.Map, out: *std.Io.Writer) !void {
    for (plugins.plugins) |plugin| {
        if (provider_name) |wanted| if (!std.mem.eql(u8, wanted, plugin.name)) continue;
        const record = try store.load(io, dir, alloc, cfg.agent.state_dir, plugin.name);
        const key = environ.get(plugin.api_key_env);
        try out.print("{s}: oauth={s} api_key={s}", .{ plugin.name, if (record != null) "logged-in" else "logged-out", if (key != null and key.?.len > 0) "set" else "unset" });
        if (record) |r| {
            if (r.expires_at_ms > 0) try out.print(" expires_at_ms={d}", .{r.expires_at_ms});
        }
        try out.writeAll("\n");
    }
    if (provider_name) |wanted| if (plugins.find(wanted) == null) return error.UnknownOAuthPlugin;
}

pub fn logout(io: std.Io, dir: std.Io.Dir, alloc: std.mem.Allocator, cfg: *const config.Config, provider_name: []const u8) !bool {
    _ = plugins.find(provider_name) orelse return error.UnknownOAuthPlugin;
    return store.remove(io, dir, alloc, cfg.agent.state_dir, provider_name);
}

pub fn login(init: std.process.Init, cfg: *const config.Config, provider_name: []const u8, out: *std.Io.Writer) !void {
    const plugin = (plugins.find(provider_name) orelse return error.UnknownOAuthPlugin).*;
    const arena = init.arena.allocator();
    const record = switch (plugin.flow) {
        .device_code => try loginDevice(init, arena, plugin, out),
        .codex_device => try loginCodexDevice(init, arena, plugin, out),
        .pkce_manual => try loginManual(init, arena, plugin, out),
    };
    try store.save(init.io, std.Io.Dir.cwd(), arena, cfg.agent.state_dir, plugin.name, record);
    try out.print("{s}: OAuth login saved\n", .{plugin.name});
}

fn loginDevice(init: std.process.Init, arena: std.mem.Allocator, plugin: @import("oauth_plugins/api.zig").Plugin, out: *std.Io.Writer) !store.Record {
    const device = try native.requestDeviceAuthorization(init.io, init.gpa, arena, plugin);
    const url = if (device.verification_uri_complete.len > 0) device.verification_uri_complete else device.verification_uri;
    try out.print("Open {s}\nEnter code: {s}\nWaiting for authorization...\n", .{ url, device.user_code });
    try out.flush();
    var interval = device.interval;
    const started = std.Io.Timestamp.now(init.io, .awake);
    while (started.durationTo(std.Io.Timestamp.now(init.io, .awake)).nanoseconds < @as(i96, device.expires_in) * std.time.ns_per_s) {
        try std.Io.sleep(init.io, .{ .nanoseconds = @as(i96, interval) * std.time.ns_per_s }, .awake);
        switch (try native.pollDeviceOnce(init.io, init.gpa, arena, plugin, device.device_code, nowMs(init.io))) {
            .token => |record| return record,
            .wait => |reason| switch (reason) {
                .pending => {},
                .slow_down => interval = @min(interval + 5, 60),
                .expired => return error.OAuthDeviceExpired,
                .denied => return error.OAuthDeviceDenied,
                .rejected => return error.OAuthDeviceRejected,
            },
        }
    }
    return error.OAuthDeviceExpired;
}

fn loginCodexDevice(init: std.process.Init, arena: std.mem.Allocator, plugin: @import("oauth_plugins/api.zig").Plugin, out: *std.Io.Writer) !store.Record {
    const device = try native.requestCodexDeviceAuthorization(init.io, init.gpa, arena, plugin);
    try out.print("Open {s}\nEnter code: {s}\nWaiting for authorization...\n", .{ device.verification_uri, device.user_code });
    try out.flush();
    const started = std.Io.Timestamp.now(init.io, .awake);
    while (started.durationTo(std.Io.Timestamp.now(init.io, .awake)).nanoseconds < 15 * std.time.ns_per_min) {
        try std.Io.sleep(init.io, .{ .nanoseconds = @as(i96, device.interval) * std.time.ns_per_s }, .awake);
        if (try native.pollCodexDeviceOnce(init.io, init.gpa, arena, plugin, device)) |grant|
            return native.exchangeAuthorizationCode(init.io, init.gpa, arena, plugin, grant.code, grant.verifier, "", nowMs(init.io));
    }
    return error.OAuthDeviceExpired;
}

fn loginManual(init: std.process.Init, arena: std.mem.Allocator, plugin: @import("oauth_plugins/api.zig").Plugin, out: *std.Io.Writer) !store.Record {
    const pkce = try native.generatePkce(init.io, arena);
    const state_pkce = try native.generatePkce(init.io, arena);
    const state = state_pkce.verifier;
    const url = try native.authorizationUrl(arena, plugin, pkce, state);
    try out.print("Open this URL:\n{s}\nPaste the returned code: ", .{url});
    try out.flush();
    var input: [8192]u8 = undefined;
    const n = try std.Io.File.stdin().readStreaming(init.io, &.{&input});
    const pasted = std.mem.trim(u8, input[0..n], " \t\r\n");
    if (pasted.len == 0) return error.MissingOAuthCode;
    const hash = std.mem.findScalar(u8, pasted, '#');
    const code = if (hash) |i| pasted[0..i] else pasted;
    if (hash) |i| if (!std.mem.eql(u8, pasted[i + 1 ..], state)) return error.OAuthStateMismatch;
    return native.exchangeAuthorizationCode(init.io, init.gpa, arena, plugin, code, pkce.verifier, state, nowMs(init.io));
}

fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

test "OAuth command status never prints stored token values" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg: config.Config = .{};
    cfg.agent.state_dir = "state";
    try store.save(threaded.io(), tmp.dir, arena, "state", "codex", .{ .access_token = "never-print-me", .refresh_token = "nor-this", .expires_at_ms = 42 });
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var writer: std.Io.Writer.Allocating = .init(arena);
    try status(threaded.io(), tmp.dir, arena, &cfg, "codex", &env, &writer.writer);
    try std.testing.expect(std.mem.find(u8, writer.written(), "oauth=logged-in") != null);
    try std.testing.expect(std.mem.find(u8, writer.written(), "never-print-me") == null);
    try std.testing.expect(std.mem.find(u8, writer.written(), "nor-this") == null);
}
