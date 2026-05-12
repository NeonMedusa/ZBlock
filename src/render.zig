// render.zig
pub fn draw(game: *Game) void {
    // 每帧开始时重置模型的引用计数，每帧结束时卸载引用计数为0的模型
    // game.res_manager.resetRefCount();
    // defer game.res_manager.removeZeroRefModel();

    var surface_texture: Wgpu.WGPUSurfaceTexture = undefined;
    Wgpu.wgpuSurfaceGetCurrentTexture(game.gctx.surface, &surface_texture);

    const surface_texture_view = Wgpu.wgpuTextureCreateView(surface_texture.texture, null);
    defer Wgpu.wgpuTextureViewRelease(surface_texture_view);

    const encoder_desc = Wgpu.WGPUCommandEncoderDescriptor{};
    const encoder = Wgpu.wgpuDeviceCreateCommandEncoder(game.gctx.device, &encoder_desc);

    Wgpu.wgpuQueueWriteBuffer(
        game.gctx.queue,
        game.res_manager.scene_uniform_buffer,
        0,
        &game.ubo,
        Wgpu.wgpuBufferGetSize(game.res_manager.scene_uniform_buffer),
    );

    // ========== 单次遍历：收集实体/实例数据 + 构建DrawBatch ==========
    var entity_idx: u32 = 0;
    var ins_idx: u32 = 0;
    game.res_manager.draw_batch_count = 0;

    var view = game.registry.view(.{ Comps.ModelName, Comps.Position }, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const entity_pos = view.getConst(Comps.Position, entity);
        const alpha = game.accumulator / TICK_DT;
        const render_pos = Vec3.lerp(entity_pos.prev, entity_pos.vec, alpha);
        game.res_manager.entities_data[entity_idx] = EntityData{
            .transform = Mat4.fromTranslate(render_pos),
        };

        const model_name = view.getConst(Comps.ModelName, entity);
        const model = game.res_manager.getOrLoadModel(model_name.id);

        for (model.nodes) |node| {
            if (node.mesh) |mesh_idx| {
                const mesh = model.meshes[mesh_idx];
                for (mesh.primitives) |primitive| {
                    game.res_manager.instances_data[ins_idx] = .{
                        .transform = node.matrix,
                        .entity_idx = entity_idx,
                    };

                    game.res_manager.draw_batches[game.res_manager.draw_batch_count] = .{
                        .vertex_buffer = primitive.vertex_buffer,
                        .index_buffer = primitive.index_buffer,
                        .index_count = primitive.index_count,
                        .bind_group = primitive.material.bind_group,
                        .instance_idx = ins_idx,
                    };
                    game.res_manager.draw_batch_count += 1;
                    ins_idx += 1;
                }
            }
        }
        entity_idx += 1;
    }

    // 为区块预留实体/实例
    const chunk_entity_idx = entity_idx;
    game.res_manager.entities_data[chunk_entity_idx] = EntityData{
        .transform = Mat4.fromTranslate(Vec3.new(0, 0, 0)),
    };
    entity_idx += 1;

    const chunk_instance_idx = ins_idx;
    game.res_manager.instances_data[chunk_instance_idx] = InstanceData{
        .transform = Mat4.identity,
        .entity_idx = chunk_entity_idx,
    };
    ins_idx += 1;

    // 上传 GPU 数据
    if (entity_idx > 0) {
        Wgpu.wgpuQueueWriteBuffer(
            game.gctx.queue,
            game.res_manager.entities_data_buffer,
            0,
            game.res_manager.entities_data.ptr,
            @sizeOf(EntityData) * entity_idx,
        );
    }
    if (ins_idx > 0) {
        Wgpu.wgpuQueueWriteBuffer(
            game.gctx.queue,
            game.res_manager.instances_data_buffer,
            0,
            game.res_manager.instances_data.ptr,
            @sizeOf(InstanceData) * ins_idx,
        );
    }

    // ========== 渲染通道 ==========
    const color_attachment = Wgpu.WGPURenderPassColorAttachment{
        .view = surface_texture_view,
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
            // .depthClearValue = 1.0,
            .depthClearValue = 0.0,
            .depthReadOnly = 0,
            .stencilLoadOp = Wgpu.WGPULoadOp_Undefined,
            .stencilStoreOp = Wgpu.WGPUStoreOp_Undefined,
            .stencilClearValue = 0,
            .stencilReadOnly = 1,
        },
    };

    const pass = Wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);
    Wgpu.wgpuRenderPassEncoderSetPipeline(pass, game.render_pipeline.handle);
    Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, game.render_pipeline.global_bind_group, 0, null);

    // 绘制所有模型实体
    for (game.res_manager.draw_batches[0..game.res_manager.draw_batch_count]) |batch| {
        Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, batch.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(batch.vertex_buffer));
        Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, batch.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(batch.index_buffer));
        Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, batch.bind_group, 0, null);
        Wgpu.wgpuRenderPassEncoderDrawIndexed(pass, batch.index_count, 1, 0, 0, batch.instance_idx);
    }

    // 绘制所有区块
    var chunk_it = game.block_world.chunks.valueIterator();
    while (chunk_it.next()) |loaded| {
        var mesh_it = loaded.mesh_cache.meshes.iterator();
        while (mesh_it.next()) |entry| {
            const mat_idx = entry.key_ptr.*;
            const mesh = entry.value_ptr;
            if (mesh.vertex_count == 0) continue;

            if (game.block_world.material_registry.materials[@intCast(mat_idx)]) |*global_mat| {
                Wgpu.wgpuRenderPassEncoderSetVertexBuffer(
                    pass,
                    0,
                    mesh.vertex_buffer,
                    0,
                    Wgpu.wgpuBufferGetSize(mesh.vertex_buffer),
                );
                Wgpu.wgpuRenderPassEncoderSetIndexBuffer(
                    pass,
                    mesh.index_buffer,
                    Wgpu.WGPUIndexFormat_Uint32,
                    0,
                    Wgpu.wgpuBufferGetSize(mesh.index_buffer),
                );
                Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, global_mat.material.bind_group, 0, null);
                Wgpu.wgpuRenderPassEncoderDrawIndexed(pass, mesh.index_count, 1, 0, 0, chunk_instance_idx);
            }
        }
    }

    // UI渲染
    Wgpu.wgpuRenderPassEncoderSetPipeline(pass, game.ui_system.render_pipeline.handle);
    Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, game.ui_system.render_pipeline.bind_group, 0, null);
    Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, game.ui_system.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(game.ui_system.vertex_buffer));
    Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, game.ui_system.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(game.ui_system.index_buffer));
    Wgpu.wgpuRenderPassEncoderDrawIndexed(pass, @as(u32, @intCast(game.ui_system.index_count)), 1, 0, 0, 0);

    // 图标纹理渲染（独立管线，非索引）
    if (game.icon_atlas.vertex_count > 0) {
        game.icon_atlas.upload(game.gctx.queue);
        Wgpu.wgpuRenderPassEncoderSetPipeline(pass, game.icon_atlas.pipeline.handle);
        Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, game.icon_atlas.pipeline.bind_group, 0, null);
        Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, game.icon_atlas.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(game.icon_atlas.vertex_buffer));
        Wgpu.wgpuRenderPassEncoderDraw(pass, @as(u32, @intCast(game.icon_atlas.vertex_count)), 1, 0, 0);
    }

    Wgpu.wgpuRenderPassEncoderEnd(pass);
    Wgpu.wgpuRenderPassEncoderRelease(pass);

    const command_buffer = Wgpu.wgpuCommandEncoderFinish(encoder, null);
    Wgpu.wgpuCommandEncoderRelease(encoder);
    Wgpu.wgpuQueueSubmit(game.gctx.queue, 1, &command_buffer);
    Wgpu.wgpuCommandBufferRelease(command_buffer);

    _ = Wgpu.wgpuSurfacePresent(game.gctx.surface);
    Wgpu.wgpuTextureRelease(surface_texture.texture);
}

pub fn drawUI(game: *Game) void {
    var surface_texture: Wgpu.WGPUSurfaceTexture = undefined;
    Wgpu.wgpuSurfaceGetCurrentTexture(game.gctx.surface, &surface_texture);
    const surface_texture_view = Wgpu.wgpuTextureCreateView(surface_texture.texture, null);
    defer Wgpu.wgpuTextureViewRelease(surface_texture_view);

    const encoder = Wgpu.wgpuDeviceCreateCommandEncoder(game.gctx.device, null);

    Wgpu.wgpuQueueWriteBuffer(
        game.gctx.queue,
        game.res_manager.scene_uniform_buffer,
        0,
        &game.ubo,
        Wgpu.wgpuBufferGetSize(game.res_manager.scene_uniform_buffer),
    );

    const color_attachment = Wgpu.WGPURenderPassColorAttachment{
        .view = surface_texture_view,
        .loadOp = Wgpu.WGPULoadOp_Clear,
        .storeOp = Wgpu.WGPUStoreOp_Store,
        .depthSlice = Wgpu.WGPU_DEPTH_SLICE_UNDEFINED,
        .clearValue = Wgpu.WGPUColor{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 },
    };

    const render_pass_desc = Wgpu.WGPURenderPassDescriptor{
        .colorAttachmentCount = 1,
        .colorAttachments = &color_attachment,
        .depthStencilAttachment = &Wgpu.WGPURenderPassDepthStencilAttachment{
            .view = game.gctx.depth_texture_view,
            .depthLoadOp = Wgpu.WGPULoadOp_Clear,
            .depthStoreOp = Wgpu.WGPUStoreOp_Store,
            .depthClearValue = 0.0,
            .depthReadOnly = 0,
            .stencilLoadOp = Wgpu.WGPULoadOp_Undefined,
            .stencilStoreOp = Wgpu.WGPUStoreOp_Undefined,
            .stencilClearValue = 0,
            .stencilReadOnly = 1,
        },
    };

    const pass = Wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);

    Wgpu.wgpuRenderPassEncoderSetPipeline(pass, game.ui_system.render_pipeline.handle);
    Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, game.ui_system.render_pipeline.bind_group, 0, null);
    Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, game.ui_system.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(game.ui_system.vertex_buffer));
    Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, game.ui_system.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(game.ui_system.index_buffer));
    Wgpu.wgpuRenderPassEncoderDrawIndexed(pass, @as(u32, @intCast(game.ui_system.index_count)), 1, 0, 0, 0);

    if (game.icon_atlas.vertex_count > 0) {
        game.icon_atlas.upload(game.gctx.queue);
        Wgpu.wgpuRenderPassEncoderSetPipeline(pass, game.icon_atlas.pipeline.handle);
        Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, game.icon_atlas.pipeline.bind_group, 0, null);
        Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, game.icon_atlas.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(game.icon_atlas.vertex_buffer));
        Wgpu.wgpuRenderPassEncoderDraw(pass, @as(u32, @intCast(game.icon_atlas.vertex_count)), 1, 0, 0);
    }

    Wgpu.wgpuRenderPassEncoderEnd(pass);
    Wgpu.wgpuRenderPassEncoderRelease(pass);

    const command_buffer = Wgpu.wgpuCommandEncoderFinish(encoder, null);
    Wgpu.wgpuCommandEncoderRelease(encoder);
    Wgpu.wgpuQueueSubmit(game.gctx.queue, 1, &command_buffer);
    Wgpu.wgpuCommandBufferRelease(command_buffer);
    _ = Wgpu.wgpuSurfacePresent(game.gctx.surface);
    Wgpu.wgpuTextureRelease(surface_texture.texture);
}

const Imports = @import("imports.zig");

const Wgpu = Imports.Wgpu;

const Algebra = Imports.Algebra;
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;

const RendCTX = Imports.RendCTX;
const EntityData = RendCTX.EntityData;
const InstanceData = RendCTX.InstanceData;

const Game = Imports.Game;

const Comps = Imports.Comps;

const TICK_DT = @import("block_world.zig").TICK_DT;
