const std = @import("std");
const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;

const Module = @import("module.zig").Module;

const Self = @This();

gpa: Allocator,
main_module: Module,
root_src_dir: Dir,
/// Determines if errors are reported in color.
tty_config: std.debug.TTY.Config,

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
    };
}

pub fn deinit(self: *Self) void {
    self.main_module.deinit();
}
