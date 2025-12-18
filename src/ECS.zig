const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Input = @import("input.zig");
const Key = Input.Key;
// 实体ID
pub const EntityId = u32;
pub const Player = struct {
    player_id: u32 = 0, // 用于区分不同玩家（联机时有用）
    input: *Input,
};
pub const ActionStatus = enum {
    moving,
    idel,
};
pub const Model = @import("model.zig").ModelName;
pub const Position = Vec3;
pub const MovingTarget = Vec3;
pub const Speed = f32;
pub const Health = struct {
    current: f32,
    max: f32,
};
// 组件存储
pub fn ComponentStorage(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        dense: std.ArrayList(T),
        sparse: std.ArrayList(EntityId),
        entity_to_index: std.AutoHashMap(EntityId, usize),
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .dense = std.ArrayList(T){},
                .sparse = std.ArrayList(EntityId){},
                .entity_to_index = std.AutoHashMap(EntityId, usize).init(allocator),
            };
        }
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.dense.deinit(allocator);
            self.sparse.deinit(allocator);
            self.entity_to_index.deinit();
        }
        pub fn set(self: *Self, entity: EntityId, component: T) !void {
            if (self.entity_to_index.get(entity)) |index| {
                // 更新现有组件
                self.dense.items[index] = component;
            } else {
                // 添加新组件
                const index = self.dense.items.len;
                try self.dense.append(self.allocator, component);
                try self.sparse.append(self.allocator, entity);
                try self.entity_to_index.put(entity, index);
            }
        }
        pub fn add(self: *Self, entity: EntityId, component: T) !void {
            if (self.entity_to_index.contains(entity)) {
                std.debug.print("Warning: Component already exists for entity {}\n", .{entity});
                return;
            }
            try self.set(entity, component);
        }
        pub fn get(self: *Self, entity: EntityId) ?*T {
            if (self.entity_to_index.get(entity)) |index| {
                return &self.dense.items[index];
            }
            return null;
        }
        pub fn getConst(self: *const Self, entity: EntityId) ?*const T {
            if (self.entity_to_index.get(entity)) |index| {
                return &self.dense.items[index];
            }
            return null;
        }
        pub fn has(self: *Self, entity: EntityId) bool {
            return self.entity_to_index.contains(entity);
        }
        pub fn remove(self: *Self, entity: EntityId) bool {
            if (self.entity_to_index.fetchRemove(entity)) |kv| {
                const index = kv.value;
                const last_index = self.dense.items.len - 1;

                if (index != last_index) {
                    self.dense.items[index] = self.dense.items[last_index];
                    const last_entity = self.sparse.items[last_index];
                    self.sparse.items[index] = last_entity;
                    self.entity_to_index.put(last_entity, index) catch unreachable;
                }

                _ = self.dense.pop();
                _ = self.sparse.pop();
                return true;
            }
            return false;
        }
        // 迭代器
        pub const Iterator = struct {
            storage: *Self,
            index: usize = 0,
            pub fn next(self: *@This()) ?struct { EntityId, *T } {
                if (self.index >= self.storage.dense.items.len) return null;
                const entity = self.storage.sparse.items[self.index];
                const component = &self.storage.dense.items[self.index];
                self.index += 1;
                return .{ entity, component };
            }
        };
        pub fn iterator(self: *Self) Iterator {
            return Iterator{ .storage = self };
        }
        // 只读迭代器
        pub const ConstIterator = struct {
            storage: *const Self,
            index: usize = 0,
            pub fn next(self: *@This()) ?struct { EntityId, *const T } {
                if (self.index >= self.storage.dense.items.len) return null;
                const entity = self.storage.sparse.items[self.index];
                const component = &self.storage.dense.items[self.index];
                self.index += 1;
                return .{ entity, component };
            }
        };
        pub fn constIterator(self: *const Self) ConstIterator {
            return ConstIterator{ .storage = self };
        }
    };
}
// 世界
pub const World = struct {
    allocator: std.mem.Allocator,
    next_entity_id: EntityId = 0,
    // 基础组件存储
    players: ComponentStorage(Player), // 玩家标记
    models: ComponentStorage(Model), // 模型
    positions: ComponentStorage(Position), // 位置
    moving_targets: ComponentStorage(MovingTarget), // 移动目标（将来用于寻路）
    speeds: ComponentStorage(Speed), // 移速
    healths: ComponentStorage(Health), // 生命值
    action_status: ComponentStorage(ActionStatus), // 动作状态
    // 初始化
    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .players = ComponentStorage(Player).init(allocator),
            .models = ComponentStorage(Model).init(allocator),
            .positions = ComponentStorage(Position).init(allocator),
            .moving_targets = ComponentStorage(MovingTarget).init(allocator),
            .speeds = ComponentStorage(Speed).init(allocator),
            .healths = ComponentStorage(Health).init(allocator),
            .action_status = ComponentStorage(ActionStatus).init(allocator),
        };
    }
    // 析构
    pub fn deinit(self: *World) void {
        self.players.deinit(self.allocator);
        self.models.deinit(self.allocator);
        self.positions.deinit(self.allocator);
        self.moving_targets.deinit(self.allocator);
        self.speeds.deinit(self.allocator);
        self.healths.deinit(self.allocator);
        self.action_status.deinit(self.allocator);
    }
    // 移除实体（清理所有组件）
    fn removeEntity(self: *World, entity: EntityId) void {
        _ = self.positions.remove(entity);
        _ = self.moving_targets.remove(entity);
        _ = self.speeds.remove(entity);
        _ = self.healths.remove(entity);
        _ = self.action_status.remove(entity);
        _ = self.players.remove(entity);
    }
    // 获取变换矩阵（用于渲染）
    pub fn getTransformMatrix(self: *World, entity: EntityId) ?Mat4 {
        if (self.positions.getConst(entity)) |position| {
            return Mat4.fromTranslate(position.*);
        }
        return null;
    }
    // 创建空实体
    pub fn createEntity(self: *World) EntityId {
        const id = self.next_entity_id;
        self.next_entity_id += 1;
        return id;
    }
    // 创建基础实体
    pub fn createBaseEntity(
        self: *World,
        model: Model,
        start_pos: Position,
        base_speed: Speed,
        health_value: f32,
    ) !EntityId {
        const entity = self.createEntity();
        try self.models.set(entity, model);
        try self.positions.set(entity, start_pos);
        try self.speeds.set(entity, base_speed);
        const health = Health{
            .current = health_value,
            .max = health_value,
        };
        try self.healths.set(entity, health);
        return entity;
    }
    // 创建玩家
    pub fn createPlayer(
        self: *World,
        model: Model,
        start_pos: Position,
        base_speed: Speed,
        health_value: f32,
        player_id: u32,
        input: *Input,
    ) !EntityId {
        const player = try self.createBaseEntity(
            model,
            start_pos,
            base_speed,
            health_value,
        );
        try self.players.set(player, .{
            .player_id = player_id,
            .input = input,
        });
        return player;
    }
    // 更新所有系统
    pub fn update(self: *World, delta_time: f32) void {
        self.updateMovementSystem(delta_time);
        self.updateHealthSystem(delta_time);
    }
    // 系统：更新移动逻辑
    fn updateMovementSystem(self: *World, delta_time: f32) void {
        // 处理玩家移动
        var player_it = self.players.iterator();
        while (player_it.next()) |entry| {
            const id = entry.@"0";
            const player = entry.@"1";
            if (self.positions.get(id)) |position| {
                if (self.speeds.get(id)) |speed| {
                    const velocity = speed.* * delta_time;
                    if (player.input.isKeyPressed(.left))
                        position.* = position.add(Vec3.new(-velocity, 0, 0));
                    if (player.input.isKeyPressed(.right))
                        position.* = position.add(Vec3.new(velocity, 0, 0));
                    if (player.input.isKeyPressed(.up))
                        position.* = position.add(Vec3.new(0, 0, velocity));
                    if (player.input.isKeyPressed(.down))
                        position.* = position.add(Vec3.new(0, 0, -velocity));
                }
            }
        }

        // 处理既有位置、目标、速度的实体
        var target_it = self.moving_targets.iterator();
        while (target_it.next()) |entry| {
            const entity = entry.@"0";
            const target = entry.@"1";
            if (self.positions.get(entity)) |position| {
                if (self.speeds.get(entity)) |speed| {
                    const to_target = target.*.sub(position.*);
                    const distance = to_target.length();
                    // 如果已经到达目标点
                    if (distance < 0.01) {
                        // 到达目标，停止移动
                        position.* = target.*;
                        _ = self.moving_targets.remove(entity);
                        continue;
                    }
                    // 计算本次帧移动距离
                    const move_distance = speed.* * delta_time;
                    // 如果移动距离大于到目标的距离，直接到达
                    if (move_distance >= distance) {
                        position.* = target.*;
                        _ = self.moving_targets.remove(entity);
                    } else {
                        // 否则沿方向移动
                        const direction = to_target.norm();
                        position.* = position.*.add(direction.scale(move_distance));
                    }
                }
            }
        }
    }
    // 系统：更新生命值
    fn updateHealthSystem(self: *World, delta_time: f32) void {
        _ = delta_time;
        var health_iter = self.healths.constIterator();
        while (health_iter.next()) |entry| {
            const entity = entry[0];
            const health = entry[1];
            if (health.current <= 0) {
                // 实体死亡，移除所有组件
                self.removeEntity(entity);
            }
        }
    }
};
