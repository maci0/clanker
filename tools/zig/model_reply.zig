//! Getting the JSON object out of a model's reply.
//!
//! A model asked for JSON answers with JSON wrapped in a ``` fence about as
//! often as it answers with bare JSON, and sometimes with a sentence around
//! either. Five guests (`arena_match`, `compare`, `chain`, `mutate`,
//! `translate`) each carried their own copy of the same two loops for that,
//! in two spellings: `stripFence`, which trimmed its own input, and
//! `stripFences`, which required every caller to trim first. One
//! implementation, so a reply shape that one guest learns to read is a reply
//! shape they all read.

const std = @import("std");

/// The body of a ``` fence, or `raw` trimmed when there is no fence. Trims
/// its own input: a reply that opens with a blank line is still fenced.
pub fn stripFence(raw: []const u8) []const u8 {
    var s = std.mem.trim(u8, raw, " \t\r\n");
    if (!std.mem.startsWith(u8, s, "```")) return s;
    s = s[3..];
    // Drop the info string ("json", "toml", ...) up to the newline. A fence
    // with no newline at all has no body to return.
    if (std.mem.findScalar(u8, s, '\n')) |newline| s = s[newline + 1 ..];
    if (std.mem.findLast(u8, s, "```")) |close| s = s[0..close];
    return std.mem.trim(u8, s, " \t\r\n");
}

/// The first balanced `{...}` span in `s`, or null when there is none.
/// Brace-counting rather than a JSON parse, so it can find the object inside
/// a reply that also carries prose; braces inside string literals (and the
/// backslash escapes that could hide a closing quote) do not count.
pub fn objectSpan(s: []const u8) ?[]const u8 {
    const start = std.mem.findScalar(u8, s, '{') orelse return null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i = start;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (in_string) {
            switch (c) {
                '\\' => escaped = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                // Gated by the `{` search above, so depth is at least 1 by
                // the time any `}` is reached and this never underflows.
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return s[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

test "stripFence handles fenced, bare, and untidy replies" {
    try std.testing.expectEqualStrings("{\"a\":1}", stripFence("{\"a\":1}"));
    try std.testing.expectEqualStrings("{\"a\":1}", stripFence("```json\n{\"a\":1}\n```"));
    try std.testing.expectEqualStrings("{\"a\":1}", stripFence("```\n{\"a\":1}\n```"));
    // The `stripFences` spelling left this fenced unless the caller trimmed
    // first, and three of the five call sites were the ones doing the trim.
    try std.testing.expectEqualStrings("{\"a\":1}", stripFence("\n  ```json\n{\"a\":1}\n```\n\n"));
    // An unterminated fence still yields its body rather than nothing.
    try std.testing.expectEqualStrings("{\"a\":1}", stripFence("```json\n{\"a\":1}"));
    try std.testing.expectEqualStrings("", stripFence("   "));
}

test "objectSpan finds the object and ignores braces inside strings" {
    try std.testing.expectEqualStrings("{\"a\":1}", objectSpan("noise {\"a\":1} tail").?);
    try std.testing.expectEqualStrings("{\"a\":{\"b\":2}}", objectSpan("{\"a\":{\"b\":2}}").?);
    try std.testing.expectEqualStrings("{\"a\":\"}\"}", objectSpan("{\"a\":\"}\"}").?);
    try std.testing.expectEqualStrings("{\"a\":\"\\\"}\"}", objectSpan("{\"a\":\"\\\"}\"}").?);
    try std.testing.expect(objectSpan("no object here") == null);
    try std.testing.expect(objectSpan("{\"a\":1") == null);
}
