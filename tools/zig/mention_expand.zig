//! Expand composer @rel/path mentions into fenced file bytes (ADR 0041 / PRD 0052).
//! Host-tested helper; the REPL submit path calls it.

const std = @import("std");

pub const per_file_cap: usize = 32 * 1024;

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Truncate on a UTF-8 codepoint boundary. A mid-codepoint cut is not a
/// shorter string, it is invalid UTF-8, and the expanded text goes straight
/// into a provider request body and the saved session. `src/util/utf8.zig`
/// is the same function, but this file is linked into `src/` by name as well
/// as compiled as a host-tested helper, and a file may belong to only one
/// module per compilation, so the copy stays local (as in `advisor_logic`).
fn capUtf8(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    var end = max_bytes;
    // gated on s.len > max_bytes, so end < s.len: the read is in bounds.
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

fn isEmailAt(text: []const u8, at: usize) bool {
    if (at == 0) return false;
    const before = text[at - 1];
    if (!std.ascii.isAlphanumeric(before) and before != '_') return false;
    if (at + 1 >= text.len) return false;
    const after = text[at + 1];
    if (!std.ascii.isAlphanumeric(after) and after != '_') return false;
    // A path mention always has a slash or a dot-segment after @; an email
    // has none of those before the next whitespace.
    const rest = pathToken(text[at + 1 ..]);
    return std.mem.findScalar(u8, rest, '/') == null;
}

fn pathToken(s: []const u8) []const u8 {
    var n: usize = 0;
    while (n < s.len) : (n += 1) {
        if (isWs(s[n])) break;
    }
    return s[0..n];
}

/// `ctx.refuse(path)` and `ctx.readFile(path) ?[]const u8`.
pub fn expandAlloc(gpa: std.mem.Allocator, text: []const u8, ctx: anytype) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '@' and (i == 0 or isWs(text[i - 1])) and !isEmailAt(text, i)) {
            const path = pathToken(text[i + 1 ..]);
            if (path.len > 0) {
                if (ctx.refuse(path)) {
                    try out.appendSlice(gpa, text[i .. i + 1 + path.len]);
                    try out.appendSlice(gpa, "\n[mention refused: ");
                    try out.appendSlice(gpa, path);
                    try out.appendSlice(gpa, "]\n");
                    i += 1 + path.len;
                    continue;
                }
                if (ctx.readFile(path)) |src| {
                    const body = capUtf8(src, per_file_cap);
                    try out.appendSlice(gpa, "\n```");
                    try out.appendSlice(gpa, path);
                    try out.appendSlice(gpa, "\n");
                    try out.appendSlice(gpa, body);
                    if (src.len > per_file_cap) try out.appendSlice(gpa, "\n[truncated]");
                    try out.appendSlice(gpa, "\n```\n");
                    i += 1 + path.len;
                    continue;
                }
            }
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

test "expandAlloc inlines a relative path" {
    const Ctx = struct {
        pub fn refuse(_: @This(), _: []const u8) bool {
            return false;
        }
        pub fn readFile(_: @This(), path: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, path, "src/foo.zig")) return "pub fn foo() void {}\n";
            return null;
        }
    };
    const got = try expandAlloc(std.testing.allocator, "see @src/foo.zig please", Ctx{});
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.find(u8, got, "```src/foo.zig") != null);
    try std.testing.expect(std.mem.find(u8, got, "pub fn foo() void {}") != null);
}

test "expandAlloc leaves email addresses alone" {
    const Ctx = struct {
        pub fn refuse(_: @This(), _: []const u8) bool {
            return false;
        }
        pub fn readFile(_: @This(), _: []const u8) ?[]const u8 {
            return "LEAK";
        }
    };
    const got = try expandAlloc(std.testing.allocator, "mail a@b.com thanks", Ctx{});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("mail a@b.com thanks", got);
}

test "expandAlloc refuses a path ctx.refuse names" {
    const Ctx = struct {
        pub fn refuse(_: @This(), path: []const u8) bool {
            return std.mem.eql(u8, path, ".env");
        }
        pub fn readFile(_: @This(), _: []const u8) ?[]const u8 {
            return "SECRET=1\n";
        }
    };
    const got = try expandAlloc(std.testing.allocator, "do not read @.env", Ctx{});
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.find(u8, got, "SECRET") == null);
    try std.testing.expect(std.mem.find(u8, got, "mention refused: .env") != null);
}

test "expandAlloc truncates a file over the cap" {
    const Ctx = struct {
        pub fn refuse(_: @This(), _: []const u8) bool {
            return false;
        }
        pub fn readFile(_: @This(), _: []const u8) ?[]const u8 {
            return "x" ** (per_file_cap + 8);
        }
    };
    const got = try expandAlloc(std.testing.allocator, "@big.txt", Ctx{});
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.find(u8, got, "[truncated]") != null);
}

test "expandAlloc with no mentions is byte-identical" {
    const Ctx = struct {
        pub fn refuse(_: @This(), _: []const u8) bool {
            return false;
        }
        pub fn readFile(_: @This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    const src = "no mentions here";
    const got = try expandAlloc(std.testing.allocator, src, Ctx{});
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(src, got);
}

test "expandAlloc truncates on a UTF-8 boundary" {
    // A raw `src[0..per_file_cap]` cut lands between the two bytes of one
    // codepoint here, so the fenced block ships invalid UTF-8 to the provider
    // and into the saved session.
    const Ctx = struct {
        pub fn refuse(_: @This(), _: []const u8) bool {
            return false;
        }
        pub fn readFile(_: @This(), _: []const u8) ?[]const u8 {
            // One ASCII byte first, so every following codepoint starts on an
            // odd offset and a cut at the even `per_file_cap` lands on the
            // second byte of one.
            return "a" ++ "\u{00e9}" ** (per_file_cap / 2 + 4);
        }
    };
    const got = try expandAlloc(std.testing.allocator, "@wide.txt", Ctx{});
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.find(u8, got, "[truncated]") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
}
