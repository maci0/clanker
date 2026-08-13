//! Pure grouping / validation / topo-sort for `smart_commit`.

const std = @import("std");

pub const types = [_][]const u8{
    "feat", "fix", "docs", "style", "refactor", "perf", "test", "build", "ci", "chore", "revert",
};

pub fn isLockFile(path: []const u8) bool {
    if (std.mem.endsWith(u8, path, ".lock")) return true;
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, base, "package-lock.json") or
        std.mem.eql(u8, base, "yarn.lock") or
        std.mem.eql(u8, base, "Cargo.lock") or
        std.mem.eql(u8, base, "go.sum") or
        std.mem.eql(u8, base, "zig.lock");
}

pub fn validMessage(msg: []const u8) bool {
    for (types) |t| {
        if (!std.mem.startsWith(u8, msg, t)) continue;
        var rest = msg[t.len..];
        if (rest.len > 0 and rest[0] == '(') {
            const close = std.mem.indexOfScalar(u8, rest, ')') orelse return false;
            rest = rest[close + 1 ..];
        }
        if (rest.len < 3 or rest[0] != ':' or rest[1] != ' ') return false;
        return rest[2] != ' ';
    }
    return false;
}

pub fn isTestPath(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "test_") != null or
        std.mem.indexOf(u8, path, "_test.") != null or
        std.mem.indexOf(u8, path, ".test.") != null or
        std.mem.indexOf(u8, path, "tests/") != null;
}

pub fn isDocPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or std.mem.startsWith(u8, path, "docs/");
}

pub fn isConfigPath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.eql(u8, base, "config.toml") or
        std.mem.endsWith(u8, path, ".toml") or
        std.mem.endsWith(u8, path, ".yaml") or
        (std.mem.endsWith(u8, path, ".json") and std.mem.indexOfScalar(u8, path, '/') == null);
}

pub fn fileRank(path: []const u8) u8 {
    if (isTestPath(path)) return 1;
    if (isDocPath(path)) return 2;
    if (isConfigPath(path)) return 3;
    return 0;
}

pub fn sortFiles(files: [][]const u8) void {
    std.mem.sort([]const u8, files, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            const ra = fileRank(a);
            const rb = fileRank(b);
            if (ra != rb) return ra < rb;
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
}

pub const Group = struct {
    message: []const u8,
    files: []const []const u8,
};

pub const OrderError = error{ PartialCycle, DegenerateCycle, OutOfMemory };

/// Kahn topo sort. `deps[i]` lists group indices that must come before i.
pub fn topoSort(arena: std.mem.Allocator, n: usize, deps: []const []const usize) OrderError![]usize {
    var indeg = try arena.alloc(usize, n);
    @memset(indeg, 0);
    for (deps) |ds| {
        for (ds) |_| {}
    }
    for (deps) |ds| for (ds) |_| {};
    for (0..n) |i| {
        for (deps[i]) |_| indeg[i] += 1;
    }
    var ready: std.ArrayList(usize) = .empty;
    for (indeg, 0..) |d, i| {
        if (d == 0) try ready.append(arena, i);
    }
    var out: std.ArrayList(usize) = .empty;
    while (ready.items.len > 0) {
        const i = ready.pop().?;
        try out.append(arena, i);
        for (0..n) |j| {
            for (deps[j]) |d| {
                if (d == i) {
                    indeg[j] -= 1;
                    if (indeg[j] == 0) try ready.append(arena, j);
                }
            }
        }
    }
    if (out.items.len == n) return out.toOwnedSlice(arena);
    if (out.items.len == 0) return error.DegenerateCycle;
    return error.PartialCycle;
}

pub fn references(src: []const u8, other_file: []const u8) bool {
    const base = std.fs.path.basename(other_file);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    if (std.mem.indexOf(u8, src, other_file) != null) return true;
    if (std.mem.indexOf(u8, src, stem) != null and
        (std.mem.indexOf(u8, src, "import") != null or
            std.mem.indexOf(u8, src, "@import") != null or
            std.mem.indexOf(u8, src, "require") != null or
            std.mem.indexOf(u8, src, "#include") != null)) return true;
    return false;
}

test "lock files are excluded" {
    try std.testing.expect(isLockFile("foo.lock"));
    try std.testing.expect(isLockFile("go.sum"));
    try std.testing.expect(isLockFile("package-lock.json"));
    try std.testing.expect(!isLockFile("src/foo.zig"));
}

test "conventional commit regex" {
    try std.testing.expect(validMessage("feat: add x"));
    try std.testing.expect(validMessage("fix(parser): handle empty"));
    try std.testing.expect(!validMessage("added a thing"));
    try std.testing.expect(!validMessage("feat:"));
}

test "source files rank before tests and docs" {
    var files = [_][]const u8{ "docs/a.md", "src/a.zig", "tests/a_test.zig" };
    sortFiles(&files);
    try std.testing.expectEqualStrings("src/a.zig", files[0]);
    try std.testing.expectEqualStrings("tests/a_test.zig", files[1]);
    try std.testing.expectEqualStrings("docs/a.md", files[2]);
}

test "topo sort orders a dependency first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var d0 = [_]usize{};
    var d1 = [_]usize{0};
    const deps = [_][]const usize{ &d0, &d1 };
    const order = try topoSort(arena, 2, &deps);
    try std.testing.expectEqual(@as(usize, 0), order[0]);
    try std.testing.expectEqual(@as(usize, 1), order[1]);
}

test "partial cycle is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var d0 = [_]usize{1};
    var d1 = [_]usize{0};
    var d2 = [_]usize{};
    const deps = [_][]const usize{ &d0, &d1, &d2 };
    try std.testing.expectError(error.PartialCycle, topoSort(arena_state.allocator(), 3, &deps));
}

test "all-groups cycle is degenerate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var d0 = [_]usize{1};
    var d1 = [_]usize{0};
    const deps = [_][]const usize{ &d0, &d1 };
    try std.testing.expectError(error.DegenerateCycle, topoSort(arena_state.allocator(), 2, &deps));
}
