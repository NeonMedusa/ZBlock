// raycast.zig
const std = @import("std");
const Vec2 = @import("algebra.zig").Vec2;
const Vec3 = @import("algebra.zig").Vec3;
const Terrain = @import("terrain.zig").Terrain;

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

pub const Ray = struct {
    origin: Vec3,
    direction: Vec3,

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

pub fn raycastTerrain(terrain: *Terrain, ray: Ray, max_distance: f32) RaycastHit {
    const local_origin = worldToLocal(terrain, ray.origin);
    const local_dir = worldToLocalDirection(terrain, ray.direction);
    const local_ray = Ray.init(local_origin, local_dir);

    const bounds_min = Vec3.new(-terrain.size_x / 2, 0.0, -terrain.size_z / 2);
    const bounds_max = Vec3.new(terrain.size_x / 2, terrain.max_height, terrain.size_z / 2);

    var t_min: f32 = 0;
    var t_max: f32 = max_distance;
    if (!rayAABBIntersect(local_ray, bounds_min, bounds_max, &t_min, &t_max)) {
        return RaycastHit{
            .hit = false,
            .hit_type = .none,
            .point = Vec3.zero,
            .normal = Vec3.zero,
            .distance = 0,
        };
    }

    var low = t_min;
    var high = t_max;

    for (0..32) |_| {
        const mid = (low + high) * 0.5;
        const point = local_ray.pointAt(mid);
        const terrain_height = terrain.getHeightLocal(Vec2.new(point.x, point.z));

        if (point.y <= terrain_height) {
            high = mid;
        } else {
            low = mid;
        }
    }

    const hit_t = (low + high) * 0.5;
    const hit_point_local = local_ray.pointAt(hit_t);
    const hit_point_world = localToWorld(terrain, hit_point_local);
    const normal_local = terrain.getNormalLocal(Vec2.new(hit_point_local.x, hit_point_local.z));
    const normal_world = localToWorldDirection(terrain, normal_local);

    return RaycastHit{
        .hit = true,
        .point = hit_point_world,
        .normal = normal_world,
        .distance = hit_t,
        .hit_type = .terrain,
    };
}

fn rayAABBIntersect(ray: Ray, min: Vec3, max: Vec3, t_min: *f32, t_max: *f32) bool {
    var t0: f32 = -std.math.floatMax(f32);
    var t1: f32 = std.math.floatMax(f32);

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

fn worldToLocal(terrain: *Terrain, world: Vec3) Vec3 {
    const local_xz = terrain.worldToLocal(Vec2.new(world.x, world.z));
    return Vec3.new(local_xz.x, world.y - terrain.position.y, local_xz.z);
}

fn localToWorld(terrain: *Terrain, local: Vec3) Vec3 {
    const world_xz = terrain.localToWorld(Vec2.new(local.x, local.z));
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

pub fn raycast(ray: Ray, max_distance: f32, terrain: *Terrain) RaycastHit {
    return raycastTerrain(terrain, ray, max_distance);
}
