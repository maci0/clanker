//! Pure draft logic for the goal_write guest (`clanker write-goal`, the TUI
//! /write-goal, and the goal_write catalog tool). Host-tested via
//! `host_tested_helpers` in build.zig; the guest imports this file, so the
//! CLI, the web UI and the agent all run the one implementation.
//!
//! The contract: the five review fields — objective, completion_criterion,
//! proof, boundaries, stop_rule — are distinct. A field the intent answered
//! holds only the segment(s) of the intent that answer it; a field it did not
//! answer holds `defaultFor` and is listed under Assumed / Still open. The
//! whole intent appears once, as `Draft.intent`, never as a stand-in for a
//! review field.
const std = @import("std");

pub const Field = enum {
    objective,
    completion_criterion,
    proof,
    boundaries,
    stop_rule,
};

pub const field_count = 5;
pub const fields = [_]Field{
    .objective,
    .completion_criterion,
    .proof,
    .boundaries,
    .stop_rule,
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

const objective_markers = [_][]const u8{ " exists", " survive", " is ", " stays", " remains", " will ", " must " };
const criterion_markers = [_][]const u8{ "eval", "test", "criterion", " pass", " check", " gate", "verified", "verifiable", "done when" };
const proof_markers = [_][]const u8{ "e2e", ".zig", ".md", "eval", "proof", "command", "script", "tests/", "zig build", "test" };
const boundaries_markers = [_][]const u8{ "without ", "don't change", "do not change", "preserve", "keep ", "not touch", "leave ", "untouched", "except ", "out of scope" };
const stop_markers = [_][]const u8{ "stop", "revert", "budget", "cap", "limit", "iterations", "rounds", "max " };

pub fn markersFor(field: Field) []const []const u8 {
    return switch (field) {
        .objective => &objective_markers,
        .completion_criterion => &criterion_markers,
        .proof => &proof_markers,
        .boundaries => &boundaries_markers,
        .stop_rule => &stop_markers,
    };
}

/// Earliest position at which any of the field's markers matches, or null.
pub fn hintPos(field: Field, hay: []const u8) ?usize {
    var best: ?usize = null;
    for (markersFor(field)) |m| {
        if (findFold(hay, m)) |p| {
            if (best == null or p < best.?) best = p;
        }
    }
    return best;
}

/// Whether the intent text already answers a given fork, by keyword. This is
/// only the cheap "did the intent mention this fork" signal used to pick
/// interview questions; `assemble` extracts per-segment, so a true here never
/// licenses pasting the whole intent into the field.
pub fn intentAnswers(field: Field, intent: []const u8) bool {
    return hintPos(field, intent) != null;
}

/// Case-insensitive substring search — no copy, so no stack slice escapes.
fn findFold(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
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
        if (matched) return i;
    }
    return null;
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
pub fn defaultFor(field: Field) []const u8 {
    return switch (field) {
        .objective => "TBD — restate the intent as an outcome.",
        .completion_criterion => "TBD — the intent did not state how completion is judged; revisit before persisting.",
        .proof => "TBD — no proof artifact was specified.",
        .boundaries => "None stated; assume the change is scoped to the intent.",
        .stop_rule => "None specified; stop when a gate fails or the criterion is met.",
    };
}

pub fn fieldName(field: Field) []const u8 {
    return switch (field) {
        .objective => "objective",
        .completion_criterion => "completion_criterion",
        .proof => "proof",
        .boundaries => "boundaries",
        .stop_rule => "stop_rule",
    };
}

/// Split the intent into reviewable segments: sentences first, and comma
/// clauses only when the whole intent is a single sentence. A '.'/'!'/'?'/';'
/// splits only when followed by whitespace or the end of the text, so a dot
/// inside a path or version number is not a boundary. Slices point into
/// `intent`; only the list itself is allocated.
pub fn segments(alloc: std.mem.Allocator, intent: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try splitOn(alloc, &list, intent, ".!?;\n");
    if (list.items.len <= 1) {
        list.clearRetainingCapacity();
        try splitOn(alloc, &list, intent, ".!?;\n,");
    }
    return list.toOwnedSlice(alloc);
}

fn splitOn(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8), text: []const u8, delims: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (std.mem.indexOfScalar(u8, delims, c) == null) continue;
        if (c != '\n' and i + 1 < text.len and !std.ascii.isWhitespace(text[i + 1])) continue;
        try appendTrimmed(alloc, list, text[start..i]);
        start = i + 1;
    }
    try appendTrimmed(alloc, list, text[start..]);
}

fn appendTrimmed(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8), piece: []const u8) !void {
    const trimmed = std.mem.trim(u8, piece, " \t\r\n");
    if (trimmed.len == 0) return;
    try list.append(alloc, trimmed);
}

/// Assemble the Draft: answered > extracted-from-intent > default + open.
/// Extraction hands each fork only the intent segment(s) whose markers match
/// it — never the whole intent, and never text another field already holds —
/// so a fork whose only matching segment is claimed elsewhere defaults and is
/// listed open instead of duplicating.
pub fn assemble(alloc: std.mem.Allocator, intent: []const u8, answers: *const [field_count]?[]const u8) Draft {
    const intent_trim = std.mem.trim(u8, intent, " \t\r\n");
    const segs = segments(alloc, intent_trim) catch &.{};
    var vals: [field_count][]const u8 = undefined;
    var open: [field_count][]const u8 = undefined;
    var n_open: usize = 0;

    inline for (fields) |f| {
        const idx = @intFromEnum(f);
        if (answers[idx]) |a| {
            vals[idx] = a;
        } else if (extractFor(alloc, f, intent_trim, segs, vals[0..idx])) |part| {
            vals[idx] = part;
        } else {
            // Open, unanswered, or only duplicating another field: default it,
            // but say so — never silently invent. It stays on the unresolved
            // list for the review step.
            vals[idx] = defaultFor(f);
            open[n_open] = fieldName(f);
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
        .objective = vals[@intFromEnum(Field.objective)],
        .completion_criterion = vals[@intFromEnum(Field.completion_criterion)],
        .proof = vals[@intFromEnum(Field.proof)],
        .boundaries = vals[@intFromEnum(Field.boundaries)],
        .stop_rule = vals[@intFromEnum(Field.stop_rule)],
        .assumptions = assumptions,
        .unresolved = unresolved,
    };
}

/// The part of the intent that answers `field`: the matching segments joined
/// with "; ", except the objective, which takes only its first matching
/// segment so it stays one outcome sentence. Returns null when no segment
/// matches, when the result would be the whole intent, or when it would
/// duplicate a field already filled (`taken`) — the caller defaults the field
/// instead, so the raw blob is never a stand-in for a review field.
fn extractFor(alloc: std.mem.Allocator, field: Field, intent_trim: []const u8, segs: []const []const u8, taken: []const []const u8) ?[]const u8 {
    var first: ?[]const u8 = null;
    var n: usize = 0;
    var joined_len: usize = 0;
    for (segs) |seg| {
        if (hintPos(field, seg) == null) continue;
        if (first == null) first = seg;
        joined_len += seg.len;
        n += 1;
    }
    const f = first orelse return null;

    const candidate: []const u8 = if (field == .objective or n == 1) f else blk: {
        const sep = "; ";
        const buf = alloc.alloc(u8, joined_len + sep.len * (n - 1)) catch return null;
        var at: usize = 0;
        var written: usize = 0;
        for (segs) |seg| {
            if (hintPos(field, seg) == null) continue;
            if (written > 0) {
                @memcpy(buf[at..][0..sep.len], sep);
                at += sep.len;
            }
            @memcpy(buf[at..][0..seg.len], seg);
            at += seg.len;
            written += 1;
        }
        break :blk buf[0..at];
    };
    if (usable(candidate, intent_trim, taken)) return candidate;

    // A segment that answers two forks at once: for the trailing-phrase
    // fields the text from the marker onward still reads as the answer
    // ("without changing the prompt format"); the other fields have no
    // honest sub-phrase, so they default.
    if (field == .boundaries or field == .stop_rule) {
        if (hintPos(field, f)) |pos| {
            const suffix = std.mem.trim(u8, f[pos..], " \t\r\n");
            if (usable(suffix, intent_trim, taken)) return suffix;
        }
    }
    return null;
}

/// A candidate field value is usable when it is non-empty, not the whole
/// intent, and not byte-identical to a field already filled.
fn usable(candidate: []const u8, intent_trim: []const u8, taken: []const []const u8) bool {
    if (candidate.len == 0) return false;
    if (std.mem.eql(u8, candidate, intent_trim)) return false;
    for (taken) |t| if (std.mem.eql(u8, candidate, t)) return false;
    return true;
}

/// On OOM, return the five fields filled with no open/assumption lists.
fn emptyDraft(intent: []const u8, vals: [field_count][]const u8) Draft {
    return .{
        .intent = intent,
        .objective = vals[@intFromEnum(Field.objective)],
        .completion_criterion = vals[@intFromEnum(Field.completion_criterion)],
        .proof = vals[@intFromEnum(Field.proof)],
        .boundaries = vals[@intFromEnum(Field.boundaries)],
        .stop_rule = vals[@intFromEnum(Field.stop_rule)],
        .assumptions = &.{},
        .unresolved = &.{},
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
    // renderMarkdown's allocPrint temporaries are freed by the caller's arena
    // (the guest runs on one), so the test provides an arena too.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d = Draft{
        .intent = "x",
        .objective = "o",
        .completion_criterion = "c",
        .proof = "p",
        .boundaries = "b",
        .stop_rule = "s",
        .assumptions = &.{"assumed default"},
    };
    const md = try renderMarkdown(arena, &d);
    try std.testing.expect(std.mem.find(u8, md, "**objective:**") != null);
    try std.testing.expect(std.mem.find(u8, md, "**stop_rule:**") != null);
    try std.testing.expect(std.mem.find(u8, md, "assumed default") != null);
}

test "multi-fork intent assembles five distinct fields, none the raw blob" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const intent = "The repl picker filter must match on every model field. " ++
        "Done when filtering by provider narrows the list and clanker gate stays green. " ++
        "Proof is the pty journey in e2e/pty_picker_preview.zig. " ++
        "Keep the search modal untouched and do not change the fold logic. " ++
        "Stop after two failed attempts and revert the branch.";

    const answers: [field_count]?[]const u8 = .{null} ** field_count;
    const d = assemble(arena, intent, &answers);

    try std.testing.expectEqualStrings("The repl picker filter must match on every model field", d.objective);
    try std.testing.expectEqualStrings("Done when filtering by provider narrows the list and clanker gate stays green", d.completion_criterion);
    try std.testing.expectEqualStrings("Proof is the pty journey in e2e/pty_picker_preview.zig", d.proof);
    try std.testing.expectEqualStrings("Keep the search modal untouched and do not change the fold logic", d.boundaries);
    try std.testing.expectEqualStrings("Stop after two failed attempts and revert the branch", d.stop_rule);

    // Every field is a proper subset of the intent — never the blob — and no
    // two fields hold the same text.
    const all = [_][]const u8{ d.objective, d.completion_criterion, d.proof, d.boundaries, d.stop_rule };
    for (all, 0..) |v, i| {
        try std.testing.expect(!std.mem.eql(u8, v, intent));
        try std.testing.expect(v.len < intent.len);
        try std.testing.expect(std.mem.find(u8, intent, v) != null);
        for (all[i + 1 ..]) |w| try std.testing.expect(!std.mem.eql(u8, v, w));
    }
    try std.testing.expectEqual(@as(usize, 0), d.unresolved.len);
}

test "one-sentence intent yields clause subsets and defaults the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const intent = "Make runs survive a restart without changing the prompt format, verified by the e2e restart test";
    const answers: [field_count]?[]const u8 = .{null} ** field_count;
    const d = assemble(arena, intent, &answers);

    try std.testing.expectEqualStrings("Make runs survive a restart without changing the prompt format", d.objective);
    try std.testing.expectEqualStrings("verified by the e2e restart test", d.completion_criterion);
    // The proof clause is the criterion clause, so proof defaults rather than
    // duplicating it; boundaries falls back to the marker-anchored phrase.
    try std.testing.expectEqualStrings(defaultFor(.proof), d.proof);
    try std.testing.expectEqualStrings("without changing the prompt format", d.boundaries);
    try std.testing.expectEqualStrings(defaultFor(.stop_rule), d.stop_rule);

    var saw_proof = false;
    var saw_stop = false;
    for (d.unresolved) |u| {
        if (std.mem.eql(u8, u, "proof")) saw_proof = true;
        if (std.mem.eql(u8, u, "stop_rule")) saw_stop = true;
    }
    try std.testing.expect(saw_proof);
    try std.testing.expect(saw_stop);
}

test "vague intent assembles all defaults and lists every fork open" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const answers: [field_count]?[]const u8 = .{null} ** field_count;
    const d = assemble(arena, "improve the repl", &answers);
    try std.testing.expectEqualStrings(defaultFor(.objective), d.objective);
    try std.testing.expectEqualStrings(defaultFor(.completion_criterion), d.completion_criterion);
    try std.testing.expectEqualStrings(defaultFor(.proof), d.proof);
    try std.testing.expectEqualStrings(defaultFor(.boundaries), d.boundaries);
    try std.testing.expectEqualStrings(defaultFor(.stop_rule), d.stop_rule);
    try std.testing.expectEqual(@as(usize, field_count), d.unresolved.len);
}

test "an ask_user answer beats extraction" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var answers: [field_count]?[]const u8 = .{null} ** field_count;
    answers[@intFromEnum(Field.completion_criterion)] = "the pty e2e passes";
    const d = assemble(arena, "improve the repl", &answers);
    try std.testing.expectEqualStrings("the pty e2e passes", d.completion_criterion);
    try std.testing.expectEqual(@as(usize, field_count - 1), d.unresolved.len);
}

test "segments split sentences but not dots inside paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try segments(arena, "Proof is tests/e2e/pty.zig passing. Keep ui/app untouched.");
    try std.testing.expectEqual(@as(usize, 2), segs.len);
    try std.testing.expectEqualStrings("Proof is tests/e2e/pty.zig passing", segs[0]);
    try std.testing.expectEqualStrings("Keep ui/app untouched", segs[1]);

    const clauses = try segments(arena, "do the thing, without breaking the API");
    try std.testing.expectEqual(@as(usize, 2), clauses.len);
    try std.testing.expectEqualStrings("without breaking the API", clauses[1]);
}
