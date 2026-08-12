const std = @import("std");
const config = @import("../config.zig");
const types = @import("../llm/types.zig");
const client = @import("../llm/client.zig");
const proposal_mod = @import("../improve/proposal.zig");
const ledger_mod = @import("ledger.zig");
const harness_mod = @import("harness.zig");
const registry = @import("../tools/registry.zig");
const runtime = @import("../sandbox/runtime.zig");
const log = @import("../util/log.zig");
pub const Options = struct { targets: []const []const u8 = &.{}, harness_argv: []const []const u8 = &.{}, metric_name: []const u8 = "score", metric_pattern: []const u8 = "", direction: []const u8 = "min", iters: u32 = 3, dry_run: bool = false, research_dir: []const u8 = "state/autoresearch", budget_seconds: u32 = 300 };
fn isTarget(path: []const u8, targets: []const []const u8) bool {
    for (targets) |targ| {
        if (std.mem.eql(u8, path, targ)) return true;
        if (targ.len > 2 and std.mem.endsWith(u8, targ, "/*")) {
            const prefix = targ[0 .. targ.len - 1];
            if (std.mem.startsWith(u8, path, prefix)) return true;
        }
    }
    return false;
}
pub const Loop = struct {
    ctx: *client.Ctx,
    arena: std.mem.Allocator,
    provider: *const config.Provider,
    cfg: *const config.Config,
    pub fn run(self: *Loop, opts: Options) !void {
        if (opts.targets.len == 0) {
            log.log(.error_, "autoresearch: no --target given", .{});
            return error.MissingTarget;
        }
        if (opts.harness_argv.len == 0) {
            log.log(.error_, "autoresearch: no --harness given", .{});
            return error.MissingHarness;
        }
        if (opts.dry_run) {
            log.log(.info, "autoresearch dry-run: targets={d} harness={s} metric={s} ({s}) iters={d}", .{ opts.targets.len, opts.harness_argv[0], opts.metric_name, opts.direction, opts.iters });
            return;
        }
        const gpa = self.ctx.gpa;
        const io = self.ctx.io;
        var id_buf: [64]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1))));
        const id = std.fmt.bufPrint(&id_buf, "ar-{d}-{x}", .{ @as(i64, @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000))), prng.random().int(u64) & 0xffff }) catch "ar-fallback";
        const owned_id = try gpa.dupe(u8, id);
        defer gpa.free(owned_id);
        const base = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ opts.research_dir, owned_id });
        defer gpa.free(base);
        try std.Io.Dir.cwd().createDirPath(io, base);
        var run_dir = try std.Io.Dir.cwd().openDir(io, base, .{});
        defer run_dir.close(io);
        {
            var buf: [4096]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            var s = std.json.Stringify{ .writer = &w, .options = .{} };
            try s.beginObject();
            try s.objectField("metric_name");
            try s.write(opts.metric_name);
            try s.objectField("direction");
            try s.write(opts.direction);
            try s.objectField("iters");
            try s.print("{d}", .{opts.iters});
            try s.endObject();
            try run_dir.writeFile(io, .{ .sub_path = "config.json", .data = buf[0..w.end] });
        }
        log.log(.info, "autoresearch {s}: {d} iters, metric {s} ({s})", .{ owned_id, opts.iters, opts.metric_name, opts.direction });
        var best: ?f64 = null;
        for (0..opts.iters) |iter| {
            log.log(.info, "--- autoresearch iter {d}/{d} ---", .{ iter + 1, opts.iters });
            const ok = try self.iterOnce(opts, @intCast(iter), base, &best);
            if (!ok) log.log(.warn, "iter {d}: no improvement", .{iter + 1});
        }
        if (best) |b| log.log(.info, "autoresearch {s} done: best {s} = {d}", .{ owned_id, opts.metric_name, b }) else log.log(.info, "autoresearch {s} done: no metric recorded", .{owned_id});
    }
    /// Applies `changes` under `staging` through the sandboxed `patch_apply`
    /// WASM tool instead of hand-rolled exact-match string replacement, the
    /// same tool the self-improve engine uses for its own staging tree.
    fn applyPatch(self: *Loop, staging: []const u8, changes: []const proposal_mod.Change) !void {
        const gpa = self.ctx.gpa;
        const io = self.ctx.io;
        var reg = try registry.Registry.load(io, self.arena, std.Io.Dir.cwd(), self.cfg.agent.tools_dir);
        const mod = try runtime.loadNamedTool(gpa, io, self.arena, self.ctx.environ_map, self.cfg, &reg, "patch_apply", null);
        defer mod.deinit();

        var enc: std.Io.Writer.Allocating = .init(self.arena);
        var s = std.json.Stringify{ .writer = &enc.writer, .options = .{} };
        try s.beginObject();
        try s.objectField("changes");
        try s.beginArray();
        for (changes) |c| {
            const rel = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ staging, c.file });
            try s.beginObject();
            try s.objectField("file");
            try s.write(rel);
            try s.objectField("old");
            try s.write(c.old);
            try s.objectField("new");
            try s.write(c.new);
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();

        const raw = try mod.executeTool(enc.written());
        defer gpa.free(raw);
        const resp = std.json.parseFromSliceLeaky(struct { ok: bool = false, @"error": []const u8 = "" }, self.arena, raw, .{ .ignore_unknown_fields = true }) catch
            return error.PatchApplyFailed;
        if (!resp.ok) return error.PatchApplyFailed;
    }
    fn iterOnce(self: *Loop, opts: Options, iter: u32, run_dir_path: []const u8, best: *?f64) !bool {
        const gpa = self.ctx.gpa;
        const io = self.ctx.io;
        var ctx_buf: std.ArrayList(u8) = .empty;
        defer ctx_buf.deinit(gpa);
        for (opts.targets) |targ| {
            if (std.mem.findScalar(u8, targ, '*') != null) continue;
            const content = std.Io.Dir.cwd().readFileAlloc(io, targ, gpa, .limited(64 * 1024)) catch continue;
            defer gpa.free(content);
            try ctx_buf.appendSlice(gpa, "\n--- ");
            try ctx_buf.appendSlice(gpa, targ);
            try ctx_buf.appendSlice(gpa, " ---\n");
            try ctx_buf.appendSlice(gpa, content);
        }
        const best_str = if (best.*) |b| try std.fmt.allocPrint(gpa, "{d}", .{b}) else try gpa.dupe(u8, "none");
        defer gpa.free(best_str);
        const system_prompt = "You are an autoresearch agent. Propose an exact-match patch to improve the target files for the given metric. Respond with JSON: {\"summary\":\"...\",\"rationale\":\"...\",\"changes\":[{\"file\":\"...\",\"old\":\"...\",\"new\":\"...\"}]} Only touch files listed as targets. Keep changes minimal.";
        const user_prompt = try std.fmt.allocPrint(gpa, "Metric: {s} ({s}), best so far: {s}\nHarness: {s}\nTargets:\n{s}\n\nPropose one improvement.", .{ opts.metric_name, opts.direction, best_str, opts.harness_argv[0], ctx_buf.items });
        defer gpa.free(user_prompt);
        const messages = [_]types.Message{ .{ .role = .system, .content = system_prompt }, .{ .role = .user, .content = user_prompt } };
        var err_detail: ?[]const u8 = null;
        const resp = client.chat(self.ctx, self.arena, .{ .provider = self.provider, .messages = &messages, .max_tokens = 4096 }, &err_detail) catch |err| {
            log.log(.warn, "autoresearch chat failed: {s} {s}", .{ @errorName(err), err_detail orelse "" });
            return false;
        };
        const raw = resp.message.content orelse return false;
        var rejected: ?[]const u8 = null;
        const proposal = proposal_mod.parseProposal(gpa, raw, 10, 32 * 1024, &rejected) catch |err| {
            log.log(.warn, "proposal parse failed: {s} rejected={s}", .{ @errorName(err), rejected orelse "" });
            return false;
        };
        for (proposal.changes) |ch| {
            if (!isTarget(ch.file, opts.targets)) {
                log.log(.warn, "change outside targets: {s}", .{ch.file});
                return false;
            }
            if (!proposal_mod.validatePath(ch.file)) {
                log.log(.warn, "path not allowed: {s}", .{ch.file});
                return false;
            }
        }
        const staging_path = try std.fmt.allocPrint(gpa, "{s}/staging", .{run_dir_path});
        defer gpa.free(staging_path);
        try std.Io.Dir.cwd().createDirPath(io, staging_path);
        // Seed staging with the pristine copy of every target so the
        // patch_apply tool (sandboxed to state/) has something to match
        // "old" against; a target that does not exist yet is left unseeded,
        // which is only valid for an append (old == "").
        for (proposal.changes) |ch| {
            const orig = std.Io.Dir.cwd().readFileAlloc(io, ch.file, gpa, .limited(1 << 20)) catch null;
            defer if (orig) |o| gpa.free(o);
            if (orig == null and ch.old.len > 0) {
                log.log(.warn, "patch old not found in {s}", .{ch.file});
                return false;
            }
            if (orig) |o| {
                const staged_file = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging_path, ch.file });
                defer gpa.free(staged_file);
                if (std.mem.lastIndexOfScalar(u8, staged_file, '/')) |slash| std.Io.Dir.cwd().createDirPath(io, staged_file[0..slash]) catch {};
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = staged_file, .data = o });
            }
        }
        self.applyPatch(staging_path, proposal.changes) catch |err| {
            log.log(.warn, "autoresearch patch_apply failed: {s}", .{@errorName(err)});
            return false;
        };
        const stage_dir_opt: ?std.Io.Dir = std.Io.Dir.cwd().openDir(io, staging_path, .{}) catch null;
        const stage_dir = stage_dir_opt orelse std.Io.Dir.cwd();
        defer if (stage_dir_opt != null) stage_dir.close(io);
        var harness_res = try harness_mod.runHarness(gpa, io, stage_dir, opts.harness_argv, opts.metric_name, opts.metric_pattern);
        defer harness_res.deinit(gpa);
        const improved = if (harness_res.metric) |m| ledger_mod.isBetter(m, best.*, opts.direction) else false;
        var run_dir = std.Io.Dir.cwd().openDir(io, run_dir_path, .{}) catch return false;
        defer run_dir.close(io);
        try ledger_mod.appendEntry(gpa, io, run_dir, .{ .iter = iter, .ts = @as(i64, @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000))), .summary = proposal.summary, .ok = harness_res.ok and harness_res.metric != null, .metric = harness_res.metric, .metric_name = opts.metric_name, .duration_ms = harness_res.duration_ms, .detail = harness_res.detail, .stdout_tail = harness_res.stdout, .stderr_tail = harness_res.stderr });
        if (improved) {
            best.* = harness_res.metric;
            for (proposal.changes) |ch| {
                const staged = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging_path, ch.file });
                defer gpa.free(staged);
                const content = std.Io.Dir.cwd().readFileAlloc(io, staged, gpa, .limited(1 << 20)) catch |err| {
                    log.log(.error_, "autoresearch: new best for {s} not applied, staged copy unreadable: {s}", .{ ch.file, @errorName(err) });
                    continue;
                };
                defer gpa.free(content);
                if (std.mem.lastIndexOfScalar(u8, ch.file, '/')) |slash| std.Io.Dir.cwd().createDirPath(io, ch.file[0..slash]) catch {};
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ch.file, .data = content }) catch |err| {
                    log.log(.error_, "autoresearch: new best for {s} not written back: {s}", .{ ch.file, @errorName(err) });
                };
            }
            const best_path = try std.fmt.allocPrint(gpa, "{s}/best", .{run_dir_path});
            defer gpa.free(best_path);
            try std.Io.Dir.cwd().createDirPath(io, best_path);
            log.log(.info, "new best {s} = {d} at iter {d}: {s}", .{ opts.metric_name, harness_res.metric.?, iter, proposal.summary });
            return true;
        }
        return false;
    }
};
test "isTarget exact and glob" {
    try std.testing.expect(isTarget("src/foo.zig", &.{ "src/foo.zig", "other" }));
    try std.testing.expect(!isTarget("src/bar.zig", &.{"src/foo.zig"}));
    try std.testing.expect(isTarget("src/a/b.zig", &.{"src/*"}));
}
