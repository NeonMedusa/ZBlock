// entity_list.zig
const std = @import("std");

// 约定usize最大值表示空
const NULL_INDEX = std.math.maxInt(usize);
const MAX_ENTITIES = @import("code_generator.zig").MAX_ENTITIES;
const EntityId = usize;

pub const EntityList = struct {
    entities: std.ArrayList(EntityId) = .{},
    sparse: [MAX_ENTITIES]usize = [_]usize{NULL_INDEX} ** MAX_ENTITIES, // 栈分配的稀疏数组

    pub fn init() EntityList {
        return .{
            .entities = std.ArrayList(EntityId){},
            .sparse = [_]usize{NULL_INDEX} ** MAX_ENTITIES,
        };
    }

    pub fn deinit(self: *EntityList, allocator: std.mem.Allocator) void {
        self.entities.deinit(allocator);
    }

    // O(1) 添加
    pub fn add(self: *EntityList, allocator: std.mem.Allocator, entity_id: EntityId) !void {
        std.debug.assert(entity_id < MAX_ENTITIES);

        if (self.sparse[entity_id] != NULL_INDEX) return; // 已存在

        const index = self.entities.items.len;
        try self.entities.append(allocator, entity_id);
        self.sparse[entity_id] = index;
    }

    // O(1) 删除
    pub fn remove(self: *EntityList, entity_id: EntityId) bool {
        std.debug.assert(entity_id < MAX_ENTITIES);

        const index = self.sparse[entity_id];
        if (index == NULL_INDEX) return false;

        const last_index = self.entities.items.len - 1;

        if (index < last_index) {
            const last_entity_id = self.entities.items[last_index];
            self.entities.items[index] = last_entity_id;
            self.sparse[last_entity_id] = index;
        }

        _ = self.entities.pop();
        self.sparse[entity_id] = NULL_INDEX;
        return true;
    }
    // 快速迭代
    pub fn items(self: *EntityList) []const EntityId {
        return self.entities.items;
    }
    // 检查是否存在
    pub fn contains(self: *EntityList, entity_id: EntityId) bool {
        std.debug.assert(entity_id < MAX_ENTITIES);
        return self.sparse[entity_id] != NULL_INDEX;
    }
    // 清空
    pub fn clear(self: *EntityList) void {
        self.entities.clearRetainingCapacity();
        @memset(&self.sparse, NULL_INDEX);
    }
    // 获取数量
    pub fn count(self: *EntityList) usize {
        return self.entities.items.len;
    }
    // 检查是否为空
    pub fn isEmpty(self: *EntityList) bool {
        return self.entities.items.len == 0;
    }
};

// 测试
test "entity_list" {
    const allocator = std.testing.allocator;

    var elist = EntityList.init();
    defer elist.deinit(allocator);

    // 测试基本操作
    try elist.add(allocator, 5);
    try elist.add(allocator, 10);
    try std.testing.expect(elist.contains(5));
    try std.testing.expect(elist.contains(10));
    try std.testing.expectEqual(@as(usize, 2), elist.count());

    // 测试删除
    try std.testing.expect(elist.remove(5));
    try std.testing.expect(!elist.contains(5));
    try std.testing.expect(elist.contains(10));
    try std.testing.expectEqual(@as(usize, 1), elist.count());
}
