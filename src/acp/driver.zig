//! Orchestrates ACP-first then headless fallback for one coding-agent backend
//! run (ADR 0032 / PRD 0043). One Graph schema either way; autolearn reads it.

const std = @import("std");
const vendor = @import("vendor.zig");
const acp_client = @import("client.zig");
const fallback = @import("fallback_spawn.zig");
const graph_mod = @import("../agent/graph.zig");
const autolearn = @import("../agent/auto_learn.zig");
const subprocess = @import("../agent/subprocess.zig");
const config = @import("../config.zig");
const runtime = @import("../sandbox/runtime.zig");
const registry = @import("../toolhost/registry.zig");
const log = @import("../util/log.zig");

pub const AcpOutcome = enum {
    success,
    hang,
    handshake_failed,
    missing,
    capability_refused,
};

pub const Next = enum { done, headless };

/// Hang / missing ACP / refused capability / handshake failure all take the
/// headless path. Success is done. Not "headless or an error".
pub fn afterAcp(outcome: AcpOutcome) Next {
    return switch (outcome) {
        .success => .done,
        .hang, .handshake_failed, .missing, .capability_refused => .headless,
    };
}

pub const RunOpts = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    name: vendor.Name,
    prompt: []const u8,
    cwd: []const u8 = "",
    timeout_ms: u64 = 120_000,
    acp_argv: []const []const u8 = &.{},
    headless_argv: []const []const u8 = &.{},
    /// When set, ACP is driven over this transport instead of spawning.
    transport: ?acp_client.Transport = null,
    /// Skip ACP entirely (vendor has no ACP path).
    skip_acp: bool = false,
    cfg: ?*const config.Config = null,
    environ_map: ?*std.process.Environ.Map = null,
    reg: ?*const registry.Registry = null,
    session_id: []const u8 = "backend",
    persist: bool = true,
};

pub const RunResult = struct {
    answer: []const u8,
    run_id: []const u8,
    used_acp: bool,
    used_headless: bool,
    acp_outcome: AcpOutcome,
    graph: graph_mod.Graph,
};

pub fn run(opts: RunOpts) !RunResult {
    const started_ns = std.Io.Timestamp.now(opts.io, .real).nanoseconds;
    const started_at: i64 = @intCast(@divTrunc(started_ns, 1_000_000_000));
    const run_id = try std.fmt.allocPrint(opts.arena, "run-{d}", .{started_ns});
    var g = graph_mod.Graph{
        .run_id = run_id,
        .task = opts.prompt,
        .provider = opts.name.cliName(),
        .started_at = started_at,
    };
    const t0 = std.Io.Timestamp.now(opts.io, .awake);

    var used_acp = false;
    var used_headless = false;
    var acp_outcome: AcpOutcome = .missing;
    var answer: []const u8 = "";

    if (!opts.skip_acp) {
        acp_outcome = try runAcp(opts, &g, &answer);
        used_acp = acp_outcome == .success;
        if (acp_outcome != .success) {
            try g.add(opts.gpa, .{
                .kind = .llm,
                .iteration = 0,
                .label = "acp",
                .detail = @tagName(acp_outcome),
                .ok = false,
            });
        }
    }

    if (afterAcp(acp_outcome) == .headless) {
        const head = fallback.spawn(
            opts.io,
            opts.gpa,
            opts.arena,
            opts.name,
            opts.prompt,
            opts.cwd,
            opts.headless_argv,
        ) catch |err| switch (err) {
            error.AdapterNotFound, error.FileNotFound => {
                try g.add(opts.gpa, .{
                    .kind = .final,
                    .iteration = 1,
                    .label = "final",
                    .detail = "headless missing",
                    .ok = false,
                });
                g.duration_ms = @intCast(@divTrunc(t0.durationTo(std.Io.Timestamp.now(opts.io, .awake)).nanoseconds, std.time.ns_per_ms));
                if (opts.persist) persistAndRecord(opts, &g, false);
                return .{
                    .answer = "",
                    .run_id = run_id,
                    .used_acp = used_acp,
                    .used_headless = false,
                    .acp_outcome = acp_outcome,
                    .graph = g,
                };
            },
            else => return err,
        };
        used_headless = true;
        answer = head.stdout;
        try g.add(opts.gpa, .{
            .kind = .llm,
            .iteration = 1,
            .label = "headless",
            .output = graph_mod.truncatedPreview(answer),
            .ok = head.term_ok,
        });
        try g.add(opts.gpa, .{
            .kind = .final,
            .iteration = 1,
            .label = "final",
            .output = graph_mod.finalAnswerPreview(answer),
            .ok = head.term_ok,
        });
    }

    g.duration_ms = @intCast(@divTrunc(t0.durationTo(std.Io.Timestamp.now(opts.io, .awake)).nanoseconds, std.time.ns_per_ms));
    if (opts.persist) persistAndRecord(opts, &g, used_acp);
    return .{
        .answer = answer,
        .run_id = run_id,
        .used_acp = used_acp,
        .used_headless = used_headless,
        .acp_outcome = acp_outcome,
        .graph = g,
    };
}

fn runAcp(opts: RunOpts, g: *graph_mod.Graph, answer: *[]const u8) !AcpOutcome {
    var owned_transport: ?acp_client.ChildTransport = null;
    const transport = opts.transport orelse blk: {
        const proc_reg = subprocess.processRegistry(opts.gpa, opts.io) catch return .missing;
        const argv = vendor.acpArgv(opts.name, opts.acp_argv);
        owned_transport = acp_client.spawnTransport(
            opts.io,
            opts.gpa,
            proc_reg,
            opts.session_id,
            argv,
            opts.cwd,
        ) catch return .missing;
        break :blk owned_transport.?.transport();
    };
    var client = acp_client.Client{
        .alloc = opts.arena,
        .transport = transport,
        .timeout_ms = opts.timeout_ms,
    };
    defer client.deinit();
    const cwd = if (opts.cwd.len > 0) opts.cwd else "/tmp";
    const result = client.prompt(cwd, opts.prompt) catch |err| switch (err) {
        acp_client.Error.Hang => return .hang,
        acp_client.Error.CapabilityRefused => return .capability_refused,
        acp_client.Error.HandshakeFailed, acp_client.Error.Protocol, acp_client.Error.Closed => return .handshake_failed,
        else => return .handshake_failed,
    };
    // Client.deinit frees answer_buf; persist and stdout run after that.
    answer.* = try opts.arena.dupe(u8, result.answer);
    var iteration: u32 = 0;
    for (result.updates) |u| {
        iteration += 1;
        if (std.mem.eql(u8, u.kind, "tool_call") or std.mem.eql(u8, u.kind, "tool_call_update")) {
            try g.add(opts.gpa, .{
                .kind = .tool,
                .iteration = iteration,
                .label = if (u.tool_name.len > 0) u.tool_name else "tool",
                .output = graph_mod.truncatedPreview(u.text),
                .ok = true,
            });
        } else {
            try g.add(opts.gpa, .{
                .kind = .llm,
                .iteration = iteration,
                .label = "acp",
                .output = graph_mod.truncatedPreview(u.text),
                .ok = true,
            });
        }
    }
    try g.add(opts.gpa, .{
        .kind = .final,
        .iteration = iteration + 1,
        .label = "final",
        .output = graph_mod.finalAnswerPreview(answer.*),
        .detail = result.stop_reason,
        .ok = true,
    });
    return .success;
}

fn persistAndRecord(opts: RunOpts, g: *const graph_mod.Graph, used_acp: bool) void {
    if (opts.cfg) |cfg| {
        if (cfg.modules.graphs) {
            if (opts.reg) |reg| {
                if (opts.environ_map) |env| {
                    persistGraph(opts, cfg, reg, env, g) catch |err| {
                        log.log(.warn, "backend graph write failed: {s}", .{@errorName(err)});
                    };
                }
            }
        }
        if (cfg.modules.autolearn) {
            autolearn.recordRun(opts.io, opts.gpa, opts.arena, .{
                .provider = opts.name.cliName(),
                .model = if (used_acp) "acp" else "headless",
                .duration_ms = g.duration_ms,
            });
        }
    }
}

fn persistGraph(
    opts: RunOpts,
    cfg: *const config.Config,
    reg: *const registry.Registry,
    env: *std.process.Environ.Map,
    g: *const graph_mod.Graph,
) !void {
    const payload = try graph_mod.encodeWrite(opts.arena, g);
    const mod = try runtime.loadNamedTool(opts.gpa, opts.io, opts.arena, env, cfg, reg, "graph", null);
    defer mod.deinit();
    const raw = try mod.executeTool(payload);
    defer opts.gpa.free(raw);
    const resp = std.json.parseFromSliceLeaky(struct { ok: bool = false, @"error": []const u8 = "" }, opts.arena, raw, .{ .ignore_unknown_fields = true }) catch return;
    if (!resp.ok) log.log(.warn, "backend graph write: {s}", .{resp.@"error"});
}

/// Map ACP-shaped updates onto existing NodeKind values.
pub fn nodesFromUpdates(gpa: std.mem.Allocator, g: *graph_mod.Graph, updates: []const acp_client.Update, answer: []const u8) !void {
    var iteration: u32 = 0;
    for (updates) |u| {
        iteration += 1;
        if (std.mem.eql(u8, u.kind, "tool_call") or std.mem.eql(u8, u.kind, "tool_call_update")) {
            try g.add(gpa, .{
                .kind = .tool,
                .iteration = iteration,
                .label = if (u.tool_name.len > 0) u.tool_name else "tool",
                .output = graph_mod.truncatedPreview(u.text),
            });
        } else {
            try g.add(gpa, .{
                .kind = .llm,
                .iteration = iteration,
                .label = "acp",
                .output = graph_mod.truncatedPreview(u.text),
            });
        }
    }
    try g.add(gpa, .{
        .kind = .final,
        .iteration = iteration + 1,
        .label = "final",
        .output = graph_mod.finalAnswerPreview(answer),
    });
}

pub fn nodesFromHeadless(gpa: std.mem.Allocator, g: *graph_mod.Graph, stdout: []const u8) !void {
    try g.add(gpa, .{
        .kind = .llm,
        .iteration = 1,
        .label = "headless",
        .output = graph_mod.truncatedPreview(stdout),
    });
    try g.add(gpa, .{
        .kind = .final,
        .iteration = 1,
        .label = "final",
        .output = graph_mod.finalAnswerPreview(stdout),
    });
}

test "afterAcp: hang, missing, refused, and handshake all take headless, not an error" {
    try std.testing.expectEqual(Next.done, afterAcp(.success));
    try std.testing.expectEqual(Next.headless, afterAcp(.hang));
    try std.testing.expectEqual(Next.headless, afterAcp(.missing));
    try std.testing.expectEqual(Next.headless, afterAcp(.handshake_failed));
    try std.testing.expectEqual(Next.headless, afterAcp(.capability_refused));
}

test "ACP-shaped updates map onto tool/llm/final NodeKind" {
    var g = graph_mod.Graph{ .run_id = "run-1", .task = "t", .started_at = 0 };
    defer g.deinit(std.testing.allocator);
    const updates = [_]acp_client.Update{
        .{ .kind = "agent_message_chunk", .text = "hello" },
        .{ .kind = "tool_call", .tool_name = "edit", .text = "ok" },
    };
    try nodesFromUpdates(std.testing.allocator, &g, &updates, "hello");
    try std.testing.expectEqual(@as(usize, 3), g.nodes.items.len);
    try std.testing.expectEqual(graph_mod.NodeKind.llm, g.nodes.items[0].kind);
    try std.testing.expectEqual(graph_mod.NodeKind.tool, g.nodes.items[1].kind);
    try std.testing.expectEqualStrings("edit", g.nodes.items[1].label);
    try std.testing.expectEqual(graph_mod.NodeKind.final, g.nodes.items[2].kind);
}

test "headless writes a degraded llm/final pair" {
    var g = graph_mod.Graph{ .run_id = "run-1", .task = "t", .started_at = 0 };
    defer g.deinit(std.testing.allocator);
    try nodesFromHeadless(std.testing.allocator, &g, "stdout-answer");
    try std.testing.expectEqual(@as(usize, 2), g.nodes.items.len);
    try std.testing.expectEqual(graph_mod.NodeKind.llm, g.nodes.items[0].kind);
    try std.testing.expectEqual(graph_mod.NodeKind.final, g.nodes.items[1].kind);
    try std.testing.expectEqualStrings("stdout-answer", g.nodes.items[1].output);
}

test "hang then headless persists a failed ACP node before the degraded pair" {
    var g = graph_mod.Graph{ .run_id = "run-hang", .task = "t", .provider = "grok", .started_at = 0 };
    defer g.deinit(std.testing.allocator);
    try g.add(std.testing.allocator, .{
        .kind = .llm,
        .iteration = 0,
        .label = "acp",
        .detail = "hang",
        .ok = false,
    });
    try nodesFromHeadless(std.testing.allocator, &g, "recovered");
    try std.testing.expectEqual(@as(usize, 3), g.nodes.items.len);
    try std.testing.expect(!g.nodes.items[0].ok);
    try std.testing.expectEqualStrings("hang", g.nodes.items[0].detail);
    try std.testing.expectEqual(graph_mod.NodeKind.llm, g.nodes.items[1].kind);
    try std.testing.expectEqual(graph_mod.NodeKind.final, g.nodes.items[2].kind);
}

test "encodeWrite payload is the graph-guest write action with NodeKind names" {
    var g = graph_mod.Graph{ .run_id = "run-enc", .task = "do", .provider = "grok", .started_at = 1 };
    defer g.deinit(std.testing.allocator);
    try nodesFromUpdates(std.testing.allocator, &g, &.{.{ .kind = "agent_message_chunk", .text = "hi" }}, "hi");
    const payload = try graph_mod.encodeWrite(std.testing.allocator, &g);
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.find(u8, payload, "\"write\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"kind\":\"llm\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"kind\":\"final\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "run-enc") != null);
}
