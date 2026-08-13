//! Single-pass top-level field scanner for tool manifests. cmd_tools and
//! cmd_plugins need four small fields out of each of ~90 manifests, and a
//! full std.json parse of every manifest — input_schema trees included —
//! under wasm interpretation was where `clanker tools list` spent over a
//! second of its runtime. This walks the bytes once, tracking depth and
//! string state, and only looks at keys of the root object; a nested
//! "description" inside input_schema can never match. Imports nothing from
//! the guest ABI, so `zig build test` runs these tests on the host
//! (build.zig host_tested_helpers).

const std = @import("std");

/// The raw JSON value span of a top-level `key`, or null when absent or the
/// input is not an object. The span is exactly the value's bytes: a string
/// span includes its quotes, an object/array span its braces/brackets.
pub fn topLevelValue(raw: []const u8, key: []const u8) ?[]const u8 {
    var i = std.mem.findScalar(u8, raw, '{') orelse return null;
    i += 1;
    var depth: usize = 1;
    var expecting_key = true;
    var current_matches = false;
    while (i < raw.len) {
        const c = raw[i];
        switch (c) {
            ' ', '\t', '\r', '\n', ',', ':' => i += 1,
            '"' => {
                const end = stringEnd(raw, i) orelse return null;
                if (depth == 1 and expecting_key) {
                    current_matches = keyEquals(raw[i + 1 .. end], key);
                    expecting_key = false;
                } else if (depth == 1) {
                    if (current_matches) return raw[i .. end + 1];
                    expecting_key = true;
                }
                i = end + 1;
            },
            '{', '[' => {
                const end = spanEnd(raw, i) orelse return null;
                if (depth == 1 and !expecting_key) {
                    if (current_matches) return raw[i .. end + 1];
                    expecting_key = true;
                }
                i = end + 1;
            },
            '}' => {
                depth -= 1;
                if (depth == 0) return null;
                i += 1;
            },
            else => {
                // Bare scalar: number / true / false / null.
                const start = i;
                while (i < raw.len and raw[i] != ',' and raw[i] != '}' and raw[i] != ']' and
                    raw[i] != ' ' and raw[i] != '\t' and raw[i] != '\r' and raw[i] != '\n') i += 1;
                if (depth == 1 and !expecting_key) {
                    if (current_matches) return raw[start..i];
                    expecting_key = true;
                }
            },
        }
    }
    return null;
}

/// A top-level string field, JSON-decoded (escapes resolved). Allocates only
/// when the value contains an escape; a clean string is a borrow of `raw`.
pub fn topLevelString(alloc: std.mem.Allocator, raw: []const u8, key: []const u8) ?[]const u8 {
    const span = topLevelValue(raw, key) orelse return null;
    if (span.len < 2 or span[0] != '"') return null;
    const inner = span[1 .. span.len - 1];
    if (std.mem.findScalar(u8, inner, '\\') == null) return inner;
    // Rare path: let std.json decode just this one small string token.
    const parsed = std.json.parseFromSliceLeaky([]const u8, alloc, span, .{}) catch return null;
    return parsed;
}

/// True when a top-level field is the literal `true`.
pub fn topLevelIsTrue(raw: []const u8, key: []const u8) bool {
    const span = topLevelValue(raw, key) orelse return false;
    return std.mem.eql(u8, span, "true");
}

/// True when the top-level key exists at all, whatever its value.
pub fn topLevelPresent(raw: []const u8, key: []const u8) bool {
    return topLevelValue(raw, key) != null;
}

/// Index of the closing quote of the string starting at `start` (a `"`).
fn stringEnd(raw: []const u8, start: usize) ?usize {
    var i = start + 1;
    var escaped = false;
    while (i < raw.len) : (i += 1) {
        if (escaped) {
            escaped = false;
            continue;
        }
        switch (raw[i]) {
            '\\' => escaped = true,
            '"' => return i,
            else => {},
        }
    }
    return null;
}

/// Index of the matching close brace/bracket for the open at `start`,
/// honouring strings so a brace inside "text" cannot end the span early.
fn spanEnd(raw: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var i = start;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
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
            '{', '[' => depth += 1,
            '}', ']' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Key comparison on the raw (possibly escaped) key bytes. Manifest keys are
/// plain identifiers, so escapes in a key simply never match ours.
fn keyEquals(raw_key: []const u8, key: []const u8) bool {
    return std.mem.eql(u8, raw_key, key);
}

const t = std.testing;

test "finds top-level string and skips nested keys of the same name" {
    const raw =
        \\{"name":"x","input_schema":{"properties":{"q":{"description":"nested"}}},"description":"the real one"}
    ;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("the real one", topLevelString(arena.allocator(), raw, "description").?);
}

test "decodes escaped strings" {
    const raw =
        \\{"description":"say \"hi\"\nthen stop"}
    ;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("say \"hi\"\nthen stop", topLevelString(arena.allocator(), raw, "description").?);
}

test "bool and presence" {
    const raw =
        \\{"internal":true,"transform":{"after":["x"]},"fuel":100}
    ;
    try t.expect(topLevelIsTrue(raw, "internal"));
    try t.expect(!topLevelIsTrue(raw, "fuel"));
    try t.expect(topLevelPresent(raw, "transform"));
    try t.expect(!topLevelPresent(raw, "wasm"));
}

test "absent key, non-object input, unterminated string" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expect(topLevelString(arena.allocator(), "{\"a\":1}", "b") == null);
    try t.expect(topLevelValue("[1,2]", "a") == null);
    try t.expect(topLevelValue("not json", "a") == null);
    try t.expect(topLevelValue("{\"a\":\"unterminated", "a") == null);
}

test "value with braces inside a string does not end the span early" {
    const raw =
        \\{"config":{"tpl":"}{"},"category":"web"}
    ;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("web", topLevelString(arena.allocator(), raw, "category").?);
}
