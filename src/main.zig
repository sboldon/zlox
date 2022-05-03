const std = @import("std");
const Allocator = std.mem.Allocator;

const VirtMach = @import("virt_mach.zig").VirtMach;
const Context = @import("Context.zig");
const Module = @import("module.zig").Module;
const compile = @import("compile.zig");
const ReplCompilation = @import("compile.zig").ReplCompilation;
const bytecode = @import("bytecode.zig");
const Chunk = bytecode.Chunk;
const Value = @import("value.zig").Value;

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
    const stderr = std.io.getStdErr().writer();
    var state = try ReplCompilation.init(gpa, context);
    var line = std.mem.zeroes([1024:0]u8);

    while (true) {
        try stderr.print("> ", .{});
        if (reader.readUntilDelimiterOrEof(&line, '\n') catch |err| {
            try stderr.print("\nunable to parse input: {s}\n", .{@errorName(err)});
            continue;
        }) |source_code| {
            if (std.mem.eql(u8, source_code, "exit")) {
                // Exit using a less ad-hoc method.
                return 0;
            }
            // `source_code` slice does not include the delimiter so it is guaranteed that the
            // buffer has room for a sentinel.
            line[source_code.len] = 0;
            if (state.compileSource(line[0..source_code.len :0])) {
                try vm.interpret(state.parser.current_chunk);
            } else |err| return err;
        }
    }
}

test "suite" {
    _ = @import("dynamic_array.zig");
    _ = @import("bytecode.zig");
    _ = @import("virt_mach.zig");
    _ = @import("scanner.zig");
    _ = @import("compile.zig");
}
