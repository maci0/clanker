//! Persistent Python eval-kernel supervisor (PRD 0016). One process per
//! (session, kind), stdio JSON lines, state in `__main__` across cells.
//! Host-tested so persist / reset / SIGTERM cannot drift from the PRD.
//!
//! Lives beside `host.zig` because `ck_kernel` is its only caller: this is
//! the privileged channel's implementation, not an agent-loop concern. The
//! process table it registers into stays in `agent/subprocess.zig`, which
//! DAP shares and which keys on the session.

const std = @import("std");
const subprocess = @import("../agent/subprocess.zig");
const utf8 = @import("../util/utf8.zig");

pub const supervisor_src =
    \\import ast, io, json, os, subprocess, sys, time, traceback
    \\ns = {"__name__": "__main__"}
    \\
    \\def reset():
    \\    global ns
    \\    ns = {"__name__": "__main__"}
    \\
    \\def run_cell(src):
    \\    stdout, stderr = io.StringIO(), io.StringIO()
    \\    result = None
    \\    ok = True
    \\    try:
    \\        tree = ast.parse(src, mode="exec")
    \\        body, last = (tree.body[:-1], tree.body[-1]) if tree.body else ([], None)
    \\        old_out, old_err = sys.stdout, sys.stderr
    \\        sys.stdout, sys.stderr = stdout, stderr
    \\        try:
    \\            if body:
    \\                exec(compile(ast.Module(body=body, type_ignores=[]), "<cell>", "exec"), ns, ns)
    \\            if last is not None:
    \\                if isinstance(last, ast.Expr):
    \\                    result = eval(compile(ast.Expression(last.value), "<cell>", "eval"), ns, ns)
    \\                else:
    \\                    exec(compile(ast.Module(body=[last], type_ignores=[]), "<cell>", "exec"), ns, ns)
    \\        finally:
    \\            sys.stdout, sys.stderr = old_out, old_err
    \\    except Exception:
    \\        ok = False
    \\        traceback.print_exc(file=stderr)
    \\    return ok, stdout.getvalue(), stderr.getvalue(), None if result is None else repr(result)
    \\
    \\def pip_install(spec):
    \\    args = spec.split()
    \\    cmd = [sys.executable, "-m", "pip"] + args
    \\    p = subprocess.run(cmd, capture_output=True, text=True)
    \\    return p.returncode == 0, p.stdout, p.stderr, None
    \\
    \\def run_bash(body):
    \\    p = subprocess.run(["bash", "-c", body], capture_output=True, text=True)
    \\    return p.returncode == 0, p.stdout, p.stderr, None
    \\
    \\for line in sys.stdin:
    \\    line = line.strip()
    \\    if not line:
    \\        continue
    \\    t0 = time.time()
    \\    try:
    \\        req = json.loads(line)
    \\    except Exception as e:
    \\        print(json.dumps({"ok": False, "error": str(e), "stdout": "", "stderr": "", "result": None}), flush=True)
    \\        continue
    \\    if req.get("reset"):
    \\        reset()
    \\        print(json.dumps({"ok": True, "reset": True, "stdout": "", "stderr": "", "result": None, "duration_ms": 0}), flush=True)
    \\        continue
    \\    if "pip" in req:
    \\        ok, out, err, result = pip_install(req["pip"])
    \\    elif "bash" in req:
    \\        ok, out, err, result = run_bash(req["bash"])
    \\    else:
    \\        ok, out, err, result = run_cell(req.get("cell") or "")
    \\    ms = int((time.time() - t0) * 1000)
    \\    print(json.dumps({"ok": ok, "stdout": out, "stderr": err, "result": result, "duration_ms": ms}), flush=True)
;

pub const Request = struct {
    cell: []const u8 = "",
    reset: bool = false,
    pip: ?[]const u8 = null,
    bash: ?[]const u8 = null,
};

pub const Response = struct {
    ok: bool,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    result: ?[]const u8 = null,
    duration_ms: u32 = 0,
    reset: bool = false,
    err: ?[]const u8 = null,
};

pub fn encodeRequest(arena: std.mem.Allocator, req: Request) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    if (req.reset) {
        try s.objectField("reset");
        try s.write(true);
    }
    if (req.pip) |p| {
        try s.objectField("pip");
        try s.write(p);
    } else if (req.bash) |b| {
        try s.objectField("bash");
        try s.write(b);
    } else {
        try s.objectField("cell");
        try s.write(req.cell);
    }
    try s.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn parseResponse(arena: std.mem.Allocator, line: []const u8) !Response {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    const obj = switch (parsed) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };
    const ok = switch (obj.get("ok") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };
    const stdout = switch (obj.get("stdout") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };
    const stderr = switch (obj.get("stderr") orelse std.json.Value{ .string = "" }) {
        .string => |s| s,
        else => "",
    };
    const result: ?[]const u8 = switch (obj.get("result") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        .null => null,
        else => null,
    };
    const duration: u32 = switch (obj.get("duration_ms") orelse std.json.Value{ .integer = 0 }) {
        .integer => |n| if (n < 0) 0 else @intCast(@min(n, std.math.maxInt(u32))),
        else => 0,
    };
    const reset = switch (obj.get("reset") orelse std.json.Value{ .bool = false }) {
        .bool => |b| b,
        else => false,
    };
    const err: ?[]const u8 = switch (obj.get("error") orelse std.json.Value{ .null = {} }) {
        .string => |s| s,
        else => null,
    };
    return .{
        .ok = ok,
        .stdout = stdout,
        .stderr = stderr,
        .result = result,
        .duration_ms = duration,
        .reset = reset,
        .err = err,
    };
}

pub const EvalOpts = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    reg: *subprocess.Registry,
    session_id: []const u8,
    kind: []const u8 = "python",
    cwd: std.process.Child.Cwd,
    cell: []const u8 = "",
    reset: bool = false,
    pip: ?[]const u8 = null,
    bash: ?[]const u8 = null,
    timeout_ms: u32 = 10_000,
    max_output_bytes: u32 = 65_536,
    python: []const u8 = "python3",
    enabled: bool = true,
};

pub const EvalError = error{
    KernelDisabled,
    Python3NotFound,
    KernelExited,
    Timeout,
    NotRegistered,
    NoPipes,
    NoStdin,
    NoStdout,
    StreamTooLong,
    ReadFailed,
    InvalidResponse,
    InvalidSessionId,
    EmptyKind,
    DeadChild,
    CwdNotWritable,
} || std.mem.Allocator.Error || std.Io.Writer.Error || std.process.SpawnError ||
    std.json.ParseFromValueError || std.json.ParseError(std.json.Scanner) ||
    std.Io.Writer.Error;

pub fn eval(opts: EvalOpts) EvalError![]u8 {
    if (!opts.enabled) return error.KernelDisabled;
    if (opts.reset) opts.reg.terminate(opts.session_id, opts.kind);
    try ensureSupervisor(opts);
    const line = try encodeRequest(opts.arena, .{
        .cell = opts.cell,
        .reset = false,
        .pip = opts.pip,
        .bash = opts.bash,
    });
    return roundTrip(opts, line);
}

fn ensureSupervisor(opts: EvalOpts) EvalError!void {
    if (opts.reg.get(opts.session_id, opts.kind) != null) return;
    try writeSupervisor(opts);
    var child = std.process.spawn(opts.io, .{
        .argv = &.{ opts.python, "supervisor.py" },
        .cwd = opts.cwd,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.Python3NotFound,
        else => return err,
    };
    _ = opts.reg.adopt(opts.session_id, opts.kind, child) catch |err| {
        child.kill(opts.io);
        return err;
    };
}

fn writeSupervisor(opts: EvalOpts) EvalError!void {
    switch (opts.cwd) {
        .inherit => return error.CwdNotWritable,
        .dir => |d| return writeSupervisorFile(d, opts.io),
        .path => |p| {
            std.Io.Dir.cwd().createDirPath(opts.io, p) catch return error.CwdNotWritable;
            var dir = std.Io.Dir.cwd().openDir(opts.io, p, .{}) catch return error.CwdNotWritable;
            defer dir.close(opts.io);
            return writeSupervisorFile(dir, opts.io);
        },
    }
}

fn writeSupervisorFile(dir: std.Io.Dir, io: std.Io) EvalError!void {
    dir.writeFile(io, .{ .sub_path = "supervisor.py", .data = supervisor_src }) catch
        return error.CwdNotWritable;
}

fn roundTrip(opts: EvalOpts, line: []const u8) EvalError![]u8 {
    const Killer = struct {
        io: std.Io,
        pid: std.posix.pid_t,
        ms: u32,
        cancel: *std.atomic.Value(bool),
        /// Set once the clock has run out, before the SIGTERM below, so the
        /// reader can tell a timeout-induced exit from a supervisor that
        /// exited on its own: the latter is a plain kernel failure, not a
        /// timeout.
        timed_out: *std.atomic.Value(bool),
        fn run(self: @This()) void {
            if (self.ms == 0) return;
            self.io.sleep(.{ .nanoseconds = @as(i96, self.ms) * std.time.ns_per_ms }, .awake) catch return;
            self.timed_out.store(true, .monotonic);
            if (!self.cancel.load(.monotonic)) {
                // Residual posix: signal delivery has no std.Io equivalent.
                std.posix.kill(self.pid, std.posix.SIG.TERM) catch {};
            }
        }
    };

    var cancel = std.atomic.Value(bool).init(false);
    var timed_out = std.atomic.Value(bool).init(false);
    const pid = opts.reg.get(opts.session_id, opts.kind) orelse return error.NotRegistered;
    const thread = std.Thread.spawn(.{}, Killer.run, .{Killer{
        .io = opts.io,
        .pid = pid,
        .ms = opts.timeout_ms,
        .cancel = &cancel,
        .timed_out = &timed_out,
    }}) catch null;
    defer {
        cancel.store(true, .monotonic);
        if (thread) |t| t.join();
    }

    opts.reg.writeStdin(opts.session_id, opts.kind, line) catch {
        opts.reg.terminate(opts.session_id, opts.kind);
        return error.KernelExited;
    };
    const raw = opts.reg.readStdoutLine(opts.arena, opts.session_id, opts.kind) catch |err| {
        opts.reg.terminate(opts.session_id, opts.kind);
        if (err == error.KernelExited and timed_out.load(.monotonic)) return error.Timeout;
        return error.KernelExited;
    };
    const parsed = try parseResponse(opts.arena, raw);
    return render(opts, parsed);
}

fn render(opts: EvalOpts, parsed: Response) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(opts.arena);
    var s = std.json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("ok");
    try s.write(parsed.ok);
    try s.objectField("stdout");
    try s.write(cap(parsed.stdout, opts.max_output_bytes));
    try s.objectField("stderr");
    try s.write(cap(parsed.stderr, opts.max_output_bytes));
    try s.objectField("result");
    if (parsed.result) |r| {
        try s.write(cap(r, opts.max_output_bytes));
    } else {
        try s.write(null);
    }
    try s.objectField("duration_ms");
    try s.write(parsed.duration_ms);
    if (parsed.reset) {
        try s.objectField("reset");
        try s.write(true);
    }
    if (parsed.err) |e| {
        try s.objectField("error");
        try s.write(e);
    }
    try s.endObject();
    return out.toOwnedSlice();
}

fn cap(s: []const u8, max: u32) []const u8 {
    return utf8.cap(s, @as(usize, max));
}

test "cap is UTF-8 safe at the output limit" {
    try std.testing.expectEqualStrings("", cap("é", 1));
    try std.testing.expectEqualStrings("a", cap("aé", 1));
    try std.testing.expectEqualStrings("a", cap("aé", 2));
    try std.testing.expectEqualStrings("aé", cap("aé", 3));
}

pub fn errorJson(arena: std.mem.Allocator, msg: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{{\"ok\":false,\"error\":{f}}}", .{std.json.fmt(msg, .{})}) catch
        "{\"ok\":false,\"error\":\"kernel failed\"}";
}

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.testing.allocator, .{});
}

test "encodeRequest / parseResponse are inverses for a cell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const line = try encodeRequest(arena, .{ .cell = "1 + 1" });
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
    try std.testing.expect(std.mem.find(u8, line, "\"cell\"") != null);
    const parsed = try parseResponse(arena,
        \\{"ok":true,"stdout":"","stderr":"","result":"2","duration_ms":3}
    );
    try std.testing.expect(parsed.ok);
    try std.testing.expectEqualStrings("2", parsed.result.?);
    try std.testing.expectEqual(@as(u32, 3), parsed.duration_ms);
}

test "disabled gate refuses without spawning" {
    var threaded = testIo();
    defer threaded.deinit();
    var reg = subprocess.Registry.init(std.testing.allocator, threaded.io());
    defer reg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.KernelDisabled, eval(.{
        .io = threaded.io(),
        .gpa = std.testing.allocator,
        .arena = arena_state.allocator(),
        .reg = &reg,
        .session_id = "off-1",
        .cwd = .inherit,
        .cell = "1 + 1",
        .enabled = false,
    }));
    try std.testing.expectEqual(@as(usize, 0), reg.count());
}

test "python cells persist, reset drops the name, persist works again" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var reg = subprocess.Registry.init(std.testing.allocator, io);
    defer reg.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = EvalOpts{
        .io = io,
        .gpa = std.testing.allocator,
        .arena = arena,
        .reg = &reg,
        .session_id = "k1",
        .cwd = .{ .dir = tmp.dir },
        .timeout_ms = 15_000,
    };

    var arith = base;
    arith.cell = "1 + 1";
    const arith_out = eval(arith) catch |err| switch (err) {
        error.Python3NotFound => return error.SkipZigTest,
        else => return err,
    };
    const arith_parsed = try parseResponse(arena, arith_out);
    try std.testing.expect(arith_parsed.ok);
    try std.testing.expectEqualStrings("2", arith_parsed.result.?);

    var first = base;
    first.cell = "x = 10";
    const out1 = eval(first) catch |err| switch (err) {
        error.Python3NotFound => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expect(std.mem.find(u8, out1, "\"ok\":true") != null);

    var second = base;
    second.cell = "x + 1";
    const out2 = try eval(second);
    const parsed2 = try parseResponse(arena, out2);
    try std.testing.expect(parsed2.ok);
    try std.testing.expectEqualStrings("11", parsed2.result.?);

    var reset_call = base;
    reset_call.reset = true;
    reset_call.cell = "x";
    const out3 = try eval(reset_call);
    const parsed3 = try parseResponse(arena, out3);
    try std.testing.expect(!parsed3.ok);
    try std.testing.expect(parsed3.stderr.len > 0);

    var again1 = base;
    again1.cell = "x = 10";
    _ = try eval(again1);
    var again2 = base;
    again2.cell = "x + 1";
    const out5 = try eval(again2);
    const parsed5 = try parseResponse(arena, out5);
    try std.testing.expect(parsed5.ok);
    try std.testing.expectEqualStrings("11", parsed5.result.?);

    const pid = reg.get("k1", "python").?;
    try std.testing.expect(pid > 1);
    reg.terminateSession("k1");
    try std.testing.expect(reg.get("k1", "python") == null);
}
