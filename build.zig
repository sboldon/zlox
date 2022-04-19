const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const tracing_enabled =
        b.option(
        bool,
        "exec-tracing",
        "Enable VM execution traces",
    ) orelse false;

    const options = b.addOptions();
    options.addOption(bool, "exec_tracing", tracing_enabled);

    const exe = b.addExecutable("lox", "src/main.zig");
    exe.addOptions("build_options", options);
    const opt_asm_path = b.option([]const u8, "emit-asm", "Output .s (assembly code)");
    if (opt_asm_path) |path| {
        exe.emit_asm = .{ .emit_to = path };
    }
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.addOptions("build_options", options);
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
