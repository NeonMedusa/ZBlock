// resource_manager.zig:
// 通用缓冲区
vertex_buffer: wgpu.WGPUBuffer, // 顶点缓冲区
index_buffer: wgpu.WGPUBuffer, // 索引缓冲区
scene_uniform_buffer: wgpu.WGPUBuffer, // 场景常量缓冲区
world_matrices_buffer: wgpu.WGPUBuffer, // 渲染实例的世界矩阵缓冲区
// GPU间接绘制专用缓冲区
entities_data_buffer: wgpu.WGPUBuffer, // 实体数据缓冲区
models_data_buffer: wgpu.WGPUBuffer, // 模型数据缓冲区
meshes_data_buffer: wgpu.WGPUBuffer, // 网格数据缓冲区
nodes_data_buffer: wgpu.WGPUBuffer, // 节点数据缓冲区
indexed_indirect_cmds_buffer: wgpu.WGPUBuffer, // 间接绘制index命令缓冲区
vertex_indirect_cmds_buffer: wgpu.WGPUBuffer, // 间接绘制vertex命令缓冲区
instance_counter_buffer: wgpu.WGPUBuffer, // 用于原子操作的mesh计数器
// CPU绘制专用缓冲区
entities_data: []EntityData,
world_matrices: []Mat4,
indexed_indirect_cmds: []IndexedIndirectCmd,
models_data: std.ArrayList(ModelData),
meshes_data: std.ArrayList(MeshData),
nodes_data: std.ArrayList(GltfNodeData),
// 渲染限制
const max_entities = 100; // 限制最大实体数
const max_draw_ins = max_entities * 10; // 限制平均每个实体最多50个渲染实例（mesh）
pub fn init(allocator: std.mem.Allocator, gctx: *Gctx) !@This() {
    // 创建GPU间接绘制专用缓冲区
    const entities_data_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(EntityData) * max_entities,
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst,
        .mappedAtCreation = 0,
    });
    const indexed_indirect_cmds_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(IndexedIndirectCmd) * max_draw_ins,
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Indirect,
        .mappedAtCreation = 0,
    });
    const vertex_indirect_cmds_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(VertexIndirectCmd) * max_draw_ins,
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Indirect,
        .mappedAtCreation = 0,
    });
    const instance_counter_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(u32),
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst,
        .mappedAtCreation = 0,
    });
    // 创建通用缓冲区
    const scene_uniform_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
        .size = @sizeOf(SceneUniform),
        .usage = wgpu.WGPUBufferUsage_Uniform | wgpu.WGPUBufferUsage_CopyDst,
        .mappedAtCreation = 0,
    });
    const world_matrices_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(Mat4) * max_draw_ins,
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst,
        .mappedAtCreation = 0,
    });
    // 创建顶点、索引缓冲区
    var vertex_data = std.ArrayList(VertexAttribute){};
    var index_data = std.ArrayList(u32){};
    defer vertex_data.deinit(allocator);
    defer index_data.deinit(allocator);
    // 创建CPU绘制专用缓冲区
    const entities_data = try allocator.create([max_entities]EntityData);
    const world_matrices = try allocator.create([max_draw_ins]Mat4);
    const indexed_indirect_cmds = try allocator.create([max_draw_ins]IndexedIndirectCmd);
    var meshes_data = std.ArrayList(MeshData){};
    var models_data = std.ArrayList(ModelData){};
    var nodes_data = std.ArrayList(GltfNodeData){};
    // 加载模型填充缓冲区
    var models_dir = try std.fs.cwd().openDir("resources/models", .{ .iterate = true });
    defer models_dir.close();
    var dir_iter = try models_dir.walk(allocator);
    defer dir_iter.deinit();
    while (try dir_iter.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".glb")) continue;
        const file_path = try std.fs.path.join(allocator, &.{ "resources/models", entry.basename });
        defer allocator.free(file_path);
        const file_buf = try std.fs.cwd().readFileAllocOptions(
            allocator,
            file_path,
            std.math.maxInt(usize),
            null,
            .@"16",
            null,
        );
        defer allocator.free(file_buf);
        var gltf = Gltf.init(allocator);
        defer gltf.deinit();
        try gltf.parse(file_buf);
        //添加model
        var model = ModelData{
            .first_node_idx = @as(u32, @intCast(nodes_data.items.len)),
            .node_count = @as(u32, @intCast(gltf.data.nodes.len)),
            .mesh_count = 0,
        };
        //加载node
        const cur_model_first_mesh_idx = @as(u32, @intCast(meshes_data.items.len));
        for (gltf.data.nodes) |node| {
            var out_parent_idx: u32 = std.math.maxInt(u32);
            if (node.parent) |parent_idx| {
                out_parent_idx = @as(u32, @intCast(parent_idx)) + model.first_node_idx;
            }

            var out_matrix = Mat4.identity();
            if (node.matrix) |matrix| {
                out_matrix = Mat4.fromSlice(&matrix);
            }

            var out_mesh_idx: u32 = std.math.maxInt(u32);
            if (node.mesh) |mesh_idx| {
                // 记录model实际共有多少需要渲染的mesh
                model.mesh_count += 1;
                out_mesh_idx = @as(u32, @intCast(mesh_idx)) + cur_model_first_mesh_idx;
            }

            try nodes_data.append(allocator, .{
                .parent_idx = out_parent_idx,
                .local_matrix = out_matrix,
                .mesh_idx = out_mesh_idx,
            });
        } // 添加模型
        try models_data.append(allocator, model);

        //加载mesh
        for (gltf.data.meshes) |mesh| {
            var cur_mesh_vertex_data = std.ArrayList(VertexAttribute){};
            defer cur_mesh_vertex_data.deinit(allocator);
            var cur_mesh_index_data = std.ArrayList(u32){};
            defer cur_mesh_index_data.deinit(allocator);
            // 由于一个mesh中可能会有多个primitive，所以我们需要为索引计算顶点偏移
            var vertex_offset: u32 = 0;
            for (mesh.primitives) |primitive| {
                vertex_offset += @intCast(cur_mesh_vertex_data.items.len);
                // 提取indices
                if (primitive.indices) |indices_accessor_index| {
                    const accessor = gltf.data.accessors[indices_accessor_index];
                    var it = accessor.iterator(u16, &gltf, gltf.glb_binary.?);
                    while (it.next()) |indice|
                        try cur_mesh_index_data.append(allocator, indice[0] + vertex_offset);
                }
                // 提取vertices
                for (primitive.attributes) |attribute| {
                    switch (attribute) {
                        .position => |idx| {
                            const accessor = gltf.data.accessors[idx];
                            var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                            var i: f32 = 0; // 暂时只添加一些随机性的颜色
                            while (it.next()) |v| : (i += 0.001) {
                                try cur_mesh_vertex_data.append(allocator, .{
                                    .pos = .{ v[0], v[1], v[2] },
                                    .color = .{ @mod(i / 0.1, 1), @mod(i / 0.2, 1), @mod(i / 0.3, 1), 1 },
                                });
                            }
                        },
                        .color => |idx| {
                            const accessor = gltf.data.accessors[idx];
                            var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |c| : (i += 1)
                                cur_mesh_vertex_data.items[i].color = .{ c[0], c[1], c[2], c[3] };
                        },
                        else => {},
                    }
                }
            }
            // 记录当前mesh在VertexBuffer中的偏移、大小等信息
            try meshes_data.append(
                allocator,
                .{
                    .first_vertex_idx = @intCast(vertex_data.items.len), //mesh的第一个顶点索引
                    .first_index_idx = @intCast(index_data.items.len), //mesh的第一个索引索引
                    .vertex_count = @intCast(cur_mesh_vertex_data.items.len), //mesh的顶点数量
                    .index_count = @intCast(cur_mesh_index_data.items.len), //mesh的索引数量
                },
            );
            // 将当前mesh数据追加到全局数组中
            try vertex_data.appendSlice(allocator, cur_mesh_vertex_data.items);
            try index_data.appendSlice(allocator, cur_mesh_index_data.items);
        }
    }
    // 写入顶点和索引缓冲区
    const vertex_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
        .size = @sizeOf(VertexAttribute) * vertex_data.items.len,
        .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Vertex,
        .mappedAtCreation = 0,
    });
    wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        vertex_buffer,
        0,
        @ptrCast(vertex_data.items.ptr),
        wgpu.wgpuBufferGetSize(vertex_buffer),
    );
    const index_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
        .size = @sizeOf(u32) * index_data.items.len,
        .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Index,
        .mappedAtCreation = 0,
    });
    wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        index_buffer,
        0,
        @ptrCast(index_data.items.ptr),
        wgpu.wgpuBufferGetSize(index_buffer),
    );
    // 写入GPU间接绘制专用缓冲区
    const models_data_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
        .size = @sizeOf(ModelData) * models_data.items.len,
        .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Storage,
        .mappedAtCreation = 0,
    });
    wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        models_data_buffer,
        0,
        @ptrCast(models_data.items.ptr),
        wgpu.wgpuBufferGetSize(models_data_buffer),
    );
    const meshes_data_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(MeshData) * meshes_data.items.len,
        .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Storage,
        .mappedAtCreation = 0,
    });
    wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        meshes_data_buffer,
        0,
        @ptrCast(meshes_data.items.ptr),
        wgpu.wgpuBufferGetSize(meshes_data_buffer),
    );
    const nodes_data_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(GltfNodeData) * nodes_data.items.len,
        .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Storage,
        .mappedAtCreation = 0,
    });
    wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        nodes_data_buffer,
        0,
        @ptrCast(nodes_data.items.ptr),
        wgpu.wgpuBufferGetSize(nodes_data_buffer),
    );
    // 返回实例
    return @This(){
        // 通用缓冲区
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .scene_uniform_buffer = scene_uniform_buffer,
        .world_matrices_buffer = world_matrices_buffer,
        // GPU间接绘制专用缓冲区
        .entities_data_buffer = entities_data_buffer,
        .indexed_indirect_cmds_buffer = indexed_indirect_cmds_buffer,
        .instance_counter_buffer = instance_counter_buffer,
        .models_data_buffer = models_data_buffer,
        .meshes_data_buffer = meshes_data_buffer,
        .nodes_data_buffer = nodes_data_buffer,
        .vertex_indirect_cmds_buffer = vertex_indirect_cmds_buffer,
        // CPU绘制专用缓冲区
        .indexed_indirect_cmds = indexed_indirect_cmds,
        .world_matrices = world_matrices,
        .entities_data = entities_data,
        .models_data = models_data,
        .meshes_data = meshes_data,
        .nodes_data = nodes_data,
    };
}
const ShaderType = @import("shader_types.zig");
const SceneUniform = ShaderType.SceneUniform;
const VertexAttribute = ShaderType.VertexAttribute;
const EntityData = ShaderType.EntityData;
const IndexedIndirectCmd = ShaderType.IndexedIndirectCmd;
const VertexIndirectCmd = ShaderType.VertexIndirectCmd;
const GltfNodeData = ShaderType.GltfNodeData;
const MeshData = ShaderType.MeshData;
const ModelData = ShaderType.ModelData;
const std = @import("std");
const Gctx = @import("gctx.zig");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Vec4 = Algebra.Vec4;
const Window = @import("window.zig");
const Gltf = @import("zgltf").Gltf;
const wgpu = @import("cimprots.zig").wgpu;
