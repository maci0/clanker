//! repo_search: search the project with ripgrep / ast-grep / semcode.
//! Input:  {"engine": "rg"|"ast-grep"|"semcode", "query": "...", "path": "."}
//! Output: {"ok": bool, "code": int, "stdout": "...", "stderr": "..."}

const std = @import("std");
const lib = @import("lib.zig");

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
            const parsed_native = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, native, .{}) catch
                return lib.fail(out, "could not read the search result");
            try s2.write(parsed_native);
            try s2.endObject();
            out.len = w.end;
            return;
        }
        return lib.failErr(out, err, "running the search");
    };

    // For ast-grep, parse the exec result into structured matches.
    if (std.mem.eql(u8, engine, "ast-grep")) {
        const ag_parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, result, .{ .ignore_unknown_fields = true }) catch
            return lib.fail(out, "search ran but its result was not readable JSON; narrow the query or the path");
        if (ag_parsed != .object) return lib.fail(out, "search ran but its result was not a JSON object; narrow the query or the path");

        const ag_code: i64 = if (ag_parsed.object.get("code")) |c| switch (c) {
            .integer => |i| i,
            else => 1,
        } else 1;
        const ag_stdout = if (ag_parsed.object.get("stdout")) |sv| switch (sv) {
            .string => |ss| ss,
            else => "",
        } else "";
        const ag_stderr = if (ag_parsed.object.get("stderr")) |sv| switch (sv) {
            .string => |ss| ss,
            else => "",
        } else "";

        // Exit code 1 with no stderr is the grep convention for "no
        // matches" (same as rg). Only treat it as an error when stderr
        // carries a message or the code is >= 2.
        if (ag_code == 1 and std.mem.trim(u8, ag_stderr, " \t\r\n").len == 0) {
            return lib.okText(out, "no matches");
        }
        // Non-zero exit: return a structured error with a hint when the
        // grammar or config is missing.
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
                try s.write(if (ag_stderr.len > cap) ag_stderr[0..cap] else ag_stderr);
            } else {
                try s.write("ast-grep exited with non-zero status");
            }
            // Detect grammar/config issues and add an actionable hint.
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

        // Parse ast-grep output lines into compact {file, line, text} matches.
        // ast-grep prints one match per line: "file:line:col:text" or just text.
        var w = lib.writer(out);
        var s = lib.json(&w);
        try s.beginObject();
        try s.objectField("ok");
        try s.write(true);
        try s.objectField("matches");
        try s.beginArray();

        var match_count: usize = 0;
        const max_matches: usize = 200;
        var ag_rest: []const u8 = ag_stdout;
        while (ag_rest.len > 0 and match_count < max_matches) {
            const ag_nl = std.mem.findScalar(u8, ag_rest, '\n');
            const ag_line = if (ag_nl) |n| ag_rest[0..n] else ag_rest;
            ag_rest = if (ag_nl) |n| ag_rest[n + 1 ..] else &[_]u8{};

            const trimmed = std.mem.trim(u8, ag_line, " \t\r\n");
            if (trimmed.len == 0) continue;

            // ast-grep default output: "path/file.zig:LINE:COL:matched text"
            var file_path: []const u8 = "";
            var line_num: []const u8 = "";
            var text: []const u8 = trimmed;

            // Try to split "file:line:col:text" — at least 3 colons for a
            // well-formed match. The file path may itself contain colons on
            // non-Unix systems, but Zig paths in this project do not.
            if (std.mem.findScalar(u8, trimmed, ':')) |c1| {
                const after1 = trimmed[c1 + 1 ..];
                if (std.mem.findScalar(u8, after1, ':')) |c2| {
                    const after2 = after1[c2 + 1 ..];
                    // Verify the segment between c1 and c2 looks numeric (line number).
                    const num_candidate = after1[0..c2];
                    var is_num = num_candidate.len > 0;
                    for (num_candidate) |ch| {
                        if (ch < '0' or ch > '9') {
                            is_num = false;
                            break;
                        }
                    }
                    if (is_num) {
                        file_path = trimmed[0..c1];
                        line_num = num_candidate;
                        // Skip col field if present.
                        if (std.mem.findScalar(u8, after2, ':')) |c3| {
                            text = after2[c3 + 1 ..];
                        } else {
                            text = after2;
                        }
                    }
                }
            }

            const display = if (text.len > 500) text[0..500] else text;

            try s.beginObject();
            try s.objectField("file");
            try s.write(file_path);
            try s.objectField("line");
            try s.write(line_num);
            try s.objectField("text");
            try s.write(display);
            try s.endObject();
            match_count += 1;
        }

        try s.endArray();
        if (match_count >= max_matches) {
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

    // For rg --json, parse the JSON-lines output into compact matches.
    if (std.mem.eql(u8, engine, "rg")) {
        // Extract stdout from the exec result.
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
        const max_matches: usize = 200;
        var rest: []const u8 = stdout;
        while (rest.len > 0 and match_count < max_matches) {
            // Find the end of this line.
            const nl = std.mem.findScalar(u8, rest, '\n');
            const line = if (nl) |n| rest[0..n] else rest;
            rest = if (nl) |n| rest[n + 1 ..] else &[_]u8{};

            if (line.len == 0) continue;

            const line_parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, line, .{ .ignore_unknown_fields = true }) catch continue;
            if (line_parsed != .object) continue;

            // Only process "match" type lines.
            const type_val = line_parsed.object.get("type") orelse continue;
            if (type_val != .string) continue;
            if (!std.mem.eql(u8, type_val.string, "match")) continue;

            const data = line_parsed.object.get("data") orelse continue;
            if (data != .object) continue;

            // Extract file path.
            var file_path: []const u8 = "";
            if (data.object.get("path")) |p2| {
                if (p2 == .object) {
                    if (p2.object.get("text")) |t| {
                        if (t == .string) file_path = t.string;
                    }
                }
            }

            // Extract line number.
            var line_number: i64 = 0;
            if (data.object.get("line_number")) |ln| {
                if (ln == .integer) line_number = ln.integer;
            }

            // Extract matched text.
            var line_text: []const u8 = "";
            if (data.object.get("lines")) |lines| {
                if (lines == .object) {
                    if (lines.object.get("text")) |t| {
                        if (t == .string) line_text = t.string;
                    }
                }
            }

            // Trim trailing newlines/carriage returns from the matched text.
            const trimmed = std.mem.trimEnd(u8, line_text, "\r\n");
            // Cap individual line length to keep output compact.
            const display = if (trimmed.len > 500) trimmed[0..500] else trimmed;

            try s.beginObject();
            try s.objectField("file");
            try s.write(file_path);
            try s.objectField("line");
            try s.print("{d}", .{line_number});
            try s.objectField("text");
            try s.write(display);
            try s.endObject();
            match_count += 1;
        }

        try s.endArray();
        if (match_count >= max_matches) {
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
