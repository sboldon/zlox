const std = @import("std");
const DynamicArray = @import("dynamic_array.zig").DynamicArray;

const print = std.io.getStdOut().writer().print;
const gpa = std.heap.GeneralPurposeAllocator(.{}){};
const alloc = gpa.allocator();

const VirtMach = struct {
    const Self = @This();

    const InterpretError = error{
        CompileError,
        RuntimeError,
        OutOfMemory,
    };

    // pub fn interpret(self: *Self, chunk: *Chunk) InterpretError!void {

    // }
};

// const instructions = DynamicArray(OpCode).init(alloc);

pub fn main() anyerror!void {
    std.log.info("All your codebase are belong to us.", .{});
}

test "suite" {
    _ = @import("dynamic_array.zig");
    _ = @import("chunk.zig");
}
