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

    const exe = b.addExecutable("zigbot9001", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const hzzp = std.build.Pkg{
        .name = "hzzp",
        .path = "hzzp/src/main.zig",
    };

    exe.addPackage(hzzp);
    exe.addPackage(.{
        .name = "wz",
        .path = "lib/wz/src/main.zig",
        .dependencies = &[_]std.build.Pkg{hzzp},
    });
    exe.addPackage(.{
        .name = "analysis-buddy",
        .path = "lib/analysis-buddy/src/main.zig",
    });
    exe.addPackage(.{
        .name = "zig-bearssl",
        .path = "lib/zig-bearssl/bearssl.zig",
    });

    @import("lib/zig-bearssl/bearssl.zig").linkBearSSL("./lib/zig-bearssl", exe, target);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
