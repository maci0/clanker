//! goal_write: turn a rough natural-language intent into a structured goal
//! draft without consulting a model. Draft-only:
//!
//!   * inspects the workspace first (reads state/goals.json for an already-open
//!     goal covering the intent, and reports it instead of drafting a dup);
//!   * asks only the material (open) forks, 1..4 concrete questions, routed to
//!     the human (or the parent agent in a sub-agent run) via the `ask_user`
//!     tool; when nobody is reachable it records assumptions instead;
//!   * returns BOTH a machine-readable structured record and a readable
//!     markdown rendering of the draft.
//!
//! It never persists: state/goals.json is left byte-identical, no run is
//! started, `goal` is never called. Handing the draft to `goal` is a separate,
//! user-visible step.
//!
//! Input:  {"intent":"...","max_questions":1..4,"parent":bool}
//! Output: {"ok":true,"duplicate":bool,"existing_goal_id":?str,
//!          "record":{...},"markdown":"...","questions_asked":n}
const std = @import("std");
const lib = @import("lib.zig");

// Pure draft logic, folded into this guest so it needs no build.zig
// registration and no cross-module import. Owns two of the four workflow
// steps: deciding which forks the intent answers, and assembling the Draft.
const draft = struct {
    pub const Field = enum {
        objective,
        completion_criterion,
        proof,
        boundaries,
        stop_rule,
    };

    /// One fork the intent left open, phrased as a question a human can answer.
    pub const Question = struct {
        field: Field,
        prompt: []const u8,
        options: []const []const u8,
    };

    /// The assembled draft. `intent` is the raw ask; the five fields are the
    /// reviewable handoff; `assumptions` and `unresolved` record what was filled
    /// by default (headless or over-budget) so nothing is silently invented.
    pub const Draft = struct {
        intent: []const u8,
        objective: []const u8,
        completion_criterion: []const u8,
        proof: []const u8,
        boundaries: []const u8,
        stop_rule: []const u8,
        assumptions: []const []const u8 = &.{},
        unresolved: []const []const u8 = &.{},
    };

    /// Whether the intent text already answers a given fork, by keyword.
    pub fn intentAnswers(field: Field, intent: []const u8) bool {
        return switch (field) {
            .objective => objectiveHint(intent),
            .completion_criterion => criterionHint(intent),
            .proof => criterionHint(intent), // proof is usually stated with the criterion
            .boundaries => boundariesHint(intent),
            .stop_rule => stopHint(intent),
        };
    }

    fn objectiveHint(hay: []const u8) bool {
        const markers = [_][]const u8{ " exists", " survives", " is ", " stays", " remains", " will ", " must " };
        for (markers) |m| if (containsFold(hay, m)) return true;
        return false;
    }

    fn criterionHint(hay: []const u8) bool {
        const markers = [_][]const u8{ "eval", "test", "criterion", " pass", " check", " gate", "verified", "verifiable" };
        for (markers) |m| if (containsFold(hay, m)) return true;
        return false;
    }

    fn boundariesHint(hay: []const u8) bool {
        const markers = [_][]const u8{ "without ", "don't change", "do not change", "preserve", "keep ", "not touch", "leave ", "untouched", "except ", "out of scope" };
        for (markers) |m| if (containsFold(hay, m)) return true;
        return false;
    }

    fn stopHint(hay: []const u8) bool {
        const markers = [_][]const u8{ "stop", "revert", "budget", "cap", "limit", "iterations", "rounds", "max " };
        for (markers) |m| if (containsFold(hay, m)) return true;
        return false;
    }

    /// Case-insensitive substring search — no copy, so no stack slice escapes.
    fn containsFold(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0 or needle.len > haystack.len) return false;
        const last = haystack.len - needle.len;
        var i: usize = 0;
        while (i <= last) : (i += 1) {
            var matched = true;
            for (needle, 0..) |n, j| {
                if (std.ascii.toLower(haystack[i + j]) != n) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    /// The ordered candidate questions. Order matters: criterion and objective
    /// are the only two required fields, so they rank first; proof and stop_rule
    /// are optional and rank last.
    pub const candidate_questions = [_]Question{
        .{
            .field = .completion_criterion,
            .prompt = "How will someone independently tell this is done?",
            .options = &.{ "A command that must pass", "A file that must exist", "An eval that must pass", "Reviewer judgment on the stated criterion" },
        },
        .{
            .field = .objective,
            .prompt = "Is the intent already a well-formed objective, or should it be rephrased?",
            .options = &.{ "Keep the intent verbatim as the objective", "Rephrase it as an outcome statement" },
        },
        .{
            .field = .boundaries,
            .prompt = "What stays untouched?",
            .options = &.{ "Nothing — do everything in scope", "Leave existing behaviour alone", "Do not touch a specific area (I'll say which)", "Keep the change additive" },
        },
        .{
            .field = .proof,
            .prompt = "What artifact demonstrates completion?",
            .options = &.{ "A command and its expected output", "A file that must exist", "An eval that must pass", "No artifact — the criterion is the proof" },
        },
        .{
            .field = .stop_rule,
            .prompt = "When should the attempt stop rather than keep spending?",
            .options = &.{ "When a gate fails", "After a fixed number of iterations", "When the criterion is met", "No cap — run to completion" },
        },
    };

    /// The questions to actually ask: the material (open) forks, in order,
    /// capped at `max`. The owned slice is allocated from `alloc`.
    pub fn chooseQuestions(alloc: std.mem.Allocator, intent: []const u8, max: usize) []const Question {
        var count: usize = 0;
        for (candidate_questions) |q| {
            if (!intentAnswers(q.field, intent)) count += 1;
        }
        const n = @min(count, max);
        var result: [candidate_questions.len]Question = undefined;
        var i: usize = 0;
        for (candidate_questions) |q| {
            if (i >= n) break;
            if (intentAnswers(q.field, intent)) continue;
            result[i] = q;
            i += 1;
        }
        const owned = alloc.alloc(Question, i) catch return &.{};
        @memcpy(owned, result[0..i]);
        return owned;
    }

    /// A default value for a fork the intent left open and nobody answered.
    pub fn defaultFor(comptime field: Field) []const u8 {
        return switch (field) {
            .objective => "TBD — restate the intent as an outcome.",
            .completion_criterion => "TBD — the intent did not state how completion is judged; revisit before persisting.",
            .proof => "TBD — no proof artifact was specified.",
            .boundaries => "None stated; assume the change is scoped to the intent.",
            .stop_rule => "None specified; stop when a gate fails or the criterion is met.",
        };
    }

    pub fn fieldName(comptime field: Field) []const u8 {
        return switch (field) {
            .objective => "objective",
            .completion_criterion => "completion_criterion",
            .proof => "proof",
            .boundaries => "boundaries",
            .stop_rule => "stop_rule",
        };
    }

    /// Render the draft as a human-reviewable markdown block.
    pub fn renderMarkdown(alloc: std.mem.Allocator, d: *const Draft) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        try out.appendSlice(alloc, "Goal draft\n\n");
        const pairs = [_]struct { name: []const u8, val: []const u8 }{
            .{ .name = "objective", .val = d.objective },
            .{ .name = "completion_criterion", .val = d.completion_criterion },
            .{ .name = "proof", .val = d.proof },
            .{ .name = "boundaries", .val = d.boundaries },
            .{ .name = "stop_rule", .val = d.stop_rule },
        };
        for (pairs) |p| {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "- **{s}:** {s}\n", .{ p.name, p.val }));
        }
        if (d.assumptions.len > 0) {
            try out.appendSlice(alloc, "\n**Assumed** (no human answer):\n");
            for (d.assumptions) |a| try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "- {s}\n", .{a}));
        }
        if (d.unresolved.len > 0) {
            try out.appendSlice(alloc, "\n**Still open:**\n");
            for (d.unresolved) |u| try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "- {s}\n", .{u}));
        }
        return out.toOwnedSlice(alloc);
    }

    test "intent that states boundaries and a criterion answers those forks" {
        const intent = "Make runs survive a restart without changing the prompt format, verified by the e2e restart test";
        try std.testing.expect(intentAnswers(.objective, intent));
        try std.testing.expect(intentAnswers(.completion_criterion, intent));
        try std.testing.expect(intentAnswers(.proof, intent));
        try std.testing.expect(intentAnswers(.boundaries, intent));
        try std.testing.expect(!intentAnswers(.stop_rule, intent));
    }

    test "vague intent leaves all five forks open" {
        const intent = "improve the repl";
        for (candidate_questions) |q| {
            try std.testing.expect(!intentAnswers(q.field, intent));
        }
    }

    test "chooseQuestions caps and keeps candidate order" {
        const intent = "improve the repl";
        const two = chooseQuestions(std.testing.allocator, intent, 2);
        defer std.testing.allocator.free(two);
        try std.testing.expect(two.len == 2);
        try std.testing.expect(two[0].field == .completion_criterion);
    }

    test "markdown renders all five fields plus assumptions" {
        var d = Draft{
            .intent = "x",
            .objective = "o",
            .completion_criterion = "c",
            .proof = "p",
            .boundaries = "b",
            .stop_rule = "s",
            .assumptions = &.{"assumed default"},
        };
        const md = try renderMarkdown(std.testing.allocator, &d);
        defer std.testing.allocator.free(md);
        try std.testing.expect(std.mem.find(u8, md, "**objective:**") != null);
        try std.testing.expect(std.mem.find(u8, md, "**stop_rule:**") != null);
        try std.testing.expect(std.mem.find(u8, md, "assumed default") != null);
    }
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

const field_count = 5;
const fields = [_]draft.Field{
    .objective,
    .completion_criterion,
    .proof,
    .boundaries,
    .stop_rule,
};

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const v = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const intent = lib.str(v, "intent") catch return lib.fail(out, "missing required string field: intent");
    const max_q: usize = blk: {
        const n = lib.optNum(v, "max_questions") orelse 4.0;
        const m: u32 = @trunc(n);
        break :blk if (m > 4) 4 else m;
    };
    const to_parent = lib.optBool(v, "parent", false);

    // 1. Inspect the workspace for an already-open goal covering the intent.
    if (duplicateGoalId(intent)) |gid| {
        var w = lib.writer(out);
        var s = lib.json(&w);
        s.beginObject() catch return lib.fail(out, "emit");
        s.objectField("ok") catch return lib.fail(out, "emit");
        s.write(true) catch return lib.fail(out, "emit");
        s.objectField("duplicate") catch return lib.fail(out, "emit");
        s.write(true) catch return lib.fail(out, "emit");
        s.objectField("existing_goal_id") catch return lib.fail(out, "emit");
        s.write(gid) catch return lib.fail(out, "emit");
        s.objectField("markdown") catch return lib.fail(out, "emit");
        s.write(
            \\## Already covered
            \\
            \\An open goal already covers this intent:
            \\
            \\`{gid}`
            \\
            \\Review that goal instead of drafting a duplicate; extend it if the
            \\intent is narrower than what it already holds.
        ) catch return lib.fail(out, "emit");
        s.endObject() catch return lib.fail(out, "emit");
        lib.commit(out, &w);
        return;
    }

    // 2. The material (open) forks, capped at the budget.
    const qs = draft.chooseQuestions(lib.alloc, intent, max_q);

    // 3. Interview up to the budget. A failed ask (nobody reachable) is
    //    headless: stop asking and record assumptions instead.
    var answers: [field_count]?[]const u8 = .{null} ** field_count;
    var questions_asked: usize = 0;
    for (qs) |q| {
        const reply = askOne(q.prompt, q.options, to_parent) orelse break;
        answers[@intFromEnum(q.field)] = reply;
        questions_asked += 1;
    }

    // 4. Assemble the Draft: answered > covered-by-intent > default + open.
    const d = assemble(lib.alloc, intent, &answers);

    // 5. Readable markdown rendering.
    const md = draft.renderMarkdown(lib.alloc, &d) catch
        return lib.fail(out, "could not render draft");

    // 6. Emit the dual record.
    try emit(out, d, md, questions_asked);
}

fn askOne(question: []const u8, options: []const []const u8, to_parent: bool) ?[]const u8 {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    s.beginObject() catch return null;
    s.objectField("question") catch return null;
    s.write(question) catch return null;
    s.objectField("options") catch return null;
    s.beginArray() catch return null;
    for (options) |o| s.write(o) catch return null;
    s.endArray() catch return null;
    if (to_parent) {
        s.objectField("parent") catch return null;
        s.write(true) catch return null;
    }
    s.endObject() catch return null;

    const raw = lib.toolCall("ask_user", buf[0..w.end]) catch return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch return null;
    if (v != .object) return null;
    return lib.optStr(v, "answer");
}

fn assemble(alloc: std.mem.Allocator, intent: []const u8, answers: *const [field_count]?[]const u8) draft.Draft {
    var vals: [field_count][]const u8 = undefined;
    var open: [field_count][]const u8 = undefined;
    var n_open: usize = 0;

    inline for (fields) |f| {
        const idx = @intFromEnum(f);
        if (answers[idx]) |a| {
            vals[idx] = a;
        } else if (draft.intentAnswers(f, intent)) {
            // The intent itself already covers this fork; keep it verbatim.
            vals[idx] = intent;
        } else {
            // Open and unanswered: default it, but say so — never silently
            // invent. It stays on the unresolved list for the review step.
            vals[idx] = draft.defaultFor(f);
            open[n_open] = draft.fieldName(f);
            n_open += 1;
        }
    }

    // Copy the open field names into owned arena slices so they outlive this
    // frame — never point the returned Draft at stack arrays.
    const assumptions = alloc.alloc([]const u8, n_open) catch return emptyDraft(intent, vals);
    const unresolved = alloc.alloc([]const u8, n_open) catch return emptyDraft(intent, vals);
    @memcpy(assumptions, open[0..n_open]);
    @memcpy(unresolved, open[0..n_open]);

    return .{
        .intent = intent,
        .objective = vals[@intFromEnum(draft.Field.objective)],
        .completion_criterion = vals[@intFromEnum(draft.Field.completion_criterion)],
        .proof = vals[@intFromEnum(draft.Field.proof)],
        .boundaries = vals[@intFromEnum(draft.Field.boundaries)],
        .stop_rule = vals[@intFromEnum(draft.Field.stop_rule)],
        .assumptions = assumptions,
        .unresolved = unresolved,
    };
}

/// On OOM, return the five fields filled with no open/assumption lists.
fn emptyDraft(intent: []const u8, vals: [field_count][]const u8) draft.Draft {
    return .{
        .intent = intent,
        .objective = vals[@intFromEnum(draft.Field.objective)],
        .completion_criterion = vals[@intFromEnum(draft.Field.completion_criterion)],
        .proof = vals[@intFromEnum(draft.Field.proof)],
        .boundaries = vals[@intFromEnum(draft.Field.boundaries)],
        .stop_rule = vals[@intFromEnum(draft.Field.stop_rule)],
        .assumptions = &.{},
        .unresolved = &.{},
    };
}

fn emit(out: *lib.Out, d: draft.Draft, md: []const u8, questions_asked: usize) !void {
    var w = lib.writer(out);
    var s = lib.json(&w);
    s.beginObject() catch return lib.fail(out, "emit");
    s.objectField("ok") catch return lib.fail(out, "emit");
    s.write(true) catch return lib.fail(out, "emit");
    s.objectField("duplicate") catch return lib.fail(out, "emit");
    s.write(false) catch return lib.fail(out, "emit");
    s.objectField("questions_asked") catch return lib.fail(out, "emit");
    s.write(@as(u64, questions_asked)) catch return lib.fail(out, "emit");

    s.objectField("record") catch return lib.fail(out, "emit");
    s.beginObject() catch return lib.fail(out, "emit");
    s.objectField("intent") catch return lib.fail(out, "emit");
    s.write(d.intent) catch return lib.fail(out, "emit");
    s.objectField("objective") catch return lib.fail(out, "emit");
    s.write(d.objective) catch return lib.fail(out, "emit");
    s.objectField("completion_criteria") catch return lib.fail(out, "emit");
    s.beginArray() catch return lib.fail(out, "emit");
    s.write(d.completion_criterion) catch return lib.fail(out, "emit");
    s.endArray() catch return lib.fail(out, "emit");
    s.objectField("verification") catch return lib.fail(out, "emit");
    s.beginArray() catch return lib.fail(out, "emit");
    s.write(d.proof) catch return lib.fail(out, "emit");
    s.endArray() catch return lib.fail(out, "emit");
    s.objectField("boundaries") catch return lib.fail(out, "emit");
    s.beginArray() catch return lib.fail(out, "emit");
    s.write(d.boundaries) catch return lib.fail(out, "emit");
    s.endArray() catch return lib.fail(out, "emit");
    s.objectField("execution_loop") catch return lib.fail(out, "emit");
    s.write(
        "Iterate on the objective until the completion criterion is met; stop per the stop rule.",
    ) catch return lib.fail(out, "emit");
    s.objectField("stop_rules") catch return lib.fail(out, "emit");
    s.beginArray() catch return lib.fail(out, "emit");
    s.write(d.stop_rule) catch return lib.fail(out, "emit");
    s.endArray() catch return lib.fail(out, "emit");
    s.objectField("assumptions") catch return lib.fail(out, "emit");
    s.beginArray() catch return lib.fail(out, "emit");
    for (d.assumptions) |a| s.write(a) catch return lib.fail(out, "emit");
    s.endArray() catch return lib.fail(out, "emit");
    s.objectField("unresolved_questions") catch return lib.fail(out, "emit");
    s.beginArray() catch return lib.fail(out, "emit");
    for (d.unresolved) |u| s.write(u) catch return lib.fail(out, "emit");
    s.endArray() catch return lib.fail(out, "emit");
    s.endObject() catch return lib.fail(out, "emit");

    s.objectField("markdown") catch return lib.fail(out, "emit");
    s.write(md) catch return lib.fail(out, "emit");
    s.endObject() catch return lib.fail(out, "emit");
    lib.commit(out, &w);
}

fn duplicateGoalId(intent: []const u8) ?[]const u8 {
    const raw = lib.fsRead("state/goals.json") catch return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, raw, .{}) catch return null;
    if (v != .array) return null;
    for (v.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const id = obj.get("id") orelse continue;
        const ob = obj.get("objective") orelse continue;
        if (id != .string or ob != .string) continue;
        if (overlap(intent, ob.string)) return id.string;
    }
    return null;
}

fn overlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    var abuf: [4096]u8 = undefined;
    var bbuf: [4096]u8 = undefined;
    const alen = @min(a.len, abuf.len);
    const blen = @min(b.len, bbuf.len);
    const al = std.ascii.lowerString(abuf[0..alen], a[0..alen]);
    const bl = std.ascii.lowerString(bbuf[0..blen], b[0..blen]);
    return std.mem.find(u8, al, bl) != null or std.mem.find(u8, bl, al) != null;
}
