const std = @import("std");

const bytecode = @import("bytecode.zig");
const Chunk = bytecode.Chunk;
const Value = @import("value.zig").Value;
const VirtMach = @import("virt_mach.zig").VirtMach;

pub fn main() anyerror!void {
    const stdout = std.io.getStdOut();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var vm = VirtMach(std.fs.File.Writer){};
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();

    vm.init(stdout.writer());
    try chunk.writeOpCode(.constant, 1);
    try chunk.write(try chunk.addConstant(Value.init(true)), 1);
    try chunk.writeOpCode(.neg, 1);
    try chunk.writeOpCode(.ret, 1);
    try vm.interpret(&chunk);
}

test "suite" {
    _ = @import("dynamic_array.zig");
    _ = @import("bytecode.zig");
    _ = @import("virt_mach.zig");
}
