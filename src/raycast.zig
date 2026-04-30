//racast.zig
const std = @import("std");
const Vec3 = @import("algebra.zig").Vec3;
const Vec3i = @import("algebra.zig").Vec3i;
const BlockId = @import("block_world.zig").BlockId;
const BlockWorld = @import("block_world.zig").BlockWorld;

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

    // 到达下一个体素边界的 t 增量
    const t_delta_x: f32 = if (@abs(dir.x) < epsilon) std.math.floatMax(f32) else @abs(1.0 / dir.x);
    const t_delta_y: f32 = if (@abs(dir.y) < epsilon) std.math.floatMax(f32) else @abs(1.0 / dir.y);
    const t_delta_z: f32 = if (@abs(dir.z) < epsilon) std.math.floatMax(f32) else @abs(1.0 / dir.z);

    // 当前体素到下一个边界的 t
    var t_max_x: f32 = if (@abs(dir.x) < epsilon) std.math.floatMax(f32) else blk: {
        if (step_x > 0) {
            break :blk (@as(f32, @floatFromInt(voxel_x + 1)) - origin.x) / dir.x;
        } else {
            break :blk (@as(f32, @floatFromInt(voxel_x)) - origin.x) / dir.x;
        }
    };
    var t_max_y: f32 = if (@abs(dir.y) < epsilon) std.math.floatMax(f32) else blk: {
        if (step_y > 0) {
            break :blk (@as(f32, @floatFromInt(voxel_y + 1)) - origin.y) / dir.y;
        } else {
            break :blk (@as(f32, @floatFromInt(voxel_y)) - origin.y) / dir.y;
        }
    };
    var t_max_z: f32 = if (@abs(dir.z) < epsilon) std.math.floatMax(f32) else blk: {
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

        // 步进到下一个体素 (取最小的 t_max)
        if (t_max_x < t_max_y) {
            if (t_max_x < t_max_z) {
                voxel_x += step_x;
                t_max_x += t_delta_x;
                last_step = .x;
            } else {
                voxel_z += step_z;
                t_max_z += t_delta_z;
                last_step = .z;
            }
        } else {
            if (t_max_y < t_max_z) {
                voxel_y += step_y;
                t_max_y += t_delta_y;
                last_step = .y;
            } else {
                voxel_z += step_z;
                t_max_z += t_delta_z;
                last_step = .z;
            }
        }

        // 提前终止：当前最小的 t 已经超出最大距离
        const min_t = @min(@min(t_max_x, t_max_y), t_max_z);
        if (min_t > max_dist) break;
    }

    return .{
        .hit = false,
        .block_pos = Vec3i.zero,
        .face_normal = Vec3i.zero,
        .point = Vec3.zero,
        .distance = 0,
    };
}
