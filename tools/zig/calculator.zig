//! calculator: pure arithmetic tool — no host function calls, so it can run
//! even with the most restrictive sandbox policy.
//!
//! Input:  {"a": <number>, "b": <number>, "op": "+" | "-" | "*" | "/" | "%" | "^"}
//!         or {"expr": "2+3*4"} (operators + - * / % ^, parentheses, precedence)
//! Output: {"ok": true, "result": <number>}

const std = @import("std");
const lib = @import("lib.zig");

export fn run(ptr: u32, len: u32) callconv(.c) u64 {
    return lib.run(ptr, len, tool_main);
}

fn tool_main(input: []const u8, out: *lib.Out) !void {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, lib.alloc, input, .{});
    if (parsed != .object) return lib.fail(out, "input must be a JSON object with \"expr\" or \"a\"/\"b\"/\"op\"");
    const obj = parsed.object;

    if (obj.get("expr")) |expr_val| {
        const expr = switch (expr_val) {
            .string => |s| s,
            else => return lib.fail(out, "expr must be a string"),
        };
        const result = evalExpr(expr) catch |err| {
            return lib.fail(out, if (err == error.DivisionByZero) "division by zero" else "invalid expression");
        };
        var buf: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"result\":{d}}}", .{result});
        try out.writeAll(body);
        return;
    }

    const a: f64 = switch (obj.get("a") orelse return lib.fail(out, "missing a")) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return lib.fail(out, "a must be a number"),
    };
    const b: f64 = switch (obj.get("b") orelse return lib.fail(out, "missing b")) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return lib.fail(out, "b must be a number"),
    };
    const op = switch (obj.get("op") orelse return lib.fail(out, "missing op")) {
        .string => |s| s,
        else => return lib.fail(out, "op must be a string"),
    };

    const result: f64 = if (std.mem.eql(u8, op, "+"))
        a + b
    else if (std.mem.eql(u8, op, "-"))
        a - b
    else if (std.mem.eql(u8, op, "*"))
        a * b
    else if (std.mem.eql(u8, op, "/"))
        if (b == 0) return lib.fail(out, "division by zero") else a / b
    else if (std.mem.eql(u8, op, "%"))
        if (b == 0) return lib.fail(out, "modulo by zero") else @rem(a, b)
    else if (std.mem.eql(u8, op, "^"))
        std.math.pow(f64, a, b)
    else
        return lib.fail(out, "unknown op; use + - * / % ^");

    var buf: [128]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"ok\":true,\"result\":{d}}}", .{result});
    try out.writeAll(body);
}

const ExprError = error{ DivisionByZero, InvalidExpression, MissingOperand, UnbalancedParen, TrailingChars };

fn evalExpr(input: []const u8) ExprError!f64 {
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
        if (ch == ')' or ch == '+' or ch == '-' or ch == '*' or ch == '/' or ch == '^') return error.MissingOperand;
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
