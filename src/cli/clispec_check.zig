//! Drives the clanker binary. The unit tests cannot supply a real argv to
//! `main`, so this is the check that schema, `-o json`, and a JSON-mode failure
//! go through the entry point.

const std = @import("std");

const empty_dir = ".scratch/clispec-empty";

pub fn main(minimal: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var it = minimal.args.iterate();
    _ = it.next();
    const bin_arg = it.next() orelse {
        std.debug.print("clispec_check: missing clanker path\n", .{});
        return error.MissingBinary;
    };
    // The build runner passes a cache-relative path. A quiet run chdirs
    // before exec, so that relative path would miss the binary.
    const bin = try std.Io.Dir.cwd().realPathFileAlloc(io, bin_arg, arena);

    try std.Io.Dir.cwd().createDirPath(io, empty_dir);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("PATH", "/usr/bin:/bin");
    const quiet: std.process.Child.Cwd = .{ .path = empty_dir };

    const schema = try run(gpa, io, bin, &.{"schema"}, &env, quiet);
    try expectExit(schema, 0);
    const root = try parseObject(arena, schema.stdout);
    try expectStr(root, "clispec", "0.3");
    try expectStr(root, "name", "clanker");
    const version = try fieldStr(root, "version");
    const output = try fieldObj(root, "output");
    try expectStr(output, "tty", "text");
    try expectStr(output, "piped", "text");
    try expectOutputArg(root);
    const commands = try fieldArr(root, "commands");
    if (commands.items.len == 0) return error.EmptyCommands;
    try expectErrors(root);

    const schema_text = try run(gpa, io, bin, &.{ "-o", "text", "schema" }, &env, quiet);
    try expectExit(schema_text, 0);
    if (!startsJson(schema_text.stdout)) return error.SchemaWasNotJson;

    const filtered = try run(gpa, io, bin, &.{ "schema", "doctor" }, &env, quiet);
    try expectExit(filtered, 0);
    const one = try parseObject(arena, filtered.stdout);
    const one_cmds = try fieldArr(one, "commands");
    if (one_cmds.items.len != 1) return error.FilterMissed;
    const doctor_cmd = switch (one_cmds.items[0]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    try expectStr(doctor_cmd, "name", "doctor");
    try expectStr(doctor_cmd, "cardinality", "bounded");

    const missing = try run(gpa, io, bin, &.{ "schema", "nope-nope" }, &env, quiet);
    try expectExit(missing, 2);
    if (startsJson(missing.stdout)) return error.UsageWroteStdout;
    if (startsJson(lastLine(missing.stderr))) return error.TextModeWasJson;

    const missing_json = try run(gpa, io, bin, &.{ "-o", "json", "schema", "nope-nope" }, &env, quiet);
    try expectExit(missing_json, 2);
    if (startsJson(missing_json.stdout)) return error.UsageWroteStdout;
    try expectKind(arena, missing_json.stderr, "usage");

    const version_text = try run(gpa, io, bin, &.{ "-o", "text", "--version" }, &env, quiet);
    try expectExit(version_text, 0);
    const want = try std.fmt.allocPrint(arena, "clanker {s}\n", .{version});
    if (!std.mem.eql(u8, version_text.stdout, want)) return error.TextVersion;
    if (startsJson(version_text.stdout)) return error.TextModeWasJson;

    const version_json = try run(gpa, io, bin, &.{ "--output=json", "--version" }, &env, quiet);
    try expectExit(version_json, 0);
    const ver = try parseObject(arena, version_json.stdout);
    try expectStr(ver, "name", "clanker");
    try expectStr(ver, "version", version);

    const bad = try run(gpa, io, bin, &.{ "-o", "json", "--not-a-flag" }, &env, quiet);
    try expectExit(bad, 2);
    try expectKind(arena, bad.stderr, "usage");

    const repl = try run(gpa, io, bin, &.{ "-o", "json", "repl" }, &env, quiet);
    try expectExit(repl, 1);
    if (startsJson(repl.stdout)) return error.ReplWroteStdout;
    try expectKind(arena, repl.stderr, "tty_required");

    const help = try run(gpa, io, bin, &.{"--help"}, &env, quiet);
    try expectExit(help, 0);
    if (std.mem.indexOf(u8, help.stdout, "schema") == null) return error.HelpMissedSchema;
    if (std.mem.indexOf(u8, help.stdout, "--output") == null) return error.HelpMissedOutput;

    // Doctor reads the checkout. It is offline and may exit 1 when a check fails.
    const doctor_json = try run(gpa, io, bin, &.{ "-o", "json", "doctor" }, null, .inherit);
    const doctor_code = exitCode(doctor_json);
    if (doctor_code != 0 and doctor_code != 1) {
        std.debug.print("doctor -o json exit {d}\nstdout: {s}\nstderr: {s}\n", .{ doctor_code, doctor_json.stdout, doctor_json.stderr });
        return error.Exit;
    }
    const doc = try parseObject(arena, doctor_json.stdout);
    const items = try fieldArr(doc, "items");
    if (items.items.len == 0) return error.EmptyItems;
    const item = switch (items.items[0]) {
        .object => |o| o,
        else => return error.NotObject,
    };
    _ = try fieldStr(item, "section");
    _ = try fieldStr(item, "status");
    _ = try fieldStr(item, "label");
    _ = try fieldStr(item, "detail");
    if (doctor_code == 0) {
        if (startsJson(lastLine(doctor_json.stderr))) return error.SuccessHadEnvelope;
    } else {
        try expectKind(arena, doctor_json.stderr, "failure");
    }

    const doctor_text = try run(gpa, io, bin, &.{ "-o", "text", "doctor" }, null, .inherit);
    const text_code = exitCode(doctor_text);
    if (text_code != 0 and text_code != 1) return error.Exit;
    if (!std.mem.startsWith(u8, doctor_text.stdout, "clanker doctor")) return error.DoctorText;
    if (startsJson(doctor_text.stdout)) return error.TextModeWasJson;
}

fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    args: []const []const u8,
    env: ?*const std.process.Environ.Map,
    cwd: std.process.Child.Cwd,
) !std.process.RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, args);
    defer argv.deinit(gpa);
    return std.process.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = env,
        .cwd = cwd,
    });
}

fn exitCode(result: std.process.RunResult) u8 {
    return switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
}

fn expectExit(result: std.process.RunResult, code: u8) !void {
    if (exitCode(result) != code) {
        std.debug.print("exit {d}, want {d}\nstdout: {s}\nstderr: {s}\n", .{ exitCode(result), code, result.stdout, result.stderr });
        return error.Exit;
    }
}

fn parseObject(arena: std.mem.Allocator, bytes: []const u8) !std.json.ObjectMap {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return error.NotJson;
    return switch (value) {
        .object => |o| o,
        else => error.NotObject,
    };
}

fn fieldStr(obj: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return switch (obj.get(name) orelse return error.MissingField) {
        .string => |s| s,
        else => error.NotString,
    };
}

fn expectStr(obj: std.json.ObjectMap, name: []const u8, want: []const u8) !void {
    const got = try fieldStr(obj, name);
    if (!std.mem.eql(u8, got, want)) return error.Field;
}

fn fieldObj(obj: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    return switch (obj.get(name) orelse return error.MissingField) {
        .object => |o| o,
        else => error.NotObject,
    };
}

fn fieldArr(obj: std.json.ObjectMap, name: []const u8) !std.json.Array {
    return switch (obj.get(name) orelse return error.MissingField) {
        .array => |a| a,
        else => error.NotArray,
    };
}

fn expectOutputArg(root: std.json.ObjectMap) !void {
    const args = try fieldArr(root, "global_args");
    for (args.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = fieldStr(obj, "name") catch continue;
        if (!std.mem.eql(u8, name, "--output")) continue;
        try expectStr(obj, "default", "auto");
        const values = try fieldArr(obj, "enum");
        var saw_json = false;
        for (values.items) |value| {
            if (value == .string and std.mem.eql(u8, value.string, "json")) saw_json = true;
        }
        if (!saw_json) return error.OutputEnum;
        return;
    }
    return error.MissingOutput;
}

fn expectErrors(root: std.json.ObjectMap) !void {
    const errs = try fieldArr(root, "errors");
    var usage = false;
    var failure = false;
    var tty = false;
    for (errs.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.NotObject,
        };
        const kind = try fieldStr(obj, "kind");
        const code = switch (obj.get("exit_code") orelse return error.MissingField) {
            .integer => |n| n,
            else => return error.NotInteger,
        };
        if (std.mem.eql(u8, kind, "usage")) {
            usage = true;
            if (code != 2) return error.UsageCode;
        }
        if (std.mem.eql(u8, kind, "failure")) {
            failure = true;
            if (code != 1) return error.FailureCode;
        }
        if (std.mem.eql(u8, kind, "tty_required")) {
            tty = true;
            if (code != 1) return error.TtyCode;
        }
    }
    if (!usage or !failure or !tty) return error.MissingKind;
}

fn expectKind(arena: std.mem.Allocator, stderr: []const u8, kind: []const u8) !void {
    const envelope = try parseObject(arena, lastLine(stderr));
    const err_obj = try fieldObj(envelope, "error");
    try expectStr(err_obj, "kind", kind);
    const message = try fieldStr(err_obj, "message");
    if (message.len == 0) return error.EmptyMessage;
    _ = try fieldStr(err_obj, "hint");
}

fn lastLine(s: []const u8) []const u8 {
    var t = s;
    while (t.len > 0 and (t[t.len - 1] == '\n' or t[t.len - 1] == '\r')) t = t[0 .. t.len - 1];
    if (std.mem.lastIndexOfScalar(u8, t, '\n')) |i| return t[i + 1 ..];
    return t;
}

fn startsJson(s: []const u8) bool {
    return s.len > 0 and s[0] == '{';
}
