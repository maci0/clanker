//! The self-improvement engine: clanker improving its own source code.
//!
//! Loop (per iteration, with retries):
//!   1. assemble the modifiable source tree as context for the model,
//!   2. ask the model for an exact-match patch proposal (JSON),
//!   3. validate the proposal (paths/sizes),
//!   4. apply it to a staging copy of the project,
//!   5. gate: `zig build` + `zig build test` + `zig build tools` in staging,
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
const log = @import("../util/log.zig");

pub const Options = struct {
    instructions: []const u8,
    iters: u32 = 3,
    max_attempts_per_iter: u32 = 2,
    dry_run: bool = false,
    max_context_bytes: usize = 64 * 1024,
    max_changes: usize = 40,
    max_change_bytes: usize = 32 * 1024,
    response_tokens: u32 = 16384,
};

/// Directories/files copied into staging for the compile gate. Must be enough
/// for `zig build` + `zig build test` + `zig build tools` to succeed.
const staging_roots = [_][]const u8{ "src", "tools-src", "tests", "tools-as", "build.zig", "build.zig.zon", "config.json" };

const gate_evals = [_][]const u8{ "selfhost_build", "selfhost_tests", "selfhost_tools" };

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
        const context = try self.collectContext(opts.max_context_bytes);
        const gate_tail = try self.gateErrorTail();
        const user_prompt = try std.fmt.allocPrint(self.arena, improve_user_fmt, .{
            opts.instructions,
            gate_tail,
            context,
            last_error orelse "none",
        });

        log.log(.info, "iteration attempt {d}: asking model for a proposal ({d} bytes context)", .{ attempt, context.len });

        // ---- 2. proposal from the model ----
        const messages = [_]types.Message{
            .{ .role = .system, .content = improve_system },
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
            feedback = try std.fmt.allocPrint(self.arena, "Your previous response was not a valid patch proposal: {s}. Respond with ONLY the JSON object described above — nothing else.", .{@errorName(err)});
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

        applyChanges(self.ctx.io, self.ctx.gpa, staged_dir, proposal.changes) catch |err| {
            log.log(.error_, "applying patch failed: {s}", .{@errorName(err)});
            return .failed;
        };

        // ---- 5. gate ----
        log.log(.info, "gating in {s} ...", .{staging});
        var build = try builder.buildGate(self.ctx.gpa, self.ctx.io, staged_dir, &.{});
        defer build.deinit(self.ctx.gpa);
        if (!build.ok) {
            const tail = errorTail(self.arena, build.stderr);
            log.log(.error_, "staging build failed:", .{});
            log.log(.error_, "{s}", .{tail});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, changedPaths(self.ctx.gpa, proposal.changes), 0, 0, tail);
            return .failed;
        }

        var test_gate = try builder.testGate(self.ctx.gpa, self.ctx.io, staged_dir);
        defer test_gate.deinit(self.ctx.gpa);
        if (!test_gate.ok) {
            const tail = errorTail(self.arena, test_gate.stderr);
            log.log(.error_, "staging tests failed:", .{});
            log.log(.error_, "{s}", .{tail});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, changedPaths(self.ctx.gpa, proposal.changes), 0, 0, tail);
            return .failed;
        }

        var tools = try builder.buildGate(self.ctx.gpa, self.ctx.io, staged_dir, &.{"tools"});
        defer tools.deinit(self.ctx.gpa);
        if (!tools.ok) {
            const tail = errorTail(self.arena, tools.stderr);
            log.log(.error_, "staging tools build failed:", .{});
            log.log(.error_, "{s}", .{tail});
            try self.hist.append(id, .failed, opts.instructions, proposal.summary, changedPaths(self.ctx.gpa, proposal.changes), 0, 0, tail);
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
            try std.Io.Dir.cwd().writeFile(self.ctx.io, .{ .sub_path = c.file, .data = data });
        }

        // Post-promotion gate on the live tree.
        const live = try self.gateScore();
        const score_after = live.score / @as(f64, @floatFromInt(@max(live.total, 1)));
        try self.hist.append(id, .accepted, opts.instructions, proposal.summary, files, 0, score_after, "");

        log.log(.info, "✓ promoted improvement {s} (gate {d:.2}/{d})", .{ id, live.score, live.total });
        return .accepted;
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
            .selfhost_build => try builder.buildGate(self.ctx.gpa, self.ctx.io, dir, &.{}),
            .selfhost_tests => try builder.testGate(self.ctx.gpa, self.ctx.io, dir),
            .selfhost_tools => try builder.buildGate(self.ctx.gpa, self.ctx.io, dir, &.{"tools"}),
            else => return error.NotAGateEval,
        };
        defer g.deinit(self.ctx.gpa);
        const detail = if (g.ok) "" else errorTail(self.arena, g.stderr);
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

    fn collectContext(self: *Engine, max_bytes: usize) ![]const u8 {
        const instructions = self.instructions;
        var keywords: std.ArrayList([]const u8) = .empty;
        var kw_it = std.mem.tokenizeAny(u8, instructions, " \n\r\t,.;:'\"()[]{}");
        while (kw_it.next()) |w| {
            if (w.len >= 5 and !isStopword(w)) try keywords.append(self.arena, w);
        }

        // Gather candidate files with a relevance score (keyword hits).
        var cands: std.ArrayList(Candidate) = .empty;
        try collectCandidates(self, "tools-src", keywords.items, &cands, 96 * 1024);
        try collectCandidates(self, "src", keywords.items, &cands, 96 * 1024);
        try collectCandidates(self, "tests", keywords.items, &cands, 96 * 1024);
        for ([_][]const u8{ "build.zig", "build.zig.zon", "config.json" }) |f| {
            try collectFile(self, f, keywords.items, &cands);
        }
        std.mem.sort(Candidate, cands.items, {}, struct {
            fn lt(_: void, a: Candidate, b: Candidate) bool {
                return a.score > b.score;
            }
        }.lt);

        var buf: std.ArrayList(u8) = .empty;
        var included_any = false;
        for (cands.items) |c| {
            // Keep the context tight: only include files that matched the
            // instruction keywords (plus always build.zig / config.json), so
            // the model cannot lose track of which file has what.
            const always = std.mem.eql(u8, c.path, "build.zig") or std.mem.eql(u8, c.path, "config.json") or std.mem.eql(u8, c.path, "build.zig.zon");
            if (c.score == 0 and !always) continue;
            included_any = true;
            if (buf.items.len >= max_bytes) break;
            const header = try std.fmt.allocPrint(self.arena, "\n===== FILE: {s} =====\n", .{c.path});
            const remaining = max_bytes - buf.items.len;
            const take_header = @min(header.len, remaining);
            const take_data = @min(c.data.len, remaining - take_header);
            try buf.appendSlice(self.arena, header[0..take_header]);
            try buf.appendSlice(self.arena, c.data[0..take_data]);
        }
        if (!included_any) {
            // No keyword matches — fall back to the top candidates by score.
            for (cands.items) |c| {
                if (buf.items.len >= max_bytes) break;
                const header = try std.fmt.allocPrint(self.arena, "\n===== FILE: {s} =====\n", .{c.path});
                const remaining = max_bytes - buf.items.len;
                const take_header = @min(header.len, remaining);
                const take_data = @min(c.data.len, remaining - take_header);
                try buf.appendSlice(self.arena, header[0..take_header]);
                try buf.appendSlice(self.arena, c.data[0..take_data]);
            }
        }
        if (buf.items.len == 0) return "(no source files found)";
        log.log(.debug, "context: {d} files, {d} bytes", .{ cands.items.len, buf.items.len });
        return buf.toOwnedSlice(self.arena);
    }

    fn collectFile(self: *Engine, rel: []const u8, keywords: []const []const u8, cands: *std.ArrayList(Candidate)) !void {
        const data = std.Io.Dir.cwd().readFileAlloc(self.ctx.io, rel, self.arena, .limited(96 * 1024)) catch return;
        var score: usize = 0;
        for (keywords) |kw| {
            if (std.mem.indexOf(u8, data, kw) != null) score += 1;
        }
        if (std.mem.indexOf(u8, rel, "calculator") != null and std.mem.indexOf(u8, rel, "src") == null) score += 2;
        try cands.append(self.arena, .{ .path = try self.arena.dupe(u8, rel), .score = score, .data = data });
    }

    fn collectCandidates(self: *Engine, dir_rel: []const u8, keywords: []const []const u8, cands: *std.ArrayList(Candidate), file_cap: usize) !void {
        var dir = std.Io.Dir.cwd().openDir(self.ctx.io, dir_rel, .{ .iterate = true }) catch return;
        defer dir.close(self.ctx.io);
        var it = dir.iterate();
        while (it.next(self.ctx.io) catch null) |entry| {
            switch (entry.kind) {
                .directory => {
                    const sub = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ dir_rel, entry.name });
                    try self.collectCandidates(sub, keywords, cands, file_cap);
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

    const Candidate = struct { path: []const u8, score: usize, data: []const u8 };

    fn isStopword(w: []const u8) bool {
        const stopwords = [_][]const u8{
            "make", "tool", "accept", "single", "string", "input", "like", "with",
            "addition", "existing", "fields", "evaluating", "using", "these", "those",
            "other", "should", "could", "would", "value", "number", "first", "second",
            "change", "changes", "feature", "implement", "support", "please", "need",
            "needs", "make", "also", "into",
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

fn changedPaths(gpa: std.mem.Allocator, changes: []const proposal_mod.Change) [][]const u8 {
    _ = gpa;
    const out = std.heap.page_allocator.alloc([]const u8, changes.len) catch unreachable;
    for (changes, 0..) |c, i| out[i] = c.file;
    return out;
}

fn applyChanges(io: std.Io, gpa: std.mem.Allocator, base: std.Io.Dir, changes: []const proposal_mod.Change) !void {
    for (changes) |c| {
        const current = base.readFileAlloc(io, c.file, gpa, .limited(1 << 24)) catch |err| {
            log.log(.error_, "cannot read '{s}' for patching: {s}", .{ c.file, @errorName(err) });
            return err;
        };
        defer gpa.free(current);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        if (c.old.len == 0) {
            try out.appendSlice(gpa, current);
            try out.appendSlice(gpa, c.new);
        } else {
            const idx = std.mem.indexOf(u8, current, c.old) orelse {
                log.log(.error_, "old text not found in '{s}'", .{c.file});
                return error.OldTextNotFound;
            };
            try out.appendSlice(gpa, current[0..idx]);
            try out.appendSlice(gpa, c.new);
            try out.appendSlice(gpa, current[idx + c.old.len ..]);
        }
        try base.writeFile(io, .{ .sub_path = c.file, .data = out.items });
    }
}

fn errorTail(arena: std.mem.Allocator, s: []const u8) []const u8 {
    if (s.len <= 1500) return s;
    return arena.dupe(u8, s[s.len - 1500 ..]) catch s[s.len - 1500 ..];
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
    \\      "new": "replacement text"
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

const improve_user_fmt =
    \\# Improvement instruction
    \\{s}
    \\
    \\# Current gate status
    \\{s}
    \\
    \\# Modifiable source context
    \\{s}
    \\
    \\# Previous attempt feedback
    \\{s}
    \\
    \\Produce the patch proposal JSON now. Your response must be ONLY the JSON
    \\object — no markdown fences, no prose.
;
