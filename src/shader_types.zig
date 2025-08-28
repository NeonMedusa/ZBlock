pub const Uniform = struct {
    projection_matrix: Mat4 = undefined, // 投影变换
    view_matrix: Mat4 = undefined, // 视图变换
    time: f32 = undefined, // 当前时间
    _padding: [3]f32 = undefined, // 需要对齐到16字节
    pub fn init(window: Window) @This() {
        const aspect_ratio: f32 = window.widthF / window.heightF;
        const projection_matrix = Algebra.perspective(70, aspect_ratio, 0.001, 100);
        const view_matrix = Algebra.lookAt(Vec3.new(0.0, 0.0, -3.0), Vec3.zero(), Vec3.up());
        return .{
            .projection_matrix = projection_matrix,
            .view_matrix = view_matrix,
        };
    }
};

pub const InstanceData = struct {
    entity_transform: Mat4 = undefined,
    joint_matrices: [50]Mat4 = undefined,
};

pub const VertexAttribute = struct {
    pos: [3]f32,
    normal: [3]f32,
    color: [4]f32,
    joint_indices: [4]u32,
    joint_weights: [4]f32,
};

// 包装后的 Mesh 资源信息（对应 GPU 缓冲区）
pub const GpuMesh = struct {
    vertex_offset: u32,
    vertex_size: u32,
    vertex_count: u32,
    index_offset: u32,
    index_size: u32,
    index_count: u32,
};

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Window = @import("window.zig");
