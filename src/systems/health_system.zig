// health_system.zig
const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const ECS = @import("../generated_ecs.zig");
const EntityId = ECS.EntityId;
const Signature = ECS.Signature;
const ComponentType = ECS.ComponentType;
const Components = @import("../components.zig").Components;
const World = @import("../world.zig").World;

pub fn update(world: *World) !void {
    var health_iter = world.healths.iterator();
    while (health_iter.next()) |entry| {
        const entity = entry[0];
        const health = entry[1];
        // 如果实体死亡，移除所有组件
        if (health.current <= 0) try world.removeEntity(entity);
    }
}
