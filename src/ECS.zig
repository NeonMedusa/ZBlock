const EntityId = u32;
const Generation = u32;
const Entity = packed struct {
    id: EntityId,
    generation: Generation,
};
// 组件存储 - 使用密集数组 + 稀疏索引
pub fn ComponentStorage(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        dense: std.ArrayList(T), // 紧凑存储组件数据
        sparse: std.ArrayList(EntityId), // 实体ID到密集数组索引的映射
        entity_to_index: std.AutoHashMap(EntityId, usize), // 快速查找
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .dense = std.ArrayList(T).init(allocator),
                .sparse = std.ArrayList(EntityId).init(allocator),
                .entity_to_index = std.AutoHashMap(EntityId, usize).init(allocator),
            };
        }
        pub fn deinit(self: *Self) void {
            self.dense.deinit();
            self.sparse.deinit();
            self.entity_to_index.deinit();
        }
        pub fn add(self: *Self, entity: EntityId, component: T) !void {
            const index = self.dense.items.len;
            try self.dense.append(component);
            try self.sparse.append(entity);
            try self.entity_to_index.put(entity, index);
        }
        pub fn get(self: *Self, entity: EntityId) ?*T {
            if (self.entity_to_index.get(entity)) |index| {
                return &self.dense.items[index];
            }
            return null;
        }
        pub fn remove(self: *Self, entity: EntityId) bool {
            if (self.entity_to_index.fetchRemove(entity)) |kv| {
                const index = kv.value;
                const last_index = self.dense.items.len - 1;
                if (index != last_index) {
                    // 移动最后一个元素到删除的位置
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
        // 高效迭代所有组件
        pub fn iterator(self: *Self) ComponentIterator(T) {
            return ComponentIterator(T){
                .storage = self,
                .index = 0,
            };
        }
    };
}
// 迭代器用于高效遍历
pub fn ComponentIterator(comptime T: type) type {
    return struct {
        storage: *ComponentStorage(T),
        index: usize,
        pub fn next(self: *@This()) ?struct { EntityId, *T } {
            if (self.index >= self.storage.dense.items.len) return null;
            const entity = self.storage.sparse.items[self.index];
            const component = &self.storage.dense.items[self.index];
            self.index += 1;
            return .{ entity, component };
        }
    };
}
// 组件
pub const Position3D = Vec3;
pub const Velocity3D = Vec3;
pub const Health = struct { current: f32, max: f32 };
// 游戏世界
const World = struct {
    allocator: std.mem.Allocator,
    positions: ComponentStorage(Position3D),
    velocities: ComponentStorage(Velocity3D),
    healths: ComponentStorage(Health),
    next_entity_id: EntityId,
    pub fn init(allocator: std.mem.Allocator) World {
        return World{
            .allocator = allocator,
            .positions = ComponentStorage(Position3D).init(allocator),
            .healths = ComponentStorage(Health).init(allocator),
            .next_entity_id = 0,
        };
    }
    pub fn deinit(self: *World) void {
        self.positions.deinit();
        self.healths.deinit();
    }
    pub fn createEntity(self: *World) EntityId {
        const id = self.next_entity_id;
        self.next_entity_id += 1;
        return id;
    }
    pub fn addPosition(self: *World, entity: EntityId, pos: Position3D) !void {
        try self.positions.add(entity, pos);
    }
    pub fn addHealth(self: *World, entity: EntityId, health: Health) !void {
        try self.healths.add(entity, health);
    }
    // 高效的系统迭代示例
    pub fn updateHealthSystem(self: *World) void {
        var iter = self.healths.iterator();
        while (iter.next()) |item| {
            const entity = item[0];
            const health = item[1];
            if (health.current <= 0)
                std.debug.print("Entity {} died\n", .{entity});
        }
    }
    // 处理同时需要多个组件的系统
    pub fn updateMovementSystem(self: *World) void {
        var iter = self.positions.iterator();
        while (iter.next()) |item| {
            const entity = item[0];
            const pos = item[1];
            // 这个实体同时有位置和速度组件
            if (self.velocities.get(entity)) |vel| {
                pos = pos.add(vel);
            }
        }
    }
};

const std = @import("std");
const Algebra = @import("zalgebra");
const Vec3 = Algebra.Vec3;
const Mat4 = Algebra.Mat4;
