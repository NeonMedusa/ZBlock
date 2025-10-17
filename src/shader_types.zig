//shader_types.zig:
pub const SceneUniform = struct {
    proj_matrix: Mat4 = undefined, // 投影矩阵
    view_matrix: Mat4 = undefined, // 视图矩阵
    time: f32 = undefined, // 当前时间
    _padding: [3]f32 = undefined, // 需要对齐到16字节
    pub fn init(window: Window) @This() {
        const aspect_ratio: f32 = window.widthF / window.heightF;
        const proj_matrix = Algebra.perspective(70, aspect_ratio, 0.001, 100);
        const view_matrix = Algebra.lookAt(Vec3.new(0.0, 0.0, -3.0), Vec3.zero(), Vec3.up());
        return .{
            .proj_matrix = proj_matrix,
            .view_matrix = view_matrix,
            .time = 0,
        };
    }
};
pub const VertexAttribute = struct {
    pos: [3]f32, //顶点位置
    texcoord: [2]f32, //纹理UV
    color: [4]f32, //顶点颜色
};
pub const EntityData = struct {
    transform: Mat4, //实例的世界变换
};
pub const ModelData = struct {
    first_vertex_idx: u32, //model的第一个顶点索引
    first_index_idx: u32, //model的第一个索引索引
    vertex_count: u32, //model的顶点数量
    index_count: u32, //model的索引数量
    base_color_texture: ?wgpu.WGPUTextureView = null, //基础颜色材质
};
pub const IndexedIndirectCmd = struct {
    indexCount: u32,
    instanceCount: u32,
    firstIndex: u32,
    baseVertex: u32,
    firstInstance: u32,
};
pub const VertexIndirectCmd = struct {
    vertexCount: u32,
    instanceCount: u32,
    firstVertex: u32,
    firstInstance: u32,
};
pub const TextureInfo = struct {
    texture: wgpu.WGPUTexture,
    view: wgpu.WGPUTextureView,
};

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Window = @import("window.zig");
const wgpu = @import("cimprots.zig").wgpu;
