const std = @import("std");
pub const pkgs = struct {
    pub const hzzp = std.build.Pkg{
        .name = "hzzp",
        .source = .{ .path = "lib/hzzp/src/main.zig" },
    };

    pub const wz = std.build.Pkg{
        .name = "wz",
        .source = .{ .path = "lib/wz/src/main.zig" },
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "hzzp",
                .source = .{ .path = "lib/hzzp/src/main.zig" },
            },
        },
    };

    pub const iguanaTLS = std.build.Pkg{
        .name = "iguanaTLS",
        .source = .{ .path = "lib/iguanaTLS/src/main.zig" },
    };

    pub const zasp = std.build.Pkg{
        .name = "zasp",
        .source = .{ .path = "lib/zasp/src/main.zig" },
    };

    pub const all = [_]std.build.Pkg{
        pkgs.hzzp,
        pkgs.wz,
        pkgs.iguanaTLS,
        pkgs.zasp,
    };

    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
        inline for (all) |pkg| {
            artifact.addPackage(pkg);
        }
    }
};

pub const exports = struct {
    pub const zCord = std.build.Pkg{
        .name = "zCord",
        .source = .{ .path = "src/main.zig" },
        .dependencies = &pkgs.all,
    };
};
pub const base_dirs = struct {
    pub const hzzp = "lib/hzzp";
    pub const wz = "lib/wz";
    pub const iguanaTLS = "lib/iguanaTLS";
    pub const zasp = "lib/zasp";
};
