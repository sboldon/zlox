const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Dir = std.fs.Dir;

const DynamicArray = @import("dynamic_array.zig").DynamicArray;
const Context = @import("Context.zig");
const compile = @import("compile.zig");
const Chunk = @import("bytecode.zig").Chunk;
const Token = @import("Token.zig");

pub const Module = struct {
    const Self = @This();

    gpa: Allocator,

    dir: Dir,
    /// If no file name is provided, the module is the top-level environment of a REPL session.
    sub_path: ?[]const u8 = null,
    source_code: [:0]const u8 = undefined,
    source_loaded: bool = false,
    is_toplevel: bool = false,

    // bytecode_arena: std.heap.ArenaAllocator,
    bytecode: DynamicArray(Chunk),

    pub fn init(gpa: Allocator, dir: Dir) Self {
        return .{
            .gpa = gpa,
            .dir = dir,
            .bytecode = DynamicArray(Chunk).init(gpa),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.sub_path) |path| {
            self.gpa.free(path);
            self.gpa.free(self.source_code);
        }
        for (self.bytecode.toSlice()) |*chunk| {
            // TODO: This freeing can be done all at once using an arena once the data structure
            // containing multiple chunks has been finalized. Using a dynamic array is temporary.
            chunk.deinit();
        }
        self.bytecode.deinit();
    }

    pub fn loadFile(self: *Self, sub_path: []const u8) !void {
        const file = try self.dir.openFile(sub_path, .{});
        defer file.close();

        const size: usize = try file.getEndPos();
        const source_code = try self.gpa.allocSentinel(u8, size, 0);
        defer if (!self.source_loaded) self.gpa.free(source_code);

        const bytes_read = try file.readAll(source_code);
        if (bytes_read != size)
            return error.UnexpectedEndOfFile;

        self.source_loaded = true;
        self.source_code = source_code;
        self.sub_path = try self.gpa.dupe(u8, sub_path);
    }

    /// The returned pointer may be invalidated after additional invocations.
    pub fn newChunk(self: *Self) error{OutOfMemory}!*Chunk {
        try self.bytecode.append(Chunk.init(self.gpa));
        return self.bytecode.end();
    }
};
