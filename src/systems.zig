const std = @import("std");

const PlayerMovementSys = @import("systems/player_movement_system.zig");
const HealthSys = @import("systems/health_system.zig");
const TargetMoventSys = @import("systems/target_movement_system.zig");
const PhysicsSys = @import("systems/physics_system.zig").PhysicsSystem;

pub const Systems = struct {
    world: *World,
    physics_sys: PhysicsSys,
    pub fn init(allocator: std.mem.Allocator, world: *World) Systems {
        return .{
            .world = world,
            .physics_sys = try PhysicsSys.init(allocator),
        };
    }
    pub fn deinit(self: *Systems) void {
        self.physics_sys.deinit();
    }
    pub fn updata(self: *Systems, world: *World, delta_time: f32) !void {
        try self.physics_sys.update(self.world, delta_time);
        try PlayerMovementSys.update(world, delta_time);
        try TargetMoventSys.update(world, delta_time);
        try HealthSys.update(world);
    }
};

const World = @import("generated_ecs.zig").World;
