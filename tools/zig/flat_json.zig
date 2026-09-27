//! Minimal flat-JSON field readers for tools/zig/read_file.zig. The guest is a
//! sandboxed wasm module, where a `test` block can never run, so these pure
//! readers live here and `zig build test` runs their tests on the host.

const std = @import("std");

/// Minimal field readers: the guest has no allocator, and the arguments object
/// is small and flat, so a full JSON parse would cost more than it returns.
pub fn fieldValue(input: []const u8, name: []const u8) ?[]const u8 {
    var key_buf: [64]u8 = undefined;
    if (name.len + 2 > key_buf.len) return null;
    key_buf[0] = '"';
    @memcpy(key_buf[1 .. 1 + name.len], name);
    key_buf[1 + name.len] = '"';
    const key = key_buf[0 .. name.len + 2];

    const at = std.mem.find(u8, input, key) orelse return null;
    var i = at + key.len;
    while (i < input.len and (input[i] == ' ' or input[i] == ':')) i += 1;
    if (i >= input.len) return null;
    return input[i..];
}

pub fn jsonString(input: []const u8, name: []const u8) ?[]const u8 {
    const rest = fieldValue(input, name) orelse return null;
    if (rest.len == 0 or rest[0] != '"') return null;
    const end = std.mem.findScalar(u8, rest[1..], '"') orelse return null;
    return rest[1 .. 1 + end];
}

// A schema-typed "integer" field is not proof the caller sent a bare number:
// nothing between the model and this guest validates that, and a quoted
// "603" is a real shape models produce. Skipping a leading quote here is the
// difference between silently reading from byte 0 (wrong file location, no
// error) and honoring what was plainly meant.
pub fn jsonUintOpt(input: []const u8, name: []const u8) ?usize {
    var rest = fieldValue(input, name) orelse return null;
    if (rest.len > 0 and rest[0] == '"') rest = rest[1..];
    var n: usize = 0;
    var digits: usize = 0;
    for (rest) |c| {
        if (c < '0' or c > '9') break;
        n = n *| 10 +| (c - '0');
        digits += 1;
    }
    return if (digits == 0) null else n;
}

pub fn jsonBool(input: []const u8, name: []const u8) bool {
    const rest = fieldValue(input, name) orelse return false;
    return std.mem.startsWith(u8, rest, "true");
}

pub fn jsonUint(input: []const u8, name: []const u8, fallback: usize) usize {
    return jsonUintOpt(input, name) orelse fallback;
}

test "jsonUintOpt reads a bare number and a quoted one alike" {
    try std.testing.expectEqual(@as(?usize, 603), jsonUintOpt("{\"start_line\":603}", "start_line"));
    try std.testing.expectEqual(@as(?usize, 603), jsonUintOpt("{\"start_line\":\"603\"}", "start_line"));
    try std.testing.expectEqual(@as(?usize, null), jsonUintOpt("{\"path\":\"x\"}", "start_line"));
}

test "jsonUint falls back only when no digits are present at all" {
    try std.testing.expectEqual(@as(usize, 40), jsonUint("{\"line_count\":40}", "line_count", 200));
    try std.testing.expectEqual(@as(usize, 40), jsonUint("{\"line_count\":\"40\"}", "line_count", 200));
    try std.testing.expectEqual(@as(usize, 200), jsonUint("{}", "line_count", 200));
}

// --------------------------------------------------------------- fuzz target

/// These readers are the whole of the argument parsing for every guest that
/// uses them, and the input is whatever a model emitted for a tool call: not
/// a schema-validated object, often a truncated or prose-wrapped one. The
/// Smith corpus is the shapes seen in the wild, because random bytes rarely
/// produce a key that *almost* matches.
const fuzz_corpus = [_][]const u8{
    "{\"path\":\"src/cli.zig\"}",
    "{\"path\":\"a\",\"start_line\":603,\"line_count\":40}",
    "{\"path\":\"a\",\"start_line\":\"603\"}",
    "{\"line_count\":40,\"end_line\":40}",
    "{\"path\":\"/etc/shadow\"}",
    "{\"path\":\"\",\"start_line\":0}",
    "{\"hashes\":true,\"op\":\"hashline\",\"path\":\"x\"}",
    "{\"path\":\"\\u00e9\\ud83d\\ude00\"}",
    "{\"path\":\"a\",\"path\":\"b\"}",
    "{\"path\":\"unterminated",
    "{\"path\":\"\\\"quoted\\\"\"}",
    "{\"path\":\"x\" , \"start_line\" : 12}",
    "{\"start_line\":18446744073709551616}",
    "{\"start_line\":-5}",
    "{\"start_line\":999999999999}",
    "{\"start_line\":null}",
    "{\"path\":\"a\",\"start_line\":1,\"line_count\":1e3}",
    "{\"a\":{\"b\":{\"c\":1}},\"path\":\"deep\"}",
    "[]",
    "{\"line_count\":true}",
    "{\"line_count\":\"  7  \"}",
};

/// The field names the round-trip oracle writes, all of them names a real
/// caller asks these readers for.
const oracle_fields = [_][]const u8{ "path", "line_count", "start_line", "end_line" };

test "fuzz: field readers answer only with bytes of the input they were given" {
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var in_buf: [512]u8 = undefined;
            var name_buf: [16]u8 = undefined;
            const input = in_buf[0..smith.slice(&in_buf)];
            const name = name_buf[0..smith.slice(&name_buf)];

            // A reader may answer "absent", but every answer it does give must
            // be bytes of the input it was handed. A slice reaching past the
            // end is the bug a caller cannot see: it reads as a value, and the
            // sandbox hands it on to whatever consumes the argument.
            if (fieldValue(input, name)) |v| try expectWithin(input, v);
            if (jsonString(input, name)) |v| try expectWithin(input, v);
            if (jsonUintOpt(input, name)) |v| {
                // Saturated, not wrapped: an absurd line number from a model
                // must land on the largest number rather than a small one that
                // looks like a real offset into a real file.
                try std.testing.expect(v > 0);
            }
            _ = jsonBool(input, name);
            _ = jsonUint(input, name, if (name.len == 0) 0 else name.len * 7);

            // Oracle, not just an invariant: an argument object written by a
            // real serializer must read back as the value that was written.
            // The name is drawn from a fixed list rather than the fuzzed one,
            // because a random name is never a field name any caller asks for
            // and the oracle would then never run. Only bytes needing no JSON
            // escaping are used: the readers scan for the closing quote
            // without tracking escapes, and that is a separate question.
            const field = oracle_fields[smith.index(oracle_fields.len)];
            var value: [64]u8 = undefined;
            const raw = value[0..smith.slice(&value)];
            if (!plainJsonString(raw)) return;
            var doc: [128]u8 = undefined;
            const written = try std.fmt.bufPrint(&doc, "{{\"{s}\":\"{s}\"}}", .{ field, raw });
            const got = jsonString(written, field) orelse {
                try std.testing.expect(false);
                return;
            };
            try std.testing.expectEqualStrings(raw, got);
        }

        fn expectWithin(input: []const u8, slice: []const u8) !void {
            const start = @intFromPtr(input.ptr);
            const got = @intFromPtr(slice.ptr);
            try std.testing.expect(got >= start);
            try std.testing.expect(got + slice.len <= start + input.len);
        }

        fn plainJsonString(raw: []const u8) bool {
            for (raw) |c| {
                if (c == '"' or c == '\\' or c < 0x20) return false;
            }
            return true;
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{ .corpus = &fuzz_corpus });
}
