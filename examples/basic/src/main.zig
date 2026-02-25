const std = @import("std");
const oma = @import("oma");
const dot_product = @import("dot_product");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const dot = oma.resolveFrom(dot_product, "dot", io);

    const a: @Vector(4, f32) = .{ 1.0, 2.0, 3.0, 4.0 };
    const b: @Vector(4, f32) = .{ 5.0, 6.0, 7.0, 8.0 };
    const result = dot(a, b); // 1*5 + 2*6 + 3*7 + 4*8 = 70

    try stdout.print("CPU level: {s}\n", .{oma.detectCpuLevel(io).suffix()});
    try stdout.print("dot product: {d}\n", .{result});
    try stdout.flush();
}
