// ecs.zig
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
        dense: std.ArrayList(T), // 密集集连续存储所有有效的组件数据
        sparse: std.ArrayList(EntityId), // 稀疏集提供从组件到实体的反向映射
        entity_to_index: std.AutoHashMap(EntityId, usize), // 实体ID到dense/sparse数组索引的映射
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
            // 如果组件已存在则更新现有组件
            if (self.entity_to_index.get(entity)) |index| {
                self.dense.items[index] = component;
            } else { // 否则添加新组件
                const index = self.dense.items.len;
                try self.dense.append(self.allocator, component);
                try self.sparse.append(self.allocator, entity);
                try self.entity_to_index.put(entity, index);
            }
        }
        pub fn get(self: *Self, entity: EntityId) ?*T {
            if (self.entity_to_index.get(entity)) |index|
                return &self.dense.items[index];
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
    next_entity_id: EntityId = 0, // 创建新实体时可为其分配的ID
    // 以下资源注意要释放内存
    pending_entity_removals: std.ArrayList(EntityId), // 待删除实体队列
    pending_component_removals: std.ArrayList(struct { EntityId, ComponentType }), // 待删除组件队列
    available_ids: std.ArrayList(EntityId), // 可复用ID池
    system_manager: SystemManager, // 系统管理器
    signatures: std.ArrayList(Signature), // 实体签名存储
    // 组件存储
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
            .pending_entity_removals = std.ArrayList(EntityId){},
            .pending_component_removals = std.ArrayList(struct { EntityId, ComponentType }){},
            .available_ids = std.ArrayList(EntityId){},
            .system_manager = SystemManager.init(allocator),
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
        self.system_manager.deinit();
        self.pending_entity_removals.deinit(self.allocator);
        self.pending_component_removals.deinit(self.allocator);
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
    // 标记实体待删除（而不是立即删除）
    pub fn markEntityForRemoval(self: *World, entity: EntityId) !void {
        try self.pending_entity_removals.append(self.allocator, entity);
    }
    pub fn markComponentForRemoval(self: *World, entity: EntityId, comptime T: type) !void {
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
        try self.pending_component_removals.append(self.allocator, .{ entity, comp_type });
    }
    pub fn processPendingRemovals(self: *World) !void {
        // 1. 先处理组件移除
        for (self.pending_component_removals.items) |item| {
            const entity = item.@"0";
            const comp_type = item.@"1";

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
            if (removed) {
                var new_sig = self.signatures.items[entity];
                new_sig.unset(@intFromEnum(comp_type));
                self.signatures.items[entity] = new_sig;
                // 立即通知系统
                try self.system_manager.onEntityChanged(entity, new_sig);
            }
        }
        self.pending_component_removals.clearRetainingCapacity();

        // 2. 再处理实体移除
        for (self.pending_entity_removals.items) |entity| {
            try self.removeEntity(entity); // 使用现有的removeEntity方法
        }
        self.pending_entity_removals.clearRetainingCapacity();
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
        var new_sig = self.signatures.items[entity];
        new_sig.set(@intFromEnum(comp_type));
        self.signatures.items[entity] = new_sig;
        // 通知所有系统该实体已更新
        try self.system_manager.onEntityChanged(entity, new_sig);
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
        // 通知系统管理器实体被删除
        self.system_manager.onEntityRemoved(entity);
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

// 系统基类
pub const System = struct {
    // 系统关心的组件签名
    required_signature: Signature,
    // 缓存匹配的实体ID集合（有序且去重）
    entities: std.AutoArrayHashMap(EntityId, void),
    pub fn init(allocator: std.mem.Allocator, required_sig: Signature) System {
        return .{
            .required_signature = required_sig,
            .entities = std.AutoArrayHashMap(EntityId, void).init(allocator),
        };
    }
    pub fn deinit(self: *System) void {
        self.entities.deinit();
    }
    // 检查实体是否匹配系统需求
    pub fn checkEntity(self: *System, entity_sig: Signature) bool {
        return entity_sig.supersetOf(self.required_signature);
    }
    // 更新实体缓存（单个实体）
    pub fn updateEntity(self: *System, entity: EntityId, entity_sig: Signature) !void {
        const matches = self.checkEntity(entity_sig);
        if (matches) {
            try self.entities.put(entity, {});
        } else {
            _ = self.entities.swapRemove(entity);
        }
    }
    // 批量更新实体缓存（世界初始化或重置时用）
    pub fn rebuildCache(self: *System, world: *World) !void {
        self.entities.clearRetainingCapacity();
        for (world.signatures.items, 0..) |sig, i| {
            const entity = @as(EntityId, @intCast(i));
            if (self.checkEntity(sig)) {
                try self.entities.put(entity, {});
            }
        }
    }
    // 获取匹配实体的迭代器（用于系统逻辑）
    pub fn entityIterator(self: *System) EntityIterator {
        return .{ .keys = self.entities.keys() };
    }
    // 实体ID迭代器
    const EntityIterator = struct {
        keys: []const EntityId,
        index: usize = 0,
        pub fn next(self: *EntityIterator) ?EntityId {
            if (self.index >= self.keys.len) return null;
            defer self.index += 1;
            return self.keys[self.index];
        }
    };
};
// 系统示例模板，你可以复制参考它实现自己的系统
pub const SystemExampleTemplate = struct {
    base: System, // 基础系统
    total_moved_entities: u32 = 0, // 可以添加系统特有的状态
    // 初始化
    pub fn init(allocator: std.mem.Allocator) SystemExampleTemplate {
        // 定义系统关心的组件签名
        const required_sig = blk: {
            var sig = Signature.initEmpty();
            sig.set(@intFromEnum(ComponentType.moving_target));
            sig.set(@intFromEnum(ComponentType.position));
            sig.set(@intFromEnum(ComponentType.speed));
            break :blk sig;
        };
        return .{ .base = System.init(allocator, required_sig) };
    }
    // 析构
    pub fn deinit(self: *SystemExampleTemplate) void {
        self.base.deinit();
    }
    // 更新
    pub fn update(self: *SystemExampleTemplate, world: *World, delta_time: f32) void {
        var iter = self.base.entityIterator();
        while (iter.next()) |entity| {
            // 安全访问组件，因为实体已经过筛选
            const target = world.moving_targets.get(entity).?;
            const position = world.positions.get(entity).?;
            const speed = world.speeds.get(entity).?;
            // 逻辑运算
            _ = target;
            _ = position;
            _ = speed;
            _ = delta_time;
            self.total_moved_entities += 1;
        }
    }
};
// 普通实体移动系统
pub const MovementSystem = struct {
    base: System,
    // 初始化
    pub fn init(allocator: std.mem.Allocator) MovementSystem {
        const required_sig = blk: {
            var sig = Signature.initEmpty();
            sig.set(@intFromEnum(ComponentType.position));
            sig.set(@intFromEnum(ComponentType.speed));
            sig.set(@intFromEnum(ComponentType.moving_target));
            break :blk sig;
        };
        return .{ .base = System.init(allocator, required_sig) };
    }
    // 析构
    pub fn deinit(self: *MovementSystem) void {
        self.base.deinit();
    }
    // 更新
    pub fn update(self: *MovementSystem, world: *World, delta_time: f32) !void {
        var iter = self.base.entityIterator();
        while (iter.next()) |entity| {
            // 安全访问，因为实体已经过筛选
            const position = world.positions.get(entity).?;
            const speed = world.speeds.get(entity).?;
            const target = world.moving_targets.get(entity).?;
            // 处理移动逻辑
            const to_target = target.vec.sub(position.vec);
            const distance = to_target.length();
            // 如果距离目标点已经足够近，则判定为已经到达目标点，停止移动并移除目标点组件
            if (distance < 0.01) {
                position.vec = target.vec;
                try world.markComponentForRemoval(entity, MovingTarget);
                continue;
            }
            // 如果本次帧移动距离大于到目标的距离，直接到达
            const move_distance = speed.value * delta_time;
            if (move_distance >= distance) {
                position.vec = target.vec;
                try world.markComponentForRemoval(entity, MovingTarget);
                continue;
            }
            // 否则沿方向移动
            const direction = to_target.norm();
            position.vec = position.vec.add(direction.scale(move_distance));
        }
    }
};
// 玩家控制（移动）系统
pub const PlayerControlSystem = struct {
    base: System,
    // 初始化
    pub fn init(allocator: std.mem.Allocator) PlayerControlSystem {
        const required_sig = blk: {
            var sig = Signature.initEmpty();
            sig.set(@intFromEnum(ComponentType.player));
            sig.set(@intFromEnum(ComponentType.position));
            sig.set(@intFromEnum(ComponentType.speed));
            break :blk sig;
        };
        return .{ .base = System.init(allocator, required_sig) };
    }
    // 析构
    pub fn deinit(self: *PlayerControlSystem) void {
        self.base.deinit();
    }
    // 更新
    pub fn update(self: *PlayerControlSystem, world: *World, delta_time: f32) void {
        var iter = self.base.entityIterator();
        while (iter.next()) |entity| {
            // 安全访问，因为实体已经过筛选
            const player = world.players.get(entity).?;
            const position = world.positions.get(entity).?;
            const speed = world.speeds.get(entity).?;
            // 处理移动逻辑
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
};
// 健康度（血量）系统
pub const HealthSystem = struct {
    base: System, // 基础系统
    // 初始化
    pub fn init(allocator: std.mem.Allocator) HealthSystem {
        // 定义系统关心的组件签名
        const required_sig = blk: {
            var sig = Signature.initEmpty();
            sig.set(@intFromEnum(ComponentType.health));
            break :blk sig;
        };
        return .{ .base = System.init(allocator, required_sig) };
    }
    // 析构
    pub fn deinit(self: *HealthSystem) void {
        self.base.deinit();
    }
    // 更新
    pub fn update(self: *HealthSystem, world: *World, delta_time: f32) !void {
        var iter = self.base.entityIterator();
        while (iter.next()) |entity| {
            // 安全访问组件，因为实体已经过筛选
            const health = world.healths.get(entity).?;
            // 处理逻辑
            _ = delta_time;
            // 如果实体死亡，将实体标记为待删除
            if (health.current <= 0) try world.markEntityForRemoval(entity);
        }
    }
};
// 系统管理器
pub const SystemManager = struct {
    allocator: std.mem.Allocator,
    // 存储所有系统（可以使用类型映射，这里简化用列表）
    systems: std.ArrayList(*System),
    // 初始化
    pub fn init(allocator: std.mem.Allocator) SystemManager {
        return .{
            .allocator = allocator,
            .systems = std.ArrayList(*System){},
        };
    }
    // 析构
    pub fn deinit(self: *SystemManager) void {
        // 注意：这里不释放系统内存，由创建者负责
        self.systems.deinit(self.allocator);
    }
    // 注册系统
    pub fn registerSystem(self: *SystemManager, system: *System) !void {
        try self.systems.append(self.allocator, system);
    }
    // 当实体组件变化时通知所有系统
    pub fn onEntityChanged(self: *SystemManager, entity: EntityId, entity_sig: Signature) !void {
        for (self.systems.items) |system|
            try system.updateEntity(entity, entity_sig);
    }
    // 当实体被删除时通知所有系统
    pub fn onEntityRemoved(self: *SystemManager, entity: EntityId) void {
        for (self.systems.items) |system|
            _ = system.entities.swapRemove(entity);
    }
};
