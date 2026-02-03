// systems.zig
const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Input = @import("input.zig");
const Key = Input.Key;
const ComponentStorage = @import("component_storage.zig").ComponentStorage;
const Components = @import("components.zig").Components;
const ECS = @import("generated_ecs.zig");
const Signature = ECS.Signature;
const ComponentType = ECS.ComponentType;
const World = @import("world.zig").World;

pub const EntityId = u32;

// 更新所有系统
pub fn updateAll(world: *World, delta_time: f32) !void {
    movementSystem(world, delta_time);
    try healthSystem(world, delta_time);
}

// 系统：移动
fn movementSystem(world: *World, delta_time: f32) void {
    // 可移动玩家组件签名（不是手机玩家！XD）
    const mobile_player_sig = blk: {
        var sig = Signature.initEmpty();
        sig.set(@intFromEnum(ComponentType.Player));
        sig.set(@intFromEnum(ComponentType.Position));
        sig.set(@intFromEnum(ComponentType.Speed));
        break :blk sig;
    };
    // 可移动实体组件签名
    const mobile_entity_sig = blk: {
        var sig = Signature.initEmpty();
        sig.set(@intFromEnum(ComponentType.Position));
        sig.set(@intFromEnum(ComponentType.Speed));
        sig.set(@intFromEnum(ComponentType.MovingTarget));
        break :blk sig;
    };
    // 遍历实体
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

        // 处理普通可移动实体
        if (sig.supersetOf(mobile_entity_sig)) {
            const position = world.positions.get(entity).?;
            const speed = world.speeds.get(entity).?;
            const target = world.moving_targets.get(entity).?;
            const to_target = target.vec.sub(position.vec);
            const distance = to_target.length();
            // 如果距离目标点已经足够近，则判定为已经到达目标点，停止移动并移除目标点组件
            if (distance < 0.01) {
                position.vec = target.vec;
                _ = world.removeComponent(entity, Components.MovingTarget);
                continue;
            }
            // 如果本次帧移动距离大于到目标的距离，直接到达
            const move_distance = speed.value * delta_time;
            if (move_distance >= distance) {
                position.vec = target.vec;
                _ = world.removeComponent(entity, Components.MovingTarget);
                continue;
            }
            // 否则沿方向移动
            const direction = to_target.norm();
            position.vec = position.vec.add(direction.scale(move_distance));
        }
    }
}
// 系统：更新生命值
fn healthSystem(world: *World, delta_time: f32) !void {
    _ = delta_time;
    var health_iter = world.healths.iterator();
    while (health_iter.next()) |entry| {
        const entity = entry[0];
        const health = entry[1];
        // 如果实体死亡，移除所有组件
        if (health.current <= 0) try world.removeEntity(entity);
    }
}

// 辅助函数创建基础实体
pub fn createBaseEntity(
    world: *World,
    model: Components.Model,
    start_pos: Components.Position,
    base_speed: Components.Speed,
    health: Components.Health,
) !EntityId {
    const entity = try world.createEntity();
    try world.setComponent(entity, model);
    try world.setComponent(entity, start_pos);
    try world.setComponent(entity, base_speed);
    try world.setComponent(entity, health);
    return entity;
}
// 创建玩家
pub fn createPlayer(
    world: *World,
    model: Components.Model,
    start_pos: Components.Position,
    base_speed: Components.Speed,
    health: Components.Health,
    player: Components.Player,
) !EntityId {
    const entity = try createBaseEntity(
        world,
        model,
        start_pos,
        base_speed,
        health,
    );
    try world.setComponent(entity, player);
    return entity;
}
// 获取变换矩阵（用于渲染）
pub fn getTransformMatrix(world: *World, entity: EntityId) ?Mat4 {
    if (world.positions.get(entity)) |position|
        return Mat4.fromTranslate(position.vec);
    return null;
}
