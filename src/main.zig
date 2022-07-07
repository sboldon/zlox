const std = @import("std");
const Allocator = std.mem.Allocator;

const VirtMach = @import("virt_mach.zig").VirtMach;
const Context = @import("Context.zig");
const Module = @import("Module.zig");
const compile = @import("compile.zig");
const ReplCompilation = @import("compile.zig").ReplCompilation;
const bytecode = @import("bytecode.zig");
const Chunk = bytecode.Chunk;
const Value = @import("value.zig").Value;

pub const log_level: std.log.Level = .debug;

// Currently only supporting a source file name as the sole argument OR no arguments to invoke a
// REPL.
pub fn parseArgs(args: []const []u8) Context.Options {
    return switch (args.len) {
        1 => .{ .main_file_path = null },
        2 => .{ .main_file_path = args[1] },
        else => {
            // TODO: This will result in main's deferred statements not being called, is it alright to just let
            // OS handle mem cleanup?
            std.log.err("usage: lox [path]\n", .{});
            std.process.exit(64); // Command line usage error code.
        },
    };
}

pub fn main() anyerror!u8 {
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_instance.allocator();

    const args: []const [:0]u8 = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const config = parseArgs(args);
    var context = try Context.init(gpa, config);
    defer context.deinit();

    var vm = VirtMach.init(&context);
    defer vm.deinit();
    vm.resetStack();

    if (context.main_module.is_toplevel) {
        return try repl(gpa, &context, &vm);
    }

    var module = &context.main_module;
    if (try compile.compileModule(gpa, &context, module)) {
        try vm.interpret(&module.bytecode.elems[0]);
    }
    // TODO: Return type should be based on success/failure of compilation & execution.
    return 0;
}

fn repl(gpa: Allocator, context: *Context, vm: *VirtMach) !u8 {
    const stdin = std.io.getStdIn();
    const reader = std.io.bufferedReader(stdin.reader()).reader();
    const writer = std.io.getStdErr().writer();
    var state = try ReplCompilation.init(gpa, context);
    var line = std.mem.zeroes([1024:0]u8);

    while (true) {
        try writer.print("> ", .{});
        if (reader.readUntilDelimiterOrEof(&line, '\n') catch |err| {
            try writer.print("\nunable to parse input: {s}\n", .{@errorName(err)});
            continue;
        }) |source_code| {
            // `source_code` slice does not include the delimiter so it is guaranteed that the
            // buffer has room for a sentinel.
            line[source_code.len] = 0;
            if (state.compileSource(line[0..source_code.len :0]) catch continue) {
                vm.interpret(state.parser.current_chunk) catch continue;
                // try state.parser.current_chunk.disassemble(writer, "disass post exec");
            }
        }
    }
}

/// If supported by `tty_conf` write `str` to stderr using the provided color and optional emphasis.
pub fn writeAllColor(
    tty_conf: std.debug.TTY.Config,
    color: std.debug.TTY.Color,
    emphasis: ?std.debug.TTY.Color,
    str: []const u8,
) !void {
    const TTY = std.debug.TTY;
    const stderr = std.io.getStdErr();
    TTY.Config.setColor(tty_conf, stderr, color);
    if (emphasis) |effect| {
        TTY.Config.setColor(tty_conf, stderr, effect);
    }
    try stderr.writeAll(str);
    TTY.Config.setColor(tty_conf, stderr, TTY.Color.Reset);
}

test "suite" {
    _ = @import("bytecode.zig");
    _ = @import("compile.zig");
    _ = @import("Context.zig");
    _ = @import("dynamic_array.zig");
    _ = @import("interning.zig");
    _ = @import("Module.zig");
    _ = @import("object.zig");
    _ = @import("scanner.zig");
    _ = @import("virt_mach.zig");
}
