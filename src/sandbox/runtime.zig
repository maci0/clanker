//! zwasm-based WASM sandbox: compiles a tool module, links the ck_* host
//! functions through a Linker, and executes the tool ABI
//! (scratch / host_arena / run) with a fuel + memory budget.

const std = @import("std");
const log = @import("../util/log.zig");
const protocol = @import("protocol.zig");
const host = @import("host.zig");
const config_mod = @import("../config.zig");
const chatrooms_mod = @import("../peers/chatrooms.zig");
const private_todos_mod = @import("../agent/private_todos.zig");
const token_stats_mod = @import("../stats/tokens.zig");
const registry = @import("../tools/registry.zig");
const client = @import("../llm/client.zig");
const zwasm = @import("zwasm");

/// Deterministic instruction budget per tool call (OutOfFuel trap).
const default_fuel = 10_000_000_000;

/// The effective budget for one call: a descriptor's `fuel` (0 = unset) may
/// tighten the default but never exceed it — a fat-fingered manifest stays
/// a setting, not an unmetered run (the same clamp philosophy as rlm's
/// max_depth ceiling).
fn fuelBudget(requested: u64) u64 {
    return if (requested == 0) default_fuel else @min(requested, default_fuel);
}
/// Linear memory cap in wasm pages (64 KiB each): 256 pages = 16 MiB.
const max_memory_pages = 256;

/// AssemblyScript runtime import; a no-op (the guest's abort handling is not
/// needed inside the sandbox — traps surface as ToolTrap).
fn asAbort(caller: *zwasm.Caller, msg: u32, file: u32, line: u32, col: u32) void {
    _ = caller;
    _ = msg;
    _ = file;
    _ = line;
    _ = col;
}

fn linkHostFns(lk: *zwasm.Linker, h: *host.Host) !void {
    try lk.defineFuncCtx("env", "abort", h, fn (*zwasm.Caller, u32, u32, u32, u32) void, &asAbort);
    try lk.defineFuncCtx("env", "ck_log", h, fn (*zwasm.Caller, u32, u32, u32) void, &host.ckLog);
    try lk.defineFuncCtx("env", "ck_now", h, fn (*zwasm.Caller) u64, &host.ckNow);
    try lk.defineFuncCtx("env", "ck_random", h, fn (*zwasm.Caller) u64, &host.ckRandom);
    try lk.defineFuncCtx("env", "ck_http", h, fn (*zwasm.Caller, u32, u32, u32, u32, u32, u32, u32) u32, &host.ckHttp);
    try lk.defineFuncCtx("env", "ck_fs_read", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckFsRead);
    try lk.defineFuncCtx("env", "ck_fs_read_range", h, fn (*zwasm.Caller, u32, u32, u32, u32) u32, &host.ckFsReadRange);
    // Implemented in host.zig and never reachable: no registration meant no
    // guest could call them, so the file operations an agent needs to do more
    // than read — create a directory, rename, copy, delete, append, stat, find
    // by name, grep — did not exist as far as any tool was concerned.
    try lk.defineFuncCtx("env", "ck_fs_write_range", h, fn (*zwasm.Caller, u32, u32, u32, u32, u32) u32, &host.ckFsWriteRange);
    try lk.defineFuncCtx("env", "ck_fs_append", h, fn (*zwasm.Caller, u32, u32, u32, u32) u32, &host.ckFsAppend);
    try lk.defineFuncCtx("env", "ck_fs_copy", h, fn (*zwasm.Caller, u32, u32, u32, u32) u32, &host.ckFsCopy);
    try lk.defineFuncCtx("env", "ck_fs_rename", h, fn (*zwasm.Caller, u32, u32, u32, u32) u32, &host.ckFsRename);
    try lk.defineFuncCtx("env", "ck_fs_delete", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckFsDelete);
    try lk.defineFuncCtx("env", "ck_fs_mkdir", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckFsMkdir);
    try lk.defineFuncCtx("env", "ck_fs_stat", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckFsStat);
    try lk.defineFuncCtx("env", "ck_fs_find", h, fn (*zwasm.Caller, u32, u32, u32, u32) u32, &host.ckFsFind);
    try lk.defineFuncCtx("env", "ck_fs_grep", h, fn (*zwasm.Caller, u32, u32, u32, u32) u32, &host.ckFsGrep);
    try lk.defineFuncCtx("env", "ck_env", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckEnv);
    try lk.defineFuncCtx("env", "ck_hash", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckHash);
    try lk.defineFuncCtx("env", "ck_fs_write", h, fn (*zwasm.Caller, u32, u32, u32, u32) u32, &host.ckFsWrite);
    try lk.defineFuncCtx("env", "ck_fs_write_if", h, fn (*zwasm.Caller, u32, u32, u32, u32, u32, u32) u32, &host.ckFsWriteIf);
    try lk.defineFuncCtx("env", "ck_fs_list", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckFsList);
    try lk.defineFuncCtx("env", "ck_getenv", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckGetenv);
    try lk.defineFuncCtx("env", "ck_exec", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckExec);
    try lk.defineFuncCtx("env", "ck_std_api", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckStdApi);
    try lk.defineFuncCtx("env", "ck_subagent", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckSubagent);
    try lk.defineFuncCtx("env", "ck_swarm", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckSwarm);
    try lk.defineFuncCtx("env", "ck_ask", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckAsk);
    try lk.defineFuncCtx("env", "ck_docker", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckDocker);
    try lk.defineFuncCtx("env", "ck_llm", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckLlm);
    try lk.defineFuncCtx("env", "ck_chat", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckChat);
    try lk.defineFuncCtx("env", "ck_stats", h, fn (*zwasm.Caller) u32, &host.ckStats);
    try lk.defineFuncCtx("env", "ck_config", h, fn (*zwasm.Caller) u32, &host.ckConfig);
    try lk.defineFuncCtx("env", "ck_result", h, fn (*zwasm.Caller) u64, &host.ckResult);
}

pub const ToolModule = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    engine: zwasm.Engine,
    linker: zwasm.Linker,
    module: zwasm.Module,
    inst: zwasm.Instance,
    inst_initialized: bool = false,
    sb: *host.Sandbox,
    h: *host.Host,
    /// Tool name for diagnostics: the caller (the registry) knows it, the
    /// module bytes do not carry it, and a bare trap log cannot say which
    /// tool died. Set by the caller after load(); empty means unknown.
    name: []const u8 = "",

    pub fn load(gpa: std.mem.Allocator, io: std.Io, sb: *host.Sandbox, wasm_bytes: []const u8) !*ToolModule {
        const self = try gpa.create(ToolModule);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .engine = undefined,
            .linker = undefined,
            .module = undefined,
            .inst = undefined,
            .inst_initialized = false,
            .sb = sb,
            .h = undefined,
        };
        _ = self.h;
        errdefer self.deinit();

        self.h = try gpa.create(host.Host);
        self.h.* = .{
            .sandbox = sb,
            .rng = std.Random.DefaultPrng.init(seedRng(sb.seed, wasm_bytes)),
        };

        self.engine = try zwasm.Engine.init(gpa, .{});
        self.linker = self.engine.linker();
        self.module = try self.engine.compile(wasm_bytes);
        try linkHostFns(&self.linker, self.h);
        self.inst = try self.linker.instantiate(&self.module, .{
            .fuel = .{ .limited = fuelBudget(sb.fuel) },
            .max_memory_pages = .{ .limited = max_memory_pages },
        });
        self.inst_initialized = true;

        // Discover the module's host arena base (tool ABI only).
        if (self.inst.exportFuncSig("host_arena") != null) {
            var arena_fn = self.inst.typedFunc(fn () u32, "host_arena");
            self.h.arena_base = try arena_fn.call(.{});
        }
        // A guest may reserve more than the historical 64 KiB; without this the
        // host would refuse results the guest has room for (and, if it ever
        // assumed more, write past the end of the guest's buffer).
        if (self.inst.exportFuncSig("host_arena_size") != null) {
            var size_fn = self.inst.typedFunc(fn () u32, "host_arena_size");
            const size = try size_fn.call(.{});
            if (size > 0) self.h.arena_cap = size;
        }

        return self;
    }

    pub fn deinit(self: *ToolModule) void {
        // Lifetime order: Instance -> Module -> Linker -> Engine (linker last
        // among import users), then the host context and the module itself.
        if (@TypeOf(self.inst) == void) return;
        if (self.inst_initialized) self.inst.deinit();
        self.module.deinit();
        self.linker.deinit();
        self.engine.deinit();
        self.gpa.destroy(self.h);
        self.gpa.destroy(self);
    }

    /// Executes the tool with `input` (JSON), returning the tool's JSON output
    /// in a fresh allocation.
    pub fn executeTool(self: *ToolModule, input: []const u8) ![]u8 {
        self.h.reset();

        const mem = self.inst.memory() orelse return error.ToolNoMemory;
        const mem_bytes = mem.slice();

        // ---- input buffer ----
        var scratch_fn = self.inst.typedFunc(fn (u32) u32, "scratch");
        // A trap here (e.g. OutOfFuel on a small per-tool budget) is the same
        // failure as a trap in run: report it as one instead of leaking a raw
        // zwasm error to callers that only know ToolTrap.
        const scratch_ptr = scratch_fn.call(.{@intCast(input.len)}) catch |err| {
            log.log(.error_, "[sandbox] tool trap in scratch: {s} (tool={s})", .{ @errorName(err), self.name });
            return error.ToolTrap;
        };
        if (scratch_ptr == 0) return error.ToolScratchTooSmall;
        if (@as(u64, scratch_ptr) + input.len > mem_bytes.len) return error.ToolScratchTooSmall;
        @memcpy(mem_bytes[scratch_ptr .. scratch_ptr + input.len], input);

        // ---- execute ----
        var run_fn = self.inst.typedFunc(fn (u32, u32) u64, "run");
        const p = run_fn.call(.{ scratch_ptr, @intCast(input.len) }) catch |err| {
            log.log(.error_, "[sandbox] tool trap: {s} (tool={s})", .{ @errorName(err), self.name });
            return error.ToolTrap;
        };
        const r = protocol.unpackPtrLen(p);
        if (@as(u64, r.ptr) + r.len > mem_bytes.len) return error.ToolInvalidOutput;
        return self.gpa.dupe(u8, mem_bytes[r.ptr .. r.ptr + r.len]);
    }
};

/// Looks up `tool_name` in `reg`, reads its wasm, builds its sandbox from the
/// descriptor through `host.sandboxFor`, and loads it as a runnable module.
/// The one place cli.zig, mcp/server.zig, and the improve engine go through
/// to run a named internal tool, instead of each re-deriving the sandbox by
/// hand and risking drift from `sandboxFor`'s policy. The sandbox is
/// arena-allocated so it outlives the returned module.
pub fn loadNamedTool(
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    cfg: *const config_mod.Config,
    reg: *const registry.Registry,
    tool_name: []const u8,
    llm_ctx: ?*client.Ctx,
) !*ToolModule {
    const tool = reg.get(tool_name) orelse return error.UnknownTool;
    const wasm_bytes = try std.Io.Dir.cwd().readFileAlloc(io, tool.wasm, gpa, .limited(1 << 20));
    defer gpa.free(wasm_bytes);
    const sb = try arena.create(host.Sandbox);
    sb.* = try host.sandboxFor(gpa, io, arena, environ_map, cfg, tool, llm_ctx);
    return ToolModule.load(gpa, io, sb, wasm_bytes);
}

fn seedRng(seed: u64, salt: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x6A09E667F3BCC909);
    h.update(std.mem.asBytes(&seed));
    h.update(salt);
    return h.final();
}

// ------------------------------------------------------------------- tests --

test "zwasm loads a Zig-compiled module and calls it" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/tiny.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = "/tmp/ck-sandbox-test",
        .network_allow = &.{},
        .environ_map = &env_map,
    };

    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();

    var fn_ = mod.inst.typedFunc(fn (i32, i32) i32, "add");
    const res = try fn_.call(.{ 17, 25 });
    try std.testing.expectEqual(@as(i32, 42), res);
}

test "fuelBudget lets a descriptor tighten but never raise the default" {
    try std.testing.expectEqual(@as(u64, default_fuel), fuelBudget(0));
    try std.testing.expectEqual(@as(u64, 1_000), fuelBudget(1_000));
    try std.testing.expectEqual(@as(u64, default_fuel), fuelBudget(default_fuel * 2));
}

test "a descriptor-tightened fuel budget traps a call that exceeds it" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/tiny.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = "/tmp/ck-sandbox-test",
        .network_allow = &.{},
        .environ_map = &env_map,
        .fuel = 1,
    };

    // Instantiation itself may burn the single unit of fuel; either way the
    // budget must surface as OutOfFuel, never as a successful call.
    const mod = ToolModule.load(std.testing.allocator, io, &sb, wasm) catch |err| {
        try std.testing.expectEqual(error.OutOfFuel, err);
        return;
    };
    defer mod.deinit();

    var fn_ = mod.inst.typedFunc(fn (i32, i32) i32, "add");
    try std.testing.expectError(error.OutOfFuel, fn_.call(.{ 17, 25 }));
}

test "zwasm executes on a worker thread" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "tests/fixtures/tiny.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const W = struct {
        wasm: []const u8,
        io: std.Io,
        name: []const u8,
        result: ?i32 = null,
        fn run(self: *@This()) void {
            var env = std.process.Environ.Map.init(std.testing.allocator);
            defer env.deinit();
            var sb = host.Sandbox{ .gpa = std.testing.allocator, .io = self.io, .root_dir = ".", .network_allow = &.{}, .environ_map = &env };
            const mod = ToolModule.load(std.testing.allocator, self.io, &sb, self.wasm) catch |e| {
                std.debug.print("worker load err {s} (tool={s})\n", .{ @errorName(e), self.name });
                return;
            };
            defer mod.deinit();
            mod.name = self.name;
            var fn_ = mod.inst.typedFunc(fn (i32, i32) i32, "add");
            const r = fn_.call(.{ 17, 25 }) catch |e| {
                std.debug.print("worker call err {s} (tool={s})\n", .{ @errorName(e), self.name });
                return;
            };
            self.result = r;
        }
    };
    var w = W{ .wasm = wasm, .io = io, .name = "tiny" };
    const th = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, W.run, .{&w});
    th.join();
    try std.testing.expectEqual(@as(?i32, 42), w.result);
}

test "chat wasm tool executes (send + history via ck_chat)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A minimal config: instance name, chatrooms on, one subscribed room.
    var cfg = config_mod.Config{};
    cfg.instance.name = "test-clanker";
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"dev"};
    cfg.chatrooms.max_history = 100;

    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = "/tmp/ck-sandbox-test",
        .network_allow = &.{},
        .environ_map = &env_map,
        .cfg = &cfg,
        .state_dir = "",
        .state_base_dir = tmp.dir,
        .config_json = "{\"op\":\"send\"}",
    };

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/chat.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();

    const out = try mod.executeTool("{\"room\":\"dev\",\"text\":\"hello from wasm\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);

    // The message must have landed in the (isolated) chatroom log.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hist = try chatrooms_mod.readHistory(tmp.dir, io, std.testing.allocator, arena, "", "dev", 0, 10);
    try std.testing.expectEqual(@as(usize, 1), hist.len);
    try std.testing.expectEqualStrings("hello from wasm", hist[0].text);
    try std.testing.expectEqualStrings("test-clanker", hist[0].from);
}

test "board wasm tool folds a room log longer than one history page completely" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config_mod.Config{};
    cfg.instance.name = "test-clanker";
    cfg.chatrooms.on = true;
    cfg.chatrooms.rooms = &.{"board"};
    cfg.chatrooms.max_history = 100;

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/board.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const Step = struct {
        fn run(io_: std.Io, cfg_: *config_mod.Config, env: *std.process.Environ.Map, dir: std.Io.Dir, wasm_: []const u8, config_json: []const u8, args: []const u8) ![]u8 {
            var sb = host.Sandbox{
                .gpa = std.testing.allocator,
                .io = io_,
                .root_dir = "/tmp/ck-sandbox-test",
                .network_allow = &.{},
                .environ_map = env,
                .cfg = cfg_,
                .state_dir = "",
                .state_base_dir = dir,
                .config_json = config_json,
            };
            const mod = try ToolModule.load(std.testing.allocator, io_, &sb, wasm_);
            defer mod.deinit();
            return mod.executeTool(args);
        }
    };

    // 25 cards: five more than one history page (host page size 20). All the
    // adds land within a second or two, so they share a timestamp — exactly
    // the shape that used to fold to its newest page only: the host answered
    // history newest-first, the fold's `ts > after` cursor jumped to the top,
    // and the oldest cards silently vanished from every board_list.
    var i: usize = 1;
    while (i <= 25) : (i += 1) {
        const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"title\":\"card-{d:0>2}\"}}", .{i});
        defer std.testing.allocator.free(args);
        const out = try Step.run(io, &cfg, &env_map, tmp.dir, wasm, "{\"op\":\"create\"}", args);
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
    }

    const listed = try Step.run(io, &cfg, &env_map, tmp.dir, wasm, "{\"op\":\"list\"}", "{}");
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"ok\":true") != null);
    i = 1;
    while (i <= 25) : (i += 1) {
        const title = try std.fmt.allocPrint(std.testing.allocator, "\"title\":\"card-{d:0>2}\"", .{i});
        defer std.testing.allocator.free(title);
        try std.testing.expect(std.mem.indexOf(u8, listed, title) != null);
    }
}

test "chat wasm tool routes roomless todo ops to the private list" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    // Chatrooms deliberately OFF: the private list must not need the module.
    var cfg = config_mod.Config{};
    var todos = private_todos_mod.List{ .alloc = std.testing.allocator };
    defer todos.deinit();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/chat.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    // The descriptor config pins the op, so each op is its own sandbox+module.
    const Step = struct { op: []const u8, args: []const u8, expect: []const u8 };
    const steps = [_]Step{
        .{ .op = "todo_add", .args = "{\"title\":\"first step\"}", .expect = "\"todo\":\"p1\"" },
        .{ .op = "todo_claim", .args = "{\"todo\":\"p1\"}", .expect = "\"yours\":true" },
        .{ .op = "todo_close", .args = "{\"todo\":\"p1\"}", .expect = "\"status\":\"closed\"" },
        .{ .op = "todo_list", .args = "{}", .expect = "\"title\":\"first step\"" },
    };
    for (steps) |step| {
        var sb = host.Sandbox{
            .gpa = std.testing.allocator,
            .io = io,
            .root_dir = "/tmp/ck-sandbox-test",
            .network_allow = &.{},
            .environ_map = &env_map,
            .cfg = &cfg,
            .private_todos = &todos,
            .config_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"op\":\"{s}\"}}", .{step.op}),
        };
        defer std.testing.allocator.free(@constCast(sb.config_json));
        const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
        defer mod.deinit();
        const out = try mod.executeTool(step.args);
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, step.expect) != null);
    }

    // A sandbox without a list is a host wiring error. Top-level Agent.run
    // attaches one before it can execute a tool; this defensive response must
    // never direct callers to the removed room-scoped todo path.
    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = "/tmp/ck-sandbox-test",
        .network_allow = &.{},
        .environ_map = &env_map,
        .cfg = &cfg,
        .config_json = "{\"op\":\"todo_add\"}",
    };
    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();
    const out = try mod.executeTool("{\"title\":\"nope\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "host wiring error") != null);
}

fn stubParentAnswer(ctx: *anyopaque, gpa: std.mem.Allocator, question: []const u8, options: []const []const u8) anyerror![]const u8 {
    _ = ctx;
    _ = question;
    // Deterministically picks the second option, so the test can tell a real
    // routed answer from any default.
    return gpa.dupe(u8, options[1]);
}

test "ask_user wasm tool routes {parent:true} to the parent answerer" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/ask_user.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    // A sub-agent run: parent_ask wired, no human ask_fn.
    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = "/tmp/ck-sandbox-test",
        .network_allow = &.{},
        .environ_map = &env_map,
        .parent_ask = .{ .ctx = undefined, .call = &stubParentAnswer },
    };
    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();
    const out = try mod.executeTool("{\"question\":\"Which one?\",\"options\":[\"A\",\"B\"],\"parent\":true}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"answer\":\"B\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"answered_by\":\"parent\"") != null);

    // A top-level run: no parent attached, so the tool says to decide alone
    // instead of pretending someone answered.
    var sb_top = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = "/tmp/ck-sandbox-test",
        .network_allow = &.{},
        .environ_map = &env_map,
    };
    const mod_top = try ToolModule.load(std.testing.allocator, io, &sb_top, wasm);
    defer mod_top.deinit();
    const out_top = try mod_top.executeTool("{\"question\":\"Which one?\",\"options\":[\"A\",\"B\"],\"parent\":true}");
    defer std.testing.allocator.free(out_top);
    try std.testing.expect(std.mem.indexOf(u8, out_top, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out_top, "no parent to ask") != null);
}

test "model_stats wasm tool executes (ck_stats host fn)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config_mod.Config{};
    cfg.modules.token_stats = true;

    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = "/tmp/ck-sandbox-test",
        .network_allow = &.{},
        .environ_map = &env_map,
        .cfg = &cfg,
        .state_dir = "",
        .state_base_dir = tmp.dir,
    };

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/stats.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();

    const out = try mod.executeTool("{}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"stats\":[]") != null);

    // Seed the log and check aggregation flows through the tool.
    token_stats_mod.append(tmp.dir, io, std.testing.allocator, std.testing.allocator, "", .{
        .ts = 1,
        .provider = "kimi-k3",
        .model = "kimi-k3",
        .prompt_tokens = 100,
        .completion_tokens = 20,
        .total_tokens = 120,
        .cache_hit = 90,
        .cache_miss = 10,
        .cost = 0.001,
        .duration_ms = 1000,
    });
    const out2 = try mod.executeTool("{}");
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "\"calls\":1") != null);
}

test "cmd_graph wasm tool writes and reads back a run graph (ck_fs_write/ck_fs_read host fns)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/cmd_graph.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const run_id = "test-run-cmd-graph-roundtrip";
    const path = "state/runs/" ++ run_id ++ ".json";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = ".",
        .network_allow = &.{},
        .fs_prefixes = &.{"state/runs/"},
        .environ_map = &env_map,
    };
    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();

    const write_in =
        \\{"write":{"run_id":"test-run-cmd-graph-roundtrip","parent_run_id":"run-parent","task":"t","provider":"p",
        \\"started_at":1,"duration_ms":5,"total_prompt_tokens":10,"total_completion_tokens":2,
        \\"nodes":[{"kind":"tool","iteration":1,"label":"gate","ok":true,"result_bytes":3}]}}
    ;
    const write_out = try mod.executeTool(write_in);
    defer std.testing.allocator.free(write_out);
    try std.testing.expect(std.mem.indexOf(u8, write_out, "\"ok\":true") != null);

    // A run_id crossing a path boundary must be rejected, not silently escape
    // state/runs/.
    const bad_out = try mod.executeTool("{\"write\":{\"run_id\":\"../escape\"}}");
    defer std.testing.allocator.free(bad_out);
    try std.testing.expect(std.mem.indexOf(u8, bad_out, "\"ok\":false") != null);

    const mod2 = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod2.deinit();
    const read_out = try mod2.executeTool("{\"args\":\"" ++ run_id ++ "\"}");
    defer std.testing.allocator.free(read_out);
    try std.testing.expect(std.mem.indexOf(u8, read_out, run_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, read_out, "tool gate  3 B") != null);

    // The parent link survives the round trip: a nested run's graph must
    // still name its caller when read back as JSON (the web UI's view).
    const mod3 = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod3.deinit();
    const json_out = try mod3.executeTool("{\"args\":\"json " ++ run_id ++ "\"}");
    defer std.testing.allocator.free(json_out);
    try std.testing.expect(std.mem.indexOf(u8, json_out, "\\\"parent_run_id\\\":\\\"run-parent\\\"") != null);
}

test "cmd_sessions and cmd_graph report empty when the state dir does not exist" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    // A sandbox root with no state/ at all — what a fresh clone looks like,
    // since state/ is gitignored and every subdirectory under it is created
    // lazily on first write.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = root,
        .network_allow = &.{},
        .fs_prefixes = &.{ "state/sessions/", "state/runs/" },
        .environ_map = &env_map,
    };

    const cases = [_]struct { wasm: []const u8, want: []const u8 }{
        .{ .wasm = "zig-out/tools/cmd_sessions.wasm", .want = "(no sessions yet)" },
        .{ .wasm = "zig-out/tools/cmd_graph.wasm", .want = "(no runs yet" },
    };
    for (cases) |c| {
        const wasm = try std.Io.Dir.cwd().readFileAlloc(io, c.wasm, std.testing.allocator, .limited(1 << 20));
        defer std.testing.allocator.free(wasm);
        const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
        defer mod.deinit();
        const out = try mod.executeTool("{}");
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, c.want) != null);
    }
}

test "roadmap wasm tool lists planned items from the real bullet format" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The fixture mirrors docs/ROADMAP.md's actual shape: plain "- " bullets
    // grouped under "## " headings, no checkboxes. The tool used to grep for
    // "- [ ]" and so reported every real roadmap as "(no planned items)".
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/ROADMAP.md", .data =
        \\# Roadmap
        \\
        \\## Done
        \\
        \\- **Shipped thing** — landed last week.
        \\
        \\## Planned
        \\
        \\- **Plugin SDK** — manifest format for third-party tools.
        \\  - a sub-bullet that must not surface as its own item
        \\- [x] checked item, done wherever it sits
        \\
        \\## Autolearn
        \\
        \\Observed from usage patterns.
        \\
        \\- Optimize the most-used tools.
        \\
    });
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = root,
        .network_allow = &.{},
        .fs_prefixes = &.{"docs/"},
        .environ_map = &env_map,
    };

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/roadmap.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();
    const planned = try mod.executeTool("{}");
    defer std.testing.allocator.free(planned);
    try std.testing.expect(std.mem.indexOf(u8, planned, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, planned, "Plugin SDK") != null);
    // Autolearn bullets are open work too — only "## Done" is excluded.
    try std.testing.expect(std.mem.indexOf(u8, planned, "Optimize the most-used tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, planned, "Shipped thing") == null);
    try std.testing.expect(std.mem.indexOf(u8, planned, "checked item") == null);
    try std.testing.expect(std.mem.indexOf(u8, planned, "sub-bullet") == null);
    try std.testing.expect(std.mem.indexOf(u8, planned, "no planned items") == null);

    const mod2 = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod2.deinit();
    const all = try mod2.executeTool("{\"list\":\"all\"}");
    defer std.testing.allocator.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "Shipped thing") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "checked item") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "## Done") != null);
}

test "cmd_autolearn wasm tool reports the newest tool_error detail as 'last:'" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Two failures for the same tool: the item renders "last: <detail>", so
    // the second detail must win, and events recorded before detail existed
    // (empty string) must not blank out a real one that follows.
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/autolearn.jsonl", .data =
        \\{"ts":1,"type":"tool_error","tool":"git","detail":"git exited 1: usage"}
        \\{"ts":2,"type":"tool_error","tool":"git","detail":""}
        \\{"ts":3,"type":"tool_error","tool":"git","detail":"git exited 128: not a git repository"}
        \\
    });
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = root,
        .network_allow = &.{},
        .fs_prefixes = &.{ "state/autolearn.jsonl", "docs/ROADMAP.md" },
        .environ_map = &env_map,
    };

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/cmd_autolearn.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();
    const out = try mod.executeTool("{}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "3 failure(s), last: git exited 128: not a git repository") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "last: git exited 1: usage") == null);
}

test "recent_commits wasm tool summarizes git history in one call (ck_exec)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Needs a real repository to log: a source tarball or a stripped CI
    // checkout has no .git, and a red test there would blame the tool for
    // the environment.
    var git_dir = std.Io.Dir.cwd().openDir(io, ".git", .{}) catch return error.SkipZigTest;
    git_dir.close(io);

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = ".",
        .network_allow = &.{},
        .exec_allow = &.{"git"},
        .environ_map = &env_map,
    };

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/recent_commits.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();
    // count:1 pins the shape: exactly one "hash  date  subject  (author)"
    // line, so a trailing newline or an uncapped log shows up as the extra
    // escaped newline it would put in the JSON string.
    const out = try mod.executeTool("{\"count\":1}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\\n") == null);
    // The author is the one field the format wraps in parens, so its
    // presence says the whole format string survived argv assembly.
    try std.testing.expect(std.mem.indexOf(u8, out, "(") != null);
}

test "assemblyscript calc_ts tool executes" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "tools/bin/calc_ts.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = "/tmp/ck-sandbox-test",
        .network_allow = &.{},
        .environ_map = &env_map,
    };

    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();

    const out = try mod.executeTool("17*23");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("391", out);

    const out2 = try mod.executeTool("{\"expr\": \"17*23\"}");
    defer std.testing.allocator.free(out2);
    try std.testing.expectEqualStrings("391", out2);
}

test "a tool with a tiny fuel budget runs out of fuel; the default budget answers" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "tools/bin/calc_ts.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    // 15k is measured to cover this module's instantiation and arena
    // discovery (~10.3k) but not a run (~18.8k more), so the trap lands in
    // executeTool — deterministically, since fuel accounting is
    // instruction-exact — and surfaces as ToolTrap, the error callers know,
    // not a raw zwasm OutOfFuel.
    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = "/tmp/ck-sandbox-test",
        .network_allow = &.{},
        .environ_map = &env_map,
        .fuel = 15_000,
    };
    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();
    try std.testing.expectError(error.ToolTrap, mod.executeTool("17*23"));

    // The same module bytes with fuel unset (0 resolves to the default
    // budget) still answer: it was the budget that trapped above, not the
    // tool.
    var sb_ok = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = "/tmp/ck-sandbox-test",
        .network_allow = &.{},
        .environ_map = &env_map,
    };
    const mod_ok = try ToolModule.load(std.testing.allocator, io, &sb_ok, wasm);
    defer mod_ok.deinit();
    const out = try mod_ok.executeTool("17*23");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("391", out);
}
