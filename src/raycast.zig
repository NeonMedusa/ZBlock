const std = @import("std");
const Vec3 = @import("algebra.zig").Vec3;
const Vec3i = @import("algebra.zig").Vec3i;
const BlockId = @import("block_world.zig").BlockId;
const Chunk = @import("block_world.zig").Chunk;
const getBlockAt = @import("block_world.zig").BlockWorld.getBlockAt;

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
/// `chunk`: 当前区块（可扩展为世界查询函数）
/// `ray`: 世界空间射线
/// `max_dist`: 最大检测距离
pub fn raycastWorld(chunk: *Chunk, ray: Ray, max_dist: f32) HitResult {
    // 确保方向为单位向量
    const dir = ray.direction.norm();
    const origin = ray.origin;

    // 当前体素坐标
    var voxel_x = @as(i32, @intFromFloat(@floor(origin.x)));
    var voxel_y = @as(i32, @intFromFloat(@floor(origin.y)));
    var voxel_z = @as(i32, @intFromFloat(@floor(origin.z)));

    // 步进方向 (根据射线方向)
    const step_x: i32 = if (dir.x > 0) 1 else -1;
    const step_y: i32 = if (dir.y > 0) 1 else -1;
    const step_z: i32 = if (dir.z > 0) 1 else -1;

    // 射线到达下一个体素边界所需的距离 t
    // 如果方向分量接近 0，设为极大值以忽略该轴
    const t_delta_x: f32 = if (@abs(dir.x) < 1e-6) std.math.floatMax(f32) else @abs(1.0 / dir.x);
    const t_delta_y: f32 = if (@abs(dir.y) < 1e-6) std.math.floatMax(f32) else @abs(1.0 / dir.y);
    const t_delta_z: f32 = if (@abs(dir.z) < 1e-6) std.math.floatMax(f32) else @abs(1.0 / dir.z);

    // 当前体素到下一个边界的 t
    var t_max_x: f32 = if (step_x > 0)
        (@as(f32, @floatFromInt(voxel_x + 1)) - origin.x) / dir.x
    else
        (@as(f32, @floatFromInt(voxel_x)) - origin.x) / dir.x;
    var t_max_y: f32 = if (step_y > 0)
        (@as(f32, @floatFromInt(voxel_y + 1)) - origin.y) / dir.y
    else
        (@as(f32, @floatFromInt(voxel_y)) - origin.y) / dir.y;
    var t_max_z: f32 = if (step_z > 0)
        (@as(f32, @floatFromInt(voxel_z + 1)) - origin.z) / dir.z
    else
        (@as(f32, @floatFromInt(voxel_z)) - origin.z) / dir.z;

    var last_step: ?enum { x, y, z } = null;

    // 最大步进次数，防止无限循环
    const max_steps = @as(usize, @intFromFloat(max_dist * 2.0)) + 10;
    var steps: usize = 0;

    while (steps < max_steps) : (steps += 1) {
        // 检查当前体素是否为固体
        const pos = Vec3.new(
            @as(f32, @floatFromInt(voxel_x)) + 0.5,
            @as(f32, @floatFromInt(voxel_y)) + 0.5,
            @as(f32, @floatFromInt(voxel_z)) + 0.5,
        );
        const block_id = getBlockAt(chunk, pos);
        if (block_id != BlockId.fromName("air") and block_id.prototype().is_solid) {
            // 命中
            var face_normal = Vec3i.zero;
            if (last_step) |axis| {
                switch (axis) {
                    .x => face_normal.x = -step_x,
                    .y => face_normal.y = -step_y,
                    .z => face_normal.z = -step_z,
                }
            }

            // 计算精确命中点 (取当前 t_max 的最小值)
            const t = if (t_max_x <= t_max_y and t_max_x <= t_max_z) t_max_x else if (t_max_y <= t_max_x and t_max_y <= t_max_z) t_max_y else t_max_z;
            const hit_point = ray.pointAt(t);

            // 如果距离超出最大范围，视为未命中
            if (t > max_dist) break;

            return .{
                .hit = true,
                .block_pos = Vec3i.new(voxel_x, voxel_y, voxel_z),
                .face_normal = face_normal,
                .point = hit_point,
                .distance = t,
            };
        }

        // 步进到下一个体素
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

        // 如果当前最小 t 已经超过最大距离，停止
        const min_t = @min(@min(t_max_x, t_max_y), t_max_z);
        if (min_t > max_dist) break;
    }

    return .{ .hit = false, .block_pos = Vec3i.zero, .face_normal = Vec3i.zero, .point = Vec3.zero, .distance = 0 };
}
