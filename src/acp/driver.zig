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
const llm_types = @import("../llm/types.zig");

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

/// Goal-loop work turns (CLI, TUI, HTTP) call this: empty `backend` means the
/// caller should run the in-process Agent; a named backend runs `run`.
pub fn runIfBackend(opts: RunOpts, backend: []const u8) !?RunResult {
    if (backend.len == 0) return null;
    const name = vendor.Name.parse(backend) orelse return error.BadBackend;
    var o = opts;
    o.name = name;
    return try run(o);
}

pub const RunOpts = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    name: vendor.Name,
    prompt: []const u8,
    /// Image attachments for this turn. Path A sends them as ACP `image`
    /// ContentBlocks; path B has no pinned image argv for any vendor, so a
    /// headless run with images refuses instead of spawning text-only. Empty for
    /// every text run, which is all of them today outside the HTTP composer.
    images: []const llm_types.ImagePart = &.{},
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
    /// Tests pass a local process table so they do not leak the process-global
    /// registry. Production leaves this null and uses `processRegistry`.
    acp_reg: ?*subprocess.Registry = null,
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
        // PRD 0043: "Headless image argv for `claude -p`, `codex exec`, and
        // `grok -p` is unset until pinned at each vendor CLI help/docs", and the
        // settled policy for that state is a named refusal, never a text-only
        // spawn. Stripping the images and carrying on is the one outcome the PRD
        // forbids outright, because the run then returns 200 with the child
        // having seen only text and nothing anywhere says so.
        //
        // This fires only when ACP already declined the turn, so it is not a
        // refusal of image support: path A carries images. It is a refusal to
        // pretend the fallback does.
        if (opts.images.len > 0) {
            try g.add(opts.gpa, .{
                .kind = .final,
                .iteration = 1,
                .label = "final",
                .detail = "headless cannot carry image attachments",
                .ok = false,
            });
            g.duration_ms = @intCast(@divTrunc(t0.durationTo(std.Io.Timestamp.now(opts.io, .awake)).nanoseconds, std.time.ns_per_ms));
            if (opts.persist) persistAndRecord(opts, &g, false);
            // Every other exit from this function hands the Graph to the caller
            // inside a RunResult and the caller deinits it. This one returns an
            // error instead, so the node added just above is ours to free.
            g.deinit(opts.gpa);
            return error.HeadlessImagesUnsupported;
        }
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
        try nodesFromHeadless(opts.gpa, &g, answer, head.term_ok);
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
        const proc_reg = opts.acp_reg orelse (subprocess.processRegistry(opts.gpa, opts.io) catch return .missing);
        const argv = vendor.acpArgv(opts.name, opts.acp_argv);
        owned_transport = acp_client.spawnTransport(
            opts.io,
            opts.gpa,
            proc_reg,
            opts.session_id,
            argv,
            opts.cwd,
            opts.timeout_ms,
        ) catch return .missing;
        break :blk owned_transport.?.transport();
    };
    defer if (owned_transport) |*t| t.reg.terminate(t.session_id, "acp");
    var client = acp_client.Client{
        .alloc = opts.arena,
        .transport = transport,
        .timeout_ms = opts.timeout_ms,
    };
    defer client.deinit();
    const cwd = if (opts.cwd.len > 0) opts.cwd else "/tmp";
    const result = client.promptWith(cwd, opts.prompt, opts.images) catch |err| switch (err) {
        acp_client.Error.Hang => return .hang,
        acp_client.Error.CapabilityRefused => return .capability_refused,
        acp_client.Error.HandshakeFailed, acp_client.Error.Protocol, acp_client.Error.Closed => return .handshake_failed,
        else => return .handshake_failed,
    };
    // Client.deinit frees answer_buf; persist and stdout run after that.
    answer.* = try opts.arena.dupe(u8, result.answer);
    try nodesFromUpdates(opts.gpa, g, result.updates, answer.*, result.stop_reason);
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

/// Map ACP-shaped updates onto existing NodeKind values. This is the one
/// builder for the ACP success path: runAcp calls it, so the tests below
/// exercise the same code production runs.
pub fn nodesFromUpdates(gpa: std.mem.Allocator, g: *graph_mod.Graph, updates: []const acp_client.Update, answer: []const u8, stop_reason: []const u8) !void {
    var iteration: u32 = 0;
    for (updates) |u| {
        iteration += 1;
        if (std.mem.eql(u8, u.kind, "tool_call") or std.mem.eql(u8, u.kind, "tool_call_update")) {
            try g.add(gpa, .{
                .kind = .tool,
                .iteration = iteration,
                .label = if (u.tool_name.len > 0) u.tool_name else "tool",
                .output = graph_mod.truncatedPreview(u.text),
                .ok = true,
            });
        } else {
            try g.add(gpa, .{
                .kind = .llm,
                .iteration = iteration,
                .label = "acp",
                .output = graph_mod.truncatedPreview(u.text),
                .ok = true,
            });
        }
    }
    try g.add(gpa, .{
        .kind = .final,
        .iteration = iteration + 1,
        .label = "final",
        .output = graph_mod.finalAnswerPreview(answer),
        .detail = stop_reason,
        .ok = true,
    });
}

/// The degraded pair a headless fallback writes: the child's exit status is
/// what lands in `ok`, not a constant.
pub fn nodesFromHeadless(gpa: std.mem.Allocator, g: *graph_mod.Graph, stdout: []const u8, term_ok: bool) !void {
    try g.add(gpa, .{
        .kind = .llm,
        .iteration = 1,
        .label = "headless",
        .output = graph_mod.truncatedPreview(stdout),
        .ok = term_ok,
    });
    try g.add(gpa, .{
        .kind = .final,
        .iteration = 1,
        .label = "final",
        .output = graph_mod.finalAnswerPreview(stdout),
        .ok = term_ok,
    });
}

test "images reach the ACP child as image ContentBlocks, and the headless path refuses instead of dropping them" {
    // PRD 0043 Goal 6. Two behaviours it forbids outright, both of which shipped:
    //
    //   1. a 200 with the child having seen only the text, and
    //   2. a text-only headless spawn that silently strips the images.
    //
    // Driven through the shipped `run` against the fake ACP agent, which echoes
    // the prompt blocks it actually received when FAKE_ACP_ECHO_PROMPT=1. The
    // assertion is on what crossed the wire, not on what the caller believed it
    // sent, and not on a pre-built Graph.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var proc_reg = subprocess.Registry.init(std.testing.allocator, io);
    defer proc_reg.deinit();

    const images = [_]llm_types.ImagePart{
        .{ .mime = "image/png", .b64 = "AAAAPNGPAYLOAD" },
        .{ .mime = "image/jpeg", .b64 = "BBBBJPEGPAYLOAD" },
        // Skipped: neither half of a block can be empty.
        .{ .mime = "", .b64 = "CCCCNOMIME" },
    };

    const base = RunOpts{
        .io = io,
        .gpa = std.testing.allocator,
        .arena = arena_state.allocator(),
        .name = .grok,
        .prompt = "look at this ECHO-BLOCKS",
        .images = &images,
        .timeout_ms = 5000,
        .acp_argv = &.{ "python3", "tests/fixtures/fake-acp-agent.py" },
        .persist = false,
        .session_id = "imgblocks",
        .acp_reg = &proc_reg,
    };

    // Path A: the blocks are on the wire, text first, then one per usable image.
    {
        var result = run(base) catch |err| switch (err) {
            error.FileNotFound, error.AdapterNotFound => return error.SkipZigTest,
            else => return err,
        };
        defer result.graph.deinit(std.testing.allocator);
        try std.testing.expect(result.used_acp);

        const echoed = result.answer;
        try std.testing.expect(std.mem.find(u8, echoed, "block:text/-/look at this ECHO-BLOCKS") != null);
        try std.testing.expect(std.mem.find(u8, echoed, "block:image/image/png/AAAAPNGPAYLOAD") != null);
        try std.testing.expect(std.mem.find(u8, echoed, "block:image/image/jpeg/BBBBJPEGPAYLOAD") != null);
        // The half-empty part was dropped rather than sent as a zero-byte image.
        try std.testing.expect(std.mem.find(u8, echoed, "CCCCNOMIME") == null);
    }

    // Path B with images: a named refusal, never a text-only spawn. `skip_acp`
    // is how a vendor with no ACP arrives here, which is the case the PRD's
    // failure table covers.
    {
        var headless = base;
        headless.skip_acp = true;
        headless.session_id = "imgheadless";
        headless.headless_argv = &.{ "python3", "tests/fixtures/fake-acp-agent.py", "-p", "look at this" };
        try std.testing.expectError(error.HeadlessImagesUnsupported, run(headless));
    }

    // Control: the same headless run without images still works, so the refusal
    // above is about the attachments and not about the spawn being broken.
    {
        var text_only = base;
        text_only.skip_acp = true;
        text_only.images = &.{};
        text_only.session_id = "imgheadlesstext";
        text_only.headless_argv = &.{ "python3", "tests/fixtures/fake-acp-agent.py", "-p", "look at this" };
        var result = run(text_only) catch |err| switch (err) {
            error.FileNotFound, error.AdapterNotFound => return error.SkipZigTest,
            else => return err,
        };
        defer result.graph.deinit(std.testing.allocator);
        try std.testing.expect(result.used_headless);
        try std.testing.expect(std.mem.find(u8, result.answer, "fake-headless-answer") != null);
    }
}

test "promptParams keeps text required-first and omits a half-empty image" {
    const alloc = std.testing.allocator;
    const only_text = try acp_client.promptParamsForTest(alloc, "s1", "hello", &.{});
    defer alloc.free(only_text);
    try std.testing.expectEqualStrings(
        "{\"sessionId\":\"s1\",\"prompt\":[{\"type\":\"text\",\"text\":\"hello\"}]}",
        only_text,
    );

    const with_image = try acp_client.promptParamsForTest(alloc, "s1", "hi", &.{
        .{ .mime = "image/png", .b64 = "Zm8=" },
        .{ .mime = "image/png", .b64 = "" },
        .{ .mime = "", .b64 = "Zm8=" },
    });
    defer alloc.free(with_image);
    try std.testing.expectEqualStrings(
        "{\"sessionId\":\"s1\",\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}," ++
            "{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"Zm8=\"}]}",
        with_image,
    );
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
    try nodesFromUpdates(std.testing.allocator, &g, &updates, "hello", "end_turn");
    try std.testing.expectEqual(@as(usize, 3), g.nodes.items.len);
    try std.testing.expectEqual(graph_mod.NodeKind.llm, g.nodes.items[0].kind);
    try std.testing.expectEqual(graph_mod.NodeKind.tool, g.nodes.items[1].kind);
    try std.testing.expectEqual(graph_mod.NodeKind.final, g.nodes.items[2].kind);
    // The success path stamps ok and carries the vendor stop reason on the
    // final node: both are what runAcp's inline copy used to add by hand.
    for (g.nodes.items) |n| try std.testing.expect(n.ok);
    try std.testing.expectEqualStrings("edit", g.nodes.items[1].label);
    try std.testing.expectEqualStrings("end_turn", g.nodes.items[2].detail);
}

test "headless writes a degraded llm/final pair" {
    var g = graph_mod.Graph{ .run_id = "run-1", .task = "t", .started_at = 0 };
    defer g.deinit(std.testing.allocator);
    // term_ok=false: a failed child must not read as a healthy run in the
    // graph, so the exit status has to propagate to both nodes.
    try nodesFromHeadless(std.testing.allocator, &g, "stdout-answer", false);
    try std.testing.expectEqual(@as(usize, 2), g.nodes.items.len);
    try std.testing.expectEqual(graph_mod.NodeKind.llm, g.nodes.items[0].kind);
    try std.testing.expectEqual(graph_mod.NodeKind.final, g.nodes.items[1].kind);
    try std.testing.expectEqualStrings("headless", g.nodes.items[0].label);
    for (g.nodes.items) |n| try std.testing.expect(!n.ok);
    try std.testing.expectEqualStrings("stdout-answer", g.nodes.items[0].output);
    try std.testing.expectEqualStrings("stdout-answer", g.nodes.items[1].output);

    var ok_g = graph_mod.Graph{ .run_id = "run-2", .task = "t", .started_at = 0 };
    defer ok_g.deinit(std.testing.allocator);
    try nodesFromHeadless(std.testing.allocator, &ok_g, "fine", true);
    for (ok_g.nodes.items) |n| try std.testing.expect(n.ok);
}

test "driver.run hangs a blocking child, persists a failed ACP node, then headless" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var proc_reg = subprocess.Registry.init(std.testing.allocator, io);
    defer proc_reg.deinit();
    // `sleep` never writes ACP JSON-RPC; the watchdog must kill it so
    // readStreaming unblocks, rather than waiting out the child's 30s.
    const acp_argv = [_][]const u8{ "sleep", "30" };
    const headless_argv = [_][]const u8{ "printf", "recovered-from-hang" };
    var result = try run(.{
        .io = io,
        .gpa = std.testing.allocator,
        .arena = arena,
        .name = .grok,
        .prompt = "hello",
        .timeout_ms = 200,
        .acp_argv = &acp_argv,
        .headless_argv = &headless_argv,
        .persist = false,
        .session_id = "hangchild1",
        .acp_reg = &proc_reg,
    });
    defer result.graph.deinit(std.testing.allocator);
    try std.testing.expectEqual(AcpOutcome.hang, result.acp_outcome);
    try std.testing.expect(result.used_headless);
    try std.testing.expect(!result.used_acp);
    try std.testing.expectEqualStrings("recovered-from-hang", result.answer);
    try std.testing.expect(result.graph.nodes.items.len >= 3);
    try std.testing.expect(!result.graph.nodes.items[0].ok);
    try std.testing.expectEqualStrings("hang", result.graph.nodes.items[0].detail);
    try std.testing.expectEqual(graph_mod.NodeKind.llm, result.graph.nodes.items[1].kind);
    try std.testing.expectEqual(graph_mod.NodeKind.final, result.graph.nodes.items[2].kind);
}

const LogBuf = struct {
    mu: std.atomic.Mutex = .unlocked,
    bytes: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,

    fn write(ctx: *const anyopaque, line: []const u8) void {
        const self: *LogBuf = @ptrCast(@alignCast(@constCast(ctx)));
        while (!self.mu.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.mu.unlock();
        self.bytes.appendSlice(self.alloc, line) catch {};
    }
};

test "driver.run spawn path does not log a token present in the child environment" {
    var tenv: @import("../util/test_env.zig").Env = .init();
    defer tenv.deinit();
    const io = tenv.io();
    const arena = tenv.arena();
    const token = "sekrit-token-xyz-backend";
    const script = try std.fmt.allocPrint(arena,
        \\#!/bin/sh
        \\export SEKRIT_VENDOR_TOKEN={s}
        \\printf %s "$SEKRIT_VENDOR_TOKEN" > "$1"
        \\shift
        \\exec python3 tests/fixtures/fake-acp-agent.py
        \\
    , .{token});
    try tenv.tmp.dir.writeFile(io, .{ .sub_path = "wrap.sh", .data = script });
    const wrap = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/wrap.sh", .{tenv.tmp.sub_path});
    const probe = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/probe", .{tenv.tmp.sub_path});
    var proc_reg = subprocess.Registry.init(std.testing.allocator, io);
    defer proc_reg.deinit();

    var logs = LogBuf{ .alloc = std.testing.allocator };
    defer logs.bytes.deinit(std.testing.allocator);
    log.setSink(.{ .ctx = @ptrCast(&logs), .write = LogBuf.write });
    defer log.setSink(null);

    const acp_argv = [_][]const u8{ "sh", wrap, probe };
    var result = try run(.{
        .io = io,
        .gpa = std.testing.allocator,
        .arena = arena,
        .name = .grok,
        .prompt = "hello",
        .timeout_ms = 3000,
        .acp_argv = &acp_argv,
        .persist = false,
        .session_id = "credchild1",
        .acp_reg = &proc_reg,
    });
    defer result.graph.deinit(std.testing.allocator);
    try std.testing.expect(result.used_acp or result.used_headless);
    try std.testing.expect(std.mem.find(u8, logs.bytes.items, token) == null);
    for (acp_argv) |a| try std.testing.expect(std.mem.find(u8, a, token) == null);
    const inherited = tenv.tmp.dir.readFileAlloc(io, "probe", std.testing.allocator, .limited(256)) catch "";
    defer if (inherited.len > 0) std.testing.allocator.free(inherited);
    try std.testing.expectEqualStrings(token, inherited);
}

test "runIfBackend is empty for the in-process loop and runs the driver when named" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var proc_reg = subprocess.Registry.init(std.testing.allocator, io);
    defer proc_reg.deinit();
    const base = RunOpts{
        .io = io,
        .gpa = std.testing.allocator,
        .arena = arena_state.allocator(),
        .name = .grok,
        .prompt = "hello",
        .timeout_ms = 3000,
        .acp_argv = &.{ "python3", "tests/fixtures/fake-acp-agent.py" },
        .persist = false,
        .session_id = "goalif1",
        .acp_reg = &proc_reg,
    };
    try std.testing.expect(try runIfBackend(base, "") == null);
    var result = (try runIfBackend(base, "grok")).?;
    defer result.graph.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, result.answer, "fake-acp-answer") != null);
}

test "encodeWrite payload is the graph-guest write action with NodeKind names" {
    var g = graph_mod.Graph{ .run_id = "run-enc", .task = "do", .provider = "grok", .started_at = 1 };
    defer g.deinit(std.testing.allocator);
    try nodesFromUpdates(std.testing.allocator, &g, &.{.{ .kind = "agent_message_chunk", .text = "hi" }}, "hi", "end_turn");
    const payload = try graph_mod.encodeWrite(std.testing.allocator, &g);
    defer std.testing.allocator.free(payload);
    try std.testing.expect(std.mem.find(u8, payload, "\"write\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"kind\":\"llm\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"kind\":\"final\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "run-enc") != null);
}
