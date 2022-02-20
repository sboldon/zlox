const std = @import("std");

// TODO: Add a build option that enables execution tracing. If set, traces will be written to
// std out. If set and an argument is provided, treat the argument as the filename of a log file.
// Every time vm is ran, a timestamped execution trace with the file name that the vm was invoked
// with is appeneded to the output stream.

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const tracing_enabled =
        b.option(
        bool,
        "enable-tracing",
        "Set to enable VM execution trace logging",
    ) orelse true;

    const options = b.addOptions();
    options.addOption(bool, "tracing_enabled", tracing_enabled);

    const exe = b.addExecutable("zlox", "src/main.zig");
    exe.addOptions("build_options", options);
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
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
