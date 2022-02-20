const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// A custom implementation of the standard library's ArrayList type for the purpose of learning how
/// allocators and generic types work in Zig.
pub fn DynamicArray(comptime T: type) type {
    return struct {
        const Self = @This();

        elems: []T,
        capacity: usize,
        allocator: Allocator,

        pub fn init(alloc: Allocator) Self {
            return .{
                .elems = &[_]T{}, // Slice of an empty array.
                .capacity = 0,
                .allocator = alloc,
            };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.elems.ptr[0..self.capacity]);
        }

        pub fn append(self: *Self, elem: T) !void {
            const new_len: usize = self.elems.len + 1;
            try self.verifyCapacity(new_len);
            self.elems.ptr[self.elems.len] = elem;
            self.elems.len = new_len;
        }

        pub fn appendSlice(self: *Self, slice: []const T) !void {
            const len = self.elems.len;
            const new_len = len + slice.len;
            try self.verifyCapacity(new_len);
            self.elems.len = new_len;
            std.mem.copy(T, self.elems[len..], slice);
        }

        /// A pointer to the last item in the array. The pointer may become invalid if it is still
        /// held after a call to an `append*` function.
        pub fn end(self: Self) *T {
            return &self.elems[self.elems.len - 1];
        }

        fn verifyCapacity(self: *Self, new_len: usize) !void {
            if (new_len >= self.capacity) {
                // Double the size of the backing array every time it fills up.
                var new_cap = if (self.capacity < 8) 8 else self.capacity * 2;
                while (new_len >= new_cap) : (new_cap *= 2) {}
                try self.grow(new_cap);
            }
        }

        fn grow(self: *Self, capacity: usize) !void {
            const resized_mem = try self.allocator.realloc(self.elems, capacity);
            self.elems.ptr = resized_mem.ptr;
            self.capacity = capacity;
        }
    };
}

test "init" {
    const arr = DynamicArray(u8).init(testing.allocator);
    defer arr.deinit();
    try testing.expect(arr.elems.len == 0);
    try testing.expect(arr.capacity == 0);
}

test "append" {
    var arr = DynamicArray(u8).init(testing.allocator);
    defer arr.deinit();
    try arr.append('c');
    try testing.expect(arr.elems.len == 1);
    try testing.expect(arr.elems[0] == 'c');
}

test "appendSlice" {
    var arr = DynamicArray(u8).init(testing.allocator);
    defer arr.deinit();
    const str: []const u8 = "Hello World!";
    try arr.appendSlice(str);
    try testing.expect(std.mem.eql(u8, arr.elems, str));
}

test "end" {
    var arr = DynamicArray(u8).init(testing.allocator);
    defer arr.deinit();
    const str: []const u8 = "Hello World!";
    try arr.appendSlice(str);
    try testing.expect(str[11] == arr.end().*);
}
