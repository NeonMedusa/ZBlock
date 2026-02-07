pub const PlayerMovement = @import("systems/player_movement_system.zig");
pub const Health = @import("systems/health_system.zig");
pub const TargetMovent = @import("systems/target_movement_system.zig");

pub fn updata(world: *World, delta_time: f32) !void {
    try PlayerMovement.update(world, delta_time);
    try TargetMovent.update(world, delta_time);
    try Health.update(world);
}

const World = @import("generated_ecs.zig").World;
