//render.zig:
pub fn draw(
    gctx: *const Gctx,
    render_pipeline: *const RenderPipeline,
    scene: *const Scene,
    grm: *ResourceManager,
    ui_systemd: *UiSystem,
) !void {
    // 获取当前帧的纹理
    var surface_texture: Wgpu.WGPUSurfaceTexture = undefined;
    Wgpu.wgpuSurfaceGetCurrentTexture(gctx.surface, &surface_texture);
    if (surface_texture.status == 0) return error.TextureAcquisitionFailed;
    // 创建纹理视图
    const texture_view = Wgpu.wgpuTextureCreateView(surface_texture.texture, null);
    defer Wgpu.wgpuTextureViewRelease(texture_view);
    // 创建命令编码器
    const encoder_desc = Wgpu.WGPUCommandEncoderDescriptor{};
    const encoder = Wgpu.wgpuDeviceCreateCommandEncoder(gctx.device, &encoder_desc);
    // 更新scene_uniform_buffer
    Wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        grm.scene_uniform_buffer,
        0,
        &scene.ubo,
        Wgpu.wgpuBufferGetSize(grm.scene_uniform_buffer),
    );

    // 重置渲染实例计数器
    var entity_counter: u32 = 0;
    // 不分类间接绘制
    for (scene.entities.items) |entity| {
        if (entity.model) |model_name| {
            const model = grm.models_info.get(model_name);
            grm.indexed_indirect_cmds[entity_counter].indexCount = model.index_count;
            grm.indexed_indirect_cmds[entity_counter].instanceCount = 1;
            grm.indexed_indirect_cmds[entity_counter].firstIndex = model.first_index_idx;
            grm.indexed_indirect_cmds[entity_counter].baseVertex = model.first_vertex_idx;
            grm.indexed_indirect_cmds[entity_counter].firstInstance = entity_counter;

            grm.entities_data[entity_counter] = EntityData{
                .transform = entity.getTransform(),
                .color_texture_index = model.color_texture_idx,
                // .color_texture_size = model.color_texture.size,
                // .color_texture_start = model.color_texture.coords_offset,
                .anime_texture_index = model.anime_texture.index,
                .anime_texture_size = model.anime_texture.size,
                .anime_texture_start = model.anime_texture.coords_offset,
                .anime_duration = model.anime_duration,
                .cur_anime_time = entity.cur_anime_time,
                // .cur_anime_time = 0,
            };
        }
        entity_counter += 1;
    }

    // 更新entities_data_buffer
    Wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        grm.entities_data_buffer,
        0,
        grm.entities_data.ptr,
        @sizeOf(EntityData) * entity_counter,
    );

    // 更新indexed_indirect_cmds_buffer
    Wgpu.wgpuQueueWriteBuffer(
        gctx.queue,
        grm.indexed_indirect_cmds_buffer,
        0,
        grm.indexed_indirect_cmds.ptr,
        @sizeOf(IndexedIndirectCmd) * entity_counter,
    );
    // 执行渲染
    const color_attachment = Wgpu.WGPURenderPassColorAttachment{
        .view = texture_view,
        .loadOp = Wgpu.WGPULoadOp_Clear,
        .storeOp = Wgpu.WGPUStoreOp_Store,
        .depthSlice = Wgpu.WGPU_DEPTH_SLICE_UNDEFINED,
        .clearValue = Wgpu.WGPUColor{
            .r = 0.1,
            .g = 0.1,
            .b = 0.1,
            .a = 1.0,
        },
    };
    const render_pass_desc = Wgpu.WGPURenderPassDescriptor{
        .colorAttachmentCount = 1,
        .colorAttachments = &color_attachment,
        .depthStencilAttachment = &Wgpu.WGPURenderPassDepthStencilAttachment{
            .view = gctx.depth_texture_view,
            .depthLoadOp = Wgpu.WGPULoadOp_Clear,
            .depthStoreOp = Wgpu.WGPUStoreOp_Store,
            .depthClearValue = 1.0,
            .depthReadOnly = 0,
            .stencilLoadOp = Wgpu.WGPULoadOp_Undefined,
            .stencilStoreOp = Wgpu.WGPUStoreOp_Undefined,
            .stencilClearValue = 0,
            .stencilReadOnly = 1,
        },
    };
    const pass = Wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);
    // 设置渲染管线和绑定组
    Wgpu.wgpuRenderPassEncoderSetPipeline(pass, render_pipeline.handle);
    Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, render_pipeline.bind_group, 0, null);
    // 设置顶点和索引缓冲区
    Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, grm.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(grm.vertex_buffer));
    Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, grm.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(grm.index_buffer));
    // 间接绘制所有可见实例
    Wgpu.wgpuRenderPassEncoderMultiDrawIndexedIndirect(pass, grm.indexed_indirect_cmds_buffer, 0, entity_counter);

    //UI渲染!
    // 设置UI渲染管线和绑定组
    Wgpu.wgpuRenderPassEncoderSetPipeline(pass, ui_systemd.render_pipeline.handle);
    Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, ui_systemd.render_pipeline.bind_group, 0, null);
    // 设置顶点和索引缓冲区
    Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, ui_systemd.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(ui_systemd.vertex_buffer));
    Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, ui_systemd.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(ui_systemd.index_buffer));
    // 绘制UI
    Wgpu.wgpuRenderPassEncoderDrawIndexed(pass, @as(u32, @intCast(ui_systemd.frame_indices.items.len)), 1, 0, 0, 0);

    // 结束并释放渲染通道
    Wgpu.wgpuRenderPassEncoderEnd(pass);
    Wgpu.wgpuRenderPassEncoderRelease(pass);
    // 提交命令
    const command_buffer = Wgpu.wgpuCommandEncoderFinish(encoder, null);
    Wgpu.wgpuCommandEncoderRelease(encoder);
    Wgpu.wgpuQueueSubmit(gctx.queue, 1, &command_buffer);
    Wgpu.wgpuCommandBufferRelease(command_buffer);
    // 呈现表面后释放纹理
    _ = Wgpu.wgpuSurfacePresent(gctx.surface);
    Wgpu.wgpuTextureRelease(surface_texture.texture);
}

const std = @import("std");

const Wgpu = @import("cimports.zig").Wgpu;
const Gctx = @import("gctx.zig");

const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;

const ResourceManager = @import("resource_manager.zig");
const RenderPipeline = @import("render_pipeline.zig");
const Scene = @import("scene.zig");
const Entity = @import("entity.zig");

const ShaderType = @import("shader_types.zig");
const SceneUniform = ShaderType.SceneUniform;
const VertexAttribute = ShaderType.VertexAttribute;
const EntityData = ShaderType.EntityData;
const IndexedIndirectCmd = ShaderType.IndexedIndirectCmd;
const VertexIndirectCmd = ShaderType.VertexIndirectCmd;

const UiSystem = @import("ui_system.zig");
