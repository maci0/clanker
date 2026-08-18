//! compare: put one prompt to several models at once and show the answers
//! unlabeled, so a winner is picked on the answer rather than on the badge.
//!
//! Input (run one):
//!   {"prompt": "...",
//!    "targets": [{"provider": "deepseek", "model": "deepseek-chat"}, ...],
//!    "providers": ["deepseek", "kimi-k3"],
//!    "judge": "<provider>"|"none"|"auto", "max_tokens": 600,
//!    "synthesize": false, "reveal": false}
//! Input (read one): {"id": "<id>", "reveal": true}
//! Input (pick one): {"id": "<id>", "pick": "B"}
//! Input (list):     {"reveal": true}
//! Output: {"ok": true, "id": "...", "prompt": "...", "answers": [...],
//!          "verdict": {...}, "pick": {...}, "revealed": bool,
//!          "text": "<rendered>"}
//!
//! `"reveal": false` on a read or a listing is how a caller that has not
//! already seen the blind view — the web UI's side-by-side is the blind view —
//! asks to be kept blind. It withholds the key from the payload, not just from
//! the render, and a recorded pick overrides it.
//!
//! The rules live in compare_logic.zig, which imports nothing from the guest
//! ABI and is therefore unit-tested on the host. This file is the shell: it
//! resolves targets, makes the calls, persists `state/compare/<id>.json`, and
//! renders — the same split `arena.zig` has against `arena_match.zig`.
//!
//! The entrant calls go through `ck_llm_many`, not `ck_subagent`: an answer to
//! a prompt is one bounded completion with no tools and no file access, and
//! `ck_llm_many` is reachable outside a parent agent run, which is what lets
//! `clanker compare` be a plain subcommand rather than something only an agent
//! can reach. `ck_llm_many` rather than a loop of `ck_llm` because a guest is
//! single-threaded: the host runs the legs side by side, so five models cost
//! the slowest one and not the sum.
//!
//! What is deliberately not here: this is not `providers check`, which pings
//! for connectivity and latency and says nothing about answer quality, and it
//! is not `arena`, where two models argue against each other over rounds. Here
//! the models never see each other; they answer the same question once.

const std = @import("std");
const lib = @import("lib.zig");
const b = @import("compare_logic.zig");

const alloc = lib.alloc;

const state_dir = "state/compare";
/// One line per finished comparison, so a result is replayable rather than
/// only returned once — the same reason `arena` keeps state/arena/log.jsonl.
const ledger_path = state_dir ++ "/log.jsonl";

/// Entrants are told not to introduce themselves. This is the cheap half of
/// keeping the comparison blind; `b.redactIdentity` is the half that works when
/// a model ignores it.
const entrant_system =
    "Answer the question directly and completely. Do not name, hint at, or " ++
    "describe which model, company, or product you are. Do not open with a " ++
    "greeting or a restatement of the question.";

const Settings = struct {
    max_tokens: u32 = b.default_max_tokens,
    /// "auto" picks a configured provider that is not an entrant, "none"
    /// leaves the pick to the human, and any other value names the judge.
    judge: []const u8 = "auto",
    /// Off by default: the merged answer is one more model call, and most
    /// comparisons are run to pick a model rather than to get an answer.
    synthesize: bool = false,
};

fn settings() Settings {
    return std.json.parseFromSliceLeaky(Settings, alloc, lib.config(), .{ .ignore_unknown_fields = true }) catch Settings{};
}

/// One model's run, already moved into its blind position: `pos` is what the
/// reader sees, and nothing above this struct knows which target it came from.
const Entrant = struct {
    pos: usize,
    provider: []const u8,
    model: []const u8,
    ok: bool,
    /// Answer text with the model's own names struck out. Empty when `ok` is
    /// false.
    answer: []const u8,
    err: []const u8,
    detail: []const u8,
    ms: i64,
    tokens: u64,
};

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, input, .{}) catch
        return lib.fail(out, "input must be a JSON object");
    const obj = switch (root) {
        .object => |o| o,
        else => return lib.fail(out, "input must be a JSON object"),
    };

    // Reads and listings reveal by default, because the caller that asks for a
    // comparison by id on the command line already saw the blind view that
    // minted it. `"reveal": false` is how a caller that has not — the web UI's
    // side-by-side, which is itself the blind view — says so.
    const asked_reveal = boolField(obj, "reveal", true);
    if (strField(obj, "id")) |id| {
        if (strField(obj, "pick")) |pick| return recordPick(out, id, pick);
        return readComparison(out, id, asked_reveal);
    }
    if (strField(obj, "prompt")) |prompt| return startComparison(out, obj, prompt);
    return listComparisons(out, asked_reveal);
}

// ------------------------------------------------------------ input helpers

const strField = lib.strFieldTrimmed;
const uintField = lib.uintFieldMap;
const boolField = lib.boolFieldMap;

fn newId(prompt: []const u8) ![]const u8 {
    return lib.prefixedId("compare", prompt);
}

// -------------------------------------------------------------- config view

const HarnessConfig = lib.HarnessConfig;

fn harness() HarnessConfig {
    return lib.parseHarnessConfig();
}

/// Where the entrants come from, in order of how explicit the caller was:
/// full `targets` objects, then a bare `providers` list, then every configured
/// provider. The last one is what makes `clanker compare "<prompt>"` with no
/// flags do the obvious thing on a machine that has several backends set up.
fn resolveTargets(obj: std.json.ObjectMap, cfg: HarnessConfig) ![]b.Target {
    var list: std.ArrayList(b.Target) = .empty;

    if (obj.get("targets")) |tv| {
        if (tv == .array) {
            for (tv.array.items) |item| {
                if (item != .object) continue;
                const provider = strField(item.object, "provider") orelse continue;
                try list.append(alloc, .{
                    .provider = provider,
                    .model = strField(item.object, "model") orelse "",
                });
            }
        }
    }
    if (list.items.len == 0) {
        if (obj.get("providers")) |pv| {
            if (pv == .array) {
                for (pv.array.items) |item| {
                    if (item != .string) continue;
                    const p = std.mem.trim(u8, item.string, " \t\r\n");
                    if (p.len > 0) try list.append(alloc, .{ .provider = p });
                }
            }
        }
    }
    if (list.items.len == 0) {
        // Every configured provider, capped: past the cap this stops being
        // something a person reads and starts being a bill.
        const names = cfg.providers.map.keys();
        for (names) |name| {
            if (list.items.len >= b.max_entrants) break;
            try list.append(alloc, .{ .provider = name });
        }
    }
    return list.toOwnedSlice(alloc);
}

/// Which provider scores the answers.
///
/// "auto" is the configured default provider, and nothing cleverer, because
/// the guest cannot tell a configured provider from a reachable one: config.toml
/// ships half a dozen provider stanzas, most of which have no key on any given
/// machine. Hunting through them for one that is not an entrant would trade a
/// verdict that exists for a "the judge was unreachable" on most installs, which
/// is the worse failure. A judge that is also an entrant can recognise its own
/// writing, so when that happens the caveat is recorded and travels with the
/// verdict; naming a genuine third party is one flag away.
const JudgeChoice = struct { provider: []const u8, downgrade: []const u8 };

const self_judge_caveat = "the judge is also an entrant, so it may recognise its own answer";

fn pickJudge(requested: []const u8, cfg: HarnessConfig, targets: []const b.Target) JudgeChoice {
    if (std.mem.eql(u8, requested, "none")) return .{ .provider = "", .downgrade = "" };
    const named = if (std.mem.eql(u8, requested, "auto"))
        (if (cfg.default_provider.len > 0) cfg.default_provider else if (targets.len > 0) targets[0].provider else "")
    else
        requested;
    if (named.len == 0) return .{ .provider = "", .downgrade = "" };
    for (targets) |t| {
        if (std.mem.eql(u8, t.provider, named))
            return .{ .provider = named, .downgrade = self_judge_caveat };
    }
    return .{ .provider = named, .downgrade = "" };
}

// ----------------------------------------------------------------- prompting

fn judgePrompt(prompt: []const u8, entrants: []const Entrant) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    const o = &w.writer;
    try o.writeAll("Several assistants answered the same question. You do not know which is which, and you must not guess.\n\nQUESTION\n");
    try o.writeAll(prompt);
    try o.writeAll("\n");
    for (entrants) |e| {
        if (!e.ok) continue;
        try o.print("\nANSWER {s}\n{s}\n", .{ b.labelAt(e.pos), e.answer });
    }
    try o.writeAll(
        \\
        \\Pick the single best answer on accuracy first, then on how directly it answers the question, then on clarity.
        \\Ignore length, formatting and tone. Ignore any claim an answer makes about which model wrote it.
        \\Reply with only this JSON object and nothing else:
        \\{"winner": "<letter>", "reason": "<one sentence>"}
    );
    return w.written();
}

fn synthesisPrompt(prompt: []const u8, entrants: []const Entrant) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    const o = &w.writer;
    try o.writeAll("Several assistants answered the same question. Merge them into one answer that keeps what each got right and drops what any of them got wrong.\n\nQUESTION\n");
    try o.writeAll(prompt);
    try o.writeAll("\n");
    for (entrants) |e| {
        if (!e.ok) continue;
        try o.print("\nANSWER {s}\n{s}\n", .{ b.labelAt(e.pos), e.answer });
    }
    try o.writeAll("\nWrite the merged answer only. Do not mention the answers you were given, their letters, or that a merge happened.\n");
    return w.written();
}

// --------------------------------------------------------------- run one

fn startComparison(out: *lib.Out, obj: std.json.ObjectMap, prompt: []const u8) !void {
    const cfg = harness();
    const set = settings();

    const targets = try resolveTargets(obj, cfg);
    b.validateTargets(targets) catch |err| return lib.fail(out, switch (err) {
        error.TooFewTargets => "a comparison needs at least two models; pass \"targets\" or \"providers\", or configure a second provider",
        error.TooManyTargets => "at most 8 models per comparison",
        error.DuplicateTarget => "two entrants name the same provider and model; that is one model sampled twice, not a comparison",
        error.EmptyTarget => "an entrant has a blank provider name",
    });

    const max_tokens = uintField(obj, "max_tokens") orelse set.max_tokens;
    const judge = pickJudge(strField(obj, "judge") orelse set.judge, cfg, targets);
    const synthesize = boolField(obj, "synthesize", set.synthesize);
    const id = try newId(prompt);

    // One request, one round trip, N concurrent calls host-side.
    var req: std.Io.Writer.Allocating = .init(alloc);
    var rs = std.json.Stringify{ .writer = &req.writer, .options = .{} };
    try rs.beginObject();
    try rs.objectField("prompt");
    try rs.write(prompt);
    try rs.objectField("system");
    try rs.write(entrant_system);
    try rs.objectField("max_tokens");
    try rs.write(max_tokens);
    try rs.objectField("targets");
    try rs.beginArray();
    for (targets) |t| {
        try rs.beginObject();
        try rs.objectField("provider");
        try rs.write(t.provider);
        if (t.model.len > 0) {
            try rs.objectField("model");
            try rs.write(t.model);
        }
        try rs.endObject();
    }
    try rs.endArray();
    try rs.endObject();

    const raw = lib.llmMany(req.written()) catch |err| return lib.fail(out, switch (err) {
        error.SandboxDenied => "this tool is not allowed to call the model",
        error.TooLarge => "the prompt or the combined answers were too large",
        error.NetworkError => "no provider answered",
        else => "the request could not be completed",
    });
    const results = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch
        return lib.fail(out, "unreadable answer batch");
    if (results != .array or results.array.items.len != targets.len)
        return lib.fail(out, "answer batch did not match the entrants");

    // Blinding happens here and nowhere else: from this line on the code deals
    // in positions, and the provider a position belongs to is only read again
    // when the result is revealed.
    const slots = try alloc.alloc(usize, targets.len);
    b.blindOrder(slots, b.seedFrom(id, prompt));

    const entrants = try alloc.alloc(Entrant, targets.len);
    for (slots, 0..) |target_index, pos| {
        const r = results.array.items[target_index];
        if (r != .object) {
            entrants[pos] = .{
                .pos = pos,
                .provider = targets[target_index].provider,
                .model = targets[target_index].model,
                .ok = false,
                .answer = "",
                .err = "unreadable answer",
                .detail = "",
                .ms = 0,
                .tokens = 0,
            };
            continue;
        }
        const ro = r.object;
        const provider = jsonStr(ro, "provider");
        const model = jsonStr(ro, "model");
        const ok = if (ro.get("ok")) |v| (v == .bool and v.bool) else false;
        const answer_raw = std.mem.trim(u8, jsonStr(ro, "text"), " \t\r\n");
        const needles = try b.identityNeedles(alloc, provider, model);
        entrants[pos] = .{
            .pos = pos,
            .provider = provider,
            .model = model,
            // A model that answered with nothing is not an answer to compare.
            .ok = ok and answer_raw.len > 0,
            .answer = if (ok) try b.redactIdentity(alloc, answer_raw, needles) else "",
            .err = if (ok and answer_raw.len == 0) "empty answer" else jsonStr(ro, "error"),
            .detail = jsonStr(ro, "detail"),
            .ms = jsonInt(ro, "ms"),
            .tokens = @intCast(@max(0, jsonInt(ro, "tokens"))),
        };
    }

    var answered: usize = 0;
    for (entrants) |e| {
        if (e.ok) answered += 1;
    }
    if (answered == 0) {
        // Nothing to compare and nothing worth persisting: every provider
        // failed, which is a `providers check` problem, not a comparison.
        return lib.fail(out, "no model answered; run `clanker providers check` first");
    }

    var verdict: ?b.Verdict = null;
    var judge_error: []const u8 = "";
    if (judge.provider.len > 0 and answered >= b.min_entrants) {
        if (lib.llmSystem(null, try judgePrompt(prompt, entrants), judge.provider, b.judge_max_tokens)) |reply| {
            verdict = b.parseVerdict(alloc, reply, entrants.len);
            if (verdict == null) judge_error = "the judge did not name an answer";
        } else |err| {
            judge_error = switch (err) {
                error.SandboxDenied => "judge call refused by sandbox policy",
                error.NetworkError => "judge call did not complete",
                error.TooLarge => "prompt too large for judge",
                else => "the judge did not respond",
            };
        }
    } else if (judge.provider.len > 0) {
        judge_error = "only one model answered, so there was nothing to judge";
    }

    var synthesis: []const u8 = "";
    if (synthesize and answered >= b.min_entrants) {
        const with = if (judge.provider.len > 0) judge.provider else entrants[0].provider;
        if (lib.llmSystem(null, try synthesisPrompt(prompt, entrants), with, b.synthesis_max_tokens)) |merged| {
            synthesis = std.mem.trim(u8, merged, " \t\r\n");
        } else |_| {}
    }

    // Revealed once there is a decision to attach the names to, or when the
    // caller asked outright. Without one, printing the key would defeat the
    // point of having run this blind.
    const reveal = boolField(obj, "reveal", verdict != null);

    const doc = Doc{
        .id = id,
        .prompt = prompt,
        .entrants = entrants,
        .judge_provider = judge.provider,
        .judge_downgrade = judge.downgrade,
        .judge_error = judge_error,
        .verdict = verdict,
        .synthesis = synthesis,
    };
    try persist(doc);
    try appendLedger(doc);

    const text = try render(doc, reveal);
    try emit(out, doc, text, reveal);
}

// ------------------------------------------------------------- persistence

/// Everything a stored comparison holds. Entrants are in blind order, so the
/// file on disk does not leak the order they were configured in either.
const Doc = struct {
    id: []const u8,
    prompt: []const u8,
    entrants: []const Entrant,
    judge_provider: []const u8,
    judge_downgrade: []const u8,
    judge_error: []const u8,
    verdict: ?b.Verdict,
    synthesis: []const u8,
    /// A human's pick, when one was recorded. Blind position, like a verdict.
    pick: ?usize = null,
};

fn comparisonPath(id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, state_dir ++ "/{s}.json", .{id});
}

fn writeDoc(s: *std.json.Stringify, doc: Doc) !void {
    try s.beginObject();
    try s.objectField("id");
    try s.write(doc.id);
    try s.objectField("prompt");
    try s.write(doc.prompt);
    try s.objectField("entrants");
    try s.beginArray();
    for (doc.entrants) |e| {
        try s.beginObject();
        try s.objectField("label");
        try s.write(b.labelAt(e.pos));
        try s.objectField("provider");
        try s.write(e.provider);
        try s.objectField("model");
        try s.write(e.model);
        try s.objectField("ok");
        try s.write(e.ok);
        try s.objectField("ms");
        try s.write(e.ms);
        if (e.ok) {
            try s.objectField("tokens");
            try s.write(e.tokens);
            try s.objectField("answer");
            try s.write(e.answer);
        } else {
            try s.objectField("error");
            try s.write(e.err);
            if (e.detail.len > 0) {
                try s.objectField("detail");
                try s.write(e.detail);
            }
        }
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("judge");
    try s.beginObject();
    try s.objectField("provider");
    try s.write(doc.judge_provider);
    if (doc.judge_downgrade.len > 0) {
        try s.objectField("caveat");
        try s.write(doc.judge_downgrade);
    }
    if (doc.judge_error.len > 0) {
        try s.objectField("error");
        try s.write(doc.judge_error);
    }
    if (doc.verdict) |v| {
        try s.objectField("winner");
        try s.write(b.labelAt(v.pos));
        try s.objectField("winner_provider");
        try s.write(doc.entrants[v.pos].provider);
        try s.objectField("winner_model");
        try s.write(doc.entrants[v.pos].model);
        try s.objectField("reason");
        try s.write(v.reason);
    }
    try s.endObject();
    if (doc.pick) |p| {
        try s.objectField("pick");
        try s.beginObject();
        try s.objectField("label");
        try s.write(b.labelAt(p));
        try s.objectField("provider");
        try s.write(doc.entrants[p].provider);
        try s.objectField("model");
        try s.write(doc.entrants[p].model);
        try s.endObject();
    }
    if (doc.synthesis.len > 0) {
        try s.objectField("synthesis");
        try s.write(doc.synthesis);
    }
    try s.endObject();
}

fn persist(doc: Doc) !void {
    var w: std.Io.Writer.Allocating = .init(alloc);
    defer w.deinit();
    var s = std.json.Stringify{ .writer = &w.writer, .options = .{} };
    try writeDoc(&s, doc);
    try lib.fsWrite(try comparisonPath(doc.id), w.written());
}

fn appendLedger(doc: Doc) !void {
    var w: std.Io.Writer.Allocating = .init(alloc);
    defer w.deinit();
    var s = std.json.Stringify{ .writer = &w.writer, .options = .{} };
    try s.beginObject();
    try s.objectField("id");
    try s.write(doc.id);
    try s.objectField("prompt");
    try s.write(doc.prompt);
    try s.objectField("entrants");
    try s.write(doc.entrants.len);
    try s.objectField("winner");
    if (doc.verdict) |v| try s.write(doc.entrants[v.pos].provider) else try s.write("");
    try s.endObject();
    try w.writer.writeAll("\n");
    try lib.fsAppend(ledger_path, w.written());
}

// --------------------------------------------------------------- rendering

/// The blind view. Answers first with nothing but their letter, then the
/// verdict, then the key — in that order on purpose, so a reader who wants to
/// pick for themselves can stop reading before the reveal.
fn render(doc: Doc, reveal: bool) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    const o = &w.writer;
    try o.print("compare {s}: {s}\n", .{ doc.id, doc.prompt });
    for (doc.entrants) |e| {
        if (e.ok) {
            try o.print("\n--- {s} ({d}ms) ---\n{s}\n", .{ b.labelAt(e.pos), e.ms, e.answer });
        } else {
            try o.print("\n--- {s} (no answer: {s}) ---\n", .{ b.labelAt(e.pos), e.err });
        }
    }
    if (doc.verdict) |v| {
        try o.print("\nverdict: {s}", .{b.labelAt(v.pos)});
        // Who judged is withheld while the comparison is blind. Naming the
        // judge names a provider, and the caveat on the next line says that
        // provider may also be an entrant — between them, a two-way comparison
        // is half un-blinded by a line that was only meant to attribute the
        // verdict. The caveat itself carries no name and stays either way.
        if (reveal and doc.judge_provider.len > 0) try o.print(" (judged by {s})", .{doc.judge_provider});
        try o.writeAll("\n");
        if (v.reason.len > 0) try o.print("  {s}\n", .{v.reason});
        if (doc.judge_downgrade.len > 0) try o.print("  caveat: {s}\n", .{doc.judge_downgrade});
    } else if (doc.judge_error.len > 0) {
        try o.print("\nno verdict: {s}\n", .{doc.judge_error});
    }
    if (doc.pick) |p| try o.print("\nyour pick: {s}\n", .{b.labelAt(p)});
    if (doc.synthesis.len > 0) try o.print("\nmerged answer:\n{s}\n", .{doc.synthesis});

    if (reveal) {
        try o.writeAll("\nkey\n");
        for (doc.entrants) |e| {
            if (e.model.len > 0)
                try o.print("  {s}  {s}/{s}\n", .{ b.labelAt(e.pos), e.provider, e.model })
            else
                try o.print("  {s}  {s}\n", .{ b.labelAt(e.pos), e.provider });
        }
    } else {
        try o.print("\nstill blind. Pick with: clanker compare --show {s} --pick <letter>\n", .{doc.id});
    }
    return w.written();
}

/// The tool's own reply: the rendered text plus the same facts structured, so
/// a caller does not have to scrape the text to know who won.
fn emit(out: *lib.Out, doc: Doc, text: []const u8, reveal: bool) !void {
    var w = lib.writer(out);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("id");
    try s.write(doc.id);
    // The question, structured rather than only inside `text`. A renderer that
    // has to scrape the prompt back out of a rendered block is a renderer that
    // will one day scrape something else out of it too.
    try s.objectField("prompt");
    try s.write(doc.prompt);
    try s.objectField("text");
    try s.write(text);
    try s.objectField("revealed");
    try s.write(reveal);
    try s.objectField("answers");
    try s.beginArray();
    for (doc.entrants) |e| {
        try s.beginObject();
        try s.objectField("label");
        try s.write(b.labelAt(e.pos));
        try s.objectField("ok");
        try s.write(e.ok);
        try s.objectField("ms");
        try s.write(e.ms);
        if (e.ok) {
            try s.objectField("text");
            try s.write(e.answer);
        } else {
            try s.objectField("error");
            try s.write(e.err);
        }
        // Only once the comparison is revealed: an agent reading this back
        // mid-comparison would be as un-blinded as a human reading the key.
        if (reveal) {
            try s.objectField("provider");
            try s.write(e.provider);
            try s.objectField("model");
            try s.write(e.model);
        }
        try s.endObject();
    }
    try s.endArray();
    if (doc.verdict) |v| {
        try s.objectField("verdict");
        try s.beginObject();
        try s.objectField("winner");
        try s.write(b.labelAt(v.pos));
        try s.objectField("reason");
        try s.write(v.reason);
        if (reveal) {
            try s.objectField("provider");
            try s.write(doc.entrants[v.pos].provider);
            try s.objectField("model");
            try s.write(doc.entrants[v.pos].model);
        }
        try s.endObject();
    }
    // What the human already chose, if anything — the field a picker needs to
    // tell "not decided yet" from "decided, and here is what it turned out to
    // be". Structured for the same reason the prompt is.
    if (doc.pick) |p| {
        try s.objectField("pick");
        try s.beginObject();
        try s.objectField("label");
        try s.write(b.labelAt(p));
        if (reveal) {
            try s.objectField("provider");
            try s.write(doc.entrants[p].provider);
            try s.objectField("model");
            try s.write(doc.entrants[p].model);
        }
        try s.endObject();
    }
    if (doc.synthesis.len > 0) {
        try s.objectField("synthesis");
        try s.write(doc.synthesis);
    }
    try s.endObject();
    lib.commit(out, &w);
}

// -------------------------------------------------------- read, pick & list

fn loadDoc(id: []const u8) !?Doc {
    if (!b.isSafeId(id)) return null;
    const raw = lib.fsRead(try comparisonPath(id)) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, raw, .{}) catch return null;
    if (parsed != .object) return null;
    const root = parsed.object;

    var list: std.ArrayList(Entrant) = .empty;
    if (root.get("entrants")) |ev| {
        if (ev == .array) {
            for (ev.array.items, 0..) |item, pos| {
                if (item != .object) continue;
                const eo = item.object;
                try list.append(alloc, .{
                    .pos = pos,
                    .provider = jsonStr(eo, "provider"),
                    .model = jsonStr(eo, "model"),
                    .ok = if (eo.get("ok")) |v| (v == .bool and v.bool) else false,
                    .answer = jsonStr(eo, "answer"),
                    .err = jsonStr(eo, "error"),
                    .detail = jsonStr(eo, "detail"),
                    .ms = jsonInt(eo, "ms"),
                    .tokens = @intCast(@max(0, jsonInt(eo, "tokens"))),
                });
            }
        }
    }
    const entrants = try list.toOwnedSlice(alloc);

    var doc = Doc{
        .id = jsonStr(root, "id"),
        .prompt = jsonStr(root, "prompt"),
        .entrants = entrants,
        .judge_provider = "",
        .judge_downgrade = "",
        .judge_error = "",
        .verdict = null,
        .synthesis = jsonStr(root, "synthesis"),
    };
    if (root.get("judge")) |jv| {
        if (jv == .object) {
            doc.judge_provider = jsonStr(jv.object, "provider");
            doc.judge_downgrade = jsonStr(jv.object, "caveat");
            doc.judge_error = jsonStr(jv.object, "error");
            if (b.parseLabel(jsonStr(jv.object, "winner"), entrants.len)) |pos|
                doc.verdict = .{ .pos = pos, .reason = jsonStr(jv.object, "reason") };
        }
    }
    if (root.get("pick")) |pv| {
        if (pv == .object) doc.pick = b.parseLabel(jsonStr(pv.object, "label"), entrants.len);
    }
    return doc;
}

fn readComparison(out: *lib.Out, id: []const u8, asked_reveal: bool) !void {
    const doc = (try loadDoc(id)) orelse return lib.fail(out, "no such comparison");
    // Whether the key travels at all, not merely whether it is printed: an
    // un-revealed read carries no provider and no model anywhere in its reply,
    // so a caller that renders the structured `answers` array has nothing to
    // leak even by accident. See `b.mayReveal` for why a pick overrides.
    const reveal = b.mayReveal(asked_reveal, doc.pick != null);
    const text = try render(doc, reveal);
    try emit(out, doc, text, reveal);
}

fn recordPick(out: *lib.Out, id: []const u8, pick: []const u8) !void {
    var doc = (try loadDoc(id)) orelse return lib.fail(out, "no such comparison");
    const pos = b.parseLabel(pick, doc.entrants.len) orelse
        return lib.fail(out, "that is not one of the answers on the table");
    doc.pick = pos;
    try persist(doc);
    const text = try render(doc, true);
    try emit(out, doc, text, true);
}

const jsonStr = lib.jsonStrField;

fn jsonInt(obj: std.json.ObjectMap, name: []const u8) i64 {
    const v = obj.get(name) orelse return 0;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @trunc(f),
        else => 0,
    };
}

/// Past comparisons, newest first, as both a text table and a structured array
/// — off the ledger rather than by walking every comparison file, which is the
/// reason the ledger exists.
///
/// The ledger row names the winning *provider*, which is a listing that
/// un-blinds every comparison in it before one is even opened: with two
/// entrants, "deepseek won" plus the verdict letter the blind view does show is
/// the whole key. So an un-revealed listing reports only whether a judge
/// reached a verdict, never whose it was.
fn listComparisons(out: *lib.Out, reveal: bool) !void {
    var entries: std.ArrayList(std.json.ObjectMap) = .empty;
    defer entries.deinit(alloc);
    if (lib.fsRead(ledger_path)) |ledger| {
        var it = std.mem.splitScalar(u8, ledger, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, trimmed, .{}) catch continue;
            if (parsed != .object) continue;
            try entries.append(alloc, parsed.object);
        }
    } else |_| {}

    // The ledger is append-ordered, and a picker wants the one that just
    // finished at the top.
    std.mem.reverse(std.json.ObjectMap, entries.items);

    var t: std.Io.Writer.Allocating = .init(alloc);
    defer t.deinit();
    if (entries.items.len == 0) {
        try t.writer.writeAll("(no comparisons yet; start one with a \"prompt\")");
    } else {
        for (entries.items) |doc| {
            const winner = jsonStr(doc, "winner");
            const middle = if (reveal) winner else (if (winner.len > 0) "judged" else "unjudged");
            try t.writer.print("{s}\t{s}\t{s}\n", .{ jsonStr(doc, "id"), middle, jsonStr(doc, "prompt") });
        }
    }

    var w = lib.writer(out);
    var s = std.json.Stringify{ .writer = &w, .options = .{} };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(true);
    try s.objectField("text");
    try s.write(t.written());
    try s.objectField("comparisons");
    try s.beginArray();
    for (entries.items) |doc| {
        const winner = jsonStr(doc, "winner");
        try s.beginObject();
        try s.objectField("id");
        try s.write(jsonStr(doc, "id"));
        try s.objectField("prompt");
        try s.write(jsonStr(doc, "prompt"));
        // Always present, and safe either way: that a judge reached a verdict
        // says nothing about which answer it named or who wrote it.
        try s.objectField("judged");
        try s.write(winner.len > 0);
        if (reveal) {
            try s.objectField("winner");
            try s.write(winner);
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    lib.commit(out, &w);
}
