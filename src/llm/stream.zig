//! Machine-readable usage lines for tools watching a clanker run.
//!
//! `--stream` makes every model response also print one JSON object to stdout,
//! alongside the ordinary prose. A monitor reading the process (gauntlet's
//! dashboard, tokentop) can then show live tokens-per-second without waiting
//! for the run to end or scraping `state/token_stats.jsonl` afterwards.
//!
//! Deliberately additive: the human-facing output is unchanged, and a reader
//! that does not understand JSON simply sees one more line. That is why this
//! emits usage only rather than converting the whole run to an event stream:
//! the numbers are what a monitor cannot otherwise get, and the prose is
//! already readable.
//!
//! Writes are best effort. A closed or full stdout must never take down a run
//! that is otherwise working, so every error here is dropped.

const std = @import("std");

/// Whether `--stream` was given. Set once during argument parsing, read from
/// the model call path; a plain global because the alternative is threading a
/// display concern through every call site between the two.
pub var enabled: bool = false;

/// Usage from one model response, in the provider's own terms.
pub const Usage = struct {
    provider: []const u8,
    model: []const u8,
    prompt_tokens: u64,
    completion_tokens: u64,
    total_tokens: u64,
    reasoning_tokens: u64 = 0,
    cache_hit: u64 = 0,
    duration_ms: u64 = 0,
};

/// Prints one usage line. A no-op unless `--stream` is on.
///
/// The record is serialized by `std.json.Stringify`, the same way the durable
/// token log writes its own rows: hand-assembled JSON gets the escaping wrong
/// the first time a model or provider name contains a quote.
pub fn emitUsage(io: std.Io, u: Usage) void {
    if (!enabled) return;
    var buf: [1024]u8 = undefined;
    const line = render(&buf, u) catch return; // a name long enough to overflow is not worth a line
    std.Io.File.stdout().writeStreamingAll(io, line) catch {};
}

/// The wire record. Field names are the OpenAI spellings, which is what every
/// reader of these streams already parses; `type` names the record so a reader
/// can tell it apart from whatever else shares the stream.
const Line = struct {
    type: []const u8 = "usage",
    provider: []const u8,
    model: []const u8,
    prompt_tokens: u64,
    completion_tokens: u64,
    total_tokens: u64,
    reasoning_tokens: u64,
    cache_hit: u64,
    duration_ms: u64,
};

/// render is emitUsage without the writing, so a test can read what a monitor
/// would receive.
fn render(buf: []u8, u: Usage) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    var s = std.json.Stringify{ .writer = &w };
    try s.write(Line{
        .provider = u.provider,
        .model = u.model,
        .prompt_tokens = u.prompt_tokens,
        .completion_tokens = u.completion_tokens,
        .total_tokens = u.total_tokens,
        .reasoning_tokens = u.reasoning_tokens,
        .cache_hit = u.cache_hit,
        .duration_ms = u.duration_ms,
    });
    try w.writeByte('\n');
    return w.buffered();
}

test "emitUsage stays silent unless enabled" {
    // The default must be off: a run that nobody asked to stream should print
    // nothing extra, since its stdout is read by humans.
    try std.testing.expect(!enabled);
}

test "a usage line is one object on one line" {
    var buf: [1024]u8 = undefined;
    const line = try render(&buf, .{
        // A quote in a name must not break the object, which is the whole
        // reason this goes through Stringify rather than a print.
        .provider = "a\"b",
        .model = "m",
        .prompt_tokens = 1,
        .completion_tokens = 2,
        .total_tokens = 3,
    });

    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("usage", obj.get("type").?.string);
    try std.testing.expectEqualStrings("a\"b", obj.get("provider").?.string);
    try std.testing.expectEqual(@as(i64, 2), obj.get("completion_tokens").?.integer);
    try std.testing.expectEqual(@as(i64, 3), obj.get("total_tokens").?.integer);
}
