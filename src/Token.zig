const std = @import("std");

const Module = @import("Module.zig");

const Self = @This();

@"type": @"Type",
loc: Module.Span,

pub const @"Type" = enum(u8) {
    plus,
    dash,
    star,
    fwd_slash,
    left_angle_brack,
    right_angle_brack,
    equal,
    bang,
    plus_equal,
    dash_equal,
    star_equal,
    fwd_slash_equal,
    left_angle_brack_equal,
    right_angle_brack_equal,
    equal_equal,
    bang_equal,

    left_paren,
    right_paren,
    left_brace,
    right_brace,
    semicolon,
    comma,
    dot,

    identifier,
    number_literal,
    string_literal,

    keyword_and,
    keyword_class,
    keyword_else,
    keyword_false,
    keyword_for,
    keyword_fun,
    keyword_if,
    keyword_nil,
    keyword_or,
    keyword_print,
    keyword_return,
    keyword_super,
    keyword_this,
    keyword_true,
    keyword_var,
    keyword_while,

    eof,
    invalid,

    pub fn lexeme(@"type": @"Type") ?[:0]const u8 {
        return switch (@"type") {
            .identifier,
            .number_literal,
            .string_literal,
            .eof,
            .invalid,
            => null,

            .plus => "+",
            .dash => "-",
            .star => "*",
            .fwd_slash => "/",
            .left_angle_brack => "<",
            .right_angle_brack => ">",
            .equal => "=",
            .bang => "!",
            .plus_equal => "+=",
            .dash_equal => "-=",
            .star_equal => "*=",
            .fwd_slash_equal => "/=",
            .left_angle_brack_equal => "<=",
            .right_angle_brack_equal => ">=",
            .equal_equal => "==",
            .bang_equal => "!=",

            .left_paren => "(",
            .right_paren => ")",
            .left_brace => "{",
            .right_brace => "}",
            .semicolon => ";",
            .comma => ",",
            .dot => ".",

            .keyword_and => "and",
            .keyword_class => "class",
            .keyword_else => "else",
            .keyword_false => "false",
            .keyword_for => "for",
            .keyword_fun => "fun",
            .keyword_if => "if",
            .keyword_nil => "nil",
            .keyword_or => "or",
            .keyword_print => "print",
            .keyword_return => "return",
            .keyword_super => "super",
            .keyword_this => "this",
            .keyword_true => "true",
            .keyword_var => "var",
            .keyword_while => "while",
        };
    }

    pub fn category(@"type": @"Type") []const u8 {
        return switch (@"type") {
            .identifier => "an identifier",
            .number_literal => "a number",
            .string_literal => "a string",
            .eof => "the end of the file",
            .invalid => "an invalid token",
            else => unreachable,
        };
    }
};

pub const keywords = std.ComptimeStringMap(@"Type", .{
    .{ "and", .keyword_and },
    .{ "class", .keyword_class },
    .{ "else", .keyword_else },
    .{ "false", .keyword_false },
    .{ "for", .keyword_for },
    .{ "fun", .keyword_fun },
    .{ "if", .keyword_if },
    .{ "nil", .keyword_nil },
    .{ "or", .keyword_or },
    .{ "print", .keyword_print },
    .{ "return", .keyword_return },
    .{ "super", .keyword_super },
    .{ "this", .keyword_this },
    .{ "true", .keyword_true },
    .{ "var", .keyword_var },
    .{ "while", .keyword_while },
});
