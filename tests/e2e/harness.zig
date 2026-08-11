//! Spawns the real, already-built `clanker` binary as a subprocess against a
//! temp working directory and a scripted mock LLM server (mock_llm.zig), so a
//! test can drive the actual CLI -> Agent.run -> LLM client -> sandboxed WASM
//! tool path end to end, with no real API key and no network egress.

const std = @import("std");
const clanker_bin = @import("e2e_options").clanker_bin;

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

/// Writes a minimal single-provider config.json into `dir`, pointed at a mock
/// server on 127.0.0.1:`port`. No `api_key_env`: the field is optional
/// (`config.zig` accepts a provider with none, e.g. a local Ollama-style
/// entry), and the mock server never checks auth, so there is nothing to
/// fake a credential for.
pub fn writeMockConfig(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, port: u16) !void {
    const json = try std.fmt.allocPrint(gpa,
        \\{{
        \\  "default_provider": "e2e-mock",
        \\  "providers": {{
        \\    "e2e-mock": {{
        \\      "kind": "openai_compat",
        \\      "base_url": "http://127.0.0.1:{d}",
        \\      "default_model": "mock",
        \\      "models": {{ "mock": {{ "context_window": 32000, "max_tokens": 4096 }} }}
        \\    }}
        \\  }}
        \\}}
        \\
    , .{port});
    defer gpa.free(json);
    try dir.writeFile(io, .{ .sub_path = "config.json", .data = json });
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
