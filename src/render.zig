// render.zig
// 需要为新的模型资源结构重构渲染代码:
pub fn draw(game: *Game) void {
    game.res_manager.resetRefCount();
    defer game.res_manager.removeZeroRefModel();

    // 获取当前帧的纹理
    var surface_texture: Wgpu.WGPUSurfaceTexture = undefined;
    Wgpu.wgpuSurfaceGetCurrentTexture(game.gctx.surface, &surface_texture);

    const surface_texture_view = Wgpu.wgpuTextureCreateView(surface_texture.texture, null);
    defer Wgpu.wgpuTextureViewRelease(surface_texture_view);

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

    // ========== 第一步：收集所有游戏实体和渲染实例的变换数据 ==========
    var entity_idx: u32 = 0;
    var ins_idx: u32 = 0;
    var view = game.registry.view(.{ Comps.ModelName, Comps.Position }, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const entity_pos = game.registry.getConst(Comps.Position, entity);
        game.res_manager.entities_data[entity_idx] = EntityData{
            .transform = Mat4.fromTranslate(entity_pos.vec),
        };
        const model_name = view.getConst(Comps.ModelName, entity);
        const model = game.res_manager.getOrLoadModel(model_name.string);
        for (model.nodes) |node| {
            if (node.mesh) |mesh_idx| {
                const mesh = model.meshes[mesh_idx];
                for (mesh.primitives) |_| {
                    game.res_manager.instances_data[ins_idx] = .{
                        .transform = node.matrix,
                        .entity_idx = entity_idx,
                    };
                    ins_idx += 1;
                }
            }
        }
        entity_idx += 1;
    }

    // ！！！！！为地形分配数据（使用记录的索引）
    game.res_manager.entities_data[entity_idx] = .{ .transform = Mat4.fromTranslate(Vec3.new(0, 0, 0)) };
    const terrain_translate = Mat4.fromTranslate(game.terrain.position);
    const terrain_rotation = Quat.fromAxisAngle(Vec3.unit_y, game.terrain.rotation_y).toMat4();
    const terrain_transform = terrain_translate.mul(terrain_rotation);
    game.res_manager.instances_data[ins_idx] = .{
        .transform = terrain_transform,
        .entity_idx = entity_idx,
    };
    // 更新计数（在赋值之后）
    entity_idx += 1;
    ins_idx += 1;

    // 更新entities_data_buffer
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

    // ========== 第二步：准备渲染通道 ==========
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
            .depthClearValue = 1.0,
            .depthReadOnly = 0,
            .stencilLoadOp = Wgpu.WGPULoadOp_Undefined,
            .stencilStoreOp = Wgpu.WGPUStoreOp_Undefined,
            .stencilClearValue = 0,
            .stencilReadOnly = 1,
        },
    };

    const pass = Wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &render_pass_desc);

    // ========== 第三步：设置主渲染管线并开始绘制 ==========
    Wgpu.wgpuRenderPassEncoderSetPipeline(pass, game.render_pipeline.handle);
    Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, game.render_pipeline.global_bind_group, 0, null);

    // 重新遍历并绘制（此时GPU已经收到实例数据）
    var draw_entity_idx: u32 = 0;
    var draw_ins_idx: u32 = 0;
    iter.reset(); // 重置迭代器
    while (iter.next()) |entity| {
        const model_name = game.registry.getConst(Comps.ModelName, entity);
        const model = game.res_manager.getOrLoadModel(model_name.string);
        for (model.nodes) |node| {
            if (node.mesh) |mesh_idx| {
                const mesh = model.meshes[mesh_idx];
                for (mesh.primitives) |primitive| {
                    // 设置顶点/索引缓冲区
                    Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, primitive.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(primitive.vertex_buffer));
                    Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, primitive.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(primitive.index_buffer));
                    // 设置材质绑定组
                    Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, primitive.material.bind_group, 0, null);
                    // 绘制
                    Wgpu.wgpuRenderPassEncoderDrawIndexed(
                        pass,
                        primitive.index_count,
                        1,
                        0,
                        0,
                        draw_ins_idx,
                    );
                    draw_ins_idx += 1;
                }
            }
        }
        draw_entity_idx += 1;
    }

    // ！！！绘制地形！！！！
    Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, game.terrain.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(game.terrain.vertex_buffer));
    Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, game.terrain.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(game.terrain.index_buffer));
    Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 1, game.terrain.material.bind_group, 0, null);
    Wgpu.wgpuRenderPassEncoderDrawIndexed(
        pass,
        game.terrain.index_count,
        1,
        0,
        0,
        draw_ins_idx,
    );

    // UI渲染
    Wgpu.wgpuRenderPassEncoderSetPipeline(pass, game.ui_system.render_pipeline.handle);
    Wgpu.wgpuRenderPassEncoderSetBindGroup(pass, 0, game.ui_system.render_pipeline.bind_group, 0, null);
    Wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, game.ui_system.vertex_buffer, 0, Wgpu.wgpuBufferGetSize(game.ui_system.vertex_buffer));
    Wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, game.ui_system.index_buffer, Wgpu.WGPUIndexFormat_Uint32, 0, Wgpu.wgpuBufferGetSize(game.ui_system.index_buffer));
    Wgpu.wgpuRenderPassEncoderDrawIndexed(pass, @as(u32, @intCast(game.ui_system.index_count)), 1, 0, 0, 0);

    // 结束并释放
    Wgpu.wgpuRenderPassEncoderEnd(pass);
    Wgpu.wgpuRenderPassEncoderRelease(pass);

    const command_buffer = Wgpu.wgpuCommandEncoderFinish(encoder, null);
    Wgpu.wgpuCommandEncoderRelease(encoder);
    Wgpu.wgpuQueueSubmit(game.gctx.queue, 1, &command_buffer);
    Wgpu.wgpuCommandBufferRelease(command_buffer);

    _ = Wgpu.wgpuSurfacePresent(game.gctx.surface);
    Wgpu.wgpuTextureRelease(surface_texture.texture);
}

const std = @import("std");

const Wgpu = @import("imports.zig").Wgpu;
const Gctx = @import("gctx.zig");

const Algebra = @import("algebra.zig");
const Vec3 = Algebra.Vec3;
const Quat = Algebra.Quat;
const Mat4 = Algebra.Mat4;

const RenderPipeline = @import("render_pipeline.zig");

const RendCTX = @import("rend_ctx.zig");
const SceneUniform = RendCTX.SceneUniform;
const VertexAttribute = RendCTX.VertexAttribute;
const EntityData = RendCTX.EntityData;
const InstanceData = RendCTX.InstanceData;

const UiSystem = @import("ui_system.zig");
const Imports = @import("imports.zig");
const Game = Imports.Game;
const Systems = @import("systems.zig");

const ECS = @import("zigecs");
const Comps = @import("components.zig").Components;

const Model = @import("rend_ctx.zig").Model;
