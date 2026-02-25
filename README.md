# oma - One Man Army

Runtime SIMD dispatch for Zig.

Zig's `@Vector` picks SIMD width at compile time, which means distributed binaries have to choose one CPU level. `-Dcpu=native` crashes on older hardware; `-Dcpu=baseline` leaves performance on the table. oma compiles your hot functions once per microarchitecture level and picks the best one at startup.

## Architectures

| | Levels | |
|---|---|---|
| x86-64 | `x86_64` / `x86_64_v2` / `x86_64_v3` / `x86_64_v4` | SSE2 through AVX-512 |
| AArch64 | `aarch64` / `aarch64_sve` / `aarch64_sve2` | NEON through SVE2 |

## Usage

### 1. Add the dependency

```sh
zig fetch --save git+https://github.com/ATTron/oma
```

### 2. Write a hot function

Normal Zig in a separate file. Mark dispatch targets `pub` with `callconv(.c)`:

```zig
// src/dot_product.zig
pub fn dot(a: @Vector(4, f32), b: @Vector(4, f32)) callconv(.c) f32 {
    return @reduce(.Add, a * b);
}
```

Every `pub callconv(.c)` function gets compiled N times automatically — `x86_64_v3_dot`, `aarch64_sve_dot`, etc. `@Vector` and `suggestVectorLength` use the widest registers available for each variant.

### 3. Wire up the build

```zig
// build.zig
const std = @import("std");
const oma = @import("oma");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const oma_dep = b.dependency("oma", .{});

    const exe = b.addExecutable(.{
        .name = "myapp",
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
}
```

`addMultiVersion` picks the right levels for the target arch. One call per file — all `pub callconv(.c)` functions in the file are exported.

### 4. Dispatch at runtime

```zig
// src/main.zig
const std = @import("std");
const oma = @import("oma");
const dot_product = @import("dot_product");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const dot = oma.resolveFrom(dot_product, "dot", io);

    const a: @Vector(4, f32) = .{ 1.0, 2.0, 3.0, 4.0 };
    const b: @Vector(4, f32) = .{ 5.0, 6.0, 7.0, 8.0 };
    const result = dot(a, b); // 1*5 + 2*6 + 3*7 + 4*8 = 70

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.print("dot product: {d}\n", .{result});
    try stdout.flush();
}
```

`resolveFrom` detects the CPU, picks the best variant, and returns a typed function pointer. CPU detection is cached, so repeated calls just do a few enum comparisons — cheap enough to call inline.

## Shared libraries / FFI

If you don't have `std.Io` (e.g. a `.so` loaded by Python), use the `NoIo` variants:

```zig
const dot = oma.resolveFromNoIo(dot_product, "dot");
const level = oma.detectCpuLevelNoIo();
```

These use `std.Io.Threaded.global_single_threaded` internally. The Io versions are preferred when you do have access to `main`'s Init.

## How it works

**Build time**: `addMultiVersion` generates a tiny wrapper that calls `exportAll` on your module. It compiles this wrapper N times — once per CPU level. Each compilation targets a different CPU model, so `suggestVectorLength` returns different widths and `@Vector` picks the right registers. Variants get unique symbol names like `x86_64_v3_dot`.

**Runtime**: `detectCpuLevel` detects the CPU once and caches the result; subsequent calls return instantly. `resolveForLevel` walks the levels list highest-first and returns the `@extern` pointer for the best match.

## Overriding levels

```zig
oma.addMultiVersion(oma_dep, exe, .{
    .source = b.path("src/hot_function.zig"),
    .levels = &.{ .x86_64_v3, .x86_64 }, // just AVX2 + baseline
});
```

Use `resolveForLevel` to dispatch against custom levels at runtime:

```zig
const levels = &.{ .x86_64_v3, .x86_64 };
const level = oma.detectCpuLevel(io);
const fn_ptr = oma.resolveForLevel(MyFn, "my_func", levels, level);
```

## Caveats

- **`.name` and shared files**: If your hot file `@import`s files that the root module also uses, Zig errors with a file-ownership conflict. Fix: omit `.name` and use `resolve`/`resolveNoIo` with explicit function pointer types.
- **`.imports` and circular deps**: Don't pass the parent compile step's own module as an import — it creates a dependency loop. Factor shared types into a standalone module.
- **Shared `root_module`**: If multiple compile steps share a `root_module`, call `addMultiVersion` once per source per shared module, not per compile step.

## Requirements

Right now this only targets Zig 0.16.0-dev* or later
