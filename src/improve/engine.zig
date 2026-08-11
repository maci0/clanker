//! The self-improvement engine: clanker improving its own source code.
//!
//! Loop (per iteration, with retries):
//!   1. assemble the modifiable source tree as context for the model,
//!   2. ask the model for an exact-match patch proposal (JSON),
//!   3. validate the proposal (paths/sizes),
//!   4. apply it to a staging copy of the project,
//!   5. gate: `zig build` + `zig build tools` + `zig build test` in staging
//!      (tools first: the sandbox tests load the .wasm artifacts it builds),
//!   6. on green: snapshot the originals, promote to the live tree, log it;
//!      on failure: record and feed the error tail back for a retry.

const std = @import("std");
const config = @import("../config.zig");
const types = @import("../llm/types.zig");
const client = @import("../llm/client.zig");
const providers = @import("../llm/providers.zig");
const scorers = @import("../evals/scorers.zig");
const runner_mod = @import("../evals/runner.zig");
const builder = @import("../tools/builder.zig");
const proposal_mod = @import("proposal.zig");
const history_mod = @import("history.zig");
const patch_apply = @import("../patch/apply.zig");
const gate_checks = @import("../gate/checks.zig");
const peers = @import("../peers/notify.zig");
const log = @import("../util/log.zig");
const atomic_write = @import("../util/atomic_write.zig");

pub const Options = struct {
    instructions: []const u8,
    iters: u32 = 3,
    max_attempts_per_iter: u32 = 2,
    dry_run: bool = false,
    /// null means "size it from the model's context window". A fixed 64 KiB
    /// was the same budget for a 128k model and a 1M one.
    max_context_bytes: ?usize = null,
    max_changes: usize = 40,
    max_change_bytes: usize = 32 * 1024,
    response_tokens: u32 = 16384,
};

/// Directories/files copied into staging for the compile gate. Must be enough
/// for `zig build` + `zig build test` + `zig build tools` to succeed.
const staging_roots = [_][]const u8{ "src", "tools", "tests", "docs", "README.md", "build.zig", "build.zig.zon", "config.json" };

/// Ordered by dependency: the tools build produces the .wasm artifacts the
/// sandbox tests load, so it must run before them.
const gate_evals = [_][]const u8{ "selfhost_build", "selfhost_tools", "selfhost_tests" };

pub const Engine = struct {
    ctx: *client.Ctx,
    arena: std.mem.Allocator,
    provider: *const config.Provider,
    cfg: *const config.Config,
    hist: history_mod.History,
    instructions: []const u8,

    pub fn run(self: *Engine, opts: Options) !void {
        log.log(.info, "improve-self: {s}", .{opts.instructions});
        for (gate_evals) |g| log.log(.info, "gate: {s}", .{g});

        self.hist = history_mod.History.init(self.ctx.gpa, self.ctx.io, std.Io.Dir.cwd(), "state");
        self.instructions = opts.instructions;
        defer self.hist.deinit();
        const before = try self.gateScore();
        log.log(.info, "baseline gate: {d:.2}/{d} passing", .{ before.score, before.total });

        var promoted_any = false;
        for (0..opts.iters) |iter| {
            log.log(.info, "--- improve iteration {d}/{d} ---", .{ iter + 1, opts.iters });
            var attempted = false;
            var attempt: u32 = 0;
            while (attempt < opts.max_attempts_per_iter) : (attempt += 1) {
                const outcome = try self.improveOnce(opts, attempt + 1, if (attempt == 0) null else feedback);
                switch (outcome) {
                    .accepted => {
                        promoted_any = true;
                        attempted = true;
                        break;
                    },
                    .no_change => {
                        log.log(.info, "model reports no changes needed", .{});
                        attempted = true;
                        break;
                    },
                    .failed => {
                        // loop: next attempt gets the fresh error tail in context
                    },
                }
            }
            if (!attempted) log.log(.warn, "iteration {d}: all attempts failed", .{iter + 1});
        }

        const after = try self.gateScore();
        log.log(.info, "final gate: {d:.2}/{d} passing", .{ after.score, after.total });
        if (!promoted_any) log.log(.info, "no changes were promoted", .{});
    }

    const Outcome = enum { accepted, no_change, failed };
    var feedback: ?[]const u8 = null;

    fn improveOnce(self: *Engine, opts: Options, attempt: u32, last_error: ?[]const u8) !Outcome {
        // ---- 1. context ----
        const context = try self.collectContext(opts.max_context_bytes orelse self.contextBudget());
        const gate_tail = try self.gateErrorTail();
        // The source context is ~25k tokens and identical across the attempts
        // of a run; the instruction and the last error are a few hundred and
        // change every attempt. Caching is a prefix match, so the bulk goes in
        // the system half (cached) and only the volatile part in the user
        // message. Sent the other way round — as one user message beginning
        // with the instruction — every attempt re-billed the whole context at
        // full price, which is why this path ran at a 0% cache hit rate.
        const system_prompt = try std.fmt.allocPrint(self.arena, improve_system_fmt, .{ improve_system, context });
        const user_prompt = try std.fmt.allocPrint(self.arena, improve_user_fmt, .{
            opts.instructions,
            gate_tail,
            last_error orelse "none",
        });

        log.log(.info, "iteration attempt {d}: asking model for a proposal ({d} bytes context)", .{ attempt, context.len });

        // ---- 2. proposal from the model ----
        const messages = [_]types.Message{
            .{ .role = .system, .content = system_prompt },
            .{ .role = .user, .content = user_prompt },
        };
        var err_detail: ?[]const u8 = null;
        const resp = client.chat(self.ctx, self.arena, .{
            .provider = self.provider,
            .messages = &messages,
            .max_tokens = opts.response_tokens,
        }, &err_detail) catch |err| {
            log.log(.error_, "proposal request failed: {s} ({s})", .{ @errorName(err), err_detail orelse "" });
            return error.ProposalRequestFailed;
        };

        const content = resp.message.content orelse "";
        var json_text = stripFences(self.arena, content);
        if (json_text.len == 0) {
            // Reasoning models (DeepSeek v4) can exhaust the output budget and
            // leave content empty — the answer usually trails the reasoning.
            if (resp.reasoning) |rc| {
                log.log(.warn, "content empty; extracting proposal from reasoning ({d} chars)", .{rc.len});
                if (lastProposalJson(self.arena, rc)) |js| {
                    json_text = js;
                }
            }
        }
        if (json_text.len == 0) {
            log.log(.error_, "model returned no proposal content", .{});
            if (resp.raw) |raw| log.log(.debug, "raw response (first 1200): {s}", .{raw[0..@min(raw.len, 1200)]});
            feedback = "Your previous response had an empty content field. Output the JSON object in the content field.";
            return .failed;
        }

        const proposal = proposal_mod.parseProposal(self.arena, json_text, opts.max_changes, opts.max_change_bytes) catch |err| {
            log.log(.error_, "proposal rejected: {s}", .{@errorName(err)});
            log.log(.debug, "proposal text (first 1500): {s}", .{json_text[0..@min(json_text.len, 1500)]});
            // "SyntaxError" alone tells the model nothing it can act on. The
            // usual cause is a file whose own content is full of quotes and
            // braces (a .tool.json descriptor), escaped wrongly inside the
            // proposal, so say that and show what actually arrived.
            const head = json_text[0..@min(json_text.len, 400)];
            const tail = if (json_text.len > 400) json_text[json_text.len - @min(json_text.len - 400, 200) ..] else "";
            feedback = try std.fmt.allocPrint(
                self.arena,
                "Your previous response was not a valid patch proposal: {s}.\n" ++
                    "Respond with ONLY the JSON object described above.\n" ++
                    "Every character of a file's new content goes in the \"new\" string, so each \" inside it must be written \\\" and each newline \\n. A descriptor file (.tool.json) is mostly quotes; escape them all.\n" ++
                    "This is how your last answer started:\n{s}\n...and ended:\n{s}",
                .{ @errorName(err), head, tail },
            );
            if (err == error.NoChanges) return .no_change;
            return .failed;
        };
        log.log(.info, "proposal: {s} ({d} change(s))", .{ proposal.summary, proposal.changes.len });

        // ---- 3. dry run ----
        if (opts.dry_run) {
            log.log(.info, "DRY RUN — not applying", .{});
            for (proposal.changes) |c| {
                log.log(.info, "  would change {s} ({d} bytes)", .{ c.file, c.new.len });
            }
            return .no_change;
        }

        // ---- 4. staging ----
        const id = try self.newId();
        defer self.ctx.gpa.free(id);
        const staging = try std.fmt.allocPrint(self.ctx.gpa, "state/staging/{s}", .{id});
        defer self.ctx.gpa.free(staging);
        try self.prepareStaging(staging);

        const staged_dir = try std.Io.Dir.cwd().openDir(self.ctx.io, staging, .{});
        defer staged_dir.close(self.ctx.io);

        patch_apply.apply(staged_dir, self.ctx.io, self.ctx.gpa, proposal.changes) catch |err| {
            log.log(.error_, "applying patch failed: {s}", .{@errorName(err)});
            return .failed;
        };

        // Auto-format the staged .zig files so promoted code is always
        // zig-fmt-clean regardless of the model's output formatting.
        const fmt_files_all = try proposalChangedPaths(self.ctx.gpa, proposal);
        defer self.ctx.gpa.free(fmt_files_all);
        var fmt_auto = try gate_checks.formatFiles(self.ctx.gpa, self.ctx.io, staged_dir, fmt_files_all);
        defer fmt_auto.deinit(self.ctx.gpa);

        // ---- 5. gate ----
        log.log(.info, "gating in {s} ...", .{staging});
        var build = try gate_checks.buildGate(self.ctx.gpa, self.ctx.io, staged_dir, &.{});
        defer build.deinit(self.ctx.gpa);
        if (!build.ok) {
            const tail = errorTail(self.arena, build.detail);
            log.log(.error_, "staging build failed:", .{});
            log.log(.error_, "{s}", .{tail});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, changedPaths(self.ctx.gpa, proposal.changes), 0, 0, tail);
            // Hand the failure to the next attempt. Without this the retry is
            // blind: it re-proposed the same wrong import three times because
            // nothing ever told it what the compiler said.
            feedback = try std.fmt.allocPrint(self.arena, "Your previous patch was applied but {s}:\n{s}\nFix exactly that and re-propose.", .{ "the staged tree did not compile", tail });
            return .failed;
        }

        // Tools before tests: the sandbox tests load zig-out/tools/*.wasm from
        // the working directory, and a fresh staging dir has none until this
        // gate builds them. Running tests first failed every proposal on a
        // missing artifact rather than on its own merits.
        var tools = try gate_checks.toolsGate(self.ctx.gpa, self.ctx.io, staged_dir);
        defer tools.deinit(self.ctx.gpa);
        if (!tools.ok) {
            const tail = errorTail(self.arena, tools.detail);
            log.log(.error_, "staging tools build failed:", .{});
            log.log(.error_, "{s}", .{tail});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, changedPaths(self.ctx.gpa, proposal.changes), 0, 0, tail);
            // Hand the failure to the next attempt. Without this the retry is
            // blind: it re-proposed the same wrong import three times because
            // nothing ever told it what the compiler said.
            feedback = try std.fmt.allocPrint(self.arena, "Your previous patch was applied but {s}:\n{s}\nFix exactly that and re-propose.", .{ "the staged tools did not compile", tail });
            return .failed;
        }

        var test_gate = try gate_checks.testGate(self.ctx.gpa, self.ctx.io, staged_dir);
        defer test_gate.deinit(self.ctx.gpa);
        if (!test_gate.ok) {
            const tail = errorTail(self.arena, test_gate.detail);
            log.log(.error_, "staging tests failed:", .{});
            log.log(.error_, "{s}", .{tail});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, changedPaths(self.ctx.gpa, proposal.changes), 0, 0, tail);
            // Hand the failure to the next attempt. Without this the retry is
            // blind: it re-proposed the same wrong import three times because
            // nothing ever told it what the compiler said.
            feedback = try std.fmt.allocPrint(self.arena, "Your previous patch was applied but {s}:\n{s}\nFix exactly that and re-propose.", .{ "the staged tests failed", tail });
            return .failed;
        }

        const fmt_files = try proposalChangedPaths(self.ctx.gpa, proposal);
        defer self.ctx.gpa.free(fmt_files);
        var fmt_check = try gate_checks.fmtGate(self.ctx.gpa, self.ctx.io, staged_dir, fmt_files);
        defer fmt_check.deinit(self.ctx.gpa);
        if (!fmt_check.ok) {
            const tail = errorTail(self.arena, fmt_check.detail);
            log.log(.error_, "staging fmt check failed:", .{});
            log.log(.error_, "{s}", .{tail});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, changedPaths(self.ctx.gpa, proposal.changes), 0, 0, tail);
            // Hand the failure to the next attempt. Without this the retry is
            // blind: it re-proposed the same wrong import three times because
            // nothing ever told it what the compiler said.
            feedback = try std.fmt.allocPrint(self.arena, "Your previous patch was applied but {s}:\n{s}\nFix exactly that and re-propose.", .{ "zig fmt rejected your formatting", tail });
            return .failed;
        }

        var lint_check = try gate_checks.lintGate(self.ctx.gpa, self.ctx.io, staged_dir, fmt_files);
        defer lint_check.deinit(self.ctx.gpa);
        if (!lint_check.ok) {
            const tail = errorTail(self.arena, lint_check.detail);
            log.log(.error_, "staging lint failed: {s}", .{tail});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, changedPaths(self.ctx.gpa, proposal.changes), 0, 0, tail);
            feedback = try std.fmt.allocPrint(self.arena, "Your previous patch was applied but the lint gate rejected it:\n{s}\nFix exactly that and re-propose.", .{tail});
            return .failed;
        }

        // ---- 6. promote ----
        log.log(.info, "gates green — promoting {d} file(s)", .{proposal.changes.len});
        const files = changedPaths(self.ctx.gpa, proposal.changes);
        try self.hist.snapshot(id, files);
        for (proposal.changes) |c| {
            const src = try std.fmt.allocPrint(self.ctx.gpa, "{s}/{s}", .{ staging, c.file });
            defer self.ctx.gpa.free(src);
            const data = try std.Io.Dir.cwd().readFileAlloc(self.ctx.io, src, self.ctx.gpa, .limited(1 << 24));
            defer self.ctx.gpa.free(data);
            // Atomic: promotion writes real source files into the live
            // tree, one per proposal.changes entry; a crash or kill
            // mid-write here must never leave a half-written file that
            // can't even `zig build` (the state/history snapshot above is
            // the recovery path for a half-promoted *set* of files, but
            // each individual file write still has to be all-or-nothing).
            try atomic_write.writeFile(self.ctx.io, std.Io.Dir.cwd(), c.file, data);
        }

        // Git strategy: commit the promoted change so history, diff review and
        // bisectability work; the state/history snapshot remains the fallback.
        if (self.cfg.agent.git_commit) {
            self.gitCommit(id, proposal.summary, files);
        }
        peers.notifyAll(self.ctx.gpa, self.ctx.io, self.cfg, "improve", self.arena.dupe(u8, proposal.summary) catch "");

        // Post-promotion gate on the live tree.
        const live = try self.gateScore();
        const score_after = live.score / @as(f64, @floatFromInt(@max(live.total, 1)));
        try self.hist.append(id, .accepted, opts.instructions, proposal.summary, files, 0, score_after, "");

        log.log(.info, "✓ promoted improvement {s} (gate {d:.2}/{d})", .{ id, live.score, live.total });
        return .accepted;
    }

    fn gitCommit(self: *Engine, id: []const u8, summary: []const u8, files: [][]const u8) void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.ctx.gpa);
        argv.append(self.ctx.gpa, "git") catch return;
        argv.append(self.ctx.gpa, "add") catch return;
        argv.append(self.ctx.gpa, "--") catch return;
        for (files) |f| argv.append(self.ctx.gpa, f) catch return;
        const add = std.process.run(self.ctx.gpa, self.ctx.io, .{ .argv = argv.items }) catch {
            log.log(.warn, "git add failed (no repo?); relying on state/history snapshot", .{});
            return;
        };
        defer self.ctx.gpa.free(add.stdout);
        defer self.ctx.gpa.free(add.stderr);

        const msg = std.fmt.allocPrint(self.ctx.gpa, "clanker: {s} [{s}]", .{ summary, id }) catch return;
        defer self.ctx.gpa.free(msg);
        const commit_argv = [_][]const u8{ "git", "commit", "-m", msg };
        const commit = std.process.run(self.ctx.gpa, self.ctx.io, .{ .argv = &commit_argv }) catch return;
        defer self.ctx.gpa.free(commit.stdout);
        defer self.ctx.gpa.free(commit.stderr);
        const ok = switch (commit.term) {
            .exited => |c| c == 0,
            else => false,
        };
        if (ok) {
            log.log(.info, "committed as git change: {s}", .{msg});
        } else {
            log.log(.debug, "git commit output: {s}", .{commit.stderr});
        }
    }

    fn newId(self: *Engine) ![]const u8 {
        const ns = std.Io.Timestamp.now(self.ctx.io, .real).nanoseconds;
        return std.fmt.allocPrint(self.ctx.gpa, "imp-{d}", .{ns});
    }

    fn gateScore(self: *Engine) !struct { score: f64, total: usize } {
        var passing: usize = 0;
        for (gate_evals) |name| {
            const e = scorers.Eval{ .name = name, .kind = if (std.mem.eql(u8, name, "selfhost_build")) .selfhost_build else if (std.mem.eql(u8, name, "selfhost_tests")) .selfhost_tests else .selfhost_tools };
            const res = try self.runGateEval(&e);
            if (res.ok) passing += 1;
        }
        return .{ .score = @floatFromInt(passing), .total = gate_evals.len };
    }

    fn runGateEval(self: *Engine, e: *const scorers.Eval) !runner_mod.Result {
        const dir = std.Io.Dir.cwd();
        var g = switch (e.kind) {
            .selfhost_build => try gate_checks.buildGate(self.ctx.gpa, self.ctx.io, dir, &.{}),
            .selfhost_tests => try gate_checks.testGate(self.ctx.gpa, self.ctx.io, dir),
            .selfhost_tools => try gate_checks.toolsGate(self.ctx.gpa, self.ctx.io, dir),
            else => return error.NotAGateEval,
        };
        defer g.deinit(self.ctx.gpa);
        const detail = if (g.ok) "" else errorTail(self.arena, g.detail);
        return .{ .name = e.name, .kind = e.kind, .score = if (g.ok) 1 else 0, .ok = g.ok, .detail = detail };
    }

    fn gateErrorTail(self: *Engine) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        for (gate_evals) |name| {
            const e = scorers.Eval{ .name = name, .kind = if (std.mem.eql(u8, name, "selfhost_build")) .selfhost_build else if (std.mem.eql(u8, name, "selfhost_tests")) .selfhost_tests else .selfhost_tools };
            const res = try self.runGateEval(&e);
            if (!res.ok) {
                try buf.appendSlice(self.arena, res.detail);
                try buf.append(self.arena, '\n');
            }
        }
        if (buf.items.len == 0) return "all gates pass";
        return buf.toOwnedSlice(self.arena);
    }

    // ------------------------------------------------------------ context --

    /// How much source to send, derived from the model actually being used.
    /// Roughly 3 bytes per token over about a third of the window, which comes
    /// out at the window itself in bytes, leaving the rest for the rules, the
    /// instruction, the gate output and the answer (which carries whole
    /// rewritten files). The ceiling is a little over this project's total
    /// source size, so a 1M-window model sees all of itself and never patches
    /// a file it was not shown; the floor keeps a small model working.
    fn contextBudget(self: *const Engine) usize {
        const window: usize = self.provider.activeModel().context_window;
        return std.math.clamp(window, 64 * 1024, 1024 * 1024);
    }

    fn collectContext(self: *Engine, max_bytes: usize) ![]const u8 {
        const instructions = self.instructions;
        var keywords: std.ArrayList([]const u8) = .empty;
        var kw_it = std.mem.tokenizeAny(u8, instructions, " \n\r\t,.;:'\"()[]{}");
        while (kw_it.next()) |w| {
            if (w.len >= 5 and !isStopword(w)) try keywords.append(self.arena, w);
        }

        // Gather candidate files with a relevance score (keyword hits).
        var cands: std.ArrayList(Candidate) = .empty;
        try collectCandidates(self, "tools/zig", keywords.items, &cands);
        // Descriptors are part of the modifiable surface (validatePath allows
        // *.tool.json) but were never gathered, so any instruction about a
        // tool's name, description or schema asked for an exact-match patch
        // against a file the model had never seen.
        try collectCandidates(self, "tools/manifests", keywords.items, &cands);
        try collectCandidates(self, "src", keywords.items, &cands);
        try collectCandidates(self, "tests", keywords.items, &cands);
        for ([_][]const u8{ "build.zig", "build.zig.zon", "config.json" }) |f| {
            try collectFile(self, f, keywords.items, &cands);
        }
        // A file the instruction names by path is the one being patched, and
        // an exact-match patch against a file the model never saw cannot
        // succeed. Keyword scoring alone does not guarantee it lands in
        // context, so pin it: gather it if it was missed, then rank it first.
        try self.pinNamedFiles(instructions, keywords.items, &cands);

        // Writing a new WASM tool means reproducing an ABI that is only
        // visible in the existing guests: the entry point's exact signature
        // and how lib.zig is imported. Keyword scoring will not surface those
        // for an instruction about, say, an "lsp" tool, and the model then
        // guesses — "../lib.zig" instead of "lib.zig", three attempts running.
        if (std.mem.indexOf(u8, instructions, "tools/zig") != null or
            std.mem.indexOf(u8, instructions, "WASM tool") != null or
            std.mem.indexOf(u8, instructions, "wasm tool") != null)
        {
            try self.pinNamedFiles("tools/zig/lib.zig tools/zig/learnings.zig", keywords.items, &cands);
        }

        std.mem.sort(Candidate, cands.items, {}, struct {
            fn lt(_: void, a: Candidate, b: Candidate) bool {
                return a.score > b.score;
            }
        }.lt);

        var buf: std.ArrayList(u8) = .empty;
        var omitted: std.ArrayList([]const u8) = .empty;
        var included_any = false;
        for (cands.items) |c| {
            // Keep the context tight: only include files that matched the
            // instruction keywords (plus always build.zig / config.json), so
            // the model cannot lose track of which file has what.
            const always = std.mem.eql(u8, c.path, "build.zig") or std.mem.eql(u8, c.path, "config.json") or std.mem.eql(u8, c.path, "build.zig.zon");
            if (c.score == 0 and !always) continue;
            included_any = true;
            try self.appendWholeFile(&buf, &omitted, c, max_bytes);
        }
        if (!included_any) {
            // No keyword matches — fall back to the top candidates by score.
            for (cands.items) |c| try self.appendWholeFile(&buf, &omitted, c, max_bytes);
        }
        // A file that did not fit has to be named. Silently cutting one off
        // mid-way, or dropping it entirely, left the model writing exact-match
        // patches against text it had never seen and could not know was
        // missing.
        if (omitted.items.len > 0) {
            try buf.appendSlice(self.arena, "\n===== NOT INCLUDED (too large for this context; do not patch these blind) =====\n");
            for (omitted.items) |path| {
                try buf.appendSlice(self.arena, path);
                try buf.appendSlice(self.arena, "\n");
            }
        }
        if (buf.items.len == 0) return "(no source files found)";
        log.log(.debug, "context: {d} files, {d} bytes (budget {d}, {d} omitted)", .{ cands.items.len, buf.items.len, max_bytes, omitted.items.len });
        for (omitted.items) |o| log.log(.debug, "context: omitted {s}", .{o});
        return buf.toOwnedSlice(self.arena);
    }

    /// Appends a candidate whole or not at all. A half file is worse than an
    /// absent one: it reads as complete, and every patch against its missing
    /// tail fails the exact-match check for reasons the model cannot see.
    fn appendWholeFile(
        self: *Engine,
        buf: *std.ArrayList(u8),
        omitted: *std.ArrayList([]const u8),
        c: Candidate,
        max_bytes: usize,
    ) !void {
        const header = try std.fmt.allocPrint(self.arena, "\n===== FILE: {s} =====\n", .{c.path});
        if (buf.items.len + header.len + c.data.len > max_bytes) {
            try omitted.append(self.arena, c.path);
            return;
        }
        try buf.appendSlice(self.arena, header);
        try buf.appendSlice(self.arena, c.data);
    }

    /// Boosts (and if necessary reads) every repository path mentioned in the
    /// instruction, so "fix X in src/agent/loop.zig" always ships loop.zig.
    fn pinNamedFiles(self: *Engine, instructions: []const u8, keywords: []const []const u8, cands: *std.ArrayList(Candidate)) !void {
        const pin_score: usize = 1_000_000;
        var it = std.mem.tokenizeAny(u8, instructions, " \n\r\t,;:'\"()[]{}`*");
        while (it.next()) |tok| {
            const path = std.mem.trim(u8, tok, ".");
            if (std.mem.indexOfScalar(u8, path, '/') == null) continue;
            if (!std.mem.endsWith(u8, path, ".zig") and !std.mem.endsWith(u8, path, ".json") and
                !std.mem.endsWith(u8, path, ".md") and !std.mem.endsWith(u8, path, ".zon")) continue;
            if (!proposal_mod.validatePath(path)) continue;

            var found = false;
            for (cands.items) |*c| {
                if (std.mem.eql(u8, c.path, path)) {
                    c.score += pin_score;
                    found = true;
                    break;
                }
            }
            if (found) continue;
            const before = cands.items.len;
            try self.collectFile(path, keywords, cands);
            if (cands.items.len > before) cands.items[cands.items.len - 1].score += pin_score;
        }
    }

    /// Big enough for this project's own largest source file. At 96 KiB
    /// src/agent/loop.zig was silently unreadable, so the agent loop was the
    /// one file the agent could never see or change.
    const file_read_cap = 256 * 1024;

    fn collectFile(self: *Engine, rel: []const u8, keywords: []const []const u8, cands: *std.ArrayList(Candidate)) !void {
        const data = std.Io.Dir.cwd().readFileAlloc(self.ctx.io, rel, self.arena, .limited(file_read_cap)) catch |err| {
            log.log(.debug, "context: skipping {s}: {s}", .{ rel, @errorName(err) });
            return;
        };
        var score: usize = 0;
        for (keywords) |kw| {
            if (std.mem.indexOf(u8, data, kw) != null) score += 1;
        }
        if (std.mem.indexOf(u8, rel, "calculator") != null and std.mem.indexOf(u8, rel, "src") == null) score += 2;
        try cands.append(self.arena, .{ .path = try self.arena.dupe(u8, rel), .score = score, .data = data });
    }

    fn collectCandidates(self: *Engine, dir_rel: []const u8, keywords: []const []const u8, cands: *std.ArrayList(Candidate)) !void {
        var dir = std.Io.Dir.cwd().openDir(self.ctx.io, dir_rel, .{ .iterate = true }) catch return;
        defer dir.close(self.ctx.io);
        var it = dir.iterate();
        while (it.next(self.ctx.io) catch null) |entry| {
            switch (entry.kind) {
                .directory => {
                    const sub = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ dir_rel, entry.name });
                    try self.collectCandidates(sub, keywords, cands);
                },
                .file => {
                    if (std.mem.endsWith(u8, entry.name, ".wasm")) continue;
                    if (!std.mem.endsWith(u8, entry.name, ".zig") and !std.mem.endsWith(u8, entry.name, ".md") and !std.mem.endsWith(u8, entry.name, ".json") and !std.mem.endsWith(u8, entry.name, ".toml") and !std.mem.endsWith(u8, entry.name, ".zon")) continue;
                    const sub = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ dir_rel, entry.name });
                    try self.collectFile(sub, keywords, cands);
                },
                else => {},
            }
        }
    }

    pub const Candidate = struct { path: []const u8, score: usize, data: []const u8 };

    fn isStopword(w: []const u8) bool {
        const stopwords = [_][]const u8{
            "make",     "tool",     "accept",    "single",     "string", "input", "like",   "with",
            "addition", "existing", "fields",    "evaluating", "using",  "these", "those",  "other",
            "should",   "could",    "would",     "value",      "number", "first", "second", "change",
            "changes",  "feature",  "implement", "support",    "please", "need",  "needs",  "make",
            "also",     "into",
        };
        for (stopwords) |s| {
            if (std.mem.eql(u8, w, s)) return true;
        }
        return false;
    }

    fn prepareStaging(self: *Engine, staging: []const u8) !void {
        const dir = std.Io.Dir.cwd();
        try dir.createDirPath(self.ctx.io, staging);
        for (staging_roots) |root| {
            try copyTreeInto(self.ctx.io, self.ctx.gpa, dir, root, staging);
        }
    }
};

/// File paths from a proposal's changes (page-allocated; caller frees).
fn proposalChangedPaths(gpa: std.mem.Allocator, p: proposal_mod.Proposal) ![][]const u8 {
    return proposalChangedPathsSlice(gpa, p.changes);
}

fn proposalChangedPathsSlice(gpa: std.mem.Allocator, changes: []const proposal_mod.Change) ![][]const u8 {
    const out = try gpa.alloc([]const u8, changes.len);
    for (changes, 0..) |c, i| out[i] = c.file;
    return out;
}

fn changedPaths(gpa: std.mem.Allocator, changes: []const proposal_mod.Change) [][]const u8 {
    _ = gpa;
    const out = std.heap.page_allocator.alloc([]const u8, changes.len) catch unreachable;
    for (changes, 0..) |c, i| out[i] = c.file;
    return out;
}

fn errorTail(arena: std.mem.Allocator, s: []const u8) []const u8 {
    const max = 1500;
    if (s.len <= max) return s;
    // This excerpt is the only thing the model sees about why its patch was
    // rejected. Zig prints the diagnosis first and build-runner noise last
    // ("referenced by", "Build Summary", "failed command"), so a plain tail
    // keeps the noise and drops the cause — anchor the window on the first
    // `error:` line instead, with a few lines of lead-in for the location.
    if (std.mem.indexOf(u8, s, "error:")) |hit| {
        var start = hit;
        var back: usize = 0;
        while (start > 0 and back < 3) {
            start -= 1;
            if (s[start] == '\n') back += 1;
        }
        if (s[start] == '\n') start += 1;
        const end = @min(s.len, start + max);
        return arena.dupe(u8, s[start..end]) catch s[start..end];
    }
    return arena.dupe(u8, s[s.len - max ..]) catch s[s.len - max ..];
}

/// Finds the LAST {...} block in `text` that contains a "changes" field
/// (reasoning models often restate the final answer at the end of their
/// chain of thought).
fn lastProposalJson(arena: std.mem.Allocator, text: []const u8) ?[]const u8 {
    var depth: usize = 0;
    var start: usize = 0;
    var best_start: ?usize = null;
    var best_end: ?usize = null;
    var in_string = false;
    for (text, 0..) |ch, i| {
        if (ch == '"' and (i == 0 or text[i - 1] != '\\')) in_string = !in_string;
        if (in_string) continue;
        if (ch == '{') {
            if (depth == 0) start = i;
            depth += 1;
        } else if (ch == '}') {
            if (depth > 0) {
                depth -= 1;
                if (depth == 0) {
                    best_start = start;
                    best_end = i + 1;
                }
            }
        }
    }
    if (best_start) |bs| {
        if (best_end) |be| {
            const candidate = text[bs..be];
            if (std.mem.indexOf(u8, candidate, "changes") != null) {
                return arena.dupe(u8, candidate) catch candidate;
            }
        }
    }
    return null;
}

fn stripFences(arena: std.mem.Allocator, content: []const u8) []const u8 {
    var s = content;
    if (std.mem.startsWith(u8, s, "```")) {
        if (std.mem.indexOf(u8, s, "\n")) |nl| s = s[nl + 1 ..];
    }
    s = std.mem.trim(u8, s, " \t\r\n");
    if (std.mem.endsWith(u8, s, "```")) s = s[0 .. s.len - 3];
    s = std.mem.trim(u8, s, " \t\r\n");
    // If the model wrapped the JSON with prose, extract the first {...} block.
    if (s.len > 0 and s[0] != '{') {
        if (std.mem.indexOfScalar(u8, s, '{')) |i| {
            s = s[i..];
        }
    }
    if (std.mem.lastIndexOfScalar(u8, s, '}')) |i| {
        s = s[0 .. i + 1];
    }
    return arena.dupe(u8, s) catch s;
}

// ------------------------------------------------------------- tree utils --

fn appendFile(io: std.Io, arena: std.mem.Allocator, rel: []const u8, buf: *std.ArrayList(u8), max_bytes: usize) !void {
    if (buf.items.len >= max_bytes) return;
    const data = std.Io.Dir.cwd().readFileAlloc(io, rel, arena, .limited(1 << 20)) catch return;
    const header = try std.fmt.allocPrint(arena, "\n===== FILE: {s} =====\n", .{rel});
    const remaining = max_bytes - buf.items.len;
    const take_header = @min(header.len, remaining);
    const take_data = @min(data.len, remaining - take_header);
    try buf.appendSlice(arena, header[0..take_header]);
    try buf.appendSlice(arena, data[0..take_data]);
}

fn walkInto(io: std.Io, arena: std.mem.Allocator, rel: []const u8, buf: *std.ArrayList(u8), max_bytes: usize) !void {
    var dir = std.Io.Dir.cwd().openDir(io, rel, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (buf.items.len >= max_bytes) return;
        const sub = std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, entry.name }) catch continue;
        switch (entry.kind) {
            .directory => try walkInto(io, arena, sub, buf, max_bytes),
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig") and !std.mem.endsWith(u8, entry.name, ".md") and !std.mem.endsWith(u8, entry.name, ".json") and !std.mem.endsWith(u8, entry.name, ".toml") and !std.mem.endsWith(u8, entry.name, ".zon")) continue;
                if (std.mem.endsWith(u8, entry.name, ".wasm")) continue;
                try appendFile(io, arena, sub, buf, max_bytes);
            },
            else => {},
        }
    }
}

fn copyTreeInto(io: std.Io, gpa: std.mem.Allocator, base: std.Io.Dir, rel: []const u8, staging: []const u8) !void {
    // Handle a plain file root (e.g. build.zig, config.json) directly.
    if (!isDir(base, io, rel)) {
        const data = base.readFileAlloc(io, rel, gpa, .limited(1 << 24)) catch return;
        defer gpa.free(data);
        const dst = std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging, rel }) catch return;
        defer gpa.free(dst);
        const d = std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging, dirOf(rel) }) catch return;
        defer gpa.free(d);
        std.Io.Dir.cwd().createDirPath(io, d) catch {};
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = data }) catch return;
        return;
    }
    var dir = base.openDir(io, rel, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const sub = std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.name }) catch continue;
        defer gpa.free(sub);
        switch (entry.kind) {
            .directory => try copyTreeInto(io, gpa, base, sub, staging),
            .file => {
                const data = dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 24)) catch continue;
                defer gpa.free(data);
                const dst = std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging, sub }) catch continue;
                defer gpa.free(dst);
                const d = std.fmt.allocPrint(gpa, "{s}", .{dirOf(dst)}) catch continue;
                defer gpa.free(d);
                std.Io.Dir.cwd().createDirPath(io, d) catch {};
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = data }) catch continue;
            },
            else => {},
        }
    }
}

fn isDir(base: std.Io.Dir, io: std.Io, rel: []const u8) bool {
    var dir = base.openDir(io, rel, .{}) catch return false;
    dir.close(io);
    return true;
}

fn dirName2(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[0..i];
    return "";
}

fn dirOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[0..i];
    return "";
}

const improve_system =
    \\You are an expert Zig 0.16 engineer working on clanker, a self-improving
    \\AI agent harness (LLM client + zwasm WebAssembly tool sandbox).
    \\You will be given an improvement instruction and the current source of the
    \\modifiable files. Propose the smallest correct change that satisfies the
    \\instruction.
    \\
    \\Respond with ONLY a JSON object (no markdown, no commentary):
    \\{
    \\  "summary": "one-line description of the change",
    \\  "rationale": "why this change is correct",
    \\  "changes": [
    \\    {
    \\      "file": "relative/path/within/src",
    \\      "old": "exact text currently in the file (must match verbatim; first occurrence is replaced)",
    \\      "new": "replacement text",
    \\      "note": "when the file content is full of quotes (any .json descriptor), send old_b64 and new_b64 with the same text base64-encoded instead of old/new: nothing to escape, nothing to get wrong"
    \\    }
    \\  ]
    \\}
    \\
    \\Rules:
    \\- "old" MUST match the current file content byte-for-byte. Keep it short but
    \\  unique. An empty "old" appends "new" at the end of the file.
    \\- Only touch files shown in the context. Never change the eval machinery
    \\  (src/evals/, src/improve/, src/tools/builder.zig).
    \\- Changes must compile with Zig 0.16 std APIs. Prefer minimal diffs.
    \\- If the instruction is already satisfied by the current code, respond with
    \\  {"summary":"no changes needed","changes":[]}.
    \\
;

/// Stable half of the prompt: the rules, then the source. Identical across the
/// attempts of a run, so it is what the provider cache can actually reuse.
const improve_system_fmt =
    \\{s}
    \\
    \\# Modifiable source context
    \\{s}
    \\
;

/// Volatile half: what to do this time, and what went wrong last time.
const improve_user_fmt =
    \\# Improvement instruction
    \\{s}
    \\
    \\# Current gate status
    \\{s}
    \\
    \\# Previous attempt feedback
    \\{s}
    \\
    \\Produce the patch proposal JSON now. Your response must be ONLY the JSON
    \\object — no markdown fences, no prose.
;

test "errorTail keeps the diagnosis, not the build-runner noise" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "compiling\n");
    try buf.appendSlice(std.testing.allocator, "src/agent/loop.zig:795:39: error: cast discards const qualifier\n");
    // Zig's trailing noise is longer than the excerpt budget, so a plain tail
    // would contain none of the line above.
    for (0..200) |_| try buf.appendSlice(std.testing.allocator, "referenced by: executeCalls: src/agent/loop.zig:899:50\n");
    try buf.appendSlice(std.testing.allocator, "Build Summary: 2/4 steps succeeded\n");

    const tail = errorTail(arena, buf.items);
    try std.testing.expect(tail.len <= 1500);
    try std.testing.expect(std.mem.indexOf(u8, tail, "error: cast discards const qualifier") != null);
}

test "errorTail falls back to the end when nothing looks like an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const long = try arena.alloc(u8, 4000);
    @memset(long, 'x');
    long[3999] = 'Z';
    const tail = errorTail(arena, long);
    try std.testing.expectEqual(@as(usize, 1500), tail.len);
    try std.testing.expectEqual(@as(u8, 'Z'), tail[tail.len - 1]);
}

test "a file named in the instruction is pinned into the context" {
    // Exact-match patching cannot work against a file the model never saw, so
    // "fix X in src/agent/loop.zig" has to ship loop.zig even when keyword
    // scoring would have ranked it out.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var ctx = client.Ctx{ .io = threaded.io(), .gpa = std.testing.allocator, .environ_map = &env };
    var cfg = config.Config{};
    var provider = try config.Provider.single(arena, "p", "http://localhost", .openai_compat, "m", .{});
    var engine = Engine{ .ctx = &ctx, .arena = arena, .provider = &provider, .cfg = &cfg, .hist = undefined, .instructions = "" };

    var cands: std.ArrayList(Engine.Candidate) = .empty;
    try engine.pinNamedFiles("rename the export in tools/zig/lib.zig and update build.zig", &.{}, &cands);

    var saw_lib = false;
    for (cands.items) |c| {
        if (std.mem.eql(u8, c.path, "tools/zig/lib.zig")) {
            saw_lib = true;
            try std.testing.expect(c.score >= 1_000_000);
        }
    }
    try std.testing.expect(saw_lib);

    // A path outside the modifiable surface is not pulled in.
    try engine.pinNamedFiles("do not touch ~/.secrets/key.json or state/plugins.json", &.{}, &cands);
    for (cands.items) |c| {
        try std.testing.expect(std.mem.indexOf(u8, c.path, ".secrets") == null);
    }
}

test "the context never carries half a file, and names what it left out" {
    // A truncated file reads as a complete one. Every exact-match patch
    // against its missing tail then fails for a reason the model cannot see
    // from its own context, which is how an improve run burns its attempts.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var engine = Engine{
        .ctx = undefined,
        .arena = arena,
        .provider = undefined,
        .cfg = undefined,
        .hist = undefined,
        .instructions = "",
    };

    var buf: std.ArrayList(u8) = .empty;
    var omitted: std.ArrayList([]const u8) = .empty;

    const small = Engine.Candidate{ .path = "a.zig", .score = 1, .data = "const a = 1;\n" };
    const big = Engine.Candidate{ .path = "big.zig", .score = 1, .data = "x" ** 4096 };

    try engine.appendWholeFile(&buf, &omitted, small, 1024);
    try std.testing.expect(std.mem.endsWith(u8, buf.items, small.data));
    try std.testing.expectEqual(@as(usize, 0), omitted.items.len);

    // Over budget: nothing of it is written, and it is reported by name.
    const before = buf.items.len;
    try engine.appendWholeFile(&buf, &omitted, big, 1024);
    try std.testing.expectEqual(before, buf.items.len);
    try std.testing.expectEqual(@as(usize, 1), omitted.items.len);
    try std.testing.expectEqualStrings("big.zig", omitted.items[0]);
}

test "the context budget follows the model's own window" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cfg = config.Config{};

    // A small window keeps the floor; a large one is capped rather than
    // billing the whole repository on every attempt.
    var small = try config.Provider.single(arena, "s", "http://x", .openai_compat, "m", .{ .context_window = 8192 });
    var engine = Engine{ .ctx = undefined, .arena = arena, .provider = &small, .cfg = &cfg, .hist = undefined, .instructions = "" };
    try std.testing.expectEqual(@as(usize, 64 * 1024), engine.contextBudget());

    var mid = try config.Provider.single(arena, "m", "http://x", .openai_compat, "m", .{ .context_window = 131072 });
    engine.provider = &mid;
    try std.testing.expectEqual(@as(usize, 131072), engine.contextBudget());

    var huge = try config.Provider.single(arena, "h", "http://x", .openai_compat, "m", .{ .context_window = 1_048_576 });
    engine.provider = &huge;
    try std.testing.expectEqual(@as(usize, 1024 * 1024), engine.contextBudget());
}
