// world.zig
const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Input = @import("input.zig");
const Key = Input.Key;
const ComponentStorage = @import("component_storage.zig").ComponentStorage;
const Components = @import("components.zig").Components;
const Signature = @import("generated_ecs.zig").Signature;
const ComponentType = @import("generated_ecs.zig").ComponentType;
const ECS = @import("generated_ecs.zig");

pub const EntityId = u32;

// 世界
pub const World = struct {
    allocator: std.mem.Allocator,
    next_entity_id: EntityId = 0,
    available_ids: std.ArrayList(EntityId), // 可用ID池
    // 实体签名存储
    signatures: std.ArrayList(Signature),
    // 基础组件存储
    players: ComponentStorage(Components.Player), // 玩家标记
    models: ComponentStorage(Components.Model), // 模型
    positions: ComponentStorage(Components.Position), // 位置
    moving_targets: ComponentStorage(Components.MovingTarget), // 移动目标（将来用于寻路）
    speeds: ComponentStorage(Components.Speed), // 移速
    healths: ComponentStorage(Components.Health), // 生命值
    // 初始化
    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .available_ids = std.ArrayList(EntityId){},
            .signatures = std.ArrayList(Signature){},
            .players = ComponentStorage(Components.Player).init(allocator),
            .models = ComponentStorage(Components.Model).init(allocator),
            .positions = ComponentStorage(Components.Position).init(allocator),
            .moving_targets = ComponentStorage(Components.MovingTarget).init(allocator),
            .speeds = ComponentStorage(Components.Speed).init(allocator),
            .healths = ComponentStorage(Components.Health).init(allocator),
        };
    }
    // 析构
    pub fn deinit(self: *World) void {
        self.available_ids.deinit(self.allocator);
        self.signatures.deinit(self.allocator);
        self.players.deinit(self.allocator);
        self.models.deinit(self.allocator);
        self.positions.deinit(self.allocator);
        self.moving_targets.deinit(self.allocator);
        self.speeds.deinit(self.allocator);
        self.healths.deinit(self.allocator);
    }
    // 更新所有系统
    pub fn update(self: *World, delta_time: f32) !void {
        self.MovementSystem(delta_time);
        try self.HealthSystem(delta_time);
    }
    // 系统：更新移动逻辑
    fn MovementSystem(self: *World, delta_time: f32) void {
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
        for (self.signatures.items, 0..) |sig, entity_id| {
            const entity = @as(EntityId, @intCast(entity_id));
            // 如果该实体的组件签名是mobile_player_sig的超集，那它就是一个mobile_player（可移动玩家，不是手机玩家！）
            if (sig.supersetOf(mobile_player_sig)) {
                // 现在可以安全地获取组件，无需空值检查
                const player = self.players.get(entity).?;
                const position = self.positions.get(entity).?;
                const speed = self.speeds.get(entity).?;
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
                const position = self.positions.get(entity).?;
                const speed = self.speeds.get(entity).?;
                const target = self.moving_targets.get(entity).?;
                const to_target = target.vec.sub(position.vec);
                const distance = to_target.length();
                // 如果距离目标点已经足够近，则判定为已经到达目标点，停止移动并移除目标点组件
                if (distance < 0.01) {
                    position.vec = target.vec;
                    _ = self.removeComponent(entity, Components.MovingTarget);
                    continue;
                }
                // 如果本次帧移动距离大于到目标的距离，直接到达
                const move_distance = speed.value * delta_time;
                if (move_distance >= distance) {
                    position.vec = target.vec;
                    _ = self.removeComponent(entity, Components.MovingTarget);
                    continue;
                }
                // 否则沿方向移动
                const direction = to_target.norm();
                position.vec = position.vec.add(direction.scale(move_distance));
            }
        }
    }
    // 系统：更新生命值
    fn HealthSystem(self: *World, delta_time: f32) !void {
        _ = delta_time;
        var health_iter = self.healths.iterator();
        while (health_iter.next()) |entry| {
            const entity = entry[0];
            const health = entry[1];
            // 如果实体死亡，移除所有组件
            if (health.current <= 0) try self.removeEntity(entity);
        }
    }

    // 设置组件并更新签名
    pub fn setComponent(self: *World, entity: EntityId, component: anytype) !void {
        const T = @TypeOf(component);
        const comp_type = ECS.getComponentType(T);
        // 存储组件数据
        switch (comp_type) {
            .Player => try self.players.set(entity, component),
            .Model => try self.models.set(entity, component),
            .Position => try self.positions.set(entity, component),
            .MovingTarget => try self.moving_targets.set(entity, component),
            .Speed => try self.speeds.set(entity, component),
            .Health => try self.healths.set(entity, component),
            else => unreachable,
        }
        // 更新实体签名（设置对应位为1）
        var sig = self.signatures.items[entity];
        sig.set(@intFromEnum(comp_type));
        self.signatures.items[entity] = sig;
    }

    // 移除组件并更新签名
    pub fn removeComponent(self: *World, entity: EntityId, comptime T: type) bool {
        const comp_type = ECS.getComponentType(T);
        var removed = false;
        switch (comp_type) {
            .Player => removed = self.players.remove(entity),
            .Model => removed = self.models.remove(entity),
            .Position => removed = self.positions.remove(entity),
            .MovingTarget => removed = self.moving_targets.remove(entity),
            .Speed => removed = self.speeds.remove(entity),
            .Health => removed = self.healths.remove(entity),
            .AnimationState => removed = self.action_status.remove(entity),
            // else => unreachable,
        }
        // 更新实体签名（清除对应位）
        if (removed) {
            var sig = self.signatures.items[entity];
            sig.unset(@intFromEnum(comp_type));
            self.signatures.items[entity] = sig;
        }
        return removed;
    }
    // 创建空实体
    pub fn createEmptyEntity(self: *World) !EntityId {
        // 复用已删除的实体ID
        if (self.available_ids.pop()) |id| return id;
        // 如果无可复用ID，则分配新ID并初始化一个空的组件签名
        const id = self.next_entity_id;
        self.next_entity_id += 1;
        try self.signatures.append(self.allocator, Signature.initEmpty());
        return id;
    }
    // 移除实体
    fn removeEntity(self: *World, entity: EntityId) !void {
        // 将ID归还给可用ID池
        try self.available_ids.append(self.allocator, entity);
        // 清空组件签名
        self.signatures.items[entity] = Signature.initEmpty();
        // 清理所有组件
        _ = self.players.remove(entity);
        _ = self.models.remove(entity);
        _ = self.positions.remove(entity);
        _ = self.moving_targets.remove(entity);
        _ = self.speeds.remove(entity);
        _ = self.healths.remove(entity);
    }
    // 创建基础实体
    pub fn createBaseEntity(
        self: *World,
        model: Components.Model,
        start_pos: Components.Position,
        base_speed: Components.Speed,
        health: Components.Health,
    ) !EntityId {
        const entity = try self.createEmptyEntity();
        try self.setComponent(entity, model);
        try self.setComponent(entity, start_pos);
        try self.setComponent(entity, base_speed);
        try self.setComponent(entity, health);
        return entity;
    }
    // 创建玩家
    pub fn createPlayer(
        self: *World,
        model: Components.Model,
        start_pos: Components.Position,
        base_speed: Components.Speed,
        health: Components.Health,
        player: Components.Player,
    ) !EntityId {
        const entity = try self.createBaseEntity(
            model,
            start_pos,
            base_speed,
            health,
        );
        try self.setComponent(entity, player);
        return entity;
    }
    // 获取变换矩阵（用于渲染）
    pub fn getTransformMatrix(self: *World, entity: EntityId) ?Mat4 {
        if (self.positions.get(entity)) |position|
            return Mat4.fromTranslate(position.vec);
        return null;
    }
};
