projection_matrix: Mat4 = undefined, // 投影变换
view_matrix: Mat4 = undefined, // 视图变换
model_matrix: Mat4 = undefined, // 模型变换
color: [4]f32 = undefined,
time: f32 = undefined,
_padding: [3]f32 = undefined,

pub fn init(window: Window) @This() {
    const aspect_ratio: f32 = window.widthF / window.heightF;
    const projection_matrix = Algebra.perspective(70, aspect_ratio, 0.001, 100);
    const view_matrix = Algebra.lookAt(Vec3.new(0.0, 0.0, -3.0), Vec3.zero(), Vec3.up());
    return .{
        .projection_matrix = projection_matrix,
        .view_matrix = view_matrix,
    };
}

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Window = @import("window.zig");
