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

/// Deterministic instruction budget per tool call (OutOfFuel trap). Shared
/// with the manifest validator, which rejects a descriptor asking for more
/// than this rather than letting the clamp below silently disagree with what
/// the file says.
const default_fuel = @import("../tools/manifest.zig").default_fuel;

/// The effective budget for one call: a descriptor's `fuel` (0 = unset) may
/// tighten the default but never exceed it, a fat-fingered manifest stays
/// a setting, not an unmetered run (the same clamp philosophy as rlm's
/// max_depth ceiling).
fn fuelBudget(requested: u64) u64 {
    return if (requested == 0) default_fuel else @min(requested, default_fuel);
}
/// Linear memory cap in wasm pages (64 KiB each): 256 pages = 16 MiB.
const max_memory_pages = 256;

/// AssemblyScript runtime import; a no-op (the guest's abort handling is not
/// needed inside the sandbox, traps surface as ToolTrap).
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
    // than read, create a directory, rename, copy, delete, append, stat, find
    // by name, grep, did not exist as far as any tool was concerned.
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
    try lk.defineFuncCtx("env", "ck_tool", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckTool);
    try lk.defineFuncCtx("env", "ck_subagent", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckSubagent);
    try lk.defineFuncCtx("env", "ck_swarm", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckSwarm);
    try lk.defineFuncCtx("env", "ck_ask", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckAsk);
    try lk.defineFuncCtx("env", "ck_docker", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckDocker);
    try lk.defineFuncCtx("env", "ck_llm", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckLlm);
    try lk.defineFuncCtx("env", "ck_llm_many", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckLlmMany);
    try lk.defineFuncCtx("env", "ck_chat", h, fn (*zwasm.Caller, u32, u32) u32, &host.ckChat);
    try lk.defineFuncCtx("env", "ck_stats", h, fn (*zwasm.Caller) u32, &host.ckStats);
    try lk.defineFuncCtx("env", "ck_config", h, fn (*zwasm.Caller) u32, &host.ckConfig);
    try lk.defineFuncCtx("env", "ck_harness_config", h, fn (*zwasm.Caller) u32, &host.ckHarnessConfig);
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
        // Re-read memory after every call into the guest, not once up front: a
        // guest allocator can grow linear memory to satisfy an allocation
        // (AssemblyScript's does, readily, a JSON-heavy tool like csv_json
        // triggers it on input too small to look like a memory concern), and
        // a slice captured before that call points at a size that no longer
        // matches the instance's actual memory. This surfaced as a spurious
        // ToolInvalidOutput on well-formed output from a tool that happened
        // to allocate enough during run() to grow past its starting size.
        const mem_before_run = self.inst.memory() orelse return error.ToolNoMemory;
        const scratch_mem = mem_before_run.slice();
        if (@as(u64, scratch_ptr) + input.len > scratch_mem.len) return error.ToolScratchTooSmall;
        @memcpy(scratch_mem[scratch_ptr .. scratch_ptr + input.len], input);

        // ---- execute ----
        var run_fn = self.inst.typedFunc(fn (u32, u32) u64, "run");
        const p = run_fn.call(.{ scratch_ptr, @intCast(input.len) }) catch |err| {
            log.log(.error_, "[sandbox] tool trap: {s} (tool={s})", .{ @errorName(err), self.name });
            return error.ToolTrap;
        };
        const r = protocol.unpackPtrLen(p);
        const mem_after_run = self.inst.memory() orelse return error.ToolNoMemory;
        const mem_bytes = mem_after_run.slice();
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
        .tool_self_name = "chat_send",
    };

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/chat.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();

    const out = try mod.executeTool("{\"room\":\"dev\",\"text\":\"hello from wasm\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\"ok\":true") != null);

    // The message must have landed in the (isolated) chatroom log.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const hist = try chatrooms_mod.readHistory(tmp.dir, io, std.testing.allocator, arena, "", "dev", 0, 10);
    try std.testing.expectEqual(@as(usize, 1), hist.len);
    try std.testing.expectEqualStrings("hello from wasm", hist[0].text);
    try std.testing.expectEqualStrings("test-clanker", hist[0].from);
}

test "web_search wasm tool returns results from a live backend (skips when offline)" {
    // Runs the real web_search.wasm through the real ck_http host bridge, so it
    // exercises input parsing, URL building, the network call, RSS/HTML parsing,
    // entity/URL decoding and JSON output together. Network-dependent: when no
    // backend is reachable (offline CI), the run fails gracefully and the test
    // asserts nothing rather than failing the tool gate on a transient outage.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = config_mod.Config{};
    cfg.instance.name = "test-clanker";

    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = "/tmp/ck-sandbox-test",
        .network_allow = &.{ "www.bing.com", "lite.duckduckgo.com" },
        .environ_map = &env_map,
        .cfg = &cfg,
        .state_dir = "",
        .state_base_dir = tmp.dir,
        .config_json = "{}",
    };

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/web_search.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const mod = ToolModule.load(std.testing.allocator, io, &sb, wasm) catch return error.SkipZigTest;
    defer mod.deinit();

    const out = mod.executeTool("{\"query\":\"zig programming language\",\"max_results\":4}") catch return error.SkipZigTest; // offline
    defer std.testing.allocator.free(out);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out, .{});
    if (parsed != .object) return;

    // A successful search must parse as an object; when it advertises ok and
    // carries results, verify the shape (backend tag, real URLs). When the
    // network is down or a backend is empty, nothing here is asserted, so the
    // tool gate cannot fail on a transient outage.
    switch (parsed) {
        .object => |obj| {
            const ok_v = obj.get("ok");
            if (ok_v == null or ok_v.? != .bool or !ok_v.?.bool) return;
            const backend = obj.get("backend");
            try std.testing.expect(backend != null and backend.? == .string);
            const arr = obj.get("results");
            if (arr == null or arr.? != .array or arr.?.array.items.len == 0) return;
            if (arr.?.array.items[0] == .object) {
                if (arr.?.array.items[0].object.get("url")) |u| {
                    if (u == .string) {
                        try std.testing.expect(std.mem.startsWith(u8, u.string, "http"));
                    }
                }
            }
        },
        else => return,
    }
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
                .tool_self_name = "board",
            };
            const mod = try ToolModule.load(std.testing.allocator, io_, &sb, wasm_);
            defer mod.deinit();
            return mod.executeTool(args);
        }
    };

    // 25 cards: five more than one history page (host page size 20). All the
    // adds land within a second or two, so they share a timestamp, exactly
    // the shape that used to fold to its newest page only: the host answered
    // history newest-first, the fold's `ts > after` cursor jumped to the top,
    // and the oldest cards silently vanished from every kanban_list.
    var i: usize = 1;
    while (i <= 25) : (i += 1) {
        const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"title\":\"card-{d:0>2}\"}}", .{i});
        defer std.testing.allocator.free(args);
        const out = try Step.run(io, &cfg, &env_map, tmp.dir, wasm, "{\"op\":\"create\"}", args);
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.find(u8, out, "\"ok\":true") != null);
    }

    const listed = try Step.run(io, &cfg, &env_map, tmp.dir, wasm, "{\"op\":\"list\"}", "{}");
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.find(u8, listed, "\"ok\":true") != null);
    i = 1;
    while (i <= 25) : (i += 1) {
        const title = try std.fmt.allocPrint(std.testing.allocator, "\"title\":\"card-{d:0>2}\"", .{i});
        defer std.testing.allocator.free(title);
        try std.testing.expect(std.mem.find(u8, listed, title) != null);
    }
}

test "board wasm tool assigns at creation, and update's assignee reassigns" {
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

    // Each op is its own descriptor config, so each step is its own module,
    // sharing the room's log through the same state dir.
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
                .tool_self_name = "board",
            };
            const mod = try ToolModule.load(std.testing.allocator, io_, &sb, wasm_);
            defer mod.deinit();
            return mod.executeTool(args);
        }
    };

    // A bare card first, so the later update has something unassigned to hit.
    const first = try Step.run(io, &cfg, &env_map, tmp.dir, wasm, "{\"op\":\"create\"}", "{\"title\":\"bare\"}");
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.find(u8, first, "\"ok\":true") != null);

    // kanban_add's manifested `assignee` puts the card on someone at creation.
    const second = try Step.run(io, &cfg, &env_map, tmp.dir, wasm, "{\"op\":\"create\"}", "{\"title\":\"taken\",\"assignee\":\"beta\"}");
    defer std.testing.allocator.free(second);
    try std.testing.expect(std.mem.find(u8, second, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, second, "\"assignee\":\"beta\"") != null);
    try std.testing.expect(std.mem.find(u8, second, "\"assigned_by\":\"test-clanker\"") != null);

    // The bare card is the only one in the first reply; its id leads the entry.
    const lead = "\"cards\":[{\"id\":\"";
    const start = (std.mem.find(u8, first, lead) orelse return error.TestUnexpectedResult) + lead.len;
    const end = std.mem.findScalarPos(u8, first, start, '"') orelse return error.TestUnexpectedResult;
    const card_id = first[start..end];

    // kanban_update's manifested `assignee` reassigns (it used to be silently
    // dropped by ignore_unknown_fields when only `who` was wired).
    const upd = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":\"{s}\",\"assignee\":\"gamma\"}}", .{card_id});
    defer std.testing.allocator.free(upd);
    const third = try Step.run(io, &cfg, &env_map, tmp.dir, wasm, "{\"op\":\"update\"}", upd);
    defer std.testing.allocator.free(third);
    try std.testing.expect(std.mem.find(u8, third, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, third, "\"assignee\":\"gamma\"") != null);
    try std.testing.expect(std.mem.find(u8, third, "\"assignee\":\"beta\"") != null); // the other card kept its owner
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
            .tool_self_name = step.op,
        };
        defer std.testing.allocator.free(@constCast(sb.config_json));
        const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
        defer mod.deinit();
        const out = try mod.executeTool(step.args);
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.find(u8, out, "\"ok\":true") != null);
        try std.testing.expect(std.mem.find(u8, out, step.expect) != null);
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
        .tool_self_name = "todo_add",
    };
    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();
    const out = try mod.executeTool("{\"title\":\"nope\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\"ok\":false") != null);
    try std.testing.expect(std.mem.find(u8, out, "host wiring error") != null);
}

test "todo_* through the real wasm tool moves List.rev and yields the browser's payload" {
    // The other half of the checklist-in-the-browser path (webui PRD 0006
    // phase 3.3): the agent loop decides whether to push a `todos` event by
    // watching `List.rev`, and serializes with `listJson`. Both are driven
    // here from real guest tool calls rather than from applyTodoOp directly,
    // so a change in the guest's argument handling cannot silently stop the
    // browser from ever seeing an update.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var cfg = config_mod.Config{};
    var todos = private_todos_mod.List{ .alloc = std.testing.allocator };
    defer todos.deinit();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/chat.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const Step = struct { op: []const u8, args: []const u8, moves: bool };
    const steps = [_]Step{
        .{ .op = "todo_add", .args = "{\"title\":\"read build.zig\"}", .moves = true },
        .{ .op = "todo_add", .args = "{\"title\":\"<b>patch</b> it\"}", .moves = true },
        // Reading the list is not a change, so a run that polls todo_list in
        // a loop must not push an event per poll.
        .{ .op = "todo_list", .args = "{}", .moves = false },
        .{ .op = "todo_close", .args = "{\"todo\":\"p1\"}", .moves = true },
        .{ .op = "todo_close", .args = "{\"todo\":\"p1\"}", .moves = false },
    };
    for (steps) |step| {
        const before = todos.rev;
        var sb = host.Sandbox{
            .gpa = std.testing.allocator,
            .io = io,
            .root_dir = "/tmp/ck-sandbox-test",
            .network_allow = &.{},
            .environ_map = &env_map,
            .cfg = &cfg,
            .private_todos = &todos,
            .config_json = try std.fmt.allocPrint(std.testing.allocator, "{{\"op\":\"{s}\"}}", .{step.op}),
            .tool_self_name = step.op,
        };
        defer std.testing.allocator.free(@constCast(sb.config_json));
        const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
        defer mod.deinit();
        const out = try mod.executeTool(step.args);
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.find(u8, out, "\"ok\":true") != null);
        try std.testing.expectEqual(step.moves, todos.rev != before);
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const json = try private_todos_mod.listJson(&todos, arena_state.allocator());
    try std.testing.expectEqualStrings(
        "[{\"todo\":\"p1\",\"title\":\"read build.zig\",\"status\":\"closed\"}," ++
            "{\"todo\":\"p2\",\"title\":\"<b>patch</b> it\",\"status\":\"open\"}]",
        json,
    );
}

test "webui wasm tool serves every module the asset route names" {
    // `clanker serve` cannot be driven in every environment, so this is the
    // asset half of the routing proof: the route list in src/cli.zig decides
    // whether a request is answered at all, and this decides what comes back.
    // A module wired into one and not the other is the 404 that hid
    // features/arena.js.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var cfg = config_mod.Config{};

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/webui.wasm", std.testing.allocator, .limited(8 << 20));
    defer std.testing.allocator.free(wasm);

    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = "/tmp/ck-sandbox-test",
        .network_allow = &.{},
        .environ_map = &env_map,
        .cfg = &cfg,
        .tool_self_name = "webui",
    };
    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();

    const Case = struct { path: []const u8, marker: []const u8 };
    for ([_]Case{
        .{ .path = "/webui/features/todos.js", .marker = "renderTurnTodos" },
        .{ .path = "/webui/features/arena.js", .marker = "export" },
        .{ .path = "/webui/features/prompts.js", .marker = "export" },
        .{ .path = "/webui/features/compare.js", .marker = "loadCompareView" },
    }) |case| {
        const args = try std.fmt.allocPrint(std.testing.allocator, "{{\"path\":\"{s}\"}}", .{case.path});
        defer std.testing.allocator.free(args);
        const out = try mod.executeTool(args);
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.find(u8, out, "\"ok\":true") != null);
        try std.testing.expect(std.mem.find(u8, out, "text/javascript") != null);
        try std.testing.expect(std.mem.find(u8, out, case.marker) != null);
        // The page is the catch-all, so a module that fell out of assetFor
        // comes back as index.html with a 200 rather than an error.
        try std.testing.expect(std.mem.find(u8, out, "<!doctype html>") == null);
    }
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
        .tool_self_name = "ask_user",
    };
    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();
    const out = try mod.executeTool("{\"question\":\"Which one?\",\"options\":[\"A\",\"B\"],\"parent\":true}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"answer\":\"B\"") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"answered_by\":\"parent\"") != null);

    // A top-level run: no parent attached, so the tool says to decide alone
    // instead of pretending someone answered.
    var sb_top = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = "/tmp/ck-sandbox-test",
        .network_allow = &.{},
        .environ_map = &env_map,
        .tool_self_name = "ask_user",
    };
    const mod_top = try ToolModule.load(std.testing.allocator, io, &sb_top, wasm);
    defer mod_top.deinit();
    const out_top = try mod_top.executeTool("{\"question\":\"Which one?\",\"options\":[\"A\",\"B\"],\"parent\":true}");
    defer std.testing.allocator.free(out_top);
    try std.testing.expect(std.mem.find(u8, out_top, "\"ok\":false") != null);
    try std.testing.expect(std.mem.find(u8, out_top, "no parent to ask") != null);
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
        .tool_self_name = "model_stats",
    };

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/model_stats.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();

    const out = try mod.executeTool("{}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, out, "\"stats\":[]") != null);

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
    try std.testing.expect(std.mem.find(u8, out2, "\"calls\":1") != null);

    // The CLI asks the same tool for its human-readable table. Keep the
    // structured response above stable for model callers.
    const text_out = try mod.executeTool("{\"args\":\"\"}");
    defer std.testing.allocator.free(text_out);
    try std.testing.expect(std.mem.find(u8, text_out, "\"text\":") != null);
    try std.testing.expect(std.mem.find(u8, text_out, "provider        model") != null);
    try std.testing.expect(std.mem.find(u8, text_out, "kimi-k3") != null);
    try std.testing.expect(std.mem.find(u8, text_out, "totals") != null);
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
    try std.testing.expect(std.mem.find(u8, write_out, "\"ok\":true") != null);

    // A run_id crossing a path boundary must be rejected, not silently escape
    // state/runs/.
    const bad_out = try mod.executeTool("{\"write\":{\"run_id\":\"../escape\"}}");
    defer std.testing.allocator.free(bad_out);
    try std.testing.expect(std.mem.find(u8, bad_out, "\"ok\":false") != null);

    const mod2 = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod2.deinit();
    const read_out = try mod2.executeTool("{\"args\":\"" ++ run_id ++ "\"}");
    defer std.testing.allocator.free(read_out);
    try std.testing.expect(std.mem.find(u8, read_out, run_id) != null);
    try std.testing.expect(std.mem.find(u8, read_out, "tool gate  3 B") != null);

    // The parent link survives the round trip: a nested run's graph must
    // still name its caller when read back as JSON (the web UI's view).
    const mod3 = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod3.deinit();
    const json_out = try mod3.executeTool("{\"args\":\"json " ++ run_id ++ "\"}");
    defer std.testing.allocator.free(json_out);
    try std.testing.expect(std.mem.find(u8, json_out, "\\\"parent_run_id\\\":\\\"run-parent\\\"") != null);
}

test "cmd_sessions and cmd_graph report empty when the state dir does not exist" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    // A sandbox root with no state/ at all, what a fresh clone looks like,
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
        .{ .wasm = "zig-out/tools/cmd_sessions.wasm", .want = "No saved conversations yet" },
        .{ .wasm = "zig-out/tools/cmd_graph.wasm", .want = "(no runs yet" },
    };
    for (cases) |c| {
        const wasm = try std.Io.Dir.cwd().readFileAlloc(io, c.wasm, std.testing.allocator, .limited(1 << 20));
        defer std.testing.allocator.free(wasm);
        const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
        defer mod.deinit();
        const out = try mod.executeTool("{}");
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.find(u8, out, "\"ok\":true") != null);
        try std.testing.expect(std.mem.find(u8, out, c.want) != null);
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
        \\- **Shipped thing**, landed last week.
        \\
        \\## Planned
        \\
        \\- **Plugin SDK**, manifest format for third-party tools.
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
    try std.testing.expect(std.mem.find(u8, planned, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, planned, "Plugin SDK") != null);
    // Autolearn bullets are open work too, only "## Done" is excluded.
    try std.testing.expect(std.mem.find(u8, planned, "Optimize the most-used tools") != null);
    try std.testing.expect(std.mem.find(u8, planned, "Shipped thing") == null);
    try std.testing.expect(std.mem.find(u8, planned, "checked item") == null);
    try std.testing.expect(std.mem.find(u8, planned, "sub-bullet") == null);
    try std.testing.expect(std.mem.find(u8, planned, "no planned items") == null);

    const mod2 = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod2.deinit();
    const all = try mod2.executeTool("{\"list\":\"all\"}");
    defer std.testing.allocator.free(all);
    try std.testing.expect(std.mem.find(u8, all, "Shipped thing") != null);
    try std.testing.expect(std.mem.find(u8, all, "checked item") != null);
    try std.testing.expect(std.mem.find(u8, all, "## Done") != null);
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
    // (empty string) must not blank out a real one that follows. Timestamps
    // must be recent: the aggregation only counts the last 7 days, and an
    // ancient event (like the stale one below) must be ignored.
    try tmp.dir.createDirPath(io, "state");
    try tmp.dir.createDirPath(io, "docs");
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000_000));
    const log_data = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"ts":1,"type":"tool_error","tool":"git","detail":"ancient, outside the window"}}
        \\{{"ts":{d},"type":"tool_error","tool":"git","detail":"git exited 1: usage"}}
        \\{{"ts":{d},"type":"tool_error","tool":"git","detail":""}}
        \\{{"ts":{d},"type":"tool_error","tool":"git","detail":"git exited 128: not a git repository"}}
        \\{{"ts":{d},"type":"tool_error","tool":"git","detail":"identical tool call already executed twice with the same arguments; do not repeat it"}}
        \\
    , .{ now - 3, now - 2, now - 1, now });
    defer std.testing.allocator.free(log_data);
    try tmp.dir.writeFile(io, .{ .sub_path = "state/autolearn.jsonl", .data = log_data });
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
    try std.testing.expect(std.mem.find(u8, out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, out, "3 failure(s), last: git exited 128: not a git repository") != null);
    try std.testing.expect(std.mem.find(u8, out, "last: git exited 1: usage") == null);
    // The ancient event fell outside the 7-day window, and the duplicate-call
    // guard refusal was bucketed separately instead of counted as a git error.
    try std.testing.expect(std.mem.find(u8, out, "ancient, outside the window") == null);
    try std.testing.expect(std.mem.find(u8, out, "4 failure(s)") == null);
}

test "cmd_janitor wasm tool scans and removes only shaped staging directories" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state/staging/imp-123");
    try tmp.dir.createDirPath(io, "state/staging/keep-me");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/staging/imp-123/data", .data = "discard" });
    try tmp.dir.writeFile(io, .{ .sub_path = "state/staging/keep-me/data", .data = "preserve" });
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = root,
        .network_allow = &.{},
        .fs_prefixes = &.{ "state/staging", "state/runs", "state/logs" },
        .environ_map = &env_map,
    };

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/cmd_janitor.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);
    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();

    const scan = try mod.executeTool("{\"op\":\"scan\",\"state_dir\":\"state\"}");
    defer std.testing.allocator.free(scan);
    try std.testing.expect(std.mem.find(u8, scan, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, scan, "orphaned staging directory") != null);

    const pruned = try mod.executeTool("{\"op\":\"prune\",\"state_dir\":\"state\"}");
    defer std.testing.allocator.free(pruned);
    try std.testing.expect(std.mem.find(u8, pruned, "Removed 7 B") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "state/staging/imp-123", .{}));
    _ = try tmp.dir.statFile(io, "state/staging/keep-me/data", .{});
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
    try std.testing.expect(std.mem.find(u8, out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, out, "\\n") == null);
    // The author is the one field the format wraps in parens, so its
    // presence says the whole format string survived argv assembly.
    try std.testing.expect(std.mem.find(u8, out, "(") != null);
}

test "assemblyscript calc_ts tool executes" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "tools/ts/dist/calc_ts.wasm", std.testing.allocator, .limited(1 << 20));
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

fn loadAsTool(gpa: std.mem.Allocator, io: std.Io, sb: *host.Sandbox, name: []const u8) !*ToolModule {
    const path = try std.fmt.allocPrint(gpa, "tools/ts/dist/{s}.wasm", .{name});
    defer gpa.free(path);
    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(wasm);
    return ToolModule.load(gpa, io, sb, wasm);
}

test "assemblyscript json_tool validates, pretty-prints and minifies" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var sb = host.Sandbox{ .gpa = std.testing.allocator, .io = io, .root_dir = "/tmp/ck-sandbox-test", .network_allow = &.{}, .environ_map = &env_map };
    const mod = try loadAsTool(std.testing.allocator, io, &sb, "json_tool");
    defer mod.deinit();

    // The reply is itself a JSON string (the "text" field), so a literal
    // `"` inside the pretty-printed body comes back as the two bytes `\"`.
    const pretty = try mod.executeTool("{\"json\": \"{\\\"b\\\":1,\\\"a\\\":[1,2]}\", \"mode\": \"pretty\"}");
    defer std.testing.allocator.free(pretty);
    try std.testing.expect(std.mem.find(u8, pretty, "\\n") != null);
    try std.testing.expect(std.mem.find(u8, pretty, "\\\"b\\\": 1") != null);

    const minified = try mod.executeTool("{\"json\": \"{ \\\"a\\\" : 1 }\", \"mode\": \"minify\"}");
    defer std.testing.allocator.free(minified);
    try std.testing.expectEqualStrings("{\"ok\":true,\"text\":\"{\\\"a\\\":1}\"}", minified);

    const invalid = try mod.executeTool("{\"json\": \"{bad}\"}");
    defer std.testing.allocator.free(invalid);
    try std.testing.expect(std.mem.find(u8, invalid, "\"ok\":false") != null);
    try std.testing.expect(std.mem.find(u8, invalid, "line 1") != null);
}

test "assemblyscript id_gen produces well-formed uuid4, ulid and short ids" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var sb = host.Sandbox{ .gpa = std.testing.allocator, .io = io, .root_dir = "/tmp/ck-sandbox-test", .network_allow = &.{}, .environ_map = &env_map };
    const mod = try loadAsTool(std.testing.allocator, io, &sb, "id_gen");
    defer mod.deinit();

    const uuid_out = try mod.executeTool("{\"kind\": \"uuid4\"}");
    defer std.testing.allocator.free(uuid_out);
    // {"ok":true,"text":"........-....-4...-[89ab]...-............"}
    const u_start = std.mem.find(u8, uuid_out, "\"text\":\"").? + 8;
    const uuid = uuid_out[u_start .. u_start + 36];
    try std.testing.expectEqual(@as(u8, '-'), uuid[8]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[13]);
    try std.testing.expectEqual(@as(u8, '4'), uuid[14]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[18]);
    try std.testing.expect(std.mem.findScalar(u8, "89ab", uuid[19]) != null);
    try std.testing.expectEqual(@as(u8, '-'), uuid[23]);

    // 3 short ids, newline-separated; the wrapper escapes each raw newline
    // to the two bytes \n, so the reply's byte-count grows by 2 per
    // separator rather than gaining a raw 0x0A.
    const short_out = try mod.executeTool("{\"kind\": \"short\", \"length\": 12, \"count\": 3}");
    defer std.testing.allocator.free(short_out);
    var esc_newlines: usize = 0;
    var k: usize = 0;
    while (k + 1 < short_out.len) : (k += 1) {
        if (short_out[k] == '\\' and short_out[k + 1] == 'n') esc_newlines += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), esc_newlines);

    const ulid_out = try mod.executeTool("{\"kind\": \"ulid\"}");
    defer std.testing.allocator.free(ulid_out);
    const l_start = std.mem.find(u8, ulid_out, "\"text\":\"").? + 8;
    try std.testing.expectEqual(@as(usize, 26), std.mem.findScalarPos(u8, ulid_out, l_start, '"').? - l_start);
}

test "assemblyscript text_diff renders a unified diff with hunk headers" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var sb = host.Sandbox{ .gpa = std.testing.allocator, .io = io, .root_dir = "/tmp/ck-sandbox-test", .network_allow = &.{}, .environ_map = &env_map };
    const mod = try loadAsTool(std.testing.allocator, io, &sb, "text_diff");
    defer mod.deinit();

    const out = try mod.executeTool("{\"a\": \"one\\ntwo\\nthree\\n\", \"b\": \"one\\nTWO\\nthree\\n\", \"context\": 1}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "-two") != null);
    try std.testing.expect(std.mem.find(u8, out, "+TWO") != null);
    try std.testing.expect(std.mem.find(u8, out, "@@ -1,3 +1,3 @@") != null);

    const same = try mod.executeTool("{\"a\": \"x\\n\", \"b\": \"x\\n\"}");
    defer std.testing.allocator.free(same);
    try std.testing.expectEqualStrings("{\"ok\":true,\"text\":\"(identical)\"}", same);
}

test "assemblyscript csv_json round-trips through both directions" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var sb = host.Sandbox{ .gpa = std.testing.allocator, .io = io, .root_dir = "/tmp/ck-sandbox-test", .network_allow = &.{}, .environ_map = &env_map };
    const mod = try loadAsTool(std.testing.allocator, io, &sb, "csv_json");
    defer mod.deinit();

    const to_json = try mod.executeTool("{\"csv\": \"name,age\\nAda,36\\n\\\"Grace, Hopper\\\",85\\n\"}");
    defer std.testing.allocator.free(to_json);
    try std.testing.expect(std.mem.find(u8, to_json, "\\\"name\\\": \\\"Ada\\\"") != null);
    try std.testing.expect(std.mem.find(u8, to_json, "Grace, Hopper") != null);

    const to_csv = try mod.executeTool("{\"json\": \"[{\\\"a\\\":1,\\\"b\\\":\\\"x,y\\\"},{\\\"a\\\":2}]\"}");
    defer std.testing.allocator.free(to_csv);
    try std.testing.expect(std.mem.find(u8, to_csv, "a,b") != null);
    try std.testing.expect(std.mem.find(u8, to_csv, "x,y") != null);
    try std.testing.expect(std.mem.find(u8, to_csv, "2,") != null);
}

fn loadZigOutTool(gpa: std.mem.Allocator, io: std.Io, sb: *host.Sandbox, name: []const u8) !*ToolModule {
    const path = try std.fmt.allocPrint(gpa, "zig-out/tools/{s}.wasm", .{name});
    defer gpa.free(path);
    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(wasm);
    return ToolModule.load(gpa, io, sb, wasm);
}

test "C tool crc32 computes the standard IEEE 802.3 checksum" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var sb = host.Sandbox{ .gpa = std.testing.allocator, .io = io, .root_dir = "/tmp/ck-sandbox-test", .network_allow = &.{}, .environ_map = &env_map };
    const mod = try loadZigOutTool(std.testing.allocator, io, &sb, "crc32");
    defer mod.deinit();

    // "123456789" -> 0xcbf43926 is the standard CRC-32/ISO-HDLC check value.
    const out = try mod.executeTool("{\"text\": \"123456789\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"ok\":true,\"text\":\"cbf43926\"}", out);
}

test "C tool base64 round-trips encode and decode" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var sb = host.Sandbox{ .gpa = std.testing.allocator, .io = io, .root_dir = "/tmp/ck-sandbox-test", .network_allow = &.{}, .environ_map = &env_map };
    const mod = try loadZigOutTool(std.testing.allocator, io, &sb, "base64");
    defer mod.deinit();

    const enc = try mod.executeTool("{\"text\": \"hello world\"}");
    defer std.testing.allocator.free(enc);
    try std.testing.expectEqualStrings("{\"ok\":true,\"text\":\"aGVsbG8gd29ybGQ=\"}", enc);

    const dec = try mod.executeTool("{\"text\": \"aGVsbG8gd29ybGQ=\", \"mode\": \"decode\"}");
    defer std.testing.allocator.free(dec);
    try std.testing.expectEqualStrings("{\"ok\":true,\"text\":\"hello world\"}", dec);

    const bad = try mod.executeTool("{\"text\": \"not!valid\", \"mode\": \"decode\"}");
    defer std.testing.allocator.free(bad);
    try std.testing.expect(std.mem.find(u8, bad, "\"ok\":false") != null);
}

test "C tool hexdump renders 16-byte rows with an ASCII gutter" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var sb = host.Sandbox{ .gpa = std.testing.allocator, .io = io, .root_dir = "/tmp/ck-sandbox-test", .network_allow = &.{}, .environ_map = &env_map };
    const mod = try loadZigOutTool(std.testing.allocator, io, &sb, "hexdump");
    defer mod.deinit();

    const out = try mod.executeTool("{\"text\": \"Hi\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "00000000: 48 69") != null);
    try std.testing.expect(std.mem.find(u8, out, "Hi") != null);
}

test "C++ tool roman_numeral converts both directions" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var sb = host.Sandbox{ .gpa = std.testing.allocator, .io = io, .root_dir = "/tmp/ck-sandbox-test", .network_allow = &.{}, .environ_map = &env_map };
    const mod = try loadZigOutTool(std.testing.allocator, io, &sb, "roman_numeral");
    defer mod.deinit();

    const to_numeral = try mod.executeTool("{\"value\": 1994}");
    defer std.testing.allocator.free(to_numeral);
    try std.testing.expectEqualStrings("{\"ok\":true,\"text\":\"MCMXCIV\"}", to_numeral);

    const to_int = try mod.executeTool("{\"text\": \"MCMXCIV\"}");
    defer std.testing.allocator.free(to_int);
    try std.testing.expectEqualStrings("{\"ok\":true,\"text\":\"1994\"}", to_int);

    const out_of_range = try mod.executeTool("{\"value\": 4000}");
    defer std.testing.allocator.free(out_of_range);
    try std.testing.expect(std.mem.find(u8, out_of_range, "\"ok\":false") != null);
}

test "C++ tool levenshtein computes edit distance" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var sb = host.Sandbox{ .gpa = std.testing.allocator, .io = io, .root_dir = "/tmp/ck-sandbox-test", .network_allow = &.{}, .environ_map = &env_map };
    const mod = try loadZigOutTool(std.testing.allocator, io, &sb, "levenshtein");
    defer mod.deinit();

    // kitten -> sitting is the textbook distance-3 example.
    const out = try mod.executeTool("{\"a\": \"kitten\", \"b\": \"sitting\"}");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("{\"ok\":true,\"text\":\"3\"}", out);
}

test "C++ tool run_length round-trips encode and decode" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();
    var sb = host.Sandbox{ .gpa = std.testing.allocator, .io = io, .root_dir = "/tmp/ck-sandbox-test", .network_allow = &.{}, .environ_map = &env_map };
    const mod = try loadZigOutTool(std.testing.allocator, io, &sb, "run_length");
    defer mod.deinit();

    const enc = try mod.executeTool("{\"text\": \"aaabbbbc\"}");
    defer std.testing.allocator.free(enc);
    try std.testing.expectEqualStrings("{\"ok\":true,\"text\":\"3a4b1c\"}", enc);

    const dec = try mod.executeTool("{\"text\": \"3a4b1c\", \"mode\": \"decode\"}");
    defer std.testing.allocator.free(dec);
    try std.testing.expectEqualStrings("{\"ok\":true,\"text\":\"aaabbbbc\"}", dec);

    const malformed = try mod.executeTool("{\"text\": \"abc\", \"mode\": \"decode\"}");
    defer std.testing.allocator.free(malformed);
    try std.testing.expect(std.mem.find(u8, malformed, "\"ok\":false") != null);
}

test "a tool with a tiny fuel budget runs out of fuel; the default budget answers" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "tools/ts/dist/calc_ts.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    // 15k is measured to cover this module's instantiation and arena
    // discovery (~10.3k) but not a run (~18.8k more), so the trap lands in
    // executeTool, deterministically, since fuel accounting is
    // instruction-exact, and surfaces as ToolTrap, the error callers know,
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

/// One `arena` call against an isolated sandbox root. `llm` is left unset, so
/// every `ck_llm` is denied, which is exactly how these tests reach the
/// forfeit path without a provider account.
fn arenaCall(io: std.Io, root: []const u8, wasm: []const u8, env: *std.process.Environ.Map, input: []const u8) ![]u8 {
    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = root,
        .network_allow = &.{},
        .fs_prefixes = &.{"state/arena/"},
        .environ_map = env,
    };
    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();
    return mod.executeTool(input);
}

test "arena wasm tool refuses a match without two distinct sides" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/arena.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    // A debate needs at least two distinct sides, and 3-4 way matches are not
    // implemented. Every one of these is refused at the tool boundary rather
    // than started and abandoned partway through, which for this tool means
    // refused before it has spent a single model call.
    const cases = [_]struct { input: []const u8, want: []const u8 }{
        .{ .input = "{\"question\":\"q\",\"for\":\"a\"}", .want = "two distinct positions" },
        .{ .input = "{\"question\":\"q\",\"against\":\"b\"}", .want = "two distinct positions" },
        .{ .input = "{\"question\":\"q\",\"for\":\"a\",\"against\":\" a \"}", .want = "identical" },
        .{ .input = "{\"question\":\"q\",\"for\":\"a\",\"against\":\"  \"}", .want = "cannot be blank" },
        .{ .input = "{\"question\":\"q\",\"positions\":[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\",\"i\"]}", .want = "at most 8" },
        .{ .input = "{\"question\":\"q\",\"positions\":[\"a\",\"b\",\"a\"]}", .want = "identical" },
        // Design-review seeding needs something real on both sides, and derives
        // the positions, so a half-seeded or double-seeded match is refused.
        .{ .input = "{\"question\":\"q\",\"defend\":\"impl A\"}", .want = "both \\\"defend\\\" and \\\"alternative\\\"" },
        .{ .input = "{\"question\":\"q\",\"alternative\":\"impl B\"}", .want = "both \\\"defend\\\" and \\\"alternative\\\"" },
        .{ .input = "{\"question\":\"q\",\"defend\":\"A\",\"alternative\":\"B\",\"for\":\"x\",\"against\":\"y\"}", .want = "derive the positions" },
        .{ .input = "{\"question\":\"q\",\"for\":\"a\",\"against\":\"b\",\"judge\":\"jury\"}", .want = "judge must be" },
    };
    for (cases) |c| {
        const outp = try arenaCall(io, root, wasm, &env_map, c.input);
        defer std.testing.allocator.free(outp);
        // Names the offending row: a table-driven assertion that only says
        // "expected true" makes six cases into one bisect.
        if (std.mem.find(u8, outp, "\"ok\":false") == null or
            std.mem.find(u8, outp, c.want) == null)
        {
            std.debug.print("arena refusal case {s}\n  wanted: {s}\n  got:    {s}\n", .{ c.input, c.want, outp });
            return error.TestUnexpectedResult;
        }
    }

    // A refusal must not have left a match file behind.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "state/arena", .{}));
}

test "arena wasm tool reports no matches on a fresh sandbox" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/arena.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const listed = try arenaCall(io, root, wasm, &env_map, "{}");
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.find(u8, listed, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, listed, "no arena matches yet") != null);

    // A match id that could climb out of state/arena/ is refused, rather than
    // reported as a missing match.
    for ([_][]const u8{ "../escape", "a/../../b", "a/b", "" }) |bad| {
        const req = try std.fmt.allocPrint(std.testing.allocator, "{{\"match\":\"{s}\"}}", .{bad});
        defer std.testing.allocator.free(req);
        const outp = try arenaCall(io, root, wasm, &env_map, req);
        defer std.testing.allocator.free(outp);
        // "" is absent rather than unsafe, so it lists instead of refusing;
        // every traversal attempt must be told apart from a real miss.
        if (bad.len == 0) continue;
        try std.testing.expect(std.mem.find(u8, outp, "\"ok\":false") != null);
        try std.testing.expect(std.mem.find(u8, outp, "not a match id") != null);
    }

    const missing = try arenaCall(io, root, wasm, &env_map, "{\"match\":\"arena-1-deadbeef\"}");
    defer std.testing.allocator.free(missing);
    try std.testing.expect(std.mem.find(u8, missing, "no such match") != null);
}

test "arena wasm tool finishes a match as forfeits when no provider answers" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/arena.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    // Every combatant call is denied (no `llm` grant on the sandbox), so this
    // drives the whole round loop down its failure path: a combatant whose
    // call errors forfeits the round, and the match still reaches a persisted
    // verdict instead of hanging or erroring out. That is the PRD's stated
    // behaviour for a mid-match provider failure, exercised end to end.
    const raw = try arenaCall(io, root, wasm, &env_map,
        \\{"question":"queue or direct calls?","for":"use a message queue","against":"use direct calls","max_rounds":2}
    );
    defer std.testing.allocator.free(raw);

    try std.testing.expect(std.mem.find(u8, raw, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, raw, "\"status\":\"finished\"") != null);
    try std.testing.expect(std.mem.find(u8, raw, "\"forfeit\":true") != null);
    // Nobody landed anything, so nobody won, and the verdict says so rather
    // than picking one of two untouched combatants.
    try std.testing.expect(std.mem.find(u8, raw, "\"reason\":\"draw\"") != null);
    try std.testing.expect(std.mem.find(u8, raw, "SandboxDenied") != null);

    var parsed_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parsed_arena.deinit();
    const a = parsed_arena.allocator();
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{});
    const match = doc.object.get("match").?.object;
    const id = match.get("id").?.string;
    // Both rounds ran: a forfeit is a played round, not an aborted match.
    try std.testing.expectEqual(@as(i64, 2), match.get("rounds_played").?.integer);
    try std.testing.expectEqual(@as(usize, 2), match.get("rounds").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 100), match.get("combatants").?.array.items[0].object.get("hp").?.integer);

    // The match is on disk under its own id, and reads back through the tool.
    const path = try std.fmt.allocPrint(std.testing.allocator, "state/arena/{s}.json", .{id});
    defer std.testing.allocator.free(path);
    const stored = try tmp.dir.readFileAlloc(io, path, std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(stored);
    try std.testing.expect(std.mem.find(u8, stored, "queue or direct calls?") != null);

    const req = try std.fmt.allocPrint(std.testing.allocator, "{{\"match\":\"{s}\"}}", .{id});
    defer std.testing.allocator.free(req);
    const read_back = try arenaCall(io, root, wasm, &env_map, req);
    defer std.testing.allocator.free(read_back);
    try std.testing.expect(std.mem.find(u8, read_back, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, read_back, id) != null);
    try std.testing.expect(std.mem.find(u8, read_back, "use a message queue") != null);

    // A finished match is replayable: the ledger carries it, so listing finds
    // it without walking every match file.
    const listed = try arenaCall(io, root, wasm, &env_map, "{}");
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.find(u8, listed, id) != null);
    try std.testing.expect(std.mem.find(u8, listed, "queue or direct calls?") != null);

    // The listing also answers structured, which is what the web UI's match
    // picker reads (GET /api/arena); the text table is for the CLI and an agent.
    var picker_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer picker_arena.deinit();
    const listing = try std.json.parseFromSliceLeaky(std.json.Value, picker_arena.allocator(), listed, .{});
    const entries = listing.object.get("matches").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings(id, entries[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("draw", entries[0].object.get("winner").?.string);
    try std.testing.expect(entries[0].object.get("headline").?.string.len > 0);
}

/// One `compare` call against an isolated sandbox root. `llm` is left unset, so
/// every `ck_llm_many` is denied, which is how these tests reach the tool's
/// refusal paths without a provider account.
fn compareCall(io: std.Io, root: []const u8, wasm: []const u8, env: *std.process.Environ.Map, input: []const u8) ![]u8 {
    var sb = host.Sandbox{
        .gpa = std.testing.allocator,
        .io = io,
        .root_dir = root,
        .network_allow = &.{},
        .fs_prefixes = &.{"state/compare/"},
        .environ_map = env,
    };
    const mod = try ToolModule.load(std.testing.allocator, io, &sb, wasm);
    defer mod.deinit();
    return mod.executeTool(input);
}

test "compare wasm tool refuses a comparison that is not one, before spending a call" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/compare.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const cases = [_]struct { input: []const u8, want: []const u8 }{
        // No config in this sandbox, so "every configured provider" is none.
        .{ .input = "{\"prompt\":\"q\"}", .want = "at least two models" },
        .{ .input = "{\"prompt\":\"q\",\"providers\":[\"a\"]}", .want = "at least two models" },
        .{ .input = "{\"prompt\":\"q\",\"providers\":[\"a\",\"b\",\"c\",\"d\",\"e\",\"f\",\"g\",\"h\",\"i\"]}", .want = "at most 8" },
        // Same provider and same model twice is one model sampled twice.
        .{ .input = "{\"prompt\":\"q\",\"targets\":[{\"provider\":\"a\",\"model\":\"m\"},{\"provider\":\"a\",\"model\":\"m\"}]}", .want = "not a comparison" },
        // Two models of one provider is the case that must NOT be refused, so
        // it gets as far as the denied model call instead.
        .{ .input = "{\"prompt\":\"q\",\"targets\":[{\"provider\":\"a\",\"model\":\"m1\"},{\"provider\":\"a\",\"model\":\"m2\"}]}", .want = "not allowed to call the model" },
        .{ .input = "{\"prompt\":\"q\",\"providers\":[\"a\",\"b\"]}", .want = "not allowed to call the model" },
    };
    for (cases) |c| {
        const outp = try compareCall(io, root, wasm, &env_map, c.input);
        defer std.testing.allocator.free(outp);
        if (std.mem.find(u8, outp, "\"ok\":false") == null or
            std.mem.find(u8, outp, c.want) == null)
        {
            std.debug.print("compare refusal case {s}\n  wanted: {s}\n  got:    {s}\n", .{ c.input, c.want, outp });
            return error.TestUnexpectedResult;
        }
    }

    // Nothing was persisted: a comparison that never got an answer is not a
    // comparison, and must not leave a file to list later.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "state/compare", .{}));
}

test "compare wasm tool lists nothing on a fresh sandbox and refuses a traversing id" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/compare.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    const listed = try compareCall(io, root, wasm, &env_map, "{}");
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.find(u8, listed, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, listed, "no comparisons yet") != null);
    // An empty listing still carries the array, so a caller never has to tell
    // "none yet" apart from "this build has no such field".
    var listing_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer listing_arena.deinit();
    const listing = try std.json.parseFromSliceLeaky(std.json.Value, listing_arena.allocator(), listed, .{});
    try std.testing.expectEqual(@as(usize, 0), listing.object.get("comparisons").?.array.items.len);

    // An id that could climb out of state/compare/ is refused, not reported as
    // a missing comparison.
    for ([_][]const u8{ "../escape", "a/../../b", "a/b" }) |bad| {
        const req = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":\"{s}\"}}", .{bad});
        defer std.testing.allocator.free(req);
        const outp = try compareCall(io, root, wasm, &env_map, req);
        defer std.testing.allocator.free(outp);
        try std.testing.expect(std.mem.find(u8, outp, "\"ok\":false") != null);
        try std.testing.expect(std.mem.find(u8, outp, "no such comparison") != null);
    }
}

/// A real comparison, byte for byte off `state/compare/` after
/// `clanker compare "In one sentence, why is the sky blue?"
/// --with deepseek@deepseek-v4-flash --with deepseek@deepseek-v4-pro` against
/// the live DeepSeek provider on 2026-08-13. Written by `compare.zig`'s own
/// `persist`, not by hand: the point of the tests below is what the web UI's
/// read path does to a document the tool actually produced, and a fixture
/// invented here would only prove the two agree with each other.
const compare_fixture_id = "compare-1786554094-848a3169";
const compare_fixture =
    \\{"id":"compare-1786554094-848a3169","prompt":"In one sentence, why is the sky blue?","entrants":[{"label":"A","provider":"deepseek","model":"deepseek-v4-flash","ok":true,"ms":2651,"tokens":195,"answer":"The sky appears blue because air molecules scatter sunlight in all directions, and since blue light has a shorter wavelength, it is scattered much more efficiently than other colors, making it the dominant light we see from the sky."},{"label":"B","provider":"deepseek","model":"deepseek-v4-pro","ok":true,"ms":2228,"tokens":201,"answer":"The sky appears blue because molecules in Earth’s atmosphere scatter shorter wavelengths of sunlight, especially blue light, more strongly than longer wavelengths."}],"judge":{"provider":"deepseek","caveat":"the judge is also an entrant, so it may recognise its own answer","winner":"A","winner_provider":"deepseek","winner_model":"deepseek-v4-flash","reason":"Answer A more thoroughly explains the scattering mechanism and why blue specifically dominates, while remaining accurate and directly responsive."}}
;
/// The matching ledger line, the same one `appendLedger` wrote for it.
const compare_fixture_ledger =
    \\{"id":"compare-1786554094-848a3169","prompt":"In one sentence, why is the sky blue?","entrants":2,"winner":"deepseek"}
;

/// Everything a reader could act on to learn who wrote which answer. The model
/// names are the key itself; "deepseek" is the provider that appears in the
/// entrants, the judge and the ledger's winner column alike.
const compare_identity_needles = [_][]const u8{ "deepseek-v4-flash", "deepseek-v4-pro", "deepseek" };

fn expectNoCompareIdentity(where: []const u8, out: []const u8) !void {
    for (compare_identity_needles) |needle| {
        if (std.mem.find(u8, out, needle)) |at| {
            std.debug.print("{s} leaked \"{s}\" at byte {d}:\n{s}\n", .{ where, needle, at, out });
            return error.BlindComparisonLeaked;
        }
    }
}

test "compare wasm tool keeps a stored comparison blind for a reader who asked to be" {
    // The web UI's read path, end to end against a real stored document: this
    // is the property the Compare view is built on, and the only way to hold it
    // is for the payload itself to carry no provider and no model, a page can
    // decline to paint a field, but it cannot decline to have received it.
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state/compare");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/compare/" ++ compare_fixture_id ++ ".json", .data = compare_fixture });
    try tmp.dir.writeFile(io, .{ .sub_path = "state/compare/log.jsonl", .data = compare_fixture_ledger ++ "\n" });
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/compare.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    // The listing the view opens with. The ledger's winner column names the
    // winning provider, which would un-blind every row in it before one was
    // even clicked, so an un-revealed listing reports "judged" and no more.
    const listed = try compareCall(io, root, wasm, &env_map, "{\"reveal\":false}");
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.find(u8, listed, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, listed, "\"judged\":true") != null);
    try std.testing.expect(std.mem.find(u8, listed, compare_fixture_id) != null);
    try expectNoCompareIdentity("blind listing", listed);

    // The comparison itself, read blind.
    const blind = try compareCall(io, root, wasm, &env_map, "{\"id\":\"" ++ compare_fixture_id ++ "\",\"reveal\":false}");
    defer std.testing.allocator.free(blind);
    try std.testing.expect(std.mem.find(u8, blind, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, blind, "\"revealed\":false") != null);
    // Blind, not empty: both answers are there under their positional letters,
    // the judge's verdict is there as a letter, and the prompt is structured so
    // the view never has to scrape it back out of the rendered text.
    try std.testing.expect(std.mem.find(u8, blind, "\"label\":\"A\"") != null);
    try std.testing.expect(std.mem.find(u8, blind, "\"label\":\"B\"") != null);
    try std.testing.expect(std.mem.find(u8, blind, "\"winner\":\"A\"") != null);
    try std.testing.expect(std.mem.find(u8, blind, "why is the sky blue") != null);
    try std.testing.expect(std.mem.find(u8, blind, "Rayleigh") == null); // neither answer said it
    try expectNoCompareIdentity("blind read", blind);

    // And the same read with the default: `clanker compare --show <id>` reveals,
    // because whoever names an id already watched the blind view that minted it.
    const shown = try compareCall(io, root, wasm, &env_map, "{\"id\":\"" ++ compare_fixture_id ++ "\"}");
    defer std.testing.allocator.free(shown);
    try std.testing.expect(std.mem.find(u8, shown, "\"revealed\":true") != null);
    try std.testing.expect(std.mem.find(u8, shown, "deepseek-v4-flash") != null);
}

test "compare wasm tool reveals a stored comparison once a pick is recorded" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "state/compare");
    try tmp.dir.writeFile(io, .{ .sub_path = "state/compare/" ++ compare_fixture_id ++ ".json", .data = compare_fixture });
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/compare.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    // The pick the browser's button posts is the pick the CLI's
    // `--show <id> --pick <letter>` records: one op, one tool, one code path.
    const picked = try compareCall(io, root, wasm, &env_map, "{\"id\":\"" ++ compare_fixture_id ++ "\",\"pick\":\"B\"}");
    defer std.testing.allocator.free(picked);
    try std.testing.expect(std.mem.find(u8, picked, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, picked, "\"revealed\":true") != null);
    // Structured, so the view can say who you picked without reading the prose.
    try std.testing.expect(std.mem.find(u8, picked, "\"pick\":{\"label\":\"B\",\"provider\":\"deepseek\",\"model\":\"deepseek-v4-pro\"}") != null);

    // Recorded, not just reported: the document on disk carries it, and asking
    // to stay blind afterwards cannot un-commit a reader who has already chosen.
    const after = try compareCall(io, root, wasm, &env_map, "{\"id\":\"" ++ compare_fixture_id ++ "\",\"reveal\":false}");
    defer std.testing.allocator.free(after);
    try std.testing.expect(std.mem.find(u8, after, "\"revealed\":true") != null);
    try std.testing.expect(std.mem.find(u8, after, "\"label\":\"B\",\"provider\":\"deepseek\",\"model\":\"deepseek-v4-pro\"") != null);

    // A letter nobody answered under is refused rather than rounded to A.
    const bad = try compareCall(io, root, wasm, &env_map, "{\"id\":\"" ++ compare_fixture_id ++ "\",\"pick\":\"Z\"}");
    defer std.testing.allocator.free(bad);
    try std.testing.expect(std.mem.find(u8, bad, "\"ok\":false") != null);
    try std.testing.expect(std.mem.find(u8, bad, "not one of the answers on the table") != null);
}

test "arena wasm tool runs a battle royale to a verdict when no provider answers" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env_map = std.process.Environ.Map.init(std.testing.allocator);
    defer env_map.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);

    const wasm = try std.Io.Dir.cwd().readFileAlloc(io, "zig-out/tools/arena.wasm", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(wasm);

    // Five positions, every call denied: the same forfeit path as the pairwise
    // test, but exercising the N-combatant loop, the per-combatant seat labels
    // and the generalised verdict. A royale where nobody lands anything must
    // still terminate and persist, not hang or fall over on the wider board.
    const raw = try arenaCall(io, root, wasm, &env_map,
        \\{"question":"which store?","positions":["json file","append log","sqlite","in-memory","chatroom"],"max_rounds":2}
    );
    defer std.testing.allocator.free(raw);

    try std.testing.expect(std.mem.find(u8, raw, "\"ok\":true") != null);
    try std.testing.expect(std.mem.find(u8, raw, "\"status\":\"finished\"") != null);
    try std.testing.expect(std.mem.find(u8, raw, "battle royale, 5 positions") != null);

    var parsed_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parsed_arena.deinit();
    const a = parsed_arena.allocator();
    const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{});
    const match = doc.object.get("match").?.object;
    const cs = match.get("combatants").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), cs.len);
    // Seats are numbered above pairwise, which is also how a combatant names a
    // target, so the two have to agree.
    try std.testing.expectEqualStrings("p1", cs[0].object.get("side").?.string);
    try std.testing.expectEqualStrings("p5", cs[4].object.get("side").?.string);
    for (cs) |c| {
        try std.testing.expectEqual(@as(i64, 100), c.object.get("hp").?.integer);
        try std.testing.expectEqual(false, c.object.get("eliminated").?.bool);
    }
    // Every combatant forfeited in each of the two rounds: 5 x 2 moves.
    var forfeits: usize = 0;
    for (match.get("rounds").?.array.items) |r| {
        for (r.object.get("moves").?.array.items) |mv| {
            if (mv.object.get("forfeit")) |f| {
                if (f == .bool and f.bool) forfeits += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 10), forfeits);
    // Nobody took damage, so nobody outargued anybody.
    try std.testing.expectEqualStrings("draw", match.get("verdict").?.object.get("reason").?.string);
}
