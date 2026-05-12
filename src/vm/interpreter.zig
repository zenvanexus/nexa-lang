const std = @import("std");
const ast = @import("../parser/ast.zig");
const Value = @import("../value.zig").Value;
const Builtin = @import("../value.zig").Builtin;
const stringBytes = @import("../value.zig").stringBytes;
const String = @import("../types/string.zig").String;
const Table = @import("../types/table.zig").Table;
const FunctionObj = @import("../types/function.zig").FunctionObj;
const VmError = @import("error.zig").VmError;

pub const Flow = union(enum) {
    none,
    ret: []const Value,
    @"break",
};

const Scope = struct {
    vars: std.StringHashMapUnmanaged(Value) = .{},

    fn deinit(s: *Scope, allocator: std.mem.Allocator) void {
        s.vars.deinit(allocator);
    }
};

pub const Interpreter = struct {
    arena: std.mem.Allocator,
    backing: std.mem.Allocator,
    globals: std.StringHashMapUnmanaged(Value) = .{},
    scopes: std.ArrayListUnmanaged(Scope) = .{},
    loop_depth: usize = 0,
    out: *std.array_list.Managed(u8),

    pub fn init(backing: std.mem.Allocator, arena: std.mem.Allocator, out: *std.array_list.Managed(u8)) Interpreter {
        return .{ .backing = backing, .arena = arena, .out = out };
    }

    pub fn deinit(self: *Interpreter) void {
        self.globals.deinit(self.backing);
        for (self.scopes.items) |*s| s.deinit(self.backing);
        self.scopes.deinit(self.backing);
    }

    pub fn seedBuiltins(self: *Interpreter) VmError!void {
        self.globals.put(self.backing, "print", .{ .builtin = .print }) catch return error.OutOfMemory;
    }

    fn pushScope(self: *Interpreter) VmError!void {
        self.scopes.append(self.backing, .{}) catch return error.OutOfMemory;
    }

    fn popScope(self: *Interpreter) void {
        const s = self.scopes.pop().?;
        var mut = s;
        mut.deinit(self.backing);
    }

    fn currentScope(self: *Interpreter) *Scope {
        return &self.scopes.items[self.scopes.items.len - 1];
    }

    fn declareLocal(self: *Interpreter, name: []const u8, val: Value) VmError!void {
        self.currentScope().vars.put(self.backing, name, val) catch return error.OutOfMemory;
    }

    fn lookupName(self: *Interpreter, name: []const u8) ?Value {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].vars.get(name)) |v| return v;
        }
        return self.globals.get(name);
    }

    fn assignName(self: *Interpreter, name: []const u8, val: Value) VmError!void {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].vars.getPtr(name)) |ptr| {
                ptr.* = val;
                return;
            }
        }
        self.globals.put(self.backing, name, val) catch return error.OutOfMemory;
    }

    pub fn runChunk(self: *Interpreter, chunk: *ast.Block) VmError!void {
        try self.pushScope();
        defer self.popScope();
        _ = try self.execBlock(chunk, false);
    }

    fn execBlock(self: *Interpreter, block: *ast.Block, is_function: bool) VmError!Flow {
        for (block.stmts) |st| {
            const f = try self.execStmt(st.*, is_function);
            switch (f) {
                .none => {},
                .ret, .@"break" => return f,
            }
        }
        return .none;
    }

    fn execStmt(self: *Interpreter, st: ast.Stmt, is_function: bool) VmError!Flow {
        switch (st) {
            .block => |b| {
                try self.pushScope();
                defer self.popScope();
                return self.execBlock(b, is_function);
            },
            .local => |loc| {
                const n = loc.names.len;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const val: Value = if (i < loc.inits.len) blk: {
                        const opt = loc.inits[i];
                        const ex = opt orelse break :blk .nil;
                        break :blk try self.evalExpr(ex);
                    } else .nil;
                    try self.declareLocal(loc.names[i], val);
                }
                return .none;
            },
            .assign => |as| {
                const nv = as.values.len;
                const vals = self.arena.alloc(Value, nv) catch return error.OutOfMemory;
                for (0..nv) |j| vals[j] = try self.evalExpr(as.values[j]);
                for (as.targets, 0..) |t, k| {
                    const v = if (k < vals.len) vals[k] else .nil;
                    try self.assignLValue(t.*, v);
                }
                return .none;
            },
            .if_stmt => |ifs| {
                for (ifs.branches) |br| {
                    if (truthy(try self.evalExpr(br.cond))) {
                        try self.pushScope();
                        defer self.popScope();
                        return self.execBlock(br.then_blk, is_function);
                    }
                }
                if (ifs.else_blk) |eb| {
                    try self.pushScope();
                    defer self.popScope();
                    return self.execBlock(eb, is_function);
                }
                return .none;
            },
            .while_stmt => |ws| {
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                while (truthy(try self.evalExpr(ws.cond))) {
                    try self.pushScope();
                    defer self.popScope();
                    const f = try self.execBlock(ws.body, is_function);
                    switch (f) {
                        .none => {},
                        .@"break" => break,
                        .ret => return f,
                    }
                }
                return .none;
            },
            .for_numeric => |fr| {
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.pushScope();
                defer self.popScope();
                const n0 = try asNumber(try self.evalExpr(fr.start));
                const lim = try asNumber(try self.evalExpr(fr.limit));
                const step_val = if (fr.step) |se|
                    try asNumber(try self.evalExpr(se))
                else
                    @as(f64, 1);
                try self.declareLocal(fr.var_name, .{ .number = n0 });
                while (true) {
                    const cur_v = self.lookupName(fr.var_name) orelse return error.UndefinedVariable;
                    const cur = try asNumber(cur_v);
                    if (step_val > 0) {
                        if (cur > lim) break;
                    } else if (step_val < 0) {
                        if (cur < lim) break;
                    }
                    const f = try self.execBlock(fr.body, is_function);
                    switch (f) {
                        .none => {},
                        .@"break" => break,
                        .ret => return f,
                    }
                    const after = cur + step_val;
                    try self.assignName(fr.var_name, .{ .number = after });
                }
                return .none;
            },
            .repeat_stmt => |rs| {
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                while (true) {
                    try self.pushScope();
                    defer self.popScope();
                    const f = try self.execBlock(rs.body, is_function);
                    switch (f) {
                        .none => {},
                        .@"break" => break,
                        .ret => return f,
                    }
                    if (truthy(try self.evalExpr(rs.cond))) break;
                }
                return .none;
            },
            .func_decl => |fd| {
                const func = self.backing.create(FunctionObj) catch return error.OutOfMemory;
                func.* = .{ .name = fd.name, .params = fd.params, .body = fd.body };
                const fv: Value = .{ .function = func };
                const nm = fd.name orelse return error.ParseError;
                self.globals.put(self.backing, nm, fv) catch return error.OutOfMemory;
                return .none;
            },
            .ret => |r| {
                if (!is_function) return error.ReturnOutsideFunction;
                const n = r.values.len;
                const vals = self.arena.alloc(Value, n) catch return error.OutOfMemory;
                for (0..n) |i| vals[i] = try self.evalExpr(r.values[i]);
                return .{ .ret = vals };
            },
            .break_stmt => {
                if (self.loop_depth == 0) return error.BreakOutsideLoop;
                return .@"break";
            },
            .expr => |e| {
                _ = try self.evalExpr(e);
                return .none;
            },
        }
    }

    fn assignLValue(self: *Interpreter, lhs: ast.Expr, val: Value) VmError!void {
        switch (lhs) {
            .name => |n| try self.assignName(n, val),
            .index => |ix| {
                const obj = try self.evalExpr(ix.obj);
                const key = try self.evalExpr(ix.key);
                switch (obj) {
                    .table => |t| try t.set(key, val, self.backing),
                    else => return error.TypeMismatch,
                }
            },
            else => return error.TypeMismatch,
        }
    }

    fn evalExpr(self: *Interpreter, e: *ast.Expr) VmError!Value {
        switch (e.*) {
            .literal => |lit| switch (lit) {
                .nil => return .nil,
                .bool_true => return .{ .boolean = true },
                .bool_false => return .{ .boolean = false },
                .number => |n| return .{ .number = n },
                .string => |bytes| return .{ .string_lit = bytes },
            },
            .name => |n| return self.lookupName(n) orelse error.UndefinedVariable,
            .unary => |u| {
                const v = try self.evalExpr(u.operand);
                return switch (u.op) {
                    .neg => switch (v) {
                        .number => |x| return .{ .number = -x },
                        else => return error.TypeMismatch,
                    },
                    .not => return .{ .boolean = !truthy(v) },
                    .len => switch (v) {
                        .string => |s| return .{ .number = @floatFromInt(s.bytes.len) },
                        .string_lit => |b| return .{ .number = @floatFromInt(b.len) },
                        .table => |t| return .{ .number = @floatFromInt(t.array.items.len) },
                        else => return error.TypeMismatch,
                    },
                };
            },
            .binary => |b| {
                if (b.op == .@"and") {
                    const l = try self.evalExpr(b.left);
                    if (!truthy(l)) return l;
                    return self.evalExpr(b.right);
                }
                if (b.op == .@"or") {
                    const l = try self.evalExpr(b.left);
                    if (truthy(l)) return l;
                    return self.evalExpr(b.right);
                }
                const l = try self.evalExpr(b.left);
                const r = try self.evalExpr(b.right);
                return evalBinary(self, b.op, l, r);
            },
            .call => |c| {
                const callee = try self.evalExpr(c.callee);
                const args = self.arena.alloc(Value, c.args.len) catch return error.OutOfMemory;
                for (c.args, 0..) |a, i| args[i] = try self.evalExpr(a);
                return self.callValue(callee, args);
            },
            .index => |ix| {
                const obj = try self.evalExpr(ix.obj);
                const key = try self.evalExpr(ix.key);
                switch (obj) {
                    .table => |t| return t.get(key),
                    else => return error.TypeMismatch,
                }
            },
            .table_ctor => |tc| {
                const t = self.backing.create(Table) catch return error.OutOfMemory;
                t.* = Table.init();
                var seq: f64 = 1;
                for (tc.entries) |ent| {
                    switch (ent) {
                        .array_elem => |elem| {
                            const v = try self.evalExpr(elem);
                            try t.set(.{ .number = seq }, v, self.backing);
                            seq += 1;
                        },
                        .keyed => |kv| {
                            const k = try self.evalExpr(kv.key);
                            const val = try self.evalExpr(kv.value);
                            try t.set(k, val, self.backing);
                        },
                    }
                }
                return .{ .table = t };
            },
            .group => |g| return self.evalExpr(g),
            .anon_function => |af| {
                const func = self.backing.create(FunctionObj) catch return error.OutOfMemory;
                func.* = .{ .name = null, .params = af.params, .body = af.body };
                return .{ .function = func };
            },
        }
    }

    fn callValue(self: *Interpreter, callee: Value, args: []const Value) VmError!Value {
        switch (callee) {
            .builtin => |b| switch (b) {
                .print => {
                    for (args, 0..) |a, i| {
                        if (i != 0) self.out.append('\t') catch return error.OutOfMemory;
                        try appendValueToOut(self, a);
                    }
                    self.out.append('\n') catch return error.OutOfMemory;
                    return .nil;
                },
            },
            .function => |f| {
                if (args.len != f.params.len) return error.ArityMismatch;
                try self.pushScope();
                defer self.popScope();
                for (f.params, args) |pn, av| {
                    try self.declareLocal(pn, av);
                }
                const flow = try self.execBlock(f.body, true);
                switch (flow) {
                    .none => return .nil,
                    .ret => |vals| return if (vals.len == 0) .nil else vals[0],
                    .@"break" => return error.BreakOutsideLoop,
                }
            },
            else => return error.NotCallable,
        }
    }
};

fn asNumber(v: Value) VmError!f64 {
    return switch (v) {
        .number => |n| n,
        else => error.TypeMismatch,
    };
}

fn truthy(v: Value) bool {
    return switch (v) {
        .nil => false,
        .boolean => |b| b,
        .number => |n| n != 0,
        .string => |s| s.bytes.len > 0,
        .string_lit => |b| b.len > 0,
        .table, .function, .builtin => true,
    };
}

fn appendValueToOut(self: *Interpreter, v: Value) VmError!void {
    switch (v) {
        .nil => self.out.appendSlice("nil") catch return error.OutOfMemory,
        .boolean => |b| self.out.appendSlice(if (b) "true" else "false") catch return error.OutOfMemory,
        .number => |n| {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return error.LuaError;
            self.out.appendSlice(s) catch return error.OutOfMemory;
        },
        .string => |s| self.out.appendSlice(s.bytes) catch return error.OutOfMemory,
        .string_lit => |b| self.out.appendSlice(b) catch return error.OutOfMemory,
        .table => self.out.appendSlice("table") catch return error.OutOfMemory,
        .function => self.out.appendSlice("function") catch return error.OutOfMemory,
        .builtin => self.out.appendSlice("builtin") catch return error.OutOfMemory,
    }
}

fn evalBinary(self: *Interpreter, op: ast.BinOp, l: Value, r: Value) VmError!Value {
    switch (op) {
        .concat => {
            var a = std.ArrayListUnmanaged(u8){};
            defer a.deinit(self.backing);
            try appendValueToBuf(self, &a, l);
            try appendValueToBuf(self, &a, r);
            const s = self.backing.create(String) catch return error.OutOfMemory;
            s.* = String{ .bytes = a.toOwnedSlice(self.backing) catch return error.OutOfMemory };
            return .{ .string = s };
        },
        .add, .sub, .mul, .div, .mod, .pow => {
            const x = switch (l) {
                .number => |n| n,
                else => return error.TypeMismatch,
            };
            const y = switch (r) {
                .number => |n| n,
                else => return error.TypeMismatch,
            };
            const out: f64 = switch (op) {
                .add => x + y,
                .sub => x - y,
                .mul => x * y,
                .div => if (y == 0) return error.LuaError else x / y,
                .mod => @mod(x, y),
                .pow => std.math.pow(f64, x, y),
                else => unreachable,
            };
            return .{ .number = out };
        },
        .eq, .ne => {
            const eq = valueEq(l, r);
            return .{ .boolean = if (op == .eq) eq else !eq };
        },
        .lt, .le, .gt, .ge => {
            const o = try compareValues(l, r);
            const b: bool = switch (op) {
                .lt => o == .lt,
                .le => o == .lt or o == .eq,
                .gt => o == .gt,
                .ge => o == .gt or o == .eq,
                else => unreachable,
            };
            return .{ .boolean = b };
        },
        .@"and", .@"or" => unreachable,
    }
}

fn appendValueToBuf(self: *Interpreter, buf: *std.ArrayListUnmanaged(u8), v: Value) VmError!void {
    switch (v) {
        .nil => buf.appendSlice(self.backing, "nil") catch return error.OutOfMemory,
        .boolean => |b| buf.appendSlice(self.backing, if (b) "true" else "false") catch return error.OutOfMemory,
        .number => |n| {
            var tmp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return error.LuaError;
            buf.appendSlice(self.backing, s) catch return error.OutOfMemory;
        },
        .string => |s| buf.appendSlice(self.backing, s.bytes) catch return error.OutOfMemory,
        .string_lit => |b| buf.appendSlice(self.backing, b) catch return error.OutOfMemory,
        else => return error.TypeMismatch,
    }
}

fn valueEq(a: Value, b: Value) bool {
    if (stringBytes(a)) |sa| {
        if (stringBytes(b)) |sb| return std.mem.eql(u8, sa, sb);
        return false;
    }
    if (stringBytes(b)) |_| return false;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .nil => true,
        .boolean => |x| x == b.boolean,
        .number => |x| x == b.number,
        .table => |x| x == b.table,
        .function => |x| x == b.function,
        .builtin => |x| x == b.builtin,
        .string, .string_lit => unreachable,
    };
}

const Cmp = enum { lt, eq, gt };

fn compareValues(l: Value, r: Value) VmError!Cmp {
    if (stringBytes(l)) |xs| {
        if (stringBytes(r)) |ys| {
            const o = std.mem.order(u8, xs, ys);
            if (o == .lt) return .lt;
            if (o == .gt) return .gt;
            return .eq;
        }
        return error.TypeMismatch;
    }
    return switch (l) {
        .number => |x| switch (r) {
            .number => |y| {
                if (x < y) return .lt;
                if (x > y) return .gt;
                return .eq;
            },
            else => return error.TypeMismatch,
        },
        else => return error.TypeMismatch,
    };
}
