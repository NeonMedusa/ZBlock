// animation.zig — CPU 骨骼动画更新系统
const std = @import("std");
const Allocator = std.mem.Allocator;
const Mat4 = @import("algebra.zig").Mat4;
const Vec3 = @import("algebra.zig").Vec3;
const Quat = @import("algebra.zig").Quat;
const Wgpu = @import("imports.zig").Wgpu;
const rend_ctx = @import("rend_ctx.zig");
const AnimClip = rend_ctx.AnimClip;
const Skeleton = rend_ctx.Skeleton;
const MAX_BONES = rend_ctx.MAX_BONES;
const MAX_ANIM_ENTITIES = rend_ctx.MAX_ANIM_ENTITIES;
const TOTAL_BONES = rend_ctx.TOTAL_BONES;
const Comps = @import("components.zig").Components;
const ResManager = rend_ctx.ResManager;
const Imports = @import("imports.zig");
const ECS = Imports.ECS;

pub const AnimationSystem = struct {
    allocator: Allocator,
    next_bone_offset: u32 = 0,
    max_bone_slot: u32 = 0,

    bone_prev: []Mat4,
    bone_current: []Mat4,
    bone_pool_buffer: Wgpu.WGPUBuffer,

    pub fn init(allocator: Allocator, device: Wgpu.WGPUDevice) !AnimationSystem {
        const bone_prev = try allocator.alloc(Mat4, TOTAL_BONES);
        const bone_current = try allocator.alloc(Mat4, TOTAL_BONES);
        @memset(bone_prev, Mat4.identity);
        @memset(bone_current, Mat4.identity);

        const bone_pool_buffer = Wgpu.wgpuDeviceCreateBuffer(device, &.{
            .size = @sizeOf(Mat4) * TOTAL_BONES,
            .usage = Wgpu.WGPUBufferUsage_Storage | Wgpu.WGPUBufferUsage_CopyDst,
            .mappedAtCreation = 0,
        });

        return AnimationSystem{
            .allocator = allocator,
            .bone_prev = bone_prev,
            .bone_current = bone_current,
            .bone_pool_buffer = bone_pool_buffer,
        };
    }

    pub fn deinit(self: *AnimationSystem) void {
        self.allocator.free(self.bone_prev);
        self.allocator.free(self.bone_current);
        Wgpu.wgpuBufferRelease(self.bone_pool_buffer);
    }

    /// 分配一个骨骼槽位（每实体一个，内含 MAX_BONES 个矩阵）
    pub fn allocBoneSlot(self: *AnimationSystem) ?u32 {
        const slot = self.next_bone_offset;
        if (slot >= MAX_ANIM_ENTITIES) return null;
        self.next_bone_offset += 1;
        return slot * MAX_BONES;
    }

    /// 在物理 tick 开始时调用：bone_prev = bone_current
    pub fn swapBuffers(self: *AnimationSystem) void {
        @memcpy(self.bone_prev[0..self.max_bone_slot], self.bone_current[0..self.max_bone_slot]);
    }

    /// 物理 tick 层：遍历 ECS，更新所有实体的 bone_current
    pub fn update(self: *AnimationSystem, registry: *ECS.Registry, res_manager: *ResManager, dt: f32) void {
        self.max_bone_slot = 0;
        var view = registry.view(.{ Comps.AnimationState, Comps.ModelName }, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const state = view.get(Comps.AnimationState, entity);
            const model_name = view.get(Comps.ModelName, entity);
            const model = res_manager.getOrLoadModel(model_name.id);
            const skel = model.skeleton orelse continue;
            const clip = resolveClip(model, state.clip_name) orelse continue;

            state.time += dt * state.speed;
            if (state.time > clip.duration) {
                state.time = @mod(state.time, clip.duration);
            }

            evaluateClip(self, skel, clip, state.bone_offset, state.time);

            const end = state.bone_offset + skel.joint_count;
            if (end > self.max_bone_slot) self.max_bone_slot = end;
        }
    }

    /// 渲染层：lerp 后上传到 GPU
    pub fn upload(self: *AnimationSystem, queue: Wgpu.WGPUQueue, alpha: f32) void {
        const count = self.max_bone_slot;
        if (count == 0) return;
        for (0..count) |i| {
            self.bone_prev[i] = Mat4.lerp(self.bone_prev[i], self.bone_current[i], alpha);
        }
        Wgpu.wgpuQueueWriteBuffer(
            queue,
            self.bone_pool_buffer,
            0,
            self.bone_prev.ptr,
            @sizeOf(Mat4) * count,
        );
    }
};

fn resolveClip(model: *const rend_ctx.Model, name: []const u8) ?*AnimClip {
    for (model.animations) |*clip| {
        if (std.mem.eql(u8, clip.name, name)) return clip;
    }
    if (model.anim_mapping_loaded) {
        const mapped = model.anim_mapping.get(name) orelse return null;
        for (model.animations) |*clip| {
            if (std.mem.eql(u8, clip.name, mapped)) return clip;
        }
    }
    if (model.animations.len > 0) return &model.animations[0];
    return null;
}

fn evaluateClip(sys: *AnimationSystem, skel: Skeleton, clip: *AnimClip, bone_offset: u32, time: f32) void {
    var joint_trans: [MAX_BONES]Vec3 = undefined;
    var joint_rot: [MAX_BONES]Quat = undefined;
    var joint_scale: [MAX_BONES]Vec3 = undefined;
    for (0..skel.joint_count) |i| {
        joint_trans[i] = Vec3.zero;
        joint_rot[i] = Quat.identity;
        joint_scale[i] = Vec3.new(1, 1, 1);
    }

    for (clip.channels) |*ch| {
        const joint = ch.joint_index;
        if (joint >= skel.joint_count) continue;

        switch (ch.interpolation) {
            .linear => {
                const prev, const next, const t = findKeyframe(ch.times, time);
                if (ch.stride == 3) {
                    const p0 = ch.values[prev * 3 .. prev * 3 + 3];
                    const p1 = ch.values[next * 3 .. next * 3 + 3];
                    const val = Vec3.lerp(Vec3.new(p0[0], p0[1], p0[2]), Vec3.new(p1[0], p1[1], p1[2]), t);
                    switch (ch.property) {
                        .translation => joint_trans[joint] = val,
                        .scale => joint_scale[joint] = val,
                        else => {},
                    }
                } else if (ch.stride == 4) {
                    const q0 = Quat.init(ch.values[prev * 4], ch.values[prev * 4 + 1], ch.values[prev * 4 + 2], ch.values[prev * 4 + 3]);
                    const q1 = Quat.init(ch.values[next * 4], ch.values[next * 4 + 1], ch.values[next * 4 + 2], ch.values[next * 4 + 3]);
                    joint_rot[joint] = Quat.slerp(q0, q1, t);
                }
            },
            .step => {
                const idx = prevIdx(ch.times, time);
                if (ch.stride == 3) {
                    const p = ch.values[idx * 3 ..];
                    const val = Vec3.new(p[0], p[1], p[2]);
                    switch (ch.property) {
                        .translation => joint_trans[joint] = val,
                        .scale => joint_scale[joint] = val,
                        else => {},
                    }
                } else if (ch.stride == 4) {
                    const p = ch.values[idx * 4 ..];
                    joint_rot[joint] = Quat.init(p[0], p[1], p[2], p[3]);
                }
            },
            .cubic => {
                // TODO: 未用 CUBICSPLINE 资产实测，如有动画异常请排查此处
                const prev, const next, const t = findKeyframe(ch.times, time);
                const ofs = ch.stride;
                if (ofs == 3) {
                    // Hermite 插值：p(t) = h00×v0 + h10×m0 + h01×v1 + h11×m1
                    const v0 = ch.values[prev * ofs * 3 + ofs .. prev * ofs * 3 + ofs + 3];
                    const v1 = ch.values[next * ofs * 3 + ofs .. next * ofs * 3 + ofs + 3];
                    const m0 = ch.values[prev * ofs * 3 + 2 * ofs .. prev * ofs * 3 + 2 * ofs + 3];
                    const m1 = ch.values[next * ofs * 3 .. next * ofs * 3 + ofs];

                    const t2 = t * t;
                    const t3 = t2 * t;
                    const h00 = 2 * t3 - 3 * t2 + 1;
                    const h10 = t3 - 2 * t2 + t;
                    const h01 = -2 * t3 + 3 * t2;
                    const h11 = t3 - t2;

                    const va = Vec3.new(v0[0], v0[1], v0[2]);
                    const vb = Vec3.new(v1[0], v1[1], v1[2]);
                    const ta = Vec3.new(m0[0], m0[1], m0[2]);
                    const tb = Vec3.new(m1[0], m1[1], m1[2]);

                    var val = Vec3.scale(va, h00);
                    val = Vec3.add(val, Vec3.scale(ta, h10));
                    val = Vec3.add(val, Vec3.scale(vb, h01));
                    val = Vec3.add(val, Vec3.scale(tb, h11));

                    switch (ch.property) {
                        .translation => joint_trans[joint] = val,
                        .scale => joint_scale[joint] = val,
                        else => {},
                    }
                } else if (ofs == 4) {
                    // 四元数 CUBICSPLINE 暂用 slerp 回退，待 Squad 实现
                    const p0 = ch.values[prev * ofs * 3 + ofs .. prev * ofs * 3 + ofs + 4];
                    const p1 = ch.values[next * ofs * 3 + ofs .. next * ofs * 3 + ofs + 4];
                    const q0 = Quat.init(p0[0], p0[1], p0[2], p0[3]);
                    const q1 = Quat.init(p1[0], p1[1], p1[2], p1[3]);
                    joint_rot[joint] = Quat.slerp(q0, q1, t);
                }
            },
        }
    }

    // TRS compositing: local_mats[i] = T × R × S
    var local_mats: [MAX_BONES]Mat4 = undefined;
    for (0..skel.joint_count) |i| {
        const t = Mat4.fromTranslate(joint_trans[i]);
        const r = joint_rot[i].toMat4();
        const s = Mat4.fromScale(joint_scale[i]);
        local_mats[i] = Mat4.mul(t, Mat4.mul(r, s));
    }

    // FK + IBM
    for (0..skel.joint_count) |i| {
        var world = local_mats[i];
        var parent = skel.parent_indices[i];
        while (parent >= 0) {
            world = Mat4.mul(local_mats[@as(usize, @intCast(parent))], world);
            parent = skel.parent_indices[@as(usize, @intCast(parent))];
        }
        sys.bone_current[bone_offset + i] = Mat4.mul(world, skel.inverse_bind_matrices[i]);
    }
}

fn prevIdx(times: []const f32, time: f32) usize {
    var i: usize = 0;
    while (i + 1 < times.len and times[i + 1] <= time) i += 1;
    return i;
}

fn findKeyframe(times: []const f32, time: f32) struct { usize, usize, f32 } {
    const prev = prevIdx(times, time);
    const next = @min(prev + 1, times.len - 1);
    const t0 = times[prev];
    const t1 = times[next];
    const t = if (t1 > t0) (time - t0) / (t1 - t0) else 0.0;
    return .{ prev, next, t };
}
