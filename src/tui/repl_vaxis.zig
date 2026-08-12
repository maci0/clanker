//! libvaxis-backed REPL (docs/ROADMAP.md migration). This is `clanker repl`,
//! the default REPL; the hand-rolled src/tui REPL was removed once this
//! proved out (the `repl-vaxis` spelling is kept as a compatibility alias in
//! cli.zig).
//!
//! Architecture: a single root `vxfw.Widget` ("Model") drives everything.
//! `vxfw.App.run` already handles SIGWINCH (`.winsize` events resize and
//! redraw automatically — no self-pipe needed, unlike src/tui/term.zig)
//! and owns the render loop. A submitted task runs `Agent.run` on a
//! background thread (LLM calls and tool execution are blocking); the
//! callbacks it takes (`on_token`/`on_tool_call`/`on_tool_result`) are bare
//! function pointers with no userdata slot, so they write into module-level,
//! mutex-guarded state, and the Model's `.tick` handler re-schedules itself
//! every 50ms *only while a turn is in flight* to pick up new streamed
//! content — idle, there is no timer running and the app is purely
//! event-driven, same principle as this session's KeyReader poll() fix in
//! the old REPL.
//!
//! Deliberately not yet built (documented gaps, not oversights): inline
//! ask_user/approval prompts (falls back to the same "nobody attached"
//! default a headless run gets). Full list, with what a fix looks like for
//! each: docs/ROADMAP.md's "vaxis REPL parity" entry under Planned. Tool
//! calls render as the established left-bar cards, built as plain strings by
//! transcript.zig's card helpers and styled into cells at draw time.
//!
//! Tab-complete over `command_registry` (`completeSlashCommand`) is the one
//! completion UI that isn't a modal picker: it edits the TextField in place
//! (single match, or several completing to a shared prefix) rather than
//! opening `/model`'s `picker_open`/`handlePickerKey` loop, since there is
//! nothing to navigate — just a line to finish or list.

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const config = @import("../config.zig");
const client = @import("../llm/client.zig");
const types = @import("../llm/types.zig");
const providers = @import("../llm/providers.zig");
const registry = @import("../tools/registry.zig");
const session_mod = @import("../agent/session.zig");
const runtime = @import("../sandbox/runtime.zig");
const agent_loop = @import("../agent/loop.zig");
const Agent = agent_loop.Agent;
const log = @import("../util/log.zig");
const syntax = @import("syntax.zig");
const theme_mod = @import("theme.zig");
// `_mod` because saveConversation has a local named `transcript`.
const transcript_mod = @import("transcript.zig");

/// A C0 control or DEL that must not reach the terminal, mirroring
/// src/tui/transcript.zig's writeSanitized (CWE-150): everything rendered
/// here is text clanker didn't generate itself.
fn isDroppedControl(c: u8) bool {
    return (c < 0x20 and c != '\n' and c != '\t') or c == 0x7F;
}

/// Most streamed deltas contain no control bytes, so this only allocates
/// when one is actually found, keeping the common case alloc-free on the
/// per-token `onToken` path.
fn stripControls(gpa: std.mem.Allocator, bytes: []const u8) []const u8 {
    const first_drop = for (bytes, 0..) |c, i| {
        if (isDroppedControl(c)) break i;
    } else return bytes;

    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(gpa, bytes.len) catch return bytes;
    out.appendSliceAssumeCapacity(bytes[0..first_drop]);
    for (bytes[first_drop..]) |c| {
        if (!isDroppedControl(c)) out.appendAssumeCapacity(c);
    }
    return out.toOwnedSlice(gpa) catch bytes;
}

// ---------------------------------------------------------------------
// Module-level bridge state: Agent's callbacks are bare `*const fn(...)`
// with no captured context, so the background run thread and the render
// thread meet here instead, guarded by one mutex.
// ---------------------------------------------------------------------

var bridge_mutex: std.Io.Mutex = .init;
var bridge_io: std.Io = undefined;
var bridge_gpa: std.mem.Allocator = undefined;
var bridge_streaming: bool = false;
var bridge_stream_buf: std.ArrayList(u8) = .empty;
var bridge_tool_lines: std.ArrayList([]const u8) = .empty;
var bridge_stop_flag: std.atomic.Value(bool) = .init(false);
/// Published only after runThreadMain has finished all deferred Agent cleanup.
/// The UI thread consumes this and joins the worker before making the model
/// idle, so the model arena cannot be destroyed while cleanup still uses it.
var bridge_turn_done: std.atomic.Value(bool) = .init(false);

fn onToken(delta: []const u8) void {
    bridge_mutex.lockUncancelable(bridge_io);
    defer bridge_mutex.unlock(bridge_io);
    const clean = stripControls(bridge_gpa, delta);
    defer if (clean.ptr != delta.ptr) bridge_gpa.free(clean);
    bridge_stream_buf.appendSlice(bridge_gpa, clean) catch {};
}

/// Each batch of calls becomes one left-bar card (transcript.zig's card
/// builders): the first call opens it, the rest of the batch joins the body,
/// each call's arguments follow as a truncated one-line preview, and
/// onToolResult closes it — the agent reports one timing per batch, so
/// per-call cards would draw open corners nothing ever closes. Name and
/// arguments are untrusted; the builders control-strip them (CWE-150).
fn onToolCall(calls: []const types.ToolCall) void {
    bridge_mutex.lockUncancelable(bridge_io);
    defer bridge_mutex.unlock(bridge_io);
    for (calls, 0..) |c, i| {
        const header = transcript_mod.toolCardHeader(bridge_gpa, c.name, i == 0) catch continue;
        bridge_tool_lines.append(bridge_gpa, header) catch bridge_gpa.free(header);
        const body = transcript_mod.toolCardArgs(bridge_gpa, c.arguments) catch null;
        if (body) |b| bridge_tool_lines.append(bridge_gpa, b) catch bridge_gpa.free(b);
    }
}

fn onToolResult(elapsed_ms: u64) void {
    bridge_mutex.lockUncancelable(bridge_io);
    defer bridge_mutex.unlock(bridge_io);
    const line = transcript_mod.toolCardFooter(bridge_gpa, elapsed_ms) catch return;
    bridge_tool_lines.append(bridge_gpa, line) catch bridge_gpa.free(line);
}

const RunThreadArgs = struct {
    model: *Model,
    task: []const u8,
};

fn runThreadMain(args: RunThreadArgs) void {
    defer bridge_turn_done.store(true, .release);
    const self = args.model;
    const messages = &self.messages;
    var err_detail: ?[]const u8 = null;

    var a = Agent.init(&self.ctx, self.arena, &self.provider, &self.cfg, &self.reg, self.tool_defs) catch |err| {
        self.finishTurn(std.fmt.allocPrint(self.arena, "[error: {s}]", .{@errorName(err)}) catch "[error]");
        return;
    };
    defer a.deinit();
    a.on_token = onToken;
    a.on_tool_call = onToolCall;
    a.on_tool_result = onToolResult;
    a.stop_flag = &bridge_stop_flag;

    const resp = a.run(messages, args.task, &err_detail) catch |err| {
        const text = if (err_detail) |d|
            std.fmt.allocPrint(self.arena, "[error: {s}]", .{d}) catch "[error]"
        else
            std.fmt.allocPrint(self.arena, "[error: {s}]", .{@errorName(err)}) catch "[error]";
        self.finishTurn(text);
        return;
    };
    self.finishTurn(resp.message.content orelse "");
}

/// One rendered line of session-permanent transcript (a completed turn's
/// text, or a tool-call/result line). `fence_lang` is non-null for lines
/// inside a fenced code block: they render through the syntax highlighter
/// instead of getting the dim fence style.
const Line = struct {
    text: []const u8,
    dim: bool = false,
    fence_lang: ?[]const u8 = null,
};

/// One entry in the `/model` picker: a provider/model pair flattened out of
/// `Config.providers` so the picker can filter and sort without walking the
/// nested map on every keystroke.
const ModelCandidate = struct {
    provider: []const u8,
    model: []const u8,
    display: []const u8,
    /// Preformatted once into session-lifetime memory. Vaxis cells borrow
    /// grapheme slices until the frame is flushed, so picker rows must not
    /// point into a draw function's stack buffer.
    label: []const u8,
    context_window: u32,
    cost_in: ?f64,
    cost_out: ?f64,
};

/// Flattens every configured provider's models into one list, in config
/// order (providers, then models within a provider), which is what makes the
/// picker's unfiltered list read as grouped-by-provider without a separate
/// sort pass.
fn buildModelCandidates(arena: std.mem.Allocator, cfg: *const config.Config) ![]const ModelCandidate {
    var out: std.ArrayList(ModelCandidate) = .empty;
    var pit = cfg.providers.iterator();
    while (pit.next()) |pentry| {
        var mit = pentry.value_ptr.models.iterator();
        while (mit.next()) |mentry| {
            const display = mentry.value_ptr.display orelse mentry.key_ptr.*;
            const label = if (mentry.value_ptr.cost_per_1m_input != null or mentry.value_ptr.cost_per_1m_output != null)
                try std.fmt.allocPrint(arena, "{s}/{s}  {d} ctx  ${d}/${d} per 1M", .{
                    pentry.key_ptr.*,
                    display,
                    mentry.value_ptr.context_window,
                    mentry.value_ptr.cost_per_1m_input orelse 0,
                    mentry.value_ptr.cost_per_1m_output orelse 0,
                })
            else
                try std.fmt.allocPrint(arena, "{s}/{s}  {d} ctx", .{ pentry.key_ptr.*, display, mentry.value_ptr.context_window });
            try out.append(arena, .{
                .provider = pentry.key_ptr.*,
                .model = mentry.key_ptr.*,
                .display = display,
                .label = label,
                .context_window = mentry.value_ptr.context_window,
                .cost_in = mentry.value_ptr.cost_per_1m_input,
                .cost_out = mentry.value_ptr.cost_per_1m_output,
            });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Case-insensitive subsequence match ("kc3" finds "kimi-k3"): the same
/// forgiving-order fuzzy match the web UI's command palette and saved-prompt
/// list already use (`fuzzyMatch` in `tools/zig/webui/app.js`), so `/model`
/// behaves like the picker it is modeled on rather than inventing a second
/// notion of "fuzzy" for the terminal.
fn fuzzyMatch(query: []const u8, haystack: []const u8) bool {
    if (query.len == 0) return true;
    var qi: usize = 0;
    for (haystack) |c| {
        if (qi >= query.len) break;
        if (std.ascii.toLower(c) == std.ascii.toLower(query[qi])) qi += 1;
    }
    return qi == query.len;
}

test "fuzzyMatch is a case-insensitive subsequence match" {
    try std.testing.expect(fuzzyMatch("", "kimi-k3"));
    try std.testing.expect(fuzzyMatch("kk3", "kimi-k3"));
    try std.testing.expect(fuzzyMatch("K3", "kimi-k3"));
    try std.testing.expect(fuzzyMatch("moon k3", "moonshot k3-code"));
    try std.testing.expect(!fuzzyMatch("xyz", "kimi-k3"));
    try std.testing.expect(!fuzzyMatch("3k", "kimi-k3")); // order matters
}

test "buildModelCandidates flattens providers in config order, one entry per model" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg = config.Config{};
    try cfg.providers.put(arena, "kimi-k3", try config.Provider.single(arena, "kimi-k3", "https://api.moonshot.ai/v1", .openai_compat, "kimi-k3", .{
        .context_window = 1048576,
        .cost_per_1m_input = 3,
        .cost_per_1m_output = 15,
        .display = "moonshotai/kimi-k3",
    }));
    try cfg.providers.put(arena, "deepseek", try config.Provider.single(arena, "deepseek", "https://api.deepseek.com", .openai_compat, "deepseek-chat", .{
        .context_window = 65536,
    }));

    const cands = try buildModelCandidates(arena, &cfg);
    try std.testing.expectEqual(@as(usize, 2), cands.len);
    try std.testing.expectEqualStrings("kimi-k3", cands[0].provider);
    try std.testing.expectEqualStrings("moonshotai/kimi-k3", cands[0].display); // display overrides the bare model id
    try std.testing.expectEqualStrings("kimi-k3/moonshotai/kimi-k3  1048576 ctx  $3/15 per 1M", cands[0].label);
    try std.testing.expectEqual(@as(?f64, 3), cands[0].cost_in);
    try std.testing.expectEqualStrings("deepseek", cands[1].provider);
    try std.testing.expectEqualStrings("deepseek-chat", cands[1].display); // no display set: falls back to the model id
    try std.testing.expectEqual(@as(?f64, null), cands[1].cost_in);
}

// ---------------------------------------------------------------------
// Slash-command registry: the single source of truth for what `submit`
// dispatches and what `/help` prints. Adding an entry here is the whole
// job — dispatch and the generated help list both derive from it, so a
// command can no longer ship undocumented (the hazard docs/prds/0005-repl-tui.md
// tracked against the old hand-maintained `printHelp` prose).
// ---------------------------------------------------------------------

/// What a matched command does. Commands with bespoke UI or plumbing get
/// their own arm that `runCommand` switches on; the internal `cmd_*` WASM
/// tools (the same ones the CLI subcommands invoke) share one `.tool` arm
/// carrying the tool name and its fixed argument string.
const CommandAction = union(enum) {
    quit,
    help,
    /// Opens the fuzzy provider/model picker, seeded with any args given.
    model,
    workflows,
    workflow,
    /// Routes into a goal-design agent turn (see `runGoalTask`).
    goal,
    /// Prints usage, or runs the measurement loop as a normal agent task.
    autoresearch,
    /// Runs the named internal `cmd_*` tool via `runInternalTool`.
    tool: struct { name: []const u8, args: []const u8 },
};

/// One slash command the REPL understands.
const CommandSpec = struct {
    /// Primary spelling, leading slash included, matched exactly.
    name: []const u8,
    /// Alternate spellings, matched the same way ("?", bare "exit").
    aliases: []const []const u8 = &.{},
    /// Whether "<spelling> <args>" also matches, with the trimmed
    /// remainder handed to the action.
    takes_args: bool = false,
    /// Shown after the spellings in /help ("[query]", "<intent>"); purely
    /// documentation, not parsed.
    arg_hint: []const u8 = "",
    /// One line for the generated /help list. Never empty (tested).
    help: []const u8,
    action: CommandAction,
};

const command_registry = [_]CommandSpec{
    .{ .name = "/help", .aliases = &.{"?"}, .help = "show this help", .action = .help },
    .{ .name = "/model", .takes_args = true, .arg_hint = "[query]", .help = "switch provider/model (fuzzy picker; Enter picks, Esc cancels)", .action = .model },
    .{ .name = "/workflows", .help = "list reusable prompt workflows", .action = .workflows },
    .{ .name = "/workflow", .takes_args = true, .arg_hint = "<name> [args]", .help = "run a workflow (expands {{args}} then runs as a task)", .action = .workflow },
    .{ .name = "/sessions", .help = "list saved sessions", .action = .{ .tool = .{ .name = "cmd_sessions", .args = "" } } },
    .{ .name = "/graph", .help = "list knowledge-graph entries", .action = .{ .tool = .{ .name = "cmd_graph", .args = "list" } } },
    .{ .name = "/status", .help = "show configuration and state status", .action = .{ .tool = .{ .name = "cmd_status", .args = "" } } },
    .{ .name = "/plugins", .help = "list installed plugins", .action = .{ .tool = .{ .name = "cmd_plugins", .args = "" } } },
    .{ .name = "/goal", .takes_args = true, .arg_hint = "<intent>", .help = "design and persist a structured goal", .action = .goal },
    .{ .name = "/autoresearch", .takes_args = true, .arg_hint = "...", .help = "measurement loop (see /autoresearch --help)", .action = .autoresearch },
    .{ .name = "/quit", .aliases = &.{ "/exit", "/q", "exit", "quit" }, .help = "leave the REPL", .action = .quit },
};

/// A registry hit: which entry matched, plus whatever followed the
/// matched spelling (trimmed; empty when nothing did).
const ParsedCommand = struct {
    spec: *const CommandSpec,
    args: []const u8,
};

/// Matches `input` against one spelling of `spec`: exact, or
/// "<spelling> <args>" when the spec takes arguments. Returns the trimmed
/// remainder on a match, null otherwise ("/modelx" must not match "/model").
fn matchSpelling(spec: *const CommandSpec, spelling: []const u8, input: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, input, spelling)) return "";
    if (spec.takes_args and input.len > spelling.len and
        std.mem.startsWith(u8, input, spelling) and input[spelling.len] == ' ')
    {
        return std.mem.trim(u8, input[spelling.len..], " ");
    }
    return null;
}

/// Registry lookup for a submitted line: trims, then tries every spelling
/// of every entry. Null means "not a command" — bare text is a task for the
/// agent, and `submit` reports unrecognized /slash input instead of sending
/// it (see `looksLikeSlashCommand`).
fn parseCommand(task: []const u8) ?ParsedCommand {
    const input = std.mem.trim(u8, task, " \t");
    for (&command_registry) |*spec| {
        if (matchSpelling(spec, spec.name, input)) |args| return .{ .spec = spec, .args = args };
        for (spec.aliases) |alias| {
            if (matchSpelling(spec, alias, input)) |args| return .{ .spec = spec, .args = args };
        }
    }
    return null;
}

/// True for input that was clearly meant as a slash command (leading '/'):
/// when the registry lookup missed, this is what keeps a typo'd command out
/// of the LLM conversation. Bare text without the slash stays a task.
fn looksLikeSlashCommand(task: []const u8) bool {
    const input = std.mem.trim(u8, task, " \t");
    return input.len > 0 and input[0] == '/';
}

/// One registry spelling that matched a Tab-complete prefix, paired with
/// the spec it belongs to (needed to know `takes_args` when a single match
/// completes the line).
const SpellingMatch = struct { spelling: []const u8, spec: *const CommandSpec };

/// Comfortably above the registry's total spelling count (name + aliases,
/// currently under 20); completion is a UI nicety, so silently truncating
/// past this is fine rather than worth an allocator.
const max_completions = 32;

/// Every registry spelling (name or alias) starting with `prefix`, in
/// registry order. Written into `out`; returns the matched slice.
fn matchingSpellings(prefix: []const u8, out: *[max_completions]SpellingMatch) []const SpellingMatch {
    var n: usize = 0;
    for (&command_registry) |*spec| {
        if (n < out.len and std.mem.startsWith(u8, spec.name, prefix)) {
            out[n] = .{ .spelling = spec.name, .spec = spec };
            n += 1;
        }
        for (spec.aliases) |alias| {
            if (n < out.len and std.mem.startsWith(u8, alias, prefix)) {
                out[n] = .{ .spelling = alias, .spec = spec };
                n += 1;
            }
        }
    }
    return out[0..n];
}

/// The longest prefix shared by every match, for completing "/s" toward
/// "/sessions" without picking one of several candidates arbitrarily.
fn longestCommonPrefix(matches: []const SpellingMatch) []const u8 {
    if (matches.len == 0) return "";
    var prefix = matches[0].spelling;
    for (matches[1..]) |m| {
        var i: usize = 0;
        while (i < prefix.len and i < m.spelling.len and prefix[i] == m.spelling[i]) : (i += 1) {}
        prefix = prefix[0..i];
    }
    return prefix;
}

/// Widest "spellings [hint]" cell in the registry, computed at comptime so
/// the generated help columns stay aligned no matter what gets added.
const help_names_width = blk: {
    var w: usize = 0;
    for (command_registry) |spec| {
        var n = spec.name.len;
        for (spec.aliases) |a| n += 2 + a.len;
        if (spec.arg_hint.len > 0) n += 1 + spec.arg_hint.len;
        if (n > w) w = n;
    }
    break :blk w;
};

/// The command section of `/help`, generated from `command_registry`: one
/// line per entry — every spelling comma-separated, the arg hint, then the
/// help text in a common column. Returned as one newline-joined slice the
/// caller owns.
fn buildCommandHelp(alloc: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "commands:");
    for (command_registry) |spec| {
        try out.appendSlice(alloc, "\n  ");
        var col: usize = spec.name.len;
        try out.appendSlice(alloc, spec.name);
        for (spec.aliases) |alias| {
            try out.appendSlice(alloc, ", ");
            try out.appendSlice(alloc, alias);
            col += 2 + alias.len;
        }
        if (spec.arg_hint.len > 0) {
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, spec.arg_hint);
            col += 1 + spec.arg_hint.len;
        }
        while (col < help_names_width + 2) : (col += 1) try out.append(alloc, ' ');
        try out.appendSlice(alloc, spec.help);
    }
    return out.toOwnedSlice(alloc);
}

test "every command registry entry is documented" {
    for (command_registry) |spec| {
        try std.testing.expect(spec.name.len > 0);
        try std.testing.expect(spec.help.len > 0);
    }
}

test "generated help mentions every command spelling and help line" {
    const text = try buildCommandHelp(std.testing.allocator);
    defer std.testing.allocator.free(text);
    for (command_registry) |spec| {
        try std.testing.expect(std.mem.indexOf(u8, text, spec.name) != null);
        for (spec.aliases) |alias| {
            try std.testing.expect(std.mem.indexOf(u8, text, alias) != null);
        }
        try std.testing.expect(std.mem.indexOf(u8, text, spec.help) != null);
    }
}

test "parseCommand recognizes the REPL quit set" {
    const quit_spellings = [_][]const u8{ "/quit", "/exit", "/q", "exit", "quit", "  /q  " };
    for (quit_spellings) |s| {
        const pc = parseCommand(s) orelse return error.TestExpectedCommand;
        try std.testing.expect(pc.spec.action == .quit);
    }
    // A leading slash distinguishes a command from the same word as a task;
    // a bare word that is not a quit command is a task.
    try std.testing.expect(parseCommand("/quitnow") == null);
    try std.testing.expect(parseCommand("exit handling is next") == null);
    try std.testing.expect(parseCommand("") == null);
    try std.testing.expect(parseCommand("please exit") == null);
    // Quit takes no arguments, so "/quit now" is not a quit command.
    try std.testing.expect(parseCommand("/quit now") == null);
}

test "parseCommand matches names, aliases, and arguments" {
    const help = parseCommand("/help") orelse return error.TestExpectedCommand;
    try std.testing.expect(help.spec.action == .help);
    const qmark = parseCommand("?") orelse return error.TestExpectedCommand;
    try std.testing.expect(qmark.spec.action == .help);
    // "?" takes no args: "? something" is a task, not a help request.
    try std.testing.expect(parseCommand("? something") == null);

    const bare_model = parseCommand("/model") orelse return error.TestExpectedCommand;
    try std.testing.expect(bare_model.spec.action == .model);
    try std.testing.expectEqualStrings("", bare_model.args);
    const seeded = parseCommand("/model kimi k3 ") orelse return error.TestExpectedCommand;
    try std.testing.expectEqualStrings("kimi k3", seeded.args);

    const goal = parseCommand("/goal fix the failing eval") orelse return error.TestExpectedCommand;
    try std.testing.expect(goal.spec.action == .goal);
    try std.testing.expectEqualStrings("fix the failing eval", goal.args);

    const sessions = parseCommand("/sessions") orelse return error.TestExpectedCommand;
    try std.testing.expectEqualStrings("cmd_sessions", sessions.spec.action.tool.name);
    // The internal cmd_* commands take no free-form arguments yet.
    try std.testing.expect(parseCommand("/sessions foo") == null);

    try std.testing.expect(parseCommand("hello world") == null);
    try std.testing.expect(parseCommand("/nope") == null);
}

test "looksLikeSlashCommand separates typo'd commands from tasks" {
    try std.testing.expect(looksLikeSlashCommand("/nope"));
    try std.testing.expect(looksLikeSlashCommand("  /nope  "));
    try std.testing.expect(!looksLikeSlashCommand("hello /world"));
    try std.testing.expect(!looksLikeSlashCommand(""));
}

test "matchingSpellings finds a unique prefix and every ambiguous one" {
    var buf: [max_completions]SpellingMatch = undefined;

    const unique = matchingSpellings("/hel", &buf);
    try std.testing.expectEqual(@as(usize, 1), unique.len);
    try std.testing.expectEqualStrings("/help", unique[0].spelling);

    // "/s" hits /sessions and /status; "?" alone lands on /help's alias.
    const ambiguous = matchingSpellings("/s", &buf);
    try std.testing.expectEqual(@as(usize, 2), ambiguous.len);
    try std.testing.expectEqualStrings("/sessions", ambiguous[0].spelling);
    try std.testing.expectEqualStrings("/status", ambiguous[1].spelling);

    try std.testing.expectEqual(@as(usize, 0), matchingSpellings("/nope", &buf).len);
}

test "longestCommonPrefix completes toward the shared stem or nowhere" {
    var buf: [max_completions]SpellingMatch = undefined;
    const s_matches = matchingSpellings("/s", &buf);
    // /sessions vs /status share only "/s" — no further completion possible.
    try std.testing.expectEqualStrings("/s", longestCommonPrefix(s_matches));

    var buf2: [max_completions]SpellingMatch = undefined;
    const wo_matches = matchingSpellings("/wo", &buf2);
    // /workflows vs /workflow share the full shorter spelling.
    try std.testing.expectEqualStrings("/workflow", longestCommonPrefix(wo_matches));

    try std.testing.expectEqualStrings("", longestCommonPrefix(&.{}));
}

/// `CLANKER_THEME` picks a palette by name ("mocha"/"catppuccin", "latte",
/// "frappe", "macchiato", "tokyonight", "storm", "day", "mono", "default").
/// An env var rather than a flag because the REPL is also reached
/// through `clanker` with no arguments, and a theme is a property of the
/// terminal you are sitting at rather than of one invocation.
fn themeName(environ_map: *const std.process.Environ.Map) ?[]const u8 {
    const v = environ_map.get("CLANKER_THEME") orelse return null;
    return if (v.len > 0) v else null;
}

const Model = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    ctx: client.Ctx,
    cfg: config.Config,
    provider: config.Provider,
    reg: registry.Registry,
    tool_defs: []const types.ToolDef,
    messages: std.ArrayList(types.Message) = .empty,
    /// Where this conversation persists (`state/sessions/<id>.json`), written
    /// after every completed turn; null only when the sessions module is off
    /// and no `--session` was given.
    session_id: ?[]const u8 = null,
    /// Unix seconds when this conversation was first created — preserved
    /// across resume so a continued session keeps its original birth date.
    session_created: i64 = 0,
    /// First task of the conversation, trimmed — the line `clanker sessions`
    /// shows. Kept from a loaded session; set once on the first submit.
    session_title: []const u8 = "",

    lines: std.ArrayList(Line) = .empty,
    text_field: vxfw.TextField,
    thread: ?std.Thread = null,
    spinner_frame: u8 = 0,
    status_buf: [192]u8 = undefined,
    /// Between a bracketed-paste start/end pair. `vxfw.TextField` is a
    /// single-line widget (Enter either submits or is a no-op — there is no
    /// way to insert a literal newline into one), so a multi-line paste's
    /// embedded Enters would otherwise submit the task early, mid-paste.
    /// While true, Enter is folded to a space and inserted instead.
    in_paste: bool = false,
    /// vxfw.App.run() unconditionally enables mouse reporting (setMouseMode),
    /// which takes click-drag away from the terminal's own text selection in
    /// most emulators (Konsole included) — so this app owes its own
    /// selection + clipboard copy in exchange for grabbing the mouse.
    /// Row-major, drag-to-select over the transcript region only (not the
    /// status line or input box); copies via OSC 52 on release.
    mouse_down: bool = false,
    has_selection: bool = false,
    sel_start: vxfw.Point = .{ .row = 0, .col = 0 },
    sel_end: vxfw.Point = .{ .row = 0, .col = 0 },
    /// The last frame's rendered cells, kept only to read back the plain
    /// text under a selection (surface.readCell) — its backing arena is the
    /// draw arena, valid until the next redraw actually runs, which is
    /// after event handling in vxfw.App's own loop.
    last_surface: ?vxfw.Surface = null,
    transcript_top: u16 = 0,
    transcript_bottom: u16 = 0,
    /// Manual scrollback anchor: null while the transcript follows its tail
    /// (the default — new output scrolls into view as it arrives). Non-null
    /// pins the visible window to end at this absolute line index
    /// (exclusive), so a streaming turn can append to `lines` without
    /// yanking a reader back down. PgUp/PgDn/Home/End/Esc drive it; the
    /// draw re-clamps it every frame (a resize changes what fits).
    view_end: ?usize = null,

    /// Submitted-task history for the Up/Down recall every REPL has.
    /// `hist_idx == history.len` means "editing a fresh line", and the
    /// in-progress draft is parked in `hist_draft` while browsing so Esc
    /// (which clears the field) can't destroy unsent text.
    history: std.ArrayList([]const u8) = .empty,
    hist_idx: usize = 0,
    hist_draft: []const u8 = "",

    /// Non-null while an OSC 52 clipboard read is awaited (some terminals
    /// answer on a delay, some never answer). A second paste shortcut while
    /// pending re-sends the request, which is harmless.
    awaiting_clipboard: bool = false,

    /// Every configured provider/model, flattened once at startup (config
    /// does not change mid-session). `/model` opens `picker_open`, and while
    /// it's true every key press is routed to `handlePickerKey` instead of
    /// the normal input handling below — a small modal, not a second widget.
    model_candidates: []const ModelCandidate = &.{},
    picker_open: bool = false,
    picker_query: std.ArrayList(u8) = .empty,
    picker_selected: usize = 0,

    fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    /// Called from the background run thread once Agent.run returns
    /// (success or error alike): folds the streamed buffer and any tool
    /// lines into permanent `lines`, clears the live streaming state.
    fn finishTurn(self: *Model, final_text: []const u8) void {
        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        // Tool lines are allocated from bridge_gpa by the worker callbacks;
        // the transcript owns arena copies so the originals can be freed
        // here instead of living (and leaking) for the process lifetime.
        for (bridge_tool_lines.items) |l| {
            const copy = self.arena.dupe(u8, l) catch l;
            self.lines.append(self.arena, .{ .text = copy, .dim = true }) catch {};
            if (copy.ptr != l.ptr) bridge_gpa.free(l);
        }
        bridge_tool_lines.clearRetainingCapacity();
        const answer = if (final_text.len > 0) final_text else bridge_stream_buf.items;
        const owned = self.arena.dupe(u8, answer) catch answer;
        // Fold the answer's markdown into one transcript line per source
        // line: the fence is where highlighting attaches, so lines must
        // know which fence (if any) they came from.
        var in_fence = false;
        var fence_lang: []const u8 = "";
        var first = true;
        var it = std.mem.splitScalar(u8, owned, '\n');
        while (it.next()) |src_line| {
            const trimmed = std.mem.trim(u8, src_line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "```")) {
                if (in_fence) {
                    in_fence = false;
                } else {
                    in_fence = true;
                    fence_lang = std.mem.trim(u8, trimmed[3..], " ");
                }
                continue; // fence markers themselves are not shown
            }
            const lang: ?[]const u8 = if (in_fence) fence_lang else null;
            const prefixed = if (first)
                std.fmt.allocPrint(self.arena, "\xe2\x80\xba {s}", .{src_line}) catch src_line
            else
                src_line;
            first = false;
            self.lines.append(self.arena, .{ .text = prefixed, .fence_lang = lang }) catch {};
        }
        bridge_stream_buf.clearRetainingCapacity();
    }

    /// Writes the conversation to `state/sessions/<id>.json`, called after
    /// every completed turn (never mid-turn: the caller joins the worker
    /// first, so `self.messages` is stable). A failed write is reported at
    /// error level — the only log level this REPL leaves enabled — and the
    /// next turn's save retries; it must not kill the session over a disk
    /// hiccup.
    fn persistSession(self: *Model) void {
        const sid = self.session_id orelse return;
        if (!self.cfg.modules.sessions) return;
        session_mod.compactMessages(&self.messages, session_mod.max_session_tokens);
        const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .real).nanoseconds, 1_000_000_000));
        session_mod.saveSession(self.io, self.gpa, self.arena, std.Io.Dir.cwd(), .{
            .id = sid,
            .title = self.session_title,
            .messages = self.messages.items,
            .created = self.session_created,
            .updated = updated,
        }) catch |err| {
            log.log(.error_, "session '{s}' save failed: {s}", .{ sid, @errorName(err) });
        };
    }

    fn submit(self: *Model, ctx: *vxfw.EventContext) !void {
        // One turn at a time: runThreadMain's finishTurn touches self.lines
        // and self.arena from the background thread. self.arena is a plain
        // ArenaAllocator (no internal locking) and self.lines is a plain
        // ArrayList, so a second in-flight turn spawned here would race the
        // first turn's background thread on both — not just contend for
        // bridge_mutex-guarded state, but corrupt the arena's free-list and the
        // transcript's backing storage. Leaving typed input untouched (no
        // toOwnedSlice yet) is a no-op keystroke while the picker is modal
        // for the same reason: nothing to submit into.
        bridge_mutex.lockUncancelable(bridge_io);
        const already_streaming = bridge_streaming;
        bridge_mutex.unlock(bridge_io);
        if (already_streaming) return;

        const task = try self.text_field.toOwnedSlice();
        defer self.gpa.free(task);
        if (task.len == 0) return;
        self.text_field.reset();

        // Slash commands dispatch through `command_registry` — one lookup
        // covering every spelling, instead of literal matches strewn about.
        // An unrecognized /command is reported in the transcript rather than
        // sent to the LLM (a typo'd command is not a task); bare text without
        // the slash is still a task, bare "exit"/"quit" included (they are
        // registry aliases of /quit).
        if (parseCommand(task)) |pc| {
            try self.runCommand(ctx, pc, task);
            return;
        }
        if (looksLikeSlashCommand(task)) {
            self.lines.append(self.arena, .{
                .text = std.fmt.allocPrint(self.arena, "[unknown command: {s} — try /help]", .{std.mem.trim(u8, task, " \t")}) catch "[unknown command — try /help]",
                .dim = true,
            }) catch {};
            return;
        }

        try self.submitTask(ctx, task);
    }

    /// Executes one registry command from `submit`. `task` is the raw
    /// submitted line, which /autoresearch re-submits as an agent task when
    /// given real arguments.
    fn runCommand(self: *Model, ctx: *vxfw.EventContext, pc: ParsedCommand, task: []const u8) !void {
        switch (pc.spec.action) {
            // A quit command has to set `ctx.quit`, rather than merely stop
            // the input handler: App.run returns on that flag and its
            // caller's defer then restores the alternate screen, raw input,
            // mouse mode, and bracketed paste before the shell regains the
            // terminal.
            .quit => ctx.quit = true,
            .help => self.printHelp(),
            // "/model" alone opens the picker on the full list; "/model kimi"
            // seeds it with a starting query, so a remembered partial name is
            // one Enter away instead of a blank list to type into again.
            .model => self.openModelPicker(pc.args),
            // /goal <intent> designs a goal through the agent (which calls
            // the goal tool to persist it), matching `clanker goal
            // "<intent>"`. Runs as a normal task so it streams like any
            // other turn.
            .goal => {
                if (pc.args.len == 0) {
                    self.lines.append(self.arena, .{ .text = "usage: /goal <intent> — e.g. /goal fix the failing eval", .dim = true }) catch {};
                    return;
                }
                _ = self.runGoalTask(ctx, pc.args);
            },
            .autoresearch => {
                if (pc.args.len == 0 or std.mem.eql(u8, pc.args, "--help") or std.mem.eql(u8, pc.args, "-h")) {
                    self.lines.append(self.arena, .{ .text = "usage: /autoresearch --target <file> --harness \"<cmd>\" [--iters N] [--dry-run]", .dim = true }) catch {};
                    self.lines.append(self.arena, .{ .text = "  runs the measurement loop; use --dry-run to validate without LLM", .dim = true }) catch {};
                    self.lines.append(self.arena, .{ .text = "  example: /autoresearch --target tools/zig/calculator.zig --harness \"sh -c 'echo score: 1.0'\" --dry-run", .dim = true }) catch {};
                    return;
                }
                try self.submitTask(ctx, task);
            },
            .workflows => {
                _ = self.runWorkflowsTool("");
            },
            .workflow => {
                if (pc.args.len == 0) {
                    self.lines.append(self.arena, .{ .text = "usage: /workflow <name> [args]  — try /workflows to list", .dim = true }) catch {};
                    return;
                }
                const space = std.mem.indexOfScalar(u8, pc.args, ' ');
                const wf_name = if (space) |i| std.mem.trim(u8, pc.args[0..i], " \t") else pc.args;
                const wf_args = if (space) |i| std.mem.trim(u8, pc.args[i + 1 ..], " \t") else "";
                const prompt = self.expandWorkflow(wf_name, wf_args) catch |err| {
                    self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "[workflow '{s}': {s}]", .{ wf_name, @errorName(err) }) catch "[workflow failed]", .dim = true }) catch {};
                    return;
                } orelse {
                    self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "[no workflow named '{s}' — try /workflows]", .{wf_name}) catch "[unknown workflow]", .dim = true }) catch {};
                    return;
                };
                defer self.gpa.free(prompt);
                try self.submitTask(ctx, prompt);
            },
            // /sessions, /graph, /status, /plugins run the same internal
            // `cmd_*` WASM tools the CLI subcommands invoke, so the REPL is
            // not a walled-off corner of clanker. Output is folded into the
            // transcript as dim lines, exactly like a tool result.
            .tool => |t| _ = self.runInternalTool(t.name, t.args),
        }
    }

    /// Runs one internal `cmd_*` WASM tool ({"args":"<text>"} -> {"text":"..."})
    /// and folds its output into the transcript as dim lines. Returns true so
    /// submit treats it as handled. A failure is reported in the transcript
    /// rather than bubbling: a broken internal tool should not take down the
    /// REPL, just be visible.
    fn runInternalTool(self: *Model, tool_name: []const u8, args: []const u8) bool {
        const mod = runtime.loadNamedTool(
            self.gpa,
            self.io,
            self.arena,
            self.ctx.environ_map,
            &self.cfg,
            &self.reg,
            tool_name,
            null,
        ) catch |err| {
            self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "[{s}: {s}]", .{ tool_name, @errorName(err) }) catch "[internal tool failed]", .dim = true }) catch {};
            return true;
        };
        defer mod.deinit();

        var ibuf: [8192]u8 = undefined;
        var iw: std.Io.Writer = .fixed(&ibuf);
        var is = std.json.Stringify{ .writer = &iw, .options = .{} };
        is.beginObject() catch return true;
        is.objectField("args") catch return true;
        is.write(args) catch return true;
        is.endObject() catch return true;

        const raw = mod.executeTool(ibuf[0..iw.end]) catch |err| {
            self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "[{s}: {s}]", .{ tool_name, @errorName(err) }) catch "[internal tool failed]", .dim = true }) catch {};
            return true;
        };
        defer self.gpa.free(raw);

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.arena, raw, .{ .ignore_unknown_fields = true }) catch {
            self.lines.append(self.arena, .{ .text = "[internal tool returned unparseable output]", .dim = true }) catch {};
            return true;
        };
        if (parsed != .object) {
            self.lines.append(self.arena, .{ .text = "[internal tool returned an empty result]", .dim = true }) catch {};
            return true;
        }
        var ok = false;
        if (parsed.object.get("ok")) |k| {
            if (k == .bool) ok = k.bool;
        }
        if (!ok) {
            const detail = if (parsed.object.get("error")) |e| (if (e == .string) e.string else "unknown") else "unknown";
            self.lines.append(self.arena, .{ .text = std.fmt.allocPrint(self.arena, "[{s}: {s}]", .{ tool_name, detail }) catch "[internal tool failed]", .dim = true }) catch {};
            return true;
        }
        const text = parsed.object.get("text") orelse {
            self.lines.append(self.arena, .{ .text = "[internal tool returned no text]", .dim = true }) catch {};
            return true;
        };
        if (text != .string) {
            self.lines.append(self.arena, .{ .text = "[internal tool returned no text]", .dim = true }) catch {};
            return true;
        }
        var it = std.mem.splitScalar(u8, text.string, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            self.lines.append(self.arena, .{ .text = self.arena.dupe(u8, trimmed) catch trimmed, .dim = true }) catch {};
        }
        return true;
    }

    fn runWorkflowsTool(self: *Model, name: []const u8) bool {
        const workflows_mod = @import("../workflows.zig");
        const wfs = workflows_mod.loadAllMerged(self.arena, self.io, self.cfg.agent.workflows_dir) catch {
            self.lines.append(self.arena, .{ .text = "[could not list workflows]", .dim = true }) catch {};
            return true;
        };
        if (name.len == 0) {
            if (wfs.len == 0) {
                self.lines.append(self.arena, .{ .text = "[no workflows found — add markdown files to workflows/]", .dim = true }) catch {};
                return true;
            }
            for (wfs) |wf| {
                const line = if (wf.arg_hint.len > 0)
                    std.fmt.allocPrint(self.arena, "  {s} {s} — {s}", .{ wf.name, wf.arg_hint, wf.description }) catch continue
                else
                    std.fmt.allocPrint(self.arena, "  {s} — {s}", .{ wf.name, wf.description }) catch continue;
                self.lines.append(self.arena, .{ .text = line, .dim = true }) catch {};
            }
            self.lines.append(self.arena, .{ .text = "  (run one with /workflow <name> [args])", .dim = true }) catch {};
            return true;
        }
        return true;
    }

    fn expandWorkflow(self: *Model, name: []const u8, args: []const u8) !?[]u8 {
        const workflows_mod = @import("../workflows.zig");
        const wfs = try workflows_mod.loadAllMerged(self.arena, self.io, self.cfg.agent.workflows_dir);
        const wf = workflows_mod.findByName(wfs, name) orelse return null;
        const expanded = try workflows_mod.instantiate(self.arena, wf.body, args);
        return try self.gpa.dupe(u8, expanded);
    }

    /// Submits a goal-design task through the agent, exactly like
    /// `clanker goal "<intent>"`. Runs as a normal turn so it streams, is
    /// saved to the session, and can be stopped like any other task.
    fn runGoalTask(self: *Model, ctx: *vxfw.EventContext, intent: []const u8) bool {
        const task = std.fmt.allocPrint(
            self.arena,
            "Design and persist a structured goal for: {s}\n\nDefine all five fields (objective, completion_criterion, proof, boundaries, stop_rule) and call the goal tool to persist it.",
            .{intent},
        ) catch return true;
        self.submitTask(ctx, task) catch {
            self.lines.append(self.arena, .{ .text = "[could not start the goal task]", .dim = true }) catch {};
            return true;
        };
        return true;
    }

    /// The tail of `submit` that runs a task: echoes it, records it in
    /// history, and spawns the worker thread. Extracted so slash commands like
    /// /goal can submit a synthesized task without duplicating the plumbing.
    ///
    /// self.thread is assigned here and read by finishTurn on the background
    /// thread (to detach itself); spawning and storing the handle under the
    /// same lock finishTurn locks before reading it gives that read a
    /// happens-after relationship to this write. Doing the assignment outside
    /// the lock let a background thread that fails fast in Agent.init race
    /// finishTurn's read of self.thread against this store, seeing it still
    /// null and leaking the handle.
    fn submitTask(self: *Model, ctx: *vxfw.EventContext, task: []const u8) !void {
        // Submitting snaps a scrolled-up view back to the tail: the echoed
        // task and the streamed reply land there, and hiding them behind a
        // frozen window would make Enter look like it did nothing.
        self.view_end = null;
        self.lines.append(self.arena, .{ .text = try std.fmt.allocPrint(self.arena, "clanker> {s}", .{task}) }) catch {};
        self.history.append(self.arena, try self.arena.dupe(u8, task)) catch {};
        self.hist_idx = self.history.items.len;
        self.hist_draft = "";

        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        bridge_streaming = true;
        bridge_stream_buf.clearRetainingCapacity();
        bridge_tool_lines.clearRetainingCapacity();
        bridge_stop_flag.store(false, .release);
        bridge_turn_done.store(false, .release);
        errdefer bridge_streaming = false;

        const owned_task = try self.arena.dupe(u8, task);
        if (self.session_title.len == 0) {
            self.session_title = std.mem.trim(u8, owned_task[0..@min(owned_task.len, 60)], " \t\r\n");
        }
        self.thread = try std.Thread.spawn(.{}, runThreadMain, .{RunThreadArgs{ .model = self, .task = owned_task }});

        // Kick off the tick heartbeat that picks up streamed deltas.
        try ctx.tick(50, self.widget());
    }

    /// Writes the conversation to `state/sessions/<id>.json` so a later
    /// `--session <id>` or `--continue` resumes it. Called once when the app
    /// is about to return (every quit path — /quit, Ctrl-C while idle — ends
    /// in `app.run` returning). A fresh conversation gets an id minted here;
    /// a resumed one keeps the id it was loaded under. Nothing is written
    /// when the sessions module is off, the id is invalid, or there is no
    /// conversation yet.
    fn saveConversation(self: *Model) void {
        if (!self.cfg.modules.sessions) return;
        var has_turn = false;
        for (self.messages.items) |m| {
            if (m.role != .system) {
                has_turn = true;
                break;
            }
        }
        // A freshly opened REPL quit before its first turn has nothing worth
        // persisting (at most the injected system prompt).
        if (!has_turn) return;

        const id = self.session_id orelse (mintSessionId(self.io, self.arena) catch {
            log.log(.warn, "repl: could not mint a session id; conversation not saved", .{});
            return;
        });
        if (!validSessionId(id)) {
            log.log(.warn, "repl: refusing to save under invalid session id '{s}'", .{id});
            return;
        }

        // The system prompt and the tool-call plumbing are internal; the
        // saved transcript is the user/assistant conversation, the same shape
        // `clanker run` writes and `loadSession` reads back (tool-call records
        // stay so a resumed session replays them into the model's history).
        var transcript: std.ArrayList(types.Message) = .empty;
        for (self.messages.items) |m| {
            if (m.role == .system) continue;
            transcript.append(self.arena, m) catch {};
        }
        const title = if (self.session_title.len > 0) self.session_title else blk: {
            var t: []const u8 = "";
            for (transcript.items) |m| {
                if (m.role == .user) {
                    if (m.content) |c| {
                        t = std.mem.trim(u8, c[0..@min(c.len, 60)], " \t\r\n");
                        break;
                    }
                }
            }
            break :blk t;
        };
        const updated: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(self.io, .real).nanoseconds, 1_000_000_000));
        session_mod.saveSession(self.io, self.gpa, self.arena, std.Io.Dir.cwd(), .{
            .id = id,
            .title = title,
            .messages = transcript.items,
            .created = if (self.session_created != 0) self.session_created else updated,
            .updated = updated,
        }) catch |err| {
            log.log(.warn, "repl: session '{s}' not saved: {s}", .{ id, @errorName(err) });
            return;
        };
        self.session_id = id;
    }

    /// The command list is generated from `command_registry`
    /// (`buildCommandHelp`), so a registry entry can never go undocumented —
    /// the property the deleted REPL's generated `:help` had
    /// (docs/prds/0005-repl-tui.md). The key bindings stay hand-written here:
    /// they are wired in the event handler, not the registry.
    fn printHelp(self: *Model) void {
        const commands = buildCommandHelp(self.arena) catch return;
        var it = std.mem.splitScalar(u8, commands, '\n');
        while (it.next()) |line| self.lines.append(self.arena, .{ .text = line, .dim = true }) catch {};
        const keys =
            \\keys:
            \\  Up/Down           recall previous input
            \\  PgUp/PgDn         page the transcript (Home: top; End/Esc: back to tail)
            \\  Ctrl-C            stop the current turn, or quit when idle
            \\  Ctrl-Shift-C      copy the selection (or the input line)
            \\  Ctrl-Shift-V, Shift-Insert   paste from the system clipboard
        ;
        var kit = std.mem.splitScalar(u8, keys, '\n');
        while (kit.next()) |line| self.lines.append(self.arena, .{ .text = line, .dim = true }) catch {};
    }

    fn openModelPicker(self: *Model, seed_query: []const u8) void {
        self.picker_open = true;
        self.picker_query.clearRetainingCapacity();
        self.picker_query.appendSlice(self.arena, seed_query) catch {};
        self.picker_selected = 0;
    }

    fn closeModelPicker(self: *Model) void {
        self.picker_open = false;
        self.picker_query.clearRetainingCapacity();
    }

    /// Candidates whose "provider display" matches the current query, in
    /// `model_candidates` order (config order, so unfiltered is grouped by
    /// provider). Filters into `self.arena` on every keystroke rather than
    /// caching: the candidate list itself is small (one provider's worth of
    /// models, times however many providers are configured — tens, not
    /// thousands), so re-scanning it is cheaper than the bookkeeping to
    /// avoid doing so.
    fn filteredCandidates(self: *Model) []const ModelCandidate {
        var out: std.ArrayList(ModelCandidate) = .empty;
        for (self.model_candidates) |c| {
            var buf: [192]u8 = undefined;
            const haystack = std.fmt.bufPrint(&buf, "{s} {s}", .{ c.provider, c.display }) catch c.display;
            if (fuzzyMatch(self.picker_query.items, haystack)) out.append(self.arena, c) catch break;
        }
        return out.items;
    }

    /// Switches the active provider/model for the *next* turn onward — the
    /// conversation (`self.messages`) is untouched, so the switch lands
    /// mid-session exactly like `--model` does at startup, just later.
    fn applyModelSelection(self: *Model, cand: ModelCandidate) void {
        if (self.cfg.provider(cand.provider)) |p| {
            var np = p.*;
            np.default_model = cand.model;
            self.provider = np;
            self.lines.append(self.arena, .{
                .text = std.fmt.allocPrint(self.arena, "[model: {s}/{s}]", .{ cand.provider, cand.model }) catch "[model switched]",
                .dim = true,
            }) catch {};
        } else |_| {
            // Can't happen: cand.provider always came from cfg.providers in
            // buildModelCandidates, but a config reload mid-session (not
            // currently possible) would make this reachable, so fail quiet
            // rather than unreachable().
            self.lines.append(self.arena, .{ .text = "[model: provider no longer configured]", .dim = true }) catch {};
        }
    }

    fn handlePickerKey(self: *Model, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
        if (key.matches(vaxis.Key.escape, .{})) {
            self.closeModelPicker();
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            const matches = self.filteredCandidates();
            if (matches.len > 0) self.applyModelSelection(matches[@min(self.picker_selected, matches.len - 1)]);
            self.closeModelPicker();
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.up, .{})) {
            if (self.picker_selected > 0) self.picker_selected -= 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.down, .{})) {
            const n = self.filteredCandidates().len;
            if (n > 0 and self.picker_selected + 1 < n) self.picker_selected += 1;
            return ctx.consumeAndRedraw();
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.picker_query.items.len > 0) {
                _ = self.picker_query.pop();
                self.picker_selected = 0;
            }
            return ctx.consumeAndRedraw();
        }
        if (key.text) |t| {
            try self.picker_query.appendSlice(self.arena, t);
            self.picker_selected = 0;
            return ctx.consumeAndRedraw();
        }
        return ctx.consumeAndRedraw();
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => try ctx.requestFocus(self.text_field.widget()),
            .tick => {
                // finishTurn only publishes transcript state. The worker may
                // still be running Agent.deinit after that, so reclaim it on
                // the UI thread before advertising an idle model.
                if (bridge_turn_done.swap(false, .acq_rel)) {
                    if (self.thread) |t| {
                        t.join();
                        self.thread = null;
                    }
                    bridge_mutex.lockUncancelable(bridge_io);
                    bridge_streaming = false;
                    bridge_mutex.unlock(bridge_io);
                    // The worker is joined, so self.messages is stable:
                    // persist the conversation as it stands after this turn.
                    self.persistSession();
                }
                bridge_mutex.lockUncancelable(bridge_io);
                const still_streaming = bridge_streaming;
                bridge_mutex.unlock(bridge_io);
                if (still_streaming) {
                    self.spinner_frame +%= 1;
                    try ctx.tick(50, self.widget());
                }
                ctx.redraw = true;
            },
            .key_press => |key| {
                // The picker is modal: every key goes to it, none of the
                // clipboard/history/quit shortcuts below apply while it's open.
                if (self.picker_open) return self.handlePickerKey(ctx, key);
                // Manual scrollback. PgUp/PgDn page the transcript by a
                // screenful (one line of overlap); Home jumps to the top and
                // End/Esc return to the tail — but Home/End only act on the
                // scroll while already scrolled up, so at the tail they keep
                // their TextField cursor-motion meaning (aliases of
                // Ctrl-A/Ctrl-E there). The paging math is pure
                // (`scrollUpEnd` and friends, below tailStart); this just
                // feeds it the current anchor and last-drawn height.
                if (key.matches(vaxis.Key.page_up, .{})) {
                    self.view_end = scrollUpEnd(self.view_end, self.lineCount(), self.availRows());
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.page_down, .{})) {
                    self.view_end = scrollDownEnd(self.view_end, self.lineCount(), self.availRows());
                    return ctx.consumeAndRedraw();
                }
                if (self.view_end != null and key.matches(vaxis.Key.home, .{})) {
                    self.view_end = scrollHomeEnd(self.lineCount(), self.availRows());
                    return ctx.consumeAndRedraw();
                }
                if (self.view_end != null and (key.matches(vaxis.Key.end, .{}) or key.matches(vaxis.Key.escape, .{}))) {
                    self.view_end = null;
                    return ctx.consumeAndRedraw();
                }
                // Terminal convention: Ctrl+Shift+C copies the current
                // selection (mouse-drag, same path as a drag release),
                // falling back to the whole input line. Plain Ctrl+C keeps
                // its readline meaning (interrupt the turn, quit when idle).
                if (key.matches('c', .{ .ctrl = true, .shift = true })) {
                    try self.copySelectionOrInput(ctx);
                    return ctx.consumeAndRedraw();
                }
                // Paste from the system clipboard. Two routes, tried in
                // order: Ctrl+Shift+V asks the terminal for its OSC 52
                // clipboard (arrives as a .paste event, which is handled
                // below), and Shift+Insert additionally forces a bracketed
                // paste so terminals that answer neither still do something
                // paste-like. Ctrl+V is deliberately not bound: it is the
                // readline "quote next character" prefix and the TextField
                // treats it that way.
                if (key.matches('v', .{ .ctrl = true, .shift = true })) {
                    requestSystemClipboard(ctx.io);
                    self.awaiting_clipboard = true;
                    return ctx.consumeEvent();
                }
                if (key.matches(vaxis.Key.insert, .{ .shift = true })) {
                    self.in_paste = true;
                    requestSystemClipboard(ctx.io);
                    self.awaiting_clipboard = true;
                    return ctx.consumeEvent();
                }
                if (key.matches('c', .{ .ctrl = true })) {
                    bridge_mutex.lockUncancelable(bridge_io);
                    const streaming = bridge_streaming;
                    bridge_mutex.unlock(bridge_io);
                    if (streaming) {
                        bridge_stop_flag.store(true, .release);
                    } else {
                        ctx.quit = true;
                    }
                    return;
                }
                // Readline-style line kill, including what Ctrl+U removes:
                // yanked by Ctrl+Y, the one emacs chord TextField doesn't
                // already implement.
                if (key.matches('y', .{ .ctrl = true })) {
                    self.yankInputToClipboard(ctx) catch {};
                    return ctx.consumeAndRedraw();
                }
                // REPL history recall.
                if (key.matches(vaxis.Key.up, .{})) {
                    self.historyPrev();
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.down, .{})) {
                    self.historyNext();
                    return ctx.consumeAndRedraw();
                }
                // Slash-command completion, styled after readline: one match
                // completes the line, several complete to their shared
                // prefix and list the rest. Only intercepted for `/`-prefixed
                // input; otherwise Tab falls through to the TextField like
                // any other key, unchanged from before this existed.
                if (key.matches(vaxis.Key.tab, .{}) and try self.completeSlashCommand(ctx)) {
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.in_paste) {
                        try self.text_field.insertSliceAtCursor(" ");
                        ctx.redraw = true;
                        return;
                    }
                    try self.submit(ctx);
                    return;
                }
                try self.text_field.handleEvent(ctx, event);
            },
            .paste_start => self.in_paste = true,
            .paste_end => self.in_paste = false,
            // Answer to our OSC 52 clipboard request (Ctrl+Shift+V). The
            // payload is terminal-supplied text, so newlines are folded to
            // spaces — the TextField is single-line and a raw newline would
            // otherwise submit mid-paste.
            .paste => |text| {
                defer ctx.alloc.free(text);
                self.in_paste = false;
                self.awaiting_clipboard = false;
                const flat = singleLinePaste(ctx.alloc, text);
                defer if (flat.ptr != text.ptr) ctx.alloc.free(flat);
                try self.text_field.insertSliceAtCursor(flat);
                ctx.redraw = true;
            },
            .mouse => |m| try self.handleMouse(ctx, m),
            else => try self.text_field.handleEvent(ctx, event),
        }
    }

    /// Row-major drag-to-select over the transcript region. `row`/`col` are
    /// already in this widget's local coordinates (vxfw translates before
    /// dispatch), clamped to the transcript so dragging into the status
    /// line or input box can't select outside what's actually copyable.
    fn handleMouse(self: *Model, ctx: *vxfw.EventContext, m: vaxis.Mouse) !void {
        if (m.button != .left and m.type != .release) return;
        const row = std.math.clamp(
            @as(u16, @intCast(@max(0, m.row))),
            self.transcript_top,
            if (self.transcript_bottom > 0) self.transcript_bottom - 1 else 0,
        );
        const col: u16 = @intCast(@max(0, m.col));
        switch (m.type) {
            .press => {
                self.mouse_down = true;
                self.has_selection = false;
                self.sel_start = .{ .row = row, .col = col };
                self.sel_end = self.sel_start;
                ctx.redraw = true;
            },
            .drag => {
                if (!self.mouse_down) return;
                self.sel_end = .{ .row = row, .col = col };
                self.has_selection = !std.meta.eql(self.sel_start, self.sel_end);
                ctx.redraw = true;
            },
            .release => {
                if (!self.mouse_down) return;
                self.mouse_down = false;
                if (!self.has_selection) return;
                const surface = self.last_surface orelse return;
                const text = extractSelectionText(ctx.alloc, surface, self.sel_start, self.sel_end) catch return;
                defer ctx.alloc.free(text);
                try ctx.copyToClipboard(text);
                ctx.redraw = true;
            },
            .motion => {},
        }
    }

    /// Asks the terminal for its OSC 52 clipboard contents; the answer (if
    /// any) arrives later as a `.paste` event. vxfw's `EventContext` only
    /// exposes a `copy_to_clipboard` command, not a request one, so this
    /// writes the raw control sequence straight to the tty itself, the same
    /// bytes `Vaxis.requestSystemClipboard` sends internally.
    fn requestSystemClipboard(io: std.Io) void {
        std.Io.File.stdout().writeStreamingAll(io, vaxis.ctlseqs.osc52_clipboard_request) catch {};
    }

    /// Ctrl+Shift+C: copy the active mouse-drag selection if there is one
    /// (identical to what a drag release copies), else the current input
    /// line, so the keychord is never a no-op. Clears the selection
    /// afterwards, mirroring how terminal emulators drop the highlight on
    /// copy.
    fn copySelectionOrInput(self: *Model, ctx: *vxfw.EventContext) !void {
        if (self.has_selection) {
            if (self.last_surface) |surface| {
                const text = extractSelectionText(ctx.alloc, surface, self.sel_start, self.sel_end) catch "";
                defer if (text.len > 0) ctx.alloc.free(text);
                if (text.len > 0) try ctx.copyToClipboard(text);
            }
            self.has_selection = false;
            ctx.redraw = true;
            return;
        }
        const input = self.text_field.buf.dupe() catch return;
        defer self.text_field.buf.allocator.free(input);
        if (input.len > 0) try ctx.copyToClipboard(input);
    }

    /// Ctrl+Y: send the whole input line to the system clipboard, so the
    /// kill ring TextField already maintains (Ctrl+U/Ctrl+K/Ctrl+W deletions)
    /// and any typed-but-unsent text is one OSC 52 away from the outside
    /// world.
    fn yankInputToClipboard(self: *Model, ctx: *vxfw.EventContext) !void {
        const input = self.text_field.buf.dupe() catch return;
        defer self.text_field.buf.allocator.free(input);
        if (input.len > 0) try ctx.copyToClipboard(input);
    }

    /// Up: walk one entry older in the history. First step parks the live
    /// input as the draft to come back to.
    fn historyPrev(self: *Model) void {
        const n = self.history.items.len;
        if (n == 0 or self.hist_idx == 0) return;
        if (self.hist_idx == n) {
            const draft = self.text_field.buf.dupe() catch return;
            self.arena.free(self.hist_draft);
            self.hist_draft = self.arena.dupe(u8, draft) catch return;
            self.text_field.buf.allocator.free(draft);
        }
        self.hist_idx -= 1;
        self.loadInputFrom(self.history.items[self.hist_idx]);
    }

    /// Down: walk one entry newer; past the newest entry restores the draft
    /// that was parked when browsing began.
    fn historyNext(self: *Model) void {
        const n = self.history.items.len;
        if (self.hist_idx >= n) return;
        self.hist_idx += 1;
        if (self.hist_idx == n) {
            self.loadInputFrom(self.hist_draft);
        } else {
            self.loadInputFrom(self.history.items[self.hist_idx]);
        }
    }

    fn loadInputFrom(self: *Model, text: []const u8) void {
        self.text_field.clearRetainingCapacity();
        self.text_field.insertSliceAtCursor(text) catch {};
    }

    /// Tab: complete the input line against `command_registry`, readline
    /// style. Returns whether it did anything — false (input isn't a
    /// `/`-prefixed line, or no spelling matches it) means the caller should
    /// let Tab fall through to the TextField as usual. A single match
    /// completes to the full spelling, adding a trailing space when the
    /// command takes arguments so the next keystroke lands on them; several
    /// matches complete to their longest shared prefix, or, once that stops
    /// advancing the line, get listed in the transcript instead of eating
    /// the keystroke silently.
    fn completeSlashCommand(self: *Model, ctx: *vxfw.EventContext) !bool {
        const input = self.text_field.buf.dupe() catch return false;
        defer self.text_field.buf.allocator.free(input);
        if (!looksLikeSlashCommand(input)) return false;

        var buf: [max_completions]SpellingMatch = undefined;
        const matches = matchingSpellings(input, &buf);
        if (matches.len == 0) return false;

        if (matches.len == 1) {
            const m = matches[0];
            if (m.spec.takes_args) {
                var out: [128]u8 = undefined;
                const completed = std.fmt.bufPrint(&out, "{s} ", .{m.spelling}) catch return true;
                self.loadInputFrom(completed);
            } else {
                self.loadInputFrom(m.spelling);
            }
            ctx.redraw = true;
            return true;
        }

        const lcp = longestCommonPrefix(matches);
        if (lcp.len > input.len) {
            self.loadInputFrom(lcp);
            ctx.redraw = true;
            return true;
        }

        var line: std.ArrayList(u8) = .empty;
        line.appendSlice(self.arena, "completions:") catch return true;
        for (matches) |m| {
            line.appendSlice(self.arena, "  ") catch break;
            line.appendSlice(self.arena, m.spelling) catch break;
        }
        self.lines.append(self.arena, .{ .text = line.toOwnedSlice(self.arena) catch "completions:", .dim = true }) catch {};
        ctx.redraw = true;
        return true;
    }

    /// Transcript line count, read under the bridge lock: finishTurn appends
    /// to `self.lines` from the worker thread while a turn is in flight, and
    /// the scroll keys land on the UI thread during exactly that window.
    fn lineCount(self: *Model) usize {
        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        return self.lines.items.len;
    }

    /// The transcript height as of the last draw — what one "page" means.
    /// Zero before the first frame, which the scroll math treats as a
    /// one-line page.
    fn availRows(self: *const Model) u16 {
        return self.transcript_bottom -| self.transcript_top;
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();

        var surface = try vxfw.Surface.init(ctx.arena, self.widget(), max);
        // Computed up front (draw order used to put this after the box/status
        // were already painted in the theme-less default style, so a chosen
        // CLANKER_THEME only ever showed up inside fenced code — everywhere
        // else in the vaxis REPL's chrome ignored it).
        const active = theme_mod.select(themeName(self.ctx.environ_map), self.ctx.environ_map);
        const dim: vaxis.Style = if (active.rgb) |c| .{ .dim = true, .fg = .{ .rgb = c.dim } } else .{ .dim = true };
        const rule_style: vaxis.Style = if (active.rgb) |c| .{ .fg = .{ .rgb = c.rule } } else .{};
        const tool_style: vaxis.Style = if (active.rgb) |c| .{ .dim = true, .fg = .{ .rgb = c.tool } } else dim;
        const err_style: vaxis.Style = if (active.rgb) |c| .{ .fg = .{ .rgb = c.err } } else .{};
        @memset(surface.buffer, .{ .style = .{}, .default = true });

        // Held through the self.lines read loop below, not just the
        // streaming snapshot: finishTurn appends to self.lines from the
        // background thread while a turn is in flight (this same draw runs
        // on every 50ms tick during that window), so reading self.lines.items
        // without the lock is a torn read against a concurrent append/resize.
        bridge_mutex.lockUncancelable(bridge_io);
        defer bridge_mutex.unlock(bridge_io);
        const streaming = bridge_streaming;
        const stream_snapshot = ctx.arena.dupe(u8, bridge_stream_buf.items) catch "";

        // Layout numbers before the status line: its scroll indicator needs
        // the transcript height, which is only known once the input box has
        // claimed its rows.
        const box_h: u16 = 3;
        const box_y = max.height -| box_h;
        const top: u16 = 1;
        const bottom = box_y -| 1;
        self.transcript_top = top;
        self.transcript_bottom = bottom;
        const avail_rows: u16 = if (bottom > top) bottom - top else 0;

        // Manual scrollback: while `view_end` is set the visible window is
        // anchored to an absolute line index, so a streaming turn appends to
        // `lines` without yanking the reader back to the tail. Re-clamped
        // every frame — a resize changes `avail_rows`, and once everything
        // fits on screen the anchor dissolves back to tail-following.
        const line_count = self.lines.items.len;
        if (self.view_end != null and line_count <= avail_rows) self.view_end = null;
        if (self.view_end) |ve| self.view_end = clampViewEnd(ve, line_count, avail_rows);
        const view_end = self.view_end orelse line_count;

        const spinner_glyphs = [_][]const u8{ "\xe2\xa0\x8b", "\xe2\xa0\x99", "\xe2\xa0\xb9", "\xe2\xa0\xb8", "\xe2\xa0\xbc", "\xe2\xa0\xb4", "\xe2\xa0\xa6", "\xe2\xa0\xa7", "\xe2\xa0\x87", "\xe2\xa0\x8f" };
        const activity = if (streaming) spinner_glyphs[self.spinner_frame % spinner_glyphs.len] else "";
        // "-N" is how many transcript lines sit below the frozen window —
        // the reader's distance from the tail, and the cue that the view is
        // not following new output right now.
        var scroll_buf: [24]u8 = undefined;
        const scroll_hint: []const u8 = if (self.view_end != null)
            std.fmt.bufPrint(&scroll_buf, " \xc2\xb7 [scroll -{d}]", .{line_count - view_end}) catch " \xc2\xb7 [scroll]"
        else
            "";
        const status = std.fmt.bufPrint(&self.status_buf, "clanker (vaxis) \xc2\xb7 {s}/{s} \xc2\xb7 {s}{s}{s}{s}{s} \xc2\xb7 /help for commands \xc2\xb7 Ctrl-C to exit", .{
            self.provider.name,
            self.provider.activeModelName(),
            activity,
            if (streaming) " thinking" else "ready",
            scroll_hint,
            if (self.session_id != null) " \xc2\xb7 " else "",
            self.session_id orelse "",
        }) catch "clanker (vaxis)";
        writeRow(surface, 0, status, dim);

        drawBox(surface, 0, box_y, max.width, box_h, rule_style);
        const input_surf = try self.text_field.draw(ctx.withConstraints(.{}, .{ .width = max.width -| 4, .height = 1 }));
        var children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        children[0] = .{ .origin = .{ .row = box_y + 1, .col = 2 }, .surface = input_surf };

        var row: u16 = top;
        if (line_count == 0 and !streaming and row < bottom) {
            writeWrapped(surface, &row, bottom, max.width, "Start with a task. clanker keeps the conversation and streams tool work here.", vaxis.Style{});
            if (row < bottom) row += 1;
            writeWrapped(surface, &row, bottom, max.width, "Try /model to switch models, /help for commands, or type anything to begin.", dim);
        }
        const start = tailStart(self.lines.items[0..view_end], avail_rows);
        // Lines carry fence_lang when they came out of a code fence; the
        // highlighter state is rebuilt per draw from the tagged lines.
        const fence_on = active.reset.len > 0;
        var syn_style = syntax.Style.fromTheme(&active);
        var i: usize = start;
        while (i < view_end and row < bottom) : (i += 1) {
            const l = self.lines.items[i];
            if (l.fence_lang) |lang| {
                var state = syntax.State.init(lang);
                var segs: std.ArrayList(vaxis.Segment) = .empty;
                syntax.spansVaxis(&state, &syn_style, ctx.arena, l.text, &segs) catch {
                    writeWrapped(surface, &row, bottom, max.width, l.text, dim);
                    continue;
                };
                writeWrappedSegments(ctx, surface, &row, bottom, max.width, segs.items);
            } else {
                // Completed lines wrap like the live stream does; writeRow
                // would clip a long turn's reply to a single terminal row.
                // Tool cards (dim, left-bar shaped) get their own tint and a
                // bar-preserving wrap; an error turn's "[error: " prefix gets
                // its own tint too instead of sharing one grey.
                if (l.dim and transcript_mod.isToolCardLine(l.text)) {
                    writeWrappedCard(surface, &row, bottom, max.width, l.text, tool_style);
                    continue;
                }
                const style = if (std.mem.startsWith(u8, l.text, "[error:"))
                    err_style
                else if (l.dim)
                    dim
                else
                    vaxis.Style{};
                writeWrapped(surface, &row, bottom, max.width, l.text, style);
            }
        }
        // The live stream renders only at the tail: a scrolled-up window is
        // frozen history, and painting fresh tokens under it would both lie
        // about where they belong and shove the anchored lines around.
        if (streaming and self.view_end == null and row < bottom and stream_snapshot.len > 0) {
            self.writeStream(ctx, surface, &row, bottom, stream_snapshot, fence_on, &syn_style);
        }

        if (self.has_selection) highlightSelection(surface, self.sel_start, self.sel_end);
        if (self.picker_open) self.drawModelPicker(surface, rule_style, tool_style);
        self.last_surface = surface;

        surface.children = children;
        return surface;
    }

    /// Draws the `/model` picker as a modal box over the tail of the
    /// transcript, just above the input — same left-bar box style as the
    /// input itself (`drawBox`), so it reads as part of this REPL rather
    /// than a bolted-on popup.
    fn drawModelPicker(self: *Model, surface: vxfw.Surface, rule_style: vaxis.Style, sel_style: vaxis.Style) void {
        const matches = self.filteredCandidates();
        const max_rows: u16 = 8;
        const rows_shown: u16 = @intCast(@min(matches.len, max_rows));
        const h: u16 = rows_shown + 3; // top border + query line + rows + bottom border
        if (surface.size.width < 8) return;
        const y = self.transcript_bottom -| h;
        drawBox(surface, 0, y, surface.size.width, h, rule_style);

        writeRow(surface, y + 1, "/model ", .{ .bold = true });
        var query_col: u16 = 7;
        writeRowAt(surface, y + 1, &query_col, self.picker_query.items, .{ .bold = true });
        writeRowAt(surface, y + 1, &query_col, "\xe2\x96\x8f", .{ .bold = true });

        if (matches.len == 0) {
            writeRow(surface, y + 2, "  no matching provider/model", .{ .dim = true });
            return;
        }
        const sel = @min(self.picker_selected, matches.len - 1);
        var row: u16 = y + 2;
        for (matches[0..rows_shown], 0..) |cand, i| {
            const marker: []const u8 = if (i == sel) "\xe2\x80\xba " else "  ";
            const style = if (i == sel) sel_style else vaxis.Style{};
            writeRow(surface, row, marker, style);
            var col: u16 = 2;
            writeRowAt(surface, row, &col, cand.label, style);
            row += 1;
        }
    }

    /// Renders the live streaming buffer as plain wrapped text. The buffer
    /// is raw model output without fence tags (unlike `lines`), so there's
    /// no per-line language to highlight against — `writeWrapped` is the
    /// right call. The `fence_on`/`syn_style` params are carried for a
    /// future highlight pass but not used yet.
    fn writeStream(self: *Model, ctx: vxfw.DrawContext, surface: vxfw.Surface, row: *u16, bottom: u16, text: []const u8, fence_on: bool, syn_style: *const syntax.Style) void {
        _ = self;
        _ = ctx;
        _ = fence_on;
        _ = syn_style;
        writeWrapped(surface, row, bottom, surface.size.width, text, .{});
    }
};

/// How many trailing entries of `lines` to start from so the transcript
/// shows its tail, not its head, once history exceeds the visible height.
/// A rough heuristic (one line of history per visible row) — long entries
/// still wrap past that during draw, so this under- rather than
/// over-estimates what fits, which just means the top of the visible
/// region can be blank rather than truncating the newest content.
fn tailStart(lines: []const Line, avail_rows: u16) usize {
    const n = lines.len;
    const want: usize = avail_rows;
    return if (n > want) n - want else 0;
}

// ---------------------------------------------------------------------
// Manual-scrollback math. All pure over (anchor, line_count, avail_rows)
// so the paging behaviour is unit-testable without a terminal: the anchor
// is Model.view_end — null means "follow the tail", non-null is the
// absolute line index (exclusive) the visible window ends at. Counted in
// `lines` entries, same rough one-entry-per-row heuristic as tailStart.
// ---------------------------------------------------------------------

/// One PgUp/PgDn stride: a screenful less one line of overlap so the reader
/// keeps a continuity line across pages, never less than one row.
fn scrollPage(avail_rows: u16) usize {
    return if (avail_rows > 1) avail_rows - 1 else 1;
}

/// Clamps an anchored window end to what can actually be shown: no earlier
/// than one full screen from the top (the window always fills from line 0)
/// and no later than the transcript's end.
fn clampViewEnd(view_end: usize, line_count: usize, avail_rows: u16) usize {
    const min_end = @min(line_count, avail_rows);
    return @max(min_end, @min(view_end, line_count));
}

/// PgUp: one page up from `cur` (null = following the tail). Returns null —
/// stay at the tail — when the whole transcript already fits on screen, so
/// PgUp in a short session is a no-op rather than a stuck anchor.
fn scrollUpEnd(cur: ?usize, line_count: usize, avail_rows: u16) ?usize {
    if (line_count <= avail_rows) return null;
    const end = cur orelse line_count;
    return clampViewEnd(end -| scrollPage(avail_rows), line_count, avail_rows);
}

/// PgDn: one page down; reaching (or crossing) the tail dissolves the
/// anchor back to tail-following rather than pinning at the last line.
fn scrollDownEnd(cur: ?usize, line_count: usize, avail_rows: u16) ?usize {
    const end = cur orelse return null;
    const new_end = end + scrollPage(avail_rows);
    if (new_end >= line_count) return null;
    return clampViewEnd(new_end, line_count, avail_rows);
}

/// Home: jump to the very top (window [0, avail_rows)); null when there is
/// no history above the first screen.
fn scrollHomeEnd(line_count: usize, avail_rows: u16) ?usize {
    if (line_count <= avail_rows) return null;
    return avail_rows;
}

test "scrollPage is a screenful minus one line of overlap, never zero" {
    try std.testing.expectEqual(@as(usize, 23), scrollPage(24));
    try std.testing.expectEqual(@as(usize, 1), scrollPage(2));
    try std.testing.expectEqual(@as(usize, 1), scrollPage(1));
    try std.testing.expectEqual(@as(usize, 1), scrollPage(0));
}

test "scrollUpEnd pages up and clamps at the top" {
    // 100 lines, 24 visible: the first PgUp anchors a page above the tail.
    try std.testing.expectEqual(@as(?usize, 77), scrollUpEnd(null, 100, 24));
    // Walking further up clamps so the window still fills from line 0.
    var end: ?usize = null;
    for (0..10) |_| end = scrollUpEnd(end, 100, 24);
    try std.testing.expectEqual(@as(?usize, 24), end);
    // Nothing above the first screen: stays following the tail.
    try std.testing.expectEqual(@as(?usize, null), scrollUpEnd(null, 10, 24));
    try std.testing.expectEqual(@as(?usize, null), scrollUpEnd(null, 24, 24));
}

test "scrollDownEnd pages down and dissolves at the tail" {
    try std.testing.expectEqual(@as(?usize, 47), scrollDownEnd(24, 100, 24));
    // A page that reaches past the last line returns to tail-following.
    try std.testing.expectEqual(@as(?usize, null), scrollDownEnd(90, 100, 24));
    // Already at the tail (null anchor): PgDn stays there.
    try std.testing.expectEqual(@as(?usize, null), scrollDownEnd(null, 100, 24));
}

test "scrollHomeEnd jumps to the top only when there is history above" {
    try std.testing.expectEqual(@as(?usize, 24), scrollHomeEnd(100, 24));
    try std.testing.expectEqual(@as(?usize, null), scrollHomeEnd(24, 24));
    try std.testing.expectEqual(@as(?usize, null), scrollHomeEnd(3, 24));
}

test "an anchored view end holds its lines while the transcript grows" {
    // Frozen view: the anchor is an absolute index, so appended lines (a
    // growing line_count) leave the visible window exactly where it was —
    // the stick-to-tail behaviour lives entirely in the null anchor.
    try std.testing.expectEqual(@as(usize, 50), clampViewEnd(50, 200, 24));
    try std.testing.expectEqual(@as(usize, 50), clampViewEnd(50, 500, 24));
    // A shrunk transcript (or one shorter than the anchor) re-clamps it in.
    try std.testing.expectEqual(@as(usize, 40), clampViewEnd(50, 40, 24));
    // And a taller terminal pulls a too-high anchor down to a full window.
    try std.testing.expectEqual(@as(usize, 30), clampViewEnd(10, 200, 30));
}

fn writeRow(surface: vxfw.Surface, row: u16, text: []const u8, style: vaxis.Style) void {
    var col: u16 = 0;
    writeRowAt(surface, row, &col, text, style);
}

fn writeRowAt(surface: vxfw.Surface, row: u16, col: *u16, text: []const u8, style: vaxis.Style) void {
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepointSlice()) |cp| {
        if (col.* >= surface.size.width) break;
        surface.writeCell(col.*, row, .{ .char = .{ .grapheme = cp, .width = 1 }, .style = style });
        col.* += 1;
    }
}

/// Writes styled segments with grapheme-accurate widths, wrapping at the
/// surface edge and stopping at `bottom`. Segment text borrows the caller's
/// buffer.
fn writeWrappedSegments(ctx: vxfw.DrawContext, surface: vxfw.Surface, row: *u16, bottom: u16, width: u16, segs: []const vaxis.Segment) void {
    var col: u16 = 0;
    for (segs) |seg| {
        var it = ctx.graphemeIterator(seg.text);
        while (it.next()) |g| {
            if (row.* >= bottom) return;
            const bytes = g.bytes(seg.text);
            if (std.mem.eql(u8, bytes, "\n")) {
                row.* += 1;
                col = 0;
                continue;
            }
            if (std.mem.eql(u8, bytes, "\t")) {
                const tab_width = 8 - col % 8;
                if (col + tab_width > width) {
                    row.* += 1;
                    col = 0;
                    if (row.* >= bottom) return;
                }
                col += tab_width;
                continue;
            }
            const w: u16 = @intCast(@min(ctx.stringWidth(bytes), 2));
            if (col + w > width) {
                row.* += 1;
                col = 0;
                if (row.* >= bottom) return;
            }
            if (w > 0) surface.writeCell(col, row.*, .{ .char = .{ .grapheme = bytes, .width = @intCast(w) }, .style = seg.style });
            col += w;
        }
    }
}

/// writeWrapped for a tool-card line: continuation rows re-open with the
/// card's left bar ("\u{2502}  ") so a long args preview wraps inside the
/// card instead of spilling flush-left and breaking the shape the card
/// builders drew. Terminals too narrow for bar + indent + a few glyphs fall
/// back to the plain wrap rather than filling every row with prefix.
fn writeWrappedCard(surface: vxfw.Surface, row: *u16, bottom: u16, width: u16, text: []const u8, style: vaxis.Style) void {
    if (width < 8) return writeWrapped(surface, row, bottom, width, text, style);
    var col: u16 = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepointSlice()) |cp| {
        if (row.* >= bottom) break;
        if (std.mem.eql(u8, cp, "\n")) {
            // Card lines are single-line by construction (cardPreview
            // flattens newlines); handled anyway so a stray one degrades
            // like writeWrapped instead of overprinting.
            row.* += 1;
            col = 0;
            continue;
        }
        if (col >= width) {
            row.* += 1;
            col = 0;
            if (row.* >= bottom) break;
            var pit = std.unicode.Utf8Iterator{ .bytes = "\u{2502}  ", .i = 0 };
            while (pit.nextCodepointSlice()) |pcp| {
                surface.writeCell(col, row.*, .{ .char = .{ .grapheme = pcp, .width = 1 }, .style = style });
                col += 1;
            }
        }
        surface.writeCell(col, row.*, .{ .char = .{ .grapheme = cp, .width = 1 }, .style = style });
        col += 1;
    }
}

/// Writes `text` wrapped at `width`, advancing `*row` a line at a time,
/// stopping at `bottom`. Simple hard-wrap (no word-break) — good enough for
/// a live streaming tail and for completed turns (which must not be clipped
/// to a single row); MdStream-quality wrapping is follow-up work.
fn writeWrapped(surface: vxfw.Surface, row: *u16, bottom: u16, width: u16, text: []const u8, style: vaxis.Style) void {
    var col: u16 = 0;
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepointSlice()) |cp| {
        if (row.* >= bottom) break;
        if (std.mem.eql(u8, cp, "\n")) {
            row.* += 1;
            col = 0;
            continue;
        }
        if (col >= width) {
            row.* += 1;
            col = 0;
            if (row.* >= bottom) break;
        }
        surface.writeCell(col, row.*, .{ .char = .{ .grapheme = cp, .width = 1 }, .style = style });
        col += 1;
    }
}

fn drawBox(surface: vxfw.Surface, x: u16, y: u16, w: u16, h: u16, style: vaxis.Style) void {
    if (w == 0 or h == 0) return;
    surface.writeCell(x, y, .{ .char = .{ .grapheme = "\xe2\x95\xad", .width = 1 }, .style = style });
    surface.writeCell(x + w -| 1, y, .{ .char = .{ .grapheme = "\xe2\x95\xae", .width = 1 }, .style = style });
    surface.writeCell(x, y + h -| 1, .{ .char = .{ .grapheme = "\xe2\x95\xb0", .width = 1 }, .style = style });
    surface.writeCell(x + w -| 1, y + h -| 1, .{ .char = .{ .grapheme = "\xe2\x95\xaf", .width = 1 }, .style = style });
    var i: u16 = x + 1;
    while (i < x + w -| 1) : (i += 1) {
        surface.writeCell(i, y, .{ .char = .{ .grapheme = "\xe2\x94\x80", .width = 1 }, .style = style });
        surface.writeCell(i, y + h -| 1, .{ .char = .{ .grapheme = "\xe2\x94\x80", .width = 1 }, .style = style });
    }
    var r: u16 = y + 1;
    while (r < y + h -| 1) : (r += 1) {
        surface.writeCell(x, r, .{ .char = .{ .grapheme = "\xe2\x94\x82", .width = 1 }, .style = style });
        surface.writeCell(x + w -| 1, r, .{ .char = .{ .grapheme = "\xe2\x94\x82", .width = 1 }, .style = style });
    }
}

/// Row-major order: dragging can go in any direction, so this puts
/// whichever of `a`/`b` comes first on screen first.
fn normalizeSelection(a: vxfw.Point, b: vxfw.Point) struct { first: vxfw.Point, last: vxfw.Point } {
    if (a.row < b.row or (a.row == b.row and a.col <= b.col)) return .{ .first = a, .last = b };
    return .{ .first = b, .last = a };
}

/// Reverse-video over the selected cells, drawn last so it wins over
/// whatever style the content underneath already had.
fn highlightSelection(surface: vxfw.Surface, a: vxfw.Point, b: vxfw.Point) void {
    const n = normalizeSelection(a, b);
    var row = n.first.row;
    while (row <= n.last.row and row < surface.size.height) : (row += 1) {
        const col_start: u16 = if (row == n.first.row) n.first.col else 0;
        const col_end: u16 = if (row == n.last.row) n.last.col else surface.size.width -| 1;
        var col = col_start;
        while (col <= col_end and col < surface.size.width) : (col += 1) {
            var cell = surface.readCell(col, row);
            cell.style.reverse = true;
            surface.writeCell(col, row, cell);
        }
    }
}

/// Reads the plain text back out of the selected cells (works uniformly
/// across plain, wrapped, and syntax-highlighted rows since it reads the
/// final rendered buffer, not any one code path's own text). Trailing
/// padding spaces on each row are trimmed; rows join with '\n'.
fn extractSelectionText(alloc: std.mem.Allocator, surface: vxfw.Surface, a: vxfw.Point, b: vxfw.Point) ![]const u8 {
    const n = normalizeSelection(a, b);
    var out: std.ArrayList(u8) = .empty;
    var row = n.first.row;
    while (row <= n.last.row and row < surface.size.height) : (row += 1) {
        const col_start: u16 = if (row == n.first.row) n.first.col else 0;
        const col_end: u16 = if (row == n.last.row) n.last.col else surface.size.width -| 1;
        var col = col_start;
        while (col <= col_end and col < surface.size.width) : (col += 1) {
            const cell = surface.readCell(col, row);
            try out.appendSlice(alloc, cell.char.grapheme);
        }
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        if (row < n.last.row) try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// Folds CR/LF runs in clipboard text to single spaces so a multi-line
/// paste lands on one line of the single-line TextField instead of
/// submitting early (Enter submits). Returns the input unchanged when
/// there's nothing to fold — caller frees only when the pointer differs.
fn singleLinePaste(alloc: std.mem.Allocator, text: []const u8) []const u8 {
    var out: ?[]u8 = null;
    defer if (out) |o| alloc.free(o);
    for (text, 0..) |c, i| {
        if (c != '\r' and c != '\n') continue;
        if (out == null) {
            const buf = alloc.dupe(u8, text) catch return text;
            out = buf;
        }
        out.?[i] = ' ';
    }
    return if (out) |o| o else text;
}

/// The subset of `cli.Options` the REPL honors. `--provider`/`--model` pick
/// the starting provider/model, `--session <id>` resumes a saved conversation
/// and `--continue` resumes the most recently touched one. Passing this narrow
/// struct instead of all of `cli.Options` keeps the REPL from importing all of
/// cli.zig (which would pull the whole CLI into this module) while making
/// every declared flag real.
pub const ReplOptions = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    session: ?[]const u8 = null,
    continue_last: bool = false,
};

/// Session ids become path fragments under `state/sessions/`, so only the
/// same slug shape the rest of clanker accepts is allowed here (alphanumeric,
/// `-`, `_`, length 1..64). Anything with a separator or a dot is refused
/// before it could walk out of the store — this mirrors `cli.zig`'s
/// `validSessionId`, restated locally because the REPL deliberately does not
/// import cli.zig.
fn validSessionId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// The id `--continue` means: the saved session touched most recently.
/// Returns null when there are none, so a first `--continue` starts a fresh
/// session rather than failing at someone who has not made one yet.
fn latestSessionId(io: std.Io, arena: std.mem.Allocator) ?[]const u8 {
    const metas = session_mod.listSessions(io, arena, std.Io.Dir.cwd()) catch return null;
    var best: ?session_mod.SessionMeta = null;
    for (metas) |m| {
        if (best == null or m.updated > best.?.updated) best = m;
    }
    return if (best) |b| b.id else null;
}

/// A fresh conversation's id, minted the first time it is saved. The
/// nanosecond suffix keeps rapid successive sessions distinct and stays
/// within the slug alphabet `validSessionId` accepts, like the server's
/// `sess-<base36>` fallback.
fn mintSessionId(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    return try std.fmt.allocPrint(arena, "sess-{d}", .{std.Io.Timestamp.now(io, .real).nanoseconds});
}

test "validSessionId refuses path traversal and accepts the minted shape" {
    try std.testing.expect(validSessionId("sess-123"));
    try std.testing.expect(validSessionId("7f3a1c2e-0b44-4a91-9d3e-1c2b3a4d5e6f"));
    try std.testing.expect(validSessionId("sess-m1x2y3_ab12cd"));
    try std.testing.expect(!validSessionId("../../etc/passwd"));
    try std.testing.expect(!validSessionId("a/b"));
    try std.testing.expect(!validSessionId("a.json"));
    try std.testing.expect(!validSessionId(""));
    try std.testing.expect(!validSessionId("x" ** 65));
}

test "mintSessionId produces a distinct valid id each call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const a = try mintSessionId(io, arena);
    const b = try mintSessionId(io, arena);
    try std.testing.expect(validSessionId(a));
    try std.testing.expect(validSessionId(b));
    try std.testing.expect(std.mem.startsWith(u8, a, "sess-"));
    // Nanosecond-resolution ids of two consecutive mints are not equal.
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "stripControls returns the input slice unchanged when nothing to drop" {
    const clean = "hello\nworld\t!";
    try std.testing.expectEqual(clean.ptr, stripControls(std.testing.allocator, clean).ptr);
}

test "stripControls drops control bytes but keeps newline and tab" {
    const dirty = "a\x01b\nc\x7Fd\te";
    const got = stripControls(std.testing.allocator, dirty);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("ab\ncd\te", got);
}

pub fn cmdReplVaxis(init: std.process.Init, opts: ReplOptions) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    bridge_gpa = gpa;
    bridge_io = io;
    // log.log writes straight to stderr with no coordination with vaxis's
    // owned alt-screen buffer, unlike the old REPL where stray stderr text
    // just scrolled by harmlessly. Any stray write here corrupts the
    // screen, so raise the threshold for this command's whole lifetime.
    log.setLevel(.error_);

    var cfg = try config.Config.load(io, arena, std.Io.Dir.cwd(), "config.toml", "config.local.toml");
    // `always` has no prompt-rendering path in this REPL yet (see the module
    // doc comment and docs/ROADMAP.md): write-capable tools run ungated here
    // regardless of this setting. Said once, before the alt-screen takes
    // over stderr, so the operator is not left believing they are protected.
    if (cfg.agent.confirm_writes == .always) {
        std.debug.print("warning: agent.confirm_writes=\"always\" does not gate this REPL yet — write-capable tool calls run without confirmation here. Only `clanker serve` honors it today.\n", .{});
    }
    std.Io.Dir.cwd().createDirPath(io, cfg.agent.sandbox_root) catch {};
    var reg = try registry.Registry.load(io, arena, std.Io.Dir.cwd(), cfg.agent.tools_dir);
    const tool_defs = try reg.toToolDefs(arena);
    // `--provider`/`--model` pick the starting provider/model; `--model
    // <provider>/<model>` picks both at once, resolved by the same
    // Config.resolveProvider rule `clanker run` uses.
    const provider = try cfg.resolveProvider(opts.provider, opts.model);
    const ctx = client.Ctx{ .io = io, .gpa = gpa, .environ_map = init.environ_map, .cfg = &cfg };

    // Which conversation this is: `--session <id>` names one, `--continue`
    // picks up the most recently touched one, and otherwise (sessions module
    // on) a fresh `repl-<ts>` id is minted so the conversation is findable in
    // `clanker sessions` afterwards — the same contract the deleted REPL and
    // `clanker run` honor. With the module off, nothing is read or written.
    const now_s: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    var session_id: ?[]const u8 = opts.session;
    if (session_id == null and opts.continue_last) {
        session_id = session_mod.latestSessionId(io, arena, std.Io.Dir.cwd());
    }
    // The id becomes a path fragment under state/sessions/, so it is validated
    // before it could walk out of the store (mirrors cli.zig's validSessionId).
    if (session_id) |sid| {
        if (!validSessionId(sid)) {
            log.log(.warn, "repl: ignoring invalid --session id '{s}'", .{sid});
            session_id = null;
        }
    }
    if (session_id == null and cfg.modules.sessions) {
        session_id = try std.fmt.allocPrint(arena, "repl-{d}", .{now_s});
    }
    var session_created: i64 = now_s;
    var session_title: []const u8 = "";
    var loaded_messages: []const types.Message = &.{};
    if (session_id) |sid| {
        const maybe_s: ?session_mod.Session = session_mod.loadSession(io, gpa, arena, std.Io.Dir.cwd(), sid) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (maybe_s) |s| {
            session_created = s.created;
            session_title = s.title;
            loaded_messages = s.messages;
        }
    }

    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, gpa, init.environ_map, &buffer);
    defer app.deinit();

    const model = try arena.create(Model);
    model.* = .{
        .gpa = gpa,
        .io = io,
        .arena = arena,
        .ctx = ctx,
        .cfg = cfg,
        .provider = provider,
        .reg = reg,
        .tool_defs = tool_defs,
        .text_field = vxfw.TextField.init(gpa),
        .session_id = session_id,
        .session_created = session_created,
        .session_title = session_title,
    };
    for (loaded_messages) |m| {
        // The agent rebuilds its own system prompt per run; a stored one
        // would fight it (same rule as `clanker run --session`).
        if (m.role == .system) continue;
        try model.messages.append(arena, m);
    }
    if (session_id) |sid| {
        // Say which conversation was resumed, so re-entering `--continue` is
        // not indistinguishable from a fresh REPL. Only when it actually
        // loaded something — a brand-new minted id has nothing to announce.
        var non_system: usize = 0;
        for (model.messages.items) |m| {
            if (m.role != .system) non_system += 1;
        }
        if (non_system > 0) {
            model.lines.append(arena, .{
                .text = std.fmt.allocPrint(arena, "[resumed session {s}: {d} messages]", .{ sid, non_system }) catch "[resumed session]",
                .dim = true,
            }) catch {};
        }
    }
    model.model_candidates = buildModelCandidates(arena, &model.cfg) catch &.{};
    defer model.text_field.deinit();

    // Save on every exit path: app.run returns for /quit and for Ctrl-C while
    // idle alike, so persisting here (rather than in submit) is what makes the
    // conversation survive. Save even if the run loop errored out.
    const run_result = app.run(model.widget(), .{});
    model.saveConversation();
    // Free the bridge buffers only when the worker is joined (idle exit):
    // a still-running worker appends to them, and freeing under it would
    // trade a shutdown leak report for a use-after-free.
    if (model.thread == null) {
        for (bridge_tool_lines.items) |l| bridge_gpa.free(l);
        bridge_tool_lines.deinit(bridge_gpa);
        bridge_stream_buf.deinit(bridge_gpa);
    }
    try run_result;
}
