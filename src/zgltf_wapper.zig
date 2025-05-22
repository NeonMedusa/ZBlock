/// 包装后的 Mesh 资源信息（对应 GPU 缓冲区）
const GpuMesh = struct {
    vertex_offset: u32,
    vertex_size: u32,
    vertex_count: u32,
    index_offset: u32,
    index_size: u32,
    index_count: u32,
};
/// 包装后的节点层级结构（支持变换和脏标记）
pub const SceneNode = struct {
    parent: ?*SceneNode = null,
    children: std.ArrayList(*SceneNode),
    local_translation: Vec3 = Vec3.zero(),
    local_scale: Vec3 = Vec3.one(),
    local_rotation: Quat = Quat.identity(),
    local_matrix: Mat4 = Mat4.identity(),
    world_matrix: Mat4 = Mat4.identity(),
    gpu_mesh_idx: ?usize = null,
    skin: ?SkinData = null,
    pub fn init(allocator: std.mem.Allocator, gltf_node: *Gltf.Node) !SceneNode {
        var node = SceneNode{
            .children = std.ArrayList(*SceneNode).init(allocator),
            .local_translation = Vec3{ .data = gltf_node.translation },
            .local_scale = Vec3{ .data = gltf_node.scale },
            .local_rotation = Quat.new(
                gltf_node.rotation[0],
                gltf_node.rotation[1],
                gltf_node.rotation[2],
                gltf_node.rotation[3],
            ),
            .gpu_mesh_idx = gltf_node.mesh,
        };
        if (gltf_node.matrix) |mat| {
            node.local_matrix = ArrToMat4(mat);
        } else {
            node.local_matrix = Mat4.identity();
        }
        return node;
    }
    pub fn getWorldMatrix(self: *SceneNode) Mat4 {
        self.world_matrix = if (self.parent) |parent|
            Mat4.mul(parent.getWorldMatrix(), self.local_matrix)
        else
            self.local_matrix;
        return self.world_matrix;
    }
};
/// 蒙皮数据（用于 GPU 上传）
pub const SkinData = struct {
    joints: []*SceneNode,
    inverse_bind_matrices: []Mat4,
    joint_matrices: []Mat4, // 最终传递给着色器的数据
    /// 计算所有关节的当前矩阵
    pub fn updateJointMatrices(self: *SkinData) void {
        for (self.joints, 0..) |joint, i| {
            self.joint_matrices[i] = Mat4.mul(joint.getWorldMatrix(), self.inverse_bind_matrices[i]);
        }
    }
};

pub const Model = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(*SceneNode),
    root_nodes: std.ArrayList(*SceneNode),
    skins: std.ArrayList(SkinData),
    meshes: std.ArrayList(GpuMesh),
    pub fn init(allocator: std.mem.Allocator) Model {
        return .{
            .allocator = allocator,
            .nodes = std.ArrayList(*SceneNode).init(allocator),
            .root_nodes = std.ArrayList(*SceneNode).init(allocator),
            .skins = std.ArrayList(SkinData).init(allocator),
            .meshes = std.ArrayList(GpuMesh).init(allocator),
        };
    }
    /// 从 Gltf 加载并构建层级
    pub fn loadFromGltf(
        self: *Model,
        gltf: *Gltf,
        vertex_data: *std.ArrayList(VertexAttribute),
        index_data: *std.ArrayList(u16),
    ) !void {
        // 创建所有节点
        for (gltf.data.nodes.items) |*gltf_node| {
            const node = try self.allocator.create(SceneNode);
            node.* = try SceneNode.init(self.allocator, gltf_node);
            try self.nodes.append(node);
        }
        // 构建父子关系
        for (gltf.data.nodes.items, 0..) |gltf_node, i| {
            if (gltf_node.parent) |parent_index| {
                self.nodes.items[i].parent = self.nodes.items[parent_index];
                try self.nodes.items[parent_index].children.append(self.nodes.items[i]);
            }
        }
        // 加载 Mesh
        var gpu_meshes = std.ArrayList(GpuMesh).init(self.allocator);
        defer gpu_meshes.deinit();
        for (gltf.data.meshes.items) |mesh| {
            var cur_mesh_vertex_data = std.ArrayList(VertexAttribute).init(self.allocator);
            defer cur_mesh_vertex_data.deinit();
            var cur_mesh_index_data = std.ArrayList(u16).init(self.allocator);
            defer cur_mesh_index_data.deinit();
            // 由于一个mesh中可能会有多个primitive，所以我们需要为当前primitive的索引计算顶点偏移
            var cur_primitive_vertex_offset: u16 = 0;
            for (mesh.primitives.items) |primitive| {
                cur_primitive_vertex_offset += @intCast(cur_mesh_vertex_data.items.len);
                // 提取索引数据
                if (primitive.indices) |indices_accessor_index| {
                    const accessor = gltf.data.accessors.items[indices_accessor_index];
                    var it = accessor.iterator(u16, gltf, gltf.glb_binary.?);
                    while (it.next()) |indice|
                        try cur_mesh_index_data.append(indice[0] + cur_primitive_vertex_offset);
                } // 提取顶点数据
                for (primitive.attributes.items) |attribute| {
                    switch (attribute) {
                        .position => |idx| {
                            const accessor = gltf.data.accessors.items[idx];
                            var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                            var i: f32 = 0; // 暂时只添加一些随机性的颜色
                            while (it.next()) |v| : (i += 0.001) {
                                try cur_mesh_vertex_data.append(.{
                                    .pos = .{ v[0], v[1], v[2] },
                                    .normal = .{ 1, 1, 1 },
                                    .color = .{ @mod(i / 0.1, 1), @mod(i / 0.2, 1), @mod(i / 0.3, 1), 1 },
                                    .joint_indices = .{ 0, 0, 0, 0 },
                                    .joint_weights = .{ 1, 0, 0, 0 },
                                });
                            }
                        },
                        .normal => |idx| {
                            const accessor = gltf.data.accessors.items[idx];
                            var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |n| : (i += 1)
                                cur_mesh_vertex_data.items[i].normal = .{ n[0], n[1], n[2] };
                        },
                        .color => |idx| {
                            const accessor = gltf.data.accessors.items[idx];
                            var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |c| : (i += 1)
                                cur_mesh_vertex_data.items[i].color = .{ c[0], c[1], c[2], c[3] };
                        },
                        .joints => |idx| {
                            const accessor = gltf.data.accessors.items[idx];
                            switch (accessor.component_type) {
                                .unsigned_byte => {
                                    var it = accessor.iterator(u8, gltf, gltf.glb_binary.?);
                                    var i: usize = 0;
                                    while (it.next()) |j| : (i += 1)
                                        cur_mesh_vertex_data.items[i].joint_indices = .{ j[0], j[1], j[2], j[3] };
                                },
                                .unsigned_short => {
                                    var it = accessor.iterator(u16, gltf, gltf.glb_binary.?);
                                    var i: usize = 0;
                                    while (it.next()) |j| : (i += 1)
                                        cur_mesh_vertex_data.items[i].joint_indices = .{ j[0], j[1], j[2], j[3] };
                                },
                                .unsigned_integer => {
                                    var it = accessor.iterator(u32, gltf, gltf.glb_binary.?);
                                    var i: usize = 0;
                                    while (it.next()) |j| : (i += 1)
                                        cur_mesh_vertex_data.items[i].joint_indices = .{ j[0], j[1], j[2], j[3] };
                                },
                                else => @panic("Type matching error, please refer to the definition of 'accessor.iterator'"),
                            }
                        },
                        .weights => |idx| {
                            const accessor = gltf.data.accessors.items[idx];
                            var it = accessor.iterator(f32, gltf, gltf.glb_binary.?);
                            var i: u32 = 0;
                            while (it.next()) |w| : (i += 1)
                                cur_mesh_vertex_data.items[i].joint_weights = .{ w[0], w[1], w[2], w[3] };
                        },
                        else => {},
                    }
                }
            }
            // 记录当前mesh在VertexBuffer中的偏移、大小等信息
            try self.meshes.append(.{
                .vertex_offset = @intCast(vertex_data.items.len * @sizeOf(VertexAttribute)),
                .vertex_size = @intCast(cur_mesh_vertex_data.items.len * @sizeOf(VertexAttribute)),
                .vertex_count = @intCast(cur_mesh_vertex_data.items.len),
                .index_offset = @intCast(index_data.items.len * @sizeOf(u16)),
                .index_size = @intCast(cur_mesh_index_data.items.len * @sizeOf(u16)),
                .index_count = @intCast(cur_mesh_index_data.items.len),
            });
            // 将当前mesh数据追加到全局数组中
            try vertex_data.appendSlice(cur_mesh_vertex_data.items);
            try index_data.appendSlice(cur_mesh_index_data.items);
        }
    }
    // 加载Skin
    // ...
};

pub const ModelManager = struct {
    allocator: std.mem.Allocator,
    vertex_buffer: wgpu.WGPUBuffer,
    index_buffer: wgpu.WGPUBuffer,
    models: std.StringHashMap(Model),
    pub fn init(gctx: Gctx, allocator: std.mem.Allocator) !@This() {
        var all_vertex_data = std.ArrayList(VertexAttribute).init(allocator);
        defer all_vertex_data.deinit();
        var all_index_data = std.ArrayList(u16).init(allocator);
        defer all_index_data.deinit();
        var models = std.StringHashMap(Model).init(allocator);
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
            // 创建模型，让模型填充vertex_data和index_data
            var model = Model.init(allocator);
            try model.loadFromGltf(
                &gltf,
                &all_vertex_data,
                &all_index_data,
            );
            // 记录当前模型的信息
            const model_name = try allocator.dupe(u8, std.fs.path.stem(entry.basename));
            try models.put(model_name, model);
        }
        std.debug.print("new_vertexCount:{d}\n", .{all_vertex_data.items.len});
        std.debug.print("new_indexCount:{d}\n", .{all_index_data.items.len});
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
        }
        self.models.deinit();
        wgpu.wgpuBufferRelease(self.vertex_buffer);
        wgpu.wgpuBufferRelease(self.index_buffer);
    }
};

pub fn ArrToMat4(arr: [16]f32) Mat4 {
    return .{
        .data = [4][4]f32{
            .{ arr[0], arr[1], arr[2], arr[3] },
            .{ arr[4], arr[5], arr[6], arr[7] },
            .{ arr[8], arr[9], arr[10], arr[11] },
            .{ arr[12], arr[13], arr[14], arr[15] },
        },
    };
}

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
const Quat = Algebra.Quat;
