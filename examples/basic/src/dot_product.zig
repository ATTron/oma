pub fn dot(a: @Vector(4, f32), b: @Vector(4, f32)) callconv(.c) f32 {
    return @reduce(.Add, a * b);
}
