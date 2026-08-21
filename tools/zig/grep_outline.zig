//! Enclosing-symbol walk for grep hits (ADR 0036 / PRD 0047).
//! Host-tested helper; repo_search imports the sibling file.

const std = @import("std");

pub const Symbol = struct {
    kind: []const u8,
    name: []const u8,
    decl_line: u32,
};

/// 1-based `line_no`. Nearest declaration that contains the line: a decl
/// on the line itself, else the last decl whose indent is strictly less
/// than the hit's (so a local `const` does not hide the enclosing `fn`).
/// Slices alias `source`. Allocates nothing.
pub fn enclosingSymbol(source: []const u8, line_no: u32) ?Symbol {
    if (line_no == 0) return null;
    const target_indent = indentOfLine(source, line_no) orelse return null;
    var last: ?Symbol = null;
    var current_line: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    var saw_target = false;
    while (i <= source.len) : (i += 1) {
        if (i != source.len and source[i] != '\n') continue;
        var line = source[start..i];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (current_line == line_no) saw_target = true;
        if (current_line > line_no) break;
        if (parseDecl(line)) |d| {
            const ind = leadingIndent(line);
            if (current_line == line_no or ind < target_indent) {
                last = .{ .kind = d.kind, .name = d.name, .decl_line = current_line };
            }
        }
        current_line += 1;
        start = i + 1;
    }
    if (!saw_target) return null;
    return last;
}

fn indentOfLine(source: []const u8, line_no: u32) ?usize {
    var current_line: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= source.len) : (i += 1) {
        if (i != source.len and source[i] != '\n') continue;
        if (current_line == line_no) {
            var line = source[start..i];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            return leadingIndent(line);
        }
        current_line += 1;
        start = i + 1;
    }
    return null;
}

fn leadingIndent(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c == ' ' or c == '\t') n += 1 else break;
    }
    return n;
}

const Decl = struct { kind: []const u8, name: []const u8 };

fn parseDecl(line: []const u8) ?Decl {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len == 0) return null;
    if (std.mem.startsWith(u8, t, "//") or std.mem.startsWith(u8, t, "#")) return null;
    if (parseZigDecl(t)) |d| return d;
    return parseGenericDecl(t);
}

fn parseZigDecl(t: []const u8) ?Decl {
    var rest = t;
    if (std.mem.startsWith(u8, rest, "pub")) {
        const after = rest[3..];
        if (after.len == 0 or (after[0] != ' ' and after[0] != '\t')) return null;
        rest = std.mem.trimStart(u8, after, " \t");
    }
    if (std.mem.startsWith(u8, rest, "export")) {
        const after = rest[6..];
        if (after.len == 0 or (after[0] != ' ' and after[0] != '\t')) return null;
        rest = std.mem.trimStart(u8, after, " \t");
    }
    const kinds = [_][]const u8{ "fn", "const", "var", "struct", "enum", "union" };
    for (kinds) |kind| {
        if (!std.mem.startsWith(u8, rest, kind)) continue;
        const after = rest[kind.len..];
        if (after.len == 0 or (after[0] != ' ' and after[0] != '\t' and after[0] != '(')) continue;
        const name_src = std.mem.trimStart(u8, after, " \t");
        const name = ident(name_src) orelse return null;
        return .{ .kind = kind, .name = name };
    }
    return null;
}

fn parseGenericDecl(t: []const u8) ?Decl {
    const kinds = [_][]const u8{ "function", "def", "class", "fn" };
    for (kinds) |kind| {
        if (!std.mem.startsWith(u8, t, kind)) continue;
        const after = t[kind.len..];
        if (after.len == 0 or (after[0] != ' ' and after[0] != '\t')) continue;
        const name_src = std.mem.trimStart(u8, after, " \t");
        const name = ident(name_src) orelse return null;
        return .{ .kind = kind, .name = name };
    }
    return null;
}

/// Attach symbol / symbol_kind / symbol_line when a declaration encloses
/// `line_no`. No-op when none exists. Slices alias `source`.
pub fn writeSymbolFields(s: anytype, source: []const u8, line_no: u32) !void {
    const sym = enclosingSymbol(source, line_no) orelse return;
    try s.objectField("symbol");
    try s.write(sym.name);
    try s.objectField("symbol_kind");
    try s.write(sym.kind);
    try s.objectField("symbol_line");
    try s.write(sym.decl_line);
}

fn jsonLineNumber(v: std.json.Value) u32 {
    return switch (v) {
        .integer => |n| std.math.cast(u32, n) orelse 0,
        .number_string => |ns| std.fmt.parseInt(u32, ns, 10) catch 0,
        .string => |str| std.fmt.parseInt(u32, str, 10) catch 0,
        else => 0,
    };
}

fn jsonText(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

/// Rewrite a native `ck_fs_grep` JSON array into match objects with outline.
/// `ctx.readFile(path)` returns the file bytes or null (hit without outline).
pub fn writeNativeMatches(s: anytype, native: std.json.Value, ctx: anytype) !void {
    try s.beginArray();
    if (native == .array) {
        for (native.array.items) |item| {
            try writeOneNativeMatch(s, item, ctx);
        }
    }
    try s.endArray();
}

fn writeOneNativeMatch(s: anytype, item: std.json.Value, ctx: anytype) !void {
    if (item != .object) return;
    const file_path = jsonText(item.object.get("file") orelse return);
    const line_number = jsonLineNumber(item.object.get("line") orelse .{ .integer = 0 });
    const text = jsonText(item.object.get("text") orelse .{ .string = "" });
    try s.beginObject();
    try s.objectField("file");
    try s.write(file_path);
    try s.objectField("line");
    try s.write(line_number);
    try s.objectField("text");
    try s.write(text);
    if (file_path.len > 0 and line_number > 0) {
        if (ctx.readFile(file_path)) |src| {
            try writeSymbolFields(s, src, line_number);
        }
    }
    try s.endObject();
}

fn ident(s: []const u8) ?[]const u8 {
    if (s.len == 0) return null;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return null;
    var n: usize = 1;
    while (n < s.len) : (n += 1) {
        const c = s[n];
        if (!std.ascii.isAlphanumeric(c) and c != '_') break;
    }
    return s[0..n];
}

test "enclosingSymbol finds a Zig fn above the hit" {
    const src =
        \\const std = @import("std");
        \\
        \\pub fn foo() void {
        \\    const x = 1;
        \\    _ = x;
        \\}
        \\
    ;
    const sym = enclosingSymbol(src, 5) orelse return error.MissingSymbol;
    try std.testing.expectEqualStrings("fn", sym.kind);
    try std.testing.expectEqualStrings("foo", sym.name);
    try std.testing.expectEqual(@as(u32, 3), sym.decl_line);
}

test "enclosingSymbol on the fn line is the fn itself" {
    const src =
        \\pub fn foo() void {
        \\    return;
        \\}
        \\
    ;
    const sym = enclosingSymbol(src, 1) orelse return error.MissingSymbol;
    try std.testing.expectEqualStrings("foo", sym.name);
}

test "enclosingSymbol is null when no declaration exists" {
    const src = "const x = 1;\n";
    // line 1 is itself a const; a hit with no prior decl besides that is fine.
    // A file of only comments has none:
    try std.testing.expect(enclosingSymbol("// hi\n// there\n", 2) == null);
    _ = src;
}

test "enclosingSymbol recognizes a Python def fallback" {
    const src =
        \\def bar():
        \\    return 1
        \\
    ;
    const sym = enclosingSymbol(src, 2) orelse return error.MissingSymbol;
    try std.testing.expectEqualStrings("def", sym.kind);
    try std.testing.expectEqualStrings("bar", sym.name);
    try std.testing.expectEqual(@as(u32, 1), sym.decl_line);
}

test "enclosingSymbol line 0 is null" {
    try std.testing.expect(enclosingSymbol("fn foo() void {}\n", 0) == null);
}

test "writeNativeMatches attaches enclosing outline to host-fallback hits" {
    const native_json =
        \\[{"file":"t.zig","line":3,"text":"    _ = x;"}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, native_json, .{});
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer };
    try writeNativeMatches(&s, parsed.value, struct {
        pub fn readFile(path: []const u8) ?[]const u8 {
            if (!std.mem.eql(u8, path, "t.zig")) return null;
            return
            \\pub fn foo() void {
            \\    const x = 1;
            \\    _ = x;
            \\}
            \\
            ;
        }
    });
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "\"symbol\":\"foo\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "\"symbol_kind\":\"fn\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "\"symbol_line\":1") != null);
}

test "writeNativeMatches omits outline when the file cannot be read" {
    const native_json =
        \\[{"file":"missing.zig","line":3,"text":"    _ = x;"}]
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, native_json, .{});
    defer parsed.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var s = std.json.Stringify{ .writer = &out.writer };
    try writeNativeMatches(&s, parsed.value, struct {
        pub fn readFile(_: []const u8) ?[]const u8 {
            return null;
        }
    });
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "\"file\":\"missing.zig\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "symbol") == null);
}
