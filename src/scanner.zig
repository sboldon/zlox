const std = @import("std");
const testing = std.testing;

const DynamicArray = @import("dynamic_array.zig").DynamicArray;
const compile = @import("compile.zig");
const Module = @import("module.zig").Module;
const Token = @import("Token.zig");

pub const Scanner = struct {
    const Self = @This();

    source: [:0]const u8 = undefined,
    index: usize = 0,

    const State = enum(u8) {
        // Transitions:
        // plus, dash, star, fwd_slash, left_angle_brack, right_angle_brack, equal, bang,
        // potential_keyword, identifier, number, string
        init,

        plus,
        dash,
        star,
        fwd_slash,
        left_angle_brack, // Transitions: line_comment
        right_angle_brack,
        equal,
        bang,

        potential_keyword,
        identifier,
        number, // Transitions: fractional_digits
        fractional_digits,
        string,

        line_comment, // Transitions: init
    };

    pub fn setSource(self: *Self, source: [:0]const u8) void {
        self.source = source;
        self.index = 0;
    }

    pub fn next(self: *Self) Token {
        var state = State.init;
        var tok = Token{
            .@"type" = .eof,
            .loc = .{ .lo = self.index, .hi = undefined },
        };
        while (true) : (self.index += 1) {
            const ch = self.source[self.index];
            switch (state) {
                .init => switch (ch) {
                    0 => break,
                    ' ', '\r', '\n', '\t' => tok.loc.lo += 1,
                    '+' => state = .plus,
                    '-' => state = .dash,
                    '*' => state = .star,
                    '/' => state = .fwd_slash,
                    '<' => state = .left_angle_brack,
                    '>' => state = .right_angle_brack,
                    '=' => state = .equal,
                    '!' => state = .bang,
                    '(' => {
                        tok.type = .left_paren;
                        self.index += 1;
                        break;
                    },
                    ')' => {
                        tok.type = .right_paren;
                        self.index += 1;
                        break;
                    },
                    '{' => {
                        tok.type = .left_brace;
                        self.index += 1;
                        break;
                    },
                    '}' => {
                        tok.type = .right_brace;
                        self.index += 1;
                        break;
                    },
                    '.' => {
                        tok.type = .dot;
                        self.index += 1;
                        break;
                    },
                    ',' => {
                        tok.type = .comma;
                        self.index += 1;
                        break;
                    },
                    ';' => {
                        tok.type = .semicolon;
                        self.index += 1;
                        break;
                    },
                    'a', 'c', 'e', 'f', 'i', 'n'...'p', 'r'...'t', 'v', 'w' => state = .potential_keyword,
                    '_', 'A'...'Z', 'b', 'd', 'g', 'h', 'j'...'m', 'q', 'u', 'x'...'z' => state = .identifier,
                    '0'...'9' => state = .number,
                    '"' => state = .string,
                    else => {
                        tok.type = .invalid;
                        self.index += 1;
                        break;
                    },
                },

                .plus => switch (ch) {
                    '=' => {
                        self.index += 1;
                        tok.type = .plus_equal;
                        break;
                    },
                    else => {
                        tok.type = .plus;
                        break;
                    },
                },
                .dash => switch (ch) {
                    '=' => {
                        self.index += 1;
                        tok.type = .dash_equal;
                        break;
                    },
                    else => {
                        tok.type = .dash;
                        break;
                    },
                },
                .star => switch (ch) {
                    '=' => {
                        self.index += 1;
                        tok.type = .star_equal;
                        break;
                    },
                    else => {
                        tok.type = .star;
                        break;
                    },
                },
                .fwd_slash => switch (ch) {
                    '/' => {
                        tok.loc.lo += 2; // Consume "//".
                        state = .line_comment;
                    },
                    '=' => {
                        self.index += 1;
                        tok.type = .fwd_slash_equal;
                        break;
                    },
                    else => {
                        tok.type = .fwd_slash;
                        break;
                    },
                },
                .left_angle_brack => switch (ch) {
                    '=' => {
                        self.index += 1;
                        tok.type = .left_angle_brack_equal;
                        break;
                    },
                    else => {
                        tok.type = .left_angle_brack;
                        break;
                    },
                },
                .right_angle_brack => switch (ch) {
                    '=' => {
                        self.index += 1;
                        tok.type = .right_angle_brack_equal;
                        break;
                    },
                    else => {
                        tok.type = .right_angle_brack;
                        break;
                    },
                },
                .equal => switch (ch) {
                    '=' => {
                        self.index += 1;
                        tok.type = .equal_equal;
                        break;
                    },
                    else => {
                        tok.type = .equal;
                        break;
                    },
                },
                .bang => switch (ch) {
                    '=' => {
                        self.index += 1;
                        tok.type = .bang_equal;
                        break;
                    },
                    else => {
                        tok.type = .bang;
                        break;
                    },
                },

                .potential_keyword => switch (ch) {
                    'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                    else => {
                        const lexeme = self.source[tok.loc.lo..self.index];
                        tok.type = if (Token.keywords.get(lexeme)) |keyword| keyword else .identifier;
                        break;
                    },
                },
                .identifier => switch (ch) {
                    'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                    else => {
                        tok.type = .identifier;
                        break;
                    },
                },

                .number => switch (ch) {
                    '0'...'9' => {},
                    '.' => state = .fractional_digits,
                    else => {
                        tok.type = .number_literal;
                        break;
                    },
                },
                .fractional_digits => switch (ch) {
                    '0'...'9' => {},
                    else => {
                        tok.type = .number_literal;
                        break;
                    },
                },

                .string => switch (ch) {
                    0 => {
                        // TODO: Error message "unterminated string literal"
                        self.index += 1;
                        tok.type = .invalid;
                        break;
                    },
                    '"' => {
                        self.index += 1;
                        tok.type = .string_literal;
                        break;
                    },
                    else => {},
                },

                .line_comment => switch (ch) {
                    0 => break,
                    '\n' => {
                        tok.loc.lo += 1;
                        state = .init;
                    },
                    else => tok.loc.lo += 1,
                },
            }
        }

        tok.loc.hi = self.index;
        return tok;
    }

    fn consumeInvalidNumber(self: *Self) void {
        while (true) : (self.index += 1) {
            switch (self.source[self.index]) {
                '0'...'9', '.' => {},
                else => return,
            }
        }
    }

    test "individual tokens" {
        try testCase("", &.{});
        try testCase("@", &.{.invalid});

        // Individually test each token type with an invariable lexeme.
        inline for (std.meta.fields(Token.Type)) |field| {
            const tok_type = @intToEnum(Token.Type, field.value);
            if (tok_type.lexeme()) |lexeme| {
                try testCase(lexeme, &.{tok_type});
            }
        }
    }

    test "comments" {
        try testCase("//", &.{});
        try testCase("//\n", &.{});
        try testCase("// these tokens are ignored + >=", &.{});
        try testCase(
            \\// WARNING!! DO NOT CHANGE THIS :)
            \\fun identity(a) {
            \\  return a;
            \\}
        , &.{
            .keyword_fun,
            .identifier,
            .left_paren,
            .identifier,
            .right_paren,
            .left_brace,
            .keyword_return,
            .identifier,
            .semicolon,
            .right_brace,
        });
    }

    test "numbers" {
        try testCase("0", &.{.number_literal});
        try testCase("1", &.{.number_literal});
        try testCase("2", &.{.number_literal});
        try testCase("3", &.{.number_literal});
        try testCase("4", &.{.number_literal});
        try testCase("5", &.{.number_literal});
        try testCase("6", &.{.number_literal});
        try testCase("7", &.{.number_literal});
        try testCase("8", &.{.number_literal});
        try testCase("9", &.{.number_literal});
        try testCase("123.456.897", &.{ .number_literal, .dot, .number_literal });
    }

    fn testCase(source: [:0]const u8, expected: []const Token.Type) !void {
        var scanner = Scanner{ .source = source };
        for (expected) |expected_tok_type| {
            const actual_tok = scanner.next();
            if (actual_tok.type != expected_tok_type) {
                std.debug.panic(
                    "expected {s} token but found {s}\n",
                    .{ @tagName(expected_tok_type), @tagName(actual_tok.type) },
                );
            }
            if (expected_tok_type.lexeme()) |expected_lexeme| {
                try testing.expectEqualStrings(
                    expected_lexeme,
                    source[actual_tok.loc.lo..actual_tok.loc.hi],
                );
            }
        }
        const final = scanner.next();
        try testing.expectEqual(Token.Type.eof, final.type);
        try testing.expectEqual(source.len, final.loc.hi);
    }
};

test {
    testing.refAllDecls(@This());
}
