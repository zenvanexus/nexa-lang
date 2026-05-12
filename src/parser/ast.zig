pub const BinOp = enum {
    add, // +
    sub, // -
    mul, // *
    div, // /
    mod, // %
    pow, // ^
    concat, // ..
    eq, // ==
    ne, // ~=
    lt,
    le,
    gt,
    ge,
    @"and",
    @"or",
};

pub const UnaryOp = enum {
    neg, // -
    not, // not
    len, // #
};

pub const Literal = union(enum) {
    nil,
    bool_true,
    bool_false,
    number: f64,
    string: []const u8, // unescaped bytes, allocated in arena
};

pub const Expr = union(enum) {
    literal: Literal,
    name: []const u8,
    unary: struct {
        op: UnaryOp,
        operand: *Expr,
    },
    binary: struct {
        op: BinOp,
        left: *Expr,
        right: *Expr,
    },
    call: struct {
        callee: *Expr,
        args: []const *Expr,
    },
    index: struct {
        obj: *Expr,
        key: *Expr,
    },
    anon_function: struct {
        params: []const []const u8,
        body: *Block,
    },
    group: *Expr,
};

pub const Block = struct {
    stmts: []const *Stmt,
};

pub const LocalDecl = struct {
    names: []const []const u8,
    inits: []const ?*Expr,
};

pub const Assign = struct {
    targets: []const *Expr,
    values: []const *Expr,
};

pub const IfStmt = struct {
    cond: *Expr,
    then_blk: *Block,
    else_blk: ?*Block,
};

pub const WhileStmt = struct {
    cond: *Expr,
    body: *Block,
};

pub const RepeatStmt = struct {
    body: *Block,
    cond: *Expr,
};

pub const FuncDecl = struct {
    name: ?[]const u8,
    params: []const []const u8,
    body: *Block,
};

pub const ReturnStmt = struct {
    values: []const *Expr,
};

pub const Stmt = union(enum) {
    block: *Block,
    local: LocalDecl,
    assign: Assign,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    repeat_stmt: RepeatStmt,
    func_decl: FuncDecl,
    ret: ReturnStmt,
    break_stmt: void,
    expr: *Expr,
};

pub const Chunk = struct {
    body: *Block,
};
