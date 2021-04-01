const std = @import("std");

const Options = struct {
    mode: std.builtin.Mode,
    target: std.zig.CrossTarget,

    fn apply(self: Options, lib: *std.build.LibExeObjStep) void {
        lib.setBuildMode(self.mode);
        lib.setTarget(self.target);

        // AtomicCondition is broken so we use pthreads instead
        lib.linkSystemLibrary("pthread");
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
    lib.install();
    options.apply(lib);
    for (packages.all) |pkg| {
        lib.addPackage(pkg);
    }

    const main_tests = b.addTest("src/main.zig");
    options.apply(main_tests);
    for (packages.all) |pkg| {
        main_tests.addPackage(pkg);
    }

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
    for ([_][]const u8{ "print-bot", "reply-bot" }) |name| {
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
    exe.addPackage(.{
        .name = "zCord",
        .path = "src/main.zig",
        .dependencies = packages.all,
    });

    return exe;
}

const packages = struct {
    const iguanaTLS = std.build.Pkg{
        .name = "iguanaTLS",
        .path = "lib/iguanaTLS/src/main.zig",
    };
    const hzzp = std.build.Pkg{
        .name = "hzzp",
        .path = "lib/hzzp/src/main.zig",
    };
    const wz = std.build.Pkg{
        .name = "wz",
        .path = "lib/wz/src/main.zig",
        .dependencies = &[_]std.build.Pkg{hzzp},
    };

    const all = &[_]std.build.Pkg{ iguanaTLS, hzzp, wz };
};
