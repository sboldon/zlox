const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const DynamicArray = @import("dynamic_array.zig").DynamicArray;

// pub const Instruction = union(enum) {
//     constant: u8, // The index of a constant stored in the data section of a chunk.
//     ret,
// };
//
pub const OpCode = enum(u8) {
    constant, // 2 byte instruction; opcode is followed by an index into the data section of a chunk.
    ret,
};

// Possible way of appending a slice
pub const Instruction = packed union {
    op: OpCode,
    data: u8,
};

pub const Value = f64;

/// A sequence of bytecode instructions and associated constant data.
pub const Chunk = struct {
    const Self = @This();

    code: DynamicArray(u8),
    data: DynamicArray(Value),

    pub fn init(alloc: Allocator) Self {
        return .{
            .code = DynamicArray(u8).init(alloc),
            .data = DynamicArray(Value).init(alloc),
        };
    }

    pub fn deinit(self: Self) void {
        self.code.deinit();
        self.data.deinit();
    }

    pub fn write(self: *Self, byte: u8) !void {
        try self.code.append(byte);
    }

    pub fn writeOpCode(self: *Self, op: OpCode) !void {
        try self.code.append(@enumToInt(op));
    }

    /// Add a constant to the data section of the chunk and return the index that it is stored at.
    pub fn addConstant(self: *Self, val: Value) !u8 {
        const index = @truncate(u8, self.data.elems.len);
        try self.data.append(val);
        return index;
    }

    // NOTE: This was written using a variant type to represent bytecode instructions. This means
    // that every instruction will have a size equal to the largest memeber in the union. With the
    // goal of minimizing the space needed to store instructions, I switched from an array of the
    // variant type to an array of bytes. I am keeping this around temporarily incase the raw byte
    // representation of instructions ends up not being nice to work with.
    /// Display the contents of the chunk using the provided Writer. TODO: Is it possible to specify
    /// the writer type in a more concrete way?
    // pub fn disassemble(self: Self, writer: anytype, chunk_name: []const u8) !void {
    //     var offset: usize = 0;
    //     try writer.print("== {s} ==\n", .{chunk_name});
    //     for (self.code.elems) |instruction| {
    //         try writer.print("{:0<4} {s}", .{ offset, @tagName(instruction) });
    //         switch (instruction) {
    //             .constant => |index| try writer.print(" {: <4} {}\n", .{ index, self.data.elems[index] }),
    //             else => try writer.print("\n", .{}),
    //         }
    //         offset += @sizeOf(@TypeOf(instruction));
    //     }
    // }

    /// Display the contents of the chunk using the provided Writer. TODO: Is it possible to specify
    /// the writer type in a more concrete way while still retaining as much flexibility in
    /// selecting the output stream?
    pub fn disassemble(self: Self, writer: anytype, chunk_name: []const u8) !void {
        try writer.print("== {s} ==\n", .{chunk_name});
        var i: usize = 0;
        while (i < self.code.elems.len) {
            i = try self.disassembleInstr(writer, i);
        }
    }

    fn disassembleInstr(self: Self, writer: anytype, offset: usize) !usize {
        const op = @intToEnum(OpCode, self.code.elems[offset]);
        try writer.print("{:0>4} {s}", .{ offset, @tagName(op) });
        return switch (op) {
            .constant => blk: {
                // Display the index and value of the constant.
                const i: u8 = self.code.elems[offset + 1];
                try writer.print(" {} '{d}'\n", .{ i, self.data.elems[i] });
                break :blk offset + 2;
            },
            // Single byte instructions.
            else => blk: {
                try writer.print("\n", .{});
                break :blk offset + 1;
            },
        };
    }
};

test "disassemble" {
    var list = std.ArrayList(u8).init(testing.allocator);
    var chunk = Chunk.init(testing.allocator);
    defer list.deinit();
    defer chunk.deinit();

    const const_idx = try chunk.addConstant(1.2);
    try chunk.writeOpCode(.ret);
    try chunk.writeOpCode(.constant);
    try chunk.write(const_idx);
    try chunk.writeOpCode(.ret);
    try chunk.disassemble(list.writer(), "test chunk");
    var expect =
        \\== test chunk ==
        \\0000 ret
        \\0001 constant 0 '1.2'
        \\0003 ret
        \\
    ;
    testing.expect(std.mem.eql(u8, expect, list.items)) catch |err| {
        std.log.err("\nexpected:\n{s}but found:\n{s}", .{ expect, list.items });
        return err;
    };
}
