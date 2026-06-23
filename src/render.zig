const io = @import("imports.zig").io;
// render.zig
/// 渲染帧（comptime world 控制是否渲染 3D 世界 vs 仅 UI）
fn drawFrame(game: *Game, comptime world: bool) void {
    var surface_texture: Wgpu.WGPUSurfaceTexture = undefined;
    Wgpu.wgpuSurfaceGetCurrentTexture(game.gctx.surface, &surface_texture);
    const surface_texture_view = Wgpu.wgpuTextureCreateView(surface_texture.texture, null);
    defer Wgpu.wgpuTextureViewRelease(surface_texture_view);

    const encoder = Wgpu.wgpuDeviceCreateCommandEncoder(game.gctx.device, null);
    var chunk_instance_idx: u32 = 0; // 用于区块实例索引（阴影+主渲染共享）
    const frustum = if (world) Frustum.fromViewProj(Mat4.mul(game.ubo.proj_matrix, game.ubo.view_matrix)) else undefined;

    const sky_time = @as(f32, @floatFromInt(game.server.tick_count)) * TICK_DT + game.accumulator;
    // 从天空状态同步光照数据到 ubo
    game.ubo.sun_direction = game.sky_pipeline.state.sun_direction;
    game.ubo.sun_intensity = game.sky_pipeline.state.sun_intensity;
    game.ubo.sun_color = game.sky_pipeline.state.sun_color;
    game.ubo.moon_brightness = game.sky_pipeline.state.moon_brightness;
    game.ubo.moon_color = game.sky_pipeline.state.moon_color;
    game.ubo.ambient_ground = game.sky_pipeline.state.ambient_ground;
    game.ubo.time = sky_time;

    var chunk_origins: [4096]Vec3i = undefined;
    var chunk_count: u32 = 0;
    if (world) {
        // 持锁整帧，保护 chunks map 不被服务端线程修改
        game.server.block_world.chunk_mutex.lockSharedUncancelable(io);
        {
            var chunk_it = game.server.block_world.chunks.iterator();
            while (chunk_it.next()) |entry| {
                if (chunk_count >= chunk_origins.len) break;
                chunk_origins[chunk_count] = entry.key_ptr.*;
                chunk_count += 1;
            }
        }
        // inverse(proj × view_rot)：从 NDC 方向反算世界方向（全屏三角 cubemap）
        var view_rot = game.ubo.view_matrix;
        view_rot.m[3][0] = 0;
        view_rot.m[3][1] = 0;
        view_rot.m[3][2] = 0;
        const sky_mat = Mat4.inverse(Mat4.mul(game.ubo.proj_matrix, view_rot));
        game.sky_pipeline.updateUniform(&game.gctx, sky_mat, sky_time);

        // 阴影光源方向：太阳在水平线上方用太阳，否则用月亮
        const ldir = if (game.sky_pipeline.state.sun_direction.y > 0.0)
            Vec3.new(-game.sky_pipeline.state.sun_direction.x, game.sky_pipeline.state.sun_direction.y, -game.sky_pipeline.state.sun_direction.z)
        else
            Vec3.new(game.sky_pipeline.state.sun_direction.x, -game.sky_pipeline.state.sun_direction.y, game.sky_pipeline.state.sun_direction.z);
        game.shadow_pipeline.computeLightVp(ldir, game.camera.position);
        game.shadow_pipeline.updateUniform(&game.gctx);
        game.ubo.shadow_vp = game.shadow_pipeline.light_vp;

        // ========== 提前构建所有实例数据（实体 + 区块），供阴影和主渲染共享 ==========
        var entity_idx: u32 = 0;
        var ins_idx: u32 = 0;
        game.res_manager.draw_batch_count = 0;

        // 在实体遍历前，收集所有有 AnimationState 的实体
        var anim_map = std.AutoHashMap(u32, i32).init(game.allocator);
        defer anim_map.deinit();
        {
            var view = game.server.registry.view(.{Comps.AnimationState}, .{});
            var it = view.entityIterator();
            while (it.next()) |e| {
                const state = view.get(e);
                anim_map.put(@as(u32, @intCast(e.index)), @as(i32, @intCast(state.bone_offset))) catch {};
            }
        }

        // 渲染实体
        if (game.network_mode == .client) {
            // 客机：ECS view 迭代安全（无服务端线程）
            var view = game.server.registry.view(.{ Comps.ModelName, Comps.Position, Comps.Collider }, .{});
            var iter = view.entityIterator();
            while (iter.next()) |entity| {
                if (entity_idx >= 500) break;
                const model_name = view.getConst(Comps.ModelName, entity);
                const pos = view.get(Comps.Position, entity);
                const col = view.get(Comps.Collider, entity);
                // 跳过本地玩家
                if (game.server.registry.tryGet(Comps.Player, entity)) |player| {
                    if (player.id == game.server.player_id) continue;
                }
                tryRenderEntity(game, entity, &model_name, pos, col, &anim_map, &entity_idx, &ins_idx, frustum);
            }
        } else {
            // 主机/单人：从渲染快照缓冲区迭代（避免 ECS view 迭代器和服务端线程竞态）
            for (game.render_snapshots[0..game.render_snapshot_count]) |s| {
                if (entity_idx >= 500) break;
                // 跳过本地玩家
                if (s.player_id != std.math.maxInt(u32) and s.player_id == game.server.player_id) continue;
                const entity = s.entity;
                if (!game.server.registry.valid(entity)) continue;
                const model_name = game.server.registry.tryGet(Comps.ModelName, entity) orelse continue;
                const pos = game.server.registry.tryGet(Comps.Position, entity) orelse continue;
                const col = game.server.registry.tryGet(Comps.Collider, entity) orelse continue;
                tryRenderEntity(game, entity, model_name, pos, col, &anim_map, &entity_idx, &ins_idx, frustum);
            }
        }

        // 为区块预留 entity 占位
        const chunk_entity_idx: u32 = entity_idx;
        game.res_manager.entities_data[chunk_entity_idx] = EntityData{
            .transform = Mat4.fromTranslate(Vec3.new(0, 0, 0)),
        };
        entity_idx += 1;

        // 用快照构建实例数据
        chunk_instance_idx = ins_idx;
        for (chunk_origins[0..chunk_count]) |origin| {
            game.res_manager.instances_data[ins_idx] = InstanceData{
                .transform = Mat4.fromTranslate(Vec3.new(@as(f32, @floatFromInt(origin.x)), 0, @as(f32, @floatFromInt(origin.z)))),
                .entity_idx = chunk_entity_idx,
            };
            ins_idx += 1;
        }

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

        // 设置阴影管线的 ins_data buffer
        game.shadow_pipeline.setInsDataBuffer(&game.gctx, game.res_manager.instances_data_buffer);

        // ========== 阴影渲染通道 (Pass 1) ==========
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
        const shadow_frustum = Frustum.fromViewProj(game.shadow_pipeline.light_vp); // 阴影视锥体裁剪

        // 阴影 pass：使用 chunk_handle 渲染区块
        {
            var chunk_ins_idx = chunk_instance_idx;
            Wgpu.wgpuRenderPassEncoderSetPipeline(shadow_pass, game.shadow_pipeline.chunk_handle);
            for (chunk_origins[0..chunk_count]) |origin| {
                const loaded = game.server.block_world.chunks.getPtr(origin) orelse {
                    chunk_ins_idx += 1;
                    continue;
                };
                const min = Vec3.new(@as(f32, @floatFromInt(origin.x)), 0, @as(f32, @floatFromInt(origin.z)));
                const max = Vec3.new(@as(f32, @floatFromInt(origin.x + 16)), 255, @as(f32, @floatFromInt(origin.z + 16)));
                if (!shadow_frustum.intersectsAABB(min, max)) {
                    chunk_ins_idx += 1;
                    continue;
                }
                var s_mesh_it = loaded.meshes.iterator();
                while (s_mesh_it.next()) |mesh_entry| {
                    const mesh = mesh_entry.value_ptr;
                    if (mesh.vertex_count == 0) continue;
                    Wgpu.wgpuRenderPassEncoderSetVertexBuffer(shadow_pass, 0, mesh.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(mesh.vertex_buffer));
                    Wgpu.wgpuRenderPassEncoderDraw(shadow_pass, mesh.vertex_count, 1, 0, chunk_ins_idx);
                }
                chunk_ins_idx += 1;
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

    // 实体/区块实例已在阴影 pass 前构建完成

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
                .chunk => unreachable, // chunk 不走 draw batch
            };
            Wgpu.wgpuRenderPassEncoderSetPipeline(pass, pipe);
            Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, batch.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(batch.vertex_buffer));
            Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, batch.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(batch.index_buffer));
            Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, batch.bind_group, 0, null);
            Wgpu.wgpuRenderPassEncoderDrawIndexed(pass, batch.index_count, 1, 0, 0, batch.instance_idx);
        }

        // 绘制所有区块（使用 chunk pipeline，紧凑顶点格式）
        Wgpu.wgpuRenderPassEncoderSetPipeline(pass, game.render_pipeline.pipeline_chunk);
        {
            var chunk_ins_idx = chunk_instance_idx;
            for (chunk_origins[0..chunk_count]) |origin| {
                const loaded = game.server.block_world.chunks.getPtr(origin) orelse {
                    chunk_ins_idx += 1;
                    continue;
                };
                const min = Vec3.new(@as(f32, @floatFromInt(origin.x)), 0, @as(f32, @floatFromInt(origin.z)));
                const max = Vec3.new(@as(f32, @floatFromInt(origin.x + 16)), 255, @as(f32, @floatFromInt(origin.z + 16)));
                if (!frustum.intersectsAABB(min, max)) {
                    chunk_ins_idx += 1;
                    continue;
                }
                var mesh_it = loaded.meshes.iterator();
                while (mesh_it.next()) |mesh_entry| {
                    const mat_idx = mesh_entry.key_ptr.*;
                    const mesh = mesh_entry.value_ptr;
                    if (mesh.vertex_count == 0) continue;
                    if (game.server.block_world.material_registry.materials[@intCast(mat_idx)]) |*global_mat| {
                        Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, mesh.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(mesh.vertex_buffer));
                        Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, global_mat.material.bind_group, 0, null);
                        Wgpu.wgpuRenderPassEncoderDraw(pass, mesh.vertex_count, 1, 0, chunk_ins_idx);
                    }
                }
                chunk_ins_idx += 1;
            }
        }
    }
    if (world) game.server.block_world.chunk_mutex.unlockShared(io);

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

fn tryRenderEntity(
    game: *Game,
    entity: ECS.Entity,
    model_name: *const Comps.ModelName,
    pos: *Comps.Position,
    col: *const Comps.Collider,
    anim_map: *const std.AutoHashMap(u32, i32),
    entity_idx: *u32,
    ins_idx: *u32,
    frustum: Frustum,
) void {
    // 从实体 3 槽环形缓冲区查插值位置
    const now_ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const rend_time = @as(i64, @truncate(now_ns)) -| 33_000_000;
    const render_pos = pos.interpPos(rend_time);
    const half_w = col.width / 2;
    const aabb_min = Vec3.new(render_pos.x - half_w, render_pos.y, render_pos.z - half_w);
    const aabb_max = Vec3.new(render_pos.x + half_w, render_pos.y + col.height, render_pos.z + half_w);
    if (!frustum.intersectsAABB(aabb_min, aabb_max)) return;
    const bone_off = anim_map.get(@as(u32, @intCast(entity.index))) orelse -1;
    var entity_transform = Mat4.fromTranslate(render_pos);
    if (game.server.registry.tryGet(Comps.Facing, entity)) |facing| {
        entity_transform = Mat4.mul(entity_transform, Mat4.fromRotationY(facing.yaw));
    }
    game.res_manager.entities_data[entity_idx.*] = EntityData{
        .transform = entity_transform,
        .bone_offset = bone_off,
    };

    const model = game.res_manager.getOrLoadModel(model_name.id);
    for (model.nodes) |node| {
        if (node.mesh) |mesh_idx| {
            const mesh = model.meshes[mesh_idx];
            for (mesh.primitives) |primitive| {
                game.res_manager.instances_data[ins_idx.*] = .{
                    .transform = node.matrix,
                    .entity_idx = entity_idx.*,
                    .bone_offset = bone_off,
                };
                game.res_manager.draw_batches[game.res_manager.draw_batch_count] = .{
                    .vertex_buffer = primitive.vertex_buffer,
                    .index_buffer = primitive.index_buffer,
                    .index_count = primitive.index_count,
                    .bind_group = primitive.material.bind_group,
                    .instance_idx = ins_idx.*,
                    .vertex_format = if (model.skeleton != null) .skinned_model else .static_model,
                };
                game.res_manager.draw_batch_count += 1;
                ins_idx.* += 1;
            }
        }
    }
    entity_idx.* += 1;
}

const Wgpu = @import("imports.zig").Wgpu;

const Vec3 = Algebra.Vec3;
const Vec3i = Algebra.Vec3i;
const Mat4 = Algebra.Mat4;

const EntityData = RendCTX.EntityData;
const InstanceData = RendCTX.InstanceData;

const Frustum = @import("frustum.zig").Frustum;
const std = @import("std");
const Algebra = @import("algebra.zig");
const RendCTX = @import("rend_ctx.zig");
const Game = @import("game.zig");
const Comps = @import("components.zig").Components;
const ECS = @import("zigecs");

const TICK_DT = @import("block_world.zig").TICK_DT;
