//! Static web UI asset plumbing for `clanker serve`: which paths the embedded
//! bundle owns, which cache slot each one gets, and the process-lifetime render
//! and gzip caches in front of them.
//!
//! This is the serve layer's, not the CLI's. `cli.zig` still owns the routes
//! and the wasm render call (both need config, the registry and the sandbox);
//! everything here is pure and depends on nothing but `std`, which is why it
//! can be unit-tested without standing a server up.

const std = @import("std");

/// One cache kind per first-party webui file. `.js` is only `/webui/app.js`:
/// any other path that lands there serves app.js at the wrong URL, and the
/// browser then requests `/webui/core/core/utils.js` (and the rest of app.js's
/// relative imports) as 404s. Feature views carry their directory so they
/// cannot alias `core/goals.js` / `lib/board.js`. `arena3d` is checked before
/// `arena` so a suffix match cannot steal the shorter name.
///
/// Adding a first-party module is one edit per list in this file: a tag here,
/// its suffix in `kindFor`, and its request path in `asset_paths`. The caches
/// themselves are arrays indexed by this enum, so a new tag cannot ship
/// without its own slot the way it could when each was a hand-written global.
pub const Kind = enum {
    css,
    views_css,
    js,
    boot,
    board_view,
    goals_view,
    knowledge_view,
    prompts_view,
    arena_view,
    arena3d_view,
    todos_view,
    models_view,
    vendor,
    chat,
    labels,
    goals,
    stream,
    theme,
    slash,
    overlay,
    search,
    composer,
    ai_disclosure,
    scroll,
    run_metrics,
    markdown,
    graph,
    board,
    runs_list,
    fleet,
    utils,
    icons,
    ui,
    dialog,
    usage,
    status,
    attachments,
    logs,
    plugins,
    palette,
    modelpicker,
    tools,
};

pub fn kindFor(target: []const u8) Kind {
    if (std.mem.endsWith(u8, target, "views.css")) return .views_css;
    if (std.mem.endsWith(u8, target, ".css")) return .css;
    if (std.mem.endsWith(u8, target, "preact-boot.js")) return .boot;
    if (std.mem.endsWith(u8, target, "features/board.js")) return .board_view;
    if (std.mem.endsWith(u8, target, "features/goals.js")) return .goals_view;
    if (std.mem.endsWith(u8, target, "features/knowledge.js")) return .knowledge_view;
    if (std.mem.endsWith(u8, target, "features/prompts.js")) return .prompts_view;
    if (std.mem.endsWith(u8, target, "features/arena3d.js")) return .arena3d_view;
    if (std.mem.endsWith(u8, target, "features/arena.js")) return .arena_view;
    if (std.mem.endsWith(u8, target, "features/todos.js")) return .todos_view;
    if (std.mem.endsWith(u8, target, "features/models.js")) return .models_view;
    if (std.mem.endsWith(u8, target, "vendor.js")) return .vendor;
    if (std.mem.endsWith(u8, target, "chat.js")) return .chat;
    if (std.mem.endsWith(u8, target, "labels.js")) return .labels;
    if (std.mem.endsWith(u8, target, "goals.js")) return .goals;
    if (std.mem.endsWith(u8, target, "stream.js")) return .stream;
    if (std.mem.endsWith(u8, target, "theme.js")) return .theme;
    if (std.mem.endsWith(u8, target, "core/slash.js")) return .slash;
    if (std.mem.endsWith(u8, target, "overlay.js")) return .overlay;
    if (std.mem.endsWith(u8, target, "search.js")) return .search;
    if (std.mem.endsWith(u8, target, "composer.js")) return .composer;
    if (std.mem.endsWith(u8, target, "ai-disclosure.js")) return .ai_disclosure;
    if (std.mem.endsWith(u8, target, "scroll.js")) return .scroll;
    if (std.mem.endsWith(u8, target, "run-metrics.js")) return .run_metrics;
    if (std.mem.endsWith(u8, target, "lib/runs-list.js")) return .runs_list;
    if (std.mem.endsWith(u8, target, "markdown.js")) return .markdown;
    if (std.mem.endsWith(u8, target, "graph.js")) return .graph;
    if (std.mem.endsWith(u8, target, "board.js")) return .board;
    if (std.mem.endsWith(u8, target, "fleet.js")) return .fleet;
    if (std.mem.endsWith(u8, target, "utils.js")) return .utils;
    if (std.mem.endsWith(u8, target, "icons.js")) return .icons;
    if (std.mem.endsWith(u8, target, "ui.js")) return .ui;
    if (std.mem.endsWith(u8, target, "dialog.js")) return .dialog;
    if (std.mem.endsWith(u8, target, "usage.js")) return .usage;
    if (std.mem.endsWith(u8, target, "status.js")) return .status;
    if (std.mem.endsWith(u8, target, "attachments.js")) return .attachments;
    if (std.mem.endsWith(u8, target, "logs.js")) return .logs;
    if (std.mem.endsWith(u8, target, "plugins.js")) return .plugins;
    if (std.mem.endsWith(u8, target, "palette.js")) return .palette;
    if (std.mem.endsWith(u8, target, "modelpicker.js")) return .modelpicker;
    if (std.mem.endsWith(u8, target, "tools.js")) return .tools;
    return .js;
}

/// Every asset of the comptime-embedded page bundle, by request path. Vendored
/// files (`/webui/vendor/*`), plugin assets (`/webui/plugins/*`), and
/// theme JSON (`/webui/themes/*`), and command catalogs
/// (`/webui/commands/*`) are served by their own routes and are
/// deliberately not here.
///
/// One list, because there used to be two: the module gate (`is_webui`, which
/// decides whether a disabled `modules.webui` should 404) and the asset route
/// itself were hand-maintained copies of the same set, and
/// `features/arena.js`, embedded and routed in `ui/webui.zig`, was
/// missing from both, so the Arena view's dynamic `import()` 404'd. Keeping
/// the set in one place is what stops the next module from doing the same.
/// `ui/webui.zig`'s `assetFor` still has to learn each new path too;
/// a test in `cli.zig` walks the source tree and fails if a file exists that
/// this list has never heard of.
pub const asset_paths = [_][]const u8{
    "/webui/app.css",
    "/webui/views.css",
    "/webui/app.js",
    "/webui/preact-boot.js",
    "/webui/core/attachments.js",
    "/webui/core/ai-disclosure.js",
    "/webui/core/chat.js",
    "/webui/core/composer.js",
    "/webui/core/dialog.js",
    "/webui/core/goals.js",
    "/webui/core/icons.js",
    "/webui/core/labels.js",
    "/webui/core/logs.js",
    "/webui/core/modelpicker.js",
    "/webui/core/overlay.js",
    "/webui/core/palette.js",
    "/webui/core/plugins.js",
    "/webui/core/scroll.js",
    "/webui/core/run-metrics.js",
    "/webui/core/search.js",
    "/webui/core/status.js",
    "/webui/core/stream.js",
    "/webui/core/theme.js",
    "/webui/core/slash.js",
    "/webui/core/tools.js",
    "/webui/core/ui.js",
    "/webui/core/usage.js",
    "/webui/core/utils.js",
    "/webui/core/vendor.js",
    "/webui/lib/board.js",
    "/webui/lib/graph.js",
    "/webui/lib/markdown.js",
    "/webui/lib/runs-list.js",
    "/webui/features/arena.js",
    "/webui/features/arena3d.js",
    "/webui/features/board.js",
    "/webui/features/fleet.js",
    "/webui/features/goals.js",
    "/webui/features/knowledge.js",
    "/webui/features/prompts.js",
    "/webui/features/todos.js",
    "/webui/features/models.js",
};

pub fn isAssetPath(path: []const u8) bool {
    for (asset_paths) |p| {
        if (std.mem.eql(u8, p, path)) return true;
    }
    return false;
}

/// Vendored third-party JS under `ui/vendor/`, embedded in `ui/vendor.zig` and
/// served from `/webui/vendor/*`. One list: a file added here without a route
/// (or the reverse) ships bytes the browser cannot fetch.
pub const vendor_files = [_][]const u8{
    "preact.module.js",
    "htm.module.js",
    "signals-core.module.js",
    "d3-dag.min.js",
    "hljs.min.js",
    "mermaid.min.js",
    "three.module.min.js",
    "three.core.min.js",
    "patternfly.min.css",
    "patternfly-addons.css",
};

pub fn isVendorFile(name: []const u8) bool {
    for (vendor_files) |p| {
        if (std.mem.eql(u8, p, name)) return true;
    }
    return false;
}

pub const PathNorm = struct {
    path: []const u8,
    tagged: bool,
};

/// Strip a `/webui/~<8-hex>/` cache-bust prefix. The tag itself is not verified
/// against the current build: any well-formed prefix maps to the live asset so
/// a mid-session rebuild does not 404 open tabs still holding the old URL.
pub fn normalizePath(raw: []const u8, buf: []u8) PathNorm {
    const pfx = "/webui/~";
    if (!std.mem.startsWith(u8, raw, pfx)) return .{ .path = raw, .tagged = false };
    if (raw.len < pfx.len + 9 or raw[pfx.len + 8] != '/') return .{ .path = raw, .tagged = false };
    const tag = raw[pfx.len .. pfx.len + 8];
    for (tag) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return .{ .path = raw, .tagged = false };
    }
    const rest = raw[pfx.len + 9 ..];
    if (buf.len < "/webui/".len + rest.len) return .{ .path = raw, .tagged = false };
    @memcpy(buf[0.."/webui/".len], "/webui/");
    @memcpy(buf["/webui/".len..][0..rest.len], rest);
    return .{ .path = buf[0 .. "/webui/".len + rest.len], .tagged = true };
}

/// A gzipped asset, compressed on first request and kept for the rest of
/// the process. The inputs are embedded at build time and identical for every
/// visitor, so compressing per request would burn CPU for the same bytes; the
/// buffer is intentionally never freed, being a cache that lives as long as
/// the server. A failed attempt (OOM, or output that didn't shrink) is
/// remembered too, so it is not retried on every hit.
pub const GzipCache = struct {
    /// Connection threads race for this. Whoever moves it out of `idle`
    /// compresses; anyone arriving meanwhile serves the file uncompressed for
    /// that one request instead of blocking behind a ~100ms compression. A
    /// lock would be the other option, but nothing here is worth waiting for:
    /// the identity encoding is always a correct answer.
    state: std.atomic.Value(State) = .init(.idle),
    /// Only read after `state` reads `.ready`, which is stored with release
    /// ordering after this is written.
    body: []const u8 = &.{},

    const State = enum(u8) { idle, compressing, ready, failed };
};

/// A rendered web UI asset, kept for the life of the process.
///
/// The markup, stylesheet and script are compiled into this binary, so they
/// cannot change while it runs, and when a rebuild changes them, hot reload
/// replaces the process, so a stale entry is not reachable. Without this every
/// request paid for reading the tool's wasm off disk, instantiating a zwasm
/// module, and JSON-decoding the result: 348ms and 187 KB for app.js on this
/// machine, on a connection the server closes immediately afterwards.
///
/// Races are resolved the way GzipCache resolves them: whoever moves the state
/// out of `idle` publishes, and a thread arriving meanwhile renders it the slow
/// way for that one request rather than blocking. Rendering twice is wasteful,
/// never wrong.
pub const RenderCache = struct {
    state: std.atomic.Value(State) = .init(.idle),
    /// Only read after `state` reads `.ready`.
    body: []const u8 = &.{},

    const State = enum(u8) { idle, rendering, ready, failed };
};

const kind_count = std.meta.tags(Kind).len;

var render_caches = [_]RenderCache{.{}} ** kind_count;
var gzip_caches = [_]GzipCache{.{}} ** kind_count;

pub fn renderCache(kind: Kind) *RenderCache {
    return &render_caches[@intFromEnum(kind)];
}

pub fn gzipCache(kind: Kind) *GzipCache {
    return &gzip_caches[@intFromEnum(kind)];
}

pub fn gzipCached(gpa: std.mem.Allocator, cache: *GzipCache, raw: []const u8) ?[]const u8 {
    switch (cache.state.load(.acquire)) {
        .ready => return cache.body,
        .failed, .compressing => return null,
        .idle => {},
    }
    if (cache.state.cmpxchgStrong(.idle, .compressing, .acq_rel, .acquire) != null) return null;

    // .best, not .default: this runs once per process and the result is
    // reused for every request after, so the extra CPU here is paid once
    // while the smaller body is what every visitor actually downloads.
    const compressed = gzipAlloc(gpa, raw, .best) orelse {
        cache.state.store(.failed, .release);
        return null;
    };
    // Published in this order so a thread that reads `.ready` is guaranteed to
    // see the finished slice.
    cache.body = compressed;
    cache.state.store(.ready, .release);
    return compressed;
}

pub fn gzipAlloc(gpa: std.mem.Allocator, raw: []const u8, level: std.compress.flate.Compress.Options) ?[]const u8 {
    // Sized to the input: a compressed form that needs more room than the
    // original is not worth serving, and running out of space here just means
    // falling back to the identity encoding.
    const dest = gpa.alloc(u8, raw.len) catch return null;
    const window = gpa.alloc(u8, std.compress.flate.max_window_len) catch {
        gpa.free(dest);
        return null;
    };
    defer gpa.free(window);

    var out: std.Io.Writer = .fixed(dest);
    var compress = std.compress.flate.Compress.init(&out, window, .gzip, level) catch {
        gpa.free(dest);
        return null;
    };
    compress.writer.writeAll(raw) catch {
        gpa.free(dest);
        return null;
    };
    compress.finish() catch {
        gpa.free(dest);
        return null;
    };

    return dest[0..out.end];
}

test "every cache kind gets its own slot" {
    // slash.js was on asset_paths but reused app.js's render/gzip slot: a gzip
    // client got app.js at /webui/core/slash.js and then requested
    // /webui/core/core/utils.js (and the rest of app.js's relative imports)
    // as 404s. Array-backed slots make that unrepresentable; this pins that
    // the indexing stays one-to-one.
    for (std.meta.tags(Kind), 0..) |a, i| {
        for (std.meta.tags(Kind)[i + 1 ..]) |b| {
            try std.testing.expect(renderCache(a) != renderCache(b));
            try std.testing.expect(gzipCache(a) != gzipCache(b));
        }
    }
}

test "cache-bust prefix is stripped only when well-formed" {
    var buf: [128]u8 = undefined;
    const tagged = normalizePath("/webui/~0a1b2c3d/core/utils.js", &buf);
    try std.testing.expect(tagged.tagged);
    try std.testing.expectEqualStrings("/webui/core/utils.js", tagged.path);

    const short = normalizePath("/webui/~0a1b/core/utils.js", &buf);
    try std.testing.expect(!short.tagged);
    try std.testing.expectEqualStrings("/webui/~0a1b/core/utils.js", short.path);

    const plain = normalizePath("/webui/core/utils.js", &buf);
    try std.testing.expect(!plain.tagged);
    try std.testing.expectEqualStrings("/webui/core/utils.js", plain.path);
}
