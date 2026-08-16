const std = @import("std");
const build_zon = @import("build.zig.zon");

// Pure-logic modules under tools/zig/ that don't export the tool ABI (run/scratch/host_arena).
// They are imported by other tools, not standalone guests, so the wasm build skips them
// and `zig build test` runs their tests on the host target instead.
const host_tested_helpers = [_][]const u8{ "advisor_logic", "alphaxiv_client", "arena_match", "autolearn_logic", "cards", "commit_logic", "compare_logic", "doc_scaffold", "feedback_logic", "flat_json", "gh_url", "goal_store", "graph_listing", "hashline", "kernel_magic", "log_view", "manifest_scan", "memory_embed", "patch_logic", "providers_logic", "research_queries", "run_plan_logic", "schedule_cron", "schedule_logic", "search_parse", "session_export_logic", "sessions_logic", "skills_logic", "spill_logic", "strip_xml", "thinking_logic", "webui_addon_logic" };

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Keep the package version machine-checkable. Release policy and notes live
    // in RELEASES.md and CHANGELOG.md; this catches malformed SemVer before it
    // can become a binary version, user agent, package version, or tag.
    _ = std.SemanticVersion.parse(build_zon.version) catch
        @panic("build.zig.zon .version must be valid SemVer");

    // Single source of truth for the version clanker reports (`--version`,
    // the `clanker/<version>` user agent): build.zig.zon's `.version` field,
    // piped through as a build option so it can never drift from a
    // hand-copied literal.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", build_zon.version);
    // The zig the gates shell out to. `zig fmt` and `zig ast-check` run with
    // `cwd` set to a staging or temp directory, so a bare "zig" is resolved
    // against a PATH the spawn does not reliably see; the interpreter running
    // this build is both the right version and an absolute path. Release
    // builds omit it: the path is host-specific, useless on any other machine,
    // and would make otherwise identical release artifacts byte-different.
    const zig_exe_for_options: []const u8 = if (optimize == .Debug) b.graph.zig_exe else "";
    build_options.addOption([]const u8, "zig_exe", zig_exe_for_options);

    // The host, with one adjustment: zwasm links libc, and on a glibc host the
    // crt1.o carries SFrame relocations this lld cannot resolve, so linux
    // builds against Zig's bundled musl instead. Shared by the harness and the
    // tests — they want the same thing, and drift between them is what made
    // `zig build test` unrunnable off x86_64-linux once before.
    const host = b.graph.host.result;
    const native_query: std.Target.Query = if (host.os.tag == .linux)
        .{ .cpu_arch = host.cpu.arch, .os_tag = .linux, .abi = .musl }
    else
        .{};

    // The harness defaults to the machine building it. This was a hard
    // x86_64-linux-musl pin, so every other host produced a binary it could
    // not execute — `./zig-out/bin/clanker` died with an exec format error on
    // an arm64 mac. `-Dtarget=` still cross-compiles for release builds.
    const exe_target = b.standardTargetOptions(.{ .default_target = native_query });

    // zwasm: pure-Zig WebAssembly runtime used for the tool sandbox.
    // target/optimize passed through: without them the module compiled at
    // zwasm's own default (Debug), so even a ReleaseSafe clanker ran every
    // tool on a Debug interpreter.
    const zwasm_dep = b.dependency("zwasm", .{ .target = exe_target, .optimize = optimize });
    const zwasm_mod = zwasm_dep.module("zwasm");

    // vaxis: native-tty TUI library (Phase 1 of the libvaxis migration,
    // see docs/ROADMAP.md). Declares its own standardTargetOptions, so
    // target/optimize must be passed explicitly or its module resolves
    // against its own defaults instead of ours. Native-only — irrelevant
    // to the wasm32-freestanding tool build below.
    const vaxis_dep = b.dependency("vaxis", .{ .target = exe_target, .optimize = optimize });
    const vaxis_mod = vaxis_dep.module("vaxis");

    // toml: parses config.toml/config.local.toml. Vendored
    // (vendor/toml), not fetched — see vendor/toml/README.md.
    const toml_mod = b.createModule(.{
        .root_source_file = b.path("vendor/toml/src/root.zig"),
        .target = exe_target,
        .optimize = optimize,
    });

    // ui/vendor.zig: embeds ui/vendor/* (vendored third-party JS served by the
    // host HTTP server). Separate module so @embedFile resolves within ui/.
    const ui_vendor_mod = b.createModule(.{
        .root_source_file = b.path("ui/vendor.zig"),
        .target = exe_target,
        .optimize = optimize,
    });

    // ---------------------------------------------------------------- harness
    const exe = b.addExecutable(.{
        .name = "clanker",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = exe_target,
            .optimize = optimize,
            // Debug info embeds the absolute checkout path (DWARF comp-dir
            // and per-file paths), so two clean builds of the same source
            // from differently-named directories produce byte-different
            // Debug binaries. Debug builds keep symbols and embed
            // build_options.zig_exe for local gate runs; release builds strip
            // symbols and omit zig_exe so shipped artifacts do not encode the
            // build host.
            .strip = optimize != .Debug,
            .imports = &.{
                .{ .name = "zwasm", .module = zwasm_mod },
                .{ .name = "build_options", .module = build_options.createModule() },
                .{ .name = "vaxis", .module = vaxis_mod },
                .{ .name = "toml", .module = toml_mod },
                .{ .name = "vendor", .module = ui_vendor_mod },
                .{ .name = "skills_logic", .module = b.createModule(.{
                    .root_source_file = b.path("tools/zig/skills_logic.zig"),
                    .target = exe_target,
                    .optimize = optimize,
                }) },
                .{ .name = "schedule_cron", .module = b.createModule(.{
                    .root_source_file = b.path("tools/zig/schedule_cron.zig"),
                    .target = exe_target,
                    .optimize = optimize,
                }) },
                .{ .name = "thinking_logic", .module = b.createModule(.{
                    .root_source_file = b.path("tools/zig/thinking_logic.zig"),
                    .target = exe_target,
                    .optimize = optimize,
                }) },
                .{ .name = "advisor_logic", .module = b.createModule(.{
                    .root_source_file = b.path("tools/zig/advisor_logic.zig"),
                    .target = exe_target,
                    .optimize = optimize,
                }) },
                .{ .name = "providers_logic", .module = b.createModule(.{
                    .root_source_file = b.path("tools/zig/providers_logic.zig"),
                    .target = exe_target,
                    .optimize = optimize,
                }) },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run clanker");
    run_step.dependOn(&run_cmd.step);

    // ------------------------------------------------------------------ proxy
    // `zig build proxy`: clanker-proxy, the compatibility proxy alone — no web
    // UI, agent, TUI, or tool host, so none of the vaxis/zwasm/vendor deps.
    // Not part of the default install; built only when asked for.
    const proxy_exe = b.addExecutable(.{
        .name = "clanker-proxy",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/proxy_main.zig"),
            .target = exe_target,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "build_options", .module = build_options.createModule() },
                .{ .name = "toml", .module = toml_mod },
            },
        }),
    });
    const proxy_step = b.step("proxy", "Build clanker-proxy (standalone compatibility proxy)");
    proxy_step.dependOn(&b.addInstallArtifact(proxy_exe, .{}).step);

    // ------------------------------------------------------------------ tests
    // Tests run on the host's own architecture, so `zig build test` works on any
    // dev machine rather than only an x86_64 linux one. Deliberately not
    // `exe_target`: a `-Dtarget=` cross-compile would produce a test binary the
    // build runner cannot execute.
    const test_target = b.resolveTargetQuery(native_query);
    const vaxis_test_dep = b.dependency("vaxis", .{ .target = test_target, .optimize = optimize });
    const toml_test_mod = b.createModule(.{
        .root_source_file = b.path("vendor/toml/src/root.zig"),
        .target = test_target,
        .optimize = optimize,
    });
    const ui_vendor_test_mod = b.createModule(.{
        .root_source_file = b.path("ui/vendor.zig"),
        .target = test_target,
        .optimize = optimize,
    });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = test_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zwasm", .module = zwasm_mod },
            .{ .name = "build_options", .module = build_options.createModule() },
            .{ .name = "vaxis", .module = vaxis_test_dep.module("vaxis") },
            .{ .name = "toml", .module = toml_test_mod },
            .{ .name = "vendor", .module = ui_vendor_test_mod },
            .{ .name = "skills_logic", .module = b.createModule(.{
                .root_source_file = b.path("tools/zig/skills_logic.zig"),
                .target = test_target,
                .optimize = optimize,
            }) },
            .{ .name = "schedule_cron", .module = b.createModule(.{
                .root_source_file = b.path("tools/zig/schedule_cron.zig"),
                .target = test_target,
                .optimize = optimize,
            }) },
            .{ .name = "thinking_logic", .module = b.createModule(.{
                .root_source_file = b.path("tools/zig/thinking_logic.zig"),
                .target = test_target,
                .optimize = optimize,
            }) },
            .{ .name = "advisor_logic", .module = b.createModule(.{
                .root_source_file = b.path("tools/zig/advisor_logic.zig"),
                .target = test_target,
                .optimize = optimize,
            }) },
            .{ .name = "providers_logic", .module = b.createModule(.{
                .root_source_file = b.path("tools/zig/providers_logic.zig"),
                .target = test_target,
                .optimize = optimize,
            }) },
        },
    });
    // The committed config.toml, for the config.zig test that checks it still
    // documents every key the loader accepts. Test-only on purpose: the
    // running binary has no use for the file's text, and embedding it in the
    // exe to serve one test would ship it to every user.
    test_mod.addAnonymousImport("config_toml", .{ .root_source_file = b.path("config.toml") });

    const exe_tests = b.addTest(.{ .root_module = test_mod, .use_llvm = true });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    // Chat scroll math lives in the shipped ESM helper; node --test drives
    // that file, not a Zig reimplementation.
    const scroll_js_test = b.addSystemCommand(&.{ "node", "--test" });
    scroll_js_test.addFileArg(b.path("ui/app/core/scroll.test.mjs"));
    test_step.dependOn(&scroll_js_test.step);
    // Operator vs Chat column widths live in the shipped stylesheet.
    const layout_js_test = b.addSystemCommand(&.{ "node", "--test" });
    layout_js_test.addFileArg(b.path("ui/app/core/layout.test.mjs"));
    test_step.dependOn(&layout_js_test.step);
    const markdown_js_test = b.addSystemCommand(&.{ "node", "--test" });
    markdown_js_test.addFileArg(b.path("ui/app/lib/markdown.test.mjs"));
    test_step.dependOn(&markdown_js_test.step);
    const labels_js_test = b.addSystemCommand(&.{ "node", "--test" });
    labels_js_test.addFileArg(b.path("ui/app/core/labels.test.mjs"));
    test_step.dependOn(&labels_js_test.step);
    const files_js_test = b.addSystemCommand(&.{ "node", "--test" });
    files_js_test.addFileArg(b.path("ui/plugins/files/files.test.mjs"));
    test_step.dependOn(&files_js_test.step);
    const music_js_test = b.addSystemCommand(&.{ "node", "--test" });
    music_js_test.addFileArg(b.path("ui/plugins/music/music.test.mjs"));
    test_step.dependOn(&music_js_test.step);
    const harden_js_test = b.addSystemCommand(&.{ "node", "--test" });
    harden_js_test.addFileArg(b.path("ui/app/core/harden.test.mjs"));
    test_step.dependOn(&harden_js_test.step);
    const theme_js_test = b.addSystemCommand(&.{ "node", "--test" });
    theme_js_test.addFileArg(b.path("ui/app/core/theme.test.mjs"));
    test_step.dependOn(&theme_js_test.step);
    const slash_js_test = b.addSystemCommand(&.{ "node", "--test" });
    slash_js_test.addFileArg(b.path("ui/app/core/slash.test.mjs"));
    test_step.dependOn(&slash_js_test.step);
    const distill_js_test = b.addSystemCommand(&.{ "node", "--test" });
    distill_js_test.addFileArg(b.path("ui/app/core/distill.test.mjs"));
    test_step.dependOn(&distill_js_test.step);
    const run_metrics_js_test = b.addSystemCommand(&.{ "node", "--test" });
    run_metrics_js_test.addFileArg(b.path("ui/app/core/run-metrics.test.mjs"));
    test_step.dependOn(&run_metrics_js_test.step);
    const models_js_test = b.addSystemCommand(&.{ "node", "--test" });
    models_js_test.addFileArg(b.path("ui/app/features/models.test.mjs"));
    test_step.dependOn(&models_js_test.step);
    const compare_js_test = b.addSystemCommand(&.{ "node", "--test" });
    compare_js_test.addFileArg(b.path("ui/plugins/compare/compare.test.mjs"));
    test_step.dependOn(&compare_js_test.step);
    const search_js_test = b.addSystemCommand(&.{ "node", "--test" });
    search_js_test.addFileArg(b.path("ui/plugins/search/search.test.mjs"));
    test_step.dependOn(&search_js_test.step);
    const arena_js_test = b.addSystemCommand(&.{ "node", "--test" });
    arena_js_test.addFileArg(b.path("ui/app/features/arena.test.mjs"));
    test_step.dependOn(&arena_js_test.step);

    // Logic that lives in a tool rather than in src/ still needs its tests run.
    // `zig build test` compiled only src/main.zig, so every `test` block under
    // tools/zig/ was dead: it built for wasm32-freestanding, where nothing runs
    // it, and no host target ever saw it. Only tools that import nothing from
    // the guest ABI can be tested this way — a module pulling in lib.zig
    // declares `extern "env"` functions the host test binary cannot link — so
    // the pure ones are listed rather than globbed, which is also what keeps
    // "is this testable" an explicit property of a file.
    for (host_tested_helpers) |stem| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("tools/zig/{s}.zig", .{stem})),
            .target = test_target,
            .optimize = optimize,
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }
    // The sandbox tests load zig-out/tools/*.wasm, which is build output and
    // therefore absent from a fresh checkout: `zig build test` failed there
    // with FileNotFound on a tool nobody had built yet. The improvement engine
    // already runs the tools gate before the test gate for this reason; the
    // dependency belongs here so the same holds for anyone typing the command
    // by hand. Declared after tools_step exists, further down.

    // ------------------------------------------------------- wasm tool builds
    // `zig build tools` compiles every tools/zig/<name>.zig into a
    // wasm32-freestanding module installed at zig-out/tools/<name>.wasm.
    const tools_step = b.step("tools", "Compile tools/zig/*.zig into zig-out/tools/*.wasm");
    const tool_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const tool_utf8_mod = b.createModule(.{
        .root_source_file = b.path("src/util/utf8.zig"),
        .target = tool_target,
        .optimize = .ReleaseSmall,
    });

    var threaded = std.Io.Threaded.init(b.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const tools_src_path = b.pathFromRoot("tools/zig");
    var dir = std.Io.Dir.openDirAbsolute(io, tools_src_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("cannot open {s}: {s}", .{ tools_src_path, @errorName(err) });
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "lib.zig")) continue; // shared guest library
        const stem = entry.name[0 .. entry.name.len - 4];
        const is_helper = for (host_tested_helpers) |h| {
            if (std.mem.eql(u8, stem, h)) break true;
        } else false;
        if (is_helper) continue;
        names.append(b.allocator, b.dupe(stem)) catch @panic("OOM");
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
                .imports = &.{.{ .name = "utf8", .module = tool_utf8_mod }},
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

    // ui/webui.zig: internal WASM guest that serves the web UI. Not in
    // tools/zig/ (web UI is not an LLM-callable tool), so added explicitly.
    // Imports tools/zig/lib.zig as "lib.zig" to match @import("lib.zig").
    {
        const lib_mod = b.createModule(.{
            .root_source_file = b.path("tools/zig/lib.zig"),
            .target = tool_target,
            .optimize = .ReleaseSmall,
        });
        const webui_mod = b.createModule(.{
            .root_source_file = b.path("ui/webui.zig"),
            .target = tool_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "lib.zig", .module = lib_mod },
            },
        });
        const webui_tool = b.addExecutable(.{
            .name = "webui",
            .root_module = webui_mod,
        });
        webui_tool.entry = .disabled;
        webui_tool.rdynamic = true;
        const webui_install = b.addInstallArtifact(webui_tool, .{
            .dest_dir = .{ .override = .{ .custom = "ui" } },
            .dest_sub_path = "app.wasm",
        });
        tools_step.dependOn(&webui_install.step);
    }

    // C and C++ tools (tools/c/*.c, tools/cpp/*.cpp) compile through Zig's
    // bundled clang into the same wasm32-freestanding target as the Zig
    // tools above — no separate toolchain to be missing on a checkout that
    // can already run `zig build`, unlike the AssemblyScript tools' node
    // dependency. A tool shares tools/c/ck.h by #include, not a
    // build.zig.zon dependency, so nothing here needs a package entry.
    const c_langs = [_]struct { dir: []const u8, ext: []const u8, flags: []const []const u8 }{
        .{ .dir = "tools/c", .ext = ".c", .flags = &.{"-std=c17"} },
        .{ .dir = "tools/cpp", .ext = ".cpp", .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" } },
    };
    for (c_langs) |lang| {
        const lang_src_path = b.pathFromRoot(lang.dir);
        var lang_dir = std.Io.Dir.openDirAbsolute(io, lang_src_path, .{ .iterate = true }) catch |err| {
            std.debug.panic("cannot open {s}: {s}", .{ lang_src_path, @errorName(err) });
        };
        defer lang_dir.close(io);

        var lang_names: std.ArrayList([]const u8) = .empty;
        var lang_it = lang_dir.iterate();
        while (lang_it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, lang.ext)) continue;
            lang_names.append(b.allocator, b.dupe(entry.name[0 .. entry.name.len - lang.ext.len])) catch @panic("OOM");
        }
        std.mem.sort([]const u8, lang_names.items, {}, struct {
            fn lt(_: void, a: []const u8, bb: []const u8) bool {
                return std.mem.lessThan(u8, a, bb);
            }
        }.lt);

        for (lang_names.items) |stem| {
            const tool = b.addExecutable(.{
                .name = stem,
                .root_module = b.createModule(.{
                    .target = tool_target,
                    .optimize = .ReleaseSmall,
                }),
            });
            tool.root_module.addCSourceFile(.{
                .file = b.path(b.fmt("{s}/{s}{s}", .{ lang.dir, stem, lang.ext })),
                .flags = lang.flags,
            });
            tool.entry = .disabled;
            tool.rdynamic = true;
            const install = b.addInstallArtifact(tool, .{
                .dest_dir = .{ .override = .{ .custom = "tools" } },
            });
            tools_step.dependOn(&install.step);
        }
    }

    // Every tool is built before any test runs, for the reason given where the
    // test step is declared.
    run_tests.step.dependOn(tools_step);
    // The pty-driven `tui-test` step (src/tui/testing/) drove the old
    // hand-rolled REPL (src/tui/*) over a real pty; removed with it when
    // the REPL migrated to libvaxis (src/tui/repl.zig).

    // -------------------------------------------------------------- e2e tests
    // Black-box tests (tests/e2e/) that spawn the actual built `clanker`
    // binary as a subprocess against a scripted local mock LLM server
    // (tests/e2e/mock_llm.zig), proving CLI -> Agent.run -> LLM client ->
    // sandboxed WASM tool execution end to end with no API key and no
    // network egress. Separate from `zig build test`: it needs the exe
    // actually installed first (unlike any unit test) and spawns real
    // subprocesses, so it belongs behind its own, slower step.
    const e2e_options = b.addOptions();
    e2e_options.addOption([]const u8, "clanker_bin", b.pathFromRoot("zig-out/bin/clanker"));
    // The spawned clanker's cwd is an isolated temp dir (so a test's file
    // effects never touch the real checkout), but tool descriptors ("wasm":
    // "zig-out/tools/x.wasm") and Config.load's tools_dir are both resolved
    // relative to cwd with no override flag — so the harness symlinks the
    // real zig-out into the temp dir and points tools_dir at the real
    // manifests directory absolutely, rather than duplicating either.
    e2e_options.addOption([]const u8, "zig_out_dir", b.pathFromRoot("zig-out"));
    e2e_options.addOption([]const u8, "tools_manifests_dir", b.pathFromRoot("tools/manifests"));
    const raw_http_mod = b.createModule(.{
        .root_source_file = b.path("src/util/raw_http.zig"),
        .target = test_target,
        .optimize = optimize,
        .link_libc = true,
    });
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("tests/e2e/main.zig"),
        .target = test_target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "e2e_options", .module = e2e_options.createModule() },
            .{ .name = "raw_http", .module = raw_http_mod },
        },
    });
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    const run_e2e = b.addRunArtifact(e2e_tests);
    run_e2e.step.dependOn(b.getInstallStep());
    run_e2e.step.dependOn(tools_step);
    const e2e_step = b.step("e2e", "Run black-box e2e tests against the built clanker binary + a mock LLM server");
    e2e_step.dependOn(&run_e2e.step);
}
