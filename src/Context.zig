const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;

const Module = @import("module.zig").Module;
const Obj = @import("object.zig").Obj;

const Self = @This();

gpa: Allocator,
main_module: Module,
root_src_dir: Dir,
/// Determines if errors are reported in color.
tty_config: std.debug.TTY.Config,
/// Head of list of all allocated objects.
objs: ?*Obj,

pub const Options = struct {
    /// A null value indicates lox has been started in REPL mode.
    main_file_path: ?[]const u8,
};

pub fn init(gpa: Allocator, config: Options) !Self {
    const cwd = std.fs.cwd();
    var module = Module.init(gpa, cwd);

    if (config.main_file_path) |path| {
        try module.loadFile(path);
    } else {
        module.is_toplevel = true;
    }

    return Self{
        .gpa = gpa,
        .main_module = module,
        .root_src_dir = cwd,
        .tty_config = std.debug.detectTTYConfig(),
        .objs = null,
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
}

pub fn trackObj(self: *Self, obj: *Obj) void {
    obj.next = self.objs;
    self.objs = obj;
}
