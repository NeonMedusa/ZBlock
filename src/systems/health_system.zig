// health_system.zig
const std = @import("std");
const Algebra = @import("../algebra.zig");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const ECS = @import("zigecs");
const Comps = @import("../components.zig").Components;

pub fn update(registry: *ECS.Registry) !void {
    var view = registry.view(.{Comps.Health}, .{});
    var iter = view.entityIterator();
    while (iter.next()) |entity| {
        const health = registry.getConst(Comps.Health, entity);
        // 如果实体死亡，移除所有组件，并使其成为孤立的
        if (health.current <= 0) registry.removeAll(entity);
    }
}
