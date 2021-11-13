const std = @import("std");
pub const pkgs = struct {
    pub const hzzp = std.build.Pkg{
        .name = "hzzp",
        .path = .{ .path = ".gyro/hzzp-truemedian-0.1.7-0540873cab6c5037398b0738818276c7/pkg/src/main.zig" },
    };

    pub const wz = std.build.Pkg{
        .name = "wz",
        .path = .{ .path = ".gyro/wz-truemedian-0.0.6-19c654b8a878857818318a972782b84a/pkg/src/main.zig" },
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "hzzp",
                .path = .{ .path = ".gyro/hzzp-truemedian-0.1.7-0540873cab6c5037398b0738818276c7/pkg/src/main.zig" },
            },
        },
    };

    pub const iguanaTLS = std.build.Pkg{
        .name = "iguanaTLS",
        .path = .{ .path = ".gyro/iguanaTLS-marler8997-d56e9fcd268e15bd44a65333af11d126e7ce3319/pkg/src/main.zig" },
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
        },
    };
};
pub const base_dirs = struct {
    pub const hzzp = ".gyro/hzzp-truemedian-0.1.7-0540873cab6c5037398b0738818276c7/pkg";
    pub const wz = ".gyro/wz-truemedian-0.0.6-19c654b8a878857818318a972782b84a/pkg";
    pub const iguanaTLS = ".gyro/iguanaTLS-marler8997-d56e9fcd268e15bd44a65333af11d126e7ce3319/pkg";
};
