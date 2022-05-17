const std = @import("std");
pub const pkgs = struct {
    pub const hzzp = std.build.Pkg{
        .name = "hzzp",
        .path = .{ .path = "lib/hzzp/src/main.zig" },
    };

    pub const wz = std.build.Pkg{
        .name = "wz",
        .path = .{ .path = "lib/wz/src/main.zig" },
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "hzzp",
                .path = .{ .path = "lib/hzzp/src/main.zig" },
            },
        },
    };

    pub const iguanaTLS = std.build.Pkg{
        .name = "iguanaTLS",
        .path = .{ .path = "lib/iguanaTLS/src/main.zig" },
    };

    pub const zasp = std.build.Pkg{
        .name = "zasp",
        .path = .{ .path = "lib/zasp/src/main.zig" },
    };

    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
        @setEvalBranchQuota(1_000_000);
        inline for (std.meta.declarations(pkgs)) |decl| {
            if (decl.is_pub and decl.data == .Var) {
                artifact.addPackage(@field(pkgs, decl.name));
            }
        }
    }
};

pub const exports = struct {
    pub const zCord = std.build.Pkg{
        .name = "zCord",
        .path = .{ .path = "src/main.zig" },
        .dependencies = &.{
            pkgs.hzzp,
            pkgs.wz,
            pkgs.iguanaTLS,
            pkgs.zasp,
        },
    };
};
pub const base_dirs = struct {
    pub const hzzp = "lib/hzzp";
    pub const wz = "lib/wz";
    pub const iguanaTLS = "lib/iguanaTLS";
};
