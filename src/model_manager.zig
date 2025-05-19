pub const ModelManager = struct {
    allocator: std.mem.Allocator,
    vertex_buffer: wgpu.WGPUBuffer,
    index_buffer: wgpu.WGPUBuffer,
    models: std.StringHashMap(std.ArrayList(NodeInfo)),
    pub fn init(gctx: Gctx, allocator: std.mem.Allocator) !ModelManager {
        var all_vertex_data = std.ArrayList(VertexAttribute).init(allocator);
        defer all_vertex_data.deinit();
        var all_index_data = std.ArrayList(u16).init(allocator);
        defer all_index_data.deinit();
        var models = std.StringHashMap(std.ArrayList(NodeInfo)).init(allocator);
        try extractModelData(
            allocator,
            &models,
            &all_vertex_data,
            &all_index_data,
        );

        const vertex_buffer_desc = wgpu.WGPUBufferDescriptor{
            .size = @sizeOf(VertexAttribute) * all_vertex_data.items.len,
            .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Vertex,
            .mappedAtCreation = 0,
        };
        const vertex_buffer = wgpu.wgpuDeviceCreateBuffer(
            gctx.device,
            &vertex_buffer_desc,
        );
        wgpu.wgpuQueueWriteBuffer(
            gctx.queue,
            vertex_buffer,
            0,
            @ptrCast(all_vertex_data.items.ptr),
            vertex_buffer_desc.size,
        );

        const index_buffer_desc = wgpu.WGPUBufferDescriptor{
            .size = @sizeOf(u16) * all_index_data.items.len,
            .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Index,
            .mappedAtCreation = 0,
        };
        const index_buffer = wgpu.wgpuDeviceCreateBuffer(
            gctx.device,
            &index_buffer_desc,
        );
        wgpu.wgpuQueueWriteBuffer(
            gctx.queue,
            index_buffer,
            0,
            @ptrCast(all_index_data.items.ptr),
            index_buffer_desc.size,
        );

        return ModelManager{
            .allocator = allocator,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .models = models,
        };
    }
    pub fn deinit(self: *ModelManager) void {
        var it = self.models.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.models.deinit();
        wgpu.wgpuBufferRelease(self.vertex_buffer);
        wgpu.wgpuBufferRelease(self.index_buffer);
    }
};

const MeshInVertexBufferInfo = struct {
    vertex_offset: u32,
    vertex_size: u32,
    vertex_count: u32,
    index_offset: u32,
    index_size: u32,
    index_count: u32,
    // 可继续添加材质、纹理引用等
};

fn extractModelData(
    allocator: std.mem.Allocator,
    models: *std.StringHashMap(std.ArrayList(NodeInfo)),
    all_vertex_data: *std.ArrayList(VertexAttribute),
    all_index_data: *std.ArrayList(u16),
) !void {
    // 打开models目录
    var models_dir = try std.fs.cwd().openDir("resources/models", .{ .iterate = true });
    defer models_dir.close();
    var dir_iter = try models_dir.walk(allocator);
    defer dir_iter.deinit();
    // 遍历目录中的所有文件
    while (try dir_iter.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".glb")) continue;
        // 加载并解析模型
        const file_path = try std.fs.path.join(allocator, &.{ "resources/models", entry.basename });
        defer allocator.free(file_path);
        const file_buf = try std.fs.cwd().readFileAllocOptions(
            allocator,
            file_path,
            std.math.maxInt(usize),
            null,
            4,
            null,
        );
        defer allocator.free(file_buf);
        var gltf = Gltf.init(allocator);
        defer gltf.deinit();
        try gltf.parse(file_buf);

        // 提取每个mesh的顶点、索引数据，并记录mesh在vertexbuffer中的偏移、大小信息
        var meshes_info = std.ArrayList(MeshInVertexBufferInfo).init(allocator);
        defer meshes_info.deinit();
        for (gltf.data.meshes.items) |mesh| {
            var cur_mesh_vertex_data = std.ArrayList(VertexAttribute).init(allocator);
            defer cur_mesh_vertex_data.deinit();
            var cur_mesh_index_data = std.ArrayList(u16).init(allocator);
            defer cur_mesh_index_data.deinit();
            // 由于一个mesh中可能会有多个primitive，所以我们需要为当前primitive的索引计算顶点偏移
            var cur_primitive_vertex_offset: u16 = 0;
            for (mesh.primitives.items) |primitive| {
                cur_primitive_vertex_offset += @intCast(cur_mesh_vertex_data.items.len);
                // 提取索引数据
                if (primitive.indices) |indices_accessor_index| {
                    const accessor = gltf.data.accessors.items[indices_accessor_index];
                    var it = accessor.iterator(u16, &gltf, gltf.glb_binary.?);
                    while (it.next()) |indice|
                        try cur_mesh_index_data.append(indice[0] + cur_primitive_vertex_offset);
                } // 提取顶点数据
                for (primitive.attributes.items) |attribute| {
                    switch (attribute) {
                        .position => |idx| {
                            const accessor = gltf.data.accessors.items[idx];
                            var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                            var i: f32 = 0; // 暂时只添加一些随机性的颜色
                            while (it.next()) |v| : (i += 0.001) {
                                try cur_mesh_vertex_data.append(.{
                                    .pos = .{ v[0], v[1], v[2] },
                                    .normal = .{ 1, 1, 1 },
                                    .color = .{ @mod(i / 0.1, 1), @mod(i / 0.2, 1), @mod(i / 0.3, 1), 1 },
                                    .joint_indices = .{ 0, 0, 0, 0 },
                                    .joint_weights = .{ 0, 0, 0, 0 },
                                });
                            }
                        },
                        .normal => |idx| {
                            const accessor = gltf.data.accessors.items[idx];
                            var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |n| : (i += 1)
                                cur_mesh_vertex_data.items[i].normal = .{ n[0], n[1], n[2] };
                        },
                        .color => |idx| {
                            const accessor = gltf.data.accessors.items[idx];
                            var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |c| : (i += 1)
                                cur_mesh_vertex_data.items[i].color = .{ c[0], c[1], c[2], c[3] };
                        },
                        .joints => |idx| {
                            const accessor = gltf.data.accessors.items[idx];
                            switch (accessor.component_type) {
                                .unsigned_byte => {
                                    var it = accessor.iterator(u8, &gltf, gltf.glb_binary.?);
                                    var i: usize = 0;
                                    while (it.next()) |j| : (i += 1)
                                        cur_mesh_vertex_data.items[i].joint_indices = .{ j[0], j[1], j[2], j[3] };
                                },
                                .unsigned_short => {
                                    var it = accessor.iterator(u16, &gltf, gltf.glb_binary.?);
                                    var i: usize = 0;
                                    while (it.next()) |j| : (i += 1)
                                        cur_mesh_vertex_data.items[i].joint_indices = .{ j[0], j[1], j[2], j[3] };
                                },
                                .unsigned_integer => {
                                    var it = accessor.iterator(u32, &gltf, gltf.glb_binary.?);
                                    var i: usize = 0;
                                    while (it.next()) |j| : (i += 1)
                                        cur_mesh_vertex_data.items[i].joint_indices = .{ j[0], j[1], j[2], j[3] };
                                },
                                else => @panic("Type matching error, please refer to the definition of 'accessor.iterator'"),
                            }
                        },
                        .weights => |idx| {
                            const accessor = gltf.data.accessors.items[idx];
                            var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |w| : (i += 1)
                                cur_mesh_vertex_data.items[i].joint_weights = .{ w[0], w[1], w[2], w[3] };
                        },
                        else => {},
                    }
                }
            }
            // 记录当前mesh在VertexBuffer中的偏移、大小等信息
            try meshes_info.append(MeshInVertexBufferInfo{
                .vertex_offset = @intCast(all_vertex_data.items.len * @sizeOf(VertexAttribute)),
                .vertex_size = @intCast(cur_mesh_vertex_data.items.len * @sizeOf(VertexAttribute)),
                .vertex_count = @intCast(cur_mesh_vertex_data.items.len),
                .index_offset = @intCast(all_index_data.items.len * @sizeOf(u16)),
                .index_size = @intCast(cur_mesh_index_data.items.len * @sizeOf(u16)),
                .index_count = @intCast(cur_mesh_index_data.items.len),
            });
            // 将当前mesh数据追加到全局数组中
            try all_vertex_data.appendSlice(cur_mesh_vertex_data.items);
            try all_index_data.appendSlice(cur_mesh_index_data.items);
        }
        // gltf中的mesh存储在node中，而node则构成树形结构，每个node都有自己的transform
        // 子节点的transform需要与父节点的相乘，而mesh则需要在渲染时应用transform信息
        var model = std.ArrayList(NodeInfo).init(allocator);
        const root_node_idx = gltf.data.scene.?;
        const root_node = gltf.data.nodes.items[root_node_idx];
        try linkNodeAndMesh(
            &model,
            &meshes_info,
            &gltf.data,
            root_node,
            Mat4.identity(),
        );
        // 记录当前模型的信息
        const model_name = try allocator.dupe(u8, std.fs.path.stem(entry.basename));
        try models.put(model_name, model);
        std.debug.print("------{s}------", .{model_name});
        gltf.debugPrint();
    }
}

fn linkNodeAndMesh(
    models: *std.ArrayList(NodeInfo),
    meshes: *std.ArrayList(MeshInVertexBufferInfo),
    gltf_data: *Gltf.Data,
    root_node: Gltf.Node,
    parent_transform: Mat4,
) !void {
    var cur_transform = Mat4.identity();
    if (root_node.matrix) |flat| {
        cur_transform = Mat4{
            .data = [4][4]f32{
                .{ flat[0], flat[1], flat[2], flat[3] },
                .{ flat[4], flat[5], flat[6], flat[7] },
                .{ flat[8], flat[9], flat[10], flat[11] },
                .{ flat[12], flat[13], flat[14], flat[15] },
            },
        };
    }
    const mixed_transform = Mat4.mul(parent_transform, cur_transform);
    if (root_node.mesh) |mesh_idx| {
        try models.append(NodeInfo{
            .mesh = meshes.items[mesh_idx],
            .transform = mixed_transform,
        });
    }
    for (root_node.children.items) |child_idx|
        try linkNodeAndMesh(
            models,
            meshes,
            gltf_data,
            gltf_data.nodes.items[child_idx],
            mixed_transform,
        );
}

const NodeInfo = struct {
    transform: Mat4 = Mat4.identity(),
    mesh: MeshInVertexBufferInfo,
};

const wgpu = @cImport({
    @cInclude("wgpu.h");
});
const Gctx = @import("gctx.zig");
const std = @import("std");
const Gltf = @import("zgltf");
const VertexAttribute = @import("shader_types.zig").VertexAttribute;

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
