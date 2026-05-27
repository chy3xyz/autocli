const std = @import("std");
const json = @import("std").json;
const CliError = @import("core").CliError;

/// Template context - variables available in expressions
pub const TemplateContext = struct {
    args: std.StringHashMap(json.Value),
    data: json.Value,
    item: json.Value,
    index: usize,
};

/// AST node types for template expressions
pub const Expr = union(enum) {
    IntLit: i64,
    FloatLit: f64,
    StringLit: []const u8,
    BoolLit: bool,
    NullLit: void,
    Ident: []const u8,
    DotAccess: struct {
        base: *const Expr,
        field: []const u8,
    },
    BracketAccess: struct {
        base: *const Expr,
        index: *const Expr,
    },
    FuncCall: struct {
        namespace: []const []const u8,
        name: []const u8,
        args: []const *const Expr,
    },
    UnaryNot: *const Expr,
    BinOp: struct {
        left: *const Expr,
        op: BinOpKind,
        right: *const Expr,
    },
    Ternary: struct {
        condition: *const Expr,
        if_true: *const Expr,
        if_false: *const Expr,
    },
    Pipe: struct {
        expr: *const Expr,
        filter: []const u8,
        args: []const *const Expr,
    },
};

pub const BinOpKind = enum {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Gt,
    Lt,
    Gte,
    Lte,
    Eq,
    Neq,
    And,
    Or,
};

/// Token types for lexer
const Token = union(enum) {
    Int: i64,
    Float: f64,
    String: []const u8,
    Ident: []const u8,
    BoolLit: bool,
    NullLit,
    Plus,
    Minus,
    Star,
    Slash,
    Percent,
    Bang,
    EqEq,
    NotEq,
    Lt,
    Lte,
    Gt,
    Gte,
    AmpAmp,
    PipePipe,
    Pipe,
    QMark,
    Colon,
    LParen,
    RParen,
    LBracket,
    RBracket,
    Dot,
    Comma,
    Eof,
};

/// Tokenizer for template expressions
const Lexer = struct {
    input: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    fn nextToken(self: *Lexer) !Token {
        // Skip whitespace
        while (self.pos < self.input.len and self.isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }

        if (self.pos >= self.input.len) {
            return .Eof;
        }

        const c = self.input[self.pos];


        if (c == '+') {
            self.pos += 1;
            return .Plus;
        }
        if (c == '-') {
            self.pos += 1;
            return .Minus;
        }
        if (c == '*') {
            self.pos += 1;
            return .Star;
        }
        if (c == '/') {
            self.pos += 1;
            return .Slash;
        }
        if (c == '%') {
            self.pos += 1;
            return .Percent;
        }
        if (c == '!') {
            self.pos += 1;
            if (self.pos < self.input.len and self.input[self.pos] == '=') {
                self.pos += 1;
                return .NotEq;
            }
            return .Bang;
        }
        if (c == '=') {
            self.pos += 1;
            if (self.pos < self.input.len and self.input[self.pos] == '=') {
                self.pos += 1;
                return .EqEq;
            }
            return .EqEq;
        }
        if (c == '<') {
            self.pos += 1;
            if (self.pos < self.input.len and self.input[self.pos] == '=') {
                self.pos += 1;
                return .Lte;
            }
            return .Lt;
        }
        if (c == '>') {
            self.pos += 1;
            if (self.pos < self.input.len and self.input[self.pos] == '=') {
                self.pos += 1;
                return .Gte;
            }
            return .Gt;
        }
        if (c == '&' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '&') {
            self.pos += 2;
            return .AmpAmp;
        }
        if (c == '|' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '|') {
            self.pos += 2;
            return .PipePipe;
        }
        if (c == '|') {
            self.pos += 1;
            return .Pipe;
        }
        if (c == '?') {
            self.pos += 1;
            return .QMark;
        }
        if (c == ':') {
            self.pos += 1;
            return .Colon;
        }
        if (c == '(') {
            self.pos += 1;
            return .LParen;
        }
        if (c == ')') {
            self.pos += 1;
            return .RParen;
        }
        if (c == '[') {
            self.pos += 1;
            return .LBracket;
        }
        if (c == ']') {
            self.pos += 1;
            return .RBracket;
        }
        if (c == '.') {
            self.pos += 1;
            return .Dot;
        }
        if (c == ',') {
            self.pos += 1;
            return .Comma;
        }

        // Numbers
        if (c >= '0' and c <= '9' or c == '-') {
            const start = self.pos;
            if (c == '-') self.pos += 1;
            while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') {
                self.pos += 1;
            }
            if (self.pos < self.input.len and self.input[self.pos] == '.') {
                self.pos += 1;
                while (self.pos < self.input.len and self.input[self.pos] >= '0' and self.input[self.pos] <= '9') {
                    self.pos += 1;
                }
                const num_str = self.input[start..self.pos];
                return .{ .Float = try std.fmt.parseFloat(f64, num_str) };
            }
            const num_str = self.input[start..self.pos];
            return .{ .Int = try std.fmt.parseInt(i64, num_str, 10) };
        }

        // Strings
        if (c == '"' or c == '\'') {
            const quote = c;
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != quote) {
                if (self.input[self.pos] == '\\' and self.pos + 1 < self.input.len) {
                    self.pos += 2;
                } else {
                    self.pos += 1;
                }
            }
            const str = self.input[start..self.pos];
            self.pos += 1; // skip closing quote
            return .{ .String = try self.allocator.dupe(u8, str) };
        }

        // Identifiers and keywords
        if (c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
            const start = self.pos;
            while (self.pos < self.input.len) {
                const c2 = self.input[self.pos];
                if (c2 == '_' or c2 == '-' or (c2 >= 'a' and c2 <= 'z') or (c2 >= 'A' and c2 <= 'Z') or (c2 >= '0' and c2 <= '9')) {
                    self.pos += 1;
                } else {
                    break;
                }
            }
            const ident = self.input[start..self.pos];
            if (std.mem.eql(u8, ident, "true")) return .{ .BoolLit = true };
            if (std.mem.eql(u8, ident, "false")) return .{ .BoolLit = false };
            if (std.mem.eql(u8, ident, "null")) return .NullLit;
            return .{ .Ident = try self.allocator.dupe(u8, ident) };
        }

        self.pos += 1;
        return .Eof;
    }

    fn isWhitespace(_: *Lexer, c: u8) bool {
        return c == ' ' or c == '\n' or c == '\r' or c == '\t';
    }
};

/// Parser for template expressions
const Parser = struct {
    lexer: *Lexer,
    current: Token,

    const ParseError = error{OutOfMemory, InvalidCharacter, Overflow};

    fn parse(self: *Parser) ParseError!Expr {
        self.current = try self.lexer.nextToken();
        return try self.parseTernary();
    }

    fn advance(self: *Parser) ParseError!void {
        self.current = try self.lexer.nextToken();
    }

    fn parseTernary(self: *Parser) ParseError!Expr {
        const expr = try self.parseOr();
        if (self.current == .QMark) {
            try self.advance();
            const if_true = try self.parseOr();
            if (self.current == .Colon) {
                try self.advance();
                const if_false = try self.parseOr();
                const cond_ptr = try self.lexer.allocator.create(Expr);
                cond_ptr.* = expr;
                const true_ptr = try self.lexer.allocator.create(Expr);
                true_ptr.* = if_true;
                const false_ptr = try self.lexer.allocator.create(Expr);
                false_ptr.* = if_false;
                return Expr{ .Ternary = .{
                    .condition = cond_ptr,
                    .if_true = true_ptr,
                    .if_false = false_ptr,
                }};
            }
        }
        return expr;
    }

    fn parseOr(self: *Parser) ParseError!Expr {
        var left = try self.parseAnd();
        while (self.current == .PipePipe) {
            try self.advance();
            const right = try self.parseAnd();
            const left_ptr = try self.lexer.allocator.create(Expr);
            left_ptr.* = left;
            const right_ptr = try self.lexer.allocator.create(Expr);
            right_ptr.* = right;
            left = Expr{ .BinOp = .{
                .left = left_ptr,
                .op = .Or,
                .right = right_ptr,
            }};
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!Expr {
        var left = try self.parseComparison();
        while (self.current == .AmpAmp) {
            try self.advance();
            const right = try self.parseComparison();
            const left_ptr = try self.lexer.allocator.create(Expr);
            left_ptr.* = left;
            const right_ptr = try self.lexer.allocator.create(Expr);
            right_ptr.* = right;
            left = Expr{ .BinOp = .{
                .left = left_ptr,
                .op = .And,
                .right = right_ptr,
            }};
        }
        return left;
    }

    fn parseComparison(self: *Parser) ParseError!Expr {
        var left = try self.parseAddSub();
        while (true) {
            const op: BinOpKind = switch (self.current) {
                .Gt => .Gt,
                .Lt => .Lt,
                .Gte => .Gte,
                .Lte => .Lte,
                .EqEq => .Eq,
                .NotEq => .Neq,
                else => break,
            };
            try self.advance();
            const right = try self.parseAddSub();
            const left_ptr = try self.lexer.allocator.create(Expr);
            left_ptr.* = left;
            const right_ptr = try self.lexer.allocator.create(Expr);
            right_ptr.* = right;
            left = Expr{ .BinOp = .{
                .left = left_ptr,
                .op = op,
                .right = right_ptr,
            }};
        }
        return left;
    }

    fn parseAddSub(self: *Parser) ParseError!Expr {
        var left = try self.parseMulDiv();
        while (true) {
            const op: BinOpKind = switch (self.current) {
                .Plus => .Add,
                .Minus => .Sub,
                else => break,
            };
            try self.advance();
            const right = try self.parseMulDiv();
            const left_ptr = try self.lexer.allocator.create(Expr);
            left_ptr.* = left;
            const right_ptr = try self.lexer.allocator.create(Expr);
            right_ptr.* = right;
            left = Expr{ .BinOp = .{
                .left = left_ptr,
                .op = op,
                .right = right_ptr,
            }};
        }
        return left;
    }

    fn parseMulDiv(self: *Parser) ParseError!Expr {
        var left = try self.parseUnary();
        while (true) {
            const op: BinOpKind = switch (self.current) {
                .Star => .Mul,
                .Slash => .Div,
                .Percent => .Mod,
                else => break,
            };
            try self.advance();
            const right = try self.parseUnary();
            const left_ptr = try self.lexer.allocator.create(Expr);
            left_ptr.* = left;
            const right_ptr = try self.lexer.allocator.create(Expr);
            right_ptr.* = right;
            left = Expr{ .BinOp = .{
                .left = left_ptr,
                .op = op,
                .right = right_ptr,
            }};
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!Expr {
        if (self.current == .Bang) {
            try self.advance();
            const operand = try self.parseUnary();
            const ptr = try self.lexer.allocator.create(Expr);
            ptr.* = operand;
            return Expr{ .UnaryNot = ptr };
        }
        return try self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseError!Expr {
        var expr = try self.parsePrimary();

        while (true) {
            if (self.current == .Dot) {
                try self.advance();
                if (self.current == .Ident) {
                    const field = self.current.Ident;
                    try self.advance();
                    const base_ptr = try self.lexer.allocator.create(Expr);
                    base_ptr.* = expr;
                    expr = Expr{ .DotAccess = .{
                        .base = base_ptr,
                        .field = field,
                    }};
                    continue;
                }
            }
            if (self.current == .LBracket) {
                try self.advance();
                const index = try self.parseOr();
                if (self.current == .RBracket) {
                    try self.advance();
                    const base_ptr = try self.lexer.allocator.create(Expr);
                    base_ptr.* = expr;
                    const index_ptr = try self.lexer.allocator.create(Expr);
                    index_ptr.* = index;
                    expr = Expr{ .BracketAccess = .{
                        .base = base_ptr,
                        .index = index_ptr,
                    }};
                    continue;
                }
            }
            if (self.current == .LParen) {
                try self.advance();
                var args = std.ArrayList(*const Expr).empty;
                while (self.current != .RParen and self.current != .Eof and self.current != .QMark and self.current != .Colon) {
                    const arg_ptr = try self.lexer.allocator.create(Expr);
                    arg_ptr.* = try self.parseOr();
                    try args.append(self.lexer.allocator, arg_ptr);
                        if (self.current == .Comma) {
                        try self.advance();
                    }
                    if (self.current == .Eof) break;
                }
                if (self.current == .RParen) {
                    try self.advance();
                }

                // Decompose DotAccess chain into namespace + name for function call
                // e.g. Math.min(a, b) -> namespace=["Math"], name="min"
                var ns_list = std.ArrayList([]const u8).empty;
                var func_name: []const u8 = "";

                // Collect all ident parts from left to right by recursion
                const CollectState = struct {
                    parts: *std.ArrayList([]const u8),
                    alloc: std.mem.Allocator,
                    fn collect(cs: @This(), e: Expr) std.mem.Allocator.Error!void {
                        switch (e) {
                            .Ident => |name| {
                                try cs.parts.append(cs.alloc, name);
                            },
                            .DotAccess => |access| {
                                try cs.collect(access.base.*);
                                try cs.parts.append(cs.alloc, access.field);
                            },
                            else => {
                                // Non-ident base: treat entire expr as function name
                            },
                        }
                    }
                };
                var parts = std.ArrayList([]const u8).empty;
                const cs = CollectState{ .parts = &parts, .alloc = self.lexer.allocator };
                try cs.collect(expr);

                if (parts.items.len > 1) {
                    // All but last are namespace, last is function name
                    func_name = parts.items[parts.items.len - 1];
                    for (parts.items[0 .. parts.items.len - 1]) |p| {
                        try ns_list.append(self.lexer.allocator, p);
                    }
                } else if (parts.items.len == 1) {
                    func_name = parts.items[0];
                }
                parts.deinit(self.lexer.allocator);

                return Expr{ .FuncCall = .{
                    .namespace = try ns_list.toOwnedSlice(self.lexer.allocator),
                    .name = func_name,
                    .args = try args.toOwnedSlice(self.lexer.allocator),
                }};
            }
            if (self.current == .Pipe) {
                try self.advance();
                const filter_name = switch (self.current) {
                    .Ident => self.current.Ident,
                    else => "",
                };
                if (self.current == .Ident) {
                    try self.advance();
                }
                var filter_args = std.ArrayList(*const Expr).empty;
                while (self.current == .Ident or self.current == .String or self.current == .Int or self.current == .Float) {
                    const farg_ptr = try self.lexer.allocator.create(Expr);
                    farg_ptr.* = try self.parseOr();
                    try filter_args.append(self.lexer.allocator, farg_ptr);
                }
                const expr_ptr = try self.lexer.allocator.create(Expr);
                expr_ptr.* = expr;
                expr = Expr{ .Pipe = .{
                    .expr = expr_ptr,
                    .filter = filter_name,
                    .args = try filter_args.toOwnedSlice(self.lexer.allocator),
                }};
                continue;
            }
            break;
        }
        return expr;
    }

    fn parsePrimary(self: *Parser) ParseError!Expr {
        switch (self.current) {
            .Int => |n| {
                const val = n;
                try self.advance();
                return .{ .IntLit = val };
            },
            .Float => |f| {
                const val = f;
                try self.advance();
                return .{ .FloatLit = val };
            },
            .String => |s| {
                const val = s;
                try self.advance();
                return .{ .StringLit = val };
            },
            .BoolLit => |b| {
                const val = b;
                try self.advance();
                return .{ .BoolLit = val };
            },
            .NullLit => {
                try self.advance();
                return .NullLit;
            },
            .Ident => |name| {
                try self.advance();
                return .{ .Ident = name };
            },
            .LParen => {
                try self.advance();
                const expr = try self.parseOr();
                if (self.current == .RParen) {
                    try self.advance();
                }
                return expr;
            },
            else => return .NullLit,
        }
    }
};

const Marker = struct {
    start: usize,
    end: usize,
    expr: []const u8,
};

fn findTemplateMarkers(s: []const u8, allocator: std.mem.Allocator) ![]Marker {
    var markers = std.ArrayList(Marker).empty;
    var i: usize = 0;
    while (i < s.len) {
        if (i + 4 < s.len and s[i] == '$' and s[i + 1] == '{' and s[i + 2] == '{' and s[i + 3] == ' ') {
            // Found ${{
            const start = i;
            const expr_start = i + 4;
            var j = expr_start;
            var depth: usize = 0;
            while (j + 1 < s.len) {
                if (s[j] == '{') {
                    depth += 1;
                } else if (s[j] == '}' and j + 1 < s.len and s[j + 1] == '}') {
                    if (depth == 0) {
                        const end = j + 2;
                        const expr = std.mem.trim(u8, s[expr_start..j], " \t\n\r");
                        try markers.append(allocator, Marker{
                            .start = start,
                            .end = end,
                            .expr = try allocator.dupe(u8, expr),
                        });
                        i = end;
                        break;
                    }
                    depth -= 1;
                }
                j += 1;
            }
            if (j + 1 >= s.len) {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    return try markers.toOwnedSlice(allocator);
}

fn valueToString(allocator: std.mem.Allocator, val: json.Value) ![]const u8 {
    return switch (val) {
        .null => try allocator.dupe(u8, ""),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .integer => |i| try std.fmt.allocPrint(allocator, "{}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{}", .{f}),
        .number_string => |ns| try allocator.dupe(u8, ns),
        .string => |s| try allocator.dupe(u8, s),
        else => try allocator.dupe(u8, ""),
    };
}

fn freeJsonValue(allocator: std.mem.Allocator, val: json.Value) void {
    switch (val) {
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var mut_arr = arr; mut_arr.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var mut_obj = obj; mut_obj.deinit(allocator);
        },
        else => {},
    }
}

fn evaluate(expr: Expr, ctx: TemplateContext, allocator: std.mem.Allocator) CliError!json.Value {
    return switch (expr) {
        .IntLit => |n| .{ .integer = n },
        .FloatLit => |f| .{ .float = f },
        .StringLit => |s| .{ .string = try allocator.dupe(u8, s) },
        .BoolLit => |b| .{ .bool = b },
        .NullLit => .null,
        .Ident => |name| try resolveIdent(name, ctx, allocator),
        .DotAccess => |access| blk: {
            const base_val = try evaluate(access.base.*, ctx, allocator);
            const field_val = accessField(base_val, access.field);
            const result = try copyJsonValue(allocator, field_val);
            freeJsonValue(allocator, base_val);
            break :blk result;
        },
        .BracketAccess => |access| blk: {
            const base_val = try evaluate(access.base.*, ctx, allocator);
            const index_val = try evaluate(access.index.*, ctx, allocator);
            const elem_val = accessIndex(base_val, index_val);
            const result = try copyJsonValue(allocator, elem_val);
            freeJsonValue(allocator, base_val);
            freeJsonValue(allocator, index_val);
            break :blk result;
        },
        .FuncCall => |call| blk: {
            var eval_args = std.ArrayList(json.Value).empty;
            defer eval_args.deinit(allocator);
            for (call.args) |arg| {
                try eval_args.append(allocator, try evaluate(arg.*, ctx, allocator));
            }
            const owned_args = try eval_args.toOwnedSlice(allocator);
            defer {
                for (owned_args) |a| freeJsonValue(allocator, a);
                allocator.free(owned_args);
            }
            break :blk try callFunction(call.namespace, call.name, owned_args, allocator);
        },
        .UnaryNot => |operand| blk: {
            const val = try evaluate(operand.*, ctx, allocator);
            const result: json.Value = .{ .bool = !isTruthy(val) };
            freeJsonValue(allocator, val);
            break :blk result;
        },
        .BinOp => |binop| blk: {
            const lval = try evaluate(binop.left.*, ctx, allocator);
            switch (binop.op) {
                .Or => {
                    if (isTruthy(lval)) break :blk lval;
                    freeJsonValue(allocator, lval);
                    break :blk try evaluate(binop.right.*, ctx, allocator);
                },
                .And => {
                    if (!isTruthy(lval)) break :blk lval;
                    freeJsonValue(allocator, lval);
                    break :blk try evaluate(binop.right.*, ctx, allocator);
                },
                else => {
                    const rval = try evaluate(binop.right.*, ctx, allocator);
                    const result = try evalBinop(binop.op, lval, rval);
                    freeJsonValue(allocator, lval);
                    freeJsonValue(allocator, rval);
                    break :blk result;
                },
            }
        },
        .Ternary => |t| blk: {
            const cond = try evaluate(t.condition.*, ctx, allocator);
            const result = if (isTruthy(cond))
                try evaluate(t.if_true.*, ctx, allocator)
            else
                try evaluate(t.if_false.*, ctx, allocator);
            freeJsonValue(allocator, cond);
            break :blk result;
        },
        .Pipe => |pipe| blk: {
            const val = try evaluate(pipe.expr.*, ctx, allocator);
            var eval_args = std.ArrayList(json.Value).empty;
            defer eval_args.deinit(allocator);
            for (pipe.args) |arg| {
                try eval_args.append(allocator, try evaluate(arg.*, ctx, allocator));
            }
            const filter_args = try eval_args.toOwnedSlice(allocator);
            defer {
                for (filter_args) |a| freeJsonValue(allocator, a);
                allocator.free(filter_args);
            }
            const result = try applyFilter(pipe.filter, val, filter_args, allocator);
            freeJsonValue(allocator, val);
            break :blk result;
        },
    };
}

fn resolveIdent(name: []const u8, ctx: TemplateContext, allocator: std.mem.Allocator) CliError!json.Value {
    if (std.mem.eql(u8, name, "args")) {
        var result = try json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{});
        errdefer {
            var it = result.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            result.deinit(allocator);
        }
        var iter = ctx.args.iterator();
        while (iter.next()) |entry| {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const value = try copyJsonValue(allocator, entry.value_ptr.*);
            try result.put(allocator, key, value);
        }
        return .{ .object = result };
    }
    if (std.mem.eql(u8, name, "data")) return try copyJsonValue(allocator, ctx.data);
    if (std.mem.eql(u8, name, "item")) return try copyJsonValue(allocator, ctx.item);
    if (std.mem.eql(u8, name, "index")) return .{ .integer = @as(i64, @intCast(ctx.index)) };
    if (std.mem.eql(u8, name, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, name, "false")) return .{ .bool = false };
    if (std.mem.eql(u8, name, "null")) return .null;
    if (ctx.args.get(name)) |val| return try copyJsonValue(allocator, val);
    return .null;
}

fn accessField(val: json.Value, field: []const u8) json.Value {
    switch (val) {
        .object => |obj| return obj.get(field) orelse .null,
        .array => |arr| {
            if (std.mem.eql(u8, field, "length")) {
                return .{ .integer = @as(i64, @intCast(arr.items.len)) };
            }
            return .null;
        },
        .string => |s| {
            if (std.mem.eql(u8, field, "length")) {
                return .{ .integer = @as(i64, @intCast(s.len)) };
            }
            return .null;
        },
        else => return .null,
    }
}

fn accessIndex(val: json.Value, index: json.Value) json.Value {
    switch (val) {
        .array => |arr| {
            if (index == .integer) {
                const i: i64 = index.integer;
                if (i >= 0 and i < arr.items.len) {
                    return arr.items[@intCast(i)];
                }
            }
            return .null;
        },
        .object => |obj| {
            if (index == .string) {
                return obj.get(index.string) orelse .null;
            }
            return .null;
        },
        else => return .null,
    }
}

fn isTruthy(val: json.Value) bool {
    return switch (val) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0,
        .number_string => |ns| ns.len > 0,
        .string => |s| s.len > 0,
        .array => |arr| arr.items.len > 0,
        .object => |obj| obj.count() > 0,
    };
}

fn valueEquals(a: json.Value, b: json.Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .string => |v| std.mem.eql(u8, v, b.string),
        .array => |v| v.items.len == b.array.items.len and blk: {
            for (v.items, b.array.items) |ai, bi| {
                if (!valueEquals(ai, bi)) break :blk false;
            }
            break :blk true;
        },
        .object => |v| v.count() == b.object.count() and blk: {
            var iter = v.iterator();
            while (iter.next()) |entry| {
                const bval = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!valueEquals(entry.value_ptr.*, bval)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn evalBinop(op: BinOpKind, left: json.Value, right: json.Value) CliError!json.Value {
    switch (op) {
        .Add => {
            if (left == .integer and right == .integer) {
                const li = left.integer;
                const ri = right.integer;
                return .{ .integer = li + ri };
            }
            if (left == .string and right == .string) {
                return left;
            }
            return left;
        },
        .Sub => {
            if (left == .integer and right == .integer) {
                const li = left.integer;
                const ri = right.integer;
                return .{ .integer = li - ri };
            }
            return left;
        },
        .Mul => {
            if (left == .integer and right == .integer) {
                const li = left.integer;
                const ri = right.integer;
                return .{ .integer = li * ri };
            }
            return left;
        },
        .Div => {
            if (left == .integer and right == .integer) {
                const li = left.integer;
                const ri = right.integer;
                if (ri != 0) {
                    return .{ .integer = @divTrunc(li, ri) };
                }
            }
            return .null;
        },
        .Mod => {
            if (left == .integer and right == .integer) {
                const li = left.integer;
                const ri = right.integer;
                if (ri != 0) {
                    return .{ .integer = @mod(li, ri) };
                }
            }
            return .null;
        },
        .Gt => {
            if (left == .integer and right == .integer) {
                const li = left.integer;
                const ri = right.integer;
                return .{ .bool = li > ri };
            }
            return .{ .bool = false };
        },
        .Lt => {
            if (left == .integer and right == .integer) {
                const li = left.integer;
                const ri = right.integer;
                return .{ .bool = li < ri };
            }
            return .{ .bool = false };
        },
        .Gte => {
            if (left == .integer and right == .integer) {
                const li = left.integer;
                const ri = right.integer;
                return .{ .bool = li >= ri };
            }
            return .{ .bool = false };
        },
        .Lte => {
            if (left == .integer and right == .integer) {
                const li = left.integer;
                const ri = right.integer;
                return .{ .bool = li <= ri };
            }
            return .{ .bool = false };
        },
        .Eq => {
            return .{ .bool = valueEquals(left, right) };
        },
        .Neq => {
            return .{ .bool = !valueEquals(left, right) };
        },
        .And, .Or => {
            return left;
        },
    }
}

fn callFunction(namespace: []const []const u8, name: []const u8, args: []const json.Value, allocator: std.mem.Allocator) CliError!json.Value {
    // Handle Math namespace functions
    const is_math = namespace.len == 1 and std.mem.eql(u8, namespace[0], "Math");
    if (is_math) {
        if (std.mem.eql(u8, name, "min")) {
            if (args.len >= 2) {
                const a = args[0];
                const b = args[1];
                if (a == .integer and b == .integer) {
                    return .{ .integer = @min(a.integer, b.integer) };
                }
                if (a == .integer and b == .float) {
                    return .{ .float = @min(@as(f64, @floatFromInt(a.integer)), b.float) };
                }
                if (a == .float and b == .integer) {
                    return .{ .float = @min(a.float, @as(f64, @floatFromInt(b.integer))) };
                }
                if (a == .float and b == .float) {
                    return .{ .float = @min(a.float, b.float) };
                }
            }
            return .null;
        }
        if (std.mem.eql(u8, name, "max")) {
            if (args.len >= 2) {
                const a = args[0];
                const b = args[1];
                if (a == .integer and b == .integer) {
                    return .{ .integer = @max(a.integer, b.integer) };
                }
                if (a == .integer and b == .float) {
                    return .{ .float = @max(@as(f64, @floatFromInt(a.integer)), b.float) };
                }
                if (a == .float and b == .integer) {
                    return .{ .float = @max(a.float, @as(f64, @floatFromInt(b.integer))) };
                }
                if (a == .float and b == .float) {
                    return .{ .float = @max(a.float, b.float) };
                }
            }
            return .null;
        }
        if (std.mem.eql(u8, name, "abs")) {
            if (args.len >= 1) {
                if (args[0] == .integer) return .{ .integer = @as(i64, @intCast(@abs(args[0].integer))) };
                if (args[0] == .float) return .{ .float = @abs(args[0].float) };
            }
            return .null;
        }
        if (std.mem.eql(u8, name, "floor")) {
            if (args.len >= 1 and args[0] == .float) {
                return .{ .integer = @as(i64, @intFromFloat(@floor(args[0].float))) };
            }
            return .null;
        }
        if (std.mem.eql(u8, name, "ceil")) {
            if (args.len >= 1 and args[0] == .float) {
                return .{ .integer = @as(i64, @intFromFloat(@ceil(args[0].float))) };
            }
            return .null;
        }
        return .null;
    }

    // Non-namespace functions
    if (std.mem.eql(u8, name, "default")) {
        if (args.len > 0) return try copyJsonValue(allocator, args[0]);
        return .null;
    }
    if (std.mem.eql(u8, name, "length") or std.mem.eql(u8, name, "len")) {
        if (args.len > 0) {
            return switch (args[0]) {
                .string => |s| .{ .integer = @as(i64, @intCast(s.len)) },
                .array => |a| .{ .integer = @as(i64, @intCast(a.items.len)) },
                .object => |o| .{ .integer = @as(i64, @intCast(o.count())) },
                else => .{ .integer = 0 },
            };
        }
        return .{ .integer = 0 };
    }
    return .null;
}

fn applyFilter(name: []const u8, input: json.Value, args: []const json.Value, allocator: std.mem.Allocator) CliError!json.Value {
    // String filters
    if (std.mem.eql(u8, name, "upper")) {
        return switch (input) {
            .string => |s| .{ .string = try std.ascii.allocUpperString(allocator, s) },
            else => try copyJsonValue(allocator, input),
        };
    }
    if (std.mem.eql(u8, name, "lower")) {
        return switch (input) {
            .string => |s| .{ .string = try std.ascii.allocLowerString(allocator, s) },
            else => try copyJsonValue(allocator, input),
        };
    }
    if (std.mem.eql(u8, name, "trim")) {
        return switch (input) {
            .string => |s| .{ .string = try allocator.dupe(u8, std.mem.trim(u8, s, " \t\r\n")) },
            else => try copyJsonValue(allocator, input),
        };
    }
    if (std.mem.eql(u8, name, "truncate")) {
        const n = if (args.len > 0 and args[0] == .integer) @as(usize, @intCast(args[0].integer)) else 50;
        return switch (input) {
            .string => |s| blk: {
                if (s.len > n) {
                    const truncated = s[0..n];
                    break :blk .{ .string = try std.fmt.allocPrint(allocator, "{s}...", .{truncated}) };
                }
                break :blk .{ .string = try allocator.dupe(u8, s) };
            },
            else => try copyJsonValue(allocator, input),
        };
    }
    if (std.mem.eql(u8, name, "replace")) {
        const old_str = if (args.len > 0 and args[0] == .string) args[0].string else "";
        const new_str = if (args.len > 1 and args[1] == .string) args[1].string else "";
        return switch (input) {
            .string => |s| blk: {
                var result = std.ArrayList(u8).empty;
                defer result.deinit(allocator);
                var remaining = s;
                while (std.mem.indexOf(u8, remaining, old_str)) |pos| {
                    try result.appendSlice(allocator, remaining[0..pos]);
                    try result.appendSlice(allocator, new_str);
                    remaining = remaining[pos + old_str.len ..];
                }
                try result.appendSlice(allocator, remaining);
                break :blk .{ .string = try result.toOwnedSlice(allocator) };
            },
            else => try copyJsonValue(allocator, input),
        };
    }
    if (std.mem.eql(u8, name, "slugify")) {
        return switch (input) {
            .string => |s| blk: {
                var result = std.ArrayList(u8).empty;
                defer result.deinit(allocator);
                var last_hyphen = false;
                var started = false;
                for (s) |c| {
                    if (std.ascii.isAlphanumeric(c)) {
                        try result.append(allocator, std.ascii.toLower(c));
                        last_hyphen = false;
                        started = true;
                    } else if (c == ' ' or c == '_') {
                        if (started and !last_hyphen) {
                            try result.append(allocator, '-');
                            last_hyphen = true;
                        }
                    }
                    // else skip
                }
                // Trim trailing hyphens
                while (result.items.len > 0 and result.items[result.items.len - 1] == '-') {
                    _ = result.pop();
                }
                break :blk .{ .string = try result.toOwnedSlice(allocator) };
            },
            else => try copyJsonValue(allocator, input),
        };
    }
    if (std.mem.eql(u8, name, "sanitize")) {
        return switch (input) {
            .string => |s| blk: {
                var result = std.ArrayList(u8).empty;
                defer result.deinit(allocator);
                var in_tag = false;
                for (s) |c| {
                    if (c == '<') { in_tag = true; continue; }
                    if (c == '>') { in_tag = false; continue; }
                    if (!in_tag) try result.append(allocator, c);
                }
                break :blk .{ .string = try result.toOwnedSlice(allocator) };
            },
            else => try copyJsonValue(allocator, input),
        };
    }
    if (std.mem.eql(u8, name, "ext")) {
        return switch (input) {
            .string => |s| blk: {
                if (std.mem.lastIndexOfScalar(u8, s, '.')) |pos| {
                    break :blk .{ .string = try allocator.dupe(u8, s[pos..]) };
                }
                break :blk .{ .string = "" };
            },
            else => input,
        };
    }
    if (std.mem.eql(u8, name, "basename")) {
        return switch (input) {
            .string => |s| blk: {
                const bname = if (std.mem.lastIndexOfScalar(u8, s, '/')) |pos| s[pos + 1 ..] else s;
                break :blk .{ .string = try allocator.dupe(u8, bname) };
            },
            else => try copyJsonValue(allocator, input),
        };
    }
    if (std.mem.eql(u8, name, "string") or std.mem.eql(u8, name, "str")) {
        return switch (input) {
            .string => input,
            .null => .{ .string = "" },
            .integer => |n| .{ .string = try std.fmt.allocPrint(allocator, "{}", .{n}) },
            .float => |f| .{ .string = try std.fmt.allocPrint(allocator, "{}", .{f}) },
            .bool => |b| .{ .string = try allocator.dupe(u8, if (b) "true" else "false") },
            else => try copyJsonValue(allocator, input), // array/object — could stringify
        };
    }
    if (std.mem.eql(u8, name, "int")) {
        return switch (input) {
            .integer => input,
            .float => |f| .{ .integer = @as(i64, @intFromFloat(f)) },
            .string => |s| blk: {
                const n = std.fmt.parseInt(i64, s, 10) catch 0;
                break :blk .{ .integer = n };
            },
            .bool => |b| .{ .integer = if (b) 1 else 0 },
            else => .{ .integer = 0 },
        };
    }
    if (std.mem.eql(u8, name, "float")) {
        return switch (input) {
            .float => input,
            .integer => |n| .{ .float = @as(f64, @floatFromInt(n)) },
            .string => |s| blk: {
                const f = std.fmt.parseFloat(f64, s) catch 0.0;
                break :blk .{ .float = f };
            },
            else => .{ .float = 0.0 },
        };
    }
    if (std.mem.eql(u8, name, "abs")) {
        return switch (input) {
            .integer => |n| .{ .integer = if (n < 0) -n else n },
            .float => |f| .{ .float = @abs(f) },
            else => try copyJsonValue(allocator, input),
        };
    }
    if (std.mem.eql(u8, name, "round")) {
        return switch (input) {
            .float => |f| .{ .float = @round(f) },
            else => try copyJsonValue(allocator, input),
        };
    }
    if (std.mem.eql(u8, name, "ceil")) {
        return switch (input) {
            .float => |f| .{ .float = @ceil(f) },
            else => try copyJsonValue(allocator, input),
        };
    }
    if (std.mem.eql(u8, name, "floor")) {
        return switch (input) {
            .float => |f| .{ .float = @floor(f) },
            else => try copyJsonValue(allocator, input),
        };
    }

    // Array/Object filters
    if (std.mem.eql(u8, name, "join")) {
        const sep = if (args.len > 0 and args[0] == .string) args[0].string else ",";
        return switch (input) {
            .array => |arr| blk: {
                var result = std.ArrayList(u8).empty;
                defer result.deinit(allocator);
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try result.appendSlice(allocator, sep);
                    const s = try valueToString(allocator, item);
                    defer allocator.free(s);
                    try result.appendSlice(allocator, s);
                }
                break :blk .{ .string = try result.toOwnedSlice(allocator) };
            },
            else => try copyJsonValue(allocator, input),
        };
    }
    if (std.mem.eql(u8, name, "keys")) {
        return switch (input) {
            .object => |obj| blk: {
                var keys = std.array_list.Managed(json.Value).init(allocator);
                errdefer keys.deinit();
                var it = obj.iterator();
                while (it.next()) |entry| {
                    try keys.append(.{ .string = entry.key_ptr.* });
                }
                break :blk .{ .array = keys };
            },
            else => .{ .array = std.array_list.Managed(json.Value).init(allocator) },
        };
    }
    if (std.mem.eql(u8, name, "first")) {
        return switch (input) {
            .array => |arr| if (arr.items.len > 0) arr.items[0] else .null,
            else => .null,
        };
    }
    if (std.mem.eql(u8, name, "last")) {
        return switch (input) {
            .array => |arr| if (arr.items.len > 0) arr.items[arr.items.len - 1] else .null,
            else => .null,
        };
    }
    if (std.mem.eql(u8, name, "reverse")) {
        return switch (input) {
            .array => |arr| blk: {
                var result = std.array_list.Managed(json.Value).init(allocator);
                errdefer result.deinit();
                var i: usize = arr.items.len;
                while (i > 0) {
                    i -= 1;
                    try result.append(arr.items[i]);
                }
                break :blk .{ .array = result };
            },
            .string => |s| blk: {
                var result = std.ArrayList(u8).empty;
                defer result.deinit(allocator);
                var i: usize = s.len;
                while (i > 0) {
                    i -= 1;
                    try result.append(allocator, s[i]);
                }
                break :blk .{ .string = try result.toOwnedSlice(allocator) };
            },
            else => try copyJsonValue(allocator, input),
        };
    }
    if (std.mem.eql(u8, name, "unique")) {
        return switch (input) {
            .array => |arr| blk: {
                var result = std.array_list.Managed(json.Value).init(allocator);
                errdefer result.deinit();
                var seen = std.array_list.Managed([]const u8).init(allocator);
                defer seen.deinit();
                for (arr.items) |item| {
                    const key = try valueToString(allocator, item);
                    defer allocator.free(key);
                    var found = false;
                    for (seen.items) |k| {
                        if (std.mem.eql(u8, k, key)) { found = true; break; }
                    }
                    if (!found) {
                        try seen.append(try allocator.dupe(u8, key));
                        try result.append(item);
                    }
                }
                break :blk .{ .array = result };
            },
            else => input,
        };
    }
    if (std.mem.eql(u8, name, "split")) {
        const sep = if (args.len > 0 and args[0] == .string) args[0].string else ",";
        return switch (input) {
            .string => |s| blk: {
                var result = std.array_list.Managed(json.Value).init(allocator);
                errdefer result.deinit();
                var remaining = s;
                while (std.mem.indexOf(u8, remaining, sep)) |pos| {
                    try result.append(.{ .string = try allocator.dupe(u8, remaining[0..pos]) });
                    remaining = remaining[pos + sep.len ..];
                }
                try result.append(.{ .string = try allocator.dupe(u8, remaining) });
                break :blk .{ .array = result };
            },
            else => try copyJsonValue(allocator, input),
        };
    }

    // Other filters
    if (std.mem.eql(u8, name, "json")) {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        json.fmt(input, .{}).format(&aw.writer) catch return CliError.Pipeline;
        const s = aw.toOwnedSlice() catch return CliError.Pipeline;
        return .{ .string = s };
    }
    if (std.mem.eql(u8, name, "urlencode")) {
        return switch (input) {
            .string => |s| blk: {
                var result = std.ArrayList(u8).empty;
                defer result.deinit(allocator);
                for (s) |b| {
                    switch (b) {
                        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try result.append(allocator, b),
                        else => {
                            const hex_chars = "0123456789ABCDEF";
                            const hex = [_]u8{ '%', hex_chars[b >> 4], hex_chars[b & 0xF] };
                            try result.appendSlice(allocator, &hex);
                        },
                    }
                }
                break :blk .{ .string = try result.toOwnedSlice(allocator) };
            },
            else => blk: {
                const s = try valueToString(allocator, input);
                var result = std.ArrayList(u8).empty;
                defer result.deinit(allocator);
                for (s) |b| {
                    switch (b) {
                        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try result.append(allocator, b),
                        else => {
                            const hex_chars = "0123456789ABCDEF";
                            const hex = [_]u8{ '%', hex_chars[b >> 4], hex_chars[b & 0xF] };
                            try result.appendSlice(allocator, &hex);
                        },
                    }
                }
                break :blk .{ .string = try result.toOwnedSlice(allocator) };
            },
        };
    }
    if (std.mem.eql(u8, name, "urldecode")) {
        return switch (input) {
            .string => |s| blk: {
                var result = std.ArrayList(u8).empty;
                defer result.deinit(allocator);
                var i: usize = 0;
                while (i < s.len) {
                    if (s[i] == '%' and i + 2 < s.len) {
                        const val = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch s[i];
                        try result.append(allocator, val);
                        i += 3;
                    } else if (s[i] == '+') {
                        try result.append(allocator, ' ');
                        i += 1;
                    } else {
                        try result.append(allocator, s[i]);
                        i += 1;
                    }
                }
                break :blk .{ .string = try result.toOwnedSlice(allocator) };
            },
            else => try copyJsonValue(allocator, input),
        };
    }

    // Existing filters
    if (std.mem.eql(u8, name, "default")) {
        if (!isTruthy(input)) {
            if (args.len > 0) return args[0];
        }
        return input;
    }
    if (std.mem.eql(u8, name, "length")) {
        return switch (input) {
            .string => |s| .{ .integer = @as(i64, @intCast(s.len)) },
            .array => |a| .{ .integer = @as(i64, @intCast(a.items.len)) },
            .object => |o| .{ .integer = @as(i64, @intCast(o.count())) },
            else => .{ .integer = 0 },
        };
    }
    return input;
}
fn copyJsonValue(allocator: std.mem.Allocator, val: json.Value) CliError!json.Value {
    switch (val) {
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            const items = try allocator.alloc(json.Value, arr.items.len);
            errdefer {
                for (items) |item| freeJsonValue(allocator, item);
                allocator.free(items);
            }
            for (arr.items, 0..) |item, i| {
                items[i] = try copyJsonValue(allocator, item);
            }
            return .{ .array = std.array_list.Managed(json.Value){ .items = items, .capacity = items.len, .allocator = allocator } };
        },
        .object => |obj| {
            var result = try json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{});
            errdefer {
                var it = result.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    freeJsonValue(allocator, entry.value_ptr.*);
                }
                result.deinit(allocator);
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                const value = try copyJsonValue(allocator, entry.value_ptr.*);
                try result.put(allocator, key, value);
            }
            return .{ .object = result };
        },
        else => return val,
    }
}

fn copyJsonValueCleanup(allocator: std.mem.Allocator, val: json.Value) void {
    freeJsonValue(allocator, val);
}

fn freeExpr(allocator: std.mem.Allocator, expr: *const Expr) void {
    switch (expr.*) {
        .StringLit => |s| allocator.free(s),
        .Ident => |s| allocator.free(s),
        .DotAccess => |da| {
            freeExprTree(allocator, @constCast(da.base));
            allocator.free(da.field);
        },
        .BracketAccess => |ba| {
            freeExprTree(allocator, @constCast(ba.base));
            freeExprTree(allocator, @constCast(ba.index));
        },
        .FuncCall => |fc| {
            for (fc.namespace) |ns| allocator.free(ns);
            allocator.free(fc.namespace);
            allocator.free(fc.name);
            for (fc.args) |arg| freeExprTree(allocator, @constCast(arg));
            allocator.free(fc.args);
        },
        .UnaryNot => |e| freeExprTree(allocator, @constCast(e)),
        .BinOp => |bo| {
            freeExprTree(allocator, @constCast(bo.left));
            freeExprTree(allocator, @constCast(bo.right));
        },
        .Ternary => |t| {
            freeExprTree(allocator, @constCast(t.condition));
            freeExprTree(allocator, @constCast(t.if_true));
            freeExprTree(allocator, @constCast(t.if_false));
        },
        .Pipe => |p| {
            freeExprTree(allocator, @constCast(p.expr));
            allocator.free(p.filter);
            for (p.args) |arg| freeExprTree(allocator, @constCast(arg));
            allocator.free(p.args);
        },
        else => {},
    }
}

fn freeExprTree(allocator: std.mem.Allocator, expr: *Expr) void {
    freeExpr(allocator, expr);
    allocator.destroy(expr);
}

pub fn renderTemplate(template_json: json.Value, ctx: TemplateContext, allocator: std.mem.Allocator) CliError!json.Value {
    return switch (template_json) {
        .string => |s| renderTemplateStr(s, ctx, allocator),
        .object => |obj| {
            var result = json.ObjectMap.init(allocator, &.{}, &.{}) catch return error.OutOfMemory;
            errdefer {
                var it = result.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    freeJsonValue(allocator, entry.value_ptr.*);
                }
                result.deinit(allocator);
            }
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                const rendered_val = try renderTemplate(entry.value_ptr.*, ctx, allocator);
                try result.put(allocator, key, rendered_val);
            }
            return .{ .object = result };
        },
        else => template_json,
    };
}

/// Render a single template string
pub fn renderTemplateStr(template: []const u8, ctx: TemplateContext, allocator: std.mem.Allocator) CliError!json.Value {
    const markers = try findTemplateMarkers(template, allocator);
    defer {
        for (markers) |m| allocator.free(m.expr);
        allocator.free(markers);
    }

    if (markers.len == 0) {
        const duped = try allocator.dupe(u8, template);
        return .{ .string = duped };
    }

    // Full expression mode
    if (markers.len == 1 and markers.len > 0 and markers[0].start == 0 and markers[0].end == template.len) {
        const lexer = try allocator.create(Lexer);
        lexer.* = Lexer{
            .input = markers[0].expr,
            .pos = 0,
            .allocator = allocator,
        };
        defer allocator.destroy(lexer);
        const parser = try allocator.create(Parser);
        parser.* = Parser{ .lexer = lexer, .current = .Eof };
        defer allocator.destroy(parser);
        const parsed_expr = parser.parse() catch {
            return CliError.Pipeline;
        };
        defer freeExpr(allocator, &parsed_expr);
        const result = evaluate(parsed_expr, ctx, allocator) catch {
            return CliError.Pipeline;
        };
        return result;
    }

    // Partial interpolation
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var last_end: usize = 0;

    for (markers) |m| {
        try result.appendSlice(allocator, template[last_end..m.start]);
        const lexer = try allocator.create(Lexer);
        lexer.* = Lexer{
            .input = m.expr,
            .pos = 0,
            .allocator = allocator,
        };
        defer allocator.destroy(lexer);
        const parser = try allocator.create(Parser);
        parser.* = Parser{ .lexer = lexer, .current = .Eof };
        defer allocator.destroy(parser);
        const val = blk: {
            const parsed_expr = parser.parse() catch return CliError.Pipeline;
            defer freeExpr(allocator, &parsed_expr);
            break :blk try evaluate(parsed_expr, ctx, allocator);
        };
        defer freeJsonValue(allocator, val);
        const val_str = try valueToString(allocator, val);
        defer allocator.free(val_str);
        try result.appendSlice(allocator, val_str);
        last_end = m.end;
    }
    try result.appendSlice(allocator, template[last_end..]);

    return .{ .string = try result.toOwnedSlice(allocator) };
}



test {
    _ = @import("tests.zig");
}
