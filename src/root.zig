const std = @import("std");
const builtin = @import("builtin");

pub const CpuLevel = enum {
    x86_64,
    x86_64_v2,
    x86_64_v3,
    x86_64_v4,

    aarch64,
    aarch64_sve,
    aarch64_sve2,

    pub fn suffix(self: CpuLevel) []const u8 {
        return @tagName(self);
    }
};

// Ordered highest-first so dispatch can pick the best match.
pub const x86_64_levels: []const CpuLevel = &.{ .x86_64_v4, .x86_64_v3, .x86_64_v2, .x86_64 };
pub const aarch64_levels: []const CpuLevel = &.{ .aarch64_sve2, .aarch64_sve, .aarch64 };

pub const default_levels: []const CpuLevel = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64_levels,
    .aarch64, .aarch64_be => aarch64_levels,
    else => x86_64_levels,
};

var cached_level: ?CpuLevel = null;

/// Detect the CPU level of the current machine. The result is cached after
/// the first call; subsequent calls return instantly.
pub fn detectCpuLevel(io: std.Io) CpuLevel {
    if (cached_level) |level| return level;
    var query: std.Target.Query = .fromTarget(&builtin.target);
    query.cpu_model = .native;
    const target = std.zig.system.resolveTargetQuery(io, query) catch return fallbackLevel();
    const level = levelFromFeatures(target.cpu.arch, target.cpu.features);
    cached_level = level;
    return level;
}

/// For shared libraries / FFI where there's no `std.Io` from main.
pub fn detectCpuLevelNoIo() CpuLevel {
    return detectCpuLevel(std.Io.Threaded.global_single_threaded.io());
}

/// Returns the CPU level the current binary was compiled for. This is a
/// comptime value — use `detectCpuLevel` for runtime detection.
pub fn buildCpuLevel() CpuLevel {
    return levelFromFeatures(builtin.target.cpu.arch, builtin.target.cpu.features);
}

/// Detect the CPU and resolve a function pointer in one call. The function
/// type is derived from `Source`, which must be an `@import`ed module
/// registered via `addMultiVersion(.name = ...)`.
///
///   const dot = oma.resolveFrom(dot_product, "dot", io);
///
/// If using `.name` causes a file-ownership conflict, use `resolve` with
/// an explicit function pointer type instead.
pub fn resolveFrom(
    comptime Source: type,
    comptime name: []const u8,
    io: std.Io,
) *const @TypeOf(@field(Source, name)) {
    return resolveForLevel(*const @TypeOf(@field(Source, name)), name, default_levels, detectCpuLevel(io));
}

/// `resolveFrom` for shared libraries / FFI where there's no `std.Io`.
pub fn resolveFromNoIo(
    comptime Source: type,
    comptime name: []const u8,
) *const @TypeOf(@field(Source, name)) {
    return resolveFrom(Source, name, std.Io.Threaded.global_single_threaded.io());
}

/// Like `resolveFrom`, but you supply the function pointer type directly.
/// Use this when you can't use `addMultiVersion(.name = ...)` due to
/// file-ownership conflicts.
///
///   const MyFn = *const fn(@Vector(4, f32), @Vector(4, f32)) callconv(.c) f32;
///   const dot = oma.resolve(MyFn, "dot", io);
pub fn resolve(comptime F: type, comptime name: []const u8, io: std.Io) F {
    return resolveForLevel(F, name, default_levels, detectCpuLevel(io));
}

/// `resolve` for shared libraries / FFI where there's no `std.Io`.
pub fn resolveNoIo(comptime F: type, comptime name: []const u8) F {
    return resolve(F, name, std.Io.Threaded.global_single_threaded.io());
}

/// Resolve against a pre-detected level and custom level list. Use this when
/// you need to resolve many functions at once or dispatch over non-default levels:
///
///   const level = oma.detectCpuLevel(io);
///   const dot = oma.resolveForLevel(DotFn, "dot", levels, level);
///   const sum = oma.resolveForLevel(SumFn, "sum", levels, level);
pub fn resolveForLevel(comptime F: type, comptime name: []const u8, comptime levels: []const CpuLevel, detected: CpuLevel) F {
    inline for (levels) |level| {
        if (@intFromEnum(detected) >= @intFromEnum(level))
            return externFn(F, level, name);
    }
    return externFn(F, levels[levels.len - 1], name);
}

/// Exports every pub callconv(.c) fn with a level-suffixed symbol name.
/// Called internally by `addMultiVersion`; you shouldn't need this directly.
pub fn exportAll(comptime Module: type) void {
    for (@typeInfo(Module).@"struct".decls) |decl| {
        const func = @field(Module, decl.name);
        if (isCFunc(@TypeOf(func)))
            @export(&func, .{ .name = buildCpuLevel().suffix() ++ "_" ++ decl.name });
    }
}

fn externFn(comptime F: type, comptime level: CpuLevel, comptime name: []const u8) F {
    return @extern(F, .{ .name = level.suffix() ++ "_" ++ name });
}

fn fallbackLevel() CpuLevel {
    return switch (builtin.target.cpu.arch) {
        .x86_64 => .x86_64,
        .aarch64, .aarch64_be => .aarch64,
        else => .x86_64,
    };
}

fn levelFromFeatures(arch: std.Target.Cpu.Arch, feats: std.Target.Cpu.Feature.Set) CpuLevel {
    switch (arch) {
        .x86_64 => {
            if (std.Target.x86.featureSetHasAll(feats, .{.avx512f})) return .x86_64_v4;
            if (std.Target.x86.featureSetHasAll(feats, .{.avx2})) return .x86_64_v3;
            if (std.Target.x86.featureSetHasAll(feats, .{.sse4_2})) return .x86_64_v2;
            return .x86_64;
        },
        .aarch64, .aarch64_be => {
            if (std.Target.aarch64.featureSetHasAll(feats, .{.sve2})) return .aarch64_sve2;
            if (std.Target.aarch64.featureSetHasAll(feats, .{.sve})) return .aarch64_sve;
            return .aarch64;
        },
        else => return .x86_64,
    }
}

fn isCFunc(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"fn" => |f| std.meta.activeTag(f.calling_convention) == std.meta.activeTag(std.builtin.CallingConvention.c),
        else => false,
    };
}

test "suffix" {
    try std.testing.expectEqualStrings("x86_64_v3", CpuLevel.x86_64_v3.suffix());
    try std.testing.expectEqualStrings("aarch64_sve", CpuLevel.aarch64_sve.suffix());
}

test "buildCpuLevel" {
    _ = buildCpuLevel().suffix();
}
