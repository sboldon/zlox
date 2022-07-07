const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;

const Module = @import("Module.zig");
const Obj = @import("object.zig").Obj;
const StringObj = @import("object.zig").StringObj;
const StringPool = @import("interning.zig").StringPool;
const HashedString = @import("interning.zig").HashedString;

const Self = @This();

gpa: Allocator,
main_module: Module,
root_src_dir: Dir,
/// Determines if errors are reported in color.
tty_config: std.debug.TTY.Config,
/// Head of the list of all dynamically allocated Lox objects.
objs: ?*Obj,
/// Set of interned strings.
string_pool: StringPool,
// The method used to construct a `StringObj` is selected at runtime based on whether or not the
// interpreter is running in interactive mode.
createStringObj: fn (Allocator, HashedString) error{OutOfMemory}!*StringObj,

pub const Options = struct {
    /// A null value indicates interactive mode.
    main_file_path: ?[]const u8,
};

pub fn init(gpa: Allocator, config: Options) !Self {
    const cwd = std.fs.cwd();
    var module = Module.init(gpa, cwd);

    var createStringObj: fn (Allocator, HashedString) error{OutOfMemory}!*StringObj = undefined;
    if (config.main_file_path) |path| {
        try module.loadFile(path);
        createStringObj = StringObj.createWithHash;
    } else {
        module.is_toplevel = true;
        module.sub_path = "stdin";
        // Each string must own its bytes because source code slices are invalidated everytime a new
        // command is entered in the REPL.
        createStringObj = StringObj.createOwned;
    }

    return Self{
        .gpa = gpa,
        .main_module = module,
        .root_src_dir = cwd,
        .tty_config = std.debug.detectTTYConfig(),
        .objs = null,
        .string_pool = StringPool.init(),
        .createStringObj = createStringObj,
    };
}

pub fn deinit(self: *Self) void {
    // TODO: Implicitly assuming objs were allocated with `self.gpa`. Can this be compile time
    // enforced?
    var iter = self.objs;
    while (iter) |cur_obj| {
        iter = cur_obj.next;
        self.gpa.destroy(cur_obj); // TODO: Does this properly free all mem from just an `Obj` pointer?
    }
    self.main_module.deinit();
    self.string_pool.deinit(self.gpa);
}

pub fn trackObj(self: *Self, obj: *Obj) void {
    obj.next = self.objs;
    self.objs = obj;
}

/// Return an existing `StringObj` if `slice` has already been interned, otherwise create and intern
/// a new `StringObj`.
pub fn createString(self: *Self, slice: []const u8) !*StringObj {
    const string = HashedString.init(slice);
    var pool_entry = try self.string_pool.findEntry(self.gpa, string);
    if (!pool_entry.found_existing) {
        const string_obj = try self.createStringObj(self.gpa, string);
        self.trackObj(string_obj.asObj());
        pool_entry.key_ptr.* = string_obj;
        return string_obj;
    }
    return pool_entry.key_ptr.*;
}

// TODO: How likely is it that a concatenated string will already be in the string pool? If not very
// likely this just seems like it will slow down all concats for an edge case. However, concatted
// strings must be interned to enforce the property that strings can be compared via pointer
// equality.
pub fn concatStrings(self: *Self, lhs: *const StringObj, rhs: *const StringObj) !*StringObj {
    const string_obj = try StringObj.concat(self.gpa, lhs, rhs);
    var pool_entry = try self.string_pool.findEntry(self.gpa, string_obj);
    if (!pool_entry.found_existing) {
        self.trackObj(string_obj.asObj());
        pool_entry.key_ptr.* = string_obj;
        return string_obj;
    }
    // TODO: Instead of freeing immediately, is it faster to just append to list of objects for freeing
    // later in GC?
    self.gpa.destroy(string_obj);
    return pool_entry.key_ptr.*;
}

test "string interning" {
    var self = try init(testing.allocator, .{ .main_file_path = null });
    defer self.deinit();
    const s1 = try self.createString("hello world");
    const s2 = try self.createString("hello world");
    // var iter = self.string_pool.strings.keyIterator();
    // while (iter.next()) |key| {
    //     std.debug.print("-- '{}'\n", .{key.*});
    // }
    try testing.expectEqual(s1, s2);
}

test "concat with string interning" {
    var self = try init(testing.allocator, .{ .main_file_path = null });
    defer self.deinit();
    const s1 = try self.createString("hello world");
    const s2 = try self.createString("hello worldhello world");
    const s3 = try self.concatStrings(s1, s1);
    try testing.expectEqual(s2, s3);
}
