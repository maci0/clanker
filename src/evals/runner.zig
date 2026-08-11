//! Eval runner: executes eval tasks (agent-based or selfhost build/test
//! gates) and reports scores. Used by `clanker eval` and by the
//! self-improvement engine as the promotion gate.

const std = @import("std");
const config = @import("../config.zig");
const types = @import("../llm/types.zig");
const client = @import("../llm/client.zig");
const agent = @import("../agent/loop.zig");
const registry = @import("../tools/registry.zig");
const builder = @import("../tools/builder.zig");
const scorers = @import("scorers.zig");
const log = @import("../util/log.zig");

pub const Result = struct {
    name: []const u8,
    kind: scorers.Kind,
    score: f64,
    ok: bool,
    detail: []const u8 = "",
};

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
        var a = try agent.Agent.init(self.ctx, self.arena, self.provider, self.cfg, self.reg, tool_defs);
        defer a.deinit();
        var messages: std.ArrayList(types.Message) = .empty;
        var err_detail: ?[]const u8 = null;

        const resp = a.run(&messages, e.prompt, &err_detail) catch |err| {
            log.log(.error_, "eval '{s}' agent run failed: {s}", .{ e.name, @errorName(err) });
            return .{ .name = e.name, .kind = e.kind, .score = 0, .ok = false, .detail = @errorName(err) };
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
            .detail = if (answer.len > 200) answer[0..200] else answer,
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
    return arena.dupe(u8, s[s.len - 600 ..]) catch s;
}
