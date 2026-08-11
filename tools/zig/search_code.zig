//! search_code: search the project with ripgrep / ast-grep / semcode.
//! Input:  {"engine": "rg"|"ast-grep"|"semcode", "query": "...", "path": "."}
//! Output: {"ok": bool, "code": int, "stdout": "...", "stderr": "..."}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    const obj = parsed.object;
    const engine = switch (obj.get("engine") orelse return lib.fail(out, "missing engine")) {
        .string => |s| s,
        else => return lib.fail(out, "engine must be a string"),
    };
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
        if (std.mem.endsWith(u8, path, ".zig") or std.mem.indexOf(u8, path, ".") == null) {
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
        return lib.fail(out, @errorName(err));
    };

    // For rg --json, parse the JSON-lines output into compact matches.
    if (std.mem.eql(u8, engine, "rg")) {
        // Extract stdout from the exec result.
        const exec_parsed = std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, result, .{ .ignore_unknown_fields = true }) catch
            return out.writeAll(result);
        if (exec_parsed != .object) return out.writeAll(result);
        const stdout_val = exec_parsed.object.get("stdout") orelse return out.writeAll(result);
        const stdout = if (stdout_val == .string) stdout_val.string else return out.writeAll(result);
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
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
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
                const snl = std.mem.indexOfScalar(u8, scan, '\n');
                const sline = if (snl) |n| scan[0..n] else scan;
                scan = if (snl) |n| scan[n + 1 ..] else &[_]u8{};
                if (sline.len == 0) continue;
                // Quick check before full parse: line must contain "match".
                if (std.mem.indexOf(u8, sline, "\"match\"") == null) continue;
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
