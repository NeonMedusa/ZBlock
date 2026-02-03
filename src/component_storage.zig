// component_storage.zig
const std = @import("std");
const EntityId = u32;
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
                // 如果组件已存在则更新现有组件
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
            pub fn next(self: *Iterator) ?struct { EntityId, *T } {
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
