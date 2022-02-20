const std = @import("std");
const build_options = @import("build_options");
const bytecode = @import("bytecode.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Chunk = bytecode.Chunk;
const OpCode = bytecode.OpCode;
const Value = bytecode.Value;

pub fn VirtMach(comptime writer: anytype) type {
    return struct {
        const Self = @This();

        const InterpretError = error{
            CompileError,
            RuntimeError,
            OutOfMemory,
        };

        writer: @TypeOf(writer) = writer,
        chunk: *Chunk = undefined,
        // ip: [*]u8 = undefined,

        pub fn init() Self {
            return .{};
        }

        // pub fn deinit(self: Self) void {}

        pub fn interpret(self: *Self, chunk: *Chunk) !void {
            self.chunk = chunk;
            // self.ip = self.chunk.code.elems.ptr;
            return self.run();
        }

        // TODO: Rewrite bytecode dispatch using a direct threaded approach once the accepted proposal
        // for labeled continue syntax inside a switch expression is implemented.
        fn run(self: *Self) !void {
            var ip: [*]u8 = self.chunk.code.elems.ptr;
            var instruction: OpCode = undefined;
            while (true) {
                if (comptime build_options.tracing_enabled) {
                    _ = try self.chunk.disassembleInstr(writer, self.chunk.offsetOfAddr(ip));
                }
                instruction = @intToEnum(OpCode, readByte(&ip));
                switch (instruction) {
                    .ret => return,
                    .constant => {
                        try writer.print("{}\n", .{self.readConstant(&ip)});
                        break;
                    },
                    else => return InterpretError.CompileError,
                }
            }
        }

        // TODO: Check generated code to see if inlining removes superfluous deref of ip. If it does
        // not, then there does not appear to much of a benefit to having the instruction pointer as an
        // local variable instead of as a member of VirtMach.
        inline fn readByte(ip: *[*]u8) u8 {
            const byte = ip.*[0];
            ip.* += 1;
            return byte;
        }

        inline fn readConstant(self: Self, ip: *[*]u8) Value {
            return self.chunk.data.elems[readByte(ip)];
        }
    };
}
