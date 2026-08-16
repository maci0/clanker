//! Spawns the real, already-built `clanker` binary as a subprocess against a
//! temp working directory and a scripted mock LLM server (mock_llm.zig), so a
//! test can drive the actual CLI -> Agent.run -> LLM client -> sandboxed WASM
//! tool path end to end, with no real API key and no network egress.

const std = @import("std");
const e2e_options = @import("e2e_options");
const clanker_bin = e2e_options.clanker_bin;
const zig_out_dir = e2e_options.zig_out_dir;
const tools_manifests_dir = e2e_options.tools_manifests_dir;
const docs_dir = e2e_options.docs_dir;

pub const Run = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Run, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }

    pub fn ok(self: *const Run) bool {
        return switch (self.term) {
            .exited => |c| c == 0,
            else => false,
        };
    }
};

/// Writes a minimal single-provider config.toml into `dir`, pointed at a mock
/// server on 127.0.0.1:`port`. No `api_key_env`: the field is optional
/// (`config.zig` accepts a provider with none, e.g. a local Ollama-style
/// entry), and the mock server never checks auth, so there is nothing to
/// fake a credential for. `tools_dir` is the real repo's absolute
/// `tools/manifests` path (`config.toml`'s `tools_dir` and every
/// descriptor's relative `"wasm"` path are resolved against the process's
/// cwd with no override flag, so a temp-dir cwd cannot see the real ones
/// unless pointed at directly — see `linkZigOut` for the wasm half).
pub fn writeMockConfig(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, port: u16) !void {
    const toml = try std.fmt.allocPrint(gpa,
        \\default_provider = "e2e-mock"
        \\
        \\[providers.e2e-mock]
        \\kind = "openai_compat"
        \\base_url = "http://127.0.0.1:{d}"
        \\default_model = "mock"
        \\
        \\[models."e2e-mock/mock"]
        \\provider = "e2e-mock"
        \\context_window = 32000
        \\max_tokens = 4096
        \\
        \\[agent]
        \\tools_dir = {f}
        \\
    , .{ port, std.json.fmt(tools_manifests_dir, .{}) });
    defer gpa.free(toml);
    try dir.writeFile(io, .{ .sub_path = "config.toml", .data = toml });
}

/// Symlinks `dir/zig-out` to the real, already-built `zig-out`, so a tool
/// descriptor's relative `"wasm": "zig-out/tools/x.wasm"` resolves from the
/// temp cwd exactly as it would from the real repo root. Isolation still
/// holds for what the sandboxed tools can see and write: only this one path
/// is shared, and it is read-only build output, not the checkout itself.
pub fn linkZigOut(io: std.Io, dir: std.Io.Dir) !void {
    try dir.symLink(io, zig_out_dir, "zig-out", .{});
}

/// Copies each record store's scaffolding — its `README.md` inventory and,
/// where the store has one, its `TEMPLATE.md` — from the real `docs/` tree
/// into `dir`, plus the two `docs/reports/` record subdirectories. The guests
/// resolve `docs/<store>/` against cwd, so this is what makes a create over
/// `/api/<store>` land in the temp dir instead of failing on missing
/// scaffolding. Copying beats writing a fixture by hand: a fixture would be a
/// second copy of the inventory format, which is exactly what the guests own.
pub fn copyRecordStores(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) !void {
    const stores = [_][]const u8{ "reports", "runbooks", "rfcs", "adrs", "prds", "research" };
    var src_root = try std.Io.Dir.cwd().openDir(io, docs_dir, .{});
    defer src_root.close(io);
    try dir.createDirPath(io, "docs");
    for (stores) |store| {
        const sub = try std.fmt.allocPrint(gpa, "docs/{s}", .{store});
        defer gpa.free(sub);
        try dir.createDirPath(io, sub);
        for ([_][]const u8{ "README.md", "TEMPLATE.md" }) |name| {
            const src = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ store, name });
            defer gpa.free(src);
            const dst = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ sub, name });
            defer gpa.free(dst);
            // docs/reports/ has no TEMPLATE.md: its records are scaffolded
            // from the kind, not from a file.
            const data = src_root.readFileAlloc(io, src, gpa, .limited(1 << 20)) catch continue;
            defer gpa.free(data);
            try dir.writeFile(io, .{ .sub_path = dst, .data = data });
        }
    }
    try dir.createDirPath(io, "docs/reports/bugs");
    try dir.createDirPath(io, "docs/reports/investigations");
}

/// Makes `dir` a minimal Git checkout with one commit. `run --worktree` cuts
/// its branch from that commit, so an e2e test must create a real repository
/// rather than merely using a temporary directory as its cwd.
pub fn initGitRepo(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    const commands = [_][]const []const u8{
        &.{ "git", "init", "-b", "main" },
        &.{ "git", "add", "config.toml" },
        &.{ "git", "-c", "user.name=e2e", "-c", "user.email=e2e@example.invalid", "commit", "-m", "initial e2e fixture" },
    };
    for (commands) |argv| {
        const result = try std.process.run(gpa, io, .{
            .argv = argv,
            .cwd = .{ .dir = dir },
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 20),
        });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) {},
            else => return error.GitFixtureSetupFailed,
        }
    }
}

/// Runs `clanker <args>` with `cwd` as its working directory (the built
/// binary's absolute path is baked in at build time via `e2e_options`, since
/// the child's cwd changes before exec and a relative argv[0] would then
/// resolve against the wrong directory). Captures stdout/stderr; the caller
/// owns both via `Run.deinit`.
pub fn run(gpa: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, args: []const []const u8) !Run {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, clanker_bin);
    try argv.appendSlice(gpa, args);

    const result = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(4 << 20),
        .stderr_limit = .limited(4 << 20),
    });
    return .{ .term = result.term, .stdout = result.stdout, .stderr = result.stderr };
}

/// A live `clanker serve` the test started. `stop` kills it.
pub const Serve = struct {
    child: std.process.Child,
    pid: std.posix.pid_t,
    webui_port: u16,
    mesh_port: u16,

    pub fn stop(self: *Serve, io: std.Io) void {
        if (self.pid != 0) {
            _ = std.posix.kill(self.pid, std.posix.SIG.KILL) catch {};
            self.pid = 0;
        }
        if (self.child.id != null) {
            _ = self.child.wait(io) catch {};
        }
    }
};

pub const MeshOpts = struct {
    id: []const u8,
    name: []const u8 = "",
    webui_port: u16,
    mesh_port: u16,
    admission: []const u8 = "open",
    mesh: bool = true,
};

/// Writes a serve-ready config: mesh on, hot reload off, no LLM needed.
pub fn writeMeshConfig(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, opts: MeshOpts) !void {
    const name = if (opts.name.len > 0) opts.name else opts.id;
    const toml = try std.fmt.allocPrint(gpa,
        \\default_provider = "e2e-mock"
        \\
        \\[providers.e2e-mock]
        \\kind = "openai_compat"
        \\base_url = "http://127.0.0.1:9"
        \\default_model = "mock"
        \\
        \\[models."e2e-mock/mock"]
        \\provider = "e2e-mock"
        \\
        \\[instance]
        \\id = {f}
        \\name = {f}
        \\
        \\[modules]
        \\mesh = {}
        \\hot_reload = false
        \\
        \\[mesh]
        \\listen_host = "127.0.0.1"
        \\listen_port = {d}
        \\admission = {f}
        \\
        \\[serve]
        \\host = "127.0.0.1"
        \\webui_port = {d}
        \\
        \\[agent]
        \\tools_dir = {f}
        \\
    , .{
        std.json.fmt(opts.id, .{}),
        std.json.fmt(name, .{}),
        opts.mesh,
        opts.mesh_port,
        std.json.fmt(opts.admission, .{}),
        opts.webui_port,
        std.json.fmt(tools_manifests_dir, .{}),
    });
    defer gpa.free(toml);
    try dir.writeFile(io, .{ .sub_path = "config.toml", .data = toml });
}

/// Sequential ports so parallel e2e tests do not steal a just-released bind.
/// Probe without SO_REUSEADDR: `clanker serve` sets reuse_address, so a
/// leftover e2e serve would otherwise share the port and 404 half the GETs.
var next_port: std.atomic.Value(u16) = .init(24000);

pub fn pickPort(io: std.Io) !u16 {
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        const port = next_port.fetchAdd(1, .monotonic);
        if (port < 24000) return error.CannotBindPort;
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch continue;
        const server = addr.listen(io, .{}) catch continue;
        server.socket.close(io);
        return port;
    }
    return error.CannotBindPort;
}

pub fn spawnServe(io: std.Io, cwd: std.Io.Dir, webui_port: u16) !Serve {
    var port_buf: [8]u8 = undefined;
    const port_s = try std.fmt.bufPrint(&port_buf, "{d}", .{webui_port});
    const argv = [_][]const u8{ clanker_bin, "serve", "--host", "127.0.0.1", "--webui-port", port_s };
    const child = try std.process.spawn(io, .{
        .argv = &argv,
        .cwd = .{ .dir = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const pid = child.id orelse return error.SpawnFailed;
    return .{ .child = child, .pid = pid, .webui_port = webui_port, .mesh_port = 0 };
}

pub fn waitTcp(io: std.Io, port: u16, timeout_ms: u64) !void {
    const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const budget = timeout_ms * std.time.ns_per_ms;
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    while (true) {
        if (addr.connect(io, .{ .mode = .stream })) |c| {
            c.close(io);
            return;
        } else |_| {}
        const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
        if (now - start > budget) return error.ServeTimeout;
        std.Io.sleep(io, .{ .nanoseconds = 40 * std.time.ns_per_ms }, .awake) catch {};
    }
}

pub fn waitHttp(io: std.Io, gpa: std.mem.Allocator, url: []const u8, timeout_ms: u64) !void {
    const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const budget = timeout_ms * std.time.ns_per_ms;
    while (true) {
        if (httpGet(io, gpa, url)) |body| {
            gpa.free(body);
            return;
        } else |_| {}
        const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
        if (now - start > budget) return error.ServeTimeout;
        std.Io.sleep(io, .{ .nanoseconds = 40 * std.time.ns_per_ms }, .awake) catch {};
    }
}

pub fn httpGet(io: std.Io, gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();
    const res = try http.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{ .user_agent = .{ .override = "clanker-e2e" } },
        .response_writer = &body.writer,
    });
    if (@intFromEnum(res.status) >= 400) {
        std.debug.print("e2e GET {s} -> {d}\n{s}\n", .{ url, @intFromEnum(res.status), body.written() });
        return error.HttpError;
    }
    return body.toOwnedSlice();
}

pub fn httpPost(io: std.Io, gpa: std.mem.Allocator, url: []const u8, payload: []const u8) ![]u8 {
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();
    const res = try http.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{
            .user_agent = .{ .override = "clanker-e2e" },
            .content_type = .{ .override = "application/json" },
        },
        .response_writer = &body.writer,
    });
    if (@intFromEnum(res.status) >= 400) {
        std.debug.print("e2e POST {s} -> {d}\n{s}\n", .{ url, @intFromEnum(res.status), body.written() });
        return error.HttpError;
    }
    return body.toOwnedSlice();
}

/// One HTTP answer with its status kept. `httpGet` / `httpPost` turn a 4xx
/// into an error, which is the right default for a journey that only cares
/// that the call worked — but a refusal *is* the assertion for an endpoint
/// whose contract is "404 for a missing record, 400 for everything else".
pub const Answer = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Answer, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }

    pub fn has(self: *const Answer, needle: []const u8) bool {
        return std.mem.find(u8, self.body, needle) != null;
    }
};

pub fn httpRequest(
    io: std.Io,
    gpa: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
) !Answer {
    var http: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http.deinit();
    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();
    const res = try http.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .headers = .{
            .user_agent = .{ .override = "clanker-e2e" },
            .content_type = .{ .override = "application/json" },
        },
        .response_writer = &body.writer,
    });
    return .{ .status = @intFromEnum(res.status), .body = try body.toOwnedSlice() };
}

/// Polls GET `url` until the body contains `needle` or the budget expires.
/// Caller owns the returned body.
pub fn waitHttpHas(io: std.Io, gpa: std.mem.Allocator, url: []const u8, needle: []const u8, timeout_ms: u64) ![]u8 {
    const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const budget = timeout_ms * std.time.ns_per_ms;
    var last: []u8 = &.{};
    while (true) {
        if (httpGet(io, gpa, url)) |body| {
            if (last.len > 0) gpa.free(last);
            last = body;
            if (std.mem.find(u8, body, needle) != null) return last;
        } else |_| {}
        const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
        if (now - start > budget) {
            if (last.len > 0) {
                std.debug.print("e2e waitHttpHas timeout {s} missing {s}\nlast: {s}\n", .{ url, needle, last });
                gpa.free(last);
            }
            return error.ServeTimeout;
        }
        std.Io.sleep(io, .{ .nanoseconds = 40 * std.time.ns_per_ms }, .awake) catch {};
    }
}

pub fn bin() []const u8 {
    return clanker_bin;
}
