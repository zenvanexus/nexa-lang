const std = @import("std");
const ast = @import("ast.zig");
const lex = @import("lex.zig");

pub const ParseError = lex.LexError || error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    OutOfMemory,
};

fn stops(tag: lex.Tag, comptime list: []const lex.Tag) bool {
    inline for (list) |s| {
        if (tag == s) return true;
    }
    return false;
}

const Parser = struct {
    tokens: []const lex.Token,
    i: usize,
    arena: std.mem.Allocator,
    src: []const u8,

    fn peek(p: Parser) lex.Token {
        return p.tokens[p.i];
    }
    fn at(p: Parser) lex.Tag {
        return p.peek().tag;
    }
    fn advance(p: *Parser) void {
        p.i += 1;
    }
    fn eat(p: *Parser, tag: lex.Tag) ParseError!void {
        if (p.at() != tag) return error.UnexpectedToken;
        p.advance();
    }
    fn match(p: *Parser, tag: lex.Tag) bool {
        if (p.at() == tag) {
            p.advance();
            return true;
        }
        return false;
    }

    fn dup(p: Parser, s: []const u8) ParseError![]const u8 {
        return p.arena.dupe(u8, s) catch return error.OutOfMemory;
    }

    fn allocExpr(p: Parser, e: ast.Expr) ParseError!*ast.Expr {
        const ptr = p.arena.create(ast.Expr) catch return error.OutOfMemory;
        ptr.* = e;
        return ptr;
    }

    fn allocStmt(p: Parser, s: ast.Stmt) ParseError!*ast.Stmt {
        const ptr = p.arena.create(ast.Stmt) catch return error.OutOfMemory;
        ptr.* = s;
        return ptr;
    }

    fn allocBlock(p: Parser, stmts: []const *ast.Stmt) ParseError!*ast.Block {
        const b = p.arena.create(ast.Block) catch return error.OutOfMemory;
        b.* = .{ .stmts = stmts };
        return b;
    }

    fn parseChunk(p: *Parser) ParseError!*ast.Block {
        const stmts = try p.stmtList(&.{.eof});
        try p.eat(.eof);
        return p.allocBlock(stmts);
    }

    fn stmtList(p: *Parser, comptime stop: []const lex.Tag) ParseError![]const *ast.Stmt {
        var list: std.ArrayListUnmanaged(*ast.Stmt) = .{};
        defer list.deinit(p.arena);
        while (!stops(p.at(), stop)) {
            if (p.at() == .eof) return error.UnexpectedEof;
            const st = try p.stmt(stop);
            try list.append(p.arena, st);
        }
        return list.toOwnedSlice(p.arena) catch return error.OutOfMemory;
    }

    fn stmt(p: *Parser, comptime outer_stop: []const lex.Tag) ParseError!*ast.Stmt {
        switch (p.at()) {
            .local => return p.parseLocal(),
            .function => return p.parseFunctionDecl(),
            .if_kw => return p.parseIfStatement(),
            .while_kw => return p.parseWhile(),
            .repeat => return p.parseRepeat(),
            .do => return p.parseDoEnd(),
            .return_kw => return p.parseReturn(outer_stop),
            .break_kw => {
                p.advance();
                return p.allocStmt(.{ .break_stmt = {} });
            },
            else => {
                const lhs = try p.parseExpr(0);
                if (p.at() == .eq or p.at() == .comma) {
                    return p.parseAssignLike(lhs);
                }
                return p.allocStmt(.{ .expr = lhs });
            },
        }
    }

    fn parseLocal(p: *Parser) ParseError!*ast.Stmt {
        try p.eat(.local);
        var names: std.ArrayListUnmanaged([]const u8) = .{};
        defer names.deinit(p.arena);
        while (true) {
            if (p.at() != .ident) return error.UnexpectedToken;
            try names.append(p.arena, try p.dup(p.peek().lexeme));
            p.advance();
            if (p.match(.comma)) continue else break;
        }
        var inits: std.ArrayListUnmanaged(?*ast.Expr) = .{};
        defer inits.deinit(p.arena);
        if (p.match(.eq)) {
            while (true) {
                try inits.append(p.arena, try p.parseExpr(0));
                if (p.match(.comma)) continue else break;
            }
        }
        while (inits.items.len < names.items.len) {
            try inits.append(p.arena, null);
        }
        return p.allocStmt(.{ .local = .{
            .names = try names.toOwnedSlice(p.arena),
            .inits = try inits.toOwnedSlice(p.arena),
        } });
    }

    fn parseFunctionDecl(p: *Parser) ParseError!*ast.Stmt {
        try p.eat(.function);
        var fname: ?[]const u8 = null;
        if (p.at() == .ident) {
            fname = try p.dup(p.peek().lexeme);
            p.advance();
        }
        try p.eat(.lparen);
        const params = try p.paramList();
        try p.eat(.rparen);
        const body_s = try p.stmtList(&.{.end});
        try p.eat(.end);
        const body = try p.allocBlock(body_s);
        return p.allocStmt(.{ .func_decl = .{
            .name = fname,
            .params = params,
            .body = body,
        } });
    }

    fn paramList(p: *Parser) ParseError![]const []const u8 {
        var params: std.ArrayListUnmanaged([]const u8) = .{};
        defer params.deinit(p.arena);
        if (p.at() != .rparen) {
            while (true) {
                if (p.at() != .ident) return error.UnexpectedToken;
                try params.append(p.arena, try p.dup(p.peek().lexeme));
                p.advance();
                if (p.match(.comma)) continue else break;
            }
        }
        return params.toOwnedSlice(p.arena) catch return error.OutOfMemory;
    }

    fn parseIfStatement(p: *Parser) ParseError!*ast.Stmt {
        try p.eat(.if_kw);
        return p.parseIfTail();
    }

    /// After `if` keyword; parses `expr then ... end` (optional `else`; `elseif` not supported yet).
    fn parseIfTail(p: *Parser) ParseError!*ast.Stmt {
        const cond = try p.parseExpr(0);
        try p.eat(.then);
        const then_stmts = try p.stmtList(&.{ .else_kw, .end });
        const then_blk = try p.allocBlock(then_stmts);
        var else_blk: ?*ast.Block = null;
        if (p.match(.else_kw)) {
            const es = try p.stmtList(&.{.end});
            else_blk = try p.allocBlock(es);
        }
        try p.eat(.end);
        return p.allocStmt(.{ .if_stmt = .{
            .cond = cond,
            .then_blk = then_blk,
            .else_blk = else_blk,
        } });
    }

    fn parseWhile(p: *Parser) ParseError!*ast.Stmt {
        try p.eat(.while_kw);
        const cond = try p.parseExpr(0);
        try p.eat(.do);
        const body_s = try p.stmtList(&.{.end});
        try p.eat(.end);
        const body = try p.allocBlock(body_s);
        return p.allocStmt(.{ .while_stmt = .{ .cond = cond, .body = body } });
    }

    fn parseRepeat(p: *Parser) ParseError!*ast.Stmt {
        try p.eat(.repeat);
        const body_s = try p.stmtList(&.{.until});
        try p.eat(.until);
        const cond = try p.parseExpr(0);
        const body = try p.allocBlock(body_s);
        return p.allocStmt(.{ .repeat_stmt = .{ .body = body, .cond = cond } });
    }

    fn parseDoEnd(p: *Parser) ParseError!*ast.Stmt {
        try p.eat(.do);
        const inner = try p.stmtList(&.{.end});
        try p.eat(.end);
        const blk = try p.allocBlock(inner);
        return p.allocStmt(.{ .block = blk });
    }

    fn parseReturn(p: *Parser, comptime outer_stop: []const lex.Tag) ParseError!*ast.Stmt {
        try p.eat(.return_kw);
        var vals: std.ArrayListUnmanaged(*ast.Expr) = .{};
        defer vals.deinit(p.arena);
        if (!stops(p.at(), outer_stop) and p.at() != .end and p.at() != .else_kw) {
            while (true) {
                try vals.append(p.arena, try p.parseExpr(0));
                if (p.match(.comma)) continue else break;
            }
        }
        return p.allocStmt(.{ .ret = .{ .values = try vals.toOwnedSlice(p.arena) } });
    }

    fn parseAssignLike(p: *Parser, first: *ast.Expr) ParseError!*ast.Stmt {
        var tgts: std.ArrayListUnmanaged(*ast.Expr) = .{};
        defer tgts.deinit(p.arena);
        try tgts.append(p.arena, first);
        while (p.match(.comma)) {
            try tgts.append(p.arena, try p.parseExpr(0));
        }
        try p.eat(.eq);
        var vals: std.ArrayListUnmanaged(*ast.Expr) = .{};
        defer vals.deinit(p.arena);
        while (true) {
            try vals.append(p.arena, try p.parseExpr(0));
            if (p.match(.comma)) continue else break;
        }
        return p.allocStmt(.{ .assign = .{
            .targets = try tgts.toOwnedSlice(p.arena),
            .values = try vals.toOwnedSlice(p.arena),
        } });
    }

    fn parseExpr(p: *Parser, min_prec: u8) ParseError!*ast.Expr {
        return p.parseSubexpr(min_prec);
    }

    fn parseSubexpr(p: *Parser, min_prec: u8) ParseError!*ast.Expr {
        var left = try p.parsePrefix();
        while (true) {
            const t = p.at();
            const info = binOpInfo(t) orelse break;
            if (info.prec < min_prec) break;
            const next_min = if (info.right_assoc) info.prec else info.prec + 1;
            p.advance();
            const right = try p.parseSubexpr(next_min);
            left = try p.allocExpr(.{ .binary = .{
                .op = info.op,
                .left = left,
                .right = right,
            } });
        }
        return left;
    }

    const BinInfo = struct { op: ast.BinOp, prec: u8, right_assoc: bool };

    fn binOpInfo(t: lex.Tag) ?BinInfo {
        return switch (t) {
            .kw_or => .{ .op = .@"or", .prec = 1, .right_assoc = false },
            .kw_and => .{ .op = .@"and", .prec = 2, .right_assoc = false },
            .lt, .lte, .gt, .gte, .eqeq, .tildeeq => .{ .op = switch (t) {
                .lt => .lt,
                .lte => .le,
                .gt => .gt,
                .gte => .ge,
                .eqeq => .eq,
                .tildeeq => .ne,
                else => unreachable,
            }, .prec = 3, .right_assoc = false },
            .dotdot => .{ .op = .concat, .prec = 4, .right_assoc = false },
            .plus, .minus => .{ .op = if (t == .plus) .add else .sub, .prec = 5, .right_assoc = false },
            .star, .slash, .percent => .{ .op = switch (t) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => unreachable,
            }, .prec = 6, .right_assoc = false },
            .caret => .{ .op = .pow, .prec = 8, .right_assoc = true },
            else => null,
        };
    }

    fn parsePrefix(p: *Parser) ParseError!*ast.Expr {
        switch (p.at()) {
            .nil => {
                p.advance();
                return p.allocExpr(.{ .literal = .nil });
            },
            .kw_true => {
                p.advance();
                return p.allocExpr(.{ .literal = .bool_true });
            },
            .kw_false => {
                p.advance();
                return p.allocExpr(.{ .literal = .bool_false });
            },
            .number => {
                const lx = p.peek().lexeme;
                p.advance();
                const n = std.fmt.parseFloat(f64, lx) catch return error.InvalidNumber;
                return p.allocExpr(.{ .literal = .{ .number = n } });
            },
            .string => {
                const lx = p.peek().lexeme;
                p.advance();
                return p.allocExpr(.{ .literal = .{ .string = try p.dup(lx) } });
            },
            .minus => {
                p.advance();
                const sub = try p.parseSubexpr(7);
                return p.allocExpr(.{ .unary = .{ .op = .neg, .operand = sub } });
            },
            .kw_not => {
                p.advance();
                const sub = try p.parseSubexpr(7);
                return p.allocExpr(.{ .unary = .{ .op = .not, .operand = sub } });
            },
            .hash => {
                p.advance();
                const sub = try p.parseSubexpr(7);
                return p.allocExpr(.{ .unary = .{ .op = .len, .operand = sub } });
            },
            .ident => {
                const n = try p.dup(p.peek().lexeme);
                p.advance();
                var e = try p.allocExpr(.{ .name = n });
                e = try p.suffixChain(e);
                return e;
            },
            .lparen => {
                p.advance();
                const inner = try p.parseSubexpr(0);
                try p.eat(.rparen);
                var g = try p.allocExpr(.{ .group = inner });
                g = try p.suffixChain(g);
                return g;
            },
            .function => {
                try p.eat(.function);
                try p.eat(.lparen);
                const params = try p.paramList();
                try p.eat(.rparen);
                const body_s = try p.stmtList(&.{.end});
                try p.eat(.end);
                const body = try p.allocBlock(body_s);
                return p.allocExpr(.{ .anon_function = .{ .params = params, .body = body } });
            },
            else => return error.UnexpectedToken,
        }
    }

    fn suffixChain(p: *Parser, base: *ast.Expr) ParseError!*ast.Expr {
        var e = base;
        while (true) {
            if (p.match(.lparen)) {
                var args: std.ArrayListUnmanaged(*ast.Expr) = .{};
                defer args.deinit(p.arena);
                if (p.at() != .rparen) {
                    while (true) {
                        try args.append(p.arena, try p.parseSubexpr(0));
                        if (p.match(.comma)) continue else break;
                    }
                }
                try p.eat(.rparen);
                e = try p.allocExpr(.{ .call = .{ .callee = e, .args = try args.toOwnedSlice(p.arena) } });
            } else if (p.match(.lbrack)) {
                const key = try p.parseSubexpr(0);
                try p.eat(.rbrack);
                e = try p.allocExpr(.{ .index = .{ .obj = e, .key = key } });
            } else if (p.match(.dot)) {
                if (p.at() != .ident) return error.UnexpectedToken;
                const field = try p.dup(p.peek().lexeme);
                p.advance();
                const key = try p.allocExpr(.{ .literal = .{ .string = field } });
                e = try p.allocExpr(.{ .index = .{ .obj = e, .key = key } });
            } else break;
        }
        return e;
    }
};

pub fn parse(arena: std.mem.Allocator, tokens: []const lex.Token, src: []const u8) ParseError!*ast.Block {
    var p = Parser{ .tokens = tokens, .i = 0, .arena = arena, .src = src };
    return p.parseChunk();
}
