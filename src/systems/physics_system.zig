// physics_system.zig
const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const ECS = @import("../generated_ecs.zig");
const EntityId = ECS.EntityId;
const Signature = ECS.Signature;
const ComponentType = ECS.ComponentType;
const Components = @import("../components.zig").Components;
const World = @import("../generated_ecs.zig").World;
const CollisionSystem = @import("./collision_detection_system.zig").CollisionSystem;
const CollisionEvent = @import("./collision_detection_system.zig").CollisionEvent;

const physics_entity_sig = blk: {
    var sig = Signature.initEmpty();
    sig.set(@intFromEnum(ComponentType.Position));
    sig.set(@intFromEnum(ComponentType.Collider));
    sig.set(@intFromEnum(ComponentType.PhysicsBody));
    break :blk sig;
};

pub const PhysicsSystem = struct {
    collision_system: CollisionSystem,
    gravity: Vec3 = Vec3.new(0, -9.8, 0),

    pub fn init(allocator: std.mem.Allocator) !PhysicsSystem {
        return .{
            .collision_system = try CollisionSystem.init(allocator),
        };
    }

    pub fn deinit(self: *PhysicsSystem) void {
        self.collision_system.deinit();
    }

    fn resolveCollision(world: *World, collision: CollisionEvent) void {
        const body_a = world.physics_bodys.get(collision.entity_a).?;
        const pos_a = world.positions.get(collision.entity_a).?;
        const body_b = world.physics_bodys.get(collision.entity_b).?;
        const pos_b = world.positions.get(collision.entity_b).?;

        const cr = collision.result;

        // 跳过静态物体
        if (body_a.is_static and body_b.is_static) return;

        const relative_velocity = body_b.velocity.sub(body_a.velocity);
        const velocity_along_normal = relative_velocity.dot(cr.normal);

        // 如果物体正在分离，不需要处理
        if (velocity_along_normal > 0) return;

        // 计算恢复系数
        const e = @min(body_a.restitution, body_b.restitution);

        // 计算冲量大小
        var j = -(1.0 + e) * velocity_along_normal;
        j /= (if (!body_a.is_static) 1.0 / body_a.mass else 0) +
            (if (!body_b.is_static) 1.0 / body_b.mass else 0);

        // 应用冲量
        const impulse = cr.normal.scale(j);

        if (!body_a.is_static) {
            body_a.velocity = body_a.velocity.sub(impulse.scale(1.0 / body_a.mass));
            // 位置修正
            pos_a.vec = pos_a.vec.sub(cr.normal.scale(cr.penetration * 0.5));
        }

        if (!body_b.is_static) {
            body_b.velocity = body_b.velocity.add(impulse.scale(1.0 / body_b.mass));
            // 位置修正
            pos_b.vec = pos_b.vec.add(cr.normal.scale(cr.penetration * 0.5));
        }

        // 摩擦力
        const tangent = relative_velocity.sub(cr.normal.scale(velocity_along_normal));
        if (tangent.length() > 0.001) {
            const tangent_normalized = tangent.norm();
            const friction_impulse = tangent_normalized.scale(-j * body_a.friction * body_b.friction);

            if (!body_a.is_static) {
                body_a.velocity = body_a.velocity.add(friction_impulse.scale(1.0 / body_a.mass));
            }

            if (!body_b.is_static) {
                body_b.velocity = body_b.velocity.sub(friction_impulse.scale(1.0 / body_b.mass));
            }
        }
    }

    pub fn update(self: *PhysicsSystem, world: *World, delta_time: f32) !void {
        // 1. 应用力和积分
        for (world.signatures.items, 0..) |sig, entity_id| {
            const entity = @as(EntityId, @intCast(entity_id));
            if (sig.supersetOf(physics_entity_sig)) {
                const position = world.positions.get(entity).?;
                const body = world.physics_bodys.get(entity).?;

                if (!body.is_static) {
                    // 应用重力
                    body.acceleration = body.acceleration.add(self.gravity.scale(body.gravity_scale));

                    // 欧拉积分
                    body.velocity = body.velocity.add(body.acceleration.scale(delta_time));
                    position.vec = position.vec.add(body.velocity.scale(delta_time));

                    // 简单阻尼
                    body.velocity = body.velocity.scale(0.99);
                    body.acceleration = Vec3.zero();
                }
            }
        }

        // 2. 检测碰撞
        try self.collision_system.detectCollisions(world, delta_time);

        // 3. 解决碰撞
        for (self.collision_system.collisions.items) |collision| {
            resolveCollision(world, collision);
        }
    }
};
