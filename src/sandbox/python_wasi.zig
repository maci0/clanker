//! Runs the vendored WASI CPython (`scripts/setup-python-wasi.sh`) under
//! zwasm's own sandboxing limits: fuel, wall-clock timeout, memory cap, and
//! exactly one filesystem preopen (the interpreter's stdlib, read-only in
//! effect since nothing here ever calls back into the guest to write it).
//! No network syscalls exist in the WASI preview1 import set this binary
//! links against, so there is nothing to allow or deny there.
//!
//! Mirrors zwasm's own `cli/run.zig` `runWasmCapturedFull` (same vendored
//! dependency clanker already links for its tool sandbox), reimplemented
//! here because that function is CLI-internal, not part of the public
//! `@import("zwasm")` facade.

const std = @import("std");
const zwasm = @import("zwasm");

pub const Limits = struct {
    fuel: u64,
    timeout_ms: u32,
    max_memory_bytes: u64,
    max_output_bytes: u32,
};

pub const RunError = error{
    BinaryNotFound,
    StdlibNotFound,
    EngineAllocFailed,
    StoreAllocFailed,
    ConfigAllocFailed,
    ModuleAllocFailed,
    InstanceAllocFailed,
} || std.mem.Allocator.Error;

pub const Output = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

const wasm_page_bytes: u64 = 64 * 1024;

fn timeoutRaiser(io: std.Io, ms: u64, flag: *std.atomic.Value(u32)) void {
    io.sleep(.{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms }, .awake) catch return;
    flag.store(1, .monotonic);
}

/// Runs `argv` against `binary_path` under a WASI sandbox scoped to one
/// preopened stdlib directory at guest path `/usr/local/lib`, no other
/// filesystem or network access. `stdin_bytes` feeds the guest's stdin, so
/// the caller's script never needs shell/argv escaping for the actual cell
/// text — it reads its input from stdin instead.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    binary_path: []const u8,
    stdlib_path: []const u8,
    argv: []const []const u8,
    stdin_bytes: []const u8,
    limits: Limits,
) RunError!Output {
    const c = zwasm.api.wasm;
    const wasi_host = zwasm.wasi.host;
    const diagnostic = zwasm.diagnostic;
    const instance_mod = zwasm.api.instance;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, binary_path, gpa, .limited(64 << 20)) catch
        return error.BinaryNotFound;
    defer gpa.free(bytes);

    diagnostic.clearDiag();

    const engine = c.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer c.wasm_engine_delete(engine);
    const store = c.wasm_store_new(engine) orelse return error.StoreAllocFailed;
    defer c.wasm_store_delete(store);

    const cfg = c.zwasm_wasi_config_new() orelse return error.ConfigAllocFailed;
    cfg.io = io;

    const stdlib_dir = std.Io.Dir.cwd().openDir(io, stdlib_path, .{ .iterate = true }) catch {
        c.zwasm_wasi_config_delete(cfg);
        return error.StdlibNotFound;
    };
    _ = cfg.addPreopen(stdlib_dir.handle, "/usr/local/lib") catch {
        c.zwasm_wasi_config_delete(cfg);
        return error.ConfigAllocFailed;
    };

    var stdout_capture: std.ArrayList(u8) = .empty;
    errdefer stdout_capture.deinit(gpa);
    var stderr_capture: std.ArrayList(u8) = .empty;
    errdefer stderr_capture.deinit(gpa);
    cfg.stdout_buffer = &stdout_capture;
    cfg.stderr_buffer = &stderr_capture;
    cfg.stdin_bytes = stdin_bytes;
    cfg.capture_alloc = gpa;
    cfg.max_capture_bytes = limits.max_output_bytes;

    cfg.setArgs(argv) catch {
        c.zwasm_wasi_config_delete(cfg);
        return error.ConfigAllocFailed;
    };
    const env_keys = [_][]const u8{"PYTHONHOME"};
    const env_vals = [_][]const u8{"/usr/local"};
    cfg.setEnvs(&env_keys, &env_vals) catch {
        c.zwasm_wasi_config_delete(cfg);
        return error.ConfigAllocFailed;
    };
    c.zwasm_store_set_wasi(store, cfg);

    var bv: c.ByteVec = .{ .size = bytes.len, .data = @constCast(bytes.ptr) };
    const module = c.wasm_module_new(store, &bv) orelse return error.ModuleAllocFailed;
    defer c.wasm_module_delete(module);

    const instance = instance_mod.instanceNewWithEngine(store, module, null, null, .auto) orelse
        return error.InstanceAllocFailed;
    defer c.wasm_instance_delete(instance);

    var timeout_flag = std.atomic.Value(u32).init(0);
    var timeout_fut: ?std.Io.Future(void) = null;
    defer if (timeout_fut) |*f| f.cancel(io);
    if (instance.runtime) |rt| {
        rt.fuel = limits.fuel;
        rt.store_memory_pages_max = limits.max_memory_bytes / wasm_page_bytes;
        timeout_fut = io.concurrent(timeoutRaiser, .{ io, limits.timeout_ms, &timeout_flag }) catch null;
        rt.interrupt = &timeout_flag;
    } else if (instance_mod.jitOf(instance)) |jit| {
        jit.setFuel(limits.fuel);
        jit.setMemoryPagesLimit(limits.max_memory_bytes / wasm_page_bytes);
        timeout_fut = io.concurrent(timeoutRaiser, .{ io, limits.timeout_ms, &timeout_flag }) catch null;
        jit.setInterruptFlag(&timeout_flag);
    }

    var exports: c.ExternVec = .{ .size = 0, .data = null };
    c.wasm_instance_exports(instance, &exports);
    defer c.wasm_extern_vec_delete(&exports);

    var entry_idx: ?usize = null;
    for (instance.exports_storage, 0..) |exp, i| {
        if (exp.kind == .func and std.mem.eql(u8, exp.name, "_start")) {
            entry_idx = i;
            break;
        }
    }
    const idx = entry_idx orelse return error.InstanceAllocFailed;
    const ext = exports.data.?[idx] orelse return error.InstanceAllocFailed;
    const entry_fn = c.wasm_extern_as_func(ext) orelse return error.InstanceAllocFailed;

    var results: c.ValVec = .{ .size = 0, .data = null };
    const trap = c.wasm_func_call(entry_fn, null, &results);
    if (trap == null) {
        return .{ .stdout = try stdout_capture.toOwnedSlice(gpa), .stderr = try stderr_capture.toOwnedSlice(gpa), .exit_code = 0 };
    }
    c.wasm_trap_delete(trap);
    if (store.wasi_host) |host_opaque| {
        const host: *wasi_host.Host = @ptrCast(@alignCast(host_opaque));
        if (host.exit_code) |code| {
            return .{
                .stdout = try stdout_capture.toOwnedSlice(gpa),
                .stderr = try stderr_capture.toOwnedSlice(gpa),
                .exit_code = @intCast(@min(code, std.math.maxInt(u8))),
            };
        }
    }
    return .{ .stdout = try stdout_capture.toOwnedSlice(gpa), .stderr = try stderr_capture.toOwnedSlice(gpa), .exit_code = 1 };
}

const test_binary_path = "vendor/python-wasi/bin/python-3.12.0.wasm";
const test_stdlib_path = "vendor/python-wasi/usr/local/lib";

test "runs a script, captures stdout, and enforces the memory-page conversion" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (!binaryPresent(io)) return error.SkipZigTest;

    const out = try run(io, std.testing.allocator, test_binary_path, test_stdlib_path, &.{"python"}, "print(2 + 2)\n", .{
        .fuel = 5_000_000_000,
        .timeout_ms = 30_000,
        .max_memory_bytes = 256 << 20,
        .max_output_bytes = 65536,
    });
    defer std.testing.allocator.free(out.stdout);
    defer std.testing.allocator.free(out.stderr);
    try std.testing.expectEqual(@as(u8, 0), out.exit_code);
    try std.testing.expectEqualStrings("4\n", out.stdout);
}

test "an infinite loop traps on the fuel budget instead of hanging" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (!binaryPresent(io)) return error.SkipZigTest;

    const out = try run(io, std.testing.allocator, test_binary_path, test_stdlib_path, &.{"python"}, "while True: pass\n", .{
        .fuel = 2_000_000,
        .timeout_ms = 10_000,
        .max_memory_bytes = 256 << 20,
        .max_output_bytes = 65536,
    });
    defer std.testing.allocator.free(out.stdout);
    defer std.testing.allocator.free(out.stderr);
    try std.testing.expect(out.exit_code != 0);
}

test "a path outside the stdlib preopen is unreachable" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (!binaryPresent(io)) return error.SkipZigTest;

    const out = try run(io, std.testing.allocator, test_binary_path, test_stdlib_path, &.{"python"}, "print(open('/etc/passwd').read())\n", .{
        .fuel = 5_000_000_000,
        .timeout_ms = 30_000,
        .max_memory_bytes = 256 << 20,
        .max_output_bytes = 65536,
    });
    defer std.testing.allocator.free(out.stdout);
    defer std.testing.allocator.free(out.stderr);
    // Bare `python` with no `-c`/file argument runs interactively (banner and
    // prompt on stderr); an uncaught exception there prints a traceback and
    // continues rather than setting a nonzero process exit, so the exit code
    // is not the signal here — the traceback naming the denied path is.
    try std.testing.expect(std.mem.indexOf(u8, out.stderr, "FileNotFoundError") != null);
}

fn binaryPresent(io: std.Io) bool {
    _ = std.Io.Dir.cwd().statFile(io, test_binary_path, .{}) catch return false;
    return true;
}
