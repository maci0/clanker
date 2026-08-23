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
const log = @import("../util/log.zig");

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
    /// Whether the cell ran under a sandbox. Always false on this path, and
    /// stated rather than assumed: ADR 0010 describes a WASI-confined Python
    /// kernel, and a caller reading these replies would otherwise have no way
    /// to tell that it is not the path it got. Defaults true so a reply from
    /// some future confined backend is not mislabelled by omission.
    sandboxed: bool = true,
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
    const sandboxed = switch (obj.get("sandboxed") orelse std.json.Value{ .bool = true }) {
        .bool => |b| b,
        else => true,
    };
    return .{
        .ok = ok,
        .stdout = stdout,
        .stderr = stderr,
        .result = result,
        .duration_ms = duration,
        .reset = reset,
        .err = err,
        .sandboxed = sandboxed,
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

/// What every reply from this path carries, because the path has no sandbox.
///
/// Deliberately does not say "run scripts/setup-python-wasi.sh to sandbox it",
/// which is what `runPythonCell` in src/sandbox/host.zig tells an operator.
/// That advice is false here: the WASI interpreter that script fetches drives
/// a one-shot cell, and this supervisor exists precisely so `__main__` survives
/// between cells, so no amount of setup routes this path through it. Pointing
/// an operator at a script that cannot help would be worse than saying nothing.
pub const unsandboxed_notice =
    "cells run in an UNSANDBOXED host python3 process with this process's full " ++
    "filesystem and network access, and exec_allow is not applied to %%bash or " ++
    "subprocess; see docs/reports/bugs/2026-08-23-kernel-persist-path-is-unsandboxed.md";

/// Adds the posture fields to a supervisor reply.
///
/// A reply that cannot be parsed is returned untouched: this annotation exists
/// to make a reply more honest, and dropping a real result to add a label to it
/// would be a poor trade.
fn annotatePosture(arena: std.mem.Allocator, raw: []u8) EvalError![]u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return raw;
    const obj = switch (parsed) {
        .object => |o| o,
        else => return raw,
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    var s = std.json.Stringify{ .writer = &out.writer };
    try s.beginObject();
    for (obj.keys(), obj.values()) |k, v| {
        // Never let a supervisor reply set its own posture: the supervisor is
        // the unsandboxed process, so its word on the subject is worthless.
        if (std.mem.eql(u8, k, "sandboxed") or std.mem.eql(u8, k, "sandbox_warning")) continue;
        try s.objectField(k);
        try s.write(v);
    }
    try s.objectField("sandboxed");
    try s.write(false);
    try s.objectField("sandbox_warning");
    try s.write(unsandboxed_notice);
    try s.endObject();
    return out.toOwnedSlice();
}

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
    // Every reply says so: this path has no sandbox, and a caller that cannot
    // see that has no way to know it is not on the confined path ADR 0010
    // describes.
    return annotatePosture(opts.arena, try roundTrip(opts, line));
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
    // Once per supervisor, not once per cell: this is a posture an operator
    // needs told, and a long session would otherwise bury it in repeats.
    //
    // It used to be told to nobody. `runPythonCell` (src/sandbox/host.zig)
    // carries the deprecation warning ADR 0010 promises, but that function has
    // no production caller -- `ck_kernel` reaches this file instead -- so the
    // warning never fired and the only account of the kernel's confinement an
    // operator had was an ADR describing a path the code does not take.
    log.log(.warn, "kernel: started an UNSANDBOXED host {s} supervisor for session '{s}' ({s}); {s}", .{
        opts.python,
        opts.session_id,
        opts.kind,
        unsandboxed_notice,
    });
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

/// Session-end removal of kernel working directories under
/// `<state_dir>/kernels/` (PRD 0016). The ending session's directory goes
/// immediately: `Registry.terminateSession` has already SIGTERMed and
/// synchronously reaped that session's processes (`Child.kill` blocks), so
/// no in-flight read of ours can still hold a file in it. Sibling session
/// directories are what crashed runs leave behind and nothing else ever
/// cleans (ADR 0008: nothing fires on its own) — one is removed only when
/// its session holds no live process in `live` and its mtime is older than
/// `cleanup_delay_ms`, the same write-clears-its-own-garbage shape as the
/// `ck_fs_write_if` lock sweep. Two runs sharing one session id are outside
/// this guard (the registry is per-process; see the concurrent-sessions
/// runbook): the first to end removes the shared directory.
pub fn cleanupSessionDirs(
    io: std.Io,
    base: std.Io.Dir,
    state_dir: []const u8,
    session_id: []const u8,
    cleanup_delay_ms: u32,
    live: ?*subprocess.Registry,
) void {
    var path_buf: [512]u8 = undefined;
    const kernels_rel = std.fmt.bufPrint(&path_buf, "{s}/kernels", .{state_dir}) catch return;
    var kdir = base.openDir(io, kernels_rel, .{ .iterate = true }) catch return;
    defer kdir.close(io);
    kdir.deleteTree(io, session_id) catch {};
    const now_ms = log.unixMilliseconds();
    var it = kdir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (live) |reg| {
            if (reg.sessionLive(entry.name)) continue;
        }
        const st = kdir.statFile(io, entry.name, .{}) catch continue;
        const age_ms = now_ms - @divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms);
        if (age_ms < cleanup_delay_ms) continue;
        kdir.deleteTree(io, entry.name) catch {};
    }
}

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(std.testing.allocator, .{});
}

test "cleanupSessionDirs removes the ending session and aged orphans, keeps live ones" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "state/kernels/s-end/python");
    try tmp.dir.createDirPath(io, "state/kernels/s-orphan/python");
    try tmp.dir.createDirPath(io, "state/kernels/s-live/python");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/kernels/s-end/python/x.txt", .data = "x" });

    var reg = subprocess.Registry.init(std.testing.allocator, io);
    defer reg.deinit();
    try reg.register("s-live", "python", 1);

    // delay 0: the ending session goes, and so does the aged orphan; the
    // session with a live registered process survives.
    cleanupSessionDirs(io, tmp.dir, "state", "s-end", 0, &reg);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "state/kernels/s-end", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "state/kernels/s-orphan", .{}));
    _ = try tmp.dir.statFile(io, "state/kernels/s-live", .{});

    // A fresh orphan inside the delay window is kept for inspection.
    try tmp.dir.createDirPath(io, "state/kernels/s-fresh/python");
    cleanupSessionDirs(io, tmp.dir, "state", "s-end", 3_600_000, &reg);
    _ = try tmp.dir.statFile(io, "state/kernels/s-fresh", .{});

    // A missing kernels tree is a no-op, not an error.
    cleanupSessionDirs(io, tmp.dir, "nowhere", "s-end", 0, null);
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

test "every kernel reply states that this path is unsandboxed, and it really is" {
    // ADR 0010 says a configured Python kernel is "bounded by the sandbox, not
    // by config + confirm alone". That is not true of the path production
    // takes. `ck_kernel` -> `ckKernel` (src/sandbox/host.zig) -> `eval` here is
    // a plain host `python3` subprocess; `runPythonCell` and
    // `runPythonCellSandboxed`, the WASI-confined functions the ADR describes,
    // have no caller outside their own test.
    //
    // This test pins both halves of that, so neither can drift silently:
    //   1. the reply says `sandboxed:false` and carries the reason, and
    //   2. the cell really does have ambient access, so (1) is not a label on
    //      something already confined.
    //
    // If someone confines this path, (2) fails and forces the docs, the notice
    // and this test to be updated together. That is the intent: the assertion
    // is on the posture, not on a bug.
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
        .session_id = "posture",
        .cwd = .{ .dir = tmp.dir },
        .timeout_ms = 15_000,
    };
    defer reg.terminateSession("posture");

    // 1. A plain cell's reply is labelled.
    var cell = base;
    cell.cell = "1 + 1";
    const out = eval(cell) catch |err| switch (err) {
        error.Python3NotFound => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expect(std.mem.find(u8, out, "\"sandboxed\":false") != null);
    try std.testing.expect(std.mem.find(u8, out, "exec_allow is not applied") != null);
    const parsed = try parseResponse(arena, out);
    try std.testing.expect(parsed.ok);
    try std.testing.expect(!parsed.sandboxed);
    // The label did not cost the result.
    try std.testing.expectEqualStrings("2", parsed.result.?);

    // 2. The posture is real, not pessimistic labelling. `%%bash` reaches a
    // shell with no exec_allow consulted, and a plain cell can do the same
    // through `subprocess` without going near the bash route at all -- which is
    // why enforcing exec_allow on `%%bash` alone would not be a boundary.
    var shell = base;
    shell.bash = "echo AMBIENT-SHELL-REACHED";
    const shell_out = try eval(shell);
    try std.testing.expect(std.mem.find(u8, shell_out, "AMBIENT-SHELL-REACHED") != null);
    try std.testing.expect(std.mem.find(u8, shell_out, "\"sandboxed\":false") != null);

    // `capture_output=True` is not incidental. Without it the child inherits
    // the supervisor's stdout and its bytes land in the middle of the JSON
    // line, which the host then cannot parse -- see the separate report on the
    // stdout-corruption bug. Capturing keeps this assertion about exec reach
    // rather than about that.
    var via_python = base;
    via_python.cell = "import subprocess; subprocess.run(['echo','AMBIENT-VIA-SUBPROCESS'],capture_output=True).stdout";
    const via_out = try eval(via_python);
    try std.testing.expect(std.mem.find(u8, via_out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, via_out, "AMBIENT-VIA-SUBPROCESS") != null);

    // A supervisor reply cannot claim to be sandboxed: the unsandboxed process
    // is not a trustworthy source on its own confinement.
    const forged = try annotatePosture(arena, try arena.dupe(u8, "{\"ok\":true,\"sandboxed\":true}"));
    try std.testing.expect(std.mem.find(u8, forged, "\"sandboxed\":false") != null);
    try std.testing.expect(std.mem.find(u8, forged, "\"sandboxed\":true") == null);

    // An unparseable reply is passed through rather than dropped for a label.
    const junk = try annotatePosture(arena, try arena.dupe(u8, "not json"));
    try std.testing.expectEqualStrings("not json", junk);
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
