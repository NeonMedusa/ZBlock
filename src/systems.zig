const std = @import("std");

const PlayerMovementSys = @import("systems/player_movement_system.zig");
const HealthSys = @import("systems/health_system.zig");
const TargetMoventSys = @import("systems/target_movement_system.zig");

pub const Systems = struct {
    pub fn updata(registry: *ECS.Registry, delta_time: f32) !void {
        try PlayerMovementSys.update(registry, delta_time);
        try TargetMoventSys.update(registry, delta_time);
        try HealthSys.update(registry);
    }
};

const ECS = @import("zigecs");
