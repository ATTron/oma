const std = @import("std");
const builtin = @import("builtin");
const root = @import("src/root.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("oma", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    const lib = b.addObject(.{
        .name = "oma",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}

/// Compile `source` once per CPU level and link all variants into `compile`.
///
/// If multiple compile steps share a `root_module`, call once per source file
/// per shared module — not once per compile step — to avoid duplicate symbols.
pub fn addMultiVersion(
    oma_dep: *std.Build.Dependency,
    compile: *std.Build.Step.Compile,
    options: struct {
        source: std.Build.LazyPath,
        /// If set, the source becomes importable via `@import(name)` so `resolveFrom`
        /// can derive types. **Caveat:** if the source file transitively `@import`s
        /// files that the root module also imports, Zig will error with a
        /// file-ownership conflict. Workaround: omit `.name` and use
        /// `resolve`/`resolveNoIo` with explicit function pointer types instead.
        name: ?[]const u8 = null,
        levels: ?[]const root.CpuLevel = null,
        /// Extra modules to make available inside the source file.
        /// **Do not** pass the parent compile step's own root module here — it
        /// creates a circular build dependency. Factor shared types into a
        /// separate module instead.
        imports: []const std.Build.Module.Import = &.{},
    },
) void {
    const b = compile.step.owner;
    const arch = compile.root_module.resolved_target.?.query.cpu_arch orelse builtin.cpu.arch;
    const levels = options.levels orelse defaultLevelsForArch(arch);

    // Thin wrapper that auto-exports all pub callconv(.c) fns from the user's source.
    const wf = b.addWriteFiles();
    const wrapper_source = wf.add("oma_wrapper.zig",
        \\const oma = @import("oma");
        \\const mod = @import("_oma_source");
        \\comptime { oma.exportAll(mod); }
    );

    if (options.name) |name| {
        const type_mod = b.createModule(.{
            .root_source_file = options.source,
            .target = compile.root_module.resolved_target,
            .optimize = compile.root_module.optimize orelse .Debug,
        });
        for (options.imports) |imp| type_mod.addImport(imp.name, imp.module);
        compile.root_module.addImport(name, type_mod);
    }

    for (levels) |level| {
        var query = compile.root_module.resolved_target.?.query;
        query.cpu_model = .{ .explicit = cpuModelForLevel(level) };
        const resolved = b.resolveTargetQuery(query);

        const user_mod = b.createModule(.{
            .root_source_file = options.source,
            .target = resolved,
            .optimize = compile.root_module.optimize orelse .Debug,
        });
        for (options.imports) |imp| user_mod.addImport(imp.name, imp.module);

        const variant_mod = b.createModule(.{
            .root_source_file = wrapper_source,
            .target = resolved,
            .optimize = compile.root_module.optimize orelse .Debug,
        });
        variant_mod.addImport("oma", oma_dep.module("oma"));
        variant_mod.addImport("_oma_source", user_mod);

        compile.root_module.addObject(b.addObject(.{
            .name = b.fmt("oma_{s}", .{level.suffix()}),
            .root_module = variant_mod,
        }));
    }
}

fn defaultLevelsForArch(arch: std.Target.Cpu.Arch) []const root.CpuLevel {
    return switch (arch) {
        .x86_64 => root.x86_64_levels,
        .aarch64, .aarch64_be => root.aarch64_levels,
        else => root.x86_64_levels,
    };
}

fn cpuModelForLevel(level: root.CpuLevel) *const std.Target.Cpu.Model {
    return switch (level) {
        .x86_64 => &std.Target.x86.cpu.x86_64,
        .x86_64_v2 => &std.Target.x86.cpu.x86_64_v2,
        .x86_64_v3 => &std.Target.x86.cpu.x86_64_v3,
        .x86_64_v4 => &std.Target.x86.cpu.x86_64_v4,
        .aarch64 => &std.Target.aarch64.cpu.generic,
        .aarch64_sve => &std.Target.aarch64.cpu.neoverse_v1,
        .aarch64_sve2 => &std.Target.aarch64.cpu.neoverse_v2,
    };
}
