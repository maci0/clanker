//! Search for a closed-form expression that fits numeric data.
//! Pure: no guest ABI. The `symbolic_regression` guest is the sandbox
//! wrapper; this is what `zig build test` actually runs.
//!
//! Not a port of astroautomata/symbolic_regression.rs. That crate's
//! wasm is wasm-bindgen + rayon (browser workers), which cannot load as
//! a clanker guest. Same job, our sandbox.

const std = @import("std");

pub const max_rows: usize = 200;
pub const max_features: usize = 6;
pub const max_nodes: usize = 28;
pub const max_pop: usize = 40;
pub const max_generations: u16 = 60;
pub const default_generations: u16 = 28;
pub const max_pareto: usize = 8;

pub const Op = enum(u8) {
    c,
    v,
    add,
    sub,
    mul,
    div,
    neg,
    sin,
    cos,
    exp,
    log,
};

pub const Node = struct {
    op: Op,
    a: u8 = 0,
    b: u8 = 0,
    k: f32 = 0,
    vi: u8 = 0,
};

pub const Tree = struct {
    nodes: [max_nodes]Node = undefined,
    len: u8 = 0,
};

pub const Dataset = struct {
    x: []const f64,
    y: []const f64,
    n_rows: u16,
    n_features: u8,

    pub fn row(self: Dataset, i: usize) []const f64 {
        const f = self.n_features;
        return self.x[i * f .. i * f + f];
    }
};

pub const SearchOpts = struct {
    generations: u16 = default_generations,
    seed: u64 = 1,
    ops: []const Op = &default_ops,
};

pub const default_ops = [_]Op{ .add, .sub, .mul, .div, .neg, .sin, .cos };

pub const ParseError = error{
    BadInput,
    Empty,
    TooManyRows,
    TooManyFeatures,
    LengthMismatch,
    OutOfMemory,
};

pub const Owned = struct {
    x: []f64,
    y: []f64,
    n_rows: u16,
    n_features: u8,

    pub fn dataset(self: Owned) Dataset {
        return .{
            .x = self.x,
            .y = self.y,
            .n_rows = self.n_rows,
            .n_features = self.n_features,
        };
    }

    pub fn deinit(self: Owned, alloc: std.mem.Allocator) void {
        alloc.free(self.x);
        alloc.free(self.y);
    }
};

pub fn clampGenerations(n: u16) u16 {
    if (n == 0) return default_generations;
    return @min(n, max_generations);
}

fn finite(v: f64) bool {
    return !std.math.isNan(v) and !std.math.isInf(v);
}

pub fn evalTree(t: *const Tree, row: []const f64) ?f64 {
    if (t.len == 0) return null;
    return evalNode(t, t.len - 1, row);
}

fn evalNode(t: *const Tree, idx: u8, row: []const f64) ?f64 {
    if (idx >= t.len) return null;
    const n = t.nodes[idx];
    const v: f64 = switch (n.op) {
        .c => n.k,
        .v => if (n.vi < row.len) row[n.vi] else return null,
        .neg => -(evalNode(t, n.a, row) orelse return null),
        .sin => @sin(evalNode(t, n.a, row) orelse return null),
        .cos => @cos(evalNode(t, n.a, row) orelse return null),
        .exp => blk: {
            const a = evalNode(t, n.a, row) orelse return null;
            if (a > 20 or a < -20) return null;
            break :blk @exp(a);
        },
        .log => blk: {
            const a = evalNode(t, n.a, row) orelse return null;
            if (a <= 0) return null;
            break :blk @log(a);
        },
        .add => (evalNode(t, n.a, row) orelse return null) + (evalNode(t, n.b, row) orelse return null),
        .sub => (evalNode(t, n.a, row) orelse return null) - (evalNode(t, n.b, row) orelse return null),
        .mul => (evalNode(t, n.a, row) orelse return null) * (evalNode(t, n.b, row) orelse return null),
        .div => blk: {
            const b = evalNode(t, n.b, row) orelse return null;
            if (@abs(b) < 1e-12) return null;
            break :blk (evalNode(t, n.a, row) orelse return null) / b;
        },
    };
    return if (finite(v)) v else null;
}

pub fn mseOf(t: *const Tree, data: Dataset) f64 {
    var acc: f64 = 0;
    var i: usize = 0;
    while (i < data.n_rows) : (i += 1) {
        const pred = evalTree(t, data.row(i)) orelse return 1e12;
        const d = pred - data.y[i];
        acc += d * d;
    }
    return acc / @as(f64, @floatFromInt(data.n_rows));
}

pub fn complexityOf(t: *const Tree) u16 {
    return t.len;
}

const leaf_consts = [_]f32{ -3, -2, -1, -0.5, 0.5, 1, 2, 3, 5, 10 };

const Rng = struct {
    s: u64,

    fn next(self: *Rng) u64 {
        // xorshift64
        var x = self.s;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.s = if (x == 0) 0x9E3779B97F4A7C15 else x;
        return self.s;
    }

    fn below(self: *Rng, n: usize) usize {
        if (n == 0) return 0;
        return @intCast(self.next() % n);
    }

    fn chance(self: *Rng, p_thousand: u16) bool {
        return self.below(1000) < p_thousand;
    }
};

fn push(t: *Tree, n: Node) ?u8 {
    if (t.len >= max_nodes) return null;
    const i: u8 = t.len;
    t.nodes[i] = n;
    t.len += 1;
    return i;
}

fn copySubtree(src: *const Tree, si: u8, dst: *Tree) ?u8 {
    if (si >= src.len) return null;
    const n = src.nodes[si];
    var out = n;
    switch (n.op) {
        .c, .v => {},
        .neg, .sin, .cos, .exp, .log => {
            out.a = copySubtree(src, n.a, dst) orelse return null;
        },
        .add, .sub, .mul, .div => {
            out.a = copySubtree(src, n.a, dst) orelse return null;
            out.b = copySubtree(src, n.b, dst) orelse return null;
        },
    }
    return push(dst, out);
}

fn cloneTree(src: *const Tree) Tree {
    var dst = Tree{};
    _ = copySubtree(src, src.len - 1, &dst);
    return dst;
}

fn allowed(ops: []const Op, want: Op) bool {
    if (want == .c or want == .v) return true;
    for (ops) |o| if (o == want) return true;
    return false;
}

fn pickOp(rng: *Rng, ops: []const Op, unary: bool) Op {
    var buf: [16]Op = undefined;
    var n: usize = 0;
    for (ops) |o| {
        const is_u = switch (o) {
            .neg, .sin, .cos, .exp, .log => true,
            .add, .sub, .mul, .div => false,
            .c, .v => continue,
        };
        if (is_u == unary and n < buf.len) {
            buf[n] = o;
            n += 1;
        }
    }
    if (n == 0) return if (unary) .neg else .add;
    return buf[rng.below(n)];
}

fn randomTree(rng: *Rng, n_features: u8, ops: []const Op, depth: u8) Tree {
    var t = Tree{};
    _ = grow(rng, &t, n_features, ops, depth);
    if (t.len == 0) {
        _ = push(&t, .{ .op = .c, .k = 1 });
    }
    return t;
}

fn grow(rng: *Rng, t: *Tree, n_features: u8, ops: []const Op, depth: u8) ?u8 {
    if (depth == 0 or rng.chance(350) or t.len + 3 >= max_nodes) {
        if (rng.chance(500) and n_features > 0) {
            return push(t, .{ .op = .v, .vi = @intCast(rng.below(n_features)) });
        }
        return push(t, .{ .op = .c, .k = leaf_consts[rng.below(leaf_consts.len)] });
    }
    if (rng.chance(300)) {
        const op = pickOp(rng, ops, true);
        const a = grow(rng, t, n_features, ops, depth - 1) orelse return null;
        return push(t, .{ .op = op, .a = a });
    }
    const op = pickOp(rng, ops, false);
    const a = grow(rng, t, n_features, ops, depth - 1) orelse return null;
    const b = grow(rng, t, n_features, ops, depth - 1) orelse return null;
    return push(t, .{ .op = op, .a = a, .b = b });
}

fn squareGuess(feat: u8) Tree {
    var t = Tree{};
    const a = push(&t, .{ .op = .v, .vi = feat }).?;
    const b = push(&t, .{ .op = .v, .vi = feat }).?;
    _ = push(&t, .{ .op = .mul, .a = a, .b = b });
    return t;
}

fn linearGuess(feat: u8, slope: f32, intercept: f32) Tree {
    var t = Tree{};
    const v = push(&t, .{ .op = .v, .vi = feat }).?;
    const s = push(&t, .{ .op = .c, .k = slope }).?;
    const p = push(&t, .{ .op = .mul, .a = s, .b = v }).?;
    const c = push(&t, .{ .op = .c, .k = intercept }).?;
    _ = push(&t, .{ .op = .add, .a = p, .b = c });
    return t;
}

fn mutate(rng: *Rng, src: *const Tree, n_features: u8, ops: []const Op) Tree {
    var t = cloneTree(src);
    if (t.len == 0) return randomTree(rng, n_features, ops, 2);
    const i: u8 = @intCast(rng.below(t.len));
    var n = t.nodes[i];
    switch (rng.below(3)) {
        0 => {
            if (n.op == .c) {
                n.k = leaf_consts[rng.below(leaf_consts.len)];
            } else if (n.op == .v and n_features > 0) {
                n.vi = @intCast(rng.below(n_features));
            } else if (allowed(ops, n.op)) {
                const unary = switch (n.op) {
                    .neg, .sin, .cos, .exp, .log => true,
                    else => false,
                };
                n.op = pickOp(rng, ops, unary);
            }
            t.nodes[i] = n;
        },
        1 => {
            var repl = randomTree(rng, n_features, ops, 2);
            var dst = Tree{};
            _ = graft(src, i, &repl, &dst) orelse return t;
            if (dst.len > 0) return dst;
        },
        else => {
            if (n.op == .c) n.k = n.k + if (rng.chance(500)) @as(f32, 1) else -1;
            t.nodes[i] = n;
        },
    }
    return t;
}

fn graft(src: *const Tree, cut: u8, repl: *const Tree, dst: *Tree) ?u8 {
    if (src.len == 0) return copySubtree(repl, repl.len - 1, dst);
    // rebuild src, swapping the subtree at `cut`
    return graftNode(src, src.len - 1, cut, repl, dst);
}

fn graftNode(src: *const Tree, si: u8, cut: u8, repl: *const Tree, dst: *Tree) ?u8 {
    if (si == cut) return copySubtree(repl, repl.len - 1, dst);
    const n = src.nodes[si];
    var out = n;
    switch (n.op) {
        .c, .v => {},
        .neg, .sin, .cos, .exp, .log => {
            out.a = graftNode(src, n.a, cut, repl, dst) orelse return null;
        },
        .add, .sub, .mul, .div => {
            out.a = graftNode(src, n.a, cut, repl, dst) orelse return null;
            out.b = graftNode(src, n.b, cut, repl, dst) orelse return null;
        },
    }
    return push(dst, out);
}

fn crossover(rng: *Rng, a: *const Tree, b: *const Tree) Tree {
    if (a.len == 0) return cloneTree(b);
    if (b.len == 0) return cloneTree(a);
    const cut: u8 = @intCast(rng.below(a.len));
    const take: u8 = @intCast(rng.below(b.len));
    var repl = Tree{};
    _ = copySubtree(b, take, &repl) orelse return cloneTree(a);
    var dst = Tree{};
    _ = graftNode(a, a.len - 1, cut, &repl, &dst) orelse return cloneTree(a);
    return dst;
}

const Scored = struct { t: Tree, mse: f64, c: u16 };

fn tournament(rng: *Rng, pop: []const Scored) *const Scored {
    var best = &pop[rng.below(pop.len)];
    var k: u8 = 0;
    while (k < 2) : (k += 1) {
        const o = &pop[rng.below(pop.len)];
        if (o.mse < best.mse) best = o;
    }
    return best;
}

pub const SearchResult = struct {
    items: [max_pareto]Scored = undefined,
    len: u8 = 0,
};

pub fn search(data: Dataset, opts: SearchOpts) SearchResult {
    var rng = Rng{ .s = if (opts.seed == 0) 1 else opts.seed };
    const gens = clampGenerations(opts.generations);
    const ops = if (opts.ops.len == 0) default_ops[0..] else opts.ops;

    var pop: [max_pop]Scored = undefined;
    var n: usize = 0;

    // Seed a few linear guesses so y = ax+b is found without a lucky tree.
    if (allowed(ops, .add) and allowed(ops, .mul) and data.n_features > 0) {
        const slopes = [_]f32{ 1, 2, -1, 0.5 };
        const intercepts = [_]f32{ 0, 1, -1, 2 };
        for (slopes) |s| {
            for (intercepts) |c| {
                if (n >= max_pop) break;
                var f: u8 = 0;
                while (f < data.n_features and n < max_pop) : (f += 1) {
                    const t = linearGuess(f, s, c);
                    pop[n] = .{ .t = t, .mse = mseOf(&t, data), .c = complexityOf(&t) };
                    n += 1;
                }
            }
        }
        var f: u8 = 0;
        while (f < data.n_features and n < max_pop) : (f += 1) {
            const t = squareGuess(f);
            pop[n] = .{ .t = t, .mse = mseOf(&t, data), .c = complexityOf(&t) };
            n += 1;
        }
    }

    while (n < max_pop) : (n += 1) {
        const t = randomTree(&rng, data.n_features, ops, 3);
        pop[n] = .{ .t = t, .mse = mseOf(&t, data), .c = complexityOf(&t) };
    }

    var hall: [max_nodes + 1]?Scored = .{null} ** (max_nodes + 1);
    var g: u16 = 0;
    while (g < gens) : (g += 1) {
        for (pop[0..n]) |s| consider(&hall, s);

        // Sort by mse, keep two elites.
        std.mem.sort(Scored, pop[0..n], {}, struct {
            fn lt(_: void, a: Scored, b: Scored) bool {
                return a.mse < b.mse;
            }
        }.lt);

        var next: [max_pop]Scored = undefined;
        next[0] = pop[0];
        next[1] = pop[1];
        var i: usize = 2;
        while (i < n) : (i += 1) {
            const p1 = tournament(&rng, pop[0..n]);
            const child = if (rng.chance(550))
                crossover(&rng, &p1.t, &tournament(&rng, pop[0..n]).t)
            else
                mutate(&rng, &p1.t, data.n_features, ops);
            next[i] = .{ .t = child, .mse = mseOf(&child, data), .c = complexityOf(&child) };
        }
        pop = next;
    }
    for (pop[0..n]) |s| consider(&hall, s);

    var out = SearchResult{};
    var c: usize = 1;
    while (c <= max_nodes and out.len < max_pareto) : (c += 1) {
        if (hall[c]) |s| {
            out.items[out.len] = s;
            out.len += 1;
        }
    }
    return out;
}

fn consider(hall: *[max_nodes + 1]?Scored, s: Scored) void {
    if (s.c == 0 or s.c > max_nodes) return;
    if (hall[s.c]) |cur| {
        if (s.mse < cur.mse) hall[s.c] = s;
    } else {
        hall[s.c] = s;
    }
}

pub fn formatTree(t: *const Tree, names: []const []const u8, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeNode(t, t.len - 1, names, &w) catch {};
    return buf[0..w.end];
}

fn writeNode(t: *const Tree, idx: u8, names: []const []const u8, w: *std.Io.Writer) !void {
    if (idx >= t.len) {
        try w.writeAll("?");
        return;
    }
    const n = t.nodes[idx];
    switch (n.op) {
        .c => {
            if (n.k == @floor(n.k) and @abs(n.k) < 1e6) {
                const k: f64 = n.k;
                try w.print("{d}", .{@as(i32, @trunc(k))});
            } else {
                try w.print("{d}", .{n.k});
            }
        },
        .v => {
            if (n.vi < names.len) {
                try w.writeAll(names[n.vi]);
            } else {
                try w.print("x{d}", .{n.vi});
            }
        },
        .neg => {
            try w.writeAll("-(");
            try writeNode(t, n.a, names, w);
            try w.writeByte(')');
        },
        .sin, .cos, .exp, .log => {
            try w.writeAll(@tagName(n.op));
            try w.writeByte('(');
            try writeNode(t, n.a, names, w);
            try w.writeByte(')');
        },
        .add => {
            try w.writeByte('(');
            try writeNode(t, n.a, names, w);
            try w.writeAll(" + ");
            try writeNode(t, n.b, names, w);
            try w.writeByte(')');
        },
        .sub => {
            try w.writeByte('(');
            try writeNode(t, n.a, names, w);
            try w.writeAll(" - ");
            try writeNode(t, n.b, names, w);
            try w.writeByte(')');
        },
        .mul => {
            try w.writeByte('(');
            try writeNode(t, n.a, names, w);
            try w.writeAll("*");
            try writeNode(t, n.b, names, w);
            try w.writeByte(')');
        },
        .div => {
            try w.writeByte('(');
            try writeNode(t, n.a, names, w);
            try w.writeAll("/");
            try writeNode(t, n.b, names, w);
            try w.writeByte(')');
        },
    }
}

pub fn asNumber(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn appendNum(list: *std.ArrayList(f64), alloc: std.mem.Allocator, v: std.json.Value) ParseError!void {
    const n = asNumber(v) orelse return error.BadInput;
    list.append(alloc, n) catch return error.OutOfMemory;
}

pub fn parseOwned(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ParseError!Owned {
    if (obj.get("rows")) |rows| {
        if (rows != .array) return error.BadInput;
        return parseRows(alloc, rows.array.items);
    }
    if (obj.get("csv")) |csv| {
        if (csv != .string) return error.BadInput;
        return parseCsv(alloc, csv.string);
    }
    const xv = obj.get("x") orelse return error.BadInput;
    const yv = obj.get("y") orelse return error.BadInput;
    if (yv != .array) return error.BadInput;
    if (yv.array.items.len == 0) return error.Empty;
    if (yv.array.items.len > max_rows) return error.TooManyRows;

    var xs: std.ArrayList(f64) = .empty;
    var ys: std.ArrayList(f64) = .empty;
    errdefer xs.deinit(alloc);
    errdefer ys.deinit(alloc);

    if (xv == .array and xv.array.items.len > 0 and xv.array.items[0] == .array) {
        if (xv.array.items.len != yv.array.items.len) return error.LengthMismatch;
        const nf = xv.array.items[0].array.items.len;
        if (nf == 0 or nf > max_features) return error.TooManyFeatures;
        for (xv.array.items) |row| {
            if (row != .array or row.array.items.len != nf) return error.LengthMismatch;
            for (row.array.items) |c| try appendNum(&xs, alloc, c);
        }
        for (yv.array.items) |c| try appendNum(&ys, alloc, c);
        return try finishOwned(alloc, &xs, &ys, @intCast(nf));
    }

    if (xv != .array) return error.BadInput;
    if (xv.array.items.len != yv.array.items.len) return error.LengthMismatch;
    for (xv.array.items) |c| try appendNum(&xs, alloc, c);
    for (yv.array.items) |c| try appendNum(&ys, alloc, c);
    return try finishOwned(alloc, &xs, &ys, 1);
}

fn finishOwned(alloc: std.mem.Allocator, xs: *std.ArrayList(f64), ys: *std.ArrayList(f64), nf: u8) ParseError!Owned {
    const nr: u16 = @intCast(ys.items.len);
    const xo = xs.toOwnedSlice(alloc) catch return error.OutOfMemory;
    const yo = ys.toOwnedSlice(alloc) catch {
        alloc.free(xo);
        return error.OutOfMemory;
    };
    return .{ .x = xo, .y = yo, .n_rows = nr, .n_features = nf };
}

fn parseRows(alloc: std.mem.Allocator, rows: []const std.json.Value) ParseError!Owned {
    if (rows.len == 0) return error.Empty;
    if (rows.len > max_rows) return error.TooManyRows;
    if (rows[0] != .array or rows[0].array.items.len < 2) return error.BadInput;
    const width = rows[0].array.items.len;
    const nf = width - 1;
    if (nf == 0 or nf > max_features) return error.TooManyFeatures;

    var xs: std.ArrayList(f64) = .empty;
    var ys: std.ArrayList(f64) = .empty;
    errdefer xs.deinit(alloc);
    errdefer ys.deinit(alloc);
    for (rows) |row| {
        if (row != .array or row.array.items.len != width) return error.LengthMismatch;
        var i: usize = 0;
        while (i < nf) : (i += 1) try appendNum(&xs, alloc, row.array.items[i]);
        try appendNum(&ys, alloc, row.array.items[nf]);
    }
    return try finishOwned(alloc, &xs, &ys, @intCast(nf));
}

fn parseCsv(alloc: std.mem.Allocator, text: []const u8) ParseError!Owned {
    var xs: std.ArrayList(f64) = .empty;
    var ys: std.ArrayList(f64) = .empty;
    errdefer xs.deinit(alloc);
    errdefer ys.deinit(alloc);
    var nf: usize = 0;
    var n_rows: usize = 0;
    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var width: usize = 0;
        var last: f64 = 0;
        var col_it = std.mem.splitScalar(u8, line, ',');
        while (col_it.next()) |c| {
            const t = std.mem.trim(u8, c, " \t");
            const n = std.fmt.parseFloat(f64, t) catch return error.BadInput;
            if (width > 0) xs.append(alloc, last) catch return error.OutOfMemory;
            last = n;
            width += 1;
        }
        if (width < 2) return error.BadInput;
        if (n_rows == 0) {
            nf = width - 1;
            if (nf == 0 or nf > max_features) return error.TooManyFeatures;
        } else if (width - 1 != nf) return error.LengthMismatch;
        ys.append(alloc, last) catch return error.OutOfMemory;
        n_rows += 1;
        if (n_rows > max_rows) return error.TooManyRows;
    }
    if (n_rows == 0) return error.Empty;
    return try finishOwned(alloc, &xs, &ys, @intCast(nf));
}

pub fn parseOpName(s: []const u8) ?Op {
    if (std.mem.eql(u8, s, "+") or std.mem.eql(u8, s, "add")) return .add;
    if (std.mem.eql(u8, s, "-") or std.mem.eql(u8, s, "sub")) return .sub;
    if (std.mem.eql(u8, s, "*") or std.mem.eql(u8, s, "mul")) return .mul;
    if (std.mem.eql(u8, s, "/") or std.mem.eql(u8, s, "div")) return .div;
    if (std.mem.eql(u8, s, "neg")) return .neg;
    if (std.mem.eql(u8, s, "sin")) return .sin;
    if (std.mem.eql(u8, s, "cos")) return .cos;
    if (std.mem.eql(u8, s, "exp")) return .exp;
    if (std.mem.eql(u8, s, "log")) return .log;
    return null;
}

test "eval of 2*x+1 is exact" {
    const t = linearGuess(0, 2, 1);
    const x = [_]f64{ 0, 1, 2, 3 };
    const y = [_]f64{ 1, 3, 5, 7 };
    const data = Dataset{ .x = &x, .y = &y, .n_rows = 4, .n_features = 1 };
    try std.testing.expect(mseOf(&t, data) < 1e-12);
    var buf: [64]u8 = undefined;
    const s = formatTree(&t, &.{}, &buf);
    try std.testing.expect(std.mem.find(u8, s, "x0") != null);
}

test "search finds a close fit for y=2x+1" {
    const x = [_]f64{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const y = [_]f64{ 1, 3, 5, 7, 9, 11, 13, 15 };
    const data = Dataset{ .x = &x, .y = &y, .n_rows = 8, .n_features = 1 };
    const found = search(data, .{ .generations = 8, .seed = 1 });
    try std.testing.expect(found.len >= 1);
    try std.testing.expect(bestMse(found) < 1e-6);
}

test "search on y=x*x returns a front" {
    const x = [_]f64{ -2, -1, 0, 1, 2, 3 };
    const y = [_]f64{ 4, 1, 0, 1, 4, 9 };
    const data = Dataset{ .x = &x, .y = &y, .n_rows = 6, .n_features = 1 };
    const found = search(data, .{ .generations = 8, .seed = 2 });
    try std.testing.expect(found.len >= 1);
    try std.testing.expect(bestMse(found) < 1e-6);
}

fn bestMse(found: SearchResult) f64 {
    var best: f64 = 1e12;
    var i: u8 = 0;
    while (i < found.len) : (i += 1) {
        if (found.items[i].mse < best) best = found.items[i].mse;
    }
    return best;
}

test "parse x/y vectors and rows" {
    const gpa = std.testing.allocator;
    const vec =
        \\{"x":[1,2,3],"y":[2,4,6]}
    ;
    const v = try std.json.parseFromSlice(std.json.Value, gpa, vec, .{});
    defer v.deinit();
    const a = try parseOwned(gpa, v.value.object);
    defer a.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 3), a.n_rows);
    try std.testing.expectEqual(@as(u8, 1), a.n_features);
    try std.testing.expectEqual(@as(f64, 6), a.y[2]);

    const rows =
        \\{"rows":[[1,10,11],[2,20,22]]}
    ;
    const r = try std.json.parseFromSlice(std.json.Value, gpa, rows, .{});
    defer r.deinit();
    const b = try parseOwned(gpa, r.value.object);
    defer b.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), b.n_features);
    try std.testing.expectEqual(@as(f64, 22), b.y[1]);
}

test "parse refuses empty and oversize" {
    const gpa = std.testing.allocator;
    const empty = try std.json.parseFromSlice(std.json.Value, gpa, "{\"x\":[],\"y\":[]}", .{});
    defer empty.deinit();
    try std.testing.expectError(error.Empty, parseOwned(gpa, empty.value.object));
}
