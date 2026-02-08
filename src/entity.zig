// entity.zig
const std = @import("std");
const ECS = @import("generated_ecs.zig");
const ComponentType = ECS.ComponentType;
const World = ECS.World;

pub const Entity = struct {
    id: u32,
    world: *World,
    pub fn init(world: *World) !Entity {
        const id = try world.createEntity();
        return .{
            .world = world,
            .id = id,
        };
    }
    pub fn setComponent(self: Entity, component: anytype) !void {
        try self.world.setComponent(self.id, component);
    }
    pub fn getComponent(self: Entity, T: type) ?*T {
        return self.world.getComponent(self.id, T);
    }
    pub fn removeComponent(self: Entity, comp_type: ComponentType) bool {
        return self.world.removeComponent(self.id, comp_type);
    }
    pub fn destroy(self: Entity) !void {
        try self.world.removeEntity(self.id);
    }
    pub fn hasComponent(self: Entity, comp_type: ComponentType) bool {
        return self.world.hasComponent(self.id, comp_type);
    }
};
