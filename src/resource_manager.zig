// resource_manager.zig:
vertex_buffer: wgpu.WGPUBuffer, // 顶点缓冲区
index_buffer: wgpu.WGPUBuffer, // 索引缓冲区
scene_uniform_buffer: wgpu.WGPUBuffer, // 场景常量缓冲区
entities_data: []EntityData,
entities_data_buffer: wgpu.WGPUBuffer, // 渲染实例的世界矩阵缓冲区
indexed_indirect_cmds: []IndexedIndirectCmd,
indexed_indirect_cmds_buffer: wgpu.WGPUBuffer, // 间接绘制index命令缓冲区
models_data: std.ArrayList(ModelInfo),
// 纹理图集数组，ALL_IN_BOOM！包含所有的颜色、法线、高光贴图，还有动画纹理也在其中！
texture_altas_array: wgpu.WGPUTexture,
texture_altas_view: wgpu.WGPUTextureView,
// 渲染限制
const max_entities = 500; // 限制最大实体数
pub fn init(allocator: std.mem.Allocator, gctx: *Gctx) !@This() {
    const indexed_indirect_cmds_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(IndexedIndirectCmd) * max_entities,
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Indirect,
        .mappedAtCreation = 0,
    });
    const scene_uniform_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &.{
        .size = @sizeOf(SceneUniform),
        .usage = wgpu.WGPUBufferUsage_Uniform | wgpu.WGPUBufferUsage_CopyDst,
        .mappedAtCreation = 0,
    });
    const entities_data_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(Mat4) * max_entities,
        .usage = wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst,
        .mappedAtCreation = 0,
    });
    const entities_data = try allocator.alloc(EntityData, max_entities);
    const indexed_indirect_cmds = try allocator.alloc(IndexedIndirectCmd, max_entities);

    const texture_desc = wgpu.WGPUTextureDescriptor{
        .usage = wgpu.WGPUTextureUsage_CopyDst | wgpu.WGPUTextureUsage_TextureBinding,
        .dimension = wgpu.WGPUTextureDimension_2D,
        .size = .{
            .width = 2048,
            .height = 2048,
            // 大于1表明这是一个纹理数组，填入多少就有多少张纹理
            // 写入纹理时通过修改origin的z轴来指定写入哪一张纹理
            .depthOrArrayLayers = 3,
        },
        .format = wgpu.WGPUTextureFormat_RGBA8Unorm,
        .mipLevelCount = 1,
        .sampleCount = 1,
    };
    const texture_altas_array = wgpu.wgpuDeviceCreateTexture(gctx.device, &texture_desc);
    const texture_altas_view = wgpu.wgpuTextureCreateView(
        texture_altas_array,
        &wgpu.struct_WGPUTextureViewDescriptor{
            .aspect = wgpu.WGPUTextureAspect_All,
            .baseArrayLayer = 0,
            .arrayLayerCount = texture_desc.size.depthOrArrayLayers,
            .baseMipLevel = 0,
            .mipLevelCount = 1,
            .dimension = wgpu.WGPUTextureViewDimension_2DArray,
            .format = texture_desc.format,
        },
    );

    // 加载模型填充缓冲区
    var vertex_data = std.ArrayList(VertexAttribute){};
    var index_data = std.ArrayList(u32){};
    defer vertex_data.deinit(allocator);
    defer index_data.deinit(allocator);
    var models_data = std.ArrayList(ModelInfo){};
    var models_dir = try std.fs.cwd().openDir("resources/models", .{ .iterate = true });
    defer models_dir.close();
    var dir_iter = try models_dir.walk(allocator);
    defer dir_iter.deinit();
    var color_texture_count: u32 = 0;
    // 遍历模型文件夹
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

        // 提取纹理数据
        var texture_info = TextureInfo{};
        for (gltf.data.materials) |material| {
            if (material.metallic_roughness.base_color_texture) |color_texture_info| {
                const color_texture_img_idx = gltf.data.textures[color_texture_info.index].source;
                const img_source = gltf.data.images[color_texture_img_idx.?];
                defer color_texture_count += 1;
                var img = try zigimg.Image.fromMemory(allocator, img_source.data.?);
                defer img.deinit(allocator);
                try img.convert(allocator, .rgba32);
                wgpu.wgpuQueueWriteTexture(
                    gctx.queue,
                    &wgpu.WGPUTexelCopyTextureInfo{
                        .texture = texture_altas_array,
                        .mipLevel = 0,
                        // xy为写入时的像素偏移，我们可以利用这个特性实现纹理图集，z轴用于指定写入到哪张纹理中
                        .origin = .{ .x = 0, .y = 0, .z = color_texture_count },
                    },
                    img.pixels.rgba32.ptr,
                    img.pixels.rgba32.len * @sizeOf(zigimg.color.Rgba32),
                    &wgpu.struct_WGPUTexelCopyBufferLayout{
                        .offset = 0,
                        .bytesPerRow = @intCast(img.width * 4),
                        .rowsPerImage = @intCast(img.height),
                    },
                    &wgpu.struct_WGPUExtent3D{
                        .width = @intCast(img.width),
                        .height = @intCast(img.height),
                        .depthOrArrayLayers = 1,
                    },
                );
                texture_info.index = color_texture_count;
                const size_x_f: f32 = @floatFromInt(img.width);
                const size_y_f: f32 = @floatFromInt(img.height);
                texture_info.size = .{ size_x_f, size_y_f };
                texture_info.uv_offset = .{ 0, 0 };
            }
        }

        // 提取有mesh的节点的vertex和index数据
        var model_vertex_data = std.ArrayList(VertexAttribute){};
        var model_index_data = std.ArrayList(u32){};
        defer model_vertex_data.deinit(allocator);
        defer model_index_data.deinit(allocator);
        for (gltf.data.nodes, 0..) |node, node_idx| {
            if (node.mesh) |mesh_idx| {
                const world_matrix = calWorldMatrix(node_idx, &gltf);
                const mesh = gltf.data.meshes[mesh_idx];
                var mesh_vertex_data = std.ArrayList(VertexAttribute){};
                var mesh_index_data = std.ArrayList(u32){};
                defer mesh_vertex_data.deinit(allocator);
                defer mesh_index_data.deinit(allocator);
                for (mesh.primitives) |primitive| {
                    var primitive_vertex_data = std.ArrayList(VertexAttribute){};
                    var primitive_index_data = std.ArrayList(u32){};
                    defer primitive_vertex_data.deinit(allocator);
                    defer primitive_index_data.deinit(allocator);
                    // 处理索引，记录当前model的顶点数量作为偏移
                    const vertex_offset: u32 = @intCast(model_vertex_data.items.len);
                    if (primitive.indices) |indices_accessor_index| {
                        const accessor = gltf.data.accessors[indices_accessor_index];
                        var it = accessor.iterator(u16, &gltf, gltf.glb_binary.?);
                        while (it.next()) |indice| {
                            try primitive_index_data.append(allocator, indice[0] + vertex_offset);
                        }
                    }
                    // 处理顶点
                    for (primitive.attributes) |attribute| {
                        switch (attribute) {
                            .position => |idx| {
                                const accessor = gltf.data.accessors[idx];
                                var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                                while (it.next()) |v| {
                                    const final_pos = world_matrix.mulByVec4(.{ .data = .{ v[0], v[1], v[2], 1.0 } });
                                    try primitive_vertex_data.append(allocator, .{
                                        .pos = .{ final_pos.data[0], final_pos.data[1], final_pos.data[2] },
                                        .uv = .{ 0.1, 0.9 }, // ↓暂时只添加一些随机性的颜色
                                    });
                                }
                            },
                            .texcoord => |idx| {
                                const accessor = gltf.data.accessors[idx];
                                var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                                var i: u32 = 0;
                                while (it.next()) |t| : (i += 1) {
                                    primitive_vertex_data.items[i].uv = .{ t[0], t[1] };
                                }
                            },
                            else => {},
                        }
                    }
                    // 将primitive数据添加到model数据中
                    try model_vertex_data.appendSlice(allocator, primitive_vertex_data.items);
                    try model_index_data.appendSlice(allocator, primitive_index_data.items);
                }
                // 将当前mesh数据追加到当前model数据中
                try model_vertex_data.appendSlice(allocator, mesh_vertex_data.items);
                try model_index_data.appendSlice(allocator, mesh_index_data.items);
            }
        }
        // 将当前model数据追加到全局数据中
        const model = ModelInfo{
            .first_vertex_idx = @intCast(vertex_data.items.len),
            .first_index_idx = @intCast(index_data.items.len),
            .vertex_count = @intCast(model_vertex_data.items.len),
            .index_count = @intCast(model_index_data.items.len),
            .color_texture = texture_info,
        };
        try models_data.append(allocator, model);
        try vertex_data.appendSlice(allocator, model_vertex_data.items);
        try index_data.appendSlice(allocator, model_index_data.items);
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
    // 返回实例
    return @This(){
        .vertex_buffer = vertex_buffer,
        .index_buffer = index_buffer,
        .models_data = models_data,
        .scene_uniform_buffer = scene_uniform_buffer,
        .indexed_indirect_cmds = indexed_indirect_cmds,
        .indexed_indirect_cmds_buffer = indexed_indirect_cmds_buffer,
        .entities_data = entities_data,
        .entities_data_buffer = entities_data_buffer,
        .texture_altas_array = texture_altas_array,
        .texture_altas_view = texture_altas_view,
    };
}

fn calWorldMatrix(node_idx: usize, gltf: *Gltf) Mat4 {
    var current_idx = node_idx;
    var world_matrix = Mat4.identity();
    while (true) {
        const node = gltf.data.nodes[current_idx];
        if (node.matrix) |matrix| {
            world_matrix = Mat4.fromSlice(&matrix).mul(world_matrix);
        }
        current_idx = node.parent orelse break;
    }
    return world_matrix;
}

const ShaderType = @import("shader_types.zig");
const SceneUniform = ShaderType.SceneUniform;
const VertexAttribute = ShaderType.VertexAttribute;
const EntityData = ShaderType.EntityData;
const IndexedIndirectCmd = ShaderType.IndexedIndirectCmd;
const VertexIndirectCmd = ShaderType.VertexIndirectCmd;
const ModelInfo = ShaderType.ModelInfo;
const TextureInfo = ShaderType.TextureInfo;
const std = @import("std");
const Gctx = @import("gctx.zig");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Vec4 = Algebra.Vec4;
const Window = @import("window.zig");
const Gltf = @import("zgltf").Gltf;
const wgpu = @import("cimprots.zig").wgpu;
const zigimg = @import("zigimg");
