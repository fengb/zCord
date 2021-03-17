const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("zCord", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();
    for (packages.all) |pkg| {
        lib.addPackage(pkg);
    }

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);
    for (packages.all) |pkg| {
        main_tests.addPackage(pkg);
    }

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    stepExample(b, "print-bot");
}

fn stepExample(b: *std.build.Builder, name: []const u8) void {
    const filename = std.fmt.allocPrint(b.allocator, "examples/{s}.zig", .{name}) catch unreachable;
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable(name, filename);
    exe.setBuildMode(mode);
    exe.addPackage(.{
        .name = "zCord",
        .path = "src/main.zig",
        .dependencies = packages.all,
    });

    const run_cmd = exe.run();
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const cmd_name = std.fmt.allocPrint(b.allocator, "example:{s}", .{name}) catch unreachable;
    const run_step = b.step(cmd_name, filename);
    run_step.dependOn(&run_cmd.step);
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
