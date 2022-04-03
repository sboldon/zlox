const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const stderr = std.io.getStdErr();

const bytecode = @import("bytecode.zig");
const Chunk = bytecode.Chunk;
const OpCode = bytecode.OpCode;
const value = @import("value.zig");
const Value = value.Value;
const ValueType = value.ValueType;

// const InterpretError = blk: {
//     var ErrorSet = CompileError || RuntimeError || std.os.WriteError;
//     if (build_options.exec_tracing and Writer.Error != std.os.WriteError) {
//         ErrorSet = ErrorSet || Writer.Error;
//     }
//     break :blk ErrorSet;
// };
// TODO: Moving these errors outside VirtMach function so that they can be accessed in other scopes
// no longer adds vm `Writer.Error` to `InterpretError` when project was built with execution
// tracing enabled.
const InterpretError = CompileError || RuntimeError || std.os.WriteError;
const CompileError = error{
    Placeholder,
};
const RuntimeError = TypeError;
const TypeError = error{
    UnOp,
    BinOp,
};

pub fn VirtMach(comptime Writer: type) type {
    return struct {
        const Self = @This();

        const stack_size = 50;

        writer: Writer = undefined,
        // TODO: Grow stack when it is full instead of overflowing?
        stack: [stack_size]Value = [_]Value{Value.init(0)} ** stack_size,
        sp: [*]Value = undefined,
        chunk: *Chunk = undefined,
        // ip: [*]u8 = undefined,

        pub fn init(self: *Self, writer: Writer) void {
            self.sp = &self.stack;
            self.writer = writer;
        }

        pub fn emptyStack(self: *Self) void {
            self.sp = &self.stack;
        }

        pub fn interpret(self: *Self, chunk: *Chunk) InterpretError!void {
            //  try self.writer.print("{*} {*}\n", .{ self.sp, &self.stack[0] });
            self.chunk = chunk;
            // self.sp = &self.stack;
            // self.ip = self.chunk.code.elems.ptr;
            return self.run();
        }

        // TODO: Rewrite bytecode dispatch using a direct threaded approach once the accepted proposal
        // for labeled continue syntax inside a switch expression is implemented.
        fn run(self: *Self) InterpretError!void {
            var ip: [*]u8 = self.chunk.code.elems.ptr;
            var instruction: OpCode = undefined;
            while (true) {
                if (comptime build_options.exec_tracing) {
                    for (self.stack) |val| {
                        try self.writer.print("[ {} ]", .{val});
                    }
                    try self.writer.print("\n", .{});
                    _ = try self.chunk.disassembleInstr(self.writer, self.chunk.offsetOfAddr(ip));
                }
                instruction = @intToEnum(OpCode, readByte(&ip));
                switch (instruction) {
                    .ret => {
                        std.debug.print("returned: {}\n", .{self.pop()});
                        return;
                    },
                    .constant => {
                        //self.push(self.readConstant(&ip));
                        var val = self.readConstant(&ip);
                        self.push(val);
                        // break;
                    },
                    .nil => self.push(Value.init({})),
                    .@"true" => self.push(Value.init(true)),
                    .@"false" => self.push(Value.init(false)),
                    .add => try self.binOp(ip, .add),
                    .sub => try self.binOp(ip, .sub),
                    .mul => try self.binOp(ip, .mul),
                    .div => try self.binOp(ip, .div),
                    .gt => try self.binOp(ip, .gt),
                    .ge => try self.binOp(ip, .ge),
                    .lt => try self.binOp(ip, .lt),
                    .le => try self.binOp(ip, .le),
                    .eq => {
                        // It is not possible for an equality operation to fail type checking.
                        const rhs = self.pop();
                        const lhs = self.pop();
                        self.push(lhs.binOp(.eq, rhs));
                    },
                    .neq => {
                        const rhs = self.pop();
                        const lhs = self.pop();
                        self.push(lhs.binOp(.neq, rhs));
                    },
                    .neg => {
                        var stacktop = @ptrCast(*Value, self.sp - 1);
                        try self.checkOperandType(ip, stacktop.*, ValueType.number);
                        // Equivalent to `push(-pop())`.
                        stacktop.set(-stacktop.asNumber());
                    },
                    .not => {
                        var stacktop = @ptrCast(*Value, self.sp - 1);
                        // Equivalent to `push(!pop())`.
                        stacktop.set(stacktop.isFalsey());
                    },
                    else => std.debug.panic("invalid bytecode opcode: {}", .{instruction}),
                }
            }
        }

        inline fn push(self: *Self, val: Value) void {
            // TODO: This currently will write past the end of the stack like it's nbd.
            self.sp[0] = val;
            self.sp += 1;
        }

        inline fn pop(self: *Self) Value {
            self.sp -= 1;
            return self.sp[0];
        }

        inline fn peek(self: Self, distance: usize) Value {
            return (self.sp - 1 - distance)[0]; // Top of the stack is at `self.sp - 1`.
        }

        // TODO: Check generated code to see if inlining removes superfluous deref of ip. If it does
        // not, then there does not appear to be much of a benefit to having the instruction pointer
        // as an local variable instead of as a member of VirtMach.
        inline fn readByte(ip: *[*]const u8) u8 {
            const byte = ip.*[0];
            ip.* += 1;
            return byte;
        }

        inline fn readConstant(self: Self, ip: *[*]u8) Value {
            return self.chunk.data.elems[readByte(ip)];
        }

        fn binOp(self: *Self, ip: [*]const u8, comptime op: OpCode) InterpretError!void {
            const rhs = self.pop();
            const lhs = self.pop();
            if (bytecode.validOperandTypes(op).contains(lhs.type()) and rhs.type() == lhs.type()) {
                self.push(lhs.binOp(op, rhs));
            } else {
                // Push operands back onto the stack to make them visible to the GC.
                self.push(lhs);
                self.push(rhs);
                return self.interpretError(
                    TypeError.BinOp,
                    ip,
                    .{ bytecode.opCodeLexeme(op), lhs.type(), rhs.type() },
                );
            }
        }

        fn checkOperandType(
            self: Self,
            ip: [*]const u8,
            operand: Value,
            expected_type: ValueType,
        ) InterpretError!void {
            if (operand.type() != expected_type) {
                return self.interpretError(
                    TypeError.UnOp,
                    ip,
                    .{ ValueType.number, operand.type() },
                );
            }
        }

        fn interpretError(
            self: Self,
            comptime err: InterpretError,
            ip: [*]const u8,
            args: anytype,
        ) InterpretError {
            const TTY = std.debug.TTY;
            const config = std.debug.detectTTYConfig();
            TTY.Config.setColor(config, stderr, TTY.Color.Bold);
            TTY.Config.setColor(config, stderr, TTY.Color.Red);
            try stderr.writeAll("error: ");
            TTY.Config.setColor(config, stderr, TTY.Color.Reset);

            const writer = stderr.writer();
            switch (err) {
                // "expected an operand of numeric type, but found bool"
                // "expected operand with number type, but found bool"
                // "expected numeric operand but found {}",
                // RuntimeError.InvalidType => try writer.print(
                //     "expected {s} of type {} but found {}\n",
                //     args,
                // ),
                TypeError.UnOp => try writer.print(
                    "expected {} operand but found {}\n",
                    args,
                ),
                TypeError.BinOp => try writer.print(
                    "invalid operand types for {s} operator: {} and {}\n",
                    args,
                ),
                else => {},
            }
            try writer.print("[line {d}] in script\n", .{self.chunk.lineOfInstr(ip - 1)});
            // try writer.print("[line {d}] in script\n", .{self.chunk.line_info.getLineFromOffset(self.chunk.offsetOfAddr(ip - 1))});
            return err;
        }
    };
}

test "arithmetic operators" {
    const stdout = std.io.getStdOut();
    var vm = VirtMach(std.fs.File.Writer){};
    vm.init(stdout.writer());

    // `-((1.2 + 3.4) / 2)` == `-2.3`
    {
        var chunk = Chunk.init(testing.allocator);
        defer chunk.deinit();
        try chunk.writeOpCode(.constant, 1);
        try chunk.write(try chunk.addConstant(Value.init(1.2)), 1);
        try chunk.writeOpCode(.constant, 1);
        try chunk.write(try chunk.addConstant(Value.init(3.4)), 1);
        try chunk.writeOpCode(.add, 1);
        try chunk.writeOpCode(.constant, 1);
        try chunk.write(try chunk.addConstant(Value.init(2)), 1);
        try chunk.writeOpCode(.div, 1);
        try chunk.writeOpCode(.neg, 1);
        try chunk.writeOpCode(.ret, 2);
        try chunk.writeOpCode(.ret, 3);
        try vm.interpret(&chunk);
        try testing.expectEqual(@as(f64, -2.3), vm.stack[0].asNumber());
    }

    // `-true` results in a type error
    {
        var chunk = Chunk.init(testing.allocator);
        defer chunk.deinit();
        try chunk.writeOpCode(.constant, 1);
        try chunk.write(try chunk.addConstant(Value.init(true)), 1);
        try chunk.writeOpCode(.neg, 1);
        try chunk.writeOpCode(.ret, 1);
        try testing.expectError(TypeError.UnOp, vm.interpret(&chunk));
    }

    // `2.5 + false` results in a type error
    {
        var chunk = Chunk.init(testing.allocator);
        defer chunk.deinit();
        const lhs = Value.init(2.5);
        const rhs = Value.init(false);
        try chunk.writeOpCode(.constant, 1);
        try chunk.write(try chunk.addConstant(lhs), 1);
        try chunk.writeOpCode(.constant, 1);
        try chunk.write(try chunk.addConstant(rhs), 1);
        try chunk.writeOpCode(.add, 1);
        try testing.expectError(TypeError.BinOp, vm.interpret(&chunk));
        try testing.expectEqual(vm.peek(0), rhs);
        try testing.expectEqual(vm.peek(1), lhs);
    }
}
