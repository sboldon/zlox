const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const DynamicArray = @import("dynamic_array.zig").DynamicArray;
const value = @import("value.zig");
const Value = value.Value;
const ValueType = value.ValueType;

// Multi-byte operands are written in little-endian byte order.
pub const OpCode = enum(u8) {
    const Self = @This();

    /// Pushes a constant value onto the stack.
    /// Args: The u8/u16 index that the constant is stored at.
    constant,
    constant_long,
    /// Binds the value on the top of the stack to an identifier and then pops the stack.
    /// Args: The u8/u16 index that the identifier is stored at.
    def_global,
    def_global_long,
    /// Attempts to retrieve the value bound to an identifier. If successful, the value is pushed
    /// onto the stack. If the identifier is undefined, a runtime error occurs.
    /// Args: The u8/u16 index that the identifier is stored at.
    get_global,
    get_global_long,
    /// Attempts to update the binding of an identifier to the value on the top of the stack. If the
    /// identifier is undefined, a runtime error occurs.
    /// Args: The u8/u16 index that the identifier is stored at.
    set_global,
    set_global_long,

    nil,
    @"true",
    @"false",

    add,
    sub,
    mul,
    div,
    gt,
    ge,
    lt,
    le,
    eq,
    neq,
    neg,
    not,

    ret,
    pop,
    print,
    _,

    pub fn validOperandType(comptime self: Self, val: Value) bool {
        return switch (self) {
            .add => val.type() == .number or val.isObjType(.string),
            .sub, .mul, .div => val.type() == .number,
            .gt, .ge, .lt, .le => val.type() == .number, // Should these be supported for strings?
            else => @compileError("invalid opcode: " ++ @tagName(self)),
        };
    }

    pub fn lexeme(comptime self: Self) []const u8 {
        return switch (self) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .gt => ">",
            .ge => ">=",
            .lt => "<",
            .le => "<=",
            .eq => "==",
            .neq => "!=",
            else => @compileError("opcode has no lexeme: " ++ @tagName(self)),
        };
    }
};

/// A sequence of bytecode instructions and associated constant data.
pub const Chunk = struct {
    const Self = @This();
    code: DynamicArray(u8),
    data: DynamicArray(Value),
    instr_locs: LocationInfo,

    pub fn init(alloc: Allocator) Self {
        return .{
            .code = DynamicArray(u8).init(alloc),
            .data = DynamicArray(Value).init(alloc),
            .instr_locs = LocationInfo.init(alloc),
        };
    }

    pub fn deinit(self: Self) void {
        self.code.deinit();
        self.data.deinit();
        self.instr_locs.deinit();
    }

    /// Add an instruction or constant to the chunk. Expecting `item` to be a `Value`, `OpCode`,
    /// `u16`, or `u8`.
    pub fn write(self: *Self, item: anytype, line: usize) !void {
        const T = @TypeOf(item);
        if (T == Value) {
            try self.writeVariableLenInstr(
                .constant,
                .constant_long,
                try self.addConstant(item),
                line,
            );
        } else if (T == @Type(.EnumLiteral) or T == OpCode) {
            try self.writeByte(@enumToInt(@as(OpCode, item)), line);
        } else if (T == u16) {
            try self.writeByte(@truncate(u8, item), line);
            if (item > std.math.maxInt(u8)) {
                try self.writeByte(@truncate(u8, item >> 8), line);
            }
        } else {
            // Expecting `T` to be u8.
            try self.writeByte(item, line);
        }
    }

    pub fn writeVariableLenInstr(
        self: *Self,
        u8_operand_op: OpCode,
        u16_operand_op: OpCode,
        operand: u16,
        line: usize,
    ) !void {
        if (operand <= std.math.maxInt(u8)) {
            try self.writeByte(@enumToInt(u8_operand_op), line);
            try self.writeByte(@truncate(u8, operand), line);
        } else {
            try self.writeByte(@enumToInt(u16_operand_op), line);
            try self.writeByte(@truncate(u8, operand), line);
            try self.writeByte(@truncate(u8, operand >> 8), line);
        }
    }

    fn writeByte(self: *Self, byte: u8, line: usize) !void {
        try self.code.append(byte);
        try self.instr_locs.update(line);
    }

    /// Return the index of `self.data` that the constant is stored at.
    pub fn addConstant(self: *Self, val: Value) !u16 {
        const index = self.data.elems.len;
        if (index > std.math.maxInt(u16)) {
            std.debug.panic(
                "internal compilation error: attempted to add a constant to a full bytecode chunk.\n",
                .{},
            );
        }
        try self.data.append(val);
        return @truncate(u16, index);
    }

    /// Display the contents of the chunk using the writer provided.
    pub fn disassemble(self: *Self, writer: anytype, chunk_name: []const u8) !void {
        std.debug.assert(self.instr_locs.line_tbl.elems.len >= 2);
        try writer.print("== {s} ==\n", .{chunk_name});
        {
            var i: usize = 0;
            while (i < self.code.elems.len) : (i = try self.disassembleInstr(writer, i)) {}
        }
        self.instr_locs.lower_bound = 0;
        self.instr_locs.upper_bound = 0;
    }

    pub fn disassembleInstr(self: *Self, writer: anytype, offset: usize) !usize {
        const op = @intToEnum(OpCode, self.code.elems[offset]);
        try writer.print("{:0>4} ", .{offset});
        if (self.instr_locs.onSameLine(offset)) {
            try writer.print("   | ", .{});
        } else {
            try writer.print("{: >4} ", .{self.lineOfInstr(offset)});
        }
        try writer.print("{s}", .{@tagName(op)});
        return switch (op) {
            .constant,
            .def_global,
            .get_global,
            .set_global,
            => blk: {
                // Display the index of `self.data` that a constant is stored at and its value.
                const i = self.code.elems[offset + 1];
                try writer.print(" {} '{}'\n", .{ i, self.data.elems[i] });
                break :blk offset + 2;
            },
            .constant_long,
            .def_global_long,
            .get_global_long,
            .set_global_long,
            => blk: {
                // Display the index of `self.data` that a constant is stored at and its value.
                const i =
                    (@as(u16, self.code.elems[offset + 2]) << 8) | self.code.elems[offset + 1];
                try writer.print(" {} '{}'\n", .{ i, self.data.elems[i] });
                break :blk offset + 3;
            },
            // Single byte instructions.
            else => blk: {
                try writer.print("\n", .{});
                break :blk offset + 1;
            },
        };
    }

    /// Expecting `ref` to be a `usize` or `[*]u8`.
    pub fn lineOfInstr(self: *Self, ref: anytype) usize {
        const T = @TypeOf(ref);
        return switch (@typeInfo(T)) {
            .Int => self.instr_locs.getLineFromOffset(ref),
            .Pointer => self.instr_locs.getLineFromOffset(self.offsetOfAddr(ref)),
            else => @compileError("invalid type of `ref` parameter: " ++ @typeName(T)),
        };
    }

    /// Given its address, return the offset of an instruction.
    pub inline fn offsetOfAddr(self: Self, instruct_addr: [*]const u8) usize {
        return @ptrToInt(instruct_addr) - @ptrToInt(self.code.elems.ptr);
    }

    /// Populate a test chunk with instructions and constants. Everything is written to the chunk at
    /// the same line number.
    pub fn fill(self: *Self, contents: anytype) !void {
        inline for (std.meta.fields(@TypeOf(contents))) |field| {
            // Expecting `item` to be a `Value`, `OpCode`, `u16`, or `u8`.
            const item = @field(contents, field.name);
            try self.write(item, 1);
        }
    }

    /// Compare the instructions and constants of two chunks for equality.
    pub fn testingExpectEqual(expected: *Self, actual: *Self) !void {
        try testing.expectEqualSlices(u8, expected.code.elems, actual.code.elems);
        const expected_constants = expected.data.elems;
        const actual_constants = actual.data.elems;
        if (expected_constants.len != actual_constants.len) {
            std.debug.print("number of constants in chunk differ. expected {d}, found {d}\n", .{
                expected_constants.len,
                actual_constants.len,
            });
            return error.TestExpectedEqual;
        }
        var i: usize = 0;
        while (i < expected_constants.len) : (i += 1) {
            expected_constants[i].testingExpectEqual(actual_constants[i]) catch {
                std.debug.print("constant at index {} incorrect\n", .{i});
                return error.testingExpectEqual;
            };
        }
    }

    test "disassemble" {
        var list = std.ArrayList(u8).init(testing.allocator);
        var self = init(testing.allocator);
        defer self.deinit();
        defer list.deinit();

        try self.write(Value.init(1.2), 1);
        try self.write(Value.init(3.4), 1);
        try self.write(.add, 1);
        try self.write(Value.init(2), 1);
        try self.write(.div, 1);
        try self.write(.neg, 1);
        try self.write(.ret, 2);
        try self.write(.ret, 3);
        try self.disassemble(list.writer(), "test");
        const expect =
            \\== test ==
            \\0000    1 constant 0 '1.2'
            \\0002    | constant 1 '3.4'
            \\0004    | add
            \\0005    | constant 2 '2'
            \\0007    | div
            \\0008    | neg
            \\0009    2 ret
            \\0010    3 ret
            \\
        ;
        try testing.expectEqualStrings(expect, list.items);
    }

    test "chunk requiring u16 constant indices" {
        var self = init(testing.allocator);
        defer self.deinit();

        var i: usize = 0;
        while (i <= std.math.maxInt(u8)) : (i += 1) {
            try self.write(Value.init(0), 1);
        }
        try self.write(Value.init(1), 1);
        try testing.expectEqualSlices(
            u8,
            self.code.elems[self.code.elems.len - 3 ..],
            &.{ @enumToInt(OpCode.constant_long), 0, 1 },
        );
    }
};

const LocationInfo = struct {
    const Self = @This();
    // A compressed list of (bytecode offset increment, line number increment) pairs. For each
    // instruction that begins a new line, the difference in offset and line number from the
    // instruction that began the previous line are appended to the list. If either increment is
    // greater than 255, pairs of the form (255, 0) or (0, 255) are appended until the remaining
    // increment can fit in a u8. This method is adopted from how Python tracks line
    // information in its bytecode representation.
    line_tbl: DynamicArray(u8),
    line: usize = 0,
    bytecode_offset: usize = 0,
    lower_bound: usize = 0, // The offset of the instruction that starts the current line.
    upper_bound: usize = 0, // The offset of the instruction that starts the next line.

    fn init(alloc: Allocator) Self {
        return .{ .line_tbl = DynamicArray(u8).init(alloc) };
    }

    fn deinit(self: Self) void {
        self.line_tbl.deinit();
    }

    /// Associate each bytecode offset with a source code line number.
    fn update(self: *Self, cur_line: usize) !void {
        if (cur_line > self.line) {
            var cur_bytecode_offset: usize =
                @fieldParentPtr(Chunk, "instr_locs", self).code.elems.len - 1;
            var bytecode_incr: usize = cur_bytecode_offset - self.bytecode_offset;
            var line_incr: usize = cur_line - self.line;
            self.line = cur_line;
            self.bytecode_offset = cur_bytecode_offset;
            while (bytecode_incr > 255) : (bytecode_incr -= 255) {
                try self.line_tbl.append(255);
                try self.line_tbl.append(0);
            }
            while (line_incr > 255) : (line_incr -= 255) {
                try self.line_tbl.append(0);
                try self.line_tbl.append(255);
            }
            try self.line_tbl.append(@truncate(u8, bytecode_incr));
            try self.line_tbl.append(@truncate(u8, line_incr));
        }
    }

    /// Avoid calling `getLineFromOffset` for each instruction by first checking if the
    /// instruction's offset is on the same line as the previous instruction.
    fn onSameLine(self: Self, instruct_offset: usize) bool {
        return (self.lower_bound <= instruct_offset and instruct_offset < self.upper_bound);
    }

    /// Given the offset of an instruction, return its line number.
    fn getLineFromOffset(self: *Self, instruct_offset: usize) usize {
        var offset: usize = 0;
        var prev_offset: usize = 0;
        var line: usize = 0;
        {
            var i: usize = 0;
            var j: usize = 1;
            while (j < self.line_tbl.elems.len) : ({
                i += 2;
                j += 2;
            }) {
                prev_offset = offset;
                offset += self.line_tbl.elems[i];
                if (offset > instruct_offset) {
                    self.lower_bound = prev_offset;
                    self.upper_bound = offset;
                    return line;
                }
                line += self.line_tbl.elems[j];
            }
        }
        return line;
    }
};

test {
    testing.refAllDecls(@This());
}
