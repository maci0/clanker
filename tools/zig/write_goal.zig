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

// Pure draft logic — which forks the intent answers, per-segment extraction,
// Draft assembly, markdown rendering — lives in write_goal_logic.zig, listed
// in build.zig's host_tested_helpers so `zig build test` runs its tests (a
// wasm guest's own test blocks never run).
const draft = @import("write_goal_logic.zig");

/// The documented ceiling on `max_questions`: the input schema says 1..4, and
/// a request above it is clamped rather than refused. Untyped so it reads as
/// both the float default and the integer clamp below.
const max_questions = 4;

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const v = lib.object(input) catch return lib.fail(out, "input must be a JSON object");
    const intent = lib.str(v, "intent") catch return lib.fail(out, "missing required string field: intent");
    const max_q: usize = blk: {
        const n = lib.optNum(v, "max_questions") orelse @as(f64, max_questions);
        const m: u32 = @trunc(n);
        break :blk @min(m, max_questions);
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
    var answers: [draft.field_count]?[]const u8 = .{null} ** draft.field_count;
    var questions_asked: usize = 0;
    for (qs) |q| {
        const reply = askOne(q.prompt, q.options, to_parent) orelse break;
        answers[@intFromEnum(q.field)] = reply;
        questions_asked += 1;
    }

    // 4. Assemble the Draft: answered > extracted-from-intent > default + open.
    const d = draft.assemble(lib.alloc, intent, &answers);

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
