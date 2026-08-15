//! Per-turn stats and compaction notices: what a turn cost, and when history
//! was silently thrown away to make room for the next one.
//!
//! One formatter, two surfaces. `clanker run` prints the turn line on stderr
//! (stdout stays pipe-clean, as ever) and the vaxis REPL appends the same
//! string to its transcript, so the two can't drift into two dialects of
//! "1234 in / 567 out". Session-lifetime totals share this file too
//! (`writeSession`): the web `#run-metrics` strip and the REPL's last row
//! under the composer. Everything here is pure: a struct of numbers in, a
//! string out, no allocator-per-frame and no terminal, which is what makes it
//! testable at all, the vaxis event loop is not.
//!
//! Two deliberate omissions, both about not printing a confident zero:
//!
//!   * Cost is `?f64`. A model with no `cost_per_1m_input`/`cost_per_1m_output`
//!     in the catalogue has an *unknown* price, not a free one, and `$0.0000`
//!     reads as the second. The segment is dropped instead.
//!   * Cache hit rate is dropped when the provider reported no cache
//!     accounting at all, rather than shown as `cache 0%`.
//!
//! The context meter estimates history at bytes/4, the same chars-per-token
//! heuristic `session.compactMessages` compacts against and the web UI's own
//! context meter divides by (`core/composer.js`'s `contextLabel`), so the
//! REPL's percentage and the browser's agree on the same conversation.

const std = @import("std");
const types = @import("../llm/types.zig");

/// Everything one completed turn is worth reporting. Zero-valued fields are
/// omitted from the rendered line rather than printed as zeroes (see the
/// module comment), so a caller that only knows some of this can leave the
/// rest at its default.
pub const TurnStats = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    /// Prompt tokens the provider served from its cache, and the ones it
    /// didn't. Both zero means "the provider said nothing about caching",
    /// which is not the same as a 0% hit rate.
    cache_hit_tokens: u64 = 0,
    cache_miss_tokens: u64 = 0,
    /// Wall time of the whole turn: every LLM call and every tool round in
    /// it, not just the time the model spent generating.
    wall_ms: u64 = 0,
    /// Estimated USD for this turn, or null when the active model carries no
    /// pricing in the catalogue.
    cost_usd: ?f64 = null,
    /// Conversation history after the turn, and the active model's window.
    /// A zero window (an unconfigured `context_window`) drops the meter.
    context_tokens: usize = 0,
    context_window: u32 = 0,

    /// False when no LLM call in this turn reported usage, which is what a
    /// turn that failed before it reached the provider looks like. Callers
    /// use it to skip the line entirely rather than print an all-zero one.
    pub fn accounted(self: TurnStats) bool {
        return self.prompt_tokens > 0 or self.completion_tokens > 0;
    }
};

/// Completion tokens per second of wall time. Wall time, not model time: a
/// turn that spent 40 seconds in tool calls really did produce its tokens
/// that slowly from where the user is sitting.
pub fn tokensPerSecond(completion_tokens: u64, wall_ms: u64) f64 {
    if (wall_ms == 0) return 0;
    return @as(f64, @floatFromInt(completion_tokens)) / (@as(f64, @floatFromInt(wall_ms)) / 1000.0);
}

/// Percentage of prompt tokens served from the provider's cache, or null when
/// the provider reported no cache accounting for this turn.
pub fn cacheHitRate(hit: u64, miss: u64) ?f64 {
    const total = hit +| miss;
    if (total == 0) return null;
    return @as(f64, @floatFromInt(hit)) / @as(f64, @floatFromInt(total)) * 100.0;
}

/// How much of the model's context window the conversation now occupies, or
/// null when the window is unknown (nothing useful to be a percentage of).
pub fn contextPercent(used: usize, window: u32) ?f64 {
    if (window == 0) return null;
    return @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(window)) * 100.0;
}

/// Token counts, shortened. Exact below 1000 (the numbers small enough to
/// mean something individually), then one decimal of k up to 100k, then whole
/// k, so a 128000-token window renders "128k" and not "128.0k".
pub fn compactCount(buf: []u8, n: u64) []const u8 {
    const f: f64 = @floatFromInt(n);
    if (n < 1000) return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
    if (n < 100_000) return std.fmt.bufPrint(buf, "{d:.1}k", .{f / 1000.0}) catch "?";
    if (n < 1_000_000) return std.fmt.bufPrint(buf, "{d:.0}k", .{f / 1000.0}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1}M", .{f / 1_000_000.0}) catch "?";
}

/// Byte counts, in the units and rounding the web UI's `fmtBytes` uses
/// (`ui/app/core/utils.js`), so "freed 48.2 KB" here and the size
/// the browser shows for the same conversation are the same number.
pub fn compactBytes(buf: []u8, n: usize) []const u8 {
    const f: f64 = @floatFromInt(n);
    if (n >= 1024 * 1024) return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / (1024.0 * 1024.0)}) catch "?";
    if (n >= 1024) return std.fmt.bufPrint(buf, "{d:.0} KB", .{f / 1024.0}) catch "?";
    return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
}

/// Wall time at one significant unit: milliseconds under a second, seconds
/// under a minute, then minutes and seconds. A turn is either quick enough to
/// count in ms or long enough that the ms are noise.
pub fn compactDuration(buf: []u8, ms: u64) []const u8 {
    if (ms < 1000) return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch "?";
    if (ms < 60_000) return std.fmt.bufPrint(buf, "{d:.1}s", .{@as(f64, @floatFromInt(ms)) / 1000.0}) catch "?";
    return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ ms / 60_000, (ms % 60_000) / 1000 }) catch "?";
}

/// The separator between stats segments: the same middot the REPL status bar
/// already puts between its own fields.
const dot = " \xc2\xb7 ";

/// Writes the turn line: `[turn: 1234 in / 567 out · 4.2s · 135.1 tok/s ·
/// cache 82% · $0.0031 · ctx 12.1k/128k (9%)]`. Bracketed so it reads as
/// harness metadata rather than model prose; errors use the CLI-compatible
/// `error: ...` prefix instead.
pub fn writeTurn(w: *std.Io.Writer, s: TurnStats) !void {
    var num: [32]u8 = undefined;
    var num2: [32]u8 = undefined;
    try w.print("[turn: {d} in / {d} out", .{ s.prompt_tokens, s.completion_tokens });
    if (s.wall_ms > 0) try w.print(dot ++ "{s}", .{compactDuration(&num, s.wall_ms)});
    if (s.completion_tokens > 0 and s.wall_ms > 0) {
        try w.print(dot ++ "{d:.1} tok/s", .{tokensPerSecond(s.completion_tokens, s.wall_ms)});
    }
    if (cacheHitRate(s.cache_hit_tokens, s.cache_miss_tokens)) |rate| {
        try w.print(dot ++ "cache {d:.0}%", .{rate});
    }
    if (s.cost_usd) |cost| try w.print(dot ++ "${d:.4}", .{cost});
    if (contextPercent(s.context_tokens, s.context_window)) |pct| {
        try w.print(dot ++ "ctx {s}/{s} ({d:.0}%)", .{
            compactCount(&num, s.context_tokens),
            compactCount(&num2, s.context_window),
            pct,
        });
    }
    try w.writeAll("]");
}

/// Session-lifetime strip, same fields as the web UI's `#run-metrics`.
/// Times include the in-flight turn when the caller folds live elapsed in.
pub const SessionStats = struct {
    turns: u64 = 0,
    steps: u64 = 0,
    llm_ms: u64 = 0,
    tool_ms: u64 = 0,
    ttft_ms_total: u64 = 0,
    ttft_samples: u32 = 0,
    live_ttft_ms: ?u64 = null,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    cache_hit_tokens: u64 = 0,
    cache_miss_tokens: u64 = 0,

    pub fn empty(self: SessionStats) bool {
        return self.turns == 0 and self.steps == 0 and self.llm_ms == 0 and self.tool_ms == 0;
    }
};

/// Writes `21 turns · 1588 steps | LLM 4m25s · Tool call 2m10s | TTFT avg 3.0s · 143 tok/s | Cache hit 100% | Input 1.0M tok · Output 1.6M tok`.
pub fn writeSession(w: *std.Io.Writer, s: SessionStats) !void {
    if (s.empty()) return;
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    try w.print("{d} turn{s}" ++ dot ++ "{d} step{s}", .{
        s.turns,
        if (s.turns == 1) "" else "s",
        s.steps,
        if (s.steps == 1) "" else "s",
    });
    try w.print(" | LLM {s}" ++ dot ++ "Tool call {s}", .{
        compactDuration(&a, s.llm_ms),
        compactDuration(&b, s.tool_ms),
    });
    var rate_started = false;
    if (s.ttft_samples > 0) {
        try w.print(" | TTFT avg {s}", .{compactDuration(&a, s.ttft_ms_total / s.ttft_samples)});
        rate_started = true;
    } else if (s.live_ttft_ms) |ttft| {
        try w.print(" | TTFT {s}", .{compactDuration(&a, ttft)});
        rate_started = true;
    }
    if (s.completion_tokens > 0 and s.llm_ms > 0) {
        const tps = tokensPerSecond(s.completion_tokens, s.llm_ms);
        if (rate_started) try w.print(dot ++ "{d:.0} tok/s", .{tps}) else try w.print(" | {d:.0} tok/s", .{tps});
    }
    if (cacheHitRate(s.cache_hit_tokens, s.cache_miss_tokens)) |rate| {
        try w.print(" | Cache hit {d:.0}%", .{rate});
    }
    if (s.prompt_tokens > 0 or s.completion_tokens > 0) {
        try w.print(" | Input {s} tok" ++ dot ++ "Output {s} tok", .{
            compactCount(&a, s.prompt_tokens),
            compactCount(&b, s.completion_tokens),
        });
    }
}

/// `writeSession` into `buf`. Null when there is nothing to show.
pub fn formatSession(buf: []u8, s: SessionStats) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeSession(&w, s) catch return null;
    if (w.end == 0) return null;
    return buf[0..w.end];
}

/// `writeTurn` into a fresh allocation, for the surfaces that store a line
/// rather than stream it (the REPL's transcript owns its strings).
pub fn formatTurn(alloc: std.mem.Allocator, s: TurnStats) ![]u8 {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeTurn(&w, s);
    return alloc.dupe(u8, buf[0..w.end]);
}

/// The status-bar form: `ctx 12.1k/128k (9%)`, short enough to sit beside the
/// provider/model on one row. Null when there is no window to measure
/// against, so the caller writes nothing rather than a bare byte count.
pub fn contextMeter(buf: []u8, used: usize, window: u32) ?[]const u8 {
    const pct = contextPercent(used, window) orelse return null;
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    return std.fmt.bufPrint(buf, "ctx {s}/{s} ({d:.0}%)", .{
        compactCount(&a, used),
        compactCount(&b, window),
        pct,
    }) catch null;
}

// ------------------------------------------------------------- compaction --
//
// Two different things drop history out from under a session, and both used
// to happen with nothing on screen:
//
//   * `session.compactMessages` trims the oldest messages before every save
//     once the conversation passes `max_session_tokens`. Measurable exactly:
//     count and weigh the list either side of the call (`Compaction`).
//   * `Agent.maybeCompactMessages` replaces the middle of the conversation
//     with an LLM-written summary mid-turn once it passes
//     `agent.compact_threshold_bytes`. That one happens inside `Agent.run`,
//     which reports it only to the log, so it is detected after the fact from
//     the summary message it leaves behind (`summaryState`).

/// A `session.compactMessages` call, weighed either side.
pub const Compaction = struct {
    messages_before: usize = 0,
    messages_after: usize = 0,
    bytes_before: usize = 0,
    bytes_after: usize = 0,

    pub fn droppedMessages(self: Compaction) usize {
        return self.messages_before -| self.messages_after;
    }

    pub fn freedBytes(self: Compaction) usize {
        return self.bytes_before -| self.bytes_after;
    }
};

/// `[history compacted: dropped 12 messages, freed 48 KB]`, or null when the
/// call left the conversation alone, which is the overwhelmingly common
/// case, so the caller can measure unconditionally and print only on a hit.
pub fn formatCompaction(alloc: std.mem.Allocator, c: Compaction) !?[]u8 {
    const dropped = c.droppedMessages();
    if (dropped == 0) return null;
    var bytes_buf: [32]u8 = undefined;
    return try std.fmt.allocPrint(alloc, "[history compacted: dropped {d} {s}, freed {s}]", .{
        dropped,
        if (dropped == 1) "message" else "messages",
        compactBytes(&bytes_buf, c.freedBytes()),
    });
}

/// Byte weight of a conversation: content plus tool-call arguments, matching
/// what `session.listSessions` reports and what the web UI shows beside a
/// session. Counting content alone would under-report a transcript that is
/// mostly tool traffic, which is exactly the kind that compacts.
pub fn historyBytes(messages: []const types.Message) usize {
    var n: usize = 0;
    for (messages) |m| {
        if (m.content) |c| n +|= c.len;
        if (m.tool_calls) |calls| {
            for (calls) |tc| n +|= tc.arguments.len;
        }
    }
    return n;
}

/// The same chars/4 estimate `session.compactMessages` budgets against. It is
/// a heuristic, not a tokenizer: the meter says "roughly how full", and being
/// exactly right would need a per-provider tokenizer clanker does not carry.
pub fn historyTokens(messages: []const types.Message) usize {
    return historyBytes(messages) / 4;
}

/// How many mid-turn compactions a conversation carries, and how many
/// messages they swallowed between them.
pub const SummaryState = struct {
    /// One per compaction that has happened in this conversation.
    markers: usize = 0,
    /// Messages named as compacted by those markers. Only the summarizing
    /// forms of the placeholder carry a count, so this can lag `markers`.
    messages: usize = 0,
};

/// Counts the summary messages `Agent.maybeCompactMessages` leaves behind.
///
/// A marker scan rather than a callback because `Agent` exposes no compaction
/// hook (it logs and moves on), and the REPL's alternative was to say nothing
/// at all about the compaction the roadmap called out as invisible. Both
/// placeholder spellings the agent can write start with one of these two
/// prefixes, and the summarizing ones name the number of messages they
/// replaced, which is parsed out when present.
///
/// The cost of the shortcut: a user message that itself opens with one of the
/// prefixes would be miscounted. A proper `Agent.on_compact` hook in
/// `agent/loop.zig` would retire this function; it is tracked as follow-up
/// work in `docs/prds/0005-repl-tui.md`.
pub fn summaryState(messages: []const types.Message) SummaryState {
    var st: SummaryState = .{};
    for (messages) |m| {
        const c = m.content orelse continue;
        if (!std.mem.startsWith(u8, c, "[conversation summary") and
            !std.mem.startsWith(u8, c, "[earlier conversation compacted")) continue;
        st.markers += 1;
        if (firstNumber(c)) |n| st.messages +|= n;
    }
    return st;
}

/// The first run of digits in `s`, or null. Used only to lift the message
/// count out of a summary placeholder.
fn firstNumber(s: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.len and !std.ascii.isDigit(s[i])) : (i += 1) {}
    if (i == s.len) return null;
    var n: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        n = n *| 10 +| (s[i] - '0');
    }
    return n;
}

/// `[context compacted: 42 earlier messages replaced by a summary to fit the
/// model window]`, or null when no new summary appeared over the turn. The
/// count is omitted when the placeholder did not carry one (the static
/// fallback the agent writes when summarization itself fails).
pub fn formatSummaryNotice(alloc: std.mem.Allocator, before: SummaryState, after: SummaryState) !?[]u8 {
    if (after.markers <= before.markers) return null;
    const grew = after.messages -| before.messages;
    if (grew == 0) {
        return try alloc.dupe(u8, "[context compacted: earlier messages replaced by a summary to fit the model window]");
    }
    return try std.fmt.allocPrint(
        alloc,
        "[context compacted: {d} earlier {s} replaced by a summary to fit the model window]",
        .{ grew, if (grew == 1) "message" else "messages" },
    );
}

// ------------------------------------------------------------------ tests --

test "tokensPerSecond divides completion tokens by wall seconds" {
    try std.testing.expectApproxEqAbs(@as(f64, 100), tokensPerSecond(500, 5000), 0.001);
    try std.testing.expectEqual(@as(f64, 0), tokensPerSecond(500, 0)); // no divide by zero
}

test "cacheHitRate is null when the provider reported no cache accounting" {
    try std.testing.expectEqual(@as(?f64, null), cacheHitRate(0, 0));
    try std.testing.expectApproxEqAbs(@as(f64, 80), cacheHitRate(800, 200).?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), cacheHitRate(0, 200).?, 0.001);
}

test "contextPercent needs a window to be a percentage of" {
    try std.testing.expectEqual(@as(?f64, null), contextPercent(1000, 0));
    try std.testing.expectApproxEqAbs(@as(f64, 50), contextPercent(64, 128).?, 0.001);
}

test "compactCount keeps small numbers exact and shortens the rest" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", compactCount(&buf, 0));
    try std.testing.expectEqualStrings("999", compactCount(&buf, 999));
    try std.testing.expectEqualStrings("1.0k", compactCount(&buf, 1000));
    try std.testing.expectEqualStrings("12.3k", compactCount(&buf, 12345));
    try std.testing.expectEqualStrings("128k", compactCount(&buf, 128_000));
    try std.testing.expectEqualStrings("1.0M", compactCount(&buf, 1_048_576));
}

test "compactDuration switches unit once the ms stop mattering" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("840ms", compactDuration(&buf, 840));
    try std.testing.expectEqualStrings("4.2s", compactDuration(&buf, 4210));
    try std.testing.expectEqualStrings("2m05s", compactDuration(&buf, 125_000));
}

test "compactBytes matches the web UI's units" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 B", compactBytes(&buf, 512));
    try std.testing.expectEqualStrings("48 KB", compactBytes(&buf, 49_152));
    try std.testing.expectEqualStrings("1.5 MB", compactBytes(&buf, 1024 * 1024 * 3 / 2));
}

test "the turn line carries every field it was given" {
    const line = try formatTurn(std.testing.allocator, .{
        .prompt_tokens = 1234,
        .completion_tokens = 567,
        .cache_hit_tokens = 800,
        .cache_miss_tokens = 200,
        .wall_ms = 4200,
        .cost_usd = 0.0031,
        .context_tokens = 12_345,
        .context_window = 128_000,
    });
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings(
        "[turn: 1234 in / 567 out \u{b7} 4.2s \u{b7} 135.0 tok/s \u{b7} cache 80% \u{b7} $0.0031 \u{b7} ctx 12.3k/128k (10%)]",
        line,
    );
}

test "an unpriced model drops the cost segment instead of claiming it was free" {
    const line = try formatTurn(std.testing.allocator, .{
        .prompt_tokens = 100,
        .completion_tokens = 20,
        .wall_ms = 1000,
        .cost_usd = null,
        .context_window = 0,
    });
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("[turn: 100 in / 20 out \u{b7} 1.0s \u{b7} 20.0 tok/s]", line);
    try std.testing.expect(std.mem.find(u8, line, "$") == null);
    try std.testing.expect(std.mem.find(u8, line, "cache") == null);
    try std.testing.expect(std.mem.find(u8, line, "ctx") == null);
}

test "a turn with no reported usage is not worth a line" {
    try std.testing.expect(!(TurnStats{ .wall_ms = 12 }).accounted());
    try std.testing.expect((TurnStats{ .completion_tokens = 1 }).accounted());
}

test "session strip matches the web UI field set" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), formatSession(&buf, .{}));
    const line = formatSession(&buf, .{
        .turns = 21,
        .steps = 1588,
        .llm_ms = 265 * 60_000 + 34_000,
        .tool_ms = 130 * 60_000 + 18_000,
        .ttft_ms_total = 3000,
        .ttft_samples = 1,
        .prompt_tokens = 682_000_000,
        .completion_tokens = 1_600_000,
        .cache_hit_tokens = 100,
        .cache_miss_tokens = 0,
    }).?;
    try std.testing.expectEqualStrings(
        "21 turns \u{b7} 1588 steps | LLM 265m34s \u{b7} Tool call 130m18s | TTFT avg 3.0s \u{b7} 100 tok/s | Cache hit 100% | Input 682.0M tok \u{b7} Output 1.6M tok",
        line,
    );
}

test "live session strip shows a turn before any tokens land" {
    var buf: [256]u8 = undefined;
    const line = formatSession(&buf, .{
        .turns = 1,
        .steps = 1,
        .llm_ms = 400,
        .live_ttft_ms = 320,
    }).?;
    try std.testing.expect(std.mem.startsWith(u8, line, "1 turn \u{b7} 1 step"));
    try std.testing.expect(std.mem.indexOf(u8, line, "TTFT 320ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "Input") == null);
}

test "contextMeter is null without a window" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), contextMeter(&buf, 1000, 0));
    try std.testing.expectEqualStrings("ctx 6.0k/64.0k (9%)", contextMeter(&buf, 6000, 64_000).?);
}

test "formatCompaction reports only a compaction that actually dropped something" {
    const none = try formatCompaction(std.testing.allocator, .{
        .messages_before = 8,
        .messages_after = 8,
        .bytes_before = 100,
        .bytes_after = 100,
    });
    try std.testing.expectEqual(@as(?[]u8, null), none);

    const one = (try formatCompaction(std.testing.allocator, .{
        .messages_before = 9,
        .messages_after = 8,
        .bytes_before = 2048,
        .bytes_after = 1024,
    })).?;
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("[history compacted: dropped 1 message, freed 1 KB]", one);

    const many = (try formatCompaction(std.testing.allocator, .{
        .messages_before = 20,
        .messages_after = 8,
        .bytes_before = 100_000,
        .bytes_after = 50_672,
    })).?;
    defer std.testing.allocator.free(many);
    try std.testing.expectEqualStrings("[history compacted: dropped 12 messages, freed 48 KB]", many);
}

test "historyBytes counts tool-call arguments, not just content" {
    const msgs = [_]types.Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "c1", .name = "read", .arguments = "12345678" }} },
        .{ .role = .user, .content = "abcde" },
    };
    try std.testing.expectEqual(@as(usize, 16), historyBytes(&msgs));
    try std.testing.expectEqual(@as(usize, 4), historyTokens(&msgs));
}

test "summaryState finds both placeholder spellings and lifts the count out" {
    const msgs = [_]types.Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "[conversation summary \u{2014} 42 earlier messages compacted]\nblah" },
        .{ .role = .user, .content = "[earlier conversation compacted \u{2014} the context is summarized above]" },
        .{ .role = .assistant, .content = "ordinary answer mentioning 7 things" },
    };
    const st = summaryState(&msgs);
    try std.testing.expectEqual(@as(usize, 2), st.markers);
    try std.testing.expectEqual(@as(usize, 42), st.messages);
}

test "formatSummaryNotice fires only on a new summary, with or without a count" {
    const quiet = try formatSummaryNotice(std.testing.allocator, .{ .markers = 1, .messages = 42 }, .{ .markers = 1, .messages = 42 });
    try std.testing.expectEqual(@as(?[]u8, null), quiet);

    const counted = (try formatSummaryNotice(
        std.testing.allocator,
        .{ .markers = 0, .messages = 0 },
        .{ .markers = 1, .messages = 42 },
    )).?;
    defer std.testing.allocator.free(counted);
    try std.testing.expectEqualStrings("[context compacted: 42 earlier messages replaced by a summary to fit the model window]", counted);

    // The static fallback placeholder names no count; the notice still fires.
    const uncounted = (try formatSummaryNotice(
        std.testing.allocator,
        .{ .markers = 0, .messages = 0 },
        .{ .markers = 1, .messages = 0 },
    )).?;
    defer std.testing.allocator.free(uncounted);
    try std.testing.expectEqualStrings("[context compacted: earlier messages replaced by a summary to fit the model window]", uncounted);
}
