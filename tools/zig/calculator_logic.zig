//! Pure arithmetic logic for the calculator guest (`clanker`'s `calculator`
//! catalog tool). Host-tested via `host_tested_helpers` in build.zig; the
//! guest imports this file, so the agent runs the one implementation.
//!
//! Two entry shapes share this module: a two-operand form (`{a,b,op}`) and a
//! string expression (`{"expr": "2+3*4"}`). Operators: `+ - * / % ^`, with
//! parentheses and standard precedence (`%` binds with `*` and `/`). `sqrt(x)`
//! is a one-argument function. `%` is `@rem` (truncated remainder, like C's
//! fmod): `@rem(-7, 3) == -1`, keeping `%` a true remainder rather than a
//! floored modulo. Division and modulo by zero are the only runtime failures;
//! everything else is total, so `pow`/`sqrt` may return NaN/Inf for an
//! out-of-domain operand rather than erroring; `requireFinite` is where a
//! caller that must serialize the value into JSON refuses it instead.
const std = @import("std");

pub const ExprError = error{
    DivisionByZero,
    InvalidExpression,
    MissingOperand,
    UnbalancedParen,
    TrailingChars,
};

pub const Op = enum { add, sub, mul, div, rem, pow };

/// Map an operator string to its `Op`. Unknown strings return null so the
/// guest can report the unsupported operator by name.
pub fn opFromStr(s: []const u8) ?Op {
    const table = std.StaticStringMap(Op).initComptime(.{
        .{ "+", .add },
        .{ "-", .sub },
        .{ "*", .mul },
        .{ "/", .div },
        .{ "%", .rem },
        .{ "^", .pow },
    });
    return table.get(s);
}

/// The guest serializes a result into JSON, and JSON has no spelling for NaN
/// or Infinity: `{d}` would emit `nan`/`inf` and the host would refuse the
/// whole tool output as malformed instead of answering. Callers turn this
/// error into a plain failure naming the cause.
pub fn requireFinite(v: f64) error{NotFinite}!f64 {
    if (!std.math.isFinite(v)) return error.NotFinite;
    return v;
}

/// Evaluate the two-operand form. Division and modulo by zero are the one
/// runtime failure.
pub fn applyOp(a: f64, op: Op, b: f64) error{DivisionByZero}!f64 {
    return switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => if (b == 0) error.DivisionByZero else a / b,
        .rem => if (b == 0) error.DivisionByZero else @rem(a, b),
        .pow => std.math.pow(f64, a, b),
    };
}

/// Evaluate a whole expression string. Trailing non-whitespace characters are
/// an error, so `"2+3*4"` parses but `"2+3*4 extra"` does not.
pub fn evalExpr(input: []const u8) ExprError!f64 {
    var p = ExprParser{ .s = input, .i = 0 };
    const val = try p.parseExpr();
    p.skipWs();
    if (p.i != p.s.len) return error.TrailingChars;
    return val;
}

const ExprParser = struct {
    s: []const u8,
    i: usize,

    fn skipWs(self: *ExprParser) void {
        while (self.i < self.s.len) : (self.i += 1) {
            const c = self.s[self.i];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
        }
    }

    fn eat(self: *ExprParser, ch: u8) bool {
        self.skipWs();
        if (self.i < self.s.len and self.s[self.i] == ch) {
            self.i += 1;
            return true;
        }
        return false;
    }

    fn parseExpr(self: *ExprParser) ExprError!f64 {
        var left = try self.parseTerm();
        while (true) {
            if (self.eat('+')) {
                const right = try self.parseTerm();
                left += right;
            } else if (self.eat('-')) {
                const right = try self.parseTerm();
                left -= right;
            } else return left;
        }
    }

    fn parseTerm(self: *ExprParser) ExprError!f64 {
        var left = try self.parseUnary();
        while (true) {
            if (self.eat('*')) {
                const right = try self.parseUnary();
                left *= right;
            } else if (self.eat('/')) {
                const right = try self.parseUnary();
                if (right == 0) return error.DivisionByZero;
                left /= right;
            } else if (self.eat('%')) {
                const right = try self.parseUnary();
                if (right == 0) return error.DivisionByZero;
                left = @rem(left, right);
            } else return left;
        }
    }

    fn parseUnary(self: *ExprParser) ExprError!f64 {
        if (self.eat('-')) return -(try self.parseUnary());
        if (self.eat('+')) return self.parseUnary();
        return self.parsePower();
    }

    fn parsePower(self: *ExprParser) ExprError!f64 {
        const base = try self.parsePrimary();
        if (self.eat('^')) {
            const exponent = try self.parseUnary();
            return std.math.pow(f64, base, exponent);
        }
        return base;
    }

    fn parsePrimary(self: *ExprParser) ExprError!f64 {
        self.skipWs();
        if (self.i >= self.s.len) return error.MissingOperand;
        const ch = self.s[self.i];
        if (ch == '(') {
            self.i += 1;
            const val = try self.parseExpr();
            if (!self.eat(')')) return error.UnbalancedParen;
            return val;
        }
        if (ch == ')' or ch == '+' or ch == '-' or ch == '*' or ch == '/' or ch == '%' or ch == '^') return error.MissingOperand;
        // sqrt(x): a one-argument function. @sqrt on a negative argument is
        // NaN (not an error), matching pow's IEEE behaviour.
        if (std.mem.startsWith(u8, self.s[self.i..], "sqrt")) {
            self.i += 4;
            if (!self.eat('(')) return error.MissingOperand;
            const arg = try self.parseExpr();
            if (!self.eat(')')) return error.UnbalancedParen;
            return std.math.sqrt(arg);
        }
        return self.parseNumber();
    }

    fn parseNumber(self: *ExprParser) ExprError!f64 {
        const start = self.i;
        var has_dot = false;
        while (self.i < self.s.len) {
            const ch = self.s[self.i];
            if (ch >= '0' and ch <= '9') {
                self.i += 1;
            } else if (ch == '.' and !has_dot) {
                has_dot = true;
                self.i += 1;
            } else break;
        }
        // Scientific notation: 1e3, 2.5E-2. Only consumed when at least one
        // exponent digit follows, so a trailing bare 'e' still errors out.
        if (self.i > start and self.i < self.s.len and (self.s[self.i] == 'e' or self.s[self.i] == 'E')) {
            var j = self.i + 1;
            if (j < self.s.len and (self.s[j] == '+' or self.s[j] == '-')) j += 1;
            const digits_start = j;
            while (j < self.s.len and self.s[j] >= '0' and self.s[j] <= '9') j += 1;
            if (j > digits_start) self.i = j;
        }
        if (self.i == start) return error.MissingOperand;
        // Correctly-rounded parsing (and a hard error on malformed literals
        // like ".") instead of hand-rolled accumulation that compounds
        // rounding error on every fractional digit.
        return std.fmt.parseFloat(f64, self.s[start..self.i]) catch error.InvalidExpression;
    }
};

fn expectClose(expected: f64, actual: f64) !void {
    try std.testing.expect(@abs(actual - expected) < 1e-9);
}

test "opFromStr maps every operator and rejects unknown names" {
    try std.testing.expectEqual(Op.add, opFromStr("+").?);
    try std.testing.expectEqual(Op.sub, opFromStr("-").?);
    try std.testing.expectEqual(Op.mul, opFromStr("*").?);
    try std.testing.expectEqual(Op.div, opFromStr("/").?);
    try std.testing.expectEqual(Op.rem, opFromStr("%").?);
    try std.testing.expectEqual(Op.pow, opFromStr("^").?);
    try std.testing.expect(opFromStr("mod") == null);
}

test "applyOp evaluates each operator and rejects zero divisors" {
    try expectClose(8, try applyOp(5, .add, 3));
    try expectClose(2, try applyOp(5, .sub, 3));
    try expectClose(15, try applyOp(5, .mul, 3));
    try expectClose(2.5, try applyOp(5, .div, 2));
    try expectClose(1, try applyOp(7, .rem, 3));
    try expectClose(-1, try applyOp(-7, .rem, 3));
    try expectClose(1024, try applyOp(2, .pow, 10));
    try std.testing.expectError(error.DivisionByZero, applyOp(1, .div, 0));
    try std.testing.expectError(error.DivisionByZero, applyOp(1, .rem, 0));
}

test "evalExpr honours precedence, parens, power associativity, and sqrt" {
    try expectClose(14, try evalExpr("2+3*4"));
    try expectClose(27, try evalExpr("(1+2)^3"));
    try expectClose(512, try evalExpr("2^3^2"));
    try expectClose(1, try evalExpr("10%3"));
    try expectClose(2, try evalExpr("10%3*2"));
    try expectClose(4, try evalExpr("sqrt(16)"));
    try expectClose(5, try evalExpr("sqrt(3^2+4^2)"));
    try expectClose(6, try evalExpr("2*sqrt(9)"));
}

test "requireFinite rejects NaN and infinities, accepts ordinary values" {
    try std.testing.expectEqual(@as(f64, 2.5), try requireFinite(2.5));
    try std.testing.expectEqual(@as(f64, 0), try requireFinite(0));
    try std.testing.expectError(error.NotFinite, requireFinite(std.math.nan(f64)));
    try std.testing.expectError(error.NotFinite, requireFinite(std.math.inf(f64)));
    try std.testing.expectError(error.NotFinite, requireFinite(-std.math.inf(f64)));
}

test "evalExpr reports the exact malformed-input error" {
    try std.testing.expectError(error.DivisionByZero, evalExpr("1/0"));
    try std.testing.expectError(error.DivisionByZero, evalExpr("1%0"));
    try std.testing.expectError(error.TrailingChars, evalExpr("1+2 3"));
    try std.testing.expectError(error.UnbalancedParen, evalExpr("(1+2"));
    try std.testing.expectError(error.MissingOperand, evalExpr("1+"));
    try std.testing.expectError(error.MissingOperand, evalExpr("sqrt()"));
    try std.testing.expectError(error.InvalidExpression, evalExpr("."));
}

// ------------------------------------------------------- fuzz targets --

/// Structure-aware expression generator for the oracle fuzz target below. It
/// renders a valid `+ - * / %` expression into a fixed buffer while an
/// independent tree evaluator computes the value the parser must produce, so
/// a precedence or associativity bug shows up as an oracle mismatch rather
/// than as a crash. The node budget and depth cap bound every run no matter
/// what the fuzzer feeds the generator.
const ExprGen = struct {
    smith: *std.testing.Smith,
    buf: []u8,
    pos: usize = 0,
    nodes: u8 = 0,

    const max_nodes: u8 = 20;
    const max_depth: u8 = 6;

    const Result = struct {
        val: f64 = 0,
        /// Some division or modulo in the expression divides by zero, so the
        /// parser must fail with `DivisionByZero` (and `val` is not computed).
        div_zero: bool = false,
        /// The generated expression did not fit the fixed buffers; skip the
        /// iteration, there is nothing to assert.
        abort: bool = false,
    };

    const digits = [_]std.testing.Smith.Weight{.rangeAtMost(u8, '0', '9', 1)};
    const add_ops = [_]std.testing.Smith.Weight{
        .value(u8, '+', 1),
        .value(u8, '-', 1),
    };
    const mul_ops = [_]std.testing.Smith.Weight{
        .value(u8, '*', 1),
        .value(u8, '/', 1),
        .value(u8, '%', 1),
    };
    // Rarely-true, so the generated text stays mostly plain arithmetic while
    // still exercising unary minus, parens, fractions and scientific notation.
    const rarely = [_]std.testing.Smith.Weight{
        .value(bool, false, 4),
        .value(bool, true, 1),
    };

    fn put(g: *ExprGen, bytes: []const u8) bool {
        if (g.pos + bytes.len > g.buf.len) return false;
        @memcpy(g.buf[g.pos .. g.pos + bytes.len], bytes);
        g.pos += bytes.len;
        return true;
    }

    fn spend(g: *ExprGen) bool {
        if (g.nodes >= max_nodes) return false;
        g.nodes += 1;
        return true;
    }

    fn digit(g: *ExprGen, nonzero: bool) u8 {
        const d = if (nonzero) g.smith.valueRangeLessThan(u8, 1, 10) else g.smith.valueRangeLessThan(u8, 0, 10);
        return d + '0';
    }

    /// Up to 12 more digits into `num[n..]`, leaving room in the buffer for
    /// the rest of the literal. Returns the number of digits appended. The
    /// length weight is bounded by `run.len` because `sliceWeighted` asserts
    /// its max fits the slice it fills.
    fn extraDigits(g: *ExprGen, num: []u8, n: usize) usize {
        if (n >= num.len) return 0;
        const run = num[n..@min(num.len, n + 12)];
        return g.smith.sliceWeighted(run, &.{.rangeAtMost(u32, 1, @intCast(run.len), 1)}, &digits);
    }

    fn genNumber(g: *ExprGen) Result {
        if (!g.spend()) return .{ .abort = true };
        var num: [64]u8 = undefined;
        var n: usize = 0;
        num[n] = g.digit(true);
        n += 1;
        if (!g.smith.eos()) n += g.extraDigits(&num, n);
        if (!g.smith.eos() and g.smith.valueWeighted(bool, &rarely)) {
            num[n] = '.';
            n += 1;
            num[n] = g.digit(false);
            n += 1;
            if (!g.smith.eos()) n += g.extraDigits(&num, n);
        }
        if (!g.smith.eos() and g.smith.valueWeighted(bool, &rarely)) {
            num[n] = if (g.smith.value(bool)) 'e' else 'E';
            n += 1;
            if (!g.smith.eos() and g.smith.valueWeighted(bool, &rarely)) {
                num[n] = if (g.smith.value(bool)) '+' else '-';
                n += 1;
            }
            num[n] = g.digit(false);
            n += 1;
            if (!g.smith.eos()) n += g.extraDigits(&num, n);
        }
        if (!g.put(num[0..n])) return .{ .abort = true };
        // Generated literals are valid by construction; the same parseFloat
        // the parser calls, so the oracle and the parser agree on the leaf
        // before any operator is applied.
        const val = std.fmt.parseFloat(f64, num[0..n]) catch return .{ .abort = true };
        return .{ .val = val, .div_zero = false, .abort = false };
    }

    fn genPrimary(g: *ExprGen, depth: u8) Result {
        if (depth < max_depth and !g.smith.eos() and g.smith.valueWeighted(bool, &rarely)) {
            if (!g.put("(")) return .{ .abort = true };
            const inner = g.genAdd(depth + 1);
            if (inner.abort) return inner;
            if (!g.put(")")) return .{ .abort = true };
            return inner;
        }
        return g.genNumber();
    }

    fn genUnary(g: *ExprGen, depth: u8) Result {
        if (g.smith.eos() or !g.smith.valueWeighted(bool, &rarely)) return g.genPrimary(depth);
        if (!g.spend() or !g.put("-")) return .{ .abort = true };
        const inner = g.genUnary(depth);
        if (inner.abort) return inner;
        if (inner.div_zero) return inner;
        return .{ .val = -inner.val, .div_zero = false, .abort = false };
    }

    fn genMul(g: *ExprGen, depth: u8) Result {
        var left = g.genUnary(depth);
        if (left.abort) return left;
        while (g.spend()) {
            if (g.smith.eos()) break;
            const op = g.smith.valueWeighted(u8, &mul_ops);
            if (!g.put(&.{op})) return .{ .abort = true };
            const right = g.genUnary(depth);
            if (right.abort) return .{ .abort = true };
            if (left.div_zero or right.div_zero) {
                left.div_zero = true;
            } else switch (op) {
                '*' => left.val *= right.val,
                '/' => {
                    if (right.val == 0) {
                        left.div_zero = true;
                    } else {
                        left.val /= right.val;
                    }
                },
                '%' => {
                    if (right.val == 0) {
                        left.div_zero = true;
                    } else {
                        left.val = @rem(left.val, right.val);
                    }
                },
                else => unreachable,
            }
        }
        return left;
    }

    fn genAdd(g: *ExprGen, depth: u8) Result {
        var left = g.genMul(depth);
        if (left.abort) return left;
        while (g.spend()) {
            if (g.smith.eos()) break;
            const op = g.smith.valueWeighted(u8, &add_ops);
            if (!g.put(&.{op})) return .{ .abort = true };
            const right = g.genMul(depth);
            if (right.abort) return .{ .abort = true };
            if (left.div_zero or right.div_zero) {
                left.div_zero = true;
            } else {
                left.val = if (op == '+') left.val + right.val else left.val - right.val;
            }
        }
        return left;
    }
};

test "fuzz: no byte sequence crashes the expression parser" {
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const len = smith.slice(&buf);
            const input = buf[0..len];

            // Liveness plus two invariants: evaluating the same input twice is
            // bit-for-bit deterministic (a NaN payload would defeat `==`), and
            // a trailing space, which `evalExpr` skips before its end-of-input
            // check, never changes the result.
            const first = evalExpr(input) catch return;
            const second = evalExpr(input) catch return;
            try std.testing.expect(@as(u64, @bitCast(first)) == @as(u64, @bitCast(second)));
            if (len < buf.len) {
                buf[len] = ' ';
                const padded = evalExpr(buf[0 .. len + 1]) catch return;
                try std.testing.expect(@as(u64, @bitCast(first)) == @as(u64, @bitCast(padded)));
            }
        }
    };
    // Corpus entries are Smith byte seeds, not expressions handed to the
    // parser; they steer the generator toward the shapes listed.
    try std.testing.fuzz({}, Ctx.one, .{
        .corpus = &.{
            "2+3*4",
            "(1+2)^3",
            "sqrt(16)",
            "1/0",
            ".",
            "(((((((((((((((((1)))))))))))))))))",
            "1e3",
            "0x10",
            "",
        },
    });
}

test "fuzz: evalExpr agrees with an independent evaluator on generated expressions" {
    const Ctx = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            var g = ExprGen{ .smith = smith, .buf = &buf };
            const r = g.genAdd(0);
            if (r.abort) return;
            const text = buf[0..g.pos];
            if (r.div_zero) {
                // The generator only reports div_zero when a division or
                // modulo actually divides by zero, and the parser walks the
                // same left-to-right order, so it must fail with exactly this
                // error rather than returning a value.
                try std.testing.expectError(error.DivisionByZero, evalExpr(text));
            } else {
                const got = evalExpr(text) catch |e| {
                    std.debug.print("parser rejected a generated expression: {s}\n", .{text});
                    return e;
                };
                // Generated text is a strict subset of the grammar, so a
                // successful parse is mandatory and must produce the oracle
                // value: a precedence or associativity slip changes the
                // operand order and the bits.
                try std.testing.expectEqual(r.val, got);
            }
        }
    };
    try std.testing.fuzz({}, Ctx.one, .{});
}
