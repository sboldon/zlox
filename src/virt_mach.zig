const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const stderr = std.io.getStdErr();

const build_options = @import("build_options");
const Context = @import("Context.zig");
const Module = @import("module.zig").Module;
const bytecode = @import("bytecode.zig");
const Chunk = bytecode.Chunk;
const OpCode = bytecode.OpCode;
const value = @import("value.zig");
const Value = value.Value;
const ValueType = value.ValueType;

const InterpretError = CompileError || RuntimeError || std.os.WriteError;
const CompileError = error{Placeholder};
const RuntimeError = TypeError;
const TypeError = error{
    UnOp,
    BinOp,
};

pub const VirtMach = struct {
    const Self = @This();

    // TODO: Grow stack when it is full instead of overflowing?
    const stack_size = 50;

    context: *Context,
    stack: [stack_size]Value = [_]Value{Value.init(0)} ** stack_size,
    sp: [*]Value = undefined,
    chunk: *Chunk = undefined,
    // ip: [*]u8 = undefined,

    pub fn init(ctx: *Context) Self {
        return .{ .context = ctx };
    }

    /// This must be called before the first call to `interpret`.
    pub fn resetStack(self: *Self) void {
        self.sp = &self.stack;
    }

    // pub fn interpret(self: *Self, module: *Module) InterpretError!void {
    pub fn interpret(self: *Self, chunk: *Chunk) InterpretError!void {
        //  try self.writer.print("{*} {*}\n", .{ self.sp, &self.stack[0] });
        // self.chunk = chunk;
        // self.sp = &self.stack;
        // self.ip = self.chunk.code.elems.ptr;
        self.chunk = chunk;
        return self.run();
    }

    // TODO: Rewrite bytecode dispatch using a direct threaded approach once the accepted proposal
    // for labeled continue syntax inside a switch expression is implemented.
    fn run(self: *Self) InterpretError!void {
        var ip: [*]u8 = self.chunk.code.elems.ptr;
        var instruction: OpCode = undefined;
        while (true) {
            if (comptime build_options.exec_tracing) {
                const writer = stderr.writer();
                try writer.writeAll("\nVM stack contents: ");
                for (self.stack) |val| {
                    try writer.print("[ {} ]", .{val});
                }
                try writer.writeAll("\ncurrent instruction: ");
                _ = try self.chunk.disassembleInstr(writer, self.chunk.offsetOfAddr(ip));
            }
            instruction = @intToEnum(OpCode, readByte(&ip));
            switch (instruction) {
                .ret => {
                    // _ = self.pop();
                    std.debug.print("evaluates to: {}\n", .{self.pop()});
                    return;
                },
                .constant => {
                    //self.push(self.readConstant(&ip));
                    var val = self.readConstant(&ip);
                    self.push(val);
                },
                .nil => self.push(comptime Value.init({})),
                .@"true" => self.push(comptime Value.init(true)),
                .@"false" => self.push(comptime Value.init(false)),
                .add => try self.binOp(ip, .add),
                .sub => try self.binOp(ip, .sub),
                .mul => try self.binOp(ip, .mul),
                .div => try self.binOp(ip, .div),
                .gt => try self.binOp(ip, .gt),
                .ge => try self.binOp(ip, .ge),
                .lt => try self.binOp(ip, .lt),
                .le => try self.binOp(ip, .le),
                .eq => {
                    // No typechecking is required because equality is defined over all types.
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
                    try self.checkOperandType(ip, stacktop.*, .number);
                    // Equivalent to `push(-pop())`.
                    stacktop.set(-stacktop.asNumber());
                },
                .not => {
                    var stacktop = @ptrCast(*Value, self.sp - 1);
                    // Equivalent to `push(!pop())`.
                    stacktop.* = Value.init(stacktop.isFalsey());
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
                .{ .number, operand.type() },
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
        TTY.Config.setColor(self.context.tty_config, stderr, TTY.Color.Bold);
        TTY.Config.setColor(self.context.tty_config, stderr, TTY.Color.Red);
        try stderr.writeAll("error: ");
        TTY.Config.setColor(self.context.tty_config, stderr, TTY.Color.Reset);

        const writer = stderr.writer();
        switch (err) {
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
        return err;
    }
};

test "arithmetic operators" {
    const gpa = std.testing.allocator;
    var context = try Context.init(gpa, .{ .main_file_path = null });
    defer context.deinit();
    var vm = VirtMach.init(&context);
    vm.resetStack();

    // `-((1.2 + 3.4) / 2)` == `-2.3`
    {
        var chunk = Chunk.init(testing.allocator);
        defer chunk.deinit();
        try chunk.fill(comptime .{
            Value.init(1.2),
            Value.init(3.4),
            .add,
            Value.init(2),
            .div,
            .neg,
            .ret,
        });
        try vm.interpret(&chunk);
        try testing.expectEqual(@as(f64, -2.3), vm.sp[0].asNumber());
    }

    // `-true` results in a type error
    {
        var chunk = Chunk.init(testing.allocator);
        defer chunk.deinit();
        try chunk.fill(comptime .{ Value.init(true), .neg, .ret });
        try testing.expectError(TypeError.UnOp, vm.interpret(&chunk));
    }

    // `2.5 + false` results in a type error
    {
        var chunk = Chunk.init(testing.allocator);
        defer chunk.deinit();
        const lhs = comptime Value.init(2.5);
        const rhs = comptime Value.init(false);
        try chunk.fill(.{ lhs, rhs, .add });
        try testing.expectError(TypeError.BinOp, vm.interpret(&chunk));
        try testing.expectEqual(vm.peek(0), rhs);
        try testing.expectEqual(vm.peek(1), lhs);
    }
}

test "boolean operators" {
    const gpa = std.testing.allocator;
    var context = try Context.init(gpa, .{ .main_file_path = null });
    defer context.deinit();
    var vm = VirtMach.init(&context);
    vm.resetStack();

    // `!true` == `false`
    {
        var chunk = Chunk.init(testing.allocator);
        defer chunk.deinit();
        try chunk.fill(.{ .@"true", .not, .ret });
        try vm.interpret(&chunk);
        try testing.expectEqual(false, vm.sp[0].asBool());
    }

    // `!false` == `true`
    {
        var chunk = Chunk.init(testing.allocator);
        defer chunk.deinit();
        try chunk.fill(.{ .@"false", .not, .ret });
        try vm.interpret(&chunk);
        try testing.expectEqual(true, vm.sp[0].asBool());
    }

    // `!0` == `true`
    {
        var chunk = Chunk.init(testing.allocator);
        defer chunk.deinit();

        try chunk.fill(comptime .{ Value.init(0), .not, .ret });
        try vm.interpret(&chunk);
        try testing.expectEqual(true, vm.sp[0].asBool());
    }
}
