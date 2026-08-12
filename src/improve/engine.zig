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
const gate_checks = @import("../gate/checks.zig");
const sandbox_host = @import("../sandbox/host.zig");
const runtime = @import("../sandbox/runtime.zig");
const registry = @import("../tools/registry.zig");
const log = @import("../util/log.zig");
const atomic_write = @import("../util/atomic_write.zig");
const diskcap = @import("../util/diskcap.zig");
const worktree_mod = @import("worktree.zig");

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
    /// How many times in a run the model may answer with a file request
    /// instead of a patch. Each one costs a call that produces no patch, so
    /// the budget is small; it is also the only way this loop can look
    /// anything up. 0 disables the mechanism.
    max_context_requests: u32 = 3,
    /// Paths honoured per request. The whole file is read, and every granted
    /// file is billed again on every later call of the run.
    max_request_files: usize = 6,
};

/// Directories/files copied into staging for the compile gate. Must be enough
/// for `zig build` + `zig build test` + `zig build tools` to succeed. `vendor`
/// is required because `build.zig` imports vendor/toml/src/root.zig as a
/// local path module; without it the staged build can't find that module.
const staging_roots = [_][]const u8{ "src", "tools", "tests", "docs", "evals", "vendor", "README.md", "build.zig", "build.zig.zon", "config.toml" };

/// Text that has to survive in a staged file for the patch to be considered.
///
/// The improvement machinery is part of the modifiable surface, which is what
/// lets clanker improve how it improves itself. The risk that opens is a patch
/// that quietly removes a gate: it would pass every check today, because the
/// checks are run by the binary already on disk, and skip them forever after.
/// These are the load-bearing call sites, asserted against the staged text.
const gate_invariants = [_]struct { file: []const u8, needle: []const u8 }{
    .{ .file = "src/improve/engine.zig", .needle = "gate_checks.buildGate(" },
    .{ .file = "src/improve/engine.zig", .needle = "gate_checks.toolsGate(" },
    .{ .file = "src/improve/engine.zig", .needle = "gate_checks.testGate(" },
    .{ .file = "src/improve/engine.zig", .needle = "gate_checks.fmtGate(" },
    .{ .file = "src/improve/engine.zig", .needle = "gate_checks.lintGate(" },
    .{ .file = "src/improve/engine.zig", .needle = "self.capabilityGate(" },
    .{ .file = "src/improve/engine.zig", .needle = "proposal_mod.isAppendOnly(" },
    .{ .file = "src/improve/engine.zig", .needle = "gate_invariants" },
    // src/gate/checks.zig is deliberately outside the protected surface (so
    // clanker can keep strengthening the gates), which means a patch could
    // also gut buildGate/testGate/toolsGate's actual implementation there
    // and pass every check today by construction. These needles catch that:
    // the delegation call sites and the one exit-code check every gate
    // ultimately shares.
    .{ .file = "src/gate/checks.zig", .needle = ".exited => |c| c == 0," },
    .{ .file = "src/gate/checks.zig", .needle = "return runZigArgs(gpa, io, dir, argv.items, \"zig build\")" },
    .{ .file = "src/gate/checks.zig", .needle = "return runZig(gpa, io, dir, &.{ \"build\", \"test\", \"--summary\", \"all\" }, \"zig build test\")" },
    .{ .file = "src/gate/checks.zig", .needle = "return runZig(gpa, io, dir, &.{ \"build\", \"tools\", \"--summary\", \"all\" }, \"zig build tools\")" },
};

/// The next symbol worth looking up in `text`, reduced to its most specific
/// component: `std.posix.SEEK.SET` identifies itself as `SET`, which is what a
/// lookup has to search for. Returns the remainder so a caller can walk the
/// whole message.
///
/// Two shapes matter. The source line the compiler echoes back carries
/// `std.…` paths. The notes underneath carry the type it actually wanted, in
/// quotes and without the `std.` prefix: `expected type
/// 'os.linux.SIG__enum_1935'`. Missing the second shape is how one patch
/// guessed `.none` for a signal after being shown what `kill` takes but never
/// what a `SIG` is.
const SourceRef = struct { path: []const u8, line: usize, rest: []const u8 };

/// The next `<path>:<line>:<col>:` reference into the standard library in a
/// compiler message. Only std paths: the project's own files are already in
/// the context the model was given.
fn nextStdSourceRef(text: []const u8) ?SourceRef {
    const lib = sandbox_host.zig_lib_dir;
    if (lib.len == 0) return null;
    var rest = text;
    while (std.mem.indexOf(u8, rest, lib)) |at| {
        const from = rest[at..];
        const nl = std.mem.indexOfScalar(u8, from, '\n') orelse from.len;
        const line_text = from[0..nl];
        rest = from[nl..];

        // path:line:col
        const c1 = std.mem.indexOfScalar(u8, line_text, ':') orelse continue;
        const after = line_text[c1 + 1 ..];
        const c2 = std.mem.indexOfScalar(u8, after, ':') orelse continue;
        const line_no = std.fmt.parseInt(usize, after[0..c2], 10) catch continue;
        if (!std.mem.endsWith(u8, line_text[0..c1], ".zig")) continue;
        return .{ .path = line_text[0..c1], .line = line_no, .rest = rest };
    }
    return null;
}

fn pathIn(list: []const []const u8, path: []const u8) bool {
    for (list) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

const Found = struct { sym: []const u8, rest: []const u8 };

fn nextSymbol(text: []const u8) ?Found {
    const quoted = nextQuotedType(text);
    const dotted = nextStdSymbol(text);
    // Whichever comes first, so one pass over the message finds both.
    if (quoted) |q| {
        if (dotted) |d| return if (q.rest.len > d.rest.len) q else d;
        return q;
    }
    return dotted;
}

/// A type named in a compiler note, e.g. `expected type 'os.linux.SIG__enum_1935'`
/// or `enum 'os.linux.SIG__enum_1935' has no member named 'none'`. Zig's
/// generated suffix is stripped: what the reader needs is `SIG`.
fn nextQuotedType(text: []const u8) ?Found {
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '\'')) |open| {
        rest = rest[open + 1 ..];
        const close = std.mem.indexOfScalar(u8, rest, '\'') orelse return null;
        const inner = rest[0..close];
        rest = rest[close + 1 ..];
        // A type reference, not prose or a member name in quotes.
        if (std.mem.indexOfScalar(u8, inner, '.') == null) continue;
        if (std.mem.indexOfScalar(u8, inner, ' ') != null) continue;
        var name = inner[std.mem.lastIndexOfScalar(u8, inner, '.').? + 1 ..];
        if (std.mem.indexOf(u8, name, "__")) |cut| name = name[0..cut];
        if (name.len < 3) continue;
        return .{ .sym = name, .rest = rest };
    }
    return null;
}

fn nextStdSymbol(text: []const u8) ?Found {
    var rest = text;
    while (std.mem.indexOf(u8, rest, "std.")) |at| {
        rest = rest[at + "std.".len ..];
        var end: usize = 0;
        var last_dot: ?usize = null;
        while (end < rest.len) : (end += 1) {
            const c = rest[end];
            if (c == '.') {
                // A dot only continues the path when an identifier follows it,
                // so a sentence ending in "std.mem." does not swallow the space.
                if (end + 1 < rest.len and (std.ascii.isAlphanumeric(rest[end + 1]) or rest[end + 1] == '_')) {
                    last_dot = end;
                    continue;
                }
                break;
            }
            if (!std.ascii.isAlphanumeric(c) and c != '_') break;
        }
        const path = rest[0..end];
        rest = rest[end..];
        if (path.len == 0) continue;
        const sym = if (last_dot) |d| path[d + 1 ..] else path;
        if (sym.len < 3) continue;
        return .{ .sym = sym, .rest = rest };
    }
    return null;
}

/// Copied into staging when present, so the staged binary can actually run.
/// Never promoted back: neither path passes validatePath.
const staging_runtime_files = [_][]const u8{ "config.local.toml", ".env" };

/// Repeated verbatim to the model whenever it writes somewhere it may not, so
/// the retry has the whole rule and not just the refusal.
const surface_rules =
    \\You may change: src/ (but not src/evals/, src/improve/, or src/tools/builder.zig), tools/ (but not tools/bin/, and under tools/manifests/ only *.tool.json), skills/, tests/, docs/, README.md, AGENTS.md, build.zig, build.zig.zon, config.toml.
    \\You may CREATE a new evals/<name>.task.json, which adds a case to the suite your work is graded against. You may never modify or delete an eval that already exists.
;

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
    /// Set when this run is isolated in its own git worktree (the normal
    /// case — see cmdImproveSelf). Each promotion merges back into the base
    /// branch through this at the ref level; null runs promote straight
    /// into whatever tree the process is already in, unisolated.
    worktree: ?*const worktree_mod.Worktree = null,
    /// Feedback text from the previous failed attempt, fed to the next one so
    /// the model sees what went wrong. Per-instance: this must not be a
    /// container-level `var`, or concurrent Engine instances would share and
    /// corrupt each other's feedback.
    feedback: ?[]const u8 = null,
    /// Files the model asked to be shown, granted for the rest of the run and
    /// pinned into every prompt after the request. Per-instance for the same
    /// reason `feedback` is.
    granted: []const []const u8 = &.{},
    /// File requests left in this run. Set from Options at the top of `run`;
    /// the only thing that makes the request round terminate.
    requests_left: u32 = 0,

    /// Score bands for the focus block, highest first. A file the instruction
    /// names is the file being patched and goes in whatever its size; a file
    /// the model asked for is bounded, because the model chooses it and
    /// src/cli.zig alone is 310 KB.
    const pin_score: usize = 1_000_000;
    const request_score: usize = 500_000;

    pub fn run(self: *Engine, opts: Options) !void {
        log.log(.info, "improve-self: {s}", .{opts.instructions});
        for (gate_evals) |g| log.log(.info, "gate: {s}", .{g});
        self.requests_left = opts.max_context_requests;

        self.hist = history_mod.History.init(self.ctx.gpa, self.ctx.io, std.Io.Dir.cwd(), "state");
        self.instructions = opts.instructions;
        defer self.hist.deinit();
        const before = try self.gateScore();
        log.log(.info, "baseline gate: {d:.2}/{d} passing", .{ before.score, before.total });

        var promoted_any = false;
        // A static instruction against an unchanging tree gives the model the
        // same question every time it runs dry, so once it starts saying "no
        // changes needed" it tends to keep saying it: nothing about the input
        // changes between iterations. Left unchecked, a large --iters spends
        // its remainder on calls that were never going to do anything — this
        // stops the run instead of grinding through them.
        const no_change_stop_threshold = 8;
        var consecutive_no_change: usize = 0;
        for (0..opts.iters) |iter| {
            log.log(.info, "--- improve iteration {d}/{d} ---", .{ iter + 1, opts.iters });
            var attempted = false;
            var last_outcome: Outcome = .failed;
            var attempt: u32 = 0;
            while (attempt < opts.max_attempts_per_iter) {
                const outcome = try self.improveOnce(opts, attempt + 1, if (attempt == 0) null else self.feedback);
                // A file request is not an attempt: it produced no patch to
                // judge, and charging it against the retry budget would leave
                // a run that asked one question with nothing left to answer it
                // with. `requests_left` is what bounds this, not the loop.
                if (outcome == .need_context) continue;
                attempt += 1;
                last_outcome = outcome;
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
                    // Taken by the `continue` above; listed so that adding an
                    // outcome later is a compile error here rather than a
                    // silently mishandled one.
                    .need_context => {},
                }
            }
            if (!attempted) log.log(.warn, "iteration {d}: all attempts failed", .{iter + 1});

            consecutive_no_change = if (last_outcome == .no_change) consecutive_no_change + 1 else 0;
            if (consecutive_no_change >= no_change_stop_threshold) {
                log.log(.info, "stopping early: {d} consecutive iterations found nothing left to change for this instruction ({d}/{d} iterations used)", .{ consecutive_no_change, iter + 1, opts.iters });
                break;
            }
        }

        const after = try self.gateScore();
        log.log(.info, "final gate: {d:.2}/{d} passing", .{ after.score, after.total });
        if (!promoted_any) log.log(.info, "no changes were promoted", .{});
    }

    const Outcome = enum { accepted, no_change, failed, need_context };

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
        const system_prompt = try std.fmt.allocPrint(self.arena, improve_system_fmt, .{ improve_system, context.bulk });
        const focus_prompt = if (context.focus.len > 0)
            try std.fmt.allocPrint(self.arena, improve_focus_fmt, .{context.focus})
        else
            "";
        // What earlier runs already did and where they failed. Volatile, so it
        // belongs in the user half with the instruction, not in the cached
        // system half.
        const history_block = self.hist.recentSummary(self.arena, 12) catch "";
        const user_prompt = try std.fmt.allocPrint(self.arena, improve_user_fmt, .{
            opts.instructions,
            gate_tail,
            if (history_block.len > 0) history_block else "(no earlier attempts)",
            last_error orelse "none",
        });

        log.log(.info, "iteration attempt {d}: asking model for a proposal ({d} bytes context)", .{ attempt, context.bytes });

        // ---- 2. proposal from the model ----
        var msg_buf: [3]types.Message = undefined;
        var msg_n: usize = 0;
        msg_buf[msg_n] = .{ .role = .system, .content = system_prompt };
        msg_n += 1;
        if (focus_prompt.len > 0) {
            msg_buf[msg_n] = .{ .role = .system, .content = focus_prompt };
            msg_n += 1;
        }
        msg_buf[msg_n] = .{ .role = .user, .content = user_prompt };
        msg_n += 1;
        const messages = msg_buf[0..msg_n];
        var err_detail: ?[]const u8 = null;
        const resp = client.chat(self.ctx, self.arena, .{
            .provider = self.provider,
            .messages = messages,
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
            // Log the length only, not the content: the raw model response can
            // contain user PII echoed back from the conversation context.
            if (resp.raw) |raw| log.log(.debug, "raw response length: {d} chars", .{raw.len});
            self.feedback = "Your previous response had an empty content field. Output the JSON object in the content field.";
            return .failed;
        }

        // ---- 2a. a request for files, instead of a patch ----
        // The alternative to asking is guessing: an exact-match patch against
        // a file the model was never shown cannot match, and the run spends
        // its whole retry budget failing the same way. Checked before the
        // proposal parser, which would read a request as a malformed patch and
        // send back advice about JSON escaping.
        //
        // Detection itself must not be gated on requests_left: that budget is
        // per *run* (not per iteration), so a long run (e.g. --iters far above
        // a handful) exhausts it early and every later iteration would
        // otherwise fall through to parseProposal with a {"need": [...]}
        // body, failing on the missing "summary"/"changes" fields with advice
        // about JSON escaping that has nothing to do with the real problem.
        var refused: ?[]const u8 = null;
        if (proposal_mod.parseFileRequest(self.arena, json_text, opts.max_request_files, &refused) catch null) |want| {
            if (self.requests_left == 0) {
                log.log(.warn, "model asked for {d} file(s) but this run's request budget is spent", .{want.len});
                self.feedback = "Your file-request budget for this run is used up. Propose a patch with whatever is already in context above, or answer that no changes are needed.";
                return .failed;
            }
            self.requests_left -= 1;
            var missing: std.ArrayList([]const u8) = .empty;
            const added = try self.grant(want, &missing);
            if (added > 0) {
                log.log(.info, "model asked for {d} file(s); {d} newly granted, {d} request(s) left", .{ want.len, added, self.requests_left });
                for (self.granted) |g| log.log(.debug, "granted: {s}", .{g});
                // The granted files are the answer; stale feedback about a
                // previous failure still stands and must not be cleared.
                return .need_context;
            }
            // Nothing new to show. Asking again would return the same
            // question, so say why and make the next call produce a patch.
            log.log(.warn, "file request added nothing new; asking for a patch instead", .{});
            self.feedback = try std.fmt.allocPrint(
                self.arena,
                "You asked for files instead of a patch, but none could be added: {s}{s}{s}Everything else you asked for is already in the context above. Propose the patch now, or answer that no changes are needed.",
                .{
                    if (refused) |bad| bad else "",
                    if (refused != null) " is outside the readable surface. " else "",
                    if (missing.items.len > 0) "Some of those paths do not exist in this repository. " else "",
                },
            );
            return .failed;
        }

        var rejected_path: ?[]const u8 = null;
        const proposal = proposal_mod.parseProposal(self.arena, json_text, opts.max_changes, opts.max_change_bytes, &rejected_path) catch |err| {
            log.log(.error_, "proposal rejected: {s}", .{@errorName(err)});
            // A path rejection has nothing to do with JSON escaping, and the
            // generic advice below sent the model straight back to the same
            // path on every retry within one iteration -- but that feedback
            // never reached the *next* iteration (attempt 0 always starts
            // with last_error = null), and this whole catch block never
            // recorded anything to history, so a fresh iteration had no
            // memory of it either. A model whose instruction naturally draws
            // it back to the same forbidden file (an "improve improve-self"
            // instruction pulling toward src/improve/proposal.zig, say) could
            // repeat the identical rejected proposal every iteration for the
            // rest of a long run. Recording it here means the next iteration
            // sees it in history_block ("what earlier runs already did and
            // where they failed") even on a fresh attempt 0.
            if (rejected_path) |bad| {
                const id = self.newId() catch null;
                if (id) |owned_id| {
                    defer self.ctx.gpa.free(owned_id);
                    self.hist.append(owned_id, .failed, opts.instructions, "propose a change outside the modifiable surface", &.{bad}, 0, 0, try std.fmt.allocPrint(self.arena, "\"{s}\" is not allowed to write", .{bad}), &.{}) catch |herr|
                        log.log(.warn, "history append failed: {s}", .{@errorName(herr)});
                }
                self.feedback = try std.fmt.allocPrint(
                    self.arena,
                    "You proposed a change to \"{s}\", which you are not allowed to write.\n" ++
                        "{s}\n" ++
                        "Pick a different file, or say no changes are needed.",
                    .{ bad, surface_rules },
                );
                return .failed;
            }
            log.log(.debug, "proposal text (first 1500): {s}", .{json_text[0..@min(json_text.len, 1500)]});
            // "SyntaxError" alone tells the model nothing it can act on. The
            // usual cause is a file whose own content is full of quotes and
            // braces (a .tool.json descriptor), escaped wrongly inside the
            // proposal, so say that and show what actually arrived.
            const head = json_text[0..@min(json_text.len, 400)];
            const tail = if (json_text.len > 400) json_text[json_text.len - @min(json_text.len - 400, 200) ..] else "";
            self.feedback = try std.fmt.allocPrint(
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

        // The eval suite is the gate this proposal has to pass, so a pass may
        // add to it but never rewrite it. Checked against the live tree, which
        // is what "already exists" has to mean.
        for (proposal.changes) |c| {
            if (!proposal_mod.isAppendOnly(c.file)) continue;
            const exists = blk: {
                std.Io.Dir.cwd().access(self.ctx.io, c.file, .{}) catch break :blk false;
                break :blk true;
            };
            if (exists or c.old.len != 0) {
                log.log(.warn, "proposal rejected: '{s}' already exists and may only be added to, not rewritten", .{c.file});
                self.feedback = try std.fmt.allocPrint(
                    self.arena,
                    "You tried to rewrite \"{s}\". Files under evals/ are the gate your own work is measured against: you may create a new one, never change or remove an existing one.\n{s}",
                    .{ c.file, surface_rules },
                );
                return .failed;
            }
        }

        // ---- 4. reject work already done ----
        // The gates decide whether a change is correct; none of them asks
        // whether it is new. A redundant edit builds, tests, formats and lints,
        // so without this the loop can promote the same edit repeatedly.
        var fp_list: std.ArrayList(u64) = .empty;
        defer fp_list.deinit(self.ctx.gpa);
        for (proposal.changes) |c| {
            try fp_list.append(self.ctx.gpa, history_mod.History.changeFingerprint(c.file, c.old, c.new));
        }
        const fingerprints = fp_list.items;
        {
            var dup_arena = std.heap.ArenaAllocator.init(self.ctx.gpa);
            defer dup_arena.deinit();
            if (self.hist.alreadyAccepted(dup_arena.allocator(), fingerprints) catch false) {
                log.log(.warn, "proposal repeats an improvement already accepted; skipping", .{});
                // Not a failure: nothing went wrong and nothing changed, so
                // retrying the same attempt would only spend tokens repeating
                // the refusal.
                return .no_change;
            }
        }

        // ---- 5. staging ----
        const id = try self.newId();
        defer self.ctx.gpa.free(id);
        const staging = try std.fmt.allocPrint(self.ctx.gpa, "state/staging/{s}", .{id});
        defer self.ctx.gpa.free(staging);
        try self.prepareStaging(staging);

        const staged_dir = try std.Io.Dir.cwd().openDir(self.ctx.io, staging, .{});
        defer staged_dir.close(self.ctx.io);

        self.applyPatch(staging, proposal.changes) catch |err| {
            log.log(.error_, "applying patch failed: {s}", .{@errorName(err)});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, proposalChangedPathsSlice(self.arena, proposal.changes) catch &.{}, 0, 0, @errorName(err), fingerprints);
            self.feedback = try std.fmt.allocPrint(
                self.arena,
                "Your previous patch failed to apply: {s}. The \"old\" text of every change must match the current file byte for byte, including whitespace. Re-read the file content shown above and match it exactly, or propose a different change.",
                .{@errorName(err)},
            );
            self.removeTree(staging);
            return .failed;
        };

        // Auto-format the staged .zig files so promoted code is always
        // zig-fmt-clean regardless of the model's output formatting.
        const fmt_files_all = try proposalChangedPaths(self.ctx.gpa, proposal);
        defer self.ctx.gpa.free(fmt_files_all);
        var fmt_auto = try gate_checks.formatFiles(self.ctx.gpa, self.ctx.io, staged_dir, fmt_files_all);
        defer fmt_auto.deinit(self.ctx.gpa);

        // Before spending a compile on it: a patch that dropped a gate from
        // the improvement machinery would pass every check that follows,
        // because those checks are run by this binary and not by the patched
        // one, and then never run again.
        if (try self.brokenInvariant(staged_dir, proposal.changes)) |bad| {
            log.log(.warn, "proposal rejected: it removes '{s}' from {s}", .{ bad.needle, bad.file });
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, proposalChangedPathsSlice(self.arena, proposal.changes) catch &.{}, 0, 0, bad.needle, fingerprints);
            self.feedback = try std.fmt.allocPrint(
                self.arena,
                "Your patch removed \"{s}\" from {s}. That call is part of the gate every improvement has to pass, including this one. Keep it and re-propose.",
                .{ bad.needle, bad.file },
            );
            self.removeTree(staging);
            return .failed;
        }

        // ---- 5. gate ----
        log.log(.info, "gating in {s} ...", .{staging});
        var build = try gate_checks.buildGate(self.ctx.gpa, self.ctx.io, staged_dir, &.{});
        defer build.deinit(self.ctx.gpa);
        if (!build.ok) {
            const tail = try errorTail(self.arena, build.detail);
            log.log(.error_, "staging build failed:", .{});
            log.log(.error_, "{s}", .{tail});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, proposalChangedPathsSlice(self.arena, proposal.changes) catch &.{}, 0, 0, tail, fingerprints);
            self.feedback = try std.fmt.allocPrint(self.arena, "Your previous patch was applied but {s}:\n{s}\nFix exactly that and re-propose.{s}", .{ "the staged tree did not compile", tail, self.stdSymbolHelp(tail) });
            self.removeTree(staging);
            return .failed;
        }

        // Tools before tests: the sandbox tests load zig-out/tools/*.wasm from
        // the working directory, and a fresh staging dir has none until this
        // gate builds them. Running tests first failed every proposal on a
        // missing artifact rather than on its own merits.
        var tools = try gate_checks.toolsGate(self.ctx.gpa, self.ctx.io, staged_dir);
        defer tools.deinit(self.ctx.gpa);
        if (!tools.ok) {
            const tail = try errorTail(self.arena, tools.detail);
            log.log(.error_, "staging tools build failed:", .{});
            log.log(.error_, "{s}", .{tail});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, proposalChangedPathsSlice(self.arena, proposal.changes) catch &.{}, 0, 0, tail, fingerprints);
            self.feedback = try std.fmt.allocPrint(self.arena, "Your previous patch was applied but {s}:\n{s}\nFix exactly that and re-propose.{s}", .{ "the staged tools did not compile", tail, self.stdSymbolHelp(tail) });
            self.removeTree(staging);
            return .failed;
        }

        var test_gate = try gate_checks.testGate(self.ctx.gpa, self.ctx.io, staged_dir);
        defer test_gate.deinit(self.ctx.gpa);
        if (!test_gate.ok) {
            const tail = try errorTail(self.arena, test_gate.detail);
            log.log(.error_, "staging tests failed:", .{});
            log.log(.error_, "{s}", .{tail});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, proposalChangedPathsSlice(self.arena, proposal.changes) catch &.{}, 0, 0, tail, fingerprints);
            self.feedback = try std.fmt.allocPrint(self.arena, "Your previous patch was applied but {s}:\n{s}\nFix exactly that and re-propose.", .{ "the staged tests failed", tail });
            self.removeTree(staging);
            return .failed;
        }

        const fmt_files = try proposalChangedPaths(self.ctx.gpa, proposal);
        defer self.ctx.gpa.free(fmt_files);
        var fmt_check = try gate_checks.fmtGate(self.ctx.gpa, self.ctx.io, staged_dir, fmt_files);
        defer fmt_check.deinit(self.ctx.gpa);
        if (!fmt_check.ok) {
            const tail = try errorTail(self.arena, fmt_check.detail);
            log.log(.error_, "staging fmt check failed:", .{});
            log.log(.error_, "{s}", .{tail});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, proposalChangedPathsSlice(self.arena, proposal.changes) catch &.{}, 0, 0, tail, fingerprints);
            self.feedback = try std.fmt.allocPrint(self.arena, "Your previous patch was applied but {s}:\n{s}\nFix exactly that and re-propose.", .{ "zig fmt rejected your formatting", tail });
            self.removeTree(staging);
            return .failed;
        }

        var lint_check = try gate_checks.lintGate(self.ctx.gpa, self.ctx.io, staged_dir, fmt_files);
        defer lint_check.deinit(self.ctx.gpa);
        if (!lint_check.ok) {
            const tail = try errorTail(self.arena, lint_check.detail);
            log.log(.error_, "staging lint failed: {s}", .{tail});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, proposalChangedPathsSlice(self.arena, proposal.changes) catch &.{}, 0, 0, tail, fingerprints);
            self.feedback = try std.fmt.allocPrint(self.arena, "Your previous patch was applied but the lint gate rejected it:\n{s}\nFix exactly that and re-propose.", .{tail});
            self.removeTree(staging);
            return .failed;
        }

        if (self.cfg.improve.capability_gate) {
            var cap = try self.capabilityGate(staging, staged_dir);
            defer cap.deinit(self.ctx.gpa);
            if (!cap.ok) {
                // A task eval is an agent run, and an agent run is not
                // deterministic: one model turn that skips a tool call fails a
                // case that passed a minute earlier. Rejecting a good patch on
                // that would stall every improvement, so a failure has to
                // happen twice to count.
                //
                // Only re-run the cases that actually failed: each case is a
                // full agent run, and re-running the whole suite for one flaky
                // case costs N runs instead of 1.
                const failed_names = try parseFailedEvalNames(self.arena, cap.detail);
                if (failed_names.len > 0) {
                    log.log(.warn, "capability evals: {d} case(s) failed; retrying only those", .{failed_names.len});
                    var retry = try self.capabilityGateRetry(staged_dir, failed_names);
                    defer retry.deinit(self.ctx.gpa);
                    if (retry.ok) {
                        log.log(.info, "capability evals: PASS on retry", .{});
                    } else {
                        const tail = try errorTail(self.arena, retry.detail);
                        log.log(.error_, "staged tree failed its own capability evals:", .{});
                        log.log(.error_, "{s}", .{tail});
                        try self.hist.append(id, .failed, opts.instructions, proposal.summary, proposalChangedPathsSlice(self.arena, proposal.changes) catch &.{}, 0, 0, tail, fingerprints);
                        self.feedback = try std.fmt.allocPrint(self.arena, "Your previous patch compiled and its unit tests passed, but it broke a capability the eval suite checks:\n{s}\nFix exactly that and re-propose.", .{tail});
                        self.removeTree(staging);
                        return .failed;
                    }
                } else {
                    // Could not parse any names; fall back to full retry.
                    log.log(.warn, "capability evals failed; retrying all (no parseable FAIL lines)", .{});
                    const retry = try self.capabilityGate(staging, staged_dir);
                    cap.deinit(self.ctx.gpa);
                    cap = retry;
                    if (cap.ok) {
                        log.log(.info, "capability evals: PASS on retry", .{});
                    } else {
                        const tail = try errorTail(self.arena, cap.detail);
                        log.log(.error_, "staged tree failed its own capability evals:", .{});
                        log.log(.error_, "{s}", .{tail});
                        try self.hist.append(id, .failed, opts.instructions, proposal.summary, proposalChangedPathsSlice(self.arena, proposal.changes) catch &.{}, 0, 0, tail, fingerprints);
                        self.feedback = try std.fmt.allocPrint(self.arena, "Your previous patch compiled and its unit tests passed, but it broke a capability the eval suite checks:\n{s}\nFix exactly that and re-propose.", .{tail});
                        self.removeTree(staging);
                        return .failed;
                    }
                }
            }
            log.log(.info, "capability evals: PASS", .{});
        }

        // ---- 6. promote ----
        log.log(.info, "gates green — promoting {d} file(s)", .{proposal.changes.len});
        const files = proposalChangedPathsSlice(self.arena, proposal.changes) catch &.{};
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
            atomic_write.writeFile(self.ctx.io, std.Io.Dir.cwd(), c.file, data) catch |err| {
                // A write failing partway through the set (disk full,
                // permission error, ...) must not leave the live tree with
                // some files promoted and others not: nothing here has been
                // recorded to history yet, so it would look, to the next
                // run, like a half-applied change nobody knows about.
                log.log(.error_, "promotion of '{s}' failed: {s} — restoring the pre-promotion snapshot", .{ c.file, @errorName(err) });
                self.hist.restoreFiles(id, files);
                self.removeTree(staging);
                return err;
            };
        }

        // Recorded before git commit and peer notification, which are
        // best-effort and safe to lose: a crash here must not leave a
        // promoted file set with no history entry, because that entry is
        // both the dedup guard (`alreadyAccepted`) and the only way to
        // `revert` a promotion — without it a half-crashed run looks, to
        // the next one, like work that never happened.
        const live = try self.gateScore();
        const score_after = live.score / @as(f64, @floatFromInt(@max(live.total, 1)));
        try self.hist.append(id, .accepted, opts.instructions, proposal.summary, files, 0, score_after, "", fingerprints);

        // Git strategy: commit the promoted change so history, diff review and
        // bisectability work; the state/history snapshot remains the fallback.
        if (self.cfg.agent.git_commit) {
            self.gitCommit(id, proposal.summary, files);
            if (self.worktree) |wt| {
                const msg = std.fmt.allocPrint(self.arena, "clanker: {s} [{s}]", .{ proposal.summary, id }) catch proposal.summary;
                wt.mergeBack(self.ctx.gpa, self.ctx.io, msg);
            }
        }
        self.notifyPeers("improve", proposal.summary);

        log.log(.info, "✓ promoted improvement {s} (gate {d:.2}/{d})", .{ id, live.score, live.total });
        // Clean up the staging directory now that promotion is done.
        self.removeTree(staging);
        return .accepted;
    }

    /// Adds `paths` to the granted set for the rest of the run, skipping ones
    /// already there. Returns how many were new; paths that do not exist are
    /// appended to `missing` instead.
    ///
    /// The existence check is what keeps a hallucinated path from being
    /// granted: `collectFile` drops a file it cannot read with only a debug
    /// line, so an invented path would look, from the next prompt, exactly
    /// like a granted file that happened to be empty — and the model would
    /// spend the rest of the run patching against nothing.
    fn grant(self: *Engine, paths: []const []const u8, missing: *std.ArrayList([]const u8)) !usize {
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(self.arena, self.granted);
        var added: usize = 0;
        for (paths) |p| {
            if (pathIn(list.items, p)) continue;
            std.Io.Dir.cwd().access(self.ctx.io, p, .{}) catch {
                log.log(.warn, "file request: '{s}' does not exist", .{p});
                try missing.append(self.arena, p);
                continue;
            };
            try list.append(self.arena, try self.arena.dupe(u8, p));
            added += 1;
        }
        self.granted = try list.toOwnedSlice(self.arena);
        return added;
    }

    /// Applies the proposal's changes under `staging` through the sandboxed
    /// `patch_apply` WASM tool (fs_prefixes: ["state/staging"]) instead of a
    /// native file-write path. The tool only performs the text edits; the
    /// decision to gate and promote the result stays here, native.
    fn applyPatch(self: *Engine, staging: []const u8, changes: []const proposal_mod.Change) !void {
        var reg = try registry.Registry.load(self.ctx.io, self.arena, std.Io.Dir.cwd(), self.cfg.agent.tools_dir);
        const mod = try runtime.loadNamedTool(self.ctx.gpa, self.ctx.io, self.arena, self.ctx.environ_map, self.cfg, &reg, "patch_apply", null);
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
        defer self.ctx.gpa.free(raw);
        const resp = std.json.parseFromSliceLeaky(struct { ok: bool = false, @"error": []const u8 = "" }, self.arena, raw, .{ .ignore_unknown_fields = true }) catch
            return error.PatchApplyFailed;
        if (!resp.ok) {
            log.log(.error_, "patch_apply tool: {s}", .{resp.@"error"});
            return error.PatchApplyFailed;
        }
    }

    fn gitCommit(self: *Engine, id: []const u8, summary: []const u8, files: []const []const u8) void {
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
        const commit = std.process.run(self.ctx.gpa, self.ctx.io, .{ .argv = &commit_argv }) catch |err| {
            log.log(.warn, "git commit failed to spawn: {s}; change is only in the state/history snapshot", .{@errorName(err)});
            return;
        };
        defer self.ctx.gpa.free(commit.stdout);
        defer self.ctx.gpa.free(commit.stderr);
        const ok = switch (commit.term) {
            .exited => |c| c == 0,
            else => false,
        };
        if (ok) {
            log.log(.info, "committed as git change: {s}", .{msg});
        } else {
            log.log(.warn, "git commit failed; change is only in the state/history snapshot: {s}", .{commit.stderr});
        }
    }

    /// Fans a promotion event out to every configured peer through the
    /// sandboxed `peers` WASM tool, the same path `clanker notify` and the
    /// model itself use, instead of a second hand-rolled HTTP client.
    fn notifyPeers(self: *Engine, kind: []const u8, payload: []const u8) void {
        if (!self.cfg.modules.peers) return;
        if (!self.cfg.notify.on) return;
        if (self.cfg.peers.len == 0) return;

        var reg = registry.Registry.load(self.ctx.io, self.arena, std.Io.Dir.cwd(), self.cfg.agent.tools_dir) catch |err| {
            log.log(.warn, "notifyPeers: registry load failed: {s}", .{@errorName(err)});
            return;
        };
        const mod = runtime.loadNamedTool(self.ctx.gpa, self.ctx.io, self.arena, self.ctx.environ_map, self.cfg, &reg, "peers", null) catch |err| {
            log.log(.warn, "notifyPeers: tool load failed: {s}", .{@errorName(err)});
            return;
        };
        defer mod.deinit();

        var ibuf: [8192]u8 = undefined;
        var iw: std.Io.Writer = .fixed(&ibuf);
        var is = std.json.Stringify{ .writer = &iw, .options = .{} };
        is.beginObject() catch return;
        is.objectField("action") catch return;
        is.write("notify") catch return;
        is.objectField("message") catch return;
        is.write(payload) catch return;
        is.objectField("kind") catch return;
        is.write(kind) catch return;
        is.objectField("topic") catch return;
        is.write(self.cfg.notify.topic) catch return;
        is.endObject() catch return;

        const raw = mod.executeTool(ibuf[0..iw.end]) catch |err| {
            log.log(.warn, "notifyPeers: tool call failed: {s}", .{@errorName(err)});
            return;
        };
        self.ctx.gpa.free(raw);
    }

    fn newId(self: *Engine) ![]const u8 {
        const ns = std.Io.Timestamp.now(self.ctx.io, .real).nanoseconds;
        return std.fmt.allocPrint(self.ctx.gpa, "imp-{d}", .{ns});
    }

    fn gateEvalNamed(name: []const u8) scorers.Eval {
        const kind: scorers.Kind = if (std.mem.eql(u8, name, "selfhost_build"))
            .selfhost_build
        else if (std.mem.eql(u8, name, "selfhost_tests"))
            .selfhost_tests
        else
            .selfhost_tools;
        return .{ .name = name, .kind = kind };
    }

    fn gateScore(self: *Engine) !struct { score: f64, total: usize } {
        var passing: usize = 0;
        for (gate_evals) |name| {
            const e = gateEvalNamed(name);
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
        const detail = if (g.ok) "" else try errorTail(self.arena, g.detail);
        return .{ .name = e.name, .kind = e.kind, .score = if (g.ok) 1 else 0, .ok = g.ok, .detail = detail };
    }

    fn gateErrorTail(self: *Engine) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        for (gate_evals) |name| {
            const e = gateEvalNamed(name);
            const res = try self.runGateEval(&e);
            if (!res.ok) {
                try buf.appendSlice(self.arena, res.detail);
                try buf.append(self.arena, '\n');
            }
        }
        if (buf.items.len == 0) return "all gates pass";
        return buf.toOwnedSlice(self.arena);
    }

    /// Real declarations for the std symbols a compile error complains about.
    ///
    /// The model writes the patch in one shot with no tools, so it cannot look
    /// a signature up: it recalls one, and what it recalls is usually a
    /// different Zig version. Handing it only "expected enum, found
    /// comptime_int" leaves it guessing again, which is how one lock patch
    /// failed four attempts running on std.posix.SEEK. This is the same lookup
    /// the std_api tool does, attached to the failure that needs it.
    fn stdSymbolHelp(self: *Engine, err_text: []const u8) []const u8 {
        if (sandbox_host.zig_lib_dir.len == 0) return "";
        var out: std.ArrayList(u8) = .empty;
        var seen: [4][]const u8 = undefined;
        var seen_n: usize = 0;

        // The compiler already says where the thing it wanted is declared:
        // "…/std/os/linux.zig:4036:8: note: enum declared here". Reading those
        // lines answers the question exactly, with no guessing about which of
        // several same-named declarations is the relevant one.
        var notes = err_text;
        var shown: usize = 0;
        while (nextStdSourceRef(notes)) |ref| {
            notes = ref.rest;
            if (shown == 3) break;
            const excerpt = self.readAround(ref.path, ref.line) orelse continue;
            shown += 1;
            out.appendSlice(self.arena, "\n") catch return "";
            out.appendSlice(self.arena, ref.path) catch return "";
            out.appendSlice(self.arena, ", as it actually is in this Zig:\n") catch return "";
            out.appendSlice(self.arena, excerpt) catch return "";
        }

        var rest = err_text;
        while (nextSymbol(rest)) |found| {
            rest = found.rest;
            const sym = found.sym;

            var dup = false;
            for (seen[0..seen_n]) |s2| {
                if (std.mem.eql(u8, s2, sym)) dup = true;
            }
            if (dup) continue;
            if (seen_n == seen.len) break;
            seen[seen_n] = sym;
            seen_n += 1;

            const lines = self.stdGrep(sym) orelse continue;
            out.appendSlice(self.arena, "\n") catch return "";
            out.appendSlice(self.arena, sym) catch return "";
            out.appendSlice(self.arena, ", as it actually is in this Zig:\n") catch return "";
            out.appendSlice(self.arena, lines) catch return "";
        }
        if (out.items.len == 0) return "";
        return out.items;
    }

    /// 15 lines of `path` centred on `line`, for showing a declaration the
    /// compiler pointed at.
    fn readAround(self: *Engine, path: []const u8, line: usize) ?[]const u8 {
        const data = std.Io.Dir.cwd().readFileAlloc(self.ctx.io, path, self.arena, .limited(4 << 20)) catch return null;
        var n: usize = 1;
        var start: usize = 0;
        var idx: usize = 0;
        var end: usize = data.len;
        const first = if (line > 1) line - 1 else 1;
        const last = line + 14;
        while (idx < data.len) : (idx += 1) {
            if (data[idx] != '\n') continue;
            if (n == first - 1) start = idx + 1;
            if (n == last) {
                end = idx;
                break;
            }
            n += 1;
        }
        if (start >= end) return null;
        return data[start..end];
    }

    /// Up to 12 lines mentioning `sym` in the standard library source.
    fn stdGrep(self: *Engine, sym: []const u8) ?[]const u8 {
        const std_dir = std.fmt.allocPrint(self.ctx.gpa, "{s}/std", .{sandbox_host.zig_lib_dir}) catch return null;
        defer self.ctx.gpa.free(std_dir);
        const pattern = std.fmt.allocPrint(self.ctx.gpa, "(pub (fn|const|var) {s}\\b|\\b{s} *[:=])", .{ sym, sym }) catch return null;
        defer self.ctx.gpa.free(pattern);
        // With context: a bare "pub const SIG = ..." line does not say what
        // its members are, which is exactly the question being asked.
        const run_argv = [_][]const u8{ "rg", "-n", "--max-count", "6", "-A", "10", "-e", pattern, std_dir };
        const res = std.process.run(self.ctx.gpa, self.ctx.io, .{
            .argv = &run_argv,
            .stdout_limit = .limited(8 * 1024),
            .stderr_limit = .limited(4 * 1024),
        }) catch return null;
        defer self.ctx.gpa.free(res.stdout);
        defer self.ctx.gpa.free(res.stderr);
        if (res.stdout.len == 0) return null;
        return self.arena.dupe(u8, res.stdout) catch null;
    }

    /// The first gate invariant the staged tree no longer satisfies, if any.
    /// Only files the proposal actually touched are read: everything else is a
    /// verbatim copy of the tree these invariants already hold in.
    fn brokenInvariant(
        self: *Engine,
        staged_dir: std.Io.Dir,
        changes: []const proposal_mod.Change,
    ) !?struct { file: []const u8, needle: []const u8 } {
        for (gate_invariants) |inv| {
            var touched = false;
            for (changes) |c| {
                if (std.mem.eql(u8, c.file, inv.file)) touched = true;
            }
            if (!touched) continue;
            const data = staged_dir.readFileAlloc(self.ctx.io, inv.file, self.arena, .limited(1 << 22)) catch continue;
            if (std.mem.indexOf(u8, data, inv.needle) == null) return .{ .file = inv.file, .needle = inv.needle };
        }
        return null;
    }

    /// Runs the staged tree's own task evals with the staged binary. The
    /// build gates only prove the patch compiles and its unit tests pass;
    /// nothing there notices a change that keeps everything green while
    /// breaking a tool an agent depends on, which is how a promotion once cut
    /// the worker stack down to a segfault. This is the check that fails.
    fn capabilityGate(self: *Engine, staging: []const u8, staged_dir: std.Io.Dir) !gate_checks.GateResult {
        // Relative to the child's own cwd, which is the staging tree: the
        // binary under test has to be the staged one, not the one running now.
        const exe = "./zig-out/bin/clanker";
        const probe = try std.fmt.allocPrint(self.ctx.gpa, "{s}/zig-out/bin/clanker", .{staging});
        defer self.ctx.gpa.free(probe);
        std.Io.Dir.cwd().access(self.ctx.io, probe, .{}) catch |err| {
            log.log(.warn, "capability gate skipped: no staged binary ({s})", .{@errorName(err)});
            return .{ .ok = true, .label = "capability evals" };
        };

        const result = try std.process.run(self.ctx.gpa, self.ctx.io, .{
            .argv = &.{ exe, "eval", "--tasks" },
            .cwd = .{ .dir = staged_dir },
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        });
        const ok = switch (result.term) {
            .exited => |c| c == 0,
            else => false,
        };
        const detail: []const u8 = if (ok) "" else if (result.stdout.len > 0) result.stdout else result.stderr;
        return .{ .ok = ok, .label = "capability evals", .detail = detail, .stdout = result.stdout, .stderr = result.stderr };
    }

    /// Re-runs only the named eval cases (the ones that failed on the first
    /// pass). Returns a green gate when every retried case passes.
    fn capabilityGateRetry(self: *Engine, staged_dir: std.Io.Dir, failed_names: []const []const u8) !gate_checks.GateResult {
        const exe = "./zig-out/bin/clanker";
        var all_ok = true;
        var detail_buf: std.ArrayList(u8) = .empty;
        defer detail_buf.deinit(self.ctx.gpa);
        for (failed_names) |name| {
            const result = try std.process.run(self.ctx.gpa, self.ctx.io, .{
                .argv = &.{ exe, "eval", name },
                .cwd = .{ .dir = staged_dir },
                .stdout_limit = .limited(1 << 20),
                .stderr_limit = .limited(1 << 20),
            });
            const case_ok = switch (result.term) {
                .exited => |c| c == 0,
                else => false,
            };
            if (!case_ok) {
                all_ok = false;
                const out = if (result.stdout.len > 0) result.stdout else result.stderr;
                detail_buf.appendSlice(self.ctx.gpa, out) catch {};
                detail_buf.append(self.ctx.gpa, '\n') catch {};
            }
            self.ctx.gpa.free(result.stdout);
            self.ctx.gpa.free(result.stderr);
        }
        const detail: []const u8 = if (all_ok) "" else (self.arena.dupe(u8, detail_buf.items) catch "");
        return .{ .ok = all_ok, .label = "capability evals", .detail = detail };
    }

    // ------------------------------------------------------------ context --

    /// How much source to send, derived from the model actually being used.
    /// Roughly 3 bytes per token over about a third of the window, which comes
    /// out at the window itself in bytes, leaving the rest for the rules, the
    /// instruction, the gate output and the answer (which carries whole
    /// rewritten files).
    ///
    /// The ceiling is not the model's whole window. Sending the entire
    /// repository cost 345k prompt tokens a call, at 1.79 dollars whenever the
    /// prefix missed the cache, which it does on every run that follows a
    /// promotion because the source it contains is what changed. A quarter of a
    /// megabyte still carries the files an instruction is about, whole, plus a
    /// wide margin of neighbours; what does not fit is listed by name so the
    /// model knows not to patch it blind.
    fn contextBudget(self: *const Engine) usize {
        const window: usize = self.provider.activeModel().context_window;
        return std.math.clamp(window, 64 * 1024, 256 * 1024);
    }

    /// The source context, split at the cache breakpoint.
    ///
    /// `bulk` is everything the patch is unlikely to touch and `focus` the few
    /// files it is about. They go out as two system blocks, each with its own
    /// breakpoint, so a promotion that rewrites a focus file leaves the bulk
    /// cached. Ordered the other way round, the file being edited sat first and
    /// invalidated the entire block: the first call of every run after a
    /// promotion missed completely and re-billed the whole context.
    pub const Context = struct {
        bulk: []const u8,
        focus: []const u8,
        files: usize,
        bytes: usize,
    };

    fn collectContext(self: *Engine, max_bytes: usize) !Context {
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
        // The suite a proposal is graded against. Add-only, but invisible means
        // the model re-proposes cases that already exist and the whole
        // iteration is refused.
        try collectCandidates(self, "evals", keywords.items, &cands);
        for ([_][]const u8{ "build.zig", "build.zig.zon", "config.toml" }) |f| {
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

        // Files an earlier round of this run asked for. Their own band, below
        // an instruction-named pin and above everything else: they belong in
        // the focus block, but under a budget, because the model chooses them.
        for (self.granted) |p| try self.pinPath(p, keywords.items, &cands, request_score);

        std.mem.sort(Candidate, cands.items, {}, struct {
            fn lt(_: void, a: Candidate, b: Candidate) bool {
                return a.score > b.score;
            }
        }.lt);

        var buf: std.ArrayList(u8) = .empty;
        var focus: std.ArrayList(u8) = .empty;
        var omitted: std.ArrayList([]const u8) = .empty;
        var included_any = false;

        // The volatile tail: the files the instruction names (pinNamedFiles
        // marks them with a score no keyword count can reach) plus whatever
        // recent runs already changed. Those are the files most likely to
        // change again, and one changed file invalidates the block it sits in,
        // so keeping them together is what lets the bulk stay cached from one
        // run to the next.
        // Bounded: twelve runs' worth of changed files is most of the large
        // files in the project, and an unbounded focus block is just the old
        // single block under a new name. Pinned files first, then churn, until
        // the tail has taken its share.
        const churn = self.hist.recentlyTouched(self.arena, 6) catch &.{};
        const focus_budget = max_bytes / 4;
        // A file the instruction names is the file being patched, so it goes in
        // whatever its size: dropping it is how a run ends in "no changes
        // needed" about a file it was never shown. tools/zig/webui/index.html
        // is 133 KB on its own, and the fix for that was once to quadruple the
        // whole context, which quadrupled the bill for every unrelated run too.
        for (cands.items) |c| {
            if (c.score < pin_score) continue;
            included_any = true;
            try self.appendWholeFile(&focus, &omitted, c, std.math.maxInt(usize));
        }
        // Then what the model asked for, on a quota of its own on top of
        // whatever the pins took. Unbounded, one request for src/cli.zig would
        // swallow the run; sharing the churn budget, a request would silently
        // push out the files recent promotions actually touched.
        const request_limit = focus.items.len + max_bytes / 4;
        for (cands.items) |c| {
            if (c.score < request_score or c.score >= pin_score) continue;
            included_any = true;
            try self.appendWholeFile(&focus, &omitted, c, request_limit);
        }
        for (cands.items) |c| {
            if (c.score >= request_score or !pathIn(churn, c.path)) continue;
            if (focus.items.len >= focus_budget) break;
            included_any = true;
            try self.appendWholeFile(&focus, &omitted, c, focus_budget);
        }
        // The bulk is deliberately chosen without reference to the
        // instruction, and emitted in path order. Selecting it by keyword
        // score made its bytes different on every run, which is the same thing
        // as having no cache at all: relevance decided the tail, and the tail
        // is what a prefix cache cannot tolerate moving. Relevance still
        // decides the focus block, which is where the instruction's own files
        // are.
        const bulk_order = try self.arena.dupe(Candidate, cands.items);
        std.mem.sort(Candidate, bulk_order, {}, struct {
            fn lt(_: void, a: Candidate, b: Candidate) bool {
                return std.mem.lessThan(u8, a.path, b.path);
            }
        }.lt);
        // A fixed share, not "whatever the focus left over": a cache block has
        // to be identical byte for byte, and a budget that moves with the focus
        // size changes which file lands last on every run. A large pinned file
        // therefore grows the total rather than shrinking the cached half.
        const bulk_budget = max_bytes - focus_budget;
        for (bulk_order) |c| {
            if (pathIn(churn, c.path)) continue;
            // Anything the focus block already carries. A pinned or granted
            // file that recent runs had not touched used to be emitted twice —
            // once in the focus and again here — which for an instruction
            // naming src/cli.zig meant paying for 310 KB of it a second time.
            if (c.score >= request_score) continue;
            included_any = true;
            try self.appendWholeFile(&buf, &omitted, c, bulk_budget);
        }
        // A file that did not fit has to be named. Silently cutting one off
        // mid-way, or dropping it entirely, left the model writing exact-match
        // patches against text it had never seen and could not know was
        // missing.
        // Into the volatile block, not the bulk: which files did not fit
        // depends on the instruction, and a list that changes every run sitting
        // at the end of the cached block invalidates the whole thing. This is
        // what kept the hit rate at zero even after the split.
        if (omitted.items.len > 0) {
            try focus.appendSlice(self.arena, "\n===== NOT INCLUDED (too large for this context; ask for one with \"need\" rather than patching it blind) =====\n");
            for (omitted.items) |path| {
                try focus.appendSlice(self.arena, path);
                try focus.appendSlice(self.arena, "\n");
            }
        }
        const total = buf.items.len + focus.items.len;
        if (total == 0) return .{ .bulk = "(no source files found)", .focus = "", .files = 0, .bytes = 0 };
        log.log(.debug, "context: {d} files, {d} bytes ({d} focus, budget {d}, {d} omitted)", .{ cands.items.len, total, focus.items.len, max_bytes, omitted.items.len });
        for (omitted.items) |o| log.log(.debug, "context: omitted {s}", .{o});
        return .{
            .bulk = try buf.toOwnedSlice(self.arena),
            .focus = try focus.toOwnedSlice(self.arena),
            .files = cands.items.len,
            .bytes = total,
        };
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
        var it = std.mem.tokenizeAny(u8, instructions, " \n\r\t,;:'\"()[]{}`*");
        while (it.next()) |tok| {
            const path = std.mem.trim(u8, tok, ".");
            if (std.mem.indexOfScalar(u8, path, '/') == null) continue;
            // .html is here for tools/zig/webui/index.html: the whole web UI is
            // one file, validatePath already lets a proposal write it, and
            // without it in context clanker could edit a page it had never
            // seen. It asked for "no changes needed" on web UI work for
            // exactly this reason.
            if (!std.mem.endsWith(u8, path, ".zig") and !std.mem.endsWith(u8, path, ".json") and
                !std.mem.endsWith(u8, path, ".md") and !std.mem.endsWith(u8, path, ".zon") and
                !std.mem.endsWith(u8, path, ".html")) continue;
            if (!proposal_mod.validatePath(path)) continue;
            try self.pinPath(path, keywords, cands, pin_score);
        }
    }

    /// Boosts one path into the given score band, reading it in if keyword
    /// scoring never gathered it. Shared by instruction-named pins and by the
    /// files the model asked for, so both land in context the same way.
    fn pinPath(self: *Engine, path: []const u8, keywords: []const []const u8, cands: *std.ArrayList(Candidate), score: usize) !void {
        for (cands.items) |*c| {
            if (std.mem.eql(u8, c.path, path)) {
                c.score += score;
                return;
            }
        }
        const before = cands.items.len;
        try self.collectFile(path, keywords, cands);
        if (cands.items.len > before) cands.items[cands.items.len - 1].score += score;
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
            // A keyword in the path says the file is what the instruction is
            // about. A keyword in the body only says the word occurs, which a
            // large file does by accident: src/cli.zig matched nearly every
            // instruction purely by being 189 KB.
            if (std.mem.indexOf(u8, rel, kw) != null) score += 10;
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
                    if (!std.mem.endsWith(u8, entry.name, ".zig") and !std.mem.endsWith(u8, entry.name, ".md") and !std.mem.endsWith(u8, entry.name, ".json") and !std.mem.endsWith(u8, entry.name, ".toml") and !std.mem.endsWith(u8, entry.name, ".zon") and !std.mem.endsWith(u8, entry.name, ".html")) continue;
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

    /// Removes a directory tree rooted at `rel` (relative to cwd). Only
    /// called on paths under state/staging/ whose names match the id
    /// pattern this engine generates.
    fn removeTree(self: *Engine, rel: []const u8) void {
        // A recursive delete that takes a path is one wrong argument away from
        // eating the working tree. Only ever a staging directory of this
        // engine's own making: "state/staging/imp-<digits>", nothing above it,
        // nothing beside it, no traversal.
        if (!isStagingDirPath(rel)) {
            log.log(.warn, "refusing to remove '{s}': not a staging directory", .{rel});
            return;
        }
        self.removeTreeAt(std.Io.Dir.cwd(), rel);
    }

    /// Exactly `state/staging/imp-<digits>` and nothing else.
    fn isStagingDirPath(rel: []const u8) bool {
        const prefix = "state/staging/";
        if (!std.mem.startsWith(u8, rel, prefix)) return false;
        const name = rel[prefix.len..];
        if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
        return isImpId(name);
    }

    /// Removes a directory tree rooted at `rel` under `base`. Split from
    /// removeTree so the unit test can operate on a tmpDir instead of cwd.
    fn removeTreeAt(self: *Engine, base: std.Io.Dir, rel: []const u8) void {
        diskcap.removeTree(self.ctx.gpa, self.ctx.io, base, rel);
    }

    /// Looks like an id this engine mints: "imp-" followed by digits.
    fn isImpId(name: []const u8) bool {
        if (!std.mem.startsWith(u8, name, "imp-")) return false;
        if (name.len <= 4) return false;
        for (name[4..]) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
        return true;
    }

    /// Keeps at most `keep` staging directories (by name, newest-last since
    /// the id embeds a timestamp), and removes the rest. Called at the start
    /// of prepareStaging so leftovers from crashed runs are collected too.
    /// `current_id` (if non-null) is never removed.
    fn pruneStaging(self: *Engine, keep: usize, current_id: ?[]const u8) void {
        const staging_root = "state/staging";
        var dir = std.Io.Dir.cwd().openDir(self.ctx.io, staging_root, .{ .iterate = true }) catch return;
        defer dir.close(self.ctx.io);
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |n| self.ctx.gpa.free(n);
            names.deinit(self.ctx.gpa);
        }
        var it = dir.iterate();
        while (it.next(self.ctx.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (!isImpId(entry.name)) continue;
            names.append(self.ctx.gpa, self.ctx.gpa.dupe(u8, entry.name) catch continue) catch continue;
        }
        if (names.items.len <= keep) return;
        // Sort ascending (oldest first): the id is "imp-<nanosecond ts>".
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        const to_remove = names.items.len - keep;
        for (names.items[0..to_remove]) |name| {
            if (current_id) |cid| {
                if (std.mem.eql(u8, name, cid)) continue;
            }
            const path = std.fmt.allocPrint(self.ctx.gpa, "{s}/{s}", .{ staging_root, name }) catch continue;
            defer self.ctx.gpa.free(path);
            self.removeTree(path);
        }
    }

    fn prepareStaging(self: *Engine, staging: []const u8) !void {
        // Prune old staging dirs before creating a new one. Extract the id
        // from the path ("state/staging/<id>").
        const current_id = if (std.mem.lastIndexOfScalar(u8, staging, '/')) |slash| staging[slash + 1 ..] else staging;
        self.pruneStaging(3, current_id);
        const dir = std.Io.Dir.cwd();
        try dir.createDirPath(self.ctx.io, staging);
        for (staging_roots) |root| {
            try copyTreeInto(self.ctx.io, self.ctx.gpa, dir, root, staging);
        }
        // Machine-local runtime context, not source: the capability gate runs
        // the staged binary, and without these it has no provider and fails
        // every proposal on missing credentials rather than on its merits.
        // Neither is in the modifiable surface, so nothing can be promoted
        // back out of them.
        for (staging_runtime_files) |f| {
            copyTreeInto(self.ctx.io, self.ctx.gpa, dir, f, staging) catch {};
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

/// The excerpt always owns its memory. It used to alias `s` whenever the input
/// was short enough to need no trimming, and every caller passes the `detail`
/// of a gate result it frees on scope exit, so the one caller that returns the
/// excerpt handed back freed memory: a gate whose output fitted in the budget
/// segfaulted the improve run while collecting the reasons a proposal was
/// rejected. Copying a string under 1500 bytes is not worth the aliasing.
fn errorTail(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const max = 1500;
    if (s.len <= max) return arena.dupe(u8, s);
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
        return arena.dupe(u8, s[start..end]);
    }
    return arena.dupe(u8, s[s.len - max ..]);
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

/// Parses eval names out of the capability gate output. The staged binary
/// prints lines like `calculator: 0.00 FAIL` — one per case. Returns the
/// names of every case that reported FAIL (arena-owned).
fn parseFailedEvalNames(arena: std.mem.Allocator, detail: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, detail, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.endsWith(u8, line, "FAIL")) continue;
        // Shape: "<name>: <score> FAIL"
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (name.len == 0) continue;
        try out.append(arena, name);
    }
    return out.toOwnedSlice(arena);
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

fn copyTreeInto(io: std.Io, gpa: std.mem.Allocator, base: std.Io.Dir, rel: []const u8, staging: []const u8) !void {
    // Handle a plain file root (e.g. build.zig, config.toml) directly.
    if (!isDir(base, io, rel)) {
        const data = base.readFileAlloc(io, rel, gpa, .limited(1 << 24)) catch |err| {
            log.log(.warn, "stage copy: read '{s}' failed: {s}", .{ rel, @errorName(err) });
            return;
        };
        defer gpa.free(data);
        const dst = std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging, rel }) catch return;
        defer gpa.free(dst);
        const d = std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging, dirOf(rel) }) catch return;
        defer gpa.free(d);
        std.Io.Dir.cwd().createDirPath(io, d) catch |err| {
            log.log(.warn, "stage copy: mkdir '{s}' failed: {s}", .{ d, @errorName(err) });
        };
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = data }) catch |err| {
            log.log(.warn, "stage copy: write '{s}' failed: {s}", .{ dst, @errorName(err) });
        };
        return;
    }
    var dir = base.openDir(io, rel, .{ .iterate = true }) catch |err| {
        log.log(.warn, "stage copy: open dir '{s}' failed: {s}", .{ rel, @errorName(err) });
        return;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const sub = std.fmt.allocPrint(gpa, "{s}/{s}", .{ rel, entry.name }) catch continue;
        defer gpa.free(sub);
        switch (entry.kind) {
            .directory => try copyTreeInto(io, gpa, base, sub, staging),
            .file => {
                const data = dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 24)) catch |err| {
                    log.log(.warn, "stage copy: read '{s}' failed: {s}", .{ sub, @errorName(err) });
                    continue;
                };
                defer gpa.free(data);
                const dst = std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging, sub }) catch continue;
                defer gpa.free(dst);
                const d = std.fmt.allocPrint(gpa, "{s}", .{dirOf(dst)}) catch continue;
                defer gpa.free(d);
                std.Io.Dir.cwd().createDirPath(io, d) catch |err| {
                    log.log(.warn, "stage copy: mkdir '{s}' failed: {s}", .{ d, @errorName(err) });
                };
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = data }) catch |err| {
                    log.log(.warn, "stage copy: write '{s}' failed: {s}", .{ dst, @errorName(err) });
                };
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
    \\The context below is a byte-budgeted selection of a much larger tree, not
    \\all of it. When the file you need to read is not there — including anything
    \\listed as NOT INCLUDED — do not guess at its contents. Ask for it instead,
    \\with no "changes" key:
    \\{"need": ["src/cli.zig", "docs/ROADMAP.md"], "reason": "why you need them"}
    \\You will be asked again with those files added, and they stay for the rest
    \\of the run. Ask once for everything you need: the budget is a few requests
    \\per run, and a request that names a file you were already shown wastes one.
    \\Readable (wider than what you may write): src/, evals/, tools/, skills/,
    \\tests/, docs/, README.md, AGENTS.md, build.zig, build.zig.zon, config.toml.
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
/// The files the instruction names, kept in their own block so the cached bulk
/// survives a patch to them.
const improve_focus_fmt =
    \\# The files this instruction is about
    \\{s}
    \\
;

const improve_user_fmt =
    \\# Improvement instruction
    \\{s}
    \\
    \\# Current gate status
    \\{s}
    \\
    \\# Earlier runs on this repository
    \\Work listed as accepted is already in the source you were given: do not
    \\propose it again. Work listed as rejected failed for the stated reason;
    \\do not repeat that mistake.
    \\{s}
    \\
    \\# Previous attempt feedback
    \\{s}
    \\
    \\Produce the patch proposal JSON now. Your response must be ONLY the JSON
    \\object — no markdown fences, no prose.
;

test "parseFailedEvalNames extracts names from FAIL lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const output =
        \\calculator: 1.00 PASS
        \\lsp: 0.00 FAIL
        \\read_file: 0.00 FAIL
        \\search_code_symbol: 1.00 PASS
    ;
    const names = try parseFailedEvalNames(arena, output);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("lsp", names[0]);
    try std.testing.expectEqualStrings("read_file", names[1]);
}

test "parseFailedEvalNames returns empty on no FAIL lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const output =
        \\calculator: 1.00 PASS
        \\search_code_symbol: 1.00 PASS
    ;
    const names = try parseFailedEvalNames(arena, output);
    try std.testing.expectEqual(@as(usize, 0), names.len);
}

test "parseFailedEvalNames handles empty input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const names = try parseFailedEvalNames(arena, "");
    try std.testing.expectEqual(@as(usize, 0), names.len);
}

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

    const tail = try errorTail(arena, buf.items);
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
    const tail = try errorTail(arena, long);
    try std.testing.expectEqual(@as(usize, 1500), tail.len);
    try std.testing.expectEqual(@as(u8, 'Z'), tail[tail.len - 1]);
}

test "a granted file reaches the context, once, in the focus block" {
    // The whole point of the request round: docs/ is never collected, so
    // docs/ROADMAP.md cannot reach the model any other way — which is why
    // clanker-improve.sh pastes the planned items into the instruction by hand.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var ctx = client.Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };
    var cfg = config.Config{};
    var provider = try config.Provider.single(arena, "p", "http://localhost", .openai_compat, "m", .{});

    // Runs against the real tree from the repo root, so it needs docs/ to be
    // there; a checkout without it has nothing to assert about.
    std.Io.Dir.cwd().access(io, "docs/ROADMAP.md", .{}) catch return error.SkipZigTest;

    const budget: usize = 256 * 1024;
    const header = "===== FILE: docs/ROADMAP.md =====";

    {
        var hist = history_mod.History.init(std.testing.allocator, io, std.Io.Dir.cwd(), "state");
        defer hist.deinit();
        var engine = Engine{ .ctx = &ctx, .arena = arena, .provider = &provider, .cfg = &cfg, .hist = hist, .instructions = "" };
        const before = try engine.collectContext(budget);
        try std.testing.expect(std.mem.indexOf(u8, before.bulk, header) == null);
        try std.testing.expect(std.mem.indexOf(u8, before.focus, header) == null);
    }

    {
        var hist = history_mod.History.init(std.testing.allocator, io, std.Io.Dir.cwd(), "state");
        defer hist.deinit();
        var engine = Engine{
            .ctx = &ctx,
            .arena = arena,
            .provider = &provider,
            .cfg = &cfg,
            .hist = hist,
            .instructions = "",
            .granted = &.{"docs/ROADMAP.md"},
        };
        const after = try engine.collectContext(budget);

        // In the volatile half, so a promotion cannot invalidate the cached bulk.
        try std.testing.expect(std.mem.indexOf(u8, after.focus, header) != null);
        // And exactly once. A file in the focus block used to be emitted into
        // the bulk as well, which for a 310 KB file is 310 KB billed twice.
        try std.testing.expect(std.mem.indexOf(u8, after.bulk, header) == null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, after.focus, header));
    }
}

test "granting is bounded, refuses what does not exist, and does not double-count" {
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

    var missing: std.ArrayList([]const u8) = .empty;

    // A path that does not exist is refused, not granted: collectFile drops an
    // unreadable file with only a debug line, so granting one would look, from
    // the next prompt, exactly like a file that turned out to be empty.
    try std.testing.expectEqual(@as(usize, 0), try engine.grant(&.{"src/does_not_exist.zig"}, &missing));
    try std.testing.expectEqual(@as(usize, 1), missing.items.len);
    try std.testing.expectEqual(@as(usize, 0), engine.granted.len);

    try std.testing.expectEqual(@as(usize, 1), try engine.grant(&.{"build.zig"}, &missing));
    try std.testing.expectEqual(@as(usize, 1), engine.granted.len);

    // Asking again for something already granted adds nothing — which is what
    // makes the engine answer "you already have this" instead of looping.
    try std.testing.expectEqual(@as(usize, 0), try engine.grant(&.{"build.zig"}, &missing));
    try std.testing.expectEqual(@as(usize, 1), engine.granted.len);

    // A later round accumulates onto the earlier one rather than replacing it.
    try std.testing.expectEqual(@as(usize, 1), try engine.grant(&.{ "build.zig", "README.md" }, &missing));
    try std.testing.expectEqual(@as(usize, 2), engine.granted.len);
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

    // A small window keeps the floor; a large one is still capped rather than
    // billing the whole repository on every attempt.
    var small = try config.Provider.single(arena, "s", "http://x", .openai_compat, "m", .{ .context_window = 8192 });
    var engine = Engine{ .ctx = undefined, .arena = arena, .provider = &small, .cfg = &cfg, .hist = undefined, .instructions = "" };
    try std.testing.expectEqual(@as(usize, 64 * 1024), engine.contextBudget());

    var mid = try config.Provider.single(arena, "m", "http://x", .openai_compat, "m", .{ .context_window = 131072 });
    engine.provider = &mid;
    try std.testing.expectEqual(@as(usize, 131072), engine.contextBudget());

    var huge = try config.Provider.single(arena, "h", "http://x", .openai_compat, "m", .{ .context_window = 1_048_576 });
    engine.provider = &huge;
    try std.testing.expectEqual(@as(usize, 256 * 1024), engine.contextBudget());

    // The ceiling is a cost decision, not a capacity one. A million-token model
    // can hold the whole project, and sending it cost 345k prompt tokens and
    // 1.79 dollars per attempt, on every run, whether or not the instruction
    // had anything to do with the files being sent.
    //
    // Raising it to fit one large file is the wrong lever: a file the
    // instruction names bypasses the focus share entirely (see
    // collectContext), so tools/zig/webui/index.html at 133 KiB arrives whole
    // under this ceiling. Widening the ceiling instead makes every unrelated
    // run pay for it.
    try std.testing.expect(engine.contextBudget() <= 256 * 1024);
}

test "pruneStaging keeps the newest N and removes the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var ctx = client.Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create 5 fake staging dirs under a tmp "state/staging" with imp- ids.
    try tmp.dir.createDirPath(io, "state/staging/imp-100");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/staging/imp-100/file.txt", .data = "a" });
    try tmp.dir.createDirPath(io, "state/staging/imp-200");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/staging/imp-200/file.txt", .data = "b" });
    try tmp.dir.createDirPath(io, "state/staging/imp-300");
    try tmp.dir.createDirPath(io, "state/staging/imp-400");
    try tmp.dir.createDirPath(io, "state/staging/imp-500");
    // Also a non-imp directory that must be left alone.
    try tmp.dir.createDirPath(io, "state/staging/other-thing");

    // Build an engine that operates on the tmp dir. We only need the fields
    // pruneStaging touches: ctx (io + gpa).
    var cfg = config.Config{};
    var provider = try config.Provider.single(arena, "p", "http://localhost", .openai_compat, "m", .{});
    var engine = Engine{ .ctx = &ctx, .arena = arena, .provider = &provider, .cfg = &cfg, .hist = undefined, .instructions = "" };

    // pruneStaging works against cwd, but our dirs are in tmp. We cannot
    // change cwd in a test, so call the pieces that matter directly.
    // Instead, test isImpId and the sort/keep logic by checking the names.
    try std.testing.expect(Engine.isImpId("imp-100"));
    try std.testing.expect(Engine.isImpId("imp-99999999"));
    try std.testing.expect(!Engine.isImpId("imp-"));
    try std.testing.expect(!Engine.isImpId("other-thing"));
    try std.testing.expect(!Engine.isImpId("imp-abc"));

    // Simulate the pruning logic: list, sort, keep 3.
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| std.testing.allocator.free(n);
        names.deinit(std.testing.allocator);
    }
    var staging_dir = tmp.dir.openDir(io, "state/staging", .{ .iterate = true }) catch unreachable;
    defer staging_dir.close(io);
    var it = staging_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!Engine.isImpId(entry.name)) continue;
        try names.append(std.testing.allocator, try std.testing.allocator.dupe(u8, entry.name));
    }
    try std.testing.expectEqual(@as(usize, 5), names.items.len);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    // With keep=3, the first 2 (imp-100, imp-200) would be removed.
    const to_remove = names.items.len - 3;
    try std.testing.expectEqual(@as(usize, 2), to_remove);
    try std.testing.expectEqualStrings("imp-100", names.items[0]);
    try std.testing.expectEqualStrings("imp-200", names.items[1]);
    // The kept ones are the 3 newest.
    try std.testing.expectEqualStrings("imp-300", names.items[2]);
    try std.testing.expectEqualStrings("imp-400", names.items[3]);
    try std.testing.expectEqualStrings("imp-500", names.items[4]);

    // Actually remove them to verify removeTree works on the tmp dir.
    for (names.items[0..to_remove]) |name| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "state/staging/{s}", .{name});
        defer std.testing.allocator.free(path);
        // Use the engine's removeTree indirectly: it operates on cwd, but
        // we can verify the logic with manual deletion on tmp.dir.
        engine.removeTreeAt(tmp.dir, path);
    }
    // imp-100 should be gone (its file too).
    const absent = tmp.dir.readFileAlloc(io, "state/staging/imp-100/file.txt", std.testing.allocator, .limited(64));
    try std.testing.expectError(error.FileNotFound, absent);
    // imp-300 should still exist.
    try tmp.dir.access(io, "state/staging/imp-300", .{});
    // The non-imp directory is untouched.
    try tmp.dir.access(io, "state/staging/other-thing", .{});
}

test "a patch that drops a gate call from the engine is rejected before it compiles" {
    // The improvement machinery is modifiable, so the one thing that must not
    // be removable is the gating itself. This runs against the staged text,
    // which is the only place a patch exists before it is promoted.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var ctx = client.Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };
    var engine = Engine{
        .ctx = &ctx,
        .arena = arena,
        .provider = undefined,
        .cfg = undefined,
        .hist = undefined,
        .instructions = "",
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const staged = tmp.dir;
    try staged.createDirPath(io, "src/improve");

    // A file that still contains every load-bearing call passes.
    var keeps: std.ArrayList(u8) = .empty;
    for (gate_invariants) |inv| {
        try keeps.appendSlice(arena, inv.needle);
        try keeps.appendSlice(arena, "\n");
    }
    try staged.writeFile(io, .{ .sub_path = "src/improve/engine.zig", .data = keeps.items });
    const changes = [_]proposal_mod.Change{.{ .file = "src/improve/engine.zig", .old = "", .new = "" }};
    try std.testing.expect(try engine.brokenInvariant(staged, &changes) == null);

    // Drop one call and it is named.
    const dropped = try std.mem.replaceOwned(u8, arena, keeps.items, "self.capabilityGate(", "");
    try staged.writeFile(io, .{ .sub_path = "src/improve/engine.zig", .data = dropped });
    const bad = try engine.brokenInvariant(staged, &changes) orelse return error.TestExpectedRejection;
    try std.testing.expectEqualStrings("self.capabilityGate(", bad.needle);

    // A proposal that does not touch the file is not checked against it: the
    // rest of the tree is a verbatim copy where these already hold.
    const elsewhere = [_]proposal_mod.Change{.{ .file = "src/cli.zig", .old = "", .new = "" }};
    try std.testing.expect(try engine.brokenInvariant(staged, &elsewhere) == null);
}

test "a patch that guts a gate implementation in checks.zig is rejected too" {
    // checks.zig is deliberately outside the protected surface, so a
    // proposal can legitimately touch it -- but not by deleting the exit
    // code check every gate shares.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var ctx = client.Ctx{ .io = io, .gpa = std.testing.allocator, .environ_map = &env };
    var engine = Engine{
        .ctx = &ctx,
        .arena = arena,
        .provider = undefined,
        .cfg = undefined,
        .hist = undefined,
        .instructions = "",
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const staged = tmp.dir;
    try staged.createDirPath(io, "src/gate");

    var keeps: std.ArrayList(u8) = .empty;
    for (gate_invariants) |inv| {
        if (!std.mem.eql(u8, inv.file, "src/gate/checks.zig")) continue;
        try keeps.appendSlice(arena, inv.needle);
        try keeps.appendSlice(arena, "\n");
    }
    try staged.writeFile(io, .{ .sub_path = "src/gate/checks.zig", .data = keeps.items });
    const changes = [_]proposal_mod.Change{.{ .file = "src/gate/checks.zig", .old = "", .new = "" }};
    try std.testing.expect(try engine.brokenInvariant(staged, &changes) == null);

    // Drop the exit-code check -- the shared piece that decides pass/fail
    // for build, test, and tools gates alike -- and it is caught.
    const gutted = try std.mem.replaceOwned(u8, arena, keeps.items, ".exited => |c| c == 0,", "");
    try staged.writeFile(io, .{ .sub_path = "src/gate/checks.zig", .data = gutted });
    const bad = try engine.brokenInvariant(staged, &changes) orelse return error.TestExpectedRejection;
    try std.testing.expectEqualStrings(".exited => |c| c == 0,", bad.needle);
}

test "the staging remover refuses any path that is not a staging directory" {
    // removeTree deletes a tree recursively. The only thing standing between
    // that and the working tree is this predicate.
    try std.testing.expect(Engine.isStagingDirPath("state/staging/imp-1786415790081955962"));
    try std.testing.expect(!Engine.isStagingDirPath("state/staging"));
    try std.testing.expect(!Engine.isStagingDirPath("state/staging/"));
    try std.testing.expect(!Engine.isStagingDirPath("state/staging/imp-123/src"));
    try std.testing.expect(!Engine.isStagingDirPath("state/staging/../.."));
    try std.testing.expect(!Engine.isStagingDirPath("state/staging/notanid"));
    try std.testing.expect(!Engine.isStagingDirPath("src"));
    try std.testing.expect(!Engine.isStagingDirPath("/"));
    try std.testing.expect(!Engine.isStagingDirPath(""));
}

test "a compile error's std references reduce to the symbol worth looking up" {
    // The engine hands the model a signature it cannot look up itself. Picking
    // the wrong component would look it up in the wrong place and quietly
    // teach nothing.
    const err =
        \\src/util/flock.zig:30:48: error: expected enum or tagged union, found 'comptime_int'
        \\        fl.whence = @intFromEnum(std.posix.SEEK.SET);
    ;
    const first = nextStdSymbol(err) orelse return error.TestExpectedSymbol;
    try std.testing.expectEqualStrings("SET", first.sym);
    try std.testing.expect(nextStdSymbol(first.rest) == null);

    // A bare path yields its own last component.
    const two = nextStdSymbol("std.mem.splitScalar is gone") orelse return error.TestExpectedSymbol;
    try std.testing.expectEqualStrings("splitScalar", two.sym);

    // Trailing punctuation is not part of the name.
    const three = nextStdSymbol("use std.Io.Writer.") orelse return error.TestExpectedSymbol;
    try std.testing.expectEqualStrings("Writer", three.sym);

    // Nothing to look up.
    try std.testing.expect(nextStdSymbol("no standard library here") == null);
    try std.testing.expect(nextStdSymbol("std.x") == null);
}

test "the type a compiler note names is looked up too" {
    // The source line says what was called; the note underneath says what the
    // compiler actually wanted, and only the note carries the type whose
    // members are the answer.
    const note = "error: expected type 'os.linux.SIG__enum_1935', found 'comptime_int'";
    const t = nextQuotedType(note) orelse return error.TestExpectedSymbol;
    try std.testing.expectEqualStrings("SIG", t.sym);

    const missing = "enum 'os.linux.SIG__enum_1935' has no member named 'none'";
    const m = nextQuotedType(missing) orelse return error.TestExpectedSymbol;
    try std.testing.expectEqualStrings("SIG", m.sym);
    // 'none' is a member name, not a type: no dot, so it is not looked up.
    try std.testing.expect(nextQuotedType(m.rest) == null);

    // Prose in quotes is not a type.
    try std.testing.expect(nextQuotedType("call it 'the thing that failed'") == null);

    // Both shapes in one message are found by the combined scan.
    const both =
        \\        fl.whence = @intFromEnum(std.posix.SEEK.SET);
        \\note: expected type 'os.linux.SIG__enum_1935'
    ;
    const first = nextSymbol(both) orelse return error.TestExpectedSymbol;
    const second = nextSymbol(first.rest) orelse return error.TestExpectedSymbol;
    try std.testing.expectEqualStrings("SET", first.sym);
    try std.testing.expectEqualStrings("SIG", second.sym);
}

test "a compile error about a std signature comes back with the declaration" {
    // The whole point of this help is the case that kept repeating: a signal
    // passed as an integer where SIG is an enum, five runs in a row.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var ctx = client.Ctx{ .io = threaded.io(), .gpa = std.testing.allocator, .environ_map = &env };
    var engine = Engine{
        .ctx = &ctx,
        .arena = arena,
        .provider = undefined,
        .cfg = undefined,
        .hist = undefined,
        .instructions = "",
    };

    // Without a lib dir there is nothing to read, and saying so beats a
    // confusing empty result.
    const saved = sandbox_host.zig_lib_dir;
    defer sandbox_host.zig_lib_dir = saved;
    if (saved.len == 0) return error.SkipZigTest;

    const err = try std.fmt.allocPrint(arena,
        \\src/util/pidlock.zig:72:39: error: expected type 'os.linux.SIG__enum_1935', found 'comptime_int'
        \\    const rc = std.os.linux.kill(pid, 0);
        \\{s}/std/os/linux.zig:4036:8: note: enum declared here
    , .{saved});

    const help = engine.stdSymbolHelp(err);
    try std.testing.expect(help.len > 0);
    // The declaration the compiler pointed at, not a guess at which SIG.
    try std.testing.expect(std.mem.indexOf(u8, help, "os/linux.zig") != null);
}
