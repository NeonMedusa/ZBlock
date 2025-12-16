//shader_types.zig:
pub const SceneUniform = struct {
    proj_matrix: Mat4 = undefined, // 投影矩阵
    view_matrix: Mat4 = undefined, // 视图矩阵
    time: f32 = undefined, // 当前时间
    _padding: [3]f32 = undefined, // 需要对齐到16字节
    pub fn init(window: Window) @This() {
        const aspect_ratio: f32 = window.width / window.height;
        const proj_matrix = Mat4.perspective(70, aspect_ratio, 0.001, 100);
        const view_matrix = Mat4.lookAt(Vec3.new(0.0, 0.0, -3.0), Vec3.zero(), Vec3.up());
        return .{
            .proj_matrix = proj_matrix,
            .view_matrix = view_matrix,
            .time = window.time,
        };
    }
};

pub const UiUniform = struct {
    ortho_matrix: Mat4,
    pub fn init(window: Window) @This() {
        const ortho_matrix = Mat4.orthographic(
            0,
            window.width,
            window.height,
            0,
            -1.0,
            1.0,
        );
        return @This(){
            .ortho_matrix = ortho_matrix,
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
    anime_texture_size: [2]f32 = .{ 0, 0 }, //动画纹理在纹理图集中的实际大小
    anime_texture_start: [2]i32 = .{ 0, 0 }, //动画纹理在纹理图集中的起始坐标
    anime_duration: f32 = 0, //动画的持续时间
    cur_anime_time: f32 = 0, //实例的当前动画时间
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
    color_texture_idx: u32 = 0, //基础颜色材质信息在纹理图集数组信息中的索引
    anime_texture: TextureInfo = undefined, //动画纹理
    anime_duration: f32, //动画持续时间
};

pub const TextureInfo = struct {
    size: [2]f32 = .{ 0, 0 }, // 纹理的实际大小
    coords_offset: [2]i32 = .{ 0, 0 }, // 纹理在纹理图集中的坐标偏移量
    index: u32 = 0, // 纹理在纹理数组中的索引
    _padding: [1]f32 = undefined, // 需要对齐到16字节
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

///////////////////////////////////////////////

//render_shader.wgsl:
// @group(0) @binding(0) var<uniform> scene_uniform : SceneUniform;                //场景常量数据
// @group(0) @binding(1) var<storage, read> entities_data : array<EntityData>;     //游戏实例数据
// @group(0) @binding(2) var color_atlas : texture_2d_array<f32>;                  //纹理图集数组
// @group(0) @binding(3) var anime_atlas : texture_2d_array<f32>;                  //动画纹理图集数组
// @group(0) @binding(4) var<storage, read> color_textures_info : array<TextureInfo>;    //色彩纹理信息
// @group(0) @binding(5) var<storage, read> Anime_textures_info : array<TextureInfo>;    //色彩纹理信息
pub const EntityDataRemaster = struct {
    transform: Mat4, //实例的世界变换
    anime_texture_start: u32, //实例动画纹理开始索引
    anime_texture_count: u32, //实例的动画纹理数量
    color_texture_start: u32, //实例的色彩纹理开始索引
    color_texture_count: u32, //实例色彩纹理数量
    // _padding: [1]f32 = undefined, // 需要对齐到16字节
};
const EntityAnimeState = struct {
    index: u32, //在动画纹理数组中的索引
    cur_time: f32, //动画当前时间
};
const EntityColorTexture = struct {
    index: u32, //在色彩纹理数组中的索引
};
const Animation = struct {
    duration: f32, //动画总时长
};
test "foo" {
    const allocator = std.testing.allocator;
    var animations = std.StringHashMap(Animation).init(allocator);
    defer animations.deinit();
}

const Algebra = @import("zalgebra");
const Vec2 = Algebra.Vec2;
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Window = @import("window.zig");
const Wgpu = @import("cimports.zig").Wgpu;
const std = @import("std");
