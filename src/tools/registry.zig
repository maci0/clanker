//! Tool registry: loads `*.tool.json` descriptors from the tools directory.
//! Descriptors are the agent-editable metadata (name, description, JSON
//! schema, sandbox policy); the WASM module itself implements behavior.

const std = @import("std");
const json = std.json;
const types = @import("../llm/types.zig");
const log = @import("../util/log.zig");

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// Wasm file name relative to the tools directory.
    wasm: []const u8,
    input_schema: json.Value,
    /// Hosts this tool may reach via ck_http (empty = no network).
    network_allow: []const []const u8 = &.{},
    /// Directory prefixes (relative to the sandbox root) the tool may access
    /// via ck_fs_*; empty = filesystem denied.
    fs_prefixes: []const []const u8 = &.{},
};

pub const Registry = struct {
    tools: std.StringArrayHashMapUnmanaged(Tool) = .empty,

    pub fn load(io: std.Io, arena: std.mem.Allocator, base: std.Io.Dir, tools_dir: []const u8) !Registry {
        var reg = Registry{};

        var dir = base.openDir(io, tools_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                log.log(.warn, "tools dir '{s}' not found; run `zig build tools`", .{tools_dir});
                return reg;
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
            const tool = parseDescriptor(arena, raw, tools_dir) catch |err| {
                log.log(.warn, "invalid tool descriptor '{s}': {s}", .{ entry.name, @errorName(err) });
                continue;
            };
            try reg.tools.put(arena, tool.name, tool);
        }
        return reg;
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

    /// Converts registry tools into LLM ToolDefs (in the given arena).
    pub fn toToolDefs(self: *const Registry, arena: std.mem.Allocator) ![]types.ToolDef {
        var out: std.ArrayList(types.ToolDef) = .empty;
        var it = self.tools.iterator();
        while (it.next()) |kv| {
            const t = kv.value_ptr.*;
            try out.append(arena, .{
                .name = t.name,
                .description = t.description,
                .input_schema = t.input_schema,
            });
        }
        return out.toOwnedSlice(arena);
    }

    fn parseDescriptor(arena: std.mem.Allocator, raw: []const u8, tools_dir: []const u8) !Tool {
        const v = try json.parseFromSliceLeaky(json.Value, arena, raw, .{ .ignore_unknown_fields = true });
        const obj = switch (v) {
            .object => |o| o,
            else => return error.DescriptorNotObject,
        };
        var t = Tool{
            .name = try strField(obj, "name"),
            .description = try strField(obj, "description"),
            .wasm = try strField(obj, "wasm"),
            .input_schema = obj.get("input_schema") orelse .{ .object = .empty },
        };
        _ = tools_dir;
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
        return t;
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

    fn strField(obj: json.ObjectMap, key: []const u8) ![]const u8 {
        const v = obj.get(key) orelse return error.MissingField;
        return switch (v) {
            .string => |s| s,
            else => error.FieldNotString,
        };
    }
};

// ------------------------------------------------------------------- tests --

test "registry loads descriptors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

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

    const reg = try Registry.load(io, arena, tmp.dir, "tools");
    const tool = reg.get("calculator").?;
    try std.testing.expectEqualStrings("calculator", tool.name);
    try std.testing.expectEqualStrings("calculator.wasm", tool.wasm);
    try std.testing.expectEqual(@as(usize, 1), tool.network_allow.len);
    try std.testing.expectEqualStrings("api.example.com", tool.network_allow[0]);
}
