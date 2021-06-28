const std = @import("std");
const deps = @import("deps.zig");

const Options = struct {
    mode: std.builtin.Mode,
    target: std.zig.CrossTarget,

    fn apply(self: Options, lib: *std.build.LibExeObjStep) void {
        lib.setBuildMode(self.mode);
        lib.setTarget(self.target);
    }
};

pub fn build(b: *std.build.Builder) void {
    const options = Options{
        // Standard target options allows the person running `zig build` to choose
        // what target to build for. Here we do not override the defaults, which
        // means any target is allowed, and the default is native. Other options
        // for restricting supported target set are available.
        .target = b.standardTargetOptions(.{}),

        // Standard release options allow the person running `zig build` to select
        // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
        .mode = b.standardReleaseOptions(),
    };

    const lib = b.addStaticLibrary("zCord", "src/main.zig");
    deps.pkgs.addAllTo(lib);
    lib.install();
    options.apply(lib);

    const main_tests = b.addTest("src/main.zig");
    options.apply(main_tests);
    deps.pkgs.addAllTo(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
    for ([_][]const u8{ "print-bot", "reconnect-bot", "reply-bot" }) |name| {
        const exe = createExampleExe(b, name);
        options.apply(exe);
        test_step.dependOn(&exe.step);

        const run_cmd = exe.run();
        const run_step = b.step(
            std.fmt.allocPrint(b.allocator, "example:{s}", .{name}) catch unreachable,
            std.fmt.allocPrint(b.allocator, "Run example {s}", .{name}) catch unreachable,
        );
        run_step.dependOn(&run_cmd.step);
    }
}

fn createExampleExe(b: *std.build.Builder, name: []const u8) *std.build.LibExeObjStep {
    const filename = std.fmt.allocPrint(b.allocator, "examples/{s}.zig", .{name}) catch unreachable;
    const exe = b.addExecutable(name, filename);
    exe.addPackage(deps.exports.zCord);

    return exe;
}
