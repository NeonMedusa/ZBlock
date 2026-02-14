// collision_detection_system.zig
const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const ECS = @import("../generated_ecs.zig");
const Signature = ECS.Signature;
const ComponentType = ECS.ComponentType;
const Components = @import("../components.zig").Components;
const World = @import("../generated_ecs.zig").World;

const physics_entity_sig = blk: {
    var sig = Signature.initEmpty();
    sig.set(@intFromEnum(ComponentType.Position));
    sig.set(@intFromEnum(ComponentType.Collider));
    sig.set(@intFromEnum(ComponentType.PhysicsBody));
    break :blk sig;
};

// 定义碰撞结果类型
pub const CollisionResult = struct {
    normal: Vec3,
    penetration: f32,
    contact_point: Vec3,
};

pub const CollisionEvent = struct {
    entity_a: usize,
    entity_b: usize,
    result: CollisionResult,
};

pub const CollisionSystem = struct {
    allocator: std.mem.Allocator,
    collisions: std.ArrayList(CollisionEvent),

    pub fn init(allocator: std.mem.Allocator) !CollisionSystem {
        return .{
            .allocator = allocator,
            .collisions = std.ArrayList(CollisionEvent){},
        };
    }

    pub fn deinit(self: *CollisionSystem) void {
        self.collisions.deinit(self.allocator);
    }

    fn sphereVsSphere(pos_a: Vec3, radius_a: f32, pos_b: Vec3, radius_b: f32) ?CollisionResult {
        const delta = pos_b.sub(pos_a);
        const distance = delta.length();
        const radius_sum = radius_a + radius_b;

        if (distance >= radius_sum or distance == 0) {
            return null;
        }

        const normal = delta.scale(1.0 / distance);
        const penetration = radius_sum - distance;
        const contact_point = pos_a.add(normal.scale(radius_a - penetration * 0.5));

        return CollisionResult{
            .normal = normal,
            .penetration = penetration,
            .contact_point = contact_point,
        };
    }

    fn boxVsSphere(box_pos: Vec3, box_size: Vec3, sphere_pos: Vec3, sphere_radius: f32) ?CollisionResult {
        // 计算最近点
        const half_size = box_size.scale(0.5);
        const local_point = sphere_pos.sub(box_pos);

        // 将点限制在盒子范围内
        const closet_point_x = std.math.clamp(local_point.x(), -half_size.x(), half_size.x());
        const closet_point_y = std.math.clamp(local_point.y(), -half_size.y(), half_size.y());
        const closet_point_z = std.math.clamp(local_point.z(), -half_size.z(), half_size.z());

        var closest_point = Vec3.new(closet_point_x, closet_point_y, closet_point_z);

        // 计算距离
        const distance_vec = local_point.sub(closest_point);
        const distance = distance_vec.length();

        if (distance > sphere_radius) {
            return null;
        }

        const penetration = sphere_radius - distance;
        const normal = if (distance > 0.001)
            distance_vec.scale(1.0 / distance)
        else
            Vec3.new(0, 1, 0);

        const contact_point = closest_point.add(box_pos);

        return CollisionResult{
            .normal = normal,
            .penetration = penetration,
            .contact_point = contact_point,
        };
    }

    // 简单AABB碰撞检测
    fn boxVsBox(pos_a: Vec3, size_a: Vec3, pos_b: Vec3, size_b: Vec3) ?CollisionResult {
        const half_a = size_a.scale(0.5);
        const half_b = size_b.scale(0.5);

        // 检查分离轴
        const dx = pos_b.x() - pos_a.x();
        const px = (half_a.x() + half_b.x()) - @abs(dx);
        if (px <= 0) return null;

        const dy = pos_b.y() - pos_a.y();
        const py = (half_a.y() + half_b.y()) - @abs(dy);
        if (py <= 0) return null;

        const dz = pos_b.z() - pos_a.z();
        const pz = (half_a.z() + half_b.z()) - @abs(dz);
        if (pz <= 0) return null;

        // 找到最小穿透轴
        var normal = Vec3.zero();
        var penetration: f32 = 0;

        if (px < py and px < pz) {
            normal = Vec3.new(if (dx > 0) 1 else -1, 0, 0);
            penetration = px;
        } else if (py < pz) {
            normal = Vec3.new(0, if (dy > 0) 1 else -1, 0);
            penetration = py;
        } else {
            normal = Vec3.new(0, 0, if (dz > 0) 1 else -1);
            penetration = pz;
        }

        const contact_point = pos_a.add(Vec3.new(if (dx > 0) px * 0.5 else -px * 0.5, if (dy > 0) py * 0.5 else -py * 0.5, if (dz > 0) pz * 0.5 else -pz * 0.5));

        return CollisionResult{
            .normal = normal,
            .penetration = penetration,
            .contact_point = contact_point,
        };
    }

    fn checkCollision(self: *CollisionSystem, world: *World, entity_a: usize, entity_b: usize) !void {
        const pos_a = world.positions.getPtr(entity_a).?.vec;
        const collider_a = world.colliders.getPtr(entity_a).?;
        const body_a = world.physics_bodys.getPtr(entity_a).?;

        const pos_b = world.positions.getPtr(entity_b).?.vec;
        const collider_b = world.colliders.getPtr(entity_b).?;
        const body_b = world.physics_bodys.getPtr(entity_b).?;

        // 如果都是静态物体，不需要检测
        if (body_a.is_static and body_b.is_static) return;

        var collision_result: ?CollisionResult = null;

        // 根据形状类型进行碰撞检测
        const sphere_a = collider_a.shape_type == .sphere;
        const sphere_b = collider_b.shape_type == .sphere;
        const box_a = collider_a.shape_type == .box;
        const box_b = collider_b.shape_type == .box;

        const pos_a_with_offset = pos_a.add(collider_a.offset);
        const pos_b_with_offset = pos_b.add(collider_b.offset);

        if (sphere_a and sphere_b) {
            collision_result = sphereVsSphere(
                pos_a_with_offset,
                collider_a.dimensions.x(),
                pos_b_with_offset,
                collider_b.dimensions.x(),
            );
        } else if (box_a and sphere_b) {
            collision_result = boxVsSphere(
                pos_a_with_offset,
                collider_a.dimensions,
                pos_b_with_offset,
                collider_b.dimensions.x(),
            );
            // 反转法线方向，使法线指向B
            if (collision_result) |cr| {
                collision_result = CollisionResult{
                    .normal = cr.normal.scale(-1),
                    .penetration = cr.penetration,
                    .contact_point = cr.contact_point,
                };
            }
        } else if (sphere_a and box_b) {
            collision_result = boxVsSphere(
                pos_b_with_offset,
                collider_b.dimensions,
                pos_a_with_offset,
                collider_a.dimensions.x(),
            );
        } else if (box_a and box_b) {
            collision_result = boxVsBox(
                pos_a_with_offset,
                collider_a.dimensions,
                pos_b_with_offset,
                collider_b.dimensions,
            );
        }
        // 可以在这里添加其他形状组合的检测

        if (collision_result) |cr| {
            try self.collisions.append(self.allocator, CollisionEvent{
                .entity_a = entity_a,
                .entity_b = entity_b,
                .result = cr,
            });
        }
    }

    pub fn detectCollisions(self: *CollisionSystem, world: *World, delta_time: f32) !void {
        _ = delta_time;
        self.collisions.clearRetainingCapacity();

        // 收集所有物理实体
        var physics_entities = std.ArrayList(usize){};
        defer physics_entities.deinit(self.allocator);

        for (world.activeEntities()) |entity| {
            const sig = entity.signature;
            if (sig.supersetOf(physics_entity_sig)) {
                try physics_entities.append(self.allocator, entity.id);
            }
        }

        // 检测所有实体对之间的碰撞
        for (0..physics_entities.items.len) |i| {
            const entity_a = physics_entities.items[i];

            for (i + 1..physics_entities.items.len) |j| {
                const entity_b = physics_entities.items[j];
                try self.checkCollision(world, entity_a, entity_b);
            }
        }
    }
};
