//! zwasm-based WASM sandbox: compiles a tool module, links the ck_* host
//! functions through a Linker, and executes the tool ABI
//! (scratch / host_arena / run) with a fuel + memory budget.

const std = @import("std");
const log = @import("../util/log.zig");
const protocol = @import("protocol.zig");
const host = @import("host.zig");
const config_mod = @import("../config.zig");
const chatrooms_mod = @import("../peers/chatrooms.zig");
const token_stats_mod = @import("../stats/tokens.zig");
const zwasm = @import("zwasm");

/// Deterministic instruction budget per tool call (OutOfFuel trap).
const default_fuel = 10_000_000_000;
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
    try lk.defineFuncCtx("env", "ck_fs_list", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckFsList);
    try lk.defineFuncCtx("env", "ck_getenv", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckGetenv);
    try lk.defineFuncCtx("env", "ck_exec", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckExec);
    try lk.defineFuncCtx("env", "ck_std_api", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckStdApi);
    try lk.defineFuncCtx("env", "ck_subagent", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckSubagent);
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
            .fuel = .{ .limited = default_fuel },
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
        const scratch_ptr = try scratch_fn.call(.{@intCast(input.len)});
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
