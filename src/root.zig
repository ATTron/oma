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

pub fn detectCpuLevel(io: std.Io) CpuLevel {
    var query: std.Target.Query = .fromTarget(&builtin.target);
    query.cpu_model = .native;
    const target = std.zig.system.resolveTargetQuery(io, query) catch return fallbackLevel();
    return levelFromFeatures(target.cpu.arch, target.cpu.features);
}

/// For shared libraries / FFI where there's no Io from main.
pub fn detectCpuLevelNoIo() CpuLevel {
    return detectCpuLevel(std.Io.Threaded.global_single_threaded.io());
}

pub fn buildCpuLevel() CpuLevel {
    return levelFromFeatures(builtin.target.cpu.arch, builtin.target.cpu.features);
}

/// Detect + resolve in one call. Type is derived from the source module:
///   const sum = oma.resolveFrom(vector_sum, "sum", io);
pub fn resolveFrom(
    comptime Source: type,
    comptime name: []const u8,
    io: std.Io,
) *const @TypeOf(@field(Source, name)) {
    return resolve(*const @TypeOf(@field(Source, name)), name, default_levels, io);
}

pub fn resolveFromNoIo(
    comptime Source: type,
    comptime name: []const u8,
) *const @TypeOf(@field(Source, name)) {
    return resolveFrom(Source, name, std.Io.Threaded.global_single_threaded.io());
}

/// Explicit type + levels variant.
pub fn resolve(comptime F: type, comptime name: []const u8, comptime levels: []const CpuLevel, io: std.Io) F {
    return resolveForLevel(F, name, levels, detectCpuLevel(io));
}

pub fn resolveNoIo(comptime F: type, comptime name: []const u8, comptime levels: []const CpuLevel) F {
    return resolve(F, name, levels, std.Io.Threaded.global_single_threaded.io());
}

/// Skip detection — use when you've already called detectCpuLevel and want
/// to resolve multiple functions without re-detecting.
pub fn resolveForLevel(comptime F: type, comptime name: []const u8, comptime levels: []const CpuLevel, detected: CpuLevel) F {
    inline for (levels) |level| {
        if (@intFromEnum(detected) >= @intFromEnum(level))
            return externFn(F, level, name);
    }
    return externFn(F, levels[levels.len - 1], name);
}

/// Exports every pub callconv(.c) fn with a level-suffixed symbol name.
pub fn exportAll(comptime Module: type) void {
    for (@typeInfo(Module).@"struct".decls) |decl| {
        const func = @field(Module, decl.name);
        if (isCFunc(@TypeOf(func)))
            @export(&func, .{ .name = buildCpuLevel().suffix() ++ "_" ++ decl.name });
    }
}

pub fn exportAs(comptime name: []const u8, comptime func: anytype) void {
    @export(&func, .{ .name = buildCpuLevel().suffix() ++ "_" ++ name });
}

pub fn externFn(comptime F: type, comptime level: CpuLevel, comptime name: []const u8) F {
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
