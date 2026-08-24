//! Tool registry: loads `*.tool.json` descriptors from the tools directory.
//! Descriptors are the agent-editable metadata (name, description, JSON
//! schema, sandbox policy); the WASM module itself implements behavior.

const std = @import("std");
const json = std.json;
const types = @import("../llm/types.zig");
const log = @import("../util/log.zig");
const utf8 = @import("../util/utf8.zig");
const strField = @import("../util/json.zig").strField;
const manifest = @import("manifest.zig");
const preset_mod = @import("../preset/preset.zig");
const test_env = @import("../util/test_env.zig");

pub const Tool = struct {
    /// Schema version of the descriptor this was parsed from. Absent in the
    /// file means 1: every manifest written before the key existed is a v1
    /// manifest, so the default is what keeps them loading unchanged. A
    /// version this build does not understand is refused at parse time rather
    /// than read with v1 rules, see `manifest.zig`.
    manifest_version: i64 = manifest.current_version,
    name: []const u8,
    /// The human-facing description: what a person reads in the webui Tools
    /// view or the REPL's tool detail. Free to be as long as it needs to be.
    description: []const u8,
    /// The model-facing description: sent in the catalog line every turn and
    /// in the full schema when this tool is core or revealed, so its cost is
    /// paid on nearly every request. Defaults to `description` when a
    /// manifest omits `llm_description` (see `parseDescriptor`), so an
    /// unmigrated tool still works, just not as cheaply.
    llm_description: []const u8 = "",
    /// Binding usage rules for this tool, injected into the system prompt's
    /// "## Tool guidance" section whenever the tool is in the catalog and
    /// echoed by `load_tools`. Distinct from the descriptions, which say what
    /// the tool does: this says how it must be used, and it rides ahead of the
    /// catalog so a lazy-loaded tool's rules are read before its schema is.
    prompt_guidance: []const u8 = "",
    /// Where the module is, as resolved by `resolveWasmPath` at load: a path
    /// with a separator (`zig-out/tools/x.wasm`) is read from the process's
    /// working directory, a bare name from the manifest's own directory. Not
    /// "relative to the tools directory", which is what this comment used to
    /// say and what no in-tree manifest has ever meant.
    wasm: []const u8,
    input_schema: json.Value,
    /// Hosts this tool may reach via ck_http (empty = no network).
    network_allow: []const []const u8 = &.{},
    /// Directory prefixes (relative to the sandbox root) the tool may access
    /// via ck_fs_*; empty = filesystem denied.
    fs_prefixes: []const []const u8 = &.{},
    /// Instruction budget (wasm fuel) for one call of this tool. 0 means the
    /// sandbox default; a positive value is clamped to that default as a
    /// ceiling in runtime.zig, so a descriptor can tighten its own budget
    /// but never raise it.
    fuel: u64 = 0,
    /// If true, the tool is loaded and runnable but hidden from the LLM catalog.
    internal: bool = false,
    /// Machine-local on/off switch from `state/plugins.json`. Disabled tools
    /// stay loadable (the REPL still lists them) but are withheld from the LLM
    /// catalog and refused at execution.
    enabled: bool = true,
    /// May call the model through `ck_llm`. Costs tokens, so it is opt-in per
    /// descriptor and forces the tool onto the sequential execution path.
    llm: bool = false,
    /// May read the session store through `ck_session` (list/get/search).
    /// Opt-in per descriptor: the session transcript is private to its owner.
    session: bool = false,
    /// May emit onto the serve live bus through `ck_publish`. The import
    /// existing is not a grant. Forces the sequential path: the bus is
    /// host-shared state, same reason `sequential` exists for the chat log.
    live_publish: bool = false,
    /// Never runs on the parallel worker pool (host-shared state, e.g. the
    /// chatroom log): each tool call waits its turn on the main thread.
    sequential: bool = false,
    /// Contributes a segment to the REPL status line. Pair with
    /// `"internal": true` so the model never calls it.
    statusline: bool = false,
    /// Runs once after each REPL turn (empty input) and may print a line
    /// into the transcript, a general REPL-behavior plugin, as opposed to
    /// `statusline`'s fixed one-line segment. Pair with `"internal": true`
    /// so the model never calls it.
    turn_hook: bool = false,
    /// Free-form per-plugin settings from the descriptor's `config` object,
    /// handed to the guest verbatim via `ck_config`. The harness only reads the
    /// `provider` / `model` / `max_tokens` keys, to aim `ck_llm` at a specific
    /// backend; everything else is the plugin's own business.
    config: json.Value = .{ .object = .{} },
    /// `config`, pre-serialized once at registry load. `config` never changes
    /// after `Registry.load` returns (see `applyConfigOverrides`), so
    /// re-serializing it on every `sandboxFor` call, previously once per
    /// tool invocation, transform run, and worker spawn, redid the same
    /// work every time instead of once.
    config_json: []const u8 = "{}",
    /// Which `config` keys may be changed at runtime, from the descriptor's
    /// `config_editable` array. Empty means the plugin exposes no settings:
    /// the rest of `config` is the tool's own structure, not a control panel.
    config_editable: []const []const u8 = &.{},
    /// Set when this tool rewrites another tool's input or output.
    transform: ?Transform = null,
    /// This tool answers pass/fail about something (a gate, an eval, a lint).
    /// Its verdict is recorded in the run graph as a check, because a run that
    /// turned on one reads as unmotivated without it.
    check: bool = false,
    /// `"peers"` or `"providers"`: the harness adds those configured hosts to
    /// `network_allow` at load, because a descriptor cannot know them.
    network_from_config: []const u8 = "",
    /// Commands this tool may run through `ck_exec`, compared against argv[0]
    /// exactly (`host.execAllowed`). Empty is not "the harness default set":
    /// it is no exec at all, which is what every tool that does not name a
    /// command gets.
    exec_allow: []const []const u8 = &.{},
    /// Environment variables this tool may read. Empty means the safe defaults
    /// in host.zig, never the whole process environment: that is where the API
    /// keys are.
    env_allow: []const []const u8 = &.{},
    /// May call other tools through `ck_tool`. Only the chain tool needs it.
    tool_call: bool = false,
    /// When `tool_call` is true, which tool names it may invoke via `ck_tool`.
    /// Null / empty = all enabled non-internal tools.
    tool_allow: ?[]const []const u8 = null,

    /// Ask the human before running this tool, when a confirm channel is
    /// installed (agent.confirm_writes). Unset, the answer is derived from
    /// what the descriptor grants: anything with exec or filesystem access,
    /// where fs_prefixes carry write access (there is no read-only grant), is a
    /// write in a viewer's eyes. Read-only tools opt out with
    /// `"confirm": false` so reads keep running free; a tool whose risk its
    /// grants understate (delegation, say) opts in with `"confirm": true`.
    confirm: ?bool = null,

    /// Core tools (the `cmd_*` slash commands, the web UI, the formatter) back
    /// the harness itself and stay on. A transform is hidden from the model
    /// like an internal tool, but switching it off is the whole point of it.
    pub fn toggleable(self: Tool) bool {
        return !self.internal or self.transform != null;
    }

    /// Whether a human channel, when one is installed, must approve a call
    /// to this tool before it runs (see the `confirm` field for the default).
    pub fn needsConfirm(self: *const Tool) bool {
        return self.confirm orelse (self.exec_allow.len > 0 or self.fs_prefixes.len > 0);
    }

    /// True when `key` is one the descriptor opted in to runtime editing.
    pub fn configKeyEditable(self: *const Tool, key: []const u8) bool {
        for (self.config_editable) |k| {
            if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
    }
};

/// A transform plugin sits in the chain around other tools: `before` rewrites
/// the arguments going in, `after` rewrites the result coming out. Lower
/// `order` runs first, and `tools` may name specific tools or `*` for all.
pub const Transform = struct {
    pub const Phase = enum { before, after };

    phase: Phase,
    tools: []const []const u8 = &.{"*"},
    order: i64 = 0,

    pub fn appliesTo(self: Transform, tool_name: []const u8) bool {
        for (self.tools) |t| {
            if (std.mem.eql(u8, t, "*") or std.mem.eql(u8, t, tool_name)) return true;
        }
        return false;
    }
};

/// Machine-local plugin toggles: `{"disabled": ["web_search"]}`. Lives under
/// state/ because it is per-checkout runtime state, not project configuration.
pub const plugins_state_path = "state/plugins.json";

/// Machine-local overrides of per-plugin settings:
/// `{"rlm": {"max_depth": 5}}`. Layered over the descriptor's `config` at load
/// so the committed manifest keeps holding the project default and a local
/// change stays local, the same split `plugins.json` makes for on/off.
pub const plugin_config_state_path = "state/plugin_config.json";

/// Catalog line description: enough to choose a tool, cheap enough that
/// the full listing stays small.
const max_catalog_line_bytes: usize = 160;

pub const Registry = struct {
    tools: std.array_hash_map.String(Tool) = .empty,

    pub fn load(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, tools_dirs: []const []const u8) !Registry {
        var reg = Registry{};
        var sources: std.StringHashMapUnmanaged([]const u8) = .empty;

        for (tools_dirs) |tools_dir| {
            var dir = base.openDir(io, tools_dir, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => {
                    // Wrong/missing path is a config problem (agent.tools_dir), not a
                    // missing guest rebuild, `zig build tools` only fills zig-out/tools.
                    // One missing list entry must not empty the rest of the registry.
                    log.log(.warn, "tools dir '{s}' not found; check agent.tools_dir (expected a directory of *.tool.json manifests)", .{tools_dir});
                    continue;
                },
                else => return err,
            };
            defer dir.close(io);

            var it = dir.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".tool.json")) continue;
                const raw = dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch |err| {
                    log.log(.warn, "cannot read tool descriptor '{s}': {s}", .{ entry.name, @errorName(err) });
                    continue;
                };
                var tool = parseDescriptor(arena, raw) catch |err| {
                    log.log(.warn, "invalid tool descriptor '{s}': {s} (run `clanker plugins validate {s}` for the offending key)", .{ entry.name, @errorName(err), tools_dir });
                    continue;
                };
                tool.wasm = try resolveWasmPath(arena, tools_dir, tool.wasm);
                if (reg.tools.get(tool.name)) |_| {
                    const prev = sources.get(tool.name) orelse "";
                    if (!std.mem.eql(u8, prev, tools_dir)) {
                        log.log(.warn, "tool '{s}' from '{s}' overrides '{s}'", .{ tool.name, tools_dir, prev });
                    }
                }
                try sources.put(arena, tool.name, tools_dir);
                try reg.tools.put(arena, tool.name, tool);
            }
        }
        reg.applyToggles(io, arena, base);
        reg.applyConfigOverrides(io, arena, base);
        var vals = reg.tools.iterator();
        while (vals.next()) |entry| {
            entry.value_ptr.config_json = try std.fmt.allocPrint(arena, "{f}", .{json.fmt(entry.value_ptr.config, .{})});
        }
        return reg;
    }

    /// Process-lifetime cache in front of `load`, for callers that only read
    /// the result.
    ///
    /// `load` opens and parses every `*.tool.json` under the tool directories
    /// (118 in-tree, ~180 KB of JSON) plus the two state files. `toolJson`
    /// calls it, so every CLI tool invocation and every HTTP API request under
    /// `clanker serve` re-read and re-parsed all of it to answer one call:
    /// ~260 `openat` and ~180 KB of JSON parsing per request, for data that
    /// does not change between them. A descriptor is read-only once loaded, so
    /// one copy serves every reader.
    ///
    /// Freshness is a stamp over each descriptor's name, size and mtime plus
    /// the two `state/` overlay files, so an added, removed, edited, or
    /// toggled plugin is picked up without a restart. A hit costs one `statx`
    /// per descriptor and nothing else.
    ///
    /// Read-only: the returned tools point into the cache's own arena and are
    /// shared with every other caller. A caller that rewrites them
    /// (`rebaseWasmPaths`) must use `load` and own its copy.
    pub fn loadCached(io: std.Io, tools_dirs: []const []const u8) !Registry {
        const base = std.Io.Dir.cwd();
        cacheLock();
        defer cacheUnlock();

        const stamp = cacheStamp(io, base, tools_dirs);
        if (cache_slot) |slot| {
            if (slot.stamp == stamp and sameDirs(slot.dirs, tools_dirs)) return slot.reg;
        }

        // ponytail: the superseded generation is leaked, not freed. Serve
        // answers requests on connection threads and hands each one this
        // registry by value, so freeing here would pull the descriptors out
        // from under a request still rendering them. Invalidation happens on a
        // plugin toggle or a rebuild, not per request, so the leak is bounded
        // by how often those happen; reference-counting a generation is the
        // upgrade path if that ever stops being true.
        const holder = try cache_gpa.create(std.heap.ArenaAllocator);
        holder.* = std.heap.ArenaAllocator.init(cache_gpa);
        const arena = holder.allocator();
        const reg = try load(io, arena, base, tools_dirs);
        const dirs = try arena.alloc([]const u8, tools_dirs.len);
        for (tools_dirs, 0..) |d, i| dirs[i] = try arena.dupe(u8, d);
        cache_slot = .{ .stamp = stamp, .dirs = dirs, .reg = reg };
        return reg;
    }

    /// Allocator behind the cache. The process-wide page allocator rather than
    /// a caller's gpa: the cache outlives every request that fills it, so it
    /// must not borrow an allocator a request owns.
    const cache_gpa = std.heap.page_allocator;

    const CacheSlot = struct {
        stamp: u64,
        dirs: []const []const u8,
        reg: Registry,
    };

    var cache_slot: ?CacheSlot = null;
    /// Spun rather than parked: the critical section is a stat sweep, and the
    /// same shape `serve/live.zig` uses because a lock reached from connection
    /// threads has no `std.Io` to hand.
    var cache_mutex: std.atomic.Mutex = .unlocked;

    fn cacheLock() void {
        while (!cache_mutex.tryLock()) std.Thread.yield() catch {};
    }

    fn cacheUnlock() void {
        cache_mutex.unlock();
    }

    fn sameDirs(a: []const []const u8, b: []const []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (!std.mem.eql(u8, x, y)) return false;
        }
        return true;
    }

    /// Cheap fingerprint of everything `load` would read: every descriptor's
    /// name, size and mtime, plus the two `state/` overlays. Stat only, no
    /// open and no parse, so a cache hit is ~118 syscalls instead of ~260
    /// syscalls and 180 KB of JSON.
    ///
    /// A stat that fails folds in as a miss rather than being skipped, so a
    /// descriptor appearing or vanishing still changes the stamp.
    pub fn cacheStamp(io: std.Io, base: std.Io.Dir, tools_dirs: []const []const u8) u64 {
        var h = std.hash.Wyhash.init(0x7A6B5C4D3E2F1009);
        for (tools_dirs) |tools_dir| {
            h.update(tools_dir);
            var dir = base.openDir(io, tools_dir, .{ .iterate = true }) catch {
                h.update("\x00missing");
                continue;
            };
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".tool.json")) continue;
                h.update(entry.name);
                const st = dir.statFile(io, entry.name, .{}) catch {
                    h.update("\x00unstattable");
                    continue;
                };
                h.update(std.mem.asBytes(&st.size));
                // Nanoseconds as i64, not `asBytes(&st.mtime)`: `i96` occupies
                // 16 bytes whose top 4 are unspecified, so the struct form
                // hashed uninitialized stack memory and the stamp changed
                // between calls (cache never hit).
                const mtime_ns: i64 = @intCast(st.mtime.nanoseconds);
                h.update(std.mem.asBytes(&mtime_ns));
            }
        }
        for ([_][]const u8{ plugins_state_path, plugin_config_state_path }) |p| {
            h.update(p);
            const st = base.statFile(io, p, .{}) catch {
                h.update("\x00absent");
                continue;
            };
            h.update(std.mem.asBytes(&st.size));
            const mtime_ns: i64 = @intCast(st.mtime.nanoseconds);
            h.update(std.mem.asBytes(&mtime_ns));
        }
        return h.final();
    }

    /// Where the module named by a descriptor's `wasm` key actually lives.
    ///
    /// Every path is read relative to the process's working directory, which
    /// is what the in-tree manifests want (`zig-out/tools/x.wasm`,
    /// `tools/ts/dist/x.wasm`) and exactly what an out-of-tree plugin cannot use:
    /// a directory someone unpacked somewhere has no idea what clanker's cwd
    /// will be. So a `wasm` with no path separator is resolved beside its own
    /// manifest instead, which makes `{name.tool.json, name.wasm}` in one
    /// directory a self-contained package that `agent.tools_dir` can point at.
    ///
    /// Every shipped manifest names a path with a separator, so this is a
    /// no-op for all of them: the bare form is new surface, not a change of
    /// meaning for the existing one.
    pub fn resolveWasmPath(arena: std.mem.Allocator, tools_dir: []const u8, wasm: []const u8) ![]const u8 {
        if (wasm.len == 0) return wasm;
        if (std.mem.findScalar(u8, wasm, '/') != null) return wasm;
        if (tools_dir.len == 0) return wasm;
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, tools_dir, "/"), wasm });
    }

    /// Pins every relative `wasm` path to `root`, for a run that is about to
    /// chdir somewhere else.
    ///
    /// Guest modules are build artifacts of the harness that is already
    /// running: `zig-out/tools/*.wasm` is gitignored, so a fresh worktree has
    /// none, and the paths are read cwd-relative at call time. An isolated run
    /// therefore lost every WASM tool the moment it moved (observed live:
    /// "cannot load zig-out/tools/git.wasm: FileNotFound" for all 77 of them,
    /// with the model reasonably concluding the sandbox was broken and
    /// refusing to invent results). Which binaries a run uses is a property of
    /// the harness, not of the tree it edits, so they stay pinned to where the
    /// run started rather than being copied or rebuilt per worktree.
    ///
    /// Absolute paths are left alone, and so is an already-absolute `root`
    /// requirement: a relative root would defeat the point.
    pub fn rebaseWasmPaths(self: *Registry, arena: std.mem.Allocator, root: []const u8) !void {
        if (root.len == 0 or root[0] != '/') return error.RootNotAbsolute;
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            const tool = entry.value_ptr;
            if (tool.wasm.len == 0 or tool.wasm[0] == '/') continue;
            tool.wasm = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, root, "/"), tool.wasm });
        }
    }

    /// Layers `state/plugin_config.json` over each descriptor's `config`.
    ///
    /// Only keys the descriptor lists in `config_editable` are applied. A
    /// plugin's config is otherwise free-form and some of it is structural,
    /// not tunable: the four chat_* descriptors share one wasm binary and
    /// select their behaviour with `"op"`, so letting an override reach that
    /// key would turn chat_send into chat_rooms. Editability is opt-in per
    /// key, declared by the tool that knows which of its settings are safe.
    fn applyConfigOverrides(self: *Registry, io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) void {
        const raw = base.readFileAlloc(io, plugin_config_state_path, arena, .limited(256 * 1024)) catch return;
        const parsed = json.parseFromSliceLeaky(json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch {
            log.log(.warn, "invalid {s}; leaving every plugin at its descriptor config", .{plugin_config_state_path});
            return;
        };
        if (parsed != .object) return;

        var it = parsed.object.iterator();
        while (it.next()) |entry| {
            const t = self.tools.getPtr(entry.key_ptr.*) orelse continue;
            const overrides = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => continue,
            };
            if (t.config != .object) continue;
            var merged = t.config.object.clone(arena) catch continue;
            var ov = overrides.iterator();
            while (ov.next()) |o| {
                if (!t.configKeyEditable(o.key_ptr.*)) continue;
                merged.put(arena, o.key_ptr.*, o.value_ptr.*) catch continue;
            }
            t.config = .{ .object = merged };
        }
    }

    /// Marks tools listed in `state/plugins.json` as disabled. Internal tools
    /// are skipped: they back the REPL slash commands and the HTTP routes, so
    /// switching one off would break the harness rather than a plugin.
    fn applyToggles(self: *Registry, io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir) void {
        const raw = base.readFileAlloc(io, plugins_state_path, arena, .limited(64 * 1024)) catch return;
        const parsed = json.parseFromSliceLeaky(json.Value, arena, raw, .{ .ignore_unknown_fields = true }) catch {
            log.log(.warn, "invalid {s}; leaving every plugin at its descriptor default", .{plugins_state_path});
            return;
        };
        if (parsed != .object) return;
        self.applyToggleList(parsed.object.get("disabled"), false);
        self.applyToggleList(parsed.object.get("enabled"), true);
    }

    fn applyToggleList(self: *Registry, list: ?json.Value, value: bool) void {
        const arr = switch (list orelse return) {
            .array => |a| a,
            else => return,
        };
        for (arr.items) |v| {
            if (v != .string) continue;
            const t = self.tools.getPtr(v.string) orelse continue;
            if (!t.toggleable()) continue;
            t.enabled = value;
        }
    }

    pub fn get(self: *const Registry, name: []const u8) ?*const Tool {
        return self.tools.getPtr(name);
    }

    pub fn names(self: *const Registry, arena: std.mem.Allocator) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| try out.append(arena, kv.key_ptr.*);
        return out.toOwnedSlice(arena);
    }

    /// Returns all enabled tools that have `statusline: true`. These are
    /// invoked with empty input after each turn to contribute segments to
    /// the REPL status bar. The caller owns the returned slice via `arena`.
    pub fn statuslineTools(self: *const Registry, arena: std.mem.Allocator) ![]const *const Tool {
        var out: std.ArrayList(*const Tool) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr;
            if (t.statusline and t.enabled) try out.append(arena, t);
        }
        std.mem.sort(*const Tool, out.items, {}, toolNameLt);
        return out.toOwnedSlice(arena);
    }

    /// Returns all enabled tools that have `turn_hook: true`. Same cadence
    /// as `statuslineTools` (invoked with empty input once after each turn),
    /// but the caller treats a non-empty result as a line to print into the
    /// transcript rather than a status-bar segment, for plugins that react
    /// to what just happened instead of only decorating the status line.
    pub fn turnHookTools(self: *const Registry, arena: std.mem.Allocator) ![]const *const Tool {
        var out: std.ArrayList(*const Tool) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr;
            if (t.turn_hook and t.enabled) try out.append(arena, t);
        }
        std.mem.sort(*const Tool, out.items, {}, toolNameLt);
        return out.toOwnedSlice(arena);
    }

    fn toolNameLt(_: void, a: *const Tool, b: *const Tool) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }

    fn toolDefNameLt(_: void, a: types.ToolDef, b: types.ToolDef) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }

    /// Converts registry tools into LLM ToolDefs (in the given arena).
    /// Name of the tool that hands out schemas on demand. Defined here
    /// because both the registry (which advertises it) and the agent (which
    /// answers it) have to agree on the spelling.
    pub const load_tool_name = "load_tools";

    /// The schema the model needs to ask for other schemas.
    pub fn loadToolDef(arena: std.mem.Allocator) !types.ToolDef {
        var names_schema: json.ObjectMap = .empty;
        try names_schema.put(arena, "type", .{ .string = "array" });
        var item: json.ObjectMap = .empty;
        try item.put(arena, "type", .{ .string = "string" });
        try names_schema.put(arena, "items", .{ .object = item });

        var props: json.ObjectMap = .empty;
        try props.put(arena, "names", .{ .object = names_schema });

        var required = json.Array.init(arena);
        try required.append(.{ .string = "names" });

        var schema: json.ObjectMap = .empty;
        try schema.put(arena, "type", .{ .string = "object" });
        try schema.put(arena, "properties", .{ .object = props });
        try schema.put(arena, "required", .{ .array = required });

        return .{
            .name = load_tool_name,
            .description = "Load the full input schemas for tools listed in the tool catalog, so they can be called. " ++
                "Pass the exact names from the catalog. The tools stay available for the rest of this run.",
            .input_schema = .{ .object = schema },
        };
    }

    /// One line per tool: what exists, and enough of what it does to decide
    /// whether to ask for its schema. This is what the system prompt carries
    /// instead of every schema, which for this repo is the difference between
    /// roughly 6,600 tokens and roughly 1,000 in every single request.
    pub fn catalogText(
        self: *const Registry,
        arena: std.mem.Allocator,
        revealed: *const std.array_hash_map.String(void),
        preset: ?*const preset_mod.Preset,
    ) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        // Not "names": Registry.names is a method on this same type, and a
        // local of that name shadows it and does not compile.
        var listed: std.ArrayList([]const u8) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr.*;
            if (t.internal or !t.enabled) continue;
            if (presetHides(preset, t.name)) continue;
            try listed.append(arena, t.name);
        }
        std.mem.sort([]const u8, listed.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (listed.items) |name| {
            const t = self.get(name).?;
            // A tool whose schema is already loaded is marked, so the model
            // does not spend a call asking for what it can already call.
            const mark: []const u8 = if (revealed.contains(name)) "* " else "  ";
            try out.writer.print("{s}{s}: {s}\n", .{ mark, name, firstLine(t.llm_description) });
        }
        return out.written();
    }

    /// The body of the system prompt's "## Tool guidance" section: one
    /// `### name` block per enabled catalog tool that declares
    /// `prompt_guidance`, sorted like the catalog. Rendered from the whole
    /// registry rather than the loaded tool defs, because in catalog mode a
    /// tool's schema may be lazy-loaded while its usage rules must be visible
    /// from the first request.
    pub fn guidanceText(self: *const Registry, arena: std.mem.Allocator, preset: ?*const preset_mod.Preset) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var listed: std.ArrayList([]const u8) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr.*;
            if (t.internal or !t.enabled or t.prompt_guidance.len == 0) continue;
            if (presetHides(preset, t.name)) continue;
            try listed.append(arena, t.name);
        }
        std.mem.sort([]const u8, listed.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (listed.items) |name| {
            const t = self.get(name).?;
            try out.writer.print("### {s}\n\n{s}\n\n", .{ t.name, t.prompt_guidance });
        }
        return out.written();
    }

    fn firstLine(s: []const u8) []const u8 {
        const line = s[0 .. std.mem.findScalar(u8, s, '\n') orelse s.len];
        // Long enough to choose by, short enough that forty of them stay cheap.
        return utf8.cap(line, max_catalog_line_bytes);
    }

    test firstLine {
        try std.testing.expectEqualStrings("one", firstLine("one\ntwo"));
        try std.testing.expectEqualStrings("short", firstLine("short"));
        try std.testing.expectEqual(max_catalog_line_bytes, firstLine("x" ** 400).len);
    }

    /// The tool definitions to send with a request: the always-available core,
    /// everything revealed so far, and `load_tools` itself. The rest of the
    /// registry is reachable through the catalog, not through this list.
    pub fn lazyToolDefs(
        self: *const Registry,
        arena: std.mem.Allocator,
        core: []const []const u8,
        revealed: *const std.array_hash_map.String(void),
        preset: ?*const preset_mod.Preset,
    ) ![]types.ToolDef {
        var out: std.ArrayList(types.ToolDef) = .empty;
        try out.append(arena, try loadToolDef(arena));
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr.*;
            if (t.internal or !t.enabled) continue;
            if (presetHides(preset, t.name)) continue;
            const in_core = for (core) |c| {
                if (std.mem.eql(u8, c, t.name)) break true;
            } else false;
            if (!in_core and !revealed.contains(t.name)) continue;
            try out.append(arena, .{
                .name = t.name,
                .description = t.llm_description,
                .input_schema = t.input_schema,
                .internal = t.internal,
            });
        }
        std.mem.sort(types.ToolDef, out.items[1..], {}, toolDefNameLt);
        return out.toOwnedSlice(arena);
    }

    /// Whether the active preset hides `name` from every list the model can
    /// see. `null` means no preset and nothing hidden.
    ///
    /// `load_tools` is exempt on purpose: it is how the catalog is opened, and
    /// a preset with a non-empty `tools_allow` that does not name it (every
    /// preset shipped today) would otherwise leave the model with the hot set
    /// and no door to the rest.
    pub fn presetHides(preset: ?*const preset_mod.Preset, name: []const u8) bool {
        const p = preset orelse return false;
        if (std.mem.eql(u8, name, load_tool_name)) return false;
        return !preset_mod.allowed(p.*, name);
    }

    pub fn toToolDefs(self: *const Registry, arena: std.mem.Allocator) ![]types.ToolDef {
        var out: std.ArrayList(types.ToolDef) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr.*;
            if (t.internal or !t.enabled) continue;
            try out.append(arena, .{
                .name = t.name,
                .description = t.llm_description,
                .input_schema = t.input_schema,
                .internal = t.internal,
            });
        }
        std.mem.sort(types.ToolDef, out.items, {}, toolDefNameLt);
        return out.toOwnedSlice(arena);
    }

    /// A tool's JSON Schema, with the shape providers insist on filled in.
    ///
    /// Anthropic rejects a request whose tool list contains a schema with no
    /// "type", and it rejects the *entire* request, so one manifest written
    /// with OpenAI's "parameters" key, or with the type omitted, silently
    /// breaks every tool call for every tool. Accept both spellings here and
    /// default the type rather than shipping a request no provider will take.
    fn normalizedSchema(arena: std.mem.Allocator, obj: json.ObjectMap) !json.Value {
        const raw = obj.get("input_schema") orelse obj.get("parameters") orelse json.Value{ .object = .empty };
        const src = switch (raw) {
            .object => |o| o,
            // A non-object schema is not something a provider can use.
            else => return json.Value{ .object = .empty },
        };
        if (src.get("type") != null) return raw;

        var out: json.ObjectMap = .empty;
        var it = src.iterator();
        while (it.next()) |kv| try out.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        try out.put(arena, "type", json.Value{ .string = "object" });
        return json.Value{ .object = out };
    }

    pub fn parseDescriptor(arena: std.mem.Allocator, raw: []const u8) !Tool {
        const v = try json.parseFromSliceLeaky(json.Value, arena, raw, .{ .ignore_unknown_fields = true });
        const obj = switch (v) {
            .object => |o| o,
            else => return error.DescriptorNotObject,
        };
        // Read before anything else: a descriptor written against a schema
        // this build does not know may spell a familiar key differently, so
        // parsing the rest of it under v1 rules would load a tool whose policy
        // is not what its author wrote. Refusing is the safe half of the
        // forward-compatibility deal the version key exists to make.
        var version: i64 = manifest.current_version;
        if (obj.get("manifest_version")) |mv| {
            if (mv != .integer) return error.ManifestVersionNotInteger;
            version = mv.integer;
            if (version < manifest.min_version or version > manifest.current_version)
                return error.UnsupportedManifestVersion;
        }

        const description = try strField(obj, "description");
        var t = Tool{
            .manifest_version = version,
            .name = try strField(obj, "name"),
            .description = description,
            // Falls back to the full description until the manifest carries
            // its own compressed one.
            .llm_description = description,
            .wasm = try strField(obj, "wasm"),
            // A schema without a "type" is rejected by the provider, and it
            // rejects the *whole* request: one malformed manifest takes every
            // tool call down with it. Normalize here instead, an object
            // schema is what every tool in this registry has.
            .input_schema = normalizedSchema(arena, obj) catch .{ .object = .empty },
        };
        if (obj.get("llm_description")) |ld| {
            if (ld == .string and ld.string.len > 0) t.llm_description = ld.string;
        }
        if (obj.get("prompt_guidance")) |pg| {
            if (pg == .string) t.prompt_guidance = pg.string;
        }
        if (obj.get("check")) |c| {
            if (c == .bool) t.check = c.bool;
        }
        if (obj.get("network_allow")) |na| {
            switch (na) {
                .array => |arr| t.network_allow = try strArray(arena, arr),
                else => {},
            }
        }
        if (obj.get("fs_prefixes")) |fp| {
            switch (fp) {
                .array => |arr| t.fs_prefixes = try strArray(arena, arr),
                else => {},
            }
        }
        if (obj.get("fuel")) |fv| {
            // Anything but a positive integer keeps the default: a fuel of 0
            // or a typo'd string must not turn into an unrunnable tool.
            if (fv == .integer and fv.integer > 0) t.fuel = std.math.lossyCast(u64, fv.integer);
        }
        if (obj.get("internal")) |iv| {
            switch (iv) {
                .bool => |b| t.internal = b,
                else => {},
            }
        }
        // A descriptor may ship switched off: a transform that spends tokens on
        // every tool call has to be opted into, not opted out of.
        if (obj.get("enabled")) |ev| {
            switch (ev) {
                .bool => |b| t.enabled = b,
                else => {},
            }
        }
        if (obj.get("network_from_config")) |nv| {
            if (nv == .string) t.network_from_config = nv.string;
        }
        if (obj.get("exec_allow")) |ev| {
            switch (ev) {
                .array => |arr| t.exec_allow = try strArray(arena, arr),
                else => {},
            }
        }
        if (obj.get("env_allow")) |ev| {
            switch (ev) {
                .array => |arr| t.env_allow = try strArray(arena, arr),
                else => {},
            }
        }
        if (obj.get("llm")) |lv| {
            switch (lv) {
                .bool => |b| t.llm = b,
                else => {},
            }
        }
        if (obj.get("session")) |sv| {
            switch (sv) {
                .bool => |b| t.session = b,
                else => {},
            }
        }
        if (obj.get("live_publish")) |lv| {
            switch (lv) {
                .bool => |b| t.live_publish = b,
                else => {},
            }
        }
        if (obj.get("confirm")) |cv| {
            switch (cv) {
                .bool => |b| t.confirm = b,
                else => {},
            }
        }
        if (obj.get("sequential")) |sv| {
            switch (sv) {
                .bool => |b| t.sequential = b,
                else => {},
            }
        }
        if (obj.get("statusline")) |sv| {
            switch (sv) {
                .bool => |b| t.statusline = b,
                else => {},
            }
        }
        if (obj.get("turn_hook")) |sv| {
            switch (sv) {
                .bool => |b| t.turn_hook = b,
                else => {},
            }
        }
        if (obj.get("config_editable")) |ev| {
            if (ev == .array) {
                var keys: std.ArrayList([]const u8) = .empty;
                for (ev.array.items) |k| {
                    if (k == .string) keys.append(arena, k.string) catch continue;
                }
                t.config_editable = keys.items;
            }
        }
        if (obj.get("config")) |cv| {
            if (cv == .object) t.config = cv;
        }
        if (obj.get("transform")) |tv| {
            if (tv == .object) t.transform = try parseTransform(arena, tv.object);
        }
        if (obj.get("tool_call")) |tv| {
            if (tv == .bool) t.tool_call = tv.bool;
        }
        if (obj.get("tool_allow")) |tv| {
            switch (tv) {
                .array => |arr| t.tool_allow = try strArray(arena, arr),
                else => {},
            }
        }
        return t;
    }

    fn parseTransform(arena: std.mem.Allocator, obj: json.ObjectMap) !Transform {
        const phase_str = switch (obj.get("phase") orelse return error.TransformPhaseMissing) {
            .string => |s| s,
            else => return error.TransformPhaseMissing,
        };
        var tr = Transform{
            .phase = if (std.mem.eql(u8, phase_str, "before"))
                .before
            else if (std.mem.eql(u8, phase_str, "after"))
                .after
            else
                return error.TransformPhaseInvalid,
        };
        if (obj.get("tools")) |tv| {
            switch (tv) {
                .array => |arr| tr.tools = try strArray(arena, arr),
                else => {},
            }
        }
        if (obj.get("order")) |ov| {
            switch (ov) {
                .integer => |i| tr.order = i,
                else => {},
            }
        }
        return tr;
    }

    /// Enabled transform plugins that wrap `tool_name` in `phase`, ordered.
    /// A transform never wraps itself or another transform.
    pub fn transformsFor(
        self: *const Registry,
        arena: std.mem.Allocator,
        tool_name: []const u8,
        phase: Transform.Phase,
    ) ![]const *const Tool {
        var out: std.ArrayList(*const Tool) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr;
            const tr = t.transform orelse continue;
            if (!t.enabled or tr.phase != phase) continue;
            if (std.mem.eql(u8, t.name, tool_name)) continue;
            if (!tr.appliesTo(tool_name)) continue;
            try out.append(arena, t);
        }
        std.mem.sort(*const Tool, out.items, {}, struct {
            fn lt(_: void, a: *const Tool, b: *const Tool) bool {
                return a.transform.?.order < b.transform.?.order;
            }
        }.lt);
        return out.items;
    }

    /// Union of subprocess commands granted by enabled tool descriptors plus
    /// an explicit surface-local extension. Shared by the TUI escape and
    /// lifecycle hooks so the two policy callers cannot drift.
    pub fn execAllowUnion(self: *const Registry, arena: std.mem.Allocator, extra: []const []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.enabled) continue;
            for (entry.value_ptr.exec_allow) |command| {
                if (seen.contains(command)) continue;
                try seen.put(arena, command, {});
                try out.append(arena, command);
            }
        }
        for (extra) |command| {
            if (seen.contains(command)) continue;
            try seen.put(arena, command, {});
            try out.append(arena, command);
        }
        std.mem.sort([]const u8, out.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        return out.toOwnedSlice(arena);
    }

    fn strArray(arena: std.mem.Allocator, arr: json.Array) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (arr.items) |item| {
            switch (item) {
                .string => |s| try out.append(arena, s),
                else => {},
            }
        }
        return out.toOwnedSlice(arena);
    }
};

// ------------------------------------------------------------------- tests --

test "registry loads descriptors" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    const io = env.io();

    const dir = env.tmp.dir;

    try dir.createDirPath(io, "tools");
    try dir.writeFile(io, .{
        .sub_path = "tools/calculator.tool.json",
        .data =
        \\{
        \\  "name": "calculator",
        \\  "description": "arith",
        \\  "wasm": "calculator.wasm",
        \\  "input_schema": { "type": "object" },
        \\  "network_allow": ["api.example.com"]
        \\}
        ,
    });

    const reg = try Registry.load(io, arena, env.tmp.dir, &.{"tools"});
    const tool = reg.get("calculator").?;
    try std.testing.expectEqualStrings("calculator", tool.name);
    // Bare name: resolved beside the manifest, so a self-contained plugin
    // directory works wherever clanker is run from (see resolveWasmPath).
    try std.testing.expectEqualStrings("tools/calculator.wasm", tool.wasm);
    try std.testing.expectEqual(@as(usize, 1), tool.network_allow.len);
    try std.testing.expectEqualStrings("api.example.com", tool.network_allow[0]);
    try std.testing.expectEqual(@as(u64, 0), tool.fuel); // unset: sandbox default
}

test "a descriptor's fuel budget is parsed, and junk values keep the default" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    const io = env.io();

    const dir = env.tmp.dir;

    try dir.createDirPath(io, "tools");
    try dir.writeFile(io, .{
        .sub_path = "tools/thrifty.tool.json",
        .data =
        \\{ "name": "thrifty", "description": "d", "wasm": "t.wasm", "input_schema": {}, "fuel": 250000000 }
        ,
    });
    try dir.writeFile(io, .{
        .sub_path = "tools/sloppy.tool.json",
        .data =
        \\{ "name": "sloppy", "description": "d", "wasm": "s.wasm", "input_schema": {}, "fuel": "lots" }
        ,
    });

    const reg = try Registry.load(io, arena, env.tmp.dir, &.{"tools"});
    try std.testing.expectEqual(@as(u64, 250_000_000), reg.get("thrifty").?.fuel);
    try std.testing.expectEqual(@as(u64, 0), reg.get("sloppy").?.fuel);
}

test "plugin toggles disable optional tools but never core ones" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    const io = env.io();

    const dir = env.tmp.dir;

    try dir.createDirPath(io, "tools");
    try dir.writeFile(io, .{
        .sub_path = "tools/web_search.tool.json",
        .data =
        \\{ "name": "web_search", "description": "search", "wasm": "web_search.wasm", "input_schema": {} }
        ,
    });
    try dir.writeFile(io, .{
        .sub_path = "tools/status.tool.json",
        .data =
        \\{ "name": "status", "description": "status", "wasm": "status.wasm", "input_schema": {}, "internal": true }
        ,
    });
    try dir.createDirPath(io, "state");
    try dir.writeFile(io, .{
        .sub_path = plugins_state_path,
        .data = "{\"disabled\":[\"web_search\",\"status\"]}",
    });

    const reg = try Registry.load(io, arena, env.tmp.dir, &.{"tools"});
    try std.testing.expect(!reg.get("web_search").?.enabled);
    try std.testing.expect(reg.get("status").?.enabled); // core: toggle ignored

    // A disabled plugin leaves the catalog the model sees.
    const defs = try reg.toToolDefs(arena);
    try std.testing.expectEqual(@as(usize, 0), defs.len);
}

test "config overrides apply only to keys the descriptor opted in" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    const io = env.io();

    const dir = env.tmp.dir;

    try dir.createDirPath(io, "tools");
    // `max_depth` is offered for tuning; `secret` is not.
    try dir.writeFile(io, .{
        .sub_path = "tools/rlm.tool.json",
        .data =
        \\{ "name": "rlm", "description": "r", "wasm": "rlm.wasm", "input_schema": {},
        \\  "config": { "max_depth": 3, "secret": "keep" }, "config_editable": ["max_depth"] }
        ,
    });
    // Shares a binary with its siblings and selects behaviour with "op",
    // which is exactly why it opts nothing in.
    try dir.writeFile(io, .{
        .sub_path = "tools/chat_send.tool.json",
        .data =
        \\{ "name": "chat_send", "description": "c", "wasm": "chat.wasm", "input_schema": {},
        \\  "config": { "op": "send" } }
        ,
    });
    try dir.createDirPath(io, "state");
    try dir.writeFile(io, .{
        .sub_path = plugin_config_state_path,
        .data =
        \\{ "rlm": { "max_depth": 6, "secret": "stolen" }, "chat_send": { "op": "rooms" } }
        ,
    });

    const reg = try Registry.load(io, arena, env.tmp.dir, &.{"tools"});

    const rlm = reg.get("rlm").?;
    try std.testing.expectEqual(@as(i64, 6), rlm.config.object.get("max_depth").?.integer);
    // Not listed, so the descriptor value stands.
    try std.testing.expectEqualStrings("keep", rlm.config.object.get("secret").?.string);

    // No config_editable at all: the dispatch key is untouchable, so
    // chat_send cannot be turned into chat_rooms from state/.
    const chat = reg.get("chat_send").?;
    try std.testing.expectEqualStrings("send", chat.config.object.get("op").?.string);

    // config_json is precomputed once at load, after overrides apply: it must
    // reflect the overridden value, not the raw descriptor.
    try std.testing.expect(std.mem.find(u8, rlm.config_json, "\"max_depth\":6") != null);
    try std.testing.expect(std.mem.find(u8, rlm.config_json, "\"secret\":\"keep\"") != null);
}

test "a descriptor schema always reaches the provider with a type" {
    // Anthropic rejects the whole request (every tool, not just the bad one)
    // when any tool's input_schema has no "type". A manifest written with
    // OpenAI's "parameters" key, or with the type left out, used to do exactly
    // that and broke every run until the file was found by hand.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const openai_style =
        \\{ "name": "read_file", "description": "read", "wasm": "read_file.wasm",
        \\  "parameters": { "properties": { "path": { "type": "string" } }, "required": ["path"] } }
    ;
    const t = try Registry.parseDescriptor(arena, openai_style);
    try std.testing.expectEqualStrings("object", t.input_schema.object.get("type").?.string);
    // The rest of the schema survives the normalization.
    try std.testing.expect(t.input_schema.object.get("properties") != null);
    try std.testing.expectEqualStrings("path", t.input_schema.object.get("required").?.array.items[0].string);

    // A descriptor with no schema at all still yields something sendable.
    const bare =
        \\{ "name": "noargs", "description": "d", "wasm": "n.wasm" }
    ;
    const b = try Registry.parseDescriptor(arena, bare);
    try std.testing.expect(b.input_schema == .object);
}

test "prompt_guidance is parsed from the descriptor and rendered for catalog tools only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const guided =
        \\{ "name": "rfc", "description": "d", "wasm": "r.wasm",
        \\  "prompt_guidance": "GUIDANCE_MARKER open the cited source, not the note" }
    ;
    const t = try Registry.parseDescriptor(arena, guided);
    try std.testing.expectEqualStrings("GUIDANCE_MARKER open the cited source, not the note", t.prompt_guidance);

    // An internal tool's guidance never reaches the prompt, and a tool with no
    // guidance contributes no block.
    const hidden =
        \\{ "name": "webui", "description": "d", "wasm": "w.wasm",
        \\  "internal": true, "prompt_guidance": "HIDDEN_MARKER" }
    ;
    const plain =
        \\{ "name": "calc", "description": "d", "wasm": "c.wasm" }
    ;
    var reg = Registry{};
    try reg.tools.put(arena, t.name, t);
    try reg.tools.put(arena, (try Registry.parseDescriptor(arena, hidden)).name, try Registry.parseDescriptor(arena, hidden));
    try reg.tools.put(arena, (try Registry.parseDescriptor(arena, plain)).name, try Registry.parseDescriptor(arena, plain));

    const text = try reg.guidanceText(arena, null);
    try std.testing.expect(std.mem.find(u8, text, "### rfc") != null);
    try std.testing.expect(std.mem.find(u8, text, "GUIDANCE_MARKER") != null);
    try std.testing.expect(std.mem.find(u8, text, "HIDDEN_MARKER") == null);
    try std.testing.expect(std.mem.find(u8, text, "calc") == null);
}

test "a missing tools_dir yields an empty registry without error" {
    // Wrong path is a soft miss (warn + empty), not a hard fail, serve and
    // doctor both load this way. The log must not sole-blame zig build tools;
    // that phrasing is asserted by source grep in the change's verification.
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    const io = env.io();

    const reg = try Registry.load(io, arena, env.tmp.dir, &.{"no-such-tools-dir"});
    try std.testing.expectEqual(@as(usize, 0), reg.tools.count());
    try std.testing.expect(reg.get("webui") == null);
}

test "a two-entry tools_dir list loads both directories" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    const io = env.io();

    try env.tmp.dir.createDirPath(io, "builtins");
    try env.tmp.dir.createDirPath(io, "extra");
    try env.tmp.dir.writeFile(io, .{
        .sub_path = "builtins/alpha.tool.json",
        .data =
        \\{ "name": "alpha", "description": "a", "wasm": "alpha.wasm", "input_schema": {} }
        ,
    });
    try env.tmp.dir.writeFile(io, .{
        .sub_path = "extra/beta.tool.json",
        .data =
        \\{ "name": "beta", "description": "b", "wasm": "beta.wasm", "input_schema": {} }
        ,
    });

    const reg = try Registry.load(io, arena, env.tmp.dir, &.{ "builtins", "extra" });
    try std.testing.expectEqual(@as(usize, 2), reg.tools.count());
    try std.testing.expectEqualStrings("builtins/alpha.wasm", reg.get("alpha").?.wasm);
    try std.testing.expectEqualStrings("extra/beta.wasm", reg.get("beta").?.wasm);
}

test "a later tools_dir wins a cross-directory name collision" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    const io = env.io();

    try env.tmp.dir.createDirPath(io, "builtins");
    try env.tmp.dir.createDirPath(io, "override");
    try env.tmp.dir.writeFile(io, .{
        .sub_path = "builtins/echo.tool.json",
        .data =
        \\{ "name": "echo", "description": "stock", "wasm": "stock.wasm", "input_schema": {} }
        ,
    });
    try env.tmp.dir.writeFile(io, .{
        .sub_path = "override/echo.tool.json",
        .data =
        \\{ "name": "echo", "description": "local", "wasm": "local.wasm", "input_schema": {} }
        ,
    });

    const reg = try Registry.load(io, arena, env.tmp.dir, &.{ "builtins", "override" });
    try std.testing.expectEqual(@as(usize, 1), reg.tools.count());
    try std.testing.expectEqualStrings("local", reg.get("echo").?.description);
    try std.testing.expectEqualStrings("override/local.wasm", reg.get("echo").?.wasm);
}

test "a missing tools_dir list entry does not empty the rest" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    const io = env.io();

    try env.tmp.dir.createDirPath(io, "builtins");
    try env.tmp.dir.writeFile(io, .{
        .sub_path = "builtins/keep.tool.json",
        .data =
        \\{ "name": "keep", "description": "k", "wasm": "keep.wasm", "input_schema": {} }
        ,
    });

    const reg = try Registry.load(io, arena, env.tmp.dir, &.{ "no-such-extra", "builtins" });
    try std.testing.expectEqual(@as(usize, 1), reg.tools.count());
    try std.testing.expect(reg.get("keep") != null);
}

test "every shipped manifest carries a schema the provider accepts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, "tools/manifests", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tool.json")) continue;
        const raw = try dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20));
        const t = Registry.parseDescriptor(arena, raw) catch |err| {
            std.debug.print("manifest {s}: {s}\n", .{ entry.name, @errorName(err) });
            return err;
        };
        if (t.input_schema != .object or t.input_schema.object.get("type") == null) {
            std.debug.print("manifest {s} has no usable input_schema type\n", .{entry.name});
            return error.SchemaMissingType;
        }
    }
}

test "a tool that calls the model says so in its descriptor" {
    // The descriptor is what keeps a model-calling tool off the parallel
    // worker threads. subagent, rlm and translate all called the model with
    // nothing declared, so two of them in one turn ran side by side and raced
    // the shared access-token cache: one thread freeing a token the other had
    // just been handed. Reading the guests is the only way to catch the next
    // one, since nothing else connects a source file to its manifest.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var src_dir = std.Io.Dir.cwd().openDir(io, "tools/zig", .{ .iterate = true }) catch return error.SkipZigTest;
    defer src_dir.close(io);
    var man_dir = std.Io.Dir.cwd().openDir(io, "tools/manifests", .{}) catch return error.SkipZigTest;
    defer man_dir.close(io);

    // Every guest helper that reaches a model. `lib.llmSystem` and
    // `lib.llmMany` were missing, so `arena` (which only ever calls
    // llmSystem) and `compare` (llmMany) were both invisible to this check;
    // the exact hole it exists to close. The list lives in manifest.zig
    // because `clanker plugins validate` applies the same rule to a
    // third-party plugin directory; a helper added to lib.zig without a line
    // there silently re-opens the hole in both places at once.
    var it = src_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const body = src_dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch continue;

        if (!manifest.sourceCallsModel(body)) continue;

        const stem = entry.name[0 .. entry.name.len - ".zig".len];
        const manifest_name = try std.fmt.allocPrint(arena, "{s}.tool.json", .{stem});
        const raw = man_dir.readFileAlloc(io, manifest_name, arena, .limited(1 << 20)) catch continue;
        const t = try Registry.parseDescriptor(arena, raw);
        if (!t.llm and !t.sequential) {
            std.debug.print("{s} calls the model but its descriptor sets neither llm nor sequential\n", .{manifest_name});
            return error.ModelCallerNotDeclared;
        }
    }
}

test "confirm derives from exec/fs grants and the descriptor overrides it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No grants: nothing a viewer would call a write, so no confirm.
    const inert = try Registry.parseDescriptor(arena,
        \\{ "name": "calc", "description": "d", "wasm": "c.wasm" }
    );
    try std.testing.expect(!inert.needsConfirm());

    // An exec grant is a write in a viewer's eyes.
    const execs = try Registry.parseDescriptor(arena,
        \\{ "name": "git", "description": "d", "wasm": "g.wasm", "exec_allow": ["git"] }
    );
    try std.testing.expect(execs.needsConfirm());

    // So is any fs prefix: prefixes carry write access, never read-only.
    const writes = try Registry.parseDescriptor(arena,
        \\{ "name": "edit", "description": "d", "wasm": "e.wasm", "fs_prefixes": ["src"] }
    );
    try std.testing.expect(writes.needsConfirm());

    // A read-only tool opts out despite its grants, and an explicit opt-in
    // wins despite having none.
    const reader = try Registry.parseDescriptor(arena,
        \\{ "name": "read", "description": "d", "wasm": "r.wasm", "fs_prefixes": ["."], "confirm": false }
    );
    try std.testing.expect(!reader.needsConfirm());
    const delegator = try Registry.parseDescriptor(arena,
        \\{ "name": "sub", "description": "d", "wasm": "s.wasm", "confirm": true }
    );
    try std.testing.expect(delegator.needsConfirm());
}

test "a guest that writes files does not opt out of confirmation" {
    // The opt-out is documented as read-only-only, and plan mode refuses
    // exactly what needsConfirm says is write-capable, so a writing guest with
    // `"confirm": false` could change state from a run that must not change
    // any (config set rewrote config.local.toml in plan mode; schedule add
    // created recurring exec runs there). Reading the guests is the only way
    // to connect a source file to its manifest; the helper list lives in
    // manifest.zig beside `model_call_markers` for the same reason.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var src_dir = std.Io.Dir.cwd().openDir(io, "tools/zig", .{ .iterate = true }) catch return error.SkipZigTest;
    defer src_dir.close(io);
    var man_dir = std.Io.Dir.cwd().openDir(io, "tools/manifests", .{ .iterate = true }) catch return error.SkipZigTest;
    defer man_dir.close(io);

    // One pass over the manifests: keep each descriptor's wasm output name and
    // parsed form, so a writer whose module is `add_goal.wasm` finds
    // goal_add.tool.json even though the names disagree.
    const Manifest = struct { wasm: []const u8, tool: Tool };
    var manifests: std.ArrayList(Manifest) = .empty;
    var mit = man_dir.iterate();
    while (mit.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".tool.json")) continue;
        const raw = try man_dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20));
        const t = try Registry.parseDescriptor(arena, raw);
        try manifests.append(arena, .{ .wasm = t.wasm, .tool = t });
    }
    try std.testing.expect(manifests.items.len > 50);

    var writers_seen: usize = 0;
    var it = src_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const body = src_dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20)) catch continue;
        if (!manifest.sourceWritesFiles(body)) continue;
        writers_seen += 1;

        const stem = entry.name[0 .. entry.name.len - ".zig".len];
        for (manifests.items) |m| {
            const suffix = std.fmt.allocPrint(arena, "{s}.wasm", .{stem}) catch return error.OutOfMemory;
            if (!std.mem.endsWith(u8, m.wasm, suffix)) continue;
            if (m.tool.confirm) |c| {
                if (!c) {
                    std.debug.print("{s}.zig writes files but {s} sets \"confirm\": false\n", .{ stem, m.tool.name });
                    return error.WriterOptedOutOfConfirm;
                }
            }
            break;
        }
    }
    // The check is vacuous without guests it can judge.
    try std.testing.expect(writers_seen > 10);
}

test "descriptor statusline flag parses and defaults off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{ "name": "sl", "description": "d", "wasm": "sl.wasm", "input_schema": {}, "statusline": true, "internal": true }
    ;
    const t = try Registry.parseDescriptor(arena, raw);
    try std.testing.expect(t.statusline);
    try std.testing.expect(t.internal);

    // A descriptor without the flag defaults to off, and the tool stays a
    // normal LLM-visible tool.
    const bare =
        \\{ "name": "plain", "description": "d", "wasm": "p.wasm" }
    ;
    const b = try Registry.parseDescriptor(arena, bare);
    try std.testing.expect(!b.statusline);
    try std.testing.expect(!b.internal);
}

test "descriptor live_publish flag parses and defaults off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{ "name": "pub", "description": "d", "wasm": "p.wasm", "input_schema": {}, "live_publish": true, "internal": true }
    ;
    const t = try Registry.parseDescriptor(arena, raw);
    try std.testing.expect(t.live_publish);

    const bare =
        \\{ "name": "plain3", "description": "d", "wasm": "p.wasm" }
    ;
    const b = try Registry.parseDescriptor(arena, bare);
    try std.testing.expect(!b.live_publish);
}

test "descriptor turn_hook flag parses and defaults off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw =
        \\{ "name": "th", "description": "d", "wasm": "th.wasm", "input_schema": {}, "turn_hook": true, "internal": true }
    ;
    const t = try Registry.parseDescriptor(arena, raw);
    try std.testing.expect(t.turn_hook);

    const bare =
        \\{ "name": "plain2", "description": "d", "wasm": "p.wasm" }
    ;
    const b = try Registry.parseDescriptor(arena, bare);
    try std.testing.expect(!b.turn_hook);
}

test "a manifest with no version is v1, and an unknown version is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The ~90 manifests in this repo are all of this shape. Absence of the
    // key has to keep meaning v1 forever, or adding the key breaks every one
    // of them at once.
    const implicit = try Registry.parseDescriptor(arena,
        \\{ "name": "old", "description": "d", "wasm": "o.wasm" }
    );
    try std.testing.expectEqual(manifest.current_version, implicit.manifest_version);

    const explicit = try Registry.parseDescriptor(arena,
        \\{ "manifest_version": 1, "name": "new", "description": "d", "wasm": "n.wasm" }
    );
    try std.testing.expectEqual(@as(i64, 1), explicit.manifest_version);

    // A descriptor from a newer clanker is not read under this build's rules:
    // a key it spells differently would silently become a different policy.
    try std.testing.expectError(error.UnsupportedManifestVersion, Registry.parseDescriptor(arena,
        \\{ "manifest_version": 2, "name": "future", "description": "d", "wasm": "f.wasm" }
    ));
    try std.testing.expectError(error.ManifestVersionNotInteger, Registry.parseDescriptor(arena,
        \\{ "manifest_version": "1", "name": "junk", "description": "d", "wasm": "j.wasm" }
    ));
}

test "a bare wasm name resolves beside its manifest; a path never moves" {
    var env: test_env.Env = .init();
    defer env.deinit();
    const arena = env.arena();

    const io = env.io();

    // What a third-party package looks like: one directory holding the
    // manifest and the module, with no idea what clanker's cwd will be.
    try env.tmp.dir.createDirPath(io, "vendor/hello");
    try env.tmp.dir.writeFile(io, .{
        .sub_path = "vendor/hello/hello.tool.json",
        .data =
        \\{ "name": "hello", "description": "d", "wasm": "hello.wasm", "input_schema": {"type":"object"} }
        ,
    });
    // An in-tree manifest names a path from the repo root and must keep
    // meaning exactly that.
    try env.tmp.dir.writeFile(io, .{
        .sub_path = "vendor/hello/rooted.tool.json",
        .data =
        \\{ "name": "rooted", "description": "d", "wasm": "zig-out/tools/rooted.wasm", "input_schema": {"type":"object"} }
        ,
    });

    const reg = try Registry.load(io, arena, env.tmp.dir, &.{"vendor/hello"});
    try std.testing.expectEqualStrings("vendor/hello/hello.wasm", reg.get("hello").?.wasm);
    try std.testing.expectEqualStrings("zig-out/tools/rooted.wasm", reg.get("rooted").?.wasm);

    // A trailing slash on tools_dir must not double up.
    try std.testing.expectEqualStrings(
        "vendor/hello/hello.wasm",
        try Registry.resolveWasmPath(arena, "vendor/hello/", "hello.wasm"),
    );
}

test "every shipped manifest validates clean, warnings included" {
    // The loader is deliberately forgiving, so a typo'd key or a dead grant
    // costs nothing at load and shows up as a tool that quietly does not work.
    // This is the gate that keeps the repo's own manifests honest against the
    // format `clanker plugins validate` holds third parties to.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, "tools/manifests", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);

    var bad: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".tool.json")) continue;
        const raw = try dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20));
        const rep = try manifest.validate(arena, entry.name, raw);
        if (rep.findings.len == 0) continue;
        bad += 1;
        std.debug.print("{s}", .{try rep.render(arena)});
    }
    if (bad > 0) return error.ManifestNotClean;
}

test "turnHookTools returns only enabled turn_hook tools, sorted by name" {
    var reg = Registry{};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try reg.tools.put(arena, "z_hook", .{ .name = "z_hook", .description = "d", .wasm = "z.wasm", .input_schema = .{ .object = .{} }, .turn_hook = true, .internal = true });
    try reg.tools.put(arena, "a_hook", .{ .name = "a_hook", .description = "d", .wasm = "a.wasm", .input_schema = .{ .object = .{} }, .turn_hook = true, .internal = true });
    try reg.tools.put(arena, "disabled_hook", .{ .name = "disabled_hook", .description = "d", .wasm = "d.wasm", .input_schema = .{ .object = .{} }, .turn_hook = true, .internal = true, .enabled = false });
    try reg.tools.put(arena, "not_a_hook", .{ .name = "not_a_hook", .description = "d", .wasm = "n.wasm", .input_schema = .{ .object = .{} } });

    const hooks = try reg.turnHookTools(arena);
    try std.testing.expectEqual(@as(usize, 2), hooks.len);
    try std.testing.expectEqualStrings("a_hook", hooks[0].name);
    try std.testing.expectEqualStrings("z_hook", hooks[1].name);
}

test "fuzz: no byte sequence crashes the descriptor parser" {
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.slice(&buf);
            const input = buf[0..len];

            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            _ = Registry.parseDescriptor(arena_state.allocator(), input) catch return;
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{});
}

test "the registry cache stamp changes when a descriptor is added, edited, or toggled" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;
    try dir.createDirPath(io, "tools");
    try dir.createDirPath(io, "state");

    const descriptor =
        \\{"name":"calculator","description":"arith","wasm":"calculator.wasm",
        \\ "input_schema":{"type":"object"}}
    ;
    try dir.writeFile(io, .{ .sub_path = "tools/calculator.tool.json", .data = descriptor });

    const dirs = [_][]const u8{"tools"};
    const first = Registry.cacheStamp(io, dir, &dirs);
    // Re-stamping an untouched tree must hit, or the cache never serves.
    try std.testing.expectEqual(first, Registry.cacheStamp(io, dir, &dirs));

    // A second descriptor: the name and its stat both fold in.
    try dir.writeFile(io, .{ .sub_path = "tools/echo.tool.json", .data = descriptor });
    const with_echo = Registry.cacheStamp(io, dir, &dirs);
    try std.testing.expect(with_echo != first);

    // An in-place edit of an existing descriptor changes its size, which is
    // what a directory mtime alone would have missed.
    try dir.writeFile(io, .{ .sub_path = "tools/echo.tool.json", .data = descriptor ++ "\n" });
    const edited = Registry.cacheStamp(io, dir, &dirs);
    try std.testing.expect(edited != with_echo);

    // `clanker plugins off` writes only this file; the stamp must see it.
    try dir.writeFile(io, .{ .sub_path = plugins_state_path, .data = "{\"disabled\":[\"echo\"]}" });
    try std.testing.expect(Registry.cacheStamp(io, dir, &dirs) != edited);
}

test "tool defs are sorted by name so prompts are stable across load order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reg = Registry{};
    try reg.tools.put(arena, "zeta", .{ .name = "zeta", .description = "d", .wasm = "x.wasm", .input_schema = .{ .object = .{} } });
    try reg.tools.put(arena, "alpha", .{ .name = "alpha", .description = "d", .wasm = "x.wasm", .input_schema = .{ .object = .{} } });
    try reg.tools.put(arena, "mid", .{ .name = "mid", .description = "d", .wasm = "x.wasm", .input_schema = .{ .object = .{} } });

    const defs = try reg.toToolDefs(arena);
    try std.testing.expectEqual(@as(usize, 3), defs.len);
    try std.testing.expectEqualStrings("alpha", defs[0].name);
    try std.testing.expectEqualStrings("mid", defs[1].name);
    try std.testing.expectEqualStrings("zeta", defs[2].name);

    const core = [_][]const u8{ "zeta", "alpha", "mid" };
    var revealed: std.array_hash_map.String(void) = .empty;
    const lazy = try reg.lazyToolDefs(arena, &core, &revealed, null);
    try std.testing.expectEqual(@as(usize, 4), lazy.len);
    try std.testing.expectEqualStrings("load_tools", lazy[0].name);
    try std.testing.expectEqualStrings("alpha", lazy[1].name);
    try std.testing.expectEqualStrings("mid", lazy[2].name);
    try std.testing.expectEqualStrings("zeta", lazy[3].name);
}

test "an active preset hides denied tools from the offered list and the catalog" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var reg = Registry{};
    try reg.tools.put(arena, "read_file", .{ .name = "read_file", .description = "read", .llm_description = "read a file", .wasm = "x.wasm", .input_schema = .{ .object = .{} } });
    try reg.tools.put(arena, "edit_file", .{ .name = "edit_file", .description = "edit", .llm_description = "edit a file", .wasm = "x.wasm", .input_schema = .{ .object = .{} }, .prompt_guidance = "be careful" });
    try reg.tools.put(arena, "kanban_add", .{ .name = "kanban_add", .description = "card", .llm_description = "add a card", .wasm = "x.wasm", .input_schema = .{ .object = .{} } });

    const research = preset_mod.Preset{ .tools_deny = &.{ "edit_file", "kanban_*" } };
    const core = [_][]const u8{ "read_file", "edit_file", "kanban_add" };
    var revealed: std.array_hash_map.String(void) = .empty;

    // The offered list is the assertion PRD 0033's "neither offered nor
    // callable" turns on: the dispatch gate refusing later is not enough.
    const lazy = try reg.lazyToolDefs(arena, &core, &revealed, &research);
    try std.testing.expectEqual(@as(usize, 2), lazy.len);
    try std.testing.expectEqualStrings("load_tools", lazy[0].name);
    try std.testing.expectEqualStrings("read_file", lazy[1].name);

    // The system prompt's catalog text is the other half: it used to
    // enumerate every registry tool, denied ones included.
    const catalog = try reg.catalogText(arena, &revealed, &research);
    try std.testing.expect(std.mem.find(u8, catalog, "read_file") != null);
    try std.testing.expect(std.mem.find(u8, catalog, "edit_file") == null);
    try std.testing.expect(std.mem.find(u8, catalog, "kanban_add") == null);

    // And the per-tool usage rules, which are rendered from the whole
    // registry rather than the offered defs.
    const guidance = try reg.guidanceText(arena, &research);
    try std.testing.expectEqualStrings("", guidance);

    // A preset with a non-empty allow list that does not name `load_tools`
    // still gets it: it is the catalog's only door.
    const minimal = preset_mod.Preset{ .tools_allow = &.{"read_file"} };
    const only_read = try reg.lazyToolDefs(arena, &core, &revealed, &minimal);
    try std.testing.expectEqual(@as(usize, 2), only_read.len);
    try std.testing.expectEqualStrings("load_tools", only_read[0].name);
    try std.testing.expectEqualStrings("read_file", only_read[1].name);
    try std.testing.expect(!Registry.presetHides(&minimal, Registry.load_tool_name));
    try std.testing.expect(Registry.presetHides(&minimal, "edit_file"));
    // No preset hides nothing.
    try std.testing.expect(!Registry.presetHides(null, "edit_file"));
}
