//! Runs iterative, metric-driven source experiments in isolated staging trees.

const std = @import("std");
const config = @import("../config.zig");
const types = @import("../llm/types.zig");
const client = @import("../llm/client.zig");
const proposal_mod = @import("../improve/proposal.zig");
const ledger = @import("autoresearch_logic");
const harness_mod = @import("harness.zig");
const registry = @import("../toolhost/registry.zig");
const runtime = @import("../sandbox/runtime.zig");
const log = @import("../util/log.zig");
const redact = @import("../util/redact.zig");
const atomic_write = @import("../util/atomic_write.zig");
const file_lock = @import("../util/file_lock.zig");
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
        std.Io.Dir.cwd().createDirPath(io, opts.research_dir) catch {};
        const lock_path = try std.fmt.allocPrint(gpa, "{s}/run.lock", .{opts.research_dir});
        defer gpa.free(lock_path);
        const run_lock = file_lock.createFileRetry(io, std.Io.Dir.cwd(), lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.WouldBlock => {
                log.log(.error_, "autoresearch: another run is already in progress", .{});
                return error.Busy;
            },
            else => return err,
        };
        defer run_lock.close(io);
        var id_buf: [64]u8 = undefined;
        // Seed the run-id RNG from the Io seam (io.random) rather than the
        // wall clock, so a simulated Io yields a reproducible run id.
        var seed: [8]u8 = undefined;
        std.Io.random(io, &seed);
        var prng = std.Random.DefaultPrng.init(std.mem.bytesToValue(u64, &seed));
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
            const ok = try self.iterOnce(opts, @intCast(iter), owned_id, base, &best);
            if (!ok) log.log(.warn, "iter {d}: no improvement", .{iter + 1});
        }
        if (best) |b| log.log(.info, "autoresearch {s} done: best {s} = {d}", .{ owned_id, opts.metric_name, b }) else log.log(.info, "autoresearch {s} done: no metric recorded", .{owned_id});
    }
    /// The same staging-tree patch application the improve engine performs,
    /// through the same sandboxed `patch_apply` tool.
    fn applyPatch(self: *Loop, staging: []const u8, changes: []const proposal_mod.Change) !void {
        return proposal_mod.applyPatchViaTool(self.ctx.gpa, self.ctx.io, self.arena, self.ctx.environ_map, self.cfg, staging, changes);
    }
    /// Writes one iteration result into the run's ledger through the
    /// sandboxed `autoresearch` WASM tool (`op: "append"`, fs-scoped to
    /// state/autoresearch/) instead of a native read-modify-write: the ledger
    /// is a bounded, per-run fs append, the same shape that already moved out
    /// of the engine into the tool. The entry format and the stdout/stderr
    /// tail live in `autoresearch_logic.zig`, shared with the guest.
    fn appendLedgerEntry(self: *Loop, run_id: []const u8, entry: ledger.Entry) !void {
        const gpa = self.ctx.gpa;
        const io = self.ctx.io;
        var reg = try registry.Registry.load(io, self.arena, std.Io.Dir.cwd(), self.cfg.agent.tools_dir);
        const mod = try runtime.loadNamedTool(gpa, io, self.arena, self.ctx.environ_map, self.cfg, &reg, "autoresearch", null);
        defer mod.deinit();

        var enc: std.Io.Writer.Allocating = .init(self.arena);
        var s = std.json.Stringify{ .writer = &enc.writer, .options = .{} };
        try s.beginObject();
        try s.objectField("op");
        try s.write("append");
        try s.objectField("run");
        try s.write(run_id);
        try s.objectField("iter");
        try s.print("{d}", .{entry.iter});
        try s.objectField("ts");
        try s.print("{d}", .{entry.ts});
        try s.objectField("summary");
        try s.write(entry.summary);
        try s.objectField("ok");
        try s.write(entry.ok);
        if (entry.metric) |m| {
            try s.objectField("metric");
            try s.print("{d}", .{m});
            try s.objectField("metric_name");
            try s.write(entry.metric_name);
        }
        try s.objectField("duration_ms");
        try s.print("{d}", .{entry.duration_ms});
        try s.objectField("detail");
        try s.write(entry.detail);
        try s.objectField("stdout");
        try s.write(entry.stdout_tail);
        try s.objectField("stderr");
        try s.write(entry.stderr_tail);
        try s.endObject();

        const raw = try mod.executeTool(enc.written());
        defer gpa.free(raw);
        const resp = std.json.parseFromSliceLeaky(struct { ok: bool = false, @"error": []const u8 = "" }, self.arena, raw, .{ .ignore_unknown_fields = true }) catch
            return error.LedgerAppendFailed;
        if (!resp.ok) return error.LedgerAppendFailed;
    }
    fn iterOnce(self: *Loop, opts: Options, iter: u32, run_id: []const u8, run_dir_path: []const u8, best: *?f64) !bool {
        const gpa = self.ctx.gpa;
        const io = self.ctx.io;
        var ctx_buf: std.ArrayList(u8) = .empty;
        defer ctx_buf.deinit(gpa);
        for (opts.targets) |targ| {
            if (std.mem.findScalar(u8, targ, '*') != null) continue;
            const maybe_content = std.Io.Dir.cwd().readFileAlloc(io, targ, gpa, .limited(64 * 1024)) catch |err| blk: {
                // A file the patch is expected to create has nothing to show
                // the model; that is not an error. Any other failure would
                // otherwise vanish from the model context without a trace,
                // and a run whose targets all fail this way would propose
                // against nothing and end with "no metric recorded" and no
                // hint why.
                if (err != error.FileNotFound)
                    log.log(.warn, "autoresearch: target {s} could not be read ({s}); leaving it out of the model context", .{ targ, @errorName(err) });
                break :blk null;
            };
            const content = maybe_content orelse continue;
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
            var log_detail_buf: [redact.max_log_detail_len]u8 = undefined;
            log.log(.warn, "autoresearch chat failed: {s} {s}", .{ @errorName(err), redact.forLog(&log_detail_buf, err_detail orelse "") });
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
            // Only a genuinely absent file may go unseeded. Any other read
            // failure (past the cap, permissions, I/O) must not read as
            // "does not exist yet": patch_apply would then build the file
            // from the fragment alone, and a run that improved the metric
            // writes that fragment back over the real one.
            const orig = std.Io.Dir.cwd().readFileAlloc(io, ch.file, gpa, .limited(1 << 20)) catch |err| switch (err) {
                error.FileNotFound => null,
                else => {
                    log.log(.warn, "autoresearch: {s} could not be read ({s}); refusing the proposal rather than staging it empty", .{ ch.file, @errorName(err) });
                    return false;
                },
            };
            defer if (orig) |o| gpa.free(o);
            if (orig == null and ch.old.len > 0) {
                log.log(.warn, "patch old not found in {s}", .{ch.file});
                return false;
            }
            if (orig) |o| {
                const staged_file = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging_path, ch.file });
                defer gpa.free(staged_file);
                if (std.mem.findScalarLast(u8, staged_file, '/')) |slash| std.Io.Dir.cwd().createDirPath(io, staged_file[0..slash]) catch {};
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
        const improved = if (harness_res.metric) |m| ledger.isBetter(m, best.*, opts.direction) else false;
        try self.appendLedgerEntry(run_id, .{
            .iter = iter,
            .ts = @as(i64, @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000))),
            .summary = proposal.summary,
            .ok = harness_res.ok and harness_res.metric != null,
            .metric = harness_res.metric,
            .metric_name = opts.metric_name,
            .duration_ms = harness_res.duration_ms,
            .detail = harness_res.detail,
            .stdout_tail = ledger.tail(harness_res.stdout, ledger.output_tail_bytes),
            .stderr_tail = ledger.tail(harness_res.stderr, ledger.output_tail_bytes),
        });
        if (improved) {
            // `best` must not advance until every target's staged content is
            // back in the tree. Promoting it first made a failed write-back
            // claim a gain the working tree never received: the next
            // iteration compared against a phantom value and the final report
            // reported a "best" that was never applied.
            var all_applied = true;
            for (proposal.changes) |ch| {
                const staged = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging_path, ch.file });
                defer gpa.free(staged);
                const content = std.Io.Dir.cwd().readFileAlloc(io, staged, gpa, .limited(1 << 20)) catch |err| {
                    log.log(.error_, "autoresearch: new best for {s} not applied, staged copy unreadable: {s}", .{ ch.file, @errorName(err) });
                    all_applied = false;
                    continue;
                };
                defer gpa.free(content);
                atomic_write.writeFile(io, std.Io.Dir.cwd(), ch.file, content) catch |err| {
                    log.log(.error_, "autoresearch: new best for {s} not written back: {s}", .{ ch.file, @errorName(err) });
                    all_applied = false;
                };
            }
            if (!all_applied) {
                log.log(.error_, "autoresearch: best {s} = {d} not promoted to the tree; keeping previous best", .{ opts.metric_name, harness_res.metric.? });
                return false;
            }
            best.* = harness_res.metric;
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
    try std.testing.expect(!isTarget("other/b.zig", &.{"src/*"}));
}
