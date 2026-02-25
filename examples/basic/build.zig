const std = @import("std");
const oma = @import("oma");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const oma_dep = b.dependency("oma", .{});

    const exe = b.addExecutable(.{
        .name = "basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "oma", .module = oma_dep.module("oma") }},
        }),
    });

    oma.addMultiVersion(oma_dep, exe, .{
        .source = b.path("src/dot_product.zig"),
        .name = "dot_product",
    });

    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run example").dependOn(&run.step);
}
