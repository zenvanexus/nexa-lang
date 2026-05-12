pub const Expr = union(enum) {
    number: f64,
};

pub const Stmt = union(enum) {
    @"return": Expr,
};

pub const Block = struct {
    stmts: []const Stmt,
};
