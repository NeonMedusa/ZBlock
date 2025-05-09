vertex_buffer: wgpu.WGPUBuffer,
vertex_count: usize,
vertex_buffer_size: usize,
index_buffer: wgpu.WGPUBuffer,
index_count: u32,
index_buffer_size: usize,
pub fn init(gctx: Gctx, vertex_data: []const f32, index_data: []const u16) !@This() {
    const vertex_buffer_desc = wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(f32) * vertex_data.len,
        .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Vertex,
        .mappedAtCreation = 0,
    };
    const vertex_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &vertex_buffer_desc);
    wgpu.wgpuQueueWriteBuffer(gctx.queue, vertex_buffer, 0, @ptrCast(vertex_data), vertex_buffer_desc.size);

    const index_buffer_desc = wgpu.WGPUBufferDescriptor{
        .size = @sizeOf(f32) * index_data.len,
        .usage = wgpu.WGPUBufferUsage_CopyDst | wgpu.WGPUBufferUsage_Index,
        .mappedAtCreation = 0,
    };
    const index_buffer = wgpu.wgpuDeviceCreateBuffer(gctx.device, &index_buffer_desc);
    wgpu.wgpuQueueWriteBuffer(gctx.queue, index_buffer, 0, @ptrCast(index_data), index_buffer_desc.size);

    return .{
        .vertex_buffer = vertex_buffer,
        .vertex_count = vertex_data.len / 6,
        .vertex_buffer_size = vertex_buffer_desc.size,
        .index_buffer = index_buffer,
        .index_count = @intCast(index_data.len),
        .index_buffer_size = index_buffer_desc.size,
    };
}
pub fn deinit(self: @This()) void {
    wgpu.wgpuBufferRelease(self.vertex_buffer);
    wgpu.wgpuBufferRelease(self.index_buffer);
}
const wgpu = @cImport({
    @cInclude("wgpu.h");
});
const Gctx = @import("gctx.zig");
