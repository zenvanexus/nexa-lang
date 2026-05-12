const std = @import("std");

pub const LexError = error{
    InvalidEscape,
    UnterminatedString,
    InvalidNumber,
    InvalidChar,
};

pub const Token = struct {
    tag: Tag,
    offset: usize,
    /// Slice into `src` except `.string`, where it is an arena-owned copy.
    lexeme: []const u8,
};

pub const Tag = enum {
    eof,
    ident,
    number,
    string,
    kw_true,
    kw_false,
    nil,
    kw_and,
    kw_or,
    kw_not,
    if_kw,
    then,
    else_kw,
    elseif,
    end,
    while_kw,
    do,
    repeat,
    until,
    local,
    return_kw,
    function,
    for_kw,
    in_kw,
    break_kw,
    plus,
    minus,
    star,
    slash,
    percent,
    caret,
    hash,
    eqeq,
    tildeeq,
    lte,
    gte,
    lt,
    gt,
    eq,
    comma,
    dot,
    dotdot,
    colon,
    semicolon,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbrack,
    rbrack,
};

pub fn tokenize(allocator: std.mem.Allocator, src: []const u8) (std.mem.Allocator.Error || LexError)![]Token {
    var list: std.ArrayListUnmanaged(Token) = .{};
    errdefer {
        for (list.items) |t| {
            if (t.tag == .string) allocator.free(t.lexeme);
        }
        list.deinit(allocator);
    }
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        if (c == '-' and i + 1 < src.len and src[i + 1] == '-') {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        const start = i;
        switch (c) {
            '(' => {
                try list.append(allocator, .{ .tag = .lparen, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            ')' => {
                try list.append(allocator, .{ .tag = .rparen, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            '{' => {
                try list.append(allocator, .{ .tag = .lbrace, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            '}' => {
                try list.append(allocator, .{ .tag = .rbrace, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            '[' => {
                try list.append(allocator, .{ .tag = .lbrack, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            ']' => {
                try list.append(allocator, .{ .tag = .rbrack, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            '+' => {
                try list.append(allocator, .{ .tag = .plus, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            '*' => {
                try list.append(allocator, .{ .tag = .star, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            '/' => {
                try list.append(allocator, .{ .tag = .slash, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            '%' => {
                try list.append(allocator, .{ .tag = .percent, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            '^' => {
                try list.append(allocator, .{ .tag = .caret, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            '#' => {
                try list.append(allocator, .{ .tag = .hash, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            ',' => {
                try list.append(allocator, .{ .tag = .comma, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            ':' => {
                try list.append(allocator, .{ .tag = .colon, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            ';' => {
                try list.append(allocator, .{ .tag = .semicolon, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            '=' => {
                if (i + 1 < src.len and src[i + 1] == '=') {
                    try list.append(allocator, .{ .tag = .eqeq, .offset = start, .lexeme = src[start .. start + 2] });
                    i += 2;
                } else {
                    try list.append(allocator, .{ .tag = .eq, .offset = start, .lexeme = src[start .. start + 1] });
                    i += 1;
                }
            },
            '~' => {
                if (i + 1 < src.len and src[i + 1] == '=') {
                    try list.append(allocator, .{ .tag = .tildeeq, .offset = start, .lexeme = src[start .. start + 2] });
                    i += 2;
                } else {
                    return error.InvalidChar;
                }
            },
            '<' => {
                if (i + 1 < src.len and src[i + 1] == '=') {
                    try list.append(allocator, .{ .tag = .lte, .offset = start, .lexeme = src[start .. start + 2] });
                    i += 2;
                } else {
                    try list.append(allocator, .{ .tag = .lt, .offset = start, .lexeme = src[start .. start + 1] });
                    i += 1;
                }
            },
            '>' => {
                if (i + 1 < src.len and src[i + 1] == '=') {
                    try list.append(allocator, .{ .tag = .gte, .offset = start, .lexeme = src[start .. start + 2] });
                    i += 2;
                } else {
                    try list.append(allocator, .{ .tag = .gt, .offset = start, .lexeme = src[start .. start + 1] });
                    i += 1;
                }
            },
            '.' => {
                if (i + 1 < src.len and src[i + 1] == '.') {
                    try list.append(allocator, .{ .tag = .dotdot, .offset = start, .lexeme = src[start .. start + 2] });
                    i += 2;
                } else if (i + 1 < src.len and std.ascii.isDigit(src[i + 1])) {
                    try scanNumber(allocator, src, &i, &list);
                } else {
                    try list.append(allocator, .{ .tag = .dot, .offset = start, .lexeme = src[start .. start + 1] });
                    i += 1;
                }
            },
            '-' => {
                try list.append(allocator, .{ .tag = .minus, .offset = start, .lexeme = src[start .. start + 1] });
                i += 1;
            },
            '"' => {
                i += 1;
                var buf: std.ArrayListUnmanaged(u8) = .{};
                defer buf.deinit(allocator);
                while (i < src.len) {
                    switch (src[i]) {
                        '"' => break,
                        '\\' => {
                            i += 1;
                            if (i >= src.len) return error.UnterminatedString;
                            switch (src[i]) {
                                'n' => try buf.append(allocator, '\n'),
                                't' => try buf.append(allocator, '\t'),
                                'r' => try buf.append(allocator, '\r'),
                                '\\' => try buf.append(allocator, '\\'),
                                '"' => try buf.append(allocator, '"'),
                                else => return error.InvalidEscape,
                            }
                            i += 1;
                        },
                        else => {
                            try buf.append(allocator, src[i]);
                            i += 1;
                        },
                    }
                }
                if (i >= src.len) return error.UnterminatedString;
                const bytes = try buf.toOwnedSlice(allocator);
                try list.append(allocator, .{ .tag = .string, .offset = start, .lexeme = bytes });
                i += 1;
            },
            else => {
                if (isIdentStart(c)) {
                    const id_start = i;
                    i += 1;
                    while (i < src.len and isIdentCont(src[i])) i += 1;
                    const name = src[id_start..i];
                    const tag = keywordTag(name);
                    try list.append(allocator, .{ .tag = tag, .offset = id_start, .lexeme = name });
                } else if (std.ascii.isDigit(c)) {
                    try scanNumber(allocator, src, &i, &list);
                } else {
                    return error.InvalidChar;
                }
            },
        }
    }
    try list.append(allocator, .{ .tag = .eof, .offset = src.len, .lexeme = "" });
    return try list.toOwnedSlice(allocator);
}

fn scanNumber(allocator: std.mem.Allocator, src: []const u8, i: *usize, list: *std.ArrayListUnmanaged(Token)) (std.mem.Allocator.Error || LexError)!void {
    const num_start = i.*;
    if (src[i.*] == '.') {
        i.* += 1;
        if (i.* >= src.len or !std.ascii.isDigit(src[i.*])) return error.InvalidNumber;
        while (i.* < src.len and std.ascii.isDigit(src[i.*])) i.* += 1;
    } else {
        while (i.* < src.len and std.ascii.isDigit(src[i.*])) i.* += 1;
        if (i.* < src.len and src[i.*] == '.') {
            i.* += 1;
            while (i.* < src.len and std.ascii.isDigit(src[i.*])) i.* += 1;
        }
    }
    if (i.* < src.len and (src[i.*] == 'e' or src[i.*] == 'E')) {
        i.* += 1;
        if (i.* < src.len and (src[i.*] == '+' or src[i.*] == '-')) i.* += 1;
        if (i.* >= src.len or !std.ascii.isDigit(src[i.*])) return error.InvalidNumber;
        while (i.* < src.len and std.ascii.isDigit(src[i.*])) i.* += 1;
    }
    const slice = src[num_start..i.*];
    _ = std.fmt.parseFloat(f64, slice) catch return error.InvalidNumber;
    try list.append(allocator, .{ .tag = .number, .offset = num_start, .lexeme = slice });
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn keywordTag(name: []const u8) Tag {
    const pairs = [_]struct { []const u8, Tag }{
        .{ "and", .kw_and },
        .{ "break", .break_kw },
        .{ "do", .do },
        .{ "else", .else_kw },
        .{ "elseif", .elseif },
        .{ "end", .end },
        .{ "false", .kw_false },
        .{ "for", .for_kw },
        .{ "function", .function },
        .{ "if", .if_kw },
        .{ "in", .in_kw },
        .{ "local", .local },
        .{ "nil", .nil },
        .{ "not", .kw_not },
        .{ "or", .kw_or },
        .{ "repeat", .repeat },
        .{ "return", .return_kw },
        .{ "then", .then },
        .{ "true", .kw_true },
        .{ "until", .until },
        .{ "while", .while_kw },
    };
    for (pairs) |p| {
        if (std.mem.eql(u8, name, p[0])) return p[1];
    }
    return .ident;
}

test "lex arithmetic and string" {
    const a = std.testing.allocator;
    const src = "local x = 1 + 2\nprint(\"hi\\n\")";
    const toks = try tokenize(a, src);
    defer {
        for (toks) |t| {
            if (t.tag == .string) a.free(t.lexeme);
        }
        a.free(toks);
    }
    try std.testing.expect(toks[0].tag == .local);
    try std.testing.expect(toks[1].tag == .ident);
    try std.testing.expect(std.mem.eql(u8, toks[1].lexeme, "x"));
}
