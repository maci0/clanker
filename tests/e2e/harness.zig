//! Spawns the real, already-built `clanker` binary as a subprocess against a
//! temp working directory and a scripted mock LLM server (mock_llm.zig), so a
//! test can drive the actual CLI -> Agent.run -> LLM client -> sandboxed WASM
//! tool path end to end, with no real API key and no network egress.

const std = @import("std");
const e2e_options = @import("e2e_options");
const clanker_bin = e2e_options.clanker_bin;
const zig_out_dir = e2e_options.zig_out_dir;
const tools_manifests_dir = e2e_options.tools_manifests_dir;

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
