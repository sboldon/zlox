const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const DynamicArray = @import("dynamic_array.zig").DynamicArray;
const value = @import("value.zig");
const Value = value.Value;
const ValueType = value.ValueType;

// Underscore denotes an open enum meaning that @intToEnum on an int not in the enum can be matched against
// with '_' in switch statements.
pub const OpCode = enum(u8) {
    constant, // 2 byte instruction; opcode is followed by an index into the data section of a chunk.
    ret,
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
    _,
};

pub fn validOperandTypes(comptime op: OpCode) value.TypeSet {
    const numTypeSet = value.numTypeSet;
    return switch (op) {
        .add => numTypeSet, // Eventually will be valid for strings as well.
        .sub, .mul, .div => numTypeSet,
        .gt, .ge, .lt, .le => numTypeSet, // Should these be supported for strings?
        else => @compileError("invalid opcode: " ++ @tagName(op)),
    };
}

pub fn opCodeLexeme(comptime op: OpCode) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .gt => ">",
        .ge => ">=",
        .lt => "<",
        .le => "<=",
        else => @compileError("invalid opcode: " ++ @tagName(op)),
    };
}

/// A sequence of bytecode instructions and associated constant data.
pub const Chunk = struct {
    const Self = @This();
    code: DynamicArray(u8),
    data: DynamicArray(Value),
    line_info: LineInfo,

    pub fn init(alloc: Allocator) Self {
        return .{
            .code = DynamicArray(u8).init(alloc),
            .data = DynamicArray(Value).init(alloc),
            .line_info = LineInfo.init(alloc),
        };
    }

    pub fn deinit(self: Self) void {
        self.code.deinit();
        self.data.deinit();
        self.line_info.deinit();
    }

    /// Add an instruction or constant to the chunk. Expecting `item` to be a `Value`, `OpCode`, or `u8`.
    pub fn write(self: *Self, item: anytype, line: usize) !void {
        const T = @TypeOf(item);
        if (T == Value) {
            try self.writeByte(@enumToInt(OpCode.constant), line);
            try self.writeByte(try self.addConstant(item), line);
        } else if (T == @Type(.EnumLiteral) or T == OpCode) {
            try self.writeByte(@enumToInt(@as(OpCode, item)), line);
        } else {
            // Expecting `T` to be u8.
            try self.writeByte(item, line);
        }
    }

    fn writeByte(self: *Self, byte: u8, line: usize) !void {
        try self.code.append(byte);
        try self.line_info.update(line);
    }

    /// Add a constant to the data section of the chunk and return the index that it is stored at.
    fn addConstant(self: *Self, val: Value) !u8 {
        const index = self.data.elems.len;
        if (index > 255) {
            // TODO: Support a greater number of constants by adding new opcode with 2 two byte
            // indices.
            std.debug.panic(
                "Attempted to add a constant to a full chunk. Currently only 256 constants can " ++
                    "fit in a chunk because `OpCode.constant` uses a single byte to store the " ++
                    "index of a constant.\n ",
                .{},
            );
        }
        try self.data.append(val);
        return @truncate(u8, index);
    }

    /// Display the contents of the chunk using the writer provided.
    pub fn disassemble(self: *Self, writer: anytype, chunk_name: []const u8) !void {
        std.debug.assert(self.line_info.line_tbl.elems.len >= 2);
        try writer.print("== {s} ==\n", .{chunk_name});
        var i: usize = 0;
        while (i < self.code.elems.len) : (i = try self.disassembleInstr(writer, i)) {}
        self.line_info.lower_bound = 0;
        self.line_info.upper_bound = 0;
    }

    pub fn disassembleInstr(self: *Self, writer: anytype, offset: usize) !usize {
        const op = @intToEnum(OpCode, self.code.elems[offset]);
        try writer.print("{:0>4} ", .{offset});
        if (self.line_info.onSameLine(offset)) {
            try writer.print("   | ", .{});
        } else {
            try writer.print("{: >4} ", .{self.lineOfInstr(offset)});
        }
        try writer.print("{s}", .{@tagName(op)});
        return switch (op) {
            .constant => blk: {
                // Display the index and value of the constant.
                const i: u8 = self.code.elems[offset + 1];
                try writer.print(" {} '{}'\n", .{ i, self.data.elems[i] });
                break :blk offset + 2;
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
            .Int => self.line_info.getLineFromOffset(ref),
            .Pointer => self.line_info.getLineFromOffset(self.offsetOfAddr(ref)),
            else => @compileError(
                "invalid type for `ref` argument of `Chunk.lineOfInstr` function: " ++
                    @typeName(T),
            ),
        };
    }

    /// Given its address, return the offset of an instruction.
    pub inline fn offsetOfAddr(self: Self, instruct_addr: [*]const u8) usize {
        return @ptrToInt(instruct_addr) - @ptrToInt(self.code.elems.ptr);
    }

    /// Populate a test chunk with instructions and constants. Everything is written to the chunk at
    /// the same line number.
    pub fn fill(self: *Self, comptime contents: anytype) !void {
        inline for (contents) |item| {
            try self.write(item, 1);
        }
    }

    /// Compare the instructions and constants of two chunks for equality.
    pub fn expectEqual(expected: *Self, actual: *Self) !void {
        try testing.expectEqualSlices(u8, expected.code.toSlice(), actual.code.toSlice());
        try testing.expectEqualSlices(Value, expected.data.toSlice(), actual.data.toSlice());
    }

    test "disassemble" {
        var list = std.ArrayList(u8).init(testing.allocator);
        var chunk = Chunk.init(testing.allocator);
        defer list.deinit();
        defer chunk.deinit();

        try chunk.write(Value.init(1.2), 1);
        try chunk.write(Value.init(3.4), 1);
        try chunk.write(.add, 1);
        try chunk.write(Value.init(2), 1);
        try chunk.write(.div, 1);
        try chunk.write(.neg, 1);
        try chunk.write(.ret, 2);
        try chunk.write(.ret, 3);
        try chunk.disassemble(list.writer(), "test chunk");
        var expect =
            \\== test chunk ==
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
};

const LineInfo = struct {
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
                @fieldParentPtr(Chunk, "line_info", self).code.elems.len - 1;
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

    /// Avoid calling getLineFromOffset for each instruction by first checking if the instruction's offset is on the
    /// same line as the previous instruction.
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
