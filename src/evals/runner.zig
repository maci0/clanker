//! Eval runner: executes eval tasks (agent-based or selfhost build/test
//! gates) and reports scores. Used by `clanker eval` and by the
//! self-improvement engine as the promotion gate.

const std = @import("std");
const config = @import("../config.zig");
const types = @import("../llm/types.zig");
const client = @import("../llm/client.zig");
const agent = @import("../agent/loop.zig");
const registry = @import("../toolhost/registry.zig");
const builder = @import("../toolhost/builder.zig");
const scorers = @import("scorers.zig");
const log = @import("../util/log.zig");
const utf8 = @import("../util/utf8.zig");

pub const Result = struct {
    name: []const u8,
    kind: scorers.Kind,
    score: f64,
    ok: bool,
    detail: []const u8 = "",
    /// The `agent.seed` this result was produced under, for the task evals
    /// that draw from the seeded tool RNG. `0` means time-seeded, which is
    /// the answer a failing run has to print: there is no seed to re-run
    /// with. Null is a gate eval (build, tests, tools), which never draws.
    seed: ?u64 = null,
};

/// The line a failed task eval needs to be replayed from, or `""` for
/// anything that draws no randomness. Printed after the verdict rather than
/// folded into it, so the score and PASS/FAIL stay the one thing every
/// result line says the same way.
pub fn replayHint(arena: std.mem.Allocator, res: Result) ![]const u8 {
    const seed = res.seed orelse return "";
    if (seed == 0) {
        return "  agent.seed=0: the tool RNG was time-seeded, so this run is not replayable; re-run with --seed <n>\n";
    }
    return std.fmt.allocPrint(arena, "  replay: clanker eval {s} --seed {d} (agent.seed)\n", .{ res.name, seed });
}

pub const Runner = struct {
    ctx: *client.Ctx,
    arena: std.mem.Allocator,
    provider: *const config.Provider,
    cfg: *const config.Config,
    reg: *const registry.Registry,

    pub fn runAll(self: *Runner, evals: []const scorers.Eval) ![]Result {
        var out: std.ArrayList(Result) = .empty;
        for (evals) |e| {
            const r = try self.runOne(&e);
            try out.append(self.arena, r);
            log.log(.info, "eval '{s}' ({s}): score {d:.2} {s}", .{ e.name, @tagName(e.kind), r.score, if (r.ok) "PASS" else "FAIL" });
        }
        return out.toOwnedSlice(self.arena);
    }

    pub fn runOne(self: *Runner, e: *const scorers.Eval) !Result {
        return switch (e.kind) {
            .task => self.runTask(e),
            .selfhost_build => self.selfhostGate(e, false),
            .selfhost_tests => self.selfhostGate(e, true),
            .selfhost_tools => self.selfhostTools(e),
        };
    }

    fn runTask(self: *Runner, e: *const scorers.Eval) !Result {
        const tool_defs = try self.reg.toToolDefs(self.arena);
        var a = try agent.Agent.init(self.ctx, self.arena, self.provider, self.cfg, self.reg, tool_defs, null);
        defer a.deinit();
        // Criteria assert on a bare value ("391", "clanker online"), so this is
        // the one caller that wants the lossy answer cleanup. Every other
        // surface shows the answer the model actually wrote.
        a.exact_answer = true;
        var messages: std.ArrayList(types.Message) = .empty;
        var err_detail: ?[]const u8 = null;

        const resp = a.run(&messages, e.prompt, &err_detail) catch |err| {
            log.log(.error_, "eval '{s}' agent run failed: {s}", .{ e.name, @errorName(err) });
            return .{ .name = e.name, .kind = e.kind, .score = 0, .ok = false, .detail = @errorName(err), .seed = self.cfg.agent.seed };
        };

        const answer = resp.message.content orelse "";
        var score = scorers.scoreAnswer(answer, e.criteria);

        // Tool-use requirement: did the transcript invoke the expected tool?
        if (e.requires_tool) |want| {
            var used = false;
            for (messages.items) |m| {
                if (m.tool_calls) |calls| {
                    for (calls) |tc| {
                        if (std.mem.eql(u8, tc.name, want)) used = true;
                    }
                }
            }
            if (!used) score = 0;
        }

        return .{
            .name = e.name,
            .kind = e.kind,
            .score = score,
            .ok = score >= 1.0,
            .detail = utf8.cap(answer, 200),
            .seed = self.cfg.agent.seed,
        };
    }

    fn selfhostGate(self: *Runner, e: *const scorers.Eval, run_tests: bool) !Result {
        const dir = std.Io.Dir.cwd();
        var g = if (run_tests)
            try builder.testGate(self.ctx.gpa, self.ctx.io, dir)
        else
            try builder.buildGate(self.ctx.gpa, self.ctx.io, dir, &.{});
        defer g.deinit(self.ctx.gpa);
        const detail = if (g.stderr.len > 0) g.stderr else g.stdout;
        return .{
            .name = e.name,
            .kind = e.kind,
            .score = if (g.ok) 1.0 else 0.0,
            .ok = g.ok,
            .detail = if (g.ok) "" else trimDetail(self.arena, detail),
        };
    }

    fn selfhostTools(self: *Runner, e: *const scorers.Eval) !Result {
        const dir = std.Io.Dir.cwd();
        var g = try builder.buildGate(self.ctx.gpa, self.ctx.io, dir, &.{"tools"});
        defer g.deinit(self.ctx.gpa);
        return .{
            .name = e.name,
            .kind = e.kind,
            .score = if (g.ok) 1.0 else 0.0,
            .ok = g.ok,
            .detail = if (g.ok) "" else trimDetail(self.arena, g.stderr),
        };
    }
};

fn trimDetail(arena: std.mem.Allocator, s: []const u8) []const u8 {
    if (s.len <= 600) return s;
    return arena.dupe(u8, utf8.tail(s, 600)) catch s;
}

test "a failed eval with a pinned seed names the command that re-runs it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const hint = try replayHint(arena_state.allocator(), .{
        .name = "calculator",
        .kind = .task,
        .score = 0,
        .ok = false,
        .seed = 42,
    });
    try std.testing.expectEqualStrings("  replay: clanker eval calculator --seed 42 (agent.seed)\n", hint);
}

test "a time-seeded failure says it cannot be replayed instead of printing a seed of 0" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const hint = try replayHint(arena_state.allocator(), .{
        .name = "calculator",
        .kind = .task,
        .score = 0,
        .ok = false,
        .seed = 0,
    });
    try std.testing.expect(std.mem.indexOf(u8, hint, "not replayable") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "--seed 0") == null);
}

test "a gate eval draws no randomness and so carries no hint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const hint = try replayHint(arena_state.allocator(), .{
        .name = "selfhost build",
        .kind = .selfhost_build,
        .score = 0,
        .ok = false,
    });
    try std.testing.expectEqualStrings("", hint);
}
