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
//! out-of-domain operand rather than erroring.
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

test "evalExpr reports the exact malformed-input error" {
    try std.testing.expectError(error.DivisionByZero, evalExpr("1/0"));
    try std.testing.expectError(error.DivisionByZero, evalExpr("1%0"));
    try std.testing.expectError(error.TrailingChars, evalExpr("1+2 3"));
    try std.testing.expectError(error.UnbalancedParen, evalExpr("(1+2"));
    try std.testing.expectError(error.MissingOperand, evalExpr("1+"));
    try std.testing.expectError(error.MissingOperand, evalExpr("sqrt()"));
    try std.testing.expectError(error.InvalidExpression, evalExpr("."));
}
