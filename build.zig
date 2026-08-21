const std = @import("std");
const build_zon = @import("build.zig.zon");

// Pure-logic modules under tools/zig/ that don't export the tool ABI (run/scratch/host_arena).
// They are imported by other tools, not standalone guests, so the wasm build skips them
// and `zig build test` runs their tests on the host target instead.
const host_tested_helpers = [_][]const u8{ "advisor_logic", "agency_sync_logic", "alphaxiv_client", "arena_match", "autolearn_logic", "autoresearch_logic", "calculator_logic", "cards", "cas_lock_record", "commit_logic", "compare_logic", "compact_hint", "config_logic", "doc_scaffold", "feedback_logic", "flat_json", "gauntlet_logic", "gh_url", "goal_store", "graph_listing", "grep_outline", "hashline", "kernel_magic", "llm_budget", "log_view", "manifest_scan", "memory_embed", "mention_expand", "model_reply", "model_stats_logic", "notifications_logic", "patch_logic", "plugin_config_logic", "providers_logic", "research_queries", "rewind_logic", "run_plan_logic", "schedule_cron", "schedule_logic", "search_parse", "session_export_logic", "sessions_logic", "skills_logic", "spill_logic", "strip_xml", "symbolic_regression_logic", "thinking_logic", "webui_addon_logic", "workflows_logic", "write_goal_logic" };

/// The `tools/zig` helpers the host links directly, so the CLI and the guest
/// that shares a file run the same source rather than two copies of it.
const linked_helpers = [_][]const u8{ "skills_logic", "schedule_cron", "cas_lock_record", "commit_logic", "thinking_logic", "llm_budget", "advisor_logic", "autoresearch_logic", "providers_logic", "workflows_logic", "spill_logic", "mention_expand", "compact_hint" };

/// `base` plus one module per linked helper. Unlike the wasm guests and the
/// `host_tested_helpers` test modules below, these get no `utf8` import:
/// `src/main.zig` imports `util/utf8.zig` into `root`, and a file may belong
/// to only one module, so a helper linked here carries its own cap.
fn linkedHelperImports(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    base: []const std.Build.Module.Import,
) []const std.Build.Module.Import {
    const imports = b.allocator.alloc(std.Build.Module.Import, base.len + linked_helpers.len) catch @panic("OOM");
    @memcpy(imports[0..base.len], base);
    for (linked_helpers, imports[base.len..]) |stem, *slot| {
        slot.* = .{ .name = stem, .module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tools/zig/{s}.zig", .{stem})),
            .target = target,
            .optimize = optimize,
        }) };
    }
    return imports;
}

fn lessThanUtf8(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Keep the package version machine-checkable. Release policy and notes live
    // in RELEASES.md and CHANGELOG.md; this catches malformed SemVer before it
    // can become a binary version, user agent, package version, or tag.
    _ = std.SemanticVersion.parse(build_zon.version) catch
        @panic("build.zig.zon .version must be valid SemVer");

    // Zig 0.16 only: `minimum_zig_version` in build.zig.zon is a floor, so a
    // 0.15 or 0.17 toolchain would otherwise reach the compile and fail with a
    // wall of std-API errors. Name the requirement before the build starts.
    const zig_version = @import("builtin").zig_version;
    if (zig_version.major != 0 or zig_version.minor != 16) {
        std.debug.print(
            "clanker requires Zig 0.16.x (found {d}.{d}.{d}); build.zig.zon's minimum_zig_version pins the CI release\n",
            .{ zig_version.major, zig_version.minor, zig_version.patch },
        );
        std.process.exit(1);
    }

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
            .imports = linkedHelperImports(b, exe_target, optimize, &.{
                .{ .name = "zwasm", .module = zwasm_mod },
                .{ .name = "build_options", .module = build_options.createModule() },
                .{ .name = "vaxis", .module = vaxis_mod },
                .{ .name = "toml", .module = toml_mod },
                .{ .name = "vendor", .module = ui_vendor_mod },
            }),
        }),
    });
    b.installArtifact(exe);
    // Vendored SQLite (session event store). Host-only: WASM guests never
    // link it; the store lives behind the harness like every native surface.
    exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
        },
    });
    exe.root_module.addIncludePath(b.path("vendor/sqlite"));

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
    // Run one test instead of the whole suite: the full run (Zig + the node
    // --test suites) is minutes, so a contributor iterating on one `test`
    // block needs a tight loop. The filter is a substring match applied at
    // compile time (Zig 0.16's `zig test --test-filter`), so the test binary
    // only registers matching tests. The node --test suites still run; for a
    // JS-only loop run `node --test <file>` directly.
    const test_filter = b.option([]const u8, "test-filter", "run only Zig unit tests whose name contains this substring (a filter matching nothing passes with 0 tests)") orelse "";
    const test_filters: []const []const u8 = if (test_filter.len > 0) &.{test_filter} else &.{};
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
        .imports = linkedHelperImports(b, test_target, optimize, &.{
            .{ .name = "zwasm", .module = zwasm_mod },
            .{ .name = "build_options", .module = build_options.createModule() },
            .{ .name = "vaxis", .module = vaxis_test_dep.module("vaxis") },
            .{ .name = "toml", .module = toml_test_mod },
            .{ .name = "vendor", .module = ui_vendor_test_mod },
        }),
    });
    // The committed config.toml, for the config.zig test that checks it still
    // documents every key the loader accepts. Test-only on purpose: the
    // running binary has no use for the file's text, and embedding it in the
    // exe to serve one test would ship it to every user.
    test_mod.addAnonymousImport("config_toml", .{ .root_source_file = b.path("config.toml") });

    // The session event store's host tests need SQLite in the test binary too.
    test_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
        },
    });
    test_mod.addIncludePath(b.path("vendor/sqlite"));

    const exe_tests = b.addTest(.{ .root_module = test_mod, .use_llvm = true, .filters = test_filters });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    // Chat scroll math lives in the shipped ESM helper; node --test drives
    // that file, not a Zig reimplementation.
    const scroll_js_test = b.addSystemCommand(&.{ "node", "--test" });
    scroll_js_test.addFileArg(b.path("ui/app/core/scroll.test.mjs"));
    test_step.dependOn(&scroll_js_test.step);
    // The critical-path preloads and the lazy-view failure path are contracts
    // of the served HTML/JS; pin them against the embedded files.
    const webui_load_js_test = b.addSystemCommand(&.{ "node", "--test" });
    webui_load_js_test.addFileArg(b.path("ui/app/webui-load.test.mjs"));
    test_step.dependOn(&webui_load_js_test.step);
    // The app.css/views.css split is a first-paint contract: nothing in the
    // deferred sheet may style an element the first draw shows.
    const css_split_js_test = b.addSystemCommand(&.{ "node", "--test" });
    css_split_js_test.addFileArg(b.path("ui/app/css-split.test.mjs"));
    test_step.dependOn(&css_split_js_test.step);
    // Radii and type steps are tokens, not literals: a stray `border-radius:
    // 12px` reads as no bug at all, so nothing catches the sheet drifting back
    // toward the rounded-card default one declaration at a time.
    const design_tokens_js_test = b.addSystemCommand(&.{ "node", "--test" });
    design_tokens_js_test.addFileArg(b.path("ui/app/design-tokens.test.mjs"));
    test_step.dependOn(&design_tokens_js_test.step);
    // What a visitor actually downloads, and what it is allowed to grow to.
    // These numbers are the regression record for the critical path.
    const weight_budget_js_test = b.addSystemCommand(&.{ "node", "--test" });
    weight_budget_js_test.addFileArg(b.path("ui/app/weight-budget.test.mjs"));
    test_step.dependOn(&weight_budget_js_test.step);
    // Operator vs Chat column widths live in the shipped stylesheet.
    const layout_js_test = b.addSystemCommand(&.{ "node", "--test" });
    layout_js_test.addFileArg(b.path("ui/app/core/layout.test.mjs"));
    test_step.dependOn(&layout_js_test.step);
    const markdown_js_test = b.addSystemCommand(&.{ "node", "--test" });
    markdown_js_test.addFileArg(b.path("ui/app/lib/markdown.test.mjs"));
    test_step.dependOn(&markdown_js_test.step);
    // The Runs list derives a date and a state from a summary that carries
    // neither directly; its clock has to agree with graph_listing.runOrderKey.
    const runs_list_js_test = b.addSystemCommand(&.{ "node", "--test" });
    runs_list_js_test.addFileArg(b.path("ui/app/lib/runs-list.test.mjs"));
    test_step.dependOn(&runs_list_js_test.step);
    // The Activity timeline merges two feeds that are each incomplete alone.
    const board_js_test = b.addSystemCommand(&.{ "node", "--test" });
    board_js_test.addFileArg(b.path("ui/app/lib/board.test.mjs"));
    test_step.dependOn(&board_js_test.step);
    const labels_js_test = b.addSystemCommand(&.{ "node", "--test" });
    labels_js_test.addFileArg(b.path("ui/app/core/labels.test.mjs"));
    test_step.dependOn(&labels_js_test.step);
    // The provider-availability contract: rows marked usable:false stay
    // listed as inventory but never reach the chat picker's set.
    const utils_js_test = b.addSystemCommand(&.{ "node", "--test" });
    utils_js_test.addFileArg(b.path("ui/app/core/utils.test.mjs"));
    test_step.dependOn(&utils_js_test.step);
    // Every Refresh button in the page reaches a handler that gives busy
    // feedback: three shipped with no listener at all.
    const refresh_js_test = b.addSystemCommand(&.{ "node", "--test" });
    refresh_js_test.addFileArg(b.path("ui/app/core/refresh.test.mjs"));
    test_step.dependOn(&refresh_js_test.step);
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
    // Settings fields are typed by the descriptor's declared config_types,
    // not by typeof on whatever value happens to be saved.
    const tools_js_test = b.addSystemCommand(&.{ "node", "--test" });
    tools_js_test.addFileArg(b.path("ui/app/core/tools.test.mjs"));
    test_step.dependOn(&tools_js_test.step);
    const compare_js_test = b.addSystemCommand(&.{ "node", "--test" });
    compare_js_test.addFileArg(b.path("ui/plugins/compare/compare.test.mjs"));
    test_step.dependOn(&compare_js_test.step);
    const search_js_test = b.addSystemCommand(&.{ "node", "--test" });
    search_js_test.addFileArg(b.path("ui/plugins/search/search.test.mjs"));
    test_step.dependOn(&search_js_test.step);
    const mesh_js_test = b.addSystemCommand(&.{ "node", "--test" });
    mesh_js_test.addFileArg(b.path("ui/plugins/mesh/mesh.test.mjs"));
    test_step.dependOn(&mesh_js_test.step);
    const arena_js_test = b.addSystemCommand(&.{ "node", "--test" });
    arena_js_test.addFileArg(b.path("ui/app/features/arena.test.mjs"));
    test_step.dependOn(&arena_js_test.step);
    // The Skills panel renders its cards into the container; the shipped
    // loadSkills is driven over the DOM stub.
    const skills_js_test = b.addSystemCommand(&.{ "node", "--test" });
    skills_js_test.addFileArg(b.path("ui/app/core/skills.test.mjs"));
    test_step.dependOn(&skills_js_test.step);
    // The chat composer's steering ledger: what was sent mid-run, in what
    // order, and what the run never consumed.
    const steer_js_test = b.addSystemCommand(&.{ "node", "--test" });
    steer_js_test.addFileArg(b.path("ui/app/core/steer.test.mjs"));
    test_step.dependOn(&steer_js_test.step);

    // Logic that lives in a tool rather than in src/ still needs its tests run.
    // `zig build test` compiled only src/main.zig, so every `test` block under
    // tools/zig/ was dead: it built for wasm32-freestanding, where nothing runs
    // it, and no host target ever saw it. Only tools that import nothing from
    // the guest ABI can be tested this way — a module pulling in lib.zig
    // declares `extern "env"` functions the host test binary cannot link — so
    // the pure ones are listed rather than globbed, which is also what keeps
    // "is this testable" an explicit property of a file.
    const helper_utf8_mod = b.createModule(.{
        .root_source_file = b.path("src/util/utf8.zig"),
        .target = test_target,
        .optimize = optimize,
    });
    for (host_tested_helpers) |stem| {
        const mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("tools/zig/{s}.zig", .{stem})),
            .target = test_target,
            .optimize = optimize,
            .imports = &.{
                // The same `utf8` import the wasm guests get, so a helper that
                // caps text on a codepoint boundary reaches the one shared
                // helper instead of carrying a second copy of the loop.
                .{ .name = "utf8", .module = helper_utf8_mod },
            },
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod, .filters = test_filters })).step);
    }
    // The sandbox tests load zig-out/tools/*.wasm, which is build output and
    // therefore absent from a fresh checkout: `zig build test` failed there
    // with FileNotFound on a tool nobody had built yet. The improvement engine
    // already runs the tools gate before the test gate for this reason; the
    // dependency belongs here so the same holds for anyone typing the command
    // by hand. Declared after tools_step exists, further down.

    // -------------------------------------------------------------- fmt gate
    // `zig build fmt`: format-check the checkout without the agent loop or an
    // API key. Uses the interpreter running this build (b.graph.zig_exe), so
    // no PATH lookup and no version drift.
    const fmt_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "--check" });
    const fmt_step = b.step("fmt", "Format-check all Zig source");
    fmt_step.dependOn(&fmt_cmd.step);

    // `zig build fmt-fix`: auto-format the checkout (the mutating sibling of
    // the check above). Runs zig fmt without --check, rewriting any file that
    // deviates from canonical formatting.
    const fmt_fix_cmd = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt" });
    const fmt_fix_step = b.step("fmt-fix", "Auto-format all Zig source");
    fmt_fix_step.dependOn(&fmt_fix_cmd.step);

    // `zig build quick-check`: format-check + compile in parallel — the
    // fastest possible signal that a proposed patch is syntactically valid and
    // builds. The improve loop uses this before committing to full test-suite
    // compilation, so a syntax error costs seconds rather than minutes per
    // wasted iteration.
    const quick_check_step = b.step("quick-check", "Fast fmt+compile check (no tests)");
    quick_check_step.dependOn(&fmt_cmd.step);
    quick_check_step.dependOn(b.getInstallStep());

    // ------------------------------------------------------- wasm tool builds
    // `zig build tools` compiles every guest tool under tools/zig/ (lib.zig
    // and the host-tested helpers listed above are skipped) into a
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
    // The gh and git guests mirror the host's exec_pattern_allow decision, so
    // they match with the host's own glob rather than a second copy of it.
    const tool_glob_mod = b.createModule(.{
        .root_source_file = b.path("src/util/glob.zig"),
        .target = tool_target,
        .optimize = .ReleaseSmall,
    });
    // The list_files guest walks the same tree ck_fs_find does, so it skips the
    // same cache and vendor directories from the host's table, not a copy.
    const tool_fs_skip_mod = b.createModule(.{
        .root_source_file = b.path("src/util/fs_skip.zig"),
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
        // Shared guest libraries, imported by other guests rather than shipped
        // as tools of their own: lib.zig is the ABI half every guest imports;
        // records_grep.zig is pulled into the five record-store guests by
        // relative path and has no descriptor, so neither gets a standalone
        // wasm built here.
        if (std.mem.eql(u8, entry.name, "lib.zig")) continue;
        if (std.mem.eql(u8, entry.name, "records_grep.zig")) continue;
        const stem = entry.name[0 .. entry.name.len - 4];
        const is_helper = for (host_tested_helpers) |h| {
            if (std.mem.eql(u8, stem, h)) break true;
        } else false;
        if (is_helper) continue;
        names.append(b.allocator, b.dupe(stem)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, names.items, {}, lessThanUtf8);

    for (names.items) |stem| {
        const tool = b.addExecutable(.{
            .name = stem,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tools/zig/{s}.zig", .{stem})),
                .target = tool_target,
                .optimize = .ReleaseSmall,
                .imports = &.{
                    .{ .name = "utf8", .module = tool_utf8_mod },
                    .{ .name = "glob", .module = tool_glob_mod },
                    .{ .name = "fs_skip", .module = tool_fs_skip_mod },
                },
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
        std.mem.sort([]const u8, lang_names.items, {}, lessThanUtf8);

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
    // A record store scaffolds new records from its own README.md inventory
    // and TEMPLATE.md, so an /api/<store> journey needs those files in the
    // temp cwd. The harness copies them out of the real docs/ tree rather
    // than hand-rolling a second set that would drift from the guests.
    e2e_options.addOption([]const u8, "docs_dir", b.pathFromRoot("docs"));
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
