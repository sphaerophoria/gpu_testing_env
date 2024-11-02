pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

pub fn cross(a: Vec2, b: Vec2) f32 {
    return a[0] * b[1] - a[1] * b[0];
}
