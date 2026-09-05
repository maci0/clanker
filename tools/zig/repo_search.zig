//! repo_search: search the project with ripgrep / ast-grep / semcode.
//! Input:  {"engine": "rg"|"ast-grep"|"semcode", "query": "...", "path": "."}
//! Output: {"ok": bool, "code": int, "stdout": "...", "stderr": "..."}

const std = @import("std");
const lib = @import("lib.zig");
const utf8 = @import("utf8");
const grep_outline = @import("grep_outline.zig");

const match_cap: usize = 200;

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object with \"query\" and optional \"engine\"");
    const obj = parsed.object;
    const engine = if (obj.get("engine")) |value| switch (value) {
        .string => |s| s,
        else => return lib.fail(out, "engine must be a string"),
    } else "ast-grep";
    const query = switch (obj.get("query") orelse return lib.fail(out, "missing query")) {
        .string => |s| s,
        else => return lib.fail(out, "query must be a string"),
    };
    const path = if (obj.get("path")) |p| switch (p) {
        .string => |s| s,
        else => ".",
    } else ".";

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(lib.alloc);

    if (std.mem.eql(u8, engine, "rg")) {
        try args.append(lib.alloc, "--json");
        try args.append(lib.alloc, "-n");
        try args.append(lib.alloc, query);
        try args.append(lib.alloc, path);
    } else if (std.mem.eql(u8, engine, "ast-grep")) {
        try args.append(lib.alloc, "run");
        // ast-grep ships no Zig parser; sgconfig.yml registers one built by
        // tools/grammars/build.sh. Passing the config always (not only for
        // .zig) also picks up any rules the project defines.
        try args.append(lib.alloc, "--config");
        try args.append(lib.alloc, "sgconfig.yml");
        if (std.mem.endsWith(u8, path, ".zig") or std.mem.find(u8, path, ".") == null) {
            // The Zig grammar is a custom language, so it has to be named:
            // ast-grep will not infer it from the extension alone.
            try args.append(lib.alloc, "-l");
            try args.append(lib.alloc, "zig");
        }
        try args.append(lib.alloc, "-p");
        try args.append(lib.alloc, query);
        try args.append(lib.alloc, path);
    } else if (std.mem.eql(u8, engine, "semcode")) {
        try args.append(lib.alloc, "-q");
        try args.append(lib.alloc, query);
    } else {
        return lib.fail(out, "engine must be rg | ast-grep | semcode");
    }

    const result = lib.exec(engine, args.items) catch |err| {
        // rg is an external binary and may simply not be installed, in which
        // case the only text search this agent has would fail outright. The
        // host can walk the tree itself, so answer from that instead of
        // reporting that search is unavailable.
        if (err == error.NotFound and std.mem.eql(u8, engine, "rg")) {
            const native = lib.fsGrep(path, query) catch
                return lib.failErr(out, err, "running the search");
            const parsed_native = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, native, .{}) catch
                return lib.fail(out, "could not read the search result");
            var w = out.writer();
            var s2 = std.json.Stringify{ .writer = &w, .options = .{} };
            try s2.beginObject();
            try s2.objectField("ok");
            try s2.write(true);
            try s2.objectField("engine");
            try s2.write("host");
            try s2.objectField("note");
            try s2.write("rg is not installed; this is the host's own literal search, which takes no regular expressions or flags");
            try s2.objectField("matches");
            try grep_outline.writeNativeMatches(&s2, parsed_native, struct {
                pub fn readFile(p: []const u8) ?[]const u8 {
                    return lib.fsRead(p) catch null;
                }
            });
            try s2.endObject();
            out.len = w.end;
            return;
        }
        return lib.failErr(out, err, "running the search");
    };

    if (std.mem.eql(u8, engine, "ast-grep")) {
        const ag_parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, result, .{ .ignore_unknown_fields = true }) catch
            return lib.fail(out, "search ran but its result was not readable JSON; narrow the query or the path");
        if (ag_parsed != .object) return lib.fail(out, "search ran but its result was not a JSON object; narrow the query or the path");

        const ag_code: i64 = if (ag_parsed.object.get("code")) |c| switch (c) {
            .integer => |i| i,
            else => 1,
        } else 1;
        const ag_stdout = lib.jsonStrField(ag_parsed.object, "stdout");
        const ag_stderr = lib.jsonStrField(ag_parsed.object, "stderr");

        // Exit code 1 with no stderr is the grep convention for "no
        // matches" (same as rg). Only treat it as an error when stderr
        // carries a message or the code is >= 2.
        if (ag_code == 1 and std.mem.trim(u8, ag_stderr, " \t\r\n").len == 0) {
            return lib.okText(out, "no matches");
        }
        if (ag_code != 0) {
            var w = lib.writer(out);
            var s = lib.json(&w);
            try s.beginObject();
            try s.objectField("ok");
            try s.write(false);
            try s.objectField("code");
            try s.print("{d}", .{ag_code});
            try s.objectField("error");
            if (ag_stderr.len > 0) {
                const cap: usize = 2048;
                try s.write(utf8.cap(ag_stderr, cap));
            } else {
                try s.write("ast-grep exited with non-zero status");
            }
            if (std.mem.find(u8, ag_stderr, "language") != null or
                std.mem.find(u8, ag_stderr, "config") != null or
                std.mem.find(u8, ag_stderr, "sgconfig") != null or
                std.mem.find(u8, ag_stderr, "Cannot find") != null)
            {
                try s.objectField("hint");
                try s.write("run tools/grammars/build.sh to build the Zig tree-sitter grammar, then retry");
            }
            try s.endObject();
            lib.commit(out, &w);
            return;
        }

        if (ag_stdout.len == 0) {
            return lib.okText(out, "no matches");
        }

        // ast-grep prints one match per line: "file:line:col:text" or just text.
        var w = lib.writer(out);
        var s = lib.json(&w);
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("matches");
        try s.beginArray();

        var match_count: usize = 0;
        var ag_rest: []const u8 = ag_stdout;
        while (ag_rest.len > 0 and match_count < match_cap) {
            const ag_nl = std.mem.findScalar(u8, ag_rest, '\n');
            const ag_line = if (ag_nl) |n| ag_rest[0..n] else ag_rest;
            ag_rest = if (ag_nl) |n| ag_rest[n + 1 ..] else &[_]u8{};

            const trimmed = std.mem.trim(u8, ag_line, " \t\r\n");
            if (trimmed.len == 0) continue;

            var file_path: []const u8 = "";
            var line_num: []const u8 = "";
            var line_n: u32 = 0;
            var text: []const u8 = trimmed;

            // Split "file:line:col:text". Zig paths in this project do not
            // themselves contain colons, so the first numeric field is the line.
            if (std.mem.findScalar(u8, trimmed, ':')) |c1| {
                const after1 = trimmed[c1 + 1 ..];
                if (std.mem.findScalar(u8, after1, ':')) |c2| {
                    const after2 = after1[c2 + 1 ..];
                    if (std.fmt.parseInt(u32, after1[0..c2], 10)) |n| {
                        file_path = trimmed[0..c1];
                        line_num = after1[0..c2];
                        line_n = n;
                        text = if (std.mem.findScalar(u8, after2, ':')) |c3| after2[c3 + 1 ..] else after2;
                    } else |_| {}
                }
            }

            const display = utf8.cap(text, 500);

            try s.beginObject();
            try s.objectField("file");
            try s.write(file_path);
            try s.objectField("line");
            try s.write(line_num);
            try s.objectField("text");
            try s.write(display);
            try writeOutline(&s, file_path, line_n);
            try s.endObject();
            match_count += 1;
        }

        try s.endArray();
        if (match_count >= match_cap) {
            var omitted: usize = 0;
            while (ag_rest.len > 0) {
                const snl = std.mem.findScalar(u8, ag_rest, '\n');
                const sline = if (snl) |n| ag_rest[0..n] else ag_rest;
                ag_rest = if (snl) |n| ag_rest[n + 1 ..] else &[_]u8{};
                if (std.mem.trim(u8, sline, " \t\r\n").len > 0) omitted += 1;
            }
            try s.objectField("truncated");
            try s.write(true);
            try s.objectField("truncated_count");
            try s.print("{d}", .{omitted});
        }
        try s.endObject();
        lib.commit(out, &w);
        return;
    }

    if (std.mem.eql(u8, engine, "rg")) {
        const exec_parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, result, .{ .ignore_unknown_fields = true }) catch
            return lib.fail(out, "search ran but its result was not readable JSON; narrow the query or the path");
        if (exec_parsed != .object) return lib.fail(out, "search ran but its result was not a JSON object; narrow the query or the path");
        const stdout_val = exec_parsed.object.get("stdout") orelse return lib.fail(out, "search ran but its result had no stdout; narrow the query or the path");
        const stdout = if (stdout_val == .string) stdout_val.string else return lib.fail(out, "search ran but its stdout was not text; narrow the query or the path");
        if (stdout.len == 0) {
            return lib.okText(out, "no matches");
        }

        var w = lib.writer(out);
        var s = lib.json(&w);
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("matches");
        try s.beginArray();

        var match_count: usize = 0;
        var rest: []const u8 = stdout;
        while (rest.len > 0 and match_count < match_cap) {
            const nl = std.mem.findScalar(u8, rest, '\n');
            const line = if (nl) |n| rest[0..n] else rest;
            rest = if (nl) |n| rest[n + 1 ..] else &[_]u8{};

            if (line.len == 0) continue;

            const line_parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, line, .{ .ignore_unknown_fields = true }) catch continue;
            if (line_parsed != .object) continue;

            const type_val = line_parsed.object.get("type") orelse continue;
            if (type_val != .string) continue;
            if (!std.mem.eql(u8, type_val.string, "match")) continue;

            const data = line_parsed.object.get("data") orelse continue;
            if (data != .object) continue;

            var file_path: []const u8 = "";
            if (data.object.get("path")) |p2| {
                if (p2 == .object) file_path = lib.jsonStrField(p2.object, "text");
            }

            var line_number: i64 = 0;
            if (data.object.get("line_number")) |ln| {
                if (ln == .integer) line_number = ln.integer;
            }

            var line_text: []const u8 = "";
            if (data.object.get("lines")) |lines| {
                if (lines == .object) line_text = lib.jsonStrField(lines.object, "text");
            }

            const display = utf8.cap(std.mem.trimEnd(u8, line_text, "\r\n"), 500);

            try s.beginObject();
            try s.objectField("file");
            try s.write(file_path);
            try s.objectField("line");
            try s.print("{d}", .{line_number});
            try s.objectField("text");
            try s.write(display);
            const rg_line_n: u32 = if (line_number > 0) std.math.cast(u32, line_number) orelse 0 else 0;
            try writeOutline(&s, file_path, rg_line_n);
            try s.endObject();
            match_count += 1;
        }

        try s.endArray();
        if (match_count >= match_cap) {
            // Count remaining match-type lines so the agent knows how many were omitted.
            var omitted: usize = 0;
            var scan = rest;
            while (scan.len > 0) {
                const snl = std.mem.findScalar(u8, scan, '\n');
                const sline = if (snl) |n| scan[0..n] else scan;
                scan = if (snl) |n| scan[n + 1 ..] else &[_]u8{};
                if (sline.len == 0) continue;
                // Quick check before full parse: line must contain "match".
                if (std.mem.find(u8, sline, "\"match\"") == null) continue;
                const sp = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, sline, .{ .ignore_unknown_fields = true }) catch continue;
                if (sp != .object) continue;
                const st = sp.object.get("type") orelse continue;
                if (st != .string) continue;
                if (std.mem.eql(u8, st.string, "match")) omitted += 1;
            }
            try s.objectField("truncated");
            try s.write(true);
            try s.objectField("truncated_count");
            try s.print("{d}", .{omitted});
        }
        try s.endObject();
        lib.commit(out, &w);
        return;
    }

    try out.writeAll(result);
}

fn writeOutline(s: anytype, file_path: []const u8, line_number: u32) !void {
    if (file_path.len == 0 or line_number == 0) return;
    const src = lib.fsRead(file_path) catch return;
    try grep_outline.writeSymbolFields(s, src, line_number);
}
