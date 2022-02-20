const std = @import("std");
// const DynamicArray = @import("dynamic_array.zig").DynamicArray;
const Chunk = @import("bytecode.zig").Chunk;
const VirtMach = @import("virt_mach.zig").VirtMach;

const stdOutWriter = std.io.getStdOut().writer();

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var vm = VirtMach(stdOutWriter).init();
    var chunk = Chunk.init(allocator);
    defer {
        // vm.deinit();
        chunk.deinit();
    }

    try chunk.writeOpCode(.constant, 1);
    try chunk.write(try chunk.addConstant(.{ .num = 5 }), 1);
    try chunk.writeOpCode(.ret, 2);
    // try chunk.disassemble(stdOutWriter, "test");
    try vm.interpret(&chunk);
}

test "suite" {
    _ = @import("dynamic_array.zig");
    _ = @import("bytecode.zig");
    _ = @import("virt_mach.zig");
}
