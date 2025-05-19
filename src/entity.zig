position: Vec3 = Vec3.zero(),
rotation: Vec3 = Vec3.zero(),
scale: Vec3 = Vec3.one(),
model: ?[]const u8 = null,
pub fn getModelMatrix(self: @This()) Mat4 {
    const translation = Mat4.fromTranslate(self.position);
    const rotation = Mat4.fromEulerAngles(self.rotation);
    const scale = Mat4.fromScale(self.scale);
    return Mat4.mul(translation, Mat4.mul(rotation, scale));
}
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Uniform = @import("shader_types.zig").Uniform;
