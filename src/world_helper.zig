const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Input = @import("input.zig");
const Key = Input.Key;
const ComponentStorage = @import("component_storage.zig").ComponentStorage;
const Components = @import("components.zig").Components;
const ECS = @import("generated_ecs.zig");
const EntityId = ECS.EntityId;
const Signature = ECS.Signature;
const ComponentType = ECS.ComponentType;
const World = @import("generated_ecs.zig").World;
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
