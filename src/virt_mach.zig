const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const stderr = std.io.getStdErr();

const build_options = @import("build_options");
const writeAllColor = @import("main.zig").writeAllColor;
const InternedStringHashMap = @import("interning.zig").InternedStringHashMap;
const Context = @import("Context.zig");
const Module = @import("Module.zig");
const Chunk = @import("bytecode.zig").Chunk;
const OpCode = @import("bytecode.zig").OpCode;
const value = @import("value.zig");
const Value = @import("value.zig").Value;
const ValueType = @import("value.zig").ValueType;
const Obj = @import("object.zig").Obj;
const StringObj = @import("object.zig").StringObj;

const InterpretError = RuntimeError || std.os.WriteError || error{OutOfMemory};
const RuntimeError = TypeError || error{
    UndefinedVar,
};
const TypeError = error{
    UnOp,
    BinOp,
};

pub const VirtMach = struct {
    const Self = @This();

    var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
    const stdout_writer = stdout_buffer.writer();

    // TODO: Grow stack when it is full instead of overflowing?
    const stack_size = 1024;

    gpa: Allocator,
    ctx: *Context,
    globals: InternedStringHashMap(Value),

    stack: [stack_size]Value = [_]Value{Value.init(0)} ** stack_size,
    sp: [*]Value = undefined,
    chunk: *Chunk = undefined,

    pub fn init(ctx: *Context) Self {
        return .{
            .gpa = ctx.gpa,
            .ctx = ctx,
            .globals = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.globals.deinit(self.gpa);
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
    // for labeled continue syntax inside a switch expression is implemented (github issue #8220).
    fn run(self: *Self) InterpretError!void {
        var ip: [*]u8 = self.chunk.code.elems.ptr;

        var instruction: OpCode = undefined;
        while (true) {
            if (comptime build_options.exec_tracing) {
                try self.trace(ip);
            }
            instruction = @intToEnum(OpCode, readByte(&ip));
            switch (instruction) {
                .constant => self.push(self.readConstant(&ip)),
                .constant_long => self.push(self.readConstantLong(&ip)),
                .def_global => try self.defGlobal(self.readConstant(&ip)),
                .def_global_long => try self.defGlobal(self.readConstantLong(&ip)),
                .get_global => try self.getGlobal(ip, self.readConstant(&ip)),
                .get_global_long => try self.getGlobal(ip, self.readConstantLong(&ip)),
                .set_global => try self.setGlobal(ip, self.readConstant(&ip)),
                .set_global_long => try self.setGlobal(ip, self.readConstantLong(&ip)),

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
                .eq => try self.binOp(ip, .eq),
                .neq => try self.binOp(ip, .neq),
                .neg => {
                    const stacktop = @ptrCast(*Value, self.sp - 1);
                    try self.checkOperandType(ip, stacktop.*, .number);
                    // Equivalent to `push(-pop())`.
                    stacktop.set(-stacktop.asNumber());
                },
                .not => {
                    const stacktop = @ptrCast(*Value, self.sp - 1);
                    // Equivalent to `push(!pop())`.
                    stacktop.* = Value.init(stacktop.isFalsey());
                },

                .ret => return,
                .pop => _ = self.pop(),
                .print => {
                    try stdout_writer.print("{}\n", .{self.pop()});
                    try stdout_buffer.flush();
                },
                else => std.debug.panic("invalid bytecode opcode: {}", .{instruction}),
            }
        }
    }

    inline fn defGlobal(self: *Self, identifier: Value) InterpretError!void {
        const var_name = identifier.asObj().asString();
        try self.globals.put(self.gpa, var_name, self.peek(0));
        _ = self.pop();
    }

    inline fn getGlobal(self: *Self, ip: [*]const u8, identifier: Value) InterpretError!void {
        const var_name = identifier.asObj().asString();
        if (self.globals.get(var_name)) |val| {
            self.push(val);
        } else {
            return self.interpretError(RuntimeError.UndefinedVar, ip, .{var_name});
        }
    }

    inline fn setGlobal(self: *Self, ip: [*]const u8, identifier: Value) InterpretError!void {
        const var_name = identifier.asObj().asString();
        if (self.globals.getPtr(var_name)) |val| {
            val.* = self.peek(0);
        } else {
            return self.interpretError(RuntimeError.UndefinedVar, ip, .{var_name});
        }
    }

    fn binOp(self: *Self, ip: [*]const u8, comptime op: OpCode) InterpretError!void {
        const rhs = self.pop();
        const lhs = self.pop();
        const val = switch (op) {
            .add => if (lhs.type() == .number and rhs.type() == .number)
                Value.init(lhs.number + rhs.number)
            else if (lhs.isObjType(.string) and rhs.isObjType(.string)) blk: {
                // const string_obj =
                //     try StringObj.concat(self.context.gpa, lhs.obj.asString(), rhs.obj.asString());
                // const obj = string_obj.asObj();
                // self.context.trackObj(obj);
                // break :blk Value.init(obj);
                const string_obj = try self.ctx.concatStrings(lhs.obj.asString(), rhs.obj.asString());
                break :blk Value.init(string_obj);
            } else TypeError.BinOp,
            .sub => if (lhs.type() == .number and rhs.type() == .number) Value.init(lhs.number - rhs.number) else TypeError.BinOp,
            .mul => if (lhs.type() == .number and rhs.type() == .number) Value.init(lhs.number * rhs.number) else TypeError.BinOp,
            .div => if (lhs.type() == .number and rhs.type() == .number) Value.init(lhs.number / rhs.number) else TypeError.BinOp,
            .gt => if (lhs.type() == .number and rhs.type() == .number) Value.init(lhs.number > rhs.number) else TypeError.BinOp,
            .ge => if (lhs.type() == .number and rhs.type() == .number) Value.init(lhs.number >= rhs.number) else TypeError.BinOp,
            .lt => if (lhs.type() == .number and rhs.type() == .number) Value.init(lhs.number < rhs.number) else TypeError.BinOp,
            .le => if (lhs.type() == .number and rhs.type() == .number) Value.init(lhs.number <= rhs.number) else TypeError.BinOp,
            .eq => @as(anyerror!Value, Value.init(lhs.isEqual(rhs))), // No error possible.
            .neq => @as(anyerror!Value, Value.init(!lhs.isEqual(rhs))), // No error possible.
            else => @compileError("invalid binary operator: " ++ @tagName(op)),
        } catch {
            // Push operands back onto the stack to make them visible to the GC.
            self.push(lhs);
            self.push(rhs);
            return self.interpretError(
                TypeError.BinOp,
                ip,
                .{ op.lexeme(), lhs.type(), rhs.type() },
            );
        };
        self.push(val);
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

    inline fn readByte(ip: *[*]const u8) u8 {
        const byte = ip.*[0];
        ip.* += 1;
        return byte;
    }

    inline fn readConstant(self: Self, ip: *[*]u8) Value {
        return self.chunk.data.elems[readByte(ip)];
    }

    inline fn readConstantLong(self: Self, ip: *[*]u8) Value {
        const lsb = readByte(ip);
        return self.chunk.data.elems[(@as(u16, readByte(ip)) << 8) | lsb];
    }

    fn interpretError(
        self: Self,
        comptime err: InterpretError,
        ip: [*]const u8,
        args: anytype,
    ) InterpretError {
        const Color = std.debug.TTY.Color;
        try writeAllColor(self.ctx.tty_config, Color.Red, Color.Bold, "error: ");
        const writer = stderr.writer();
        switch (err) {
            RuntimeError.UndefinedVar => try writer.print("variable '{}' is undefined\n", args),
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

    fn trace(self: *Self, ip: [*]u8) !void {
        const writer = stderr.writer();
        try writer.writeAll("\nVM stack contents: ");
        for (self.stack) |*val, i| {
            if (i == 64) break; // Only display first 64 stack values.
            if (i & 31 == 0) try writer.writeAll("\n");
            if (val == @ptrCast(*Value, self.sp - 1)) {
                try writer.print("[< {} >]", .{val});
            } else {
                try writer.print("[ {} ]", .{val});
            }
        }
        try writer.writeAll("\ncurrent instruction: ");
        _ = try self.chunk.disassembleInstr(writer, self.chunk.offsetOfAddr(ip));
    }

    test "arithmetic operators" {
        // `-((1.2 + 3.4) / 2)` == -2.3
        {
            var state = try TestCase.init();
            defer state.deinit();
            try state.chunk.fill(.{
                Value.init(1.2),
                Value.init(3.4),
                .add,
                Value.init(2),
                .div,
                .neg,
                .pop,
                .ret,
            });
            try state.vm.interpret(&state.chunk);
            try testing.expectEqual(@as(f64, -2.3), state.vm.sp[0].asNumber());
        }
        // `"hello" + "world"` == "helloworld"
        {
            var state = try TestCase.init();
            defer state.deinit();
            var s1 = StringObj.init("hello");
            var s2 = StringObj.init("world");
            var expected = StringObj.init("helloworld");
            try state.chunk.fill(.{ Value.init(&s1), Value.init(&s2), .add, .pop, .ret });
            try state.vm.interpret(&state.chunk);
            try expected.testingExpectEqual(state.vm.sp[0].asObj().asString());
        }
        // `-true` results in a type error
        {
            var state = try TestCase.init();
            defer state.deinit();
            try state.chunk.fill(.{ Value.init(true), .neg, .pop, .ret });
            try testing.expectError(TypeError.UnOp, state.vm.interpret(&state.chunk));
        }
        // `2.5 + false` results in a type error
        {
            var state = try TestCase.init();
            defer state.deinit();
            const lhs = Value.init(2.5);
            const rhs = Value.init(false);
            try state.chunk.fill(.{ lhs, rhs, .add });
            try testing.expectError(TypeError.BinOp, state.vm.interpret(&state.chunk));
            try testing.expectEqual(state.vm.peek(0), rhs);
            try testing.expectEqual(state.vm.peek(1), lhs);
        }
    }

    test "boolean operators" {
        // `!true` == `false`
        {
            var state = try TestCase.init();
            defer state.deinit();
            try state.chunk.fill(.{ .@"true", .not, .pop, .ret });
            try state.vm.interpret(&state.chunk);
            try testing.expectEqual(false, state.vm.sp[0].asBool());
        }
        // `!false` == `true`
        {
            var state = try TestCase.init();
            defer state.deinit();
            try state.chunk.fill(.{ .@"false", .not, .pop, .ret });
            try state.vm.interpret(&state.chunk);
            try testing.expectEqual(true, state.vm.sp[0].asBool());
        }
        // `!0` == `true`
        {
            var state = try TestCase.init();
            defer state.deinit();
            try state.chunk.fill(.{ Value.init(0), .not, .pop, .ret });
            try state.vm.interpret(&state.chunk);
            try testing.expectEqual(true, state.vm.sp[0].asBool());
        }
    }

    test "global vars" {
        // `var x = 2; x + 7` results in 9 on the top of the stack.
        {
            var state = try TestCase.init();
            defer state.deinit();
            // The same string value is added to the chunk multiple times to mimic how the compiler
            // currently generates chunks.
            var var_name = try state.ctx.createString("x");
            _ = try state.chunk.addConstant(Value.init(var_name));
            _ = try state.chunk.addConstant(Value.init(var_name));
            try state.chunk.fill(.{
                Value.init(2),
                .def_global,
                0,
                .get_global,
                1,
                Value.init(7),
                .add,
                .pop,
                .ret,
            });
            try state.vm.interpret(&state.chunk);
            try testing.expectEqual(@as(f64, 9), state.vm.sp[0].asNumber());
        }

        // `var x = -1; x = x + 50;` results with `x` having a value of 49
        {
            var state = try TestCase.init();
            defer state.deinit();
            // Fill chunk up with constants so that u16 operand instructions have to be used.
            var i: usize = 0;
            while (i <= std.math.maxInt(u8)) : (i += 1) {
                try state.chunk.write(Value.init(0), 1);
            }
            var var_name = try state.ctx.createString("x");
            _ = try state.chunk.addConstant(Value.init(var_name)); // At data index 256.
            _ = try state.chunk.addConstant(Value.init(var_name));
            _ = try state.chunk.addConstant(Value.init(var_name));
            try state.chunk.fill(.{
                Value.init(-1),
                .def_global_long,
                @as(u16, 256),
                .get_global_long,
                @as(u16, 257),
                Value.init(50),
                .add,
                .set_global_long,
                @as(u16, 258),
                .pop,
                .ret,
            });
            try state.vm.interpret(&state.chunk);
            try testing.expectEqual(@as(f64, 49), state.vm.globals.get(var_name).?.asNumber());
        }

        // Use of undefined variable causes runtime error
        {
            var state = try TestCase.init();
            defer state.deinit();
            var var_name = try state.ctx.createString("x");
            _ = try state.chunk.addConstant(Value.init(var_name));
            try state.chunk.fill(.{
                .get_global,
                0,
                .pop,
                .ret,
            });
            try testing.expectError(RuntimeError.UndefinedVar, state.vm.interpret(&state.chunk));
        }

        // Assignment to undefined variable causes runtime error
        {
            var state = try TestCase.init();
            defer state.deinit();
            var var_name = try state.ctx.createString("x");
            _ = try state.chunk.addConstant(Value.init(var_name));
            try state.chunk.fill(.{
                Value.init(20),
                .set_global,
                0,
                .pop,
                .ret,
            });
            try testing.expectError(RuntimeError.UndefinedVar, state.vm.interpret(&state.chunk));
        }
    }

    const TestCase = struct {
        ctx: *Context,
        vm: VirtMach,
        chunk: Chunk,

        fn init() !TestCase {
            const ctx = try testing.allocator.create(Context);
            ctx.* = try Context.init(testing.allocator, .{ .main_file_path = null });
            var vm = VirtMach.init(ctx);
            vm.resetStack();
            var chunk = Chunk.init(testing.allocator);
            return TestCase{ .ctx = ctx, .vm = vm, .chunk = chunk };
        }

        fn deinit(state: *TestCase) void {
            state.ctx.deinit();
            testing.allocator.destroy(state.ctx);
            state.vm.deinit();
            state.chunk.deinit();
        }
    };
};

test {
    testing.refAllDecls(@This());
}
