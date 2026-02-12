//render.zig:
pub fn draw(game: *Game) !void {
    // 获取当前帧的纹理
    var surface_texture: Wgpu.WGPUSurfaceTexture = undefined;
    Wgpu.wgpuSurfaceGetCurrentTexture(game.gctx.surface, &surface_texture);
    // 创建纹理视图
    const texture_view = Wgpu.wgpuTextureCreateView(surface_texture.texture, null);
    defer Wgpu.wgpuTextureViewRelease(texture_view);
    // 创建命令编码器
    const encoder_desc = Wgpu.WGPUCommandEncoderDescriptor{};
    const encoder = Wgpu.wgpuDeviceCreateCommandEncoder(game.gctx.device, &encoder_desc);
    // 更新scene_uniform_buffer
    Wgpu.wgpuQueueWriteBuffer(
        game.gctx.queue,
        game.res_manager.scene_uniform_buffer,
        0,
        &game.ubo,
        Wgpu.wgpuBufferGetSize(game.res_manager.scene_uniform_buffer),
    );
    // 重置渲染实例计数器
    var entity_counter: u32 = 0;

    // 准备缓冲区数据
    const requested_sig = blk: {
        var sig = Signature.initEmpty();
        sig.set(@intFromEnum(ComponentType.Position));
        sig.set(@intFromEnum(ComponentType.Model));
        break :blk sig;
    };
    for (game.world.activeEntities()) |entity| {
        const sig = entity.signature;
        if (sig.supersetOf(requested_sig)) {
            const model_name = game.world.models.get(entity.id).?.*;
            const model_info = game.res_manager.models_info.get(model_name);
            game.res_manager.indexed_indirect_cmds[entity_counter].indexCount = model_info.index_count;
            game.res_manager.indexed_indirect_cmds[entity_counter].instanceCount = 1;
            game.res_manager.indexed_indirect_cmds[entity_counter].firstIndex = model_info.first_index_idx;
            game.res_manager.indexed_indirect_cmds[entity_counter].baseVertex = model_info.first_vertex_idx;
            game.res_manager.indexed_indirect_cmds[entity_counter].firstInstance = entity_counter;

            const anim = model_info.animations.get(.walk) orelse undefined;

            game.res_manager.entities_data[entity_counter] = EntityData{
                .transform = WorldHelper.getTransformMatrix(entity).?,
                .color_texture_index = model_info.color_texture_idx,

                .anime_texture_index = anim.texture.index,
                .anime_texture_size = anim.texture.size,
                .anime_texture_start = anim.texture.coord,

                .anime_duration = anim.duration,

                .cur_anime_time = game.window.time,
            };
            entity_counter += 1;
        }
    }

    // 更新entities_data_buffer
    Wgpu.wgpuQueueWriteBuffer(
        game.gctx.queue,
        game.res_manager.entities_data_buffer,
        0,
        game.res_manager.entities_data.ptr,
        @sizeOf(EntityData) * entity_counter,
    );
    // 更新indexed_indirect_cmds_buffer
    Wgpu.wgpuQueueWriteBuffer(
        game.gctx.queue,
        game.res_manager.indexed_indirect_cmds_buffer,
        0,
        game.res_manager.indexed_indirect_cmds.ptr,
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
            .view = game.gctx.depth_texture_view,
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
    Wgpu.wgpuRenderPassEncoderSetPipeline(pass, game.render_pipeline.handle);
    Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, game.render_pipeline.bind_group, 0, null);
    // 设置顶点和索引缓冲区
    Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, game.res_manager.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(game.res_manager.vertex_buffer));
    Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, game.res_manager.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(game.res_manager.index_buffer));
    // 间接绘制所有可见实例
    if (entity_counter > 0)
        Wgpu.wgpuRenderPassEncoderMultiDrawIndexedIndirect(pass, game.res_manager.indexed_indirect_cmds_buffer, 0, entity_counter);

    //UI渲染!
    // 设置UI渲染管线和绑定组
    Wgpu.wgpuRenderPassEncoderSetPipeline(pass, game.ui_system.render_pipeline.handle);
    Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, game.ui_system.render_pipeline.bind_group, 0, null);
    // 设置顶点和索引缓冲区
    Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, game.ui_system.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(game.ui_system.vertex_buffer));
    Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, game.ui_system.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(game.ui_system.index_buffer));
    // 绘制UI
    Wgpu.wgpuRenderPassEncoderDrawIndexed(pass, @as(u32, @intCast(game.ui_system.index_count)), 1, 0, 0, 0);

    // 结束并释放渲染通道
    Wgpu.wgpuRenderPassEncoderEnd(pass);
    Wgpu.wgpuRenderPassEncoderRelease(pass);
    // 提交命令
    const command_buffer = Wgpu.wgpuCommandEncoderFinish(encoder, null);
    Wgpu.wgpuCommandEncoderRelease(encoder);
    Wgpu.wgpuQueueSubmit(game.gctx.queue, 1, &command_buffer);
    Wgpu.wgpuCommandBufferRelease(command_buffer);
    // 呈现表面后释放纹理
    _ = Wgpu.wgpuSurfacePresent(game.gctx.surface);
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

const ShaderType = @import("shader_types.zig");
const SceneUniform = ShaderType.SceneUniform;
const VertexAttribute = ShaderType.VertexAttribute;
const EntityData = ShaderType.EntityData;
const IndexedIndirectCmd = ShaderType.IndexedIndirectCmd;
const VertexIndirectCmd = ShaderType.VertexIndirectCmd;

const UiSystem = @import("ui_system.zig");
const Game = @import("game.zig");
const Systems = @import("systems.zig");
const WorldHelper = @import("world_helper.zig");

const ECS = @import("generated_ecs.zig");
const Signature = ECS.Signature;
const ComponentType = ECS.ComponentType;
