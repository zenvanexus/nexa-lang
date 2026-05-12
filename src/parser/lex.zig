const std = @import("std");

pub const Token = struct {
    tag: Tag,
    lexeme: []const u8,
};

pub const Tag = enum {
    eof,
};

/// Tokenize `src`; caller owns returned slice (free with same allocator).
pub fn tokenize(allocator: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error![]Token {
    _ = src;
    const out = try allocator.alloc(Token, 1);
    out[0] = .{ .tag = .eof, .lexeme = "" };
    return out;
}
