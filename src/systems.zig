const std = @import("std");

const PlayerMovementSys = @import("systems/player_movement_system.zig");
const HealthSys = @import("systems/health_system.zig");
const TargetMoventSys = @import("systems/target_movement_system.zig");
const PhysicsSys = @import("systems/physics_system.zig").PhysicsSystem;

pub const Systems = struct {
    registry: *ECS.Registry,
    physics_sys: PhysicsSys,
    pub fn init(allocator: std.mem.Allocator, registry: *ECS.Registry) Systems {
        return .{
            .registry = registry,
            .physics_sys = try PhysicsSys.init(allocator),
        };
    }
    pub fn deinit(self: *Systems) void {
        self.physics_sys.deinit();
    }
    pub fn updata(self: *Systems, registry: *ECS.Registry, delta_time: f32) !void {
        try self.physics_sys.update(self.registry, delta_time);
        try PlayerMovementSys.update(registry, delta_time);
        try TargetMoventSys.update(registry, delta_time);
        try HealthSys.update(registry);
    }
};

const ECS = @import("zigecs");
