// player_system.zig
const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const ECS = @import("../generated_ecs.zig");
const EntityId = ECS.EntityId;
const Signature = ECS.Signature;
const CompType = ECS.ComponentType;
const Comps = @import("../components.zig").Components;
const World = @import("../generated_ecs.zig").World;

const mobile_player_sig = blk: {
    var sig = Signature.initEmpty();
    sig.set(@intFromEnum(CompType.Player));
    sig.set(@intFromEnum(CompType.Position));
    sig.set(@intFromEnum(CompType.Speed));
    break :blk sig;
};

pub fn update(world: *World, delta_time: f32) !void {
    for (world.activeEntities()) |entity| {
        // 如果该实体的组件签名是mobile_player_sig的超集，那它就是一个mobile_player（可移动玩家，不是手机玩家！）
        if (entity.signature.supersetOf(mobile_player_sig)) {
            // 现在可以安全地获取组件，无需空值检查
            const player = entity.getCompPtr(Comps.Player).?;
            const position = entity.getCompPtr(Comps.Position).?;
            const speed = entity.getCompPtr(Comps.Speed).?;
            const velocity = speed.value * delta_time;
            if (player.input.isKeyPressed(.left))
                position.vec = position.vec.add(.new(-velocity, 0, 0));
            if (player.input.isKeyPressed(.right))
                position.vec = position.vec.add(.new(velocity, 0, 0));
            if (player.input.isKeyPressed(.up))
                position.vec = position.vec.add(.new(0, 0, -velocity));
            if (player.input.isKeyPressed(.down))
                position.vec = position.vec.add(.new(0, 0, velocity));
        }
    }
}
