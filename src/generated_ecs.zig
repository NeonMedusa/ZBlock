// generated_ecs.zig
// 此文件由 code_generator.zig 自动生成
// 请勿手动修改此文件

const std = @import("std");
const Components = @import("components.zig").Components;
const SparseSet = @import("sparse_set.zig").SparseSet;
pub const MAX_ENTITIES = @import("code_generator.zig").MAX_ENTITIES;

pub const EntityId = usize;

pub const Entity = struct {
    id: EntityId,
    world: *World,
    signature: Signature,
    pub fn setComp(self: Entity, component: anytype) void {
        self.world.setComp(self.id, component);
    }
    pub fn getCompPtr(self: Entity, T: type) ?*T {
        return self.world.getCompPtr(self.id, T);
    }
    pub fn delComp(self: Entity, comp_type: ComponentType) bool {
        return self.world.delComp(self.id, comp_type);
    }
    pub fn destroy(self: Entity) !void {
        try self.world.removeEntity(self.id);
    }
    pub fn hasComp(self: Entity, comp_type: ComponentType) bool {
        return self.world.hasComp(self.id, comp_type);
    }
};

// 组件类型枚举
pub const ComponentType = enum(u16) {
    Player,
    Model,
    Position,
    MovingTarget,
    Speed,
    Health,
    AnimationState,
    Collider,
    PhysicsBody,
    Ground,
};

// 组件数量
pub const component_count = 10;

// 组件签名（bitset）
pub const Signature = std.StaticBitSet(component_count);

// 从组件类型获取枚举值
pub inline fn getComponentType(comptime T: type) ComponentType {
    return switch (T) {
        Components.Player => .Player,
        Components.Model => .Model,
        Components.Position => .Position,
        Components.MovingTarget => .MovingTarget,
        Components.Speed => .Speed,
        Components.Health => .Health,
        Components.AnimationState => .AnimationState,
        Components.Collider => .Collider,
        Components.PhysicsBody => .PhysicsBody,
        Components.Ground => .Ground,
        else => @compileError("不支持的组件类型: " ++ @typeName(T)),
    };
}

// 世界
pub const World = struct {
    allocator: std.mem.Allocator,
    next_entity_id: EntityId = 0,
    available_ids: std.ArrayList(EntityId), // 可用ID池
    // 活跃的实体稀疏集，遍历它的密集数组以匹配组件签名
    active_entities: SparseSet(Entity, MAX_ENTITIES),

    // 组件存储
    players: SparseSet(Components.Player, MAX_ENTITIES), // player
    models: SparseSet(Components.Model, MAX_ENTITIES), // model
    positions: SparseSet(Components.Position, MAX_ENTITIES), // position
    moving_targets: SparseSet(Components.MovingTarget, MAX_ENTITIES), // movingtarget
    speeds: SparseSet(Components.Speed, MAX_ENTITIES), // speed
    healths: SparseSet(Components.Health, MAX_ENTITIES), // health
    animation_states: SparseSet(Components.AnimationState, MAX_ENTITIES), // animationstate
    colliders: SparseSet(Components.Collider, MAX_ENTITIES), // collider
    physics_bodys: SparseSet(Components.PhysicsBody, MAX_ENTITIES), // physicsbody
    grounds: SparseSet(Components.Ground, MAX_ENTITIES), // ground

    // 初始化
    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .next_entity_id = 0,
            .available_ids = std.ArrayList(EntityId){},
            .active_entities = SparseSet(Entity, MAX_ENTITIES).init(allocator),
            // 组件存储
            .players = SparseSet(Components.Player, MAX_ENTITIES).init(allocator),
            .models = SparseSet(Components.Model, MAX_ENTITIES).init(allocator),
            .positions = SparseSet(Components.Position, MAX_ENTITIES).init(allocator),
            .moving_targets = SparseSet(Components.MovingTarget, MAX_ENTITIES).init(allocator),
            .speeds = SparseSet(Components.Speed, MAX_ENTITIES).init(allocator),
            .healths = SparseSet(Components.Health, MAX_ENTITIES).init(allocator),
            .animation_states = SparseSet(Components.AnimationState, MAX_ENTITIES).init(allocator),
            .colliders = SparseSet(Components.Collider, MAX_ENTITIES).init(allocator),
            .physics_bodys = SparseSet(Components.PhysicsBody, MAX_ENTITIES).init(allocator),
            .grounds = SparseSet(Components.Ground, MAX_ENTITIES).init(allocator),
        };
    }

    // 析构
    pub fn deinit(self: *World) void {
        self.available_ids.deinit(self.allocator);
        self.active_entities.deinit();

        self.players.deinit();
        self.models.deinit();
        self.positions.deinit();
        self.moving_targets.deinit();
        self.speeds.deinit();
        self.healths.deinit();
        self.animation_states.deinit();
        self.colliders.deinit();
        self.physics_bodys.deinit();
        self.grounds.deinit();
    }

    // 设置组件并更新签名
    pub fn setComp(self: *World, entity_id: EntityId, component: anytype) void {
        const T = @TypeOf(component);
        const comp_type = getComponentType(T);
        // 存储组件数据
        switch (comp_type) {
            .Player => self.players.set(entity_id, component) catch unreachable,
            .Model => self.models.set(entity_id, component) catch unreachable,
            .Position => self.positions.set(entity_id, component) catch unreachable,
            .MovingTarget => self.moving_targets.set(entity_id, component) catch unreachable,
            .Speed => self.speeds.set(entity_id, component) catch unreachable,
            .Health => self.healths.set(entity_id, component) catch unreachable,
            .AnimationState => self.animation_states.set(entity_id, component) catch unreachable,
            .Collider => self.colliders.set(entity_id, component) catch unreachable,
            .PhysicsBody => self.physics_bodys.set(entity_id, component) catch unreachable,
            .Ground => self.grounds.set(entity_id, component) catch unreachable,
        }
        // 更新实体签名（设置对应位为1）
        var sig = self.active_entities.getPtr(entity_id).?.signature;
        sig.set(@intFromEnum(comp_type));
        self.active_entities.set(entity_id, Entity{
            .id = entity_id,
            .world = self,
            .signature = sig,
        }) catch unreachable;
    }

    // 移除组件并更新签名
    pub fn delComp(self: *World, entity_id: EntityId, comp_type: ComponentType) void {
        switch (comp_type) {
            .Player => _ = self.players.remove(entity_id),
            .Model => _ = self.models.remove(entity_id),
            .Position => _ = self.positions.remove(entity_id),
            .MovingTarget => _ = self.moving_targets.remove(entity_id),
            .Speed => _ = self.speeds.remove(entity_id),
            .Health => _ = self.healths.remove(entity_id),
            .AnimationState => _ = self.animation_states.remove(entity_id),
            .Collider => _ = self.colliders.remove(entity_id),
            .PhysicsBody => _ = self.physics_bodys.remove(entity_id),
            .Ground => _ = self.grounds.remove(entity_id),
        }
        // 更新实体签名（清除对应位）
        var sig = self.active_entities.getPtr(entity_id).?.signature;
        sig.unset(@intFromEnum(comp_type));
        self.active_entities.set(entity_id, Entity{
            .id = entity_id,
            .world = self,
            .signature = sig,
        }) catch unreachable;
    }

    // 创建实体
    pub fn createEntity(self: *World) Entity {
        var entity = Entity{
            .id = undefined,
            .world = self,
            .signature = Signature.initEmpty(),
        };
        // 复用已删除的实体ID
        if (self.available_ids.pop()) |id| {
            entity.id = id;
        } else { // 如果无可复用ID，则分配新ID
            entity.id = self.next_entity_id;
            self.next_entity_id += 1;
        }
        self.active_entities.set(entity.id, entity) catch unreachable;
        return entity;
    }

    // 移除实体
    pub fn removeEntity(self: *World, entity_id: EntityId) !void {
        // 将ID归还给可用ID池
        try self.available_ids.append(self.allocator, entity_id);
        // 清理所有组件
        _ = self.players.remove(entity_id);
        _ = self.models.remove(entity_id);
        _ = self.positions.remove(entity_id);
        _ = self.moving_targets.remove(entity_id);
        _ = self.speeds.remove(entity_id);
        _ = self.healths.remove(entity_id);
        _ = self.animation_states.remove(entity_id);
        _ = self.colliders.remove(entity_id);
        _ = self.physics_bodys.remove(entity_id);
        _ = self.grounds.remove(entity_id);
        // 从活跃实体集中删除
        _ = self.active_entities.remove(entity_id);
    }

    // 获取实体组件
    pub fn getCompPtr(self: *World, entity_id: EntityId, T: type) ?*T {
        var comp_storage = self.getStorage(T);
        return comp_storage.getPtr(entity_id);
    }

    // 获取组件容器
    pub inline fn getStorage(self: *World, T: type) *SparseSet(T, MAX_ENTITIES) {
        return switch (T) {
            Components.Player => &self.players,
            Components.Model => &self.models,
            Components.Position => &self.positions,
            Components.MovingTarget => &self.moving_targets,
            Components.Speed => &self.speeds,
            Components.Health => &self.healths,
            Components.AnimationState => &self.animation_states,
            Components.Collider => &self.colliders,
            Components.PhysicsBody => &self.physics_bodys,
            Components.Ground => &self.grounds,
            else => @compileError("不支持的组件类型: " ++ @typeName(T)),
        };
    }

    // 检测实体是否包含组件
    pub fn hasComp(self: *World, entity_id: EntityId, comp_type: ComponentType) bool {
        return switch (comp_type) {
            .Player => self.players.has(entity_id),
            .Model => self.models.has(entity_id),
            .Position => self.positions.has(entity_id),
            .MovingTarget => self.moving_targets.has(entity_id),
            .Speed => self.speeds.has(entity_id),
            .Health => self.healths.has(entity_id),
            .AnimationState => self.animation_states.has(entity_id),
            .Collider => self.colliders.has(entity_id),
            .PhysicsBody => self.physics_bodys.has(entity_id),
            .Ground => self.grounds.has(entity_id),
        };
    }

    pub fn activeEntities(self: *World) []Entity {
        return self.active_entities.dense.items;
    }
};
