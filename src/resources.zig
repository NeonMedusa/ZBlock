// const wgpu = @cImport({
//     @cInclude("wgpu.h");
// });

// pub const Resources = struct {
//     shader_module: wgpu.WGPUShaderModule,
//     vertex_buffer: wgpu.WGPUBuffer,
//     index_buffer: wgpu.WGPUBuffer,
//     uniform_buffer: wgpu.WGPUBuffer,
//     // 其他资源...
// };

// pub fn init(allocator: std.mem.Allocator, device: wgpu.WGPUDevice, shader_path: []const u8) !Resources {
//     const shader_module = try createShaderModule(device, shader_path);
//     const vertex_buffer = try createVertexBuffer(device);
//     const index_buffer = try createIndexBuffer(device);
//     const uniform_buffer = try createUniformBuffer(device);

//     return Resources{
//         .shader_module = shader_module,
//         .vertex_buffer = vertex_buffer,
//         .index_buffer = index_buffer,
//         .uniform_buffer = uniform_buffer,
//     };
// }

// pub fn deinit(res: Resources) void {
//     wgpu.wgpuBufferRelease(res.uniform_buffer);
//     wgpu.wgpuBufferRelease(res.index_buffer);
//     wgpu.wgpuBufferRelease(res.vertex_buffer);
//     wgpu.wgpuShaderModuleRelease(res.shader_module);
// }

// // 其他资源创建函数...
