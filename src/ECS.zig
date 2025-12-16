const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
// 实体ID
pub const EntityId = u32;
// 基础组件定义
pub const Model = @import("model.zig").ModelName;
pub const Position = Vec3; // 位置
pub const Target = Vec3; // 目标位置
pub const Speed = f32; // 移动速度
pub const Health = struct { // 生命值
    current: f32,
    max: f32,
};
// 状态标志组件
pub const Moving = bool; // 是否正在移动（可选）
pub const Buff = struct { // 增益效果（示例）
    speed_multiplier: f32 = 1.0, // 速度乘数
    duration: f32, // 持续时间
};
// 优化的组件存储
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
// 世界定义
pub const World = struct {
    allocator: std.mem.Allocator,
    next_entity_id: EntityId = 0,
    // 基础组件存储
    models: ComponentStorage(Model),
    positions: ComponentStorage(Position),
    targets: ComponentStorage(Target),
    speeds: ComponentStorage(Speed),
    healths: ComponentStorage(Health),
    // 可选组件存储
    movings: ComponentStorage(Moving), // 移动状态
    buffs: ComponentStorage(Buff), // 增益效果
    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .models = ComponentStorage(Model).init(allocator),
            .positions = ComponentStorage(Position).init(allocator),
            .targets = ComponentStorage(Target).init(allocator),
            .speeds = ComponentStorage(Speed).init(allocator),
            .healths = ComponentStorage(Health).init(allocator),
            .movings = ComponentStorage(Moving).init(allocator),
            .buffs = ComponentStorage(Buff).init(allocator),
        };
    }
    pub fn deinit(self: *World) void {
        self.models.deinit(self.allocator);
        self.positions.deinit(self.allocator);
        self.targets.deinit(self.allocator);
        self.speeds.deinit(self.allocator);
        self.healths.deinit(self.allocator);
        self.movings.deinit(self.allocator);
        self.buffs.deinit(self.allocator);
    }
    pub fn createEntity(self: *World) EntityId {
        const id = self.next_entity_id;
        self.next_entity_id += 1;
        return id;
    }
    // 组件添加方法
    pub fn setModel(self: *World, entity: EntityId, model: Model) !void {
        try self.models.set(entity, model);
    }
    pub fn setPosition(self: *World, entity: EntityId, position: Position) !void {
        try self.positions.set(entity, position);
    }
    pub fn setTarget(self: *World, entity: EntityId, target: Target) !void {
        try self.targets.set(entity, target);
        // 添加目标时自动设置移动状态
        if (!self.movings.has(entity)) {
            try self.movings.set(entity, true);
        }
    }
    // 移除目标（停止移动）
    pub fn removeTarget(self: *World, entity: EntityId) void {
        _ = self.targets.remove(entity);
        _ = self.movings.remove(entity);
    }
    pub fn setSpeed(self: *World, entity: EntityId, speed: Speed) !void {
        try self.speeds.set(entity, speed);
    }
    pub fn setHealth(self: *World, entity: EntityId, health: Health) !void {
        try self.healths.set(entity, health);
    }
    pub fn setBuff(self: *World, entity: EntityId, buff: Buff) !void {
        try self.buffs.set(entity, buff);
    }
    // 更新所有系统
    pub fn update(self: *World, delta_time: f32) void {
        self.updateBuffSystem(delta_time);
        self.updateMovementSystem(delta_time);
        self.updateHealthSystem(delta_time);
    }
    // 系统：更新移动逻辑
    fn updateMovementSystem(self: *World, delta_time: f32) void {
        // 只处理既有位置、目标、速度的实体
        var target_iter = self.targets.iterator();
        while (target_iter.next()) |entry| {
            const entity = entry[0];
            const target = entry[1];

            if (self.positions.get(entity)) |position| {
                if (self.speeds.get(entity)) |speed| {
                    const to_target = target.*.sub(position.*);
                    const distance = to_target.length();

                    // 如果已经到达目标点
                    if (distance < 0.01) {
                        // 到达目标，停止移动
                        position.* = target.*;
                        self.removeTarget(entity);
                        continue;
                    }

                    // 计算实际速度（考虑增益效果）
                    var actual_speed = speed.*;
                    if (self.buffs.get(entity)) |buff| {
                        actual_speed *= buff.speed_multiplier;
                    }

                    // 计算本次帧移动距离
                    const move_distance = actual_speed * delta_time;

                    // 如果移动距离大于到目标的距离，直接到达
                    if (move_distance >= distance) {
                        position.* = target.*;
                        self.removeTarget(entity);
                    } else {
                        // 否则沿方向移动
                        const direction = to_target.norm();
                        position.* = position.*.add(direction.scale(move_distance));
                    }
                }
            }
        }
    }
    // 系统：更新增益效果
    fn updateBuffSystem(self: *World, delta_time: f32) void {
        var buff_iter = self.buffs.iterator();
        while (buff_iter.next()) |entry| {
            const entity = entry[0];
            const buff = entry[1];

            buff.duration -= delta_time;

            // 如果持续时间结束，移除增益
            if (buff.duration <= 0) {
                _ = self.buffs.remove(entity);
            }
        }
    }
    // 系统：更新生命值（示例）
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
    // 移除实体（清理所有组件）
    fn removeEntity(self: *World, entity: EntityId) void {
        _ = self.positions.remove(entity);
        _ = self.targets.remove(entity);
        _ = self.speeds.remove(entity);
        _ = self.healths.remove(entity);
        _ = self.movings.remove(entity);
        _ = self.buffs.remove(entity);
    }
    // 创建移动实体（便捷方法）
    pub fn createFullEntity(
        self: *World,
        model: Model,
        start_pos: Position,
        target_pos: Target,
        base_speed: Speed,
        health_value: f32,
    ) !EntityId {
        const entity = self.createEntity();
        try self.setModel(entity, model);
        try self.setPosition(entity, start_pos);
        try self.setTarget(entity, target_pos);
        try self.setSpeed(entity, base_speed);

        const health = Health{
            .current = health_value,
            .max = health_value,
        };
        try self.setHealth(entity, health);

        return entity;
    }
    // 应用速度增益（例如技能效果）
    pub fn applySpeedBuff(self: *World, entity: EntityId, multiplier: f32, duration: f32) !void {
        const buff = Buff{
            .speed_multiplier = multiplier,
            .duration = duration,
        };
        try self.setBuff(entity, buff);
    }
    // 获取实体的实际速度（考虑增益）
    pub fn getActualSpeed(self: *World, entity: EntityId) ?f32 {
        if (self.speeds.getConst(entity)) |speed| {
            var actual_speed = speed.*;
            if (self.buffs.getConst(entity)) |buff| {
                actual_speed *= buff.speed_multiplier;
            }
            return actual_speed;
        }
        return null;
    }
    // 获取变换矩阵（用于渲染）
    pub fn getTransformMatrix(self: *World, entity: EntityId) ?Mat4 {
        if (self.positions.getConst(entity)) |position| {
            return Mat4.fromTranslate(position.*);
        }
        return null;
    }
    // 检查实体是否正在移动
    pub fn isMoving(self: *World, entity: EntityId) bool {
        return self.targets.has(entity);
    }
};
