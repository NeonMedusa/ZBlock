// render.zig
/// 渲染帧（comptime world 控制是否渲染 3D 世界 vs 仅 UI）
fn drawFrame(game: *Game, comptime world: bool) void {
    var surface_texture: Wgpu.WGPUSurfaceTexture = undefined;
    Wgpu.wgpuSurfaceGetCurrentTexture(game.gctx.surface, &surface_texture);
    const surface_texture_view = Wgpu.wgpuTextureCreateView(surface_texture.texture, null);
    defer Wgpu.wgpuTextureViewRelease(surface_texture_view);

    const encoder = Wgpu.wgpuDeviceCreateCommandEncoder(game.gctx.device, null);

    const sky_time = @as(f32, @floatFromInt(game.tick_count)) * TICK_DT + game.accumulator;
    // 从天空状态同步光照数据到 ubo
    game.ubo.sun_direction = game.sky_pipeline.state.sun_direction;
    game.ubo.sun_intensity = game.sky_pipeline.state.sun_intensity;
    game.ubo.sun_color = game.sky_pipeline.state.sun_color;
    game.ubo.moon_brightness = game.sky_pipeline.state.moon_brightness;
    game.ubo.ambient_ground = game.sky_pipeline.state.ambient_ground;
    game.ubo.time = sky_time;

    if (world) {
        // inverse(proj × view_rot)：从 NDC 方向反算世界方向（全屏三角 cubemap）
        var view_rot = game.ubo.view_matrix;
        view_rot.m[3][0] = 0;
        view_rot.m[3][1] = 0;
        view_rot.m[3][2] = 0;
        const sky_mat = Mat4.inverse(Mat4.mul(game.ubo.proj_matrix, view_rot));
        game.sky_pipeline.updateUniform(&game.gctx, sky_mat, sky_time);

        // 阴影光源方向：太阳在水平线上方用太阳，否则用月亮
        const player_shadow_pos = Vec3.new(game.camera.position.x, 0.0, game.camera.position.z);
        const ldir = if (game.sky_pipeline.state.sun_direction.y > 0.0)
            Vec3.new(-game.sky_pipeline.state.sun_direction.x, game.sky_pipeline.state.sun_direction.y, -game.sky_pipeline.state.sun_direction.z)
        else
            Vec3.new(game.sky_pipeline.state.sun_direction.x, -game.sky_pipeline.state.sun_direction.y, game.sky_pipeline.state.sun_direction.z);
        game.shadow_pipeline.computeLightVp(ldir, player_shadow_pos);
        game.shadow_pipeline.updateUniform(&game.gctx);
        game.ubo.shadow_vp = game.shadow_pipeline.light_vp;

        // === 阴影渲染通道 (Pass 1) ===
        const shadow_pass_desc = Wgpu.WGPURenderPassDescriptor{
            .colorAttachmentCount = 0,
            .colorAttachments = null,
            .depthStencilAttachment = &Wgpu.WGPURenderPassDepthStencilAttachment{
                .view = game.shadow_pipeline.depth_texture_view,
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
        const shadow_pass = Wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &shadow_pass_desc);
        Wgpu.wgpuRenderPassEncoderSetPipeline(shadow_pass, game.shadow_pipeline.handle);
        Wgpu.wgpuRenderPassEncoderSetBindGroup(shadow_pass, 0, game.shadow_pipeline.bind_group, 0, null);
        var s_chunk_it = game.block_world.chunks.iterator();
        while (s_chunk_it.next()) |entry| {
            const loaded = &entry.value_ptr.*;
            var s_mesh_it = loaded.mesh_cache.meshes.iterator();
            while (s_mesh_it.next()) |mesh_entry| {
                const mesh = mesh_entry.value_ptr;
                if (mesh.vertex_count == 0) continue;
                Wgpu.wgpuRenderPassEncoderSetVertexBuffer(shadow_pass, 0, mesh.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(mesh.vertex_buffer));
                Wgpu.wgpuRenderPassEncoderSetIndexBuffer(shadow_pass, mesh.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(mesh.index_buffer));
                Wgpu.wgpuRenderPassEncoderDrawIndexed(shadow_pass, mesh.index_count, 1, 0, 0, 0);
            }
        }
        Wgpu.wgpuRenderPassEncoderEnd(shadow_pass);
    }

    // 写入 scene uniform（含最新 shadow_vp），阴影 pass 与主 pass 使用同一帧的 VP
    Wgpu.wgpuQueueWriteBuffer(
        game.gctx.queue,
        game.res_manager.scene_uniform_buffer,
        0,
        &game.ubo,
        Wgpu.wgpuBufferGetSize(game.res_manager.scene_uniform_buffer),
    );

    var chunk_instance_idx: u32 = 0;
    const frustum = if (world) Frustum.fromViewProj(Mat4.mul(game.ubo.proj_matrix, game.ubo.view_matrix)) else undefined;
    if (world) {

        // ========== 单次遍历：收集实体/实例数据 + 构建DrawBatch ==========
        var entity_idx: u32 = 0;
        var ins_idx: u32 = 0;
        game.res_manager.draw_batch_count = 0;

        // 在实体遍历前，收集所有有 AnimationState 的实体
        var anim_map = std.AutoHashMap(u32, i32).init(game.allocator);
        defer anim_map.deinit();
        {
            var view = game.registry.view(.{Comps.AnimationState}, .{});
            var it = view.entityIterator();
            while (it.next()) |e| {
                const state = view.get(e);
                anim_map.put(@as(u32, @intCast(e.index)), @as(i32, @intCast(state.bone_offset))) catch {};
            }
        }

        var view = game.registry.view(.{ Comps.ModelName, Comps.Position, Comps.Collider }, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const entity_pos = view.getConst(Comps.Position, entity);
            const alpha = game.accumulator / TICK_DT;
            const render_pos = Vec3.lerp(entity_pos.prev, entity_pos.vec, alpha);
            const col = view.get(Comps.Collider, entity);
            const half_w = col.width / 2;
            const aabb_min = Vec3.new(render_pos.x - half_w, render_pos.y, render_pos.z - half_w);
            const aabb_max = Vec3.new(render_pos.x + half_w, render_pos.y + col.height, render_pos.z + half_w);
            if (!frustum.intersectsAABB(aabb_min, aabb_max)) continue;
            const bone_off = anim_map.get(@as(u32, @intCast(entity.index))) orelse -1;
            var entity_transform = Mat4.fromTranslate(render_pos);
            if (game.registry.tryGet(Comps.Facing, entity)) |facing| {
                entity_transform = Mat4.mul(entity_transform, Mat4.fromRotationY(facing.yaw));
            }
            game.res_manager.entities_data[entity_idx] = EntityData{
                .transform = entity_transform,
                .bone_offset = bone_off,
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
                            .bone_offset = bone_off,
                        };

                        game.res_manager.draw_batches[game.res_manager.draw_batch_count] = .{
                            .vertex_buffer = primitive.vertex_buffer,
                            .index_buffer = primitive.index_buffer,
                            .index_count = primitive.index_count,
                            .bind_group = primitive.material.bind_group,
                            .instance_idx = ins_idx,
                            .vertex_format = if (model.skeleton != null) .skinned_model else .static_model,
                        };
                        game.res_manager.draw_batch_count += 1;
                        ins_idx += 1;
                    }
                }
            }
            entity_idx += 1;
        }

        // 为区块预留实体/实例
        const chunk_entity_idx: u32 = entity_idx;
        game.res_manager.entities_data[chunk_entity_idx] = EntityData{
            .transform = Mat4.fromTranslate(Vec3.new(0, 0, 0)),
        };
        entity_idx += 1;

        chunk_instance_idx = ins_idx;
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
    }

    // ========== 渲染通道 ==========
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

    if (world) {
        // 绘制天空（全屏三角，无 vertex/index buffer）
        Wgpu.wgpuRenderPassEncoderSetPipeline(pass, game.sky_pipeline.handle);
        Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, game.sky_pipeline.bind_group, 0, null);
        Wgpu.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);

        Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, game.render_pipeline.global_bind_group, 0, null);
        if (game.render_pipeline.shadow_bind_group) |sg| {
            Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 2, sg, 0, null); // group 2 = 阴影贴图 + 比较采样器
        }

        // 绘制所有模型实体
        for (game.res_manager.draw_batches[0..game.res_manager.draw_batch_count]) |batch| {
            const pipe = switch (batch.vertex_format) {
                .static_model => game.render_pipeline.pipeline_static,
                .skinned_model => game.render_pipeline.pipeline_skinned,
            };
            Wgpu.wgpuRenderPassEncoderSetPipeline(pass, pipe);
            Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, batch.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(batch.vertex_buffer));
            Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, batch.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(batch.index_buffer));
            Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, batch.bind_group, 0, null);
            Wgpu.wgpuRenderPassEncoderDrawIndexed(pass, batch.index_count, 1, 0, 0, batch.instance_idx);
        }

        // 绘制所有区块（使用 static pipeline）
        Wgpu.wgpuRenderPassEncoderSetPipeline(pass, game.render_pipeline.pipeline_static);
        var chunk_it = game.block_world.chunks.iterator();
        while (chunk_it.next()) |entry| {
            const loaded = &entry.value_ptr.*;
            const origin = entry.key_ptr.*;
            const min = Vec3.new(@as(f32, @floatFromInt(origin.x)), 0, @as(f32, @floatFromInt(origin.z)));
            const max = Vec3.new(@as(f32, @floatFromInt(origin.x + 16)), 256, @as(f32, @floatFromInt(origin.z + 16)));
            if (!frustum.intersectsAABB(min, max)) continue; // 视锥体裁剪
            var mesh_it = loaded.mesh_cache.meshes.iterator();
            while (mesh_it.next()) |mesh_entry| {
                const mat_idx = mesh_entry.key_ptr.*;
                const mesh = mesh_entry.value_ptr;
                if (mesh.vertex_count == 0) continue;

                if (game.block_world.material_registry.materials[@intCast(mat_idx)]) |*global_mat| {
                    Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, mesh.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(mesh.vertex_buffer));
                    Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, mesh.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(mesh.index_buffer));
                    Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, global_mat.material.bind_group, 0, null);
                    Wgpu.wgpuRenderPassEncoderDrawIndexed(pass, mesh.index_count, 1, 0, 0, chunk_instance_idx);
                }
            }
        }
    }

    // 下层 UI（槽位背景等）
    if (game.ui_system.bg_index_count > 0) {
        const ui = &game.ui_system;
        Wgpu.wgpuRenderPassEncoderSetPipeline(pass, ui.render_pipeline.handle);
        Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, ui.render_pipeline.bind_group, 0, null);
        Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, ui.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(ui.vertex_buffer));
        Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, ui.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(ui.index_buffer));
        Wgpu.wgpuRenderPassEncoderDrawIndexed(pass, @as(u32, @intCast(ui.bg_index_count)), 1, 0, 0, 0);
    }

    // 图标纹理渲染（中间层）
    if (game.icon_atlas.vertex_count > 0) {
        game.icon_atlas.upload(game.gctx.queue);
        Wgpu.wgpuRenderPassEncoderSetPipeline(pass, game.icon_atlas.pipeline.handle);
        Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, game.icon_atlas.pipeline.bind_group, 0, null);
        Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, game.icon_atlas.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(game.icon_atlas.vertex_buffer));
        Wgpu.wgpuRenderPassEncoderDraw(pass, @as(u32, @intCast(game.icon_atlas.vertex_count)), 1, 0, 0);
    }

    // 上层 UI（文字、前景等）
    if (game.ui_system.index_count > game.ui_system.bg_index_count) {
        const ui = &game.ui_system;
        Wgpu.wgpuRenderPassEncoderSetPipeline(pass, ui.render_pipeline.handle);
        Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, ui.render_pipeline.bind_group, 0, null);
        Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, ui.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(ui.vertex_buffer));
        Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, ui.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(ui.index_buffer));
        Wgpu.wgpuRenderPassEncoderDrawIndexed(pass, @as(u32, @intCast(ui.index_count - ui.bg_index_count)), 1, @as(u32, @intCast(ui.bg_index_count)), 0, 0);
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

pub fn draw(game: *Game) void {
    drawFrame(game, true);
}
pub fn drawUI(game: *Game) void {
    drawFrame(game, false);
}

const Imports = @import("imports.zig");

const Wgpu = Imports.Wgpu;

const Algebra = Imports.Algebra;
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;

const RendCTX = Imports.RendCTX;
const EntityData = RendCTX.EntityData;
const InstanceData = RendCTX.InstanceData;

const Frustum = @import("frustum.zig").Frustum;
const Game = Imports.Game;
const std = @import("std");

const Comps = Imports.Comps;

const TICK_DT = @import("block_world.zig").TICK_DT;
