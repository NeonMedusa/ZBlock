pub const ModelManager = struct {
    allocator: std.mem.Allocator,
    vertex_buffer: wgpu.WGPUBuffer,
    index_buffer: wgpu.WGPUBuffer,
    models: std.StringHashMap(Model), // 或用数组存储
    pub fn init(gctx: Gctx, allocator: std.mem.Allocator) !ModelManager {
        var all_vertex_data = std.ArrayList(VertexAttribute).init(allocator);
        defer all_vertex_data.deinit();
        var all_index_data = std.ArrayList(u16).init(allocator);
        defer all_index_data.deinit();
        var models = std.StringHashMap(Model).init(allocator);
        try loadAllModels(allocator, &models, &all_vertex_data, &all_index_data);

        const vertex_buffer_desc = wgpu.WGPUBufferDescriptor{
            .size = @sizeOf(VertexAttribute) * all_vertex_data.items.len,
            .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Vertex,
            .mappedAtCreation = 0,
        };
        const vertex_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &vertex_buffer_desc);
        wgpu.wgpuQueueWriteBuffer(gctx.queue, vertex_buffer, 0, @ptrCast(all_vertex_data.items.ptr), vertex_buffer_desc.size);

        const index_buffer_desc = wgpu.WGPUBufferDescriptor{
            .size = @sizeOf(u16) * all_index_data.items.len,
            .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Index,
            .mappedAtCreation = 0,
        };
        const index_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &index_buffer_desc);
        wgpu.wgpuQueueWriteBuffer(gctx.queue, index_buffer, 0, @ptrCast(all_index_data.items.ptr), index_buffer_desc.size);

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

    fn loadAllModels(
        allocator: std.mem.Allocator,
        models: *std.StringHashMap(Model),
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
            var vertices = std.ArrayList(VertexAttribute).init(allocator);
            defer vertices.deinit();

            var indices = std.ArrayList(u16).init(allocator);
            defer indices.deinit();

            if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".glb")) {
                const file_path = try std.fs.path.join(allocator, &.{ "resources/models", entry.basename });
                defer allocator.free(file_path);
                // 读取GLB文件

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

                const mesh = gltf.data.meshes.items[0];

                for (mesh.primitives.items) |primitive| {
                    if (primitive.indices) |indices_accessor_index| {
                        const accessor = gltf.data.accessors.items[indices_accessor_index];
                        var it = accessor.iterator(u16, &gltf, gltf.glb_binary.?);
                        var i: u32 = 0;
                        while (it.next()) |indice| : (i += 1) {
                            try indices.append(indice[0]);
                        }
                    }

                    for (primitive.attributes.items) |attribute| {
                        switch (attribute) {
                            .position => |idx| {
                                const accessor = gltf.data.accessors.items[idx];
                                var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                                while (it.next()) |v| {
                                    try vertices.append(.{
                                        .pos = .{ v[0], v[1], v[2] },
                                        .color = .{ v[0], v[1], v[2], 1 },
                                    });
                                }
                            },
                            .color => |idx| {
                                const accessor = gltf.data.accessors.items[idx];
                                var it = accessor.iterator(f32, &gltf, gltf.glb_binary.?);
                                var i: u32 = 0;
                                while (it.next()) |color| : (i += 1) {
                                    vertices.items[i].color = .{ color[0], color[1], color[2], color[3] };
                                }
                            },
                            else => {},
                        }
                    }
                }
                // 记录当前模型的信息
                const model_name = try allocator.dupe(u8, std.fs.path.stem(entry.basename));

                try models.put(model_name, .{
                    .vertex_offset = @intCast(all_vertex_data.items.len * @sizeOf(VertexAttribute)),
                    .vertex_size = @intCast(vertices.items.len * @sizeOf(VertexAttribute)),
                    .vertex_count = @intCast(vertices.items.len),
                    .index_offset = @intCast(all_index_data.items.len * @sizeOf(u16)),
                    .index_size = @intCast(indices.items.len * @sizeOf(u16)),
                    .index_count = @intCast(indices.items.len),
                });

                // 将当前模型数据追加到全局数组中
                try all_vertex_data.appendSlice(vertices.items);
                try all_index_data.appendSlice(indices.items);
            }
        }
    }
};

const Model = struct {
    vertex_offset: u32,
    vertex_size: u32,
    vertex_count: u32,
    index_offset: u32,
    index_size: u32,
    index_count: u32,
    // 可继续添加材质、纹理引用等
};

const wgpu = @cImport({
    @cInclude("wgpu.h");
});
const Gctx = @import("gctx.zig");
const std = @import("std");
const Gltf = @import("zgltf");

const VertexAttribute = @import("vertex_attribute.zig");
