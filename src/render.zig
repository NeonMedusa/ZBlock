//render.zig:
pub fn draw(
    gctx: *const Gctx,
    render_pipeline: *const RenderPipeline,
    scene: *const Scene,
    grm: *const ResourceManager,
) !void {
    // 获取当前帧的纹理
    var surface_texture: wgpu.WGPUSurfaceTexture = undefined;
    wgpu.wgpuSurfaceGetCurrentTexture(gctx.surface, &surface_texture);
    if (surface_texture.status == 0) return error.TextureAcquisitionFailed;
    // 创建纹理视图
    const texture_view = wgpu.wgpuTextureCreateView(surface_texture.texture, null);
    defer wgpu.wgpuTextureViewRelease(texture_view);
    // 创建命令编码器
    const encoder_desc = wgpu.WGPUCommandEncoderDescriptor{};
    const encoder = wgpu.wgpuDeviceCreateCommandEncoder(gctx.device, &encoder_desc);
    // 更新scene_uniform_buffer
    wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        grm.scene_uniform_buffer,
        0,
        &scene.ubo,
        wgpu.wgpuBufferGetSize(grm.scene_uniform_buffer),
    );

    // 重置渲染实例计数器
    var entity_counter: u32 = 0;
    for (scene.entities.items) |entity| {
        if (entity.model) |model_idx| {
            const model = grm.models_data.items[model_idx];
            grm.indexed_indirect_cmds[entity_counter].indexCount = model.index_count;
            grm.indexed_indirect_cmds[entity_counter].instanceCount = 1;
            grm.indexed_indirect_cmds[entity_counter].firstIndex = model.first_index_idx;
            grm.indexed_indirect_cmds[entity_counter].baseVertex = model.first_vertex_idx;
            grm.indexed_indirect_cmds[entity_counter].firstInstance = entity_counter;

            grm.entities_data[entity_counter] = EntityData{
                .transform = entity.getTransform(),
                .texture_index = model.color_texture.index,
                .texture_size = model.color_texture.size,
                .uv_offset = model.color_texture.uv_offset,
            };
        }
        entity_counter += 1;
    }
    // 更新entities_data_buffer
    wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        grm.entities_data_buffer,
        0,
        grm.entities_data.ptr,
        @sizeOf(EntityData) * entity_counter,
    );

    // 更新indexed_indirect_cmds_buffer
    wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        grm.indexed_indirect_cmds_buffer,
        0,
        grm.indexed_indirect_cmds.ptr,
        @sizeOf(IndexedIndirectCmd) * entity_counter,
    );
    // 执行渲染
    const color_attachment = wgpu.WGPURenderPassColorAttachment{
        .view = texture_view,
        .loadOp = wgpu.WGPULoadOp_Clear,
        .storeOp = wgpu.WGPUStoreOp_Store,
        .depthSlice = wgpu.WGPU_DEPTH_SLICE_UNDEFINED,
        .clearValue = wgpu.WGPUColor{
            .r = 0.1,
            .g = 0.1,
            .b = 0.1,
            .a = 1.0,
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
    const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);
    // 设置渲染管线和绑定组
    wgpu.wgpuRenderPassEncoderSetPipeline(pass, render_pipeline.handle);
    wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, render_pipeline.bind_group, 0, null);
    // 设置顶点和索引缓冲区
    wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, grm.vertex_buffer, 0, wgpu.wgpuBufferGetSize(grm.vertex_buffer));
    wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, grm.index_buffer, wgpu.WGPUIndexFormat_Uint32, 0, wgpu.wgpuBufferGetSize(grm.index_buffer));
    // 间接绘制所有可见实例
    wgpu.wgpuRenderPassEncoderMultiDrawIndexedIndirect(pass, grm.indexed_indirect_cmds_buffer, 0, entity_counter);
    // 结束并释放渲染通道
    wgpu.wgpuRenderPassEncoderEnd(pass);
    wgpu.wgpuRenderPassEncoderRelease(pass);
    // 提交命令
    const command_buffer = wgpu.wgpuCommandEncoderFinish(encoder, null);
    wgpu.wgpuCommandEncoderRelease(encoder);
    wgpu.wgpuQueueSubmit(gctx.queue, 1, &command_buffer);
    wgpu.wgpuCommandBufferRelease(command_buffer);
    // 呈现表面后释放纹理
    _ = wgpu.wgpuSurfacePresent(gctx.surface);
    wgpu.wgpuTextureRelease(surface_texture.texture);
}

const std = @import("std");
const wgpu = @import("cimprots.zig").wgpu;
const Gctx = @import("gctx.zig");

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;

const ResourceManager = @import("resource_manager.zig");
const ComputePipeline = @import("compute_pipeline.zig");
const RenderPipeline = @import("render_pipeline.zig");
const Scene = @import("scene.zig");

const ShaderType = @import("shader_types.zig");
const SceneUniform = ShaderType.SceneUniform;
const VertexAttribute = ShaderType.VertexAttribute;
const EntityData = ShaderType.EntityData;
const ModelData = ShaderType.ModelData;
const IndexedIndirectCmd = ShaderType.IndexedIndirectCmd;
const VertexIndirectCmd = ShaderType.VertexIndirectCmd;
