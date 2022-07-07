const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Value = @import("value.zig").Value;

/// A custom implementation of the standard library's `ArrayList` type for the purpose of learning how
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
            self.allocator.free(self.allocatedSlice());
        }

        pub fn append(self: *Self, elem: T) !void {
            const new_len = self.elems.len + 1;
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

        /// The pointer may be bcome invalid if it is used after additional elements have been
        /// appended.
        pub fn end(self: Self) *T {
            return &self.elems[self.elems.len - 1];
        }

        /// Clear the array while maintaing its capacity.
        pub fn clear(self: *Self) void {
            self.elems.len = 0;
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
            const resized_mem = try self.allocator.realloc(self.allocatedSlice(), capacity);
            self.elems.ptr = resized_mem.ptr;
            self.capacity = capacity;
        }

        fn allocatedSlice(self: Self) []T {
            return self.elems.ptr[0..self.capacity];
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
    try testing.expectEqual(@as(usize, 1), arr.elems.len);
    try testing.expectEqual(@as(u8, 'c'), arr.elems[0]);
}

test "appendSlice" {
    var arr = DynamicArray(u8).init(testing.allocator);
    defer arr.deinit();
    const expect: []const u8 = "Hello World!";
    try arr.appendSlice(expect);
    try testing.expectEqualStrings(expect, arr.elems);
}
