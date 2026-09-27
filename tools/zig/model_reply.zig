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
const fuzz_corpus = @import("fuzz_corpus");

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

// --------------------------------------------------------------- fuzz target

/// Both functions run over raw model output, which is the one input an
/// attacker steers through a prompt, and both are hand-rolled scanners whose
/// whole job is to survive a reply that is truncated mid-object, fenced twice,
/// or full of braces inside strings. The corpus is those shapes: random bytes
/// reach the `}`-inside-a-string case far too rarely to matter.
const seed_corpus = [_][]const u8{
    "{\"a\":1}",
    "```json\n{\"a\":1}\n```",
    "Sure! Here you go:\n```json\n{\"move\":\"thrust\",\"conf\":0.9}\n```\nHope that helps.",
    "```json\n{\"a\":1",
    "{\"a\":\"}\",\"b\":\"{\"}",
    "{\"a\":\"\\\"}\"}",
    "{{{{{{{{{{",
    "}}}}}}}}}}",
    "{\"a\":\"\\\\\"}",
    "{\"outer\":{\"inner\":{\"deep\":[1,2,{\"x\":\"}\"}]}}}",
    "\n\n```\n\n{}\n```\n\n",
    "```json\n```json\n{}\n```",
    "no json at all",
    "",
    "\x00\x01\xff{\"a\":1}",
};

test "fuzz: a fenced reply yields a span that is a balanced subslice of the reply" {
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const raw = buf[0..smith.slice(&buf)];

            // Both answers are always windows into the text they were given,
            // never into a scratch buffer, because every caller hands the
            // result straight to `std.json` and expects it to outlive nothing.
            const body = stripFence(raw);
            try expectWithin(raw, body);
            const span = objectSpan(body) orelse return;
            try expectWithin(raw, span);

            // A span is claimed to be one balanced object. Braces inside
            // string literals do not count, so the walk has to be repeated
            // here with the same rule to check the answer rather than trust it.
            try std.testing.expectEqual(@as(u8, '{'), span[0]);
            try std.testing.expectEqual(@as(u8, '}'), span[span.len - 1]);
            try std.testing.expectEqual(@as(usize, 0), unbalancedDepth(span));
        }

        /// `slice` must be a window into `input`: a caller reads the result as
        /// a slice of the reply, so a value pointing anywhere else is a bug
        /// with no visible symptom until it is dereferenced.
        fn expectWithin(input: []const u8, slice: []const u8) !void {
            const start = @intFromPtr(input.ptr);
            const got = @intFromPtr(slice.ptr);
            try std.testing.expect(got >= start);
            try std.testing.expect(got + slice.len <= start + input.len);
        }

        /// Final brace depth after the walk `objectSpan` performs, minus the
        /// opening brace it consumed. Non-zero means the span closes early.
        fn unbalancedDepth(span: []const u8) usize {
            var depth: isize = 0;
            var in_string = false;
            var escaped = false;
            for (span) |c| {
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
                    '}' => depth -= 1,
                    else => {},
                }
            }
            return @intCast(@max(depth, 0));
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{ .corpus = &seed_corpus });
}
