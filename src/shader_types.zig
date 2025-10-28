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
    position: [3]f32, //顶点位置
    color_uv: [2]f32 = .{ 0, 0 }, //纹理UV
    joint_indices: [4]u32 = .{ 0, 0, 0, 0 }, // 骨骼矩阵索引
    joint_weights: [4]f32 = .{ 1, 0, 0, 0 }, // 骨骼矩阵权重
};
pub const EntityData = struct {
    transform: Mat4, //实例的世界变换

    color_texture_size: [2]f32, //色彩纹理在纹理图集中的实际大小
    color_texture_start: [2]i32, //色彩纹理在纹理图集中的起始坐标

    anime_texture_size: [2]f32 = .{ 0, 0 }, //动画纹理在纹理图集中的实际大小
    anime_texture_start: [2]i32 = .{ 0, 0 }, //动画纹理在纹理图集中的起始坐标

    current_frame: f32 = 0, //实例的当前动画时间
    frames_per_second: f32 = 0, //动画帧率

    color_texture_index: u32 = 0, //色彩纹理在纹理图集数组中的索引
    anime_texture_index: u32 = 0, //动画纹理在纹理图集数组中的索引

    // _padding: [1]f32 = undefined, // 需要对齐到16字节

};
pub const ModelInfo = struct {
    first_vertex_idx: u32, //model的第一个顶点索引
    first_index_idx: u32, //model的第一个索引索引
    vertex_count: u32, //model的顶点数量
    index_count: u32, //model的索引数量
    color_texture: TextureInfo, //基础颜色材质
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
    size: [2]f32 = .{ 0, 0 }, // 纹理的实际大小
    coords_offset: [2]i32 = .{ 0, 0 }, // 纹理在纹理图集中的坐标偏移量
    index: u32 = 0, // 纹理在纹理数组中的索引
};
const Algebra = @import("zalgebra");
const Vec2 = Algebra.Vec2;
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Window = @import("window.zig");
const wgpu = @import("cimprots.zig").wgpu;
