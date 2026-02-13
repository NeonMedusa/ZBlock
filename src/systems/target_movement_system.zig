// target_movement_system.zig
const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const ECS = @import("../generated_ecs.zig");
const EntityId = ECS.EntityId;
const Signature = ECS.Signature;
const ComponentType = ECS.ComponentType;
const Components = @import("../components.zig").Components;
const World = @import("../generated_ecs.zig").World;

const mobile_entity_sig = blk: {
    var sig = Signature.initEmpty();
    sig.set(@intFromEnum(ComponentType.Position));
    sig.set(@intFromEnum(ComponentType.Speed));
    sig.set(@intFromEnum(ComponentType.MovingTarget));
    break :blk sig;
};

pub fn update(world: *World, delta_time: f32) !void {
    for (world.activeEntities()) |entity| {
        const sig = entity.signature;
        if (sig.supersetOf(mobile_entity_sig)) {
            const position = world.positions.getPtr(entity.id).?;
            const speed = world.speeds.getPtr(entity.id).?;
            const target = world.moving_targets.getPtr(entity.id).?;
            const to_target = target.vec.sub(position.vec);
            const distance = to_target.length();
            // 如果距离目标点已经足够近，则判定为已经到达目标点，停止移动并移除目标点组件
            if (distance < 0.01) {
                position.vec = target.vec;
                world.delComp(entity.id, .MovingTarget);
                continue;
            }
            // 如果本次帧移动距离大于到目标的距离，直接到达
            const move_distance = speed.value * delta_time;
            if (move_distance >= distance) {
                position.vec = target.vec;
                world.delComp(entity.id, .MovingTarget);
                continue;
            }
            // 否则沿方向移动
            const direction = to_target.norm();
            position.vec = position.vec.add(direction.scale(move_distance));
        }
    }
}
