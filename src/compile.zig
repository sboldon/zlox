const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Context = @import("Context.zig");
const Module = @import("module.zig").Module;
const Scanner = @import("scanner.zig").Scanner;
const Token = @import("Token.zig");
const bytecode = @import("bytecode.zig");
const Value = @import("value.zig").Value;

pub const Error = enum(u8) {
    unknown_character,
    unexpected_token,
    empty_expression,
};

/// Maintains the state of a REPL sesssion across multiple invocations of `compileSource`.
pub const ReplCompilation = struct {
    const Self = @This();

    parser: Parser,

    pub fn init(gpa: Allocator, context: *Context) !Self {
        return Self{
            .parser = try Parser.init(gpa, context, &context.main_module, Scanner{}),
        };
    }

    pub fn compileSource(self: *Self, source: [:0]const u8) !bool {
        try self.parser.resetState(source);
        try self.parser.compile_module();
        return !self.parser.hadError();
    }
};

/// Compile a module that is not the top level. The resulting bytecode is stored in the
/// module struct.
pub fn compileModule(gpa: Allocator, context: *Context, module: *Module) !bool {
    std.debug.assert(module.source_loaded);
    var parser = try Parser.init(gpa, context, module, Scanner{ .source = module.source_code });
    try parser.compile_module();
    return !parser.hadError();
}

// `Parser` does not own any memory allocated during its execution.
const Parser = struct {
    const Self = @This();
    const max_errors = 10;

    gpa: Allocator,
    context: *Context,
    module: *Module,
    current_chunk: *bytecode.Chunk,

    scanner: Scanner,
    tok: Token = undefined,
    prev_tok: Token = undefined,

    panic_mode: bool = false,
    reported_errors: u8 = 0,

    /// Operator precedence from lowest to highest.
    const Precedence = enum(u8) {
        none,
        /// =
        assignment,
        /// or
        @"or",
        /// and
        @"and",
        /// == !=
        equality,
        /// < > <=  >=
        inequality,
        /// + -
        term,
        /// * /
        factor,
        /// ! -
        unary,
        /// () .
        call,
        primary,

        fn nextLevel(prec: Precedence) Precedence {
            return @intToEnum(Precedence, @enumToInt(prec) + 1);
        }
    };

    /// The parsing rule associated with each token when it begins an expression or acts as a
    /// binary operator.
    const Rule = struct {
        prefixAction: ?fn (*Self) error{OutOfMemory}!void,
        infixAction: ?fn (*Self) error{OutOfMemory}!void,
        prec: Precedence,
    };

    const rules = std.enums.directEnumArrayDefault(
        Token.Type,
        Rule,
        .{ .prefixAction = null, .infixAction = null, .prec = .none }, // Default rule.
        0,
        .{
            .keyword_nil = .{ .prefixAction = literal, .infixAction = null, .prec = .none },
            .keyword_true = .{ .prefixAction = literal, .infixAction = null, .prec = .none },
            .keyword_false = .{ .prefixAction = literal, .infixAction = null, .prec = .none },
            .number_literal = .{ .prefixAction = number, .infixAction = null, .prec = .none },
            .left_paren = .{ .prefixAction = grouping, .infixAction = null, .prec = .none },

            //TODO .equal = .{ },

            .equal_equal = .{ .prefixAction = null, .infixAction = binary, .prec = .equality },
            .bang_equal = .{ .prefixAction = null, .infixAction = binary, .prec = .equality },

            .left_angle_brack = .{ .prefixAction = null, .infixAction = binary, .prec = .inequality },
            .right_angle_brack = .{ .prefixAction = null, .infixAction = binary, .prec = .inequality },
            .left_angle_brack_equal = .{ .prefixAction = null, .infixAction = binary, .prec = .inequality },
            .right_angle_brack_equal = .{ .prefixAction = null, .infixAction = binary, .prec = .inequality },

            .plus = .{ .prefixAction = null, .infixAction = binary, .prec = .term },
            .dash = .{ .prefixAction = unary, .infixAction = binary, .prec = .term },

            .star = .{ .prefixAction = null, .infixAction = binary, .prec = .factor },
            .fwd_slash = .{ .prefixAction = null, .infixAction = binary, .prec = .factor },

            .bang = .{ .prefixAction = unary, .infixAction = null, .prec = .unary },
        },
    );

    inline fn parseRule(tok_ty: Token.Type) *const Rule {
        return &rules[@enumToInt(tok_ty)];
    }

    fn init(gpa: Allocator, context: *Context, module: *Module, scanner: Scanner) !Self {
        return Self{
            .gpa = gpa,
            .context = context,
            .module = module,
            .current_chunk = try module.newChunk(),
            .scanner = scanner,
        };
    }

    fn resetState(self: *Self, source: [:0]const u8) !void {
        self.panic_mode = false;
        self.reported_errors = 0;
        self.current_chunk = try self.module.newChunk();
        self.scanner.setSource(source);
    }

    fn next(self: *Self) void {
        // The first time `next` is called, both `prev_tok` and `tok` are uninitialized, but
        // `prev_tok` is not accessed until after `next` has been called an additional time.
        self.prev_tok = self.tok;
        self.tok = self.scanner.next();
        while (true) {
            // Skip invalid tokens.
            if (self.tok.type != Token.Type.invalid) return;
            self.errorAtCurrent(Error.unknown_character);
        }
    }

    fn expect(self: *Self, expected: Token.Type) void {
        if (self.tok.type == expected) {
            self.next();
            return;
        }
        self.errorAtCurrent(Error.unexpected_token);
    }

    fn hadError(self: Self) bool {
        return self.reported_errors > 0;
    }

    fn errorAt(
        self: *Self,
        comptime err: Error,
        tok: Token,
    ) !void {
        if (self.panic_mode or self.reported_errors > max_errors) {
            return;
        }
        self.panic_mode = true;

        const stderr = std.io.getStdErr();
        const TTY = std.debug.TTY;
        TTY.Config.setColor(self.context.tty_config, stderr, TTY.Color.Bold);
        TTY.Config.setColor(self.context.tty_config, stderr, TTY.Color.Red);
        try stderr.writeAll("error: ");
        TTY.Config.setColor(self.context.tty_config, stderr, TTY.Color.Reset);

        const writer = stderr.writer();
        switch (err) {
            .unknown_character => {
                const ch = self.scanner.source[tok.loc.lo];
                try if (std.ascii.isPrint(ch))
                    writer.print("invalid character in current context: '{c}'\n", .{ch})
                else
                    writer.print("unknown byte: '{x}'\n", .{ch});
            },
            .unexpected_token => try writer.print("expected {s}\n", .{tok.type.toString()}),
            .empty_expression => try writer.writeAll("expected an expression\n"),
        }
        // TODO: Print location
        self.reported_errors += 1;
    }

    fn errorAtCurrent(self: *Self, comptime err: Error) void {
        // TODO: Quick fix for ignoring failed stderr write. Ultimately want to unite error handling
        // between parser, VM, and other general errors (std.log??) in a way that can provide
        // colored output.
        errorAt(self, err, self.tok) catch return;
    }

    fn errorAtPrev(self: *Self, comptime err: Error) void {
        errorAt(self, err, self.prev_tok) catch return;
    }

    /// Expecting `item` to be a `Value`, `bytecode.OpCode`, or `u8`.
    fn emit(self: *Self, item: anytype) !void {
        // TODO: Currently cannot give line numbers to bytecode chunk because of the location
        // information associated with each token: an offset into a source file instead of
        // line/col. This allows line & col to be calculated on demand and provides easy access to
        // source code snippets for error messages. Because line & col information is only necessary
        // in the case of an error, it is ok to find the line and col from an offset for error
        // messages as needed. However, should bytecode instructions use this same location repr? It
        // will then become necessary to be able to translate offsets into line numbers from
        // bytecode module.
        try self.current_chunk.write(item, 1);
    }

    fn compile_module(self: *Self) !void {
        self.next();
        try self.expression();
        self.expect(.eof);
        try self.emit(.ret);
    }

    fn expression(self: *Self) !void {
        try self.parsePrecedence(.assignment);
    }

    fn parsePrecedence(self: *Self, min_prec: Precedence) !void {
        self.next();
        const lhs_rule = parseRule(self.prev_tok.type);
        std.log.debug("prev_tok.type in `parsePrecedence`: {s}\n", .{@tagName(self.prev_tok.type)});
        if (lhs_rule.prefixAction) |prefixAction| {
            try prefixAction(self);
            while (@enumToInt(parseRule(self.tok.type).prec) >= @enumToInt(min_prec)) {
                std.log.debug(
                    "current tok prec: {}, min prec: {} in `parsePrecedence`\n",
                    .{ @enumToInt(parseRule(self.tok.type).prec), @enumToInt(min_prec) },
                );
                self.next();
                const rhs_rule = parseRule(self.prev_tok.type);
                try rhs_rule.infixAction.?(self);
            }
        } else {
            self.errorAtPrev(.empty_expression);
        }
    }

    fn binary(self: *Self) error{OutOfMemory}!void {
        // Assumes that the lhs has already been consumed.
        const op = self.prev_tok.type;
        std.log.debug("prev_tok.type in `binary`: {s}\n", .{@tagName(self.prev_tok.type)});
        const rule = parseRule(op);
        // Precedence is incremented to enforce left-associativity.
        try self.parsePrecedence(rule.prec.nextLevel());

        const opcode: bytecode.OpCode = switch (op) {
            .equal_equal => .eq,
            .left_angle_brack => .lt,
            .left_angle_brack_equal => .le,
            .right_angle_brack => .gt,
            .right_angle_brack_equal => .ge,
            .plus => .add,
            .dash => .sub,
            .star => .mul,
            .fwd_slash => .div,
            else => unreachable,
        };
        try self.emit(opcode);
    }

    fn grouping(self: *Self) !void {
        // Assumes that left paren is the previous token.
        try self.expression();
        self.expect(.right_paren);
    }

    fn unary(self: *Self) !void {
        // Assumes that the operator is the previous token.
        const op = self.prev_tok.type;
        std.log.debug("prev_tok.type in `unary`: {s}\n", .{@tagName(self.prev_tok.type)});

        // Ensure any additional unary operators are applied first.
        try self.parsePrecedence(.unary);

        const opcode: bytecode.OpCode = switch (op) {
            .dash => .neg,
            .bang => .not,
            else => unreachable,
        };
        try self.emit(opcode);
    }

    fn number(self: *Self) error{OutOfMemory}!void {
        // Able to disregard checking for a parse error because the number has been validated during tokenization.
        const num = std.fmt.parseFloat(
            f64,
            self.prev_tok.loc.contents(self.scanner.source),
        ) catch unreachable;
        std.log.debug("num is: {}\n", .{num});
        try self.emit(Value.init(num));
    }

    fn literal(self: *Self) !void {
        const opcode: bytecode.OpCode = switch (self.prev_tok.type) {
            .keyword_nil => .nil,
            .keyword_true => .@"true",
            .keyword_false => .@"false",
            else => unreachable,
        };
        try self.emit(opcode);
    }

    test "operators" {
        try testCase("1", comptime .{Value.init(1)});
        try testCase("1 + 2", comptime .{ Value.init(1), Value.init(2), .add });
        try testCase("1 - 2 + 3", comptime .{
            Value.init(1),
            Value.init(2),
            .sub,
            Value.init(3),
            .add,
        });
        try testCase("1 - (2 + 3)", comptime .{
            Value.init(1),
            Value.init(2),
            Value.init(3),
            .add,
            .sub,
        });
        try testCase("1 + 2 * 3 - 4 < !5 == 6 > 7", comptime .{
            Value.init(1),
            Value.init(2),
            Value.init(3),
            .mul,
            .add,
            Value.init(4),
            .sub,
            Value.init(5),
            .not,
            .lt,
            Value.init(6),
            Value.init(7),
            .gt,
            .eq,
        });
        try testCase("-!-1", comptime .{
            Value.init(1),
            .neg,
            .not,
            .neg,
        });
    }

    fn testCase(source_code: [:0]const u8, comptime expected_data: anytype) !void {
        var expected_chunk = bytecode.Chunk.init(testing.allocator);
        defer expected_chunk.deinit();
        try expected_chunk.fill(expected_data);

        var context = try Context.init(testing.allocator, .{ .main_file_path = null });
        defer context.deinit();
        var module = &context.main_module;
        var parser = try Parser.init(testing.allocator, &context, module, Scanner{ .source = source_code });
        parser.next();
        try parser.expression();
        try expected_chunk.expectEqual(&module.bytecode.elems[0]);
    }
};

test {
    testing.refAllDecls(@This());
}