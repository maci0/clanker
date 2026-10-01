//! Minimal .env loader: reads KEY=VALUE lines from $CLANKER_ENV_FILE (or
//! ./.env) and fills them into the process environ map WITHOUT overriding
//! values already present in the real environment. Lines starting with '#'
//! are comments; an optional `export ` prefix is accepted; values may be
//! single- or double-quoted; an unquoted value ends at a `#` that whitespace
//! introduces (`KEY=value  # staging`), so a side note never becomes part of
//! the value it annotates. A `#` glued to the value (`KEY=a#b`) or opening
//! it (`KEY=#b`) stays literal, as bash and python-dotenv read it.

const std = @import("std");
const log = @import("log.zig");
const env_name = @import("env_name.zig");

/// Ceiling on the `.env` file (or its `CLANKER_ENV_FILE` override). Past
/// this the file is refused rather than truncated, so a runaway file cannot
/// be read into a process that had no key.
const max_env_file_bytes: usize = 1 << 16;

pub fn load(io: std.Io, gpa: std.mem.Allocator, environ_map: *std.process.Environ.Map) void {
    loadFromDir(io, gpa, environ_map, std.Io.Dir.cwd());
}

fn loadFromDir(io: std.Io, gpa: std.mem.Allocator, environ_map: *std.process.Environ.Map, base: std.Io.Dir) void {
    const path: ?[]const u8 = if (environ_map.get("CLANKER_ENV_FILE")) |p| (if (p.len > 0) p else null) else null;

    const data = if (path) |p|
        base.readFileAlloc(io, p, gpa, .limited(max_env_file_bytes)) catch |err| {
            log.log(.warn, "cannot read CLANKER_ENV_FILE '{s}': {s}", .{ p, @errorName(err) });
            return;
        }
    else
        base.readFileAlloc(io, ".env", gpa, .limited(max_env_file_bytes)) catch |err| switch (err) {
            // A checkout with no .env is the normal state for a machine that
            // sets real environment variables; stay silent there. Anything
            // else -- permission denied, a file over the 64 KiB cap -- would
            // otherwise load no keys at all and surface as a baffling
            // "X_API_KEY not set" on the first provider call, so name it now.
            error.FileNotFound => return,
            else => {
                log.log(.warn, "cannot read .env: {s} (real environment variables still apply)", .{@errorName(err)});
                return;
            },
        };
    defer gpa.free(data);

    const file_name = path orelse ".env";
    var loaded: usize = 0;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export")) {
            const after_export = line["export".len..];
            if (after_export.len > 0 and (after_export[0] == ' ' or after_export[0] == '\t')) {
                line = std.mem.trimStart(u8, after_export, " \t");
            }
        }
        const eq = std.mem.findScalar(u8, line, '=') orelse {
            log.log(.warn, "{s}:{d}: '{s}' is not KEY=VALUE, skipped", .{ file_name, line_no, line });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) {
            log.log(.warn, "{s}:{d}: assignment has an empty key, skipped", .{ file_name, line_no });
            continue;
        }
        // A key no shell can export is a line the operator believes set a
        // secret and did not: the process environment accepts any string, so
        // this one would be readable here and unreachable from every child
        // process, a tool, or the next launch from a real shell. Named the
        // same way as the other malformed lines rather than loaded in
        // silence. The rule is `util/env_name`, shared with the config keys
        // that name a secret's source.
        if (!env_name.isEnvVarName(key)) {
            log.log(.warn, "{s}:{d}: '{s}' is not an environment variable name a shell can export, skipped", .{ file_name, line_no, key });
            continue;
        }
        const raw_value = line[eq + 1 ..];
        const value = valuePart(raw_value);
        if (unterminatedQuote(value)) {
            // The value is still taken literally (bash and python-dotenv
            // both refuse the line outright, but refusing here would drop a
            // key this process used to have), so the note has to name the
            // line: the quote travels with the value and every consumer of
            // the key then fails as a bad credential instead.
            log.log(.warn, "{s}:{d}: {s} value opens a quote it never closes, so the quote is part of the value", .{ file_name, line_no, key });
        }
        if (environ_map.get(key) != null) continue; // real env vars win
        environ_map.put(key, value) catch continue;
        loaded += 1;
    }
    if (loaded > 0) {
        log.log(.debug, "loaded {d} key(s) from {s}", .{ loaded, file_name });
    }
}

/// The value half of one line: trimmed, quotes stripped, inline comment cut.
/// Quoting is decided on the trimmed half first, so a `#` inside quotes is
/// part of the value; the comment cut then runs on the *raw* half, because
/// the whitespace that introduces the note (`KEY=  # note`) is what trimming
/// removes, and a `#` left holding the whole trimmed value must still read
/// as a comment there while staying literal when glued to a real value
/// (`KEY=v#t`, `KEY=#t`). What survives the cut may itself be quoted.
fn valuePart(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (quoted(trimmed)) |inner| return inner;
    if (inlineCommentEnd(raw)) |cut| {
        const kept = std.mem.trim(u8, raw[0..cut], " \t");
        if (quoted(kept)) |inner| return inner;
        return kept;
    }
    return trimmed;
}

/// A value that opens with a quote character and does not end with the same
/// one, so the quote survives into the value instead of being stripped.
fn unterminatedQuote(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] != '"' and value[0] != '\'') return false;
    return value.len < 2 or value[value.len - 1] != value[0];
}

fn quoted(value: []const u8) ?[]const u8 {
    if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or (value[0] == '\'' and value[value.len - 1] == '\''))) {
        return value[1 .. value.len - 1];
    }
    return null;
}

/// Index of the first `#` a space or tab introduces, so `KEY=a#b` and
/// `KEY=#b` keep their value whole (the same word-boundary rule bash uses)
/// while `KEY=v # note` ends at the note.
fn inlineCommentEnd(value: []const u8) ?usize {
    var i: usize = 1;
    while (i < value.len) : (i += 1) {
        if (value[i] == '#' and (value[i - 1] == ' ' or value[i - 1] == '\t')) return i;
    }
    return null;
}

// ------------------------------------------------------------------- tests --

test "dotenv parses and fills the environ map without overriding" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Silence the loader's debug log: stderr output from a test while the
    // runner is in --listen mode breaks the test protocol. Restored after,
    // since std.testing runs all tests in one process and a level left
    // dirty here would silence logs for every test that runs after.
    const saved_level = log.getLevel();
    log.setLevel(.warn);
    defer log.setLevel(saved_level);
    // Use a temp dir with a .env file.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data =
        \\# comment
        \\FOO=bar
        \\export QUOTED="hello world"
        \\EMPTY=
        \\SINGLE='single quoted'
        \\ALREADY=from-dotenv
        \\NOTED=value # staging note
        \\NOTE_ONLY=   # trailing note after an empty value
        \\GLUED=v#tag
        \\LEAD_HASH=#tag
        \\QUOTED_HASH="a # b"
        \\
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ALREADY", "from-real-env");

    loadFromDir(io, std.testing.allocator, &env, tmp.dir);

    try std.testing.expectEqualStrings("bar", env.get("FOO").?);
    try std.testing.expectEqualStrings("hello world", env.get("QUOTED").?);
    try std.testing.expectEqualStrings("", env.get("EMPTY").?);
    try std.testing.expectEqualStrings("single quoted", env.get("SINGLE").?);
    try std.testing.expectEqualStrings("from-real-env", env.get("ALREADY").?);
    // A side note is a comment, not part of the value: without the cut the
    // note rode along as the credential and every request 401'd with it.
    try std.testing.expectEqualStrings("value", env.get("NOTED").?);
    try std.testing.expectEqualStrings("", env.get("NOTE_ONLY").?);
    // No whitespace before '#': bash's rule, so the value keeps it.
    try std.testing.expectEqualStrings("v#tag", env.get("GLUED").?);
    try std.testing.expectEqualStrings("#tag", env.get("LEAD_HASH").?);
    try std.testing.expectEqualStrings("a # b", env.get("QUOTED_HASH").?);
}

test "dotenv accepts a tab after export" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const saved_level = log.getLevel();
    log.setLevel(.warn);
    defer log.setLevel(saved_level);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "export\tTABBED='tab value'\n" });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    loadFromDir(io, std.testing.allocator, &env, tmp.dir);

    try std.testing.expectEqualStrings("tab value", env.get("TABBED").?);
}

/// Captured log lines for the malformed-line test. A sink rather than
/// `log.setLevel`: the warnings under test are the only records this test
/// produces, and stderr output from a test breaks the runner's --listen
/// protocol.
const Capture = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn write(ctx: *const anyopaque, line: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(@constCast(ctx)));
        const room = self.buf.len - self.len;
        const n = @min(room, line.len);
        @memcpy(self.buf[self.len..][0..n], line[0..n]);
        self.len += n;
    }

    fn text(self: *const Capture) []const u8 {
        return self.buf[0..self.len];
    }
};

test "dotenv names a malformed line and still loads the rest of the file" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const saved_level = log.getLevel();
    log.setLevel(.warn);
    defer log.setLevel(saved_level);
    var capture: Capture = .{};
    log.setSink(.{ .ctx = &capture, .write = Capture.write });
    defer log.setSink(null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data =
        \\GOOD=first
        \\this line has no equals sign
        \\=orphan value
        \\HALF="unterminated
        \\BAD KEY=value
        \\LAST=last
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    loadFromDir(io, std.testing.allocator, &env, tmp.dir);

    // One bad line must not cost the file: each malformed entry is named
    // with the file and line that carries it, and every well-formed key
    // around it still lands. A silent skip is the failure this replaces --
    // the operator sees "X_API_KEY not set" and never learns the line existed.
    try std.testing.expectEqualStrings("first", env.get("GOOD").?);
    try std.testing.expectEqualStrings("last", env.get("LAST").?);
    try std.testing.expectEqualStrings("\"unterminated", env.get("HALF").?);
    // A key no shell could export must not be loaded: the process
    // environment would answer for it here and no child or next launch
    // would ever see it.
    try std.testing.expect(env.get("BAD KEY") == null);
    const lines = capture.text();
    try std.testing.expect(std.mem.indexOf(u8, lines, ".env:2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "not KEY=VALUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, ".env:3:") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "empty key") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, ".env:4:") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "never closes") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, ".env:5:") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "shell can export") != null);
}

test "a quoted value closes, so it is not reported as unterminated" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const saved_level = log.getLevel();
    log.setLevel(.warn);
    defer log.setLevel(saved_level);
    var capture: Capture = .{};
    log.setSink(.{ .ctx = &capture, .write = Capture.write });
    defer log.setSink(null);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The .env.example shape: a quoted value followed by a side note, which
    // must not read as an unclosed quote.
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "CLOSED=\"a b\"  # note\nPLAIN=v\n" });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    loadFromDir(io, std.testing.allocator, &env, tmp.dir);

    try std.testing.expectEqualStrings("a b", env.get("CLOSED").?);
    try std.testing.expectEqualStrings("v", env.get("PLAIN").?);
    try std.testing.expect(std.mem.indexOf(u8, capture.text(), "never closes") == null);
}

test "an unterminated quote is detected on the value that survives" {
    try std.testing.expect(unterminatedQuote("\"unterminated"));
    try std.testing.expect(unterminatedQuote("'x"));
    try std.testing.expect(unterminatedQuote("\""));
    try std.testing.expect(!unterminatedQuote("\"closed\""));
    try std.testing.expect(!unterminatedQuote("'closed'"));
    try std.testing.expect(!unterminatedQuote(""));
    try std.testing.expect(!unterminatedQuote("a\"b"));
}
