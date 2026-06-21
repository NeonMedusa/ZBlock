//racast.zig
const std = @import("std");
const Vec3 = @import("algebra.zig").Vec3;
const Vec3i = @import("algebra.zig").Vec3i;
const BlockId = @import("block_registry.zig").BlockId;
const BlockWorld = @import("block_world.zig").BlockWorld;
const ECS = @import("zigecs");
const Comps = @import("components.zig").Components;
const Bvh = @import("bvh.zig").Bvh;

pub const Ray = struct {
    origin: Vec3,
    direction: Vec3, // 必须归一化

    pub fn init(origin: Vec3, direction: Vec3) Ray {
        return .{
            .origin = origin,
            .direction = direction.norm(),
        };
    }

    pub fn pointAt(self: Ray, t: f32) Vec3 {
        return self.origin.add(self.direction.scale(t));
    }
};

pub const HitResult = struct {
    hit: bool,
    block_pos: Vec3i, // 被击中方块的世界坐标 (整数)
    face_normal: Vec3i, // 面法线方向 (单位向量，整数)
    point: Vec3, // 命中点世界坐标 (浮点)
    distance: f32, // 从射线原点到命中点的距离
};

/// 利用 DDA 算法在体素世界中执行射线检测。
/// `world`: 方块世界（支持多区块）
/// `ray`: 世界空间射线
/// `max_dist`: 最大检测距离
pub fn raycastWorld(world: *BlockWorld, ray: Ray, max_dist: f32) HitResult {
    const dir = ray.direction.norm();
    const origin = ray.origin;

    // 零方向射线直接返回未命中
    if (dir.len2() < 1e-12)
        return .{
            .hit = false,
            .block_pos = Vec3i.zero,
            .face_normal = Vec3i.zero,
            .point = Vec3.zero,
            .distance = 0,
        };

    const epsilon: f32 = 1e-6;

    // 当前体素坐标
    var voxel_x = @as(i32, @intFromFloat(@floor(origin.x)));
    var voxel_y = @as(i32, @intFromFloat(@floor(origin.y)));
    var voxel_z = @as(i32, @intFromFloat(@floor(origin.z)));

    // 步进方向
    const step_x: i32 = if (dir.x > 0) 1 else -1;
    const step_y: i32 = if (dir.y > 0) 1 else -1;
    const step_z: i32 = if (dir.z > 0) 1 else -1;

    // 提前判断各轴是否几乎为零
    const is_zero_x = @abs(dir.x) < epsilon;
    const is_zero_y = @abs(dir.y) < epsilon;
    const is_zero_z = @abs(dir.z) < epsilon;

    // 到达下一个体素边界的 t 增量
    const t_delta_x: f32 = if (is_zero_x) std.math.floatMax(f32) else @abs(1.0 / dir.x);
    const t_delta_y: f32 = if (is_zero_y) std.math.floatMax(f32) else @abs(1.0 / dir.y);
    const t_delta_z: f32 = if (is_zero_z) std.math.floatMax(f32) else @abs(1.0 / dir.z);

    // 当前体素到下一个边界的 t
    var t_max_x: f32 = if (is_zero_x) std.math.floatMax(f32) else blk: {
        if (step_x > 0) {
            break :blk (@as(f32, @floatFromInt(voxel_x + 1)) - origin.x) / dir.x;
        } else {
            break :blk (@as(f32, @floatFromInt(voxel_x)) - origin.x) / dir.x;
        }
    };
    var t_max_y: f32 = if (is_zero_y) std.math.floatMax(f32) else blk: {
        if (step_y > 0) {
            break :blk (@as(f32, @floatFromInt(voxel_y + 1)) - origin.y) / dir.y;
        } else {
            break :blk (@as(f32, @floatFromInt(voxel_y)) - origin.y) / dir.y;
        }
    };
    var t_max_z: f32 = if (is_zero_z) std.math.floatMax(f32) else blk: {
        if (step_z > 0) {
            break :blk (@as(f32, @floatFromInt(voxel_z + 1)) - origin.z) / dir.z;
        } else {
            break :blk (@as(f32, @floatFromInt(voxel_z)) - origin.z) / dir.z;
        }
    };

    var last_step: ?enum { x, y, z } = null;

    // 步数限制：3 * max_dist + 20 足够应对任何角度
    const max_steps = @as(usize, @intFromFloat(max_dist * 3.0)) + 20;
    var steps: usize = 0;

    while (steps < max_steps) : (steps += 1) {
        // 检查当前体素
        const pos = Vec3.new(
            @as(f32, @floatFromInt(voxel_x)) + 0.5,
            @as(f32, @floatFromInt(voxel_y)) + 0.5,
            @as(f32, @floatFromInt(voxel_z)) + 0.5,
        );
        const block_id = world.getBlockAt(pos);
        if (block_id != BlockId.fromName("air") and block_id.prototype().is_solid) {
            // 计算法线
            var face_normal = Vec3i.zero;
            if (last_step) |axis| {
                switch (axis) {
                    .x => face_normal.x = -step_x,
                    .y => face_normal.y = -step_y,
                    .z => face_normal.z = -step_z,
                }
            } else {
                // 起点在方块内部：用射线反方向估计法线
                face_normal.x = if (dir.x > 0) -1 else 1;
                face_normal.y = if (dir.y > 0) -1 else 1;
                face_normal.z = if (dir.z > 0) -1 else 1;
            }

            // 命中距离
            const t = @min(@min(t_max_x, t_max_y), t_max_z);
            if (t > max_dist) break;

            const hit_point = ray.pointAt(t);
            return .{
                .hit = true,
                .block_pos = Vec3i.new(voxel_x, voxel_y, voxel_z),
                .face_normal = face_normal,
                .point = hit_point,
                .distance = t,
            };
        }

        // 步进到下一个体素，一次比较确定最小 t_max
        if (t_max_x < t_max_y) {
            if (t_max_x < t_max_z) {
                if (t_max_x > max_dist) break;
                voxel_x += step_x;
                t_max_x += t_delta_x;
                last_step = .x;
            } else {
                if (t_max_z > max_dist) break;
                voxel_z += step_z;
                t_max_z += t_delta_z;
                last_step = .z;
            }
        } else {
            if (t_max_y < t_max_z) {
                if (t_max_y > max_dist) break;
                voxel_y += step_y;
                t_max_y += t_delta_y;
                last_step = .y;
            } else {
                if (t_max_z > max_dist) break;
                voxel_z += step_z;
                t_max_z += t_delta_z;
                last_step = .z;
            }
        }
    }

    return .{
        .hit = false,
        .block_pos = Vec3i.zero,
        .face_normal = Vec3i.zero,
        .point = Vec3.zero,
        .distance = 0,
    };
}

pub const EntityHitResult = struct {
    hit: bool,
    entity: ECS.Entity,
    distance: f32,
    point: Vec3,
};

/// 射线与实体碰撞箱的检测，返回最近的命中实体
pub fn raycastEntities(registry: *ECS.Registry, bvh: *const Bvh, ray: Ray, max_dist: f32) EntityHitResult {
    var closest: EntityHitResult = .{ .hit = false, .entity = undefined, .distance = max_dist, .point = Vec3.zero };

    const RaycastCtx = struct {
        registry: *ECS.Registry,
        closest: *EntityHitResult,
        max_dist: f32,
        ray: Ray,
        fn callback(ctx: @This(), entity: ECS.Entity, t: f32) bool {
            if (t > ctx.max_dist or t <= 0) return false;
            if (!ctx.registry.valid(entity)) return false;
            const pos = ctx.registry.get(Comps.Position, entity);
            const col = ctx.registry.get(Comps.Collider, entity);
            const half_w = col.width / 2.0;
            const t_tight = rayAABBEx(pos.vec.x - half_w, pos.vec.x + half_w, pos.vec.y, pos.vec.y + col.height, pos.vec.z - half_w, pos.vec.z + half_w, ctx.ray.origin, ctx.ray.direction);
            if (t_tight == null or t_tight.? > ctx.closest.distance or t_tight.? <= 0) return false;
            ctx.closest.* = .{
                .hit = true,
                .entity = entity,
                .distance = t_tight.?,
                .point = ctx.ray.pointAt(t_tight.?),
            };
            return false;
        }
    };
    bvh.raycast(RaycastCtx{ .registry = registry, .closest = &closest, .max_dist = max_dist, .ray = ray }, RaycastCtx.callback, ray.origin, ray.direction);
    return closest;
}

/// 带独立参数的射线-AABB 精测（避免创建 Ray 对象）
pub fn rayAABBEx(min_x: f32, max_x: f32, min_y: f32, max_y: f32, min_z: f32, max_z: f32, origin: Vec3, dir: Vec3) ?f32 {
    const tx1 = (min_x - origin.x) / dir.x;
    const tx2 = (max_x - origin.x) / dir.x;
    var tmin = @min(tx1, tx2);
    var tmax = @max(tx1, tx2);

    const ty1 = (min_y - origin.y) / dir.y;
    const ty2 = (max_y - origin.y) / dir.y;
    tmin = @max(tmin, @min(ty1, ty2));
    tmax = @min(tmax, @max(ty1, ty2));

    const tz1 = (min_z - origin.z) / dir.z;
    const tz2 = (max_z - origin.z) / dir.z;
    tmin = @max(tmin, @min(tz1, tz2));
    tmax = @min(tmax, @max(tz1, tz2));

    if (tmax >= tmin and tmax >= 0) return @max(tmin, 0);
    return null;
}
