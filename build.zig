const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // zwasm links libc; the host glibc's crt1.o emits .sframe sections that
    // this lld cannot relocate, so the native harness targets Zig's bundled
    // musl libc instead.
    const exe_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });

    // zwasm: pure-Zig WebAssembly runtime used for the tool sandbox.
    const zwasm_dep = b.dependency("zwasm", .{});
    const zwasm_mod = zwasm_dep.module("zwasm");

    // ---------------------------------------------------------------- harness
    const exe = b.addExecutable(.{
        .name = "clanker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = exe_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zwasm", .module = zwasm_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run clanker");
    run_step.dependOn(&run_cmd.step);

    // ------------------------------------------------------------------ tests
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // ------------------------------------------------------- wasm tool builds
    // `zig build tools` compiles every tools/zig/<name>.zig into a
    // wasm32-freestanding module installed at zig-out/tools/<name>.wasm.
    const tools_step = b.step("tools", "Compile tools/zig/*.zig into zig-out/tools/*.wasm");
    const tool_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    var threaded = std.Io.Threaded.init(b.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const tools_src_path = b.pathFromRoot("tools/zig");
    var dir = std.Io.Dir.openDirAbsolute(io, tools_src_path, .{ .iterate = true }) catch |err| {
        std.debug.print("warning: cannot open {s}: {s}\n", .{ tools_src_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "lib.zig")) continue; // shared guest library
        names.append(b.allocator, b.dupe(entry.name[0 .. entry.name.len - 4])) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, bb: []const u8) bool {
            return std.mem.lessThan(u8, a, bb);
        }
    }.lt);

    for (names.items) |stem| {
        const tool = b.addExecutable(.{
            .name = stem,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tools/zig/{s}.zig", .{stem})),
                .target = tool_target,
                .optimize = .ReleaseSmall,
            }),
        });
        tool.entry = .disabled;
        // Zig does not pass `export fn` names to wasm-ld when the entry point is
        // disabled, so the functions get gc'd out of the export section.
        // -rdynamic exports every exported symbol — the tool ABI depends on it.
        tool.rdynamic = true;
        const install = b.addInstallArtifact(tool, .{
            .dest_dir = .{ .override = .{ .custom = "tools" } },
        });
        tools_step.dependOn(&install.step);
    }
}
