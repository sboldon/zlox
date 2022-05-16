const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const HashedString = @import("interning.zig").HashedString;

pub const ObjType = enum(u8) {
    const Self = @This();

    string,

    // /// The object corresponding to the active enum tag.
    // pub fn Obj(comptime self: Self) type {
    //     return switch (self) {
    //         .string => StringObj,
    //     };
    // }

    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        try std.fmt.formatBuf(@tagName(self), options, writer);
    }
};

pub const Obj = extern struct {
    const Self = @This();

    @"type": ObjType,
    next: ?*Self = null,

    pub fn init(@"type": ObjType) Self {
        return .{ .@"type" = @"type" };
    }

    /// Undefined behavior if `self.type` is not `string`. Expecting `self` to be either `*Obj` or
    /// `*const Obj`.
    pub fn asString(self: anytype) CopyPtrConst(@TypeOf(self), *StringObj) {
        const T = CopyPtrConst(@TypeOf(self), *StringObj);
        return self.ptrCast(T);
    }

    pub fn format(
        self: *const Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self.type) {
            .string => {
                try std.fmt.formatType(self.asString(), fmt, options, writer, std.fmt.default_max_depth);
            },
        }
    }

    /// Undefined behavior if `T` is not the corresponding object type of `self.type`. Expecting
    /// `self` to be either `*Obj` or `*const Obj`.
    fn ptrCast(self: anytype, comptime T: type) T {
        return @ptrCast(T, @alignCast(@alignOf(T), self));
    }

    pub fn testingExpectEqual(self: *const Self, other: *const Self) !void {
        return if (self.type != other.type) error.TestExpectedEqual else switch (self.type) {
            .string => self.asString().testingExpectEqual(other.asString()),
        };
    }
};

pub const StringObj = extern struct {
    const Self = @This();

    const String = extern union {
        owned: [1]u8, // Emulating a C flexible array member.
        ref: [*]const u8,
    };

    obj: Obj,
    hash: u64,
    owner: bool,
    len: usize,
    contents: String,

    /// Create a `StringObj` that does not own the bytes of its string.
    pub fn create(gpa: Allocator, slice: []const u8) !*Self {
        const self = try gpa.create(Self);
        self.* = init(slice);
        return self;
    }

    pub fn createWithHash(gpa: Allocator, string: HashedString) !*Self {
        const self = try gpa.create(Self);
        self.* = initWithHash(string);
        return self;
    }

    pub fn init(slice: []const u8) Self {
        return initWithHash(HashedString.init(slice));
    }

    pub fn initWithHash(string: HashedString) Self {
        return .{
            .obj = Obj.init(.string),
            .owner = false,
            .hash = string.hash,
            .len = string.slice.len,
            .contents = .{ .ref = string.slice.ptr },
        };
    }

    // TODO: Determine the necessity of this function. Can all use cases be handled by `create` and
    // `concat`?
    /// Create a `StringObj` by copying the bytes of `slice[0..]`.
    pub fn createOwned(gpa: Allocator, slice: []const u8) !*Self {
        // Ensure that at least `@sizeOf(Self)` bytes are allocated.
        const flexible_array_len = std.math.max(slice.len, @bitSizeOf([*]const u8));
        var self = @ptrCast(
            *Self,
            try gpa.alignedAlloc(
                u8,
                @alignOf(Self),
                @offsetOf(Self, "contents") + flexible_array_len,
            ),
        );
        self.obj = Obj.init(.string);
        self.hash = std.hash_map.hashString(slice);
        self.owner = true;
        self.len = slice.len;
        std.mem.copy(u8, @as([*]u8, &self.contents.owned)[0..self.len], slice);
        return self;
    }

    /// Create a `StringObj` by copying the bytes of `lhs` and `rhs`.
    pub fn concat(gpa: Allocator, lhs: *const Self, rhs: *const Self) !*Self {
        const str_len = lhs.len + rhs.len;
        const flexible_array_len = std.math.max(str_len, @bitSizeOf([*]const u8));
        var self = @ptrCast(
            *Self,
            try gpa.alignedAlloc(
                u8,
                @alignOf(Self),
                @offsetOf(Self, "contents") + flexible_array_len,
            ),
        );
        self.obj = Obj.init(.string);
        self.owner = true;
        self.len = str_len;
        const char_array = @as([*]u8, &self.contents.owned);
        std.mem.copy(u8, char_array[0..self.len], lhs.bytes());
        std.mem.copy(u8, char_array[lhs.len..self.len], rhs.bytes());
        self.hash = std.hash_map.hashString(self.bytes());
        return self;
    }

    pub fn bytes(self: *const Self) []const u8 {
        const ptr: [*]const u8 = if (self.owner) &self.contents.owned else self.contents.ref;
        return ptr[0..self.len];
    }

    // Cast is allowed because `Obj` and `Self` conform to C ABI.
    pub fn asObj(self: anytype) CopyPtrConst(@TypeOf(self), *Obj) {
        const T = CopyPtrConst(@TypeOf(self), *Obj);
        return @ptrCast(T, self);
    }

    pub fn format(
        self: *const Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try std.fmt.formatType(
            self.bytes(),
            if (fmt.len == 0) "s" else fmt,
            options,
            writer,
            std.fmt.default_max_depth,
        );
    }

    pub fn testingExpectEqual(self: *const Self, other: *const Self) !void {
        try testing.expectEqualStrings(self.bytes(), other.bytes());
    }

    test "creation" {
        const s1 = StringObj.init("hello world");
        try testing.expectEqualStrings("hello world", s1.bytes());

        const s2 = try StringObj.createOwned(testing.allocator, "lorem ipsum");
        defer testing.allocator.destroy(s2);
        try testing.expectEqualStrings("lorem ipsum", s2.bytes());

        const s3 = try StringObj.concat(testing.allocator, &s1, s2);
        defer testing.allocator.destroy(s3);
        try testing.expectEqualStrings("hello worldlorem ipsum", s3.bytes());
    }

    test "format" {
        const chars = "hello world";
        const str_obj = StringObj.init(chars);
        try testing.expectFmt(chars, "{}", .{str_obj.asObj()});
    }
};

/// A pointer type with its constness determined by the constness of `source`. Expecting both
/// `source` and `result` to be pointer types.
fn CopyPtrConst(comptime source: type, comptime result: type) type {
    comptime var info = @typeInfo(result);
    if (@typeInfo(source).Pointer.is_const) {
        info.Pointer.is_const = true;
    }
    return @Type(info);
}

test {
    testing.refAllDecls(@This());
}
