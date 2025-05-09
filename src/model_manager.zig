pub const ModelManager = struct {
    allocator: std.mem.Allocator,
    vertex_buffer: wgpu.WGPUBuffer,
    index_buffer: wgpu.WGPUBuffer,
    models: std.StringHashMap(Model), // 或用数组存储
    pub fn init(gctx: Gctx, allocator: std.mem.Allocator) !ModelManager {
        var models = std.StringHashMap(Model).init(allocator);
        var all_vertex_data = std.ArrayList(f32).init(allocator);
        var all_index_data = std.ArrayList(u16).init(allocator);
        defer all_index_data.deinit();
        defer all_vertex_data.deinit();

        const pyramid_vertex_data = [_]f32{
            -0.5, -0.5, -0.3, 1.0, 1.0, 1.0, // x y z  r g b 左下角
            0.5, -0.5, -0.3, 1.0, 1.0, 1.0, // x y z  r g b 右下角
            0.5, 0.5, -0.3, 1.0, 1.0, 1.0, // x y z  r g b 右上角
            -0.5, 0.5, -0.3, 1.0, 1.0, 1.0, // x y z  r g b 左上角
            0.0, 0.0, 0.5, 0.5, 0.5, 0.5, // x y z  r g b 塔尖
        };
        const pyramid_index_data = [_]u16{
            0, 1, 2, // Base
            0, 2, 3, // Base
            0, 1, 4, // Sides
            1, 2, 4, // Sides
            2, 3, 4, // Sides
            3, 0, 4, // Sides
        };

        const cube_vertex_data = [_]f32{
            -0.3, -0.3, -0.3, 1.0, 1.0, 1.0, // 左下前
            0.3, -0.3, -0.3, 1.0, 1.0, 1.0, // 右下前
            0.3, 0.3, -0.3, 1.0, 1.0, 1.0, // 右上前
            -0.3, 0.3, -0.3, 1.0, 1.0, 1.0, // 左上前
            -0.3, -0.3, 0.3, 0.8, 0.8, 0.8, // 左下后
            0.3, -0.3, 0.3, 0.8, 0.8, 0.8, // 右下后
            0.3, 0.3, 0.3, 0.8, 0.8, 0.8, // 右上后
            -0.3, 0.3, 0.3, 0.8, 0.8, 0.8, // 左上后
        };
        const cube_index_data = [_]u16{
            0, 1, 2, // 前面
            0, 2, 3,
            4, 6, 5, // 后面
            4, 7, 6,
            0, 4, 5, // 底面
            0, 5, 1,
            3, 2, 6, // 顶面
            3, 6, 7,
            0, 3, 7, // 左侧面
            0, 7, 4,
            1, 5, 6, // 右侧面
            1, 6, 2,
        };

        try all_vertex_data.appendSlice(&pyramid_vertex_data);
        try all_index_data.appendSlice(&pyramid_index_data);
        const pyramid_model = Model{
            .vertex_offset = 0,
            .vertex_size = pyramid_vertex_data.len * @sizeOf(f32),
            .vertex_count = pyramid_vertex_data.len / 6,
            .index_offset = 0,
            .index_size = pyramid_index_data.len * @sizeOf(u16),
            .index_count = pyramid_index_data.len,
        };
        try models.put("pyramid", pyramid_model);

        try all_vertex_data.appendSlice(&cube_vertex_data);
        try all_index_data.appendSlice(&cube_index_data);
        const cube_model = Model{
            .vertex_offset = pyramid_vertex_data.len * @sizeOf(f32),
            .vertex_size = cube_vertex_data.len * @sizeOf(f32),
            .vertex_count = cube_vertex_data.len / 6,
            .index_offset = pyramid_index_data.len * @sizeOf(u16),
            .index_size = cube_index_data.len * @sizeOf(u16),
            .index_count = cube_index_data.len,
        };
        try models.put("cube", cube_model);

        const vertex_buffer_desc = wgpu.WGPUBufferDescriptor{
            .size = @sizeOf(f32) * all_vertex_data.items.len,
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
        self.models.deinit();
        wgpu.wgpuBufferRelease(self.vertex_buffer);
        wgpu.wgpuBufferRelease(self.index_buffer);
    }
};

const Model = struct {
    vertex_offset: u32,
    vertex_size: u32,
    vertex_count: u32,
    index_offset: u32,
    index_size: u32,
    index_count: u32,
    // 可以添加材质、纹理引用等
};

const wgpu = @cImport({
    @cInclude("wgpu.h");
});
const Gctx = @import("gctx.zig");
const std = @import("std");
