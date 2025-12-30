const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
const Input = @import("input.zig");
const Key = Input.Key;

pub const EntityId = u32;
pub const Player = struct {
    player_id: u32 = 0, // 用于区分不同玩家（联机时有用）
    input: *Input,
};
pub const Model = @import("model.zig").ModelName;
// 有时我们需要做类型判断，所以需要包装成独立结构体
pub const Position = struct { vec: Vec3 };
pub const MovingTarget = struct { vec: Vec3 };
pub const Speed = struct { value: f32 };
pub const Health = struct {
    current: f32,
    max: f32,
};
// 将来可能用于动画系统，但这可能不是一个好的设计，为了支持多个动画，可能应该用bitset
pub const ActionStatus = enum {
    moving,
    idel,
};
// 组件签名（bitset），用于更优雅的组件匹配
pub const ComponentType = enum(u16) {
    player,
    model,
    position,
    moving_target,
    speed,
    health,
    action_status,
    _count, // 用于获取组件类型总数，必须放在最后
};
pub const Signature = std.StaticBitSet(@intFromEnum(ComponentType._count));
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
        pub fn get(self: *Self, entity: EntityId) ?*T {
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
        const Iterator = struct {
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
    };
}
// 世界
pub const World = struct {
    allocator: std.mem.Allocator,
    next_entity_id: EntityId = 0,
    available_ids: std.ArrayList(EntityId), // 可用ID池
    // 实体签名存储
    signatures: std.ArrayList(Signature),
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
            .available_ids = std.ArrayList(EntityId){},
            .signatures = std.ArrayList(Signature){},
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
        self.available_ids.deinit(self.allocator);
        self.signatures.deinit(self.allocator);
        self.players.deinit(self.allocator);
        self.models.deinit(self.allocator);
        self.positions.deinit(self.allocator);
        self.moving_targets.deinit(self.allocator);
        self.speeds.deinit(self.allocator);
        self.healths.deinit(self.allocator);
        self.action_status.deinit(self.allocator);
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
            sig.set(@intFromEnum(ComponentType.player));
            sig.set(@intFromEnum(ComponentType.position));
            sig.set(@intFromEnum(ComponentType.speed));
            break :blk sig;
        };
        // 可移动实体组件签名
        const mobile_entity_sig = blk: {
            var sig = Signature.initEmpty();
            sig.set(@intFromEnum(ComponentType.position));
            sig.set(@intFromEnum(ComponentType.speed));
            sig.set(@intFromEnum(ComponentType.moving_target));
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
                    _ = self.removeComponent(entity, MovingTarget);
                    continue;
                }
                // 如果本次帧移动距离大于到目标的距离，直接到达
                const move_distance = speed.value * delta_time;
                if (move_distance >= distance) {
                    position.vec = target.vec;
                    _ = self.removeComponent(entity, MovingTarget);
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
        const comp_type: ComponentType = switch (T) {
            Player => .player,
            Model => .model,
            Position => .position,
            MovingTarget => .moving_target,
            Speed => .speed,
            Health => .health,
            ActionStatus => .action_status,
            else => @compileError("Unsupported component type"),
        };
        // 存储组件数据
        switch (comp_type) {
            .player => try self.players.set(entity, component),
            .model => try self.models.set(entity, component),
            .position => try self.positions.set(entity, component),
            .moving_target => try self.moving_targets.set(entity, component),
            .speed => try self.speeds.set(entity, component),
            .health => try self.healths.set(entity, component),
            .action_status => try self.action_status.set(entity, component),
            else => unreachable,
        }
        // 更新实体签名（设置对应位为1）
        var sig = self.signatures.items[entity];
        sig.set(@intFromEnum(comp_type));
        self.signatures.items[entity] = sig;
    }
    // 移除组件并更新签名
    pub fn removeComponent(self: *World, entity: EntityId, comptime T: type) bool {
        const comp_type: ComponentType = switch (T) {
            Player => .player,
            Model => .model,
            Position => .position,
            MovingTarget => .moving_target,
            Speed => .speed,
            Health => .health,
            ActionStatus => .action_status,
            else => @compileError("Unsupported component type"),
        };
        var removed = false;
        switch (comp_type) {
            .player => removed = self.players.remove(entity),
            .model => removed = self.models.remove(entity),
            .position => removed = self.positions.remove(entity),
            .moving_target => removed = self.moving_targets.remove(entity),
            .speed => removed = self.speeds.remove(entity),
            .health => removed = self.healths.remove(entity),
            .action_status => removed = self.action_status.remove(entity),
            else => unreachable,
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
        _ = self.action_status.remove(entity);
    }
    // 创建基础实体
    pub fn createBaseEntity(
        self: *World,
        model: Model,
        start_pos: Position,
        base_speed: Speed,
        health: Health,
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
        model: Model,
        start_pos: Position,
        base_speed: Speed,
        health: Health,
        player: Player,
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
