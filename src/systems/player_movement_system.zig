// player_system.zig
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

const mobile_player_sig = blk: {
    var sig = Signature.initEmpty();
    sig.set(@intFromEnum(ComponentType.Player));
    sig.set(@intFromEnum(ComponentType.Position));
    sig.set(@intFromEnum(ComponentType.Speed));
    break :blk sig;
};

pub fn update(world: *World, delta_time: f32) !void {
    for (world.signatures.items, 0..) |sig, entity_id| {
        const entity = @as(EntityId, @intCast(entity_id));
        // 如果该实体的组件签名是mobile_player_sig的超集，那它就是一个mobile_player（可移动玩家，不是手机玩家！）
        if (sig.supersetOf(mobile_player_sig)) {
            // 现在可以安全地获取组件，无需空值检查
            const player = world.players.get(entity).?;
            const position = world.positions.get(entity).?;
            const speed = world.speeds.get(entity).?;
            const velocity = speed.value * delta_time;
            if (player.input.isKeyPressed(.left))
                position.vec = position.vec.add(Vec3.new(-velocity, 0, 0));
            if (player.input.isKeyPressed(.right))
                position.vec = position.vec.add(Vec3.new(velocity, 0, 0));
            if (player.input.isKeyPressed(.up))
                position.vec = position.vec.add(Vec3.new(0, 0, -velocity));
            if (player.input.isKeyPressed(.down))
                position.vec = position.vec.add(Vec3.new(0, 0, velocity));
        }
    }
}
