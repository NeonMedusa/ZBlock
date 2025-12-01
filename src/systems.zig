/// 移动系统：更新所有具有 Position 和 Velocity 的实体
pub fn movementSystem(world: *World) void {
    for (world.entities.items) |entity| {
        if (world.getComponent(entity, Components.Position3D)) |pos| {
            if (world.getComponent(entity, Components.Velocity3D)) |vel|
                pos.add(vel);
        }
    }
}
/// 健康系统：处理所有具有 Health 组件的实体
pub fn healthSystem(world: *World) void {
    for (world.entities.items) |entity| {
        if (world.getComponent(entity, Components.Health)) |health| {
            std.debug.print("Entity {d} health: {d}/{d} ({d:.1}%)\n", .{
                entity,
                health.current,
                health.max,
                health.getHealthPercentage() * 100,
            });
            if (!health.isAlive())
                std.debug.print("Entity {d} is dead!\n", .{entity});
        }
    }
}
/// 渲染系统（示例）
pub fn renderingSystem(world: *World) void {
    for (world.entities.items) |entity| {
        if (world.getComponent(entity, Components.Position3D)) |pos| {
            _ = pos;
            // if (world.getComponent(entity, Components.Sprite)) |sprite| {
            //     std.debug.print("Rendering '{s}' at ({d:.1}, {d:.1})\n", .{
            //         sprite.texture_id,
            //         pos.x,
            //         pos.y,
            //     });
            // }
        }
    }
}

const std = @import("std");
const World = @import("world.zig").World;
const Components = @import("components.zig");
