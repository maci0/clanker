//! Single-pass top-level field scanner for tool manifests. tools and
//! plugins need four small fields out of each of ~90 manifests, and a
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
    var out: [1]?[]const u8 = .{null};
    topLevelValues(raw, &.{key}, &out);
    return out[0];
}

/// The same spans for several keys in one pass: `out[i]` is `keys[i]`'s span,
/// or null when that key is absent. `out.len` must equal `keys.len`.
///
/// A caller wanting four fields used to call `topLevelValue` four times, and
/// every key that sits after `input_schema` in the manifest (`category`,
/// `internal`, `transform` all do) makes that call walk the whole schema tree
/// to reach it. Three full reads of every manifest is where `clanker tools
/// list` spent most of its runtime under wasm interpretation; this reads each
/// manifest once and stops as soon as every key is answered.
pub fn topLevelValues(raw: []const u8, keys: []const []const u8, out: []?[]const u8) void {
    std.debug.assert(keys.len == out.len);
    @memset(out, null);
    if (keys.len == 0) return;
    var remaining = keys.len;
    var i = std.mem.findScalar(u8, raw, '{') orelse return;
    i += 1;
    var depth: usize = 1;
    var expecting_key = true;
    // Index into `keys` of the key the current value belongs to, or `keys.len`
    // when this pair's key is not one we were asked for.
    var current: usize = keys.len;
    while (i < raw.len) {
        const c = raw[i];
        switch (c) {
            ' ', '\t', '\r', '\n', ',', ':' => i += 1,
            '"' => {
                const end = stringEnd(raw, i) orelse return;
                if (depth == 1 and expecting_key) {
                    current = matchKey(raw[i + 1 .. end], keys, out);
                    expecting_key = false;
                } else if (depth == 1) {
                    if (take(out, current, raw[i .. end + 1])) {
                        remaining -= 1;
                        if (remaining == 0) return;
                    }
                    expecting_key = true;
                }
                i = end + 1;
            },
            '{', '[' => {
                const end = spanEnd(raw, i) orelse return;
                if (depth == 1 and !expecting_key) {
                    if (take(out, current, raw[i .. end + 1])) {
                        remaining -= 1;
                        if (remaining == 0) return;
                    }
                    expecting_key = true;
                }
                i = end + 1;
            },
            '}' => {
                depth -= 1;
                if (depth == 0) return;
                i += 1;
            },
            else => {
                // Bare scalar: number / true / false / null.
                const start = i;
                while (i < raw.len and raw[i] != ',' and raw[i] != '}' and raw[i] != ']' and
                    raw[i] != ' ' and raw[i] != '\t' and raw[i] != '\r' and raw[i] != '\n') i += 1;
                if (depth == 1 and !expecting_key) {
                    if (take(out, current, raw[start..i])) {
                        remaining -= 1;
                        if (remaining == 0) return;
                    }
                    expecting_key = true;
                }
            },
        }
    }
}

/// Index of the first still-unanswered key equal to `raw_key`, or `keys.len`.
/// A repeated top-level key keeps its first value, which is what asking one
/// key at a time did.
fn matchKey(raw_key: []const u8, keys: []const []const u8, out: []const ?[]const u8) usize {
    for (keys, 0..) |k, idx| {
        if (out[idx] == null and keyEquals(raw_key, k)) return idx;
    }
    return keys.len;
}

/// Records `span` for slot `idx`; true when that filled a slot that was empty.
fn take(out: []?[]const u8, idx: usize, span: []const u8) bool {
    if (idx >= out.len or out[idx] != null) return false;
    out[idx] = span;
    return true;
}

/// A top-level string field, JSON-decoded (escapes resolved). Allocates only
/// when the value contains an escape; a clean string is a borrow of `raw`.
pub fn topLevelString(alloc: std.mem.Allocator, raw: []const u8, key: []const u8) ?[]const u8 {
    return decodeString(alloc, topLevelValue(raw, key) orelse return null);
}

/// The text of a string `span` from `topLevelValues`, escapes resolved, or
/// null when the span is not a string. Allocates only when the value contains
/// an escape; a clean string is a borrow of the span.
pub fn decodeString(alloc: std.mem.Allocator, span: []const u8) ?[]const u8 {
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

test "one pass answers several keys, and matches asking for each alone" {
    const raw =
        \\{"name":"x","description":"d","input_schema":{"properties":{"category":{"description":"nested"}}},"internal":true,"category":"web","transform":{"after":["y"]}}
    ;
    const keys = [_][]const u8{ "description", "internal", "category", "transform", "missing" };
    var out: [keys.len]?[]const u8 = undefined;
    topLevelValues(raw, &keys, &out);
    for (keys, out) |k, span| {
        try t.expectEqual(topLevelValue(raw, k) == null, span == null);
        if (span) |s| try t.expectEqualStrings(topLevelValue(raw, k).?, s);
    }
    try t.expectEqualStrings("\"web\"", out[2].?);
    try t.expectEqualStrings("{\"after\":[\"y\"]}", out[3].?);
    try t.expect(out[4] == null);
}

test "duplicate top-level key keeps the first value" {
    const raw =
        \\{"category":"web","category":"code"}
    ;
    var out: [1]?[]const u8 = undefined;
    topLevelValues(raw, &.{"category"}, &out);
    try t.expectEqualStrings("\"web\"", out[0].?);
}
