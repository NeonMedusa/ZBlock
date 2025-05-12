pub fn draw(gctx: Gctx, pipeline: Pipeline, scene: Scene, model_manager: ModelManager) !void {
    // 获取当前帧的纹理
    var surface_texture: wgpu.WGPUSurfaceTexture = undefined;
    wgpu.wgpuSurfaceGetCurrentTexture(gctx.surface, &surface_texture);
    if (surface_texture.status == 0) return error.TextureAcquisitionFailed;

    // 创建纹理视图
    const texture_view = wgpu.wgpuTextureCreateView(surface_texture.texture, null);
    defer wgpu.wgpuTextureViewRelease(texture_view);

    // 创建渲染通道描述符
    const color_attachment = wgpu.WGPURenderPassColorAttachment{
        .view = texture_view,
        .loadOp = wgpu.WGPULoadOp_Clear,
        .storeOp = wgpu.WGPUStoreOp_Store,
        .clearValue = wgpu.WGPUColor{
            .r = 0.1, // 红色分量 (0-1)
            .g = 0.1, // 绿色分量
            .b = 0.1, // 蓝色分量
            .a = 1.0, // 透明度
        },
    };
    const render_pass_desc = wgpu.WGPURenderPassDescriptor{
        .colorAttachmentCount = 1,
        .colorAttachments = &color_attachment,
        .depthStencilAttachment = &wgpu.WGPURenderPassDepthStencilAttachment{
            .view = gctx.depth_texture_view,
            .depthLoadOp = wgpu.WGPULoadOp_Clear,
            .depthStoreOp = wgpu.WGPUStoreOp_Store,
            .depthClearValue = 1.0,
            .depthReadOnly = 0,
            .stencilLoadOp = wgpu.WGPULoadOp_Undefined,
            .stencilStoreOp = wgpu.WGPUStoreOp_Undefined,
            .stencilClearValue = 0,
            .stencilReadOnly = 1,
        },
    };

    // 创建命令编码器
    const encoder_desc = wgpu.WGPUCommandEncoderDescriptor{};
    const encoder = wgpu.wgpuDeviceCreateCommandEncoder(gctx.device, &encoder_desc);

    // 开始渲染通道
    const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);

    // 设置渲染管线
    wgpu.wgpuRenderPassEncoderSetPipeline(pass, pipeline.handle);

    // 为每个模型写入transform
    const min_align_size = gctx.device_limits.minUniformBufferOffsetAlignment;
    const aligned_uniform_size = ((@sizeOf(Uniforms) + min_align_size - 1) / min_align_size) * min_align_size;
    for (scene.entities.items, 0..) |entity, i| {
        const model = model_manager.models.get(entity.model.?);
        var uniform_buffer_obj = scene.uniform_buffer_obj;
        uniform_buffer_obj.model_matrix = entity.getModelMatrix();
        // 计算动态偏移量并更新uniformbuffer
        const dynamic_offset = @as(u32, @intCast(i)) * aligned_uniform_size;
        wgpu.wgpuQueueWriteBuffer(
            gctx.queue,
            pipeline.uniform_buffer,
            dynamic_offset,
            &uniform_buffer_obj,
            @sizeOf(Uniforms),
        );
        // 渲染每个模型中的所有mesh
        for (model.?.items) |mesh| {
            wgpu.wgpuRenderPassEncoderSetVertexBuffer(
                pass,
                0,
                model_manager.vertex_buffer,
                mesh.vertex_offset,
                mesh.vertex_size,
            );
            wgpu.wgpuRenderPassEncoderSetIndexBuffer(
                pass,
                model_manager.index_buffer,
                wgpu.WGPUIndexFormat_Uint16,
                mesh.index_offset,
                mesh.index_size,
            );
            // 设置 bind group 并指定动态偏移量
            wgpu.wgpuRenderPassEncoderSetBindGroup(
                pass,
                0,
                pipeline.bind_group,
                1,
                &dynamic_offset,
            );
            wgpu.wgpuRenderPassEncoderDrawIndexed(
                pass,
                mesh.index_count,
                1,
                0,
                0,
                0,
            );
        }
    }

    // 结束渲染通道
    wgpu.wgpuRenderPassEncoderEnd(pass);
    wgpu.wgpuRenderPassEncoderRelease(pass);

    // 提交命令缓冲区
    const command_buffer = wgpu.wgpuCommandEncoderFinish(encoder, null);
    wgpu.wgpuCommandEncoderRelease(encoder);

    wgpu.wgpuQueueSubmit(gctx.queue, 1, &command_buffer);
    wgpu.wgpuCommandBufferRelease(command_buffer);

    // 呈现表面后释放纹理
    _ = wgpu.wgpuSurfacePresent(gctx.surface);
    wgpu.wgpuTextureRelease(surface_texture.texture);
}

const std = @import("std");
const wgpu = @cImport({
    @cInclude("wgpu.h");
});
const Gctx = @import("gctx.zig");
const Pipeline = @import("pipeline.zig");
const Uniforms = @import("uniforms.zig");
const Scene = @import("scene.zig");
const ModelManager = @import("model_manager.zig").ModelManager;

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
