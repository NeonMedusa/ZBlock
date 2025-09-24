//shader_types.zig:
pub const SceneUniform = struct {
    proj_matrix: Mat4 = undefined, // 投影矩阵
    view_matrix: Mat4 = undefined, // 视图矩阵
    time: f32 = undefined, // 当前时间
    active_entity_count: u32 = undefined, // 当前活动的实体数量
    _padding: [2]f32 = undefined, // 需要对齐到16字节
    pub fn init(window: Window) @This() {
        const aspect_ratio: f32 = window.widthF / window.heightF;
        const proj_matrix = Algebra.perspective(70, aspect_ratio, 0.001, 100);
        const view_matrix = Algebra.lookAt(Vec3.new(0.0, 0.0, -3.0), Vec3.zero(), Vec3.up());
        return .{
            .proj_matrix = proj_matrix,
            .view_matrix = view_matrix,
            .active_entity_count = 0,
            .time = 0,
        };
    }
};
pub const VertexAttribute = struct {
    pos: [3]f32, //顶点位置
    color: [4]f32, //顶点颜色
};
pub const EntityData = struct {
    transform: Mat4, //实例的模型矩阵
    model_idx: u32, //实例对应的模型索引
};
pub const ModelData = struct {
    first_node_idx: u32, //模型的第一个mesh索引
    node_count: u32, //模型的node数量
    mesh_count: u32, //模型实际需要渲染多少个mesh
};
pub const MeshData = struct {
    first_vertex_idx: u32, //mesh的第一个顶点索引
    first_index_idx: u32, //mesh的第一个索引索引
    vertex_count: u32, //mesh的顶点数量
    index_count: u32, //mesh的索引数量
};
pub const GltfNodeData = struct {
    parent_idx: u32, //父节点索引，u32的最大值表示无父节点
    local_matrix: Mat4, //节点的局部变换矩阵
    mesh_idx: u32, //mesh索引，u32的最大值表示无父节点
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

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Window = @import("window.zig");
