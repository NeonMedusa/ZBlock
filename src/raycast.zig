// raycast.zig
const std = @import("std");
const Vec2 = @import("algebra.zig").Vec2;
const Vec3 = @import("algebra.zig").Vec3;

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
