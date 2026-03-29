// raycast.zig
const std = @import("std");
const Vec3 = @import("algebra.zig").Vec3;
const Terrain = @import("terrain.zig").Terrain;

// 射线命中结果
pub const RaycastHit = struct {
    hit: bool,
    point: Vec3,
    normal: Vec3,
    distance: f32,
    hit_type: HitType,

    pub const HitType = enum {
        none,
        terrain,
        mesh,
        sphere,
        aabb,
    };
};

// 射线结构
pub const Ray = struct {
    origin: Vec3,
    direction: Vec3,

    pub fn init(origin: Vec3, direction: Vec3) Ray {
        return .{
            .origin = origin,
            .direction = direction.norm(),
        };
    }

    // 获取射线上的点
    pub fn pointAt(self: Ray, t: f32) Vec3 {
        return self.origin.add(self.direction.scale(t));
    }
};

// 射线查询接口
pub const RaycastQuery = struct {
    ray: Ray,
    max_distance: f32,

    pub fn init(ray: Ray, max_distance: f32) RaycastQuery {
        return .{
            .ray = ray,
            .max_distance = max_distance,
        };
    }

    // 对地形进行射线检测
    pub fn castTerrain(self: RaycastQuery, terrain: *Terrain) RaycastHit {
        return raycastTerrain(terrain, self.ray, self.max_distance);
    }

    // 未来可以添加更多 cast 方法
    // pub fn castMesh(self: RaycastQuery, mesh: *Mesh) RaycastHit { ... }
    // pub fn castSphere(self: RaycastQuery, sphere: *Sphere) RaycastHit { ... }
};

// 地形射线检测的具体实现
fn raycastTerrain(terrain: *Terrain, ray: Ray, max_distance: f32) RaycastHit {
    // 1. 将射线转换到地形局部空间
    const local_origin = worldToLocal(terrain, ray.origin);
    const local_dir = worldToLocalDirection(terrain, ray.direction);
    const local_ray = Ray.init(local_origin, local_dir);

    // 2. 计算与地形包围盒的交点
    const bounds_min = Vec3.new(-terrain.size_x / 2, terrain.height_min, -terrain.size_z / 2);
    const bounds_max = Vec3.new(terrain.size_x / 2, terrain.height_max, terrain.size_z / 2);

    var t_min: f32 = 0;
    var t_max: f32 = max_distance;
    if (!rayAABBIntersect(local_ray, bounds_min, bounds_max, &t_min, &t_max)) {
        return RaycastHit{
            .hit = false,
            .hit_type = .none,
            .point = Vec3.zero, // 添加缺失字段
            .normal = Vec3.zero, // 添加缺失字段
            .distance = 0, // 添加缺失字段
        };
    }

    // 3. 在局部空间中二分查找精确交点
    const t_start = t_min;
    const t_end = t_max;
    const steps: u32 = 32;

    var t = t_start;
    const step = (t_end - t_start) / @as(f32, @floatFromInt(steps));

    for (0..steps) |_| {
        const point = local_ray.pointAt(t);
        const terrain_height = terrain.getHeightLocal(point.x, point.z);

        if (point.y <= terrain_height) {
            // 找到交点，进行精确二分搜索
            const hit_t = binarySearchTerrain(terrain, local_ray, t_start, t, terrain_height);
            const hit_point_local = local_ray.pointAt(hit_t);
            const hit_point_world = localToWorld(terrain, hit_point_local);
            const normal_local = terrain.getNormalLocal(hit_point_local.x, hit_point_local.z);
            const normal_world = localToWorldDirection(terrain, normal_local);

            return RaycastHit{
                .hit = true,
                .point = hit_point_world,
                .normal = normal_world,
                .distance = hit_t,
                .hit_type = .terrain,
            };
        }

        t += step;
    }

    return RaycastHit{
        .hit = false,
        .hit_type = .none,
        .point = Vec3.zero, // 添加缺失字段
        .normal = Vec3.zero, // 添加缺失字段
        .distance = 0, // 添加缺失字段
    };
}

// 射线与 AABB 相交检测
fn rayAABBIntersect(ray: Ray, min: Vec3, max: Vec3, t_min: *f32, t_max: *f32) bool {
    var t0: f32 = -std.math.floatMax(f32);
    var t1: f32 = std.math.floatMax(f32);

    // X轴
    const inv_dir_x = 1.0 / ray.direction.x;
    var tx0 = (min.x - ray.origin.x) * inv_dir_x;
    var tx1 = (max.x - ray.origin.x) * inv_dir_x;
    if (tx0 > tx1) {
        const tmp = tx0;
        tx0 = tx1;
        tx1 = tmp;
    }
    t0 = @max(t0, tx0);
    t1 = @min(t1, tx1);

    // Y轴
    const inv_dir_y = 1.0 / ray.direction.y;
    var ty0 = (min.y - ray.origin.y) * inv_dir_y;
    var ty1 = (max.y - ray.origin.y) * inv_dir_y;
    if (ty0 > ty1) {
        const tmp = ty0;
        ty0 = ty1;
        ty1 = tmp;
    }
    t0 = @max(t0, ty0);
    t1 = @min(t1, ty1);

    // Z轴
    const inv_dir_z = 1.0 / ray.direction.z;
    var tz0 = (min.z - ray.origin.z) * inv_dir_z;
    var tz1 = (max.z - ray.origin.z) * inv_dir_z;
    if (tz0 > tz1) {
        const tmp = tz0;
        tz0 = tz1;
        tz1 = tmp;
    }
    t0 = @max(t0, tz0);
    t1 = @min(t1, tz1);

    if (t0 > t1 or t1 < 0) return false;

    t_min.* = if (t0 < 0) 0 else t0;
    t_max.* = t1;
    return true;
}

// 二分搜索精确交点
fn binarySearchTerrain(terrain: *Terrain, ray: Ray, t_start: f32, t_end: f32, target_height: f32) f32 {
    var low = t_start;
    var high = t_end;
    _ = target_height;

    for (0..16) |_| {
        const mid = (low + high) * 0.5;
        const point = ray.pointAt(mid);
        const terrain_height = terrain.getHeightLocal(point.x, point.z);

        if (point.y <= terrain_height) {
            high = mid;
        } else {
            low = mid;
        }
    }

    return (low + high) * 0.5;
}

// 坐标转换辅助函数
fn worldToLocal(terrain: *Terrain, world: Vec3) Vec3 {
    const local_xz = terrain.worldToLocal(world.x, world.z);
    return Vec3.new(local_xz.x, world.y - terrain.position.y, local_xz.z);
}

fn localToWorld(terrain: *Terrain, local: Vec3) Vec3 {
    const world_xz = terrain.localToWorld(local.x, local.z);
    return Vec3.new(world_xz.x, terrain.position.y + local.y, world_xz.z);
}

fn worldToLocalDirection(terrain: *Terrain, world_dir: Vec3) Vec3 {
    const cos = @cos(terrain.rotation_y);
    const sin = @sin(terrain.rotation_y);
    const local_x = world_dir.x * cos - world_dir.z * sin;
    const local_z = world_dir.x * sin + world_dir.z * cos;
    return Vec3.new(local_x, world_dir.y, local_z);
}

fn localToWorldDirection(terrain: *Terrain, local_dir: Vec3) Vec3 {
    const cos = @cos(terrain.rotation_y);
    const sin = @sin(terrain.rotation_y);
    const world_x = local_dir.x * cos + local_dir.z * sin;
    const world_z = -local_dir.x * sin + local_dir.z * cos;
    return Vec3.new(world_x, local_dir.y, world_z);
}

// 方便使用的辅助函数
pub fn raycast(ray: Ray, max_distance: f32, terrain: *Terrain) RaycastHit {
    const query = RaycastQuery.init(ray, max_distance);
    return query.castTerrain(terrain);
}
