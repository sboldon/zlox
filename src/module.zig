const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const DynamicArray = @import("dynamic_array.zig").DynamicArray;
const Context = @import("Context.zig");
const compile = @import("compile.zig");
const Chunk = @import("bytecode.zig").Chunk;
const Token = @import("Token.zig");

const Self = @This();

gpa: Allocator,
dir: std.fs.Dir,
sub_path: []const u8 = undefined,
source_code: [:0]const u8 = undefined,
source_loaded: bool = false,
is_toplevel: bool = false,
// bytecode_arena: std.heap.ArenaAllocator,
bytecode: DynamicArray(Chunk),

/// The index bounds [lo, hi) of a contiguous sequence of bytes in a file.
pub const Span = struct {
    lo: usize,
    hi: usize,

    pub fn ofPos(pos: usize) Span {
        return .{ .lo = pos, .hi = pos + 1 };
    }

    pub fn contents(self: Span, source: [:0]const u8) []const u8 {
        return source[self.lo..self.hi];
    }
};

pub const FileLocation = struct {
    line_no: usize,
    col_no: usize,

    pub fn ofSpan(span: Span, source: [:0]const u8) !FileLocation {
        var num_lines: usize = 0;
        var idx_of_nearest_line_start: usize = 0;
        for (source) |char, idx| {
            if (char == '\n') {
                num_lines += 1;
                idx_of_nearest_line_start = idx + 1;
            }
            if (idx == span.lo) {
                return FileLocation{
                    .line_no = num_lines + 1,
                    .col_no = span.lo - idx_of_nearest_line_start + 1,
                };
            }
        } else {
            return if (span.lo != 0)
                error.InvalidSpan
            else
                FileLocation{ .line_no = 0, .col_no = 0 };
        }
        return error.InvalidSpan;
    }

    test "creating from `Span`" {
        // Empty file
        {
            const source = "";
            const span = Span.ofPos(0);
            const expected = FileLocation{ .line_no = 0, .col_no = 0 };
            try testing.expectEqual(expected, try FileLocation.ofSpan(span, source));
        }
        // Single line file
        {
            const source = "var x = 2;";
            const span = Span.ofPos(4); // At 'x'.
            const expected = FileLocation{ .line_no = 1, .col_no = 5 };
            try testing.expectEqual(expected, try FileLocation.ofSpan(span, source));
        }
        // Multi-line file
        {
            const source =
                \\var x = 2;
                \\print x + 1;
            ;
            const span = Span.ofPos(22); // At ';' on second line.
            const expected = FileLocation{ .line_no = 2, .col_no = 12 };
            try testing.expectEqual(expected, try FileLocation.ofSpan(span, source));
        }
    }
};

pub fn init(gpa: Allocator, dir: std.fs.Dir) Self {
    return .{
        .gpa = gpa,
        .dir = dir,
        .bytecode = DynamicArray(Chunk).init(gpa),
    };
}

pub fn deinit(self: *Self) void {
    if (!self.is_toplevel) {
        // self.gpa.free(self.sub_path);
        self.gpa.free(self.source_code);
    }
    for (self.bytecode.elems) |*chunk| {
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
    if (bytes_read != size) return error.UnexpectedEndOfFile;

    self.source_loaded = true;
    self.source_code = source_code;
    self.sub_path = sub_path;
}

/// The returned pointer may be invalidated after additional calls to this function due to resizing
/// of the chunk array.
pub fn newChunk(self: *Self) error{OutOfMemory}!*Chunk {
    try self.bytecode.append(Chunk.init(self.gpa));
    return self.bytecode.end();
}

test {
    testing.refAllDecls(Self);
}
