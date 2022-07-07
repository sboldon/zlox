const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const StringObj = @import("object.zig").StringObj;

pub fn InternedStringHashMap(comptime T: type) type {
    return std.HashMapUnmanaged(
        *StringObj,
        T,
        InternedStringContext,
        std.hash_map.default_max_load_percentage,
    );
}

pub const InternedStringContext = struct {
    pub fn hash(self: @This(), str_obj: *StringObj) u64 {
        _ = self;
        return str_obj.hash;
    }
    pub fn eql(self: @This(), a: *StringObj, b: *StringObj) bool {
        _ = self;
        return a == b;
    }
};

pub const HashedString = struct {
    slice: []const u8,
    hash: u64,

    pub fn init(slice: []const u8) HashedString {
        return .{
            .slice = slice,
            .hash = std.hash_map.hashString(slice),
        };
    }
};

pub const StringPool = struct {
    const Self = @This();

    strings: HashSet,

    const HashSet = std.HashMapUnmanaged(
        *StringObj,
        void,
        StringObjContext,
        std.hash_map.default_max_load_percentage,
    );

    const StringObjContext = struct {
        pub fn hash(self: @This(), str_obj: *StringObj) u64 {
            _ = self;
            return str_obj.hash;
        }
        pub fn eql(self: @This(), a: *StringObj, b: *StringObj) bool {
            _ = self;
            return a.len == b.len and std.mem.eql(u8, a.bytes(), b.bytes());
        }
    };

    /// Allow checking for the membership of a string in a `StringObj` hash map without having to create
    /// a new `StringObj`.
    const HashedStringAdapter = struct {
        pub fn hash(self: @This(), string: HashedString) u64 {
            _ = self;
            return string.hash;
        }
        pub fn eql(self: @This(), string: HashedString, key: *StringObj) bool {
            _ = self;
            return string.slice.len == key.len and std.mem.eql(u8, string.slice, key.bytes());
        }
    };

    pub fn init() Self {
        return .{ .strings = .{} };
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.strings.deinit(gpa);
    }

    /// Return an existing `StringObj` if `slice` has already been interned, otherwise create and
    /// intern a new `StringObj`.
    // pub fn findOrCreate(self: *Self, gpa: Allocator, slice: []const u8) !*StringObj {
    //     const string = HashedString.init(slice);
    //     var entry = try self.strings.getOrPutAdapted(gpa, string, HashedStringAdapter{});
    //     if (!entry.found_existing) {
    //         const string_obj = try StringObj.createWithHash(gpa, string);
    //         entry.key_ptr.* = string_obj;
    //         return string_obj;
    //     }
    //     return entry.key_ptr.*;
    // }

    /// Return the pool entry that `string` is stored at. If `string` is not in the pool, a new
    /// entry is created. Expecting `string` to be a `HashedString` or `*StringObj`.
    pub fn findEntry(
        self: *Self,
        gpa: Allocator,
        string: anytype,
    ) !HashSet.GetOrPutResult {
        const T = @TypeOf(string);
        return if (T == HashedString)
            self.strings.getOrPutAdapted(gpa, string, HashedStringAdapter{})
        else if (T == *StringObj)
            self.strings.getOrPut(gpa, string)
        else
            @compileError("invalid type of `string` parameter: " ++ @typeName(T));
    }
};
