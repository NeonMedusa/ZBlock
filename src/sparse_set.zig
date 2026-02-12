// sparse_set.zig
const std = @import("std");
// 用usize最大值表示空
const NULL_INDEX = std.math.maxInt(usize);
pub fn SparseSet(comptime T: type, comptime MAX_ENTITIES: usize) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        dense: std.ArrayList(T),
        sparse: [MAX_ENTITIES]usize = [_]usize{NULL_INDEX} ** MAX_ENTITIES,
        index_to_key: std.ArrayList(usize),
        /// 初始化
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .dense = std.ArrayList(T){},
                .sparse = [_]usize{NULL_INDEX} ** MAX_ENTITIES, // 初始化为NULL_INDEX
                .index_to_key = std.ArrayList(usize){},
            };
        }
        /// 销毁
        pub fn deinit(self: *Self) void {
            self.dense.deinit(self.allocator);
            self.index_to_key.deinit(self.allocator);
        }
        /// 设置组件
        pub fn set(self: *Self, key: usize, value: T) !void {
            const existing_idx = self.sparse[key];
            // 如果组件已存在则更新
            if (existing_idx != NULL_INDEX) {
                self.dense.items[existing_idx] = value;
            } else { // 否则添加新组件
                const new_index = self.dense.items.len;
                try self.dense.append(self.allocator, value);
                try self.index_to_key.append(self.allocator, key);
                // 更新稀疏数组
                self.sparse[key] = new_index;
            }
        }
        /// 获取组件
        pub fn get(self: *Self, key: usize) ?*T {
            const index = self.sparse[key];
            if (index == NULL_INDEX) return null;
            return &self.dense.items[index];
        }
        /// 检查是否拥有组件
        pub fn has(self: *Self, key: usize) bool {
            return self.sparse[key] != NULL_INDEX;
        }
        /// 移除组件
        pub fn remove(self: *Self, key: usize) bool {
            const dense_index = self.sparse[key];
            if (dense_index == NULL_INDEX) return false;
            const last_index = self.dense.items.len - 1;
            if (dense_index < last_index) {
                // 交换移除
                const last_entity_id = self.index_to_key.items[last_index];
                // 交换组件
                self.dense.items[dense_index] = self.dense.items[last_index];
                // 交换实体ID映射
                self.index_to_key.items[dense_index] = last_entity_id;
                // 更新被移动实体的索引
                self.sparse[last_entity_id] = dense_index;
            }
            // 移除最后一个元素
            _ = self.dense.pop();
            _ = self.index_to_key.pop();
            // 标记为不存在
            self.sparse[key] = NULL_INDEX;
            return true;
        }
        // 迭代器
        const Iterator = struct {
            sparse_set: *Self,
            index: usize = 0,
            pub fn next(self: *Iterator) ?struct { usize, *T } {
                if (self.index >= self.sparse_set.dense.items.len) return null;
                const key = self.sparse_set.index_to_key.items[self.index];
                const value = &self.sparse_set.dense.items[self.index];
                self.index += 1;
                return .{ key, value };
            }
            pub fn reset(self: *Iterator) void {
                self.index = 0;
            }
        };
        /// 迭代器，获取键值对
        pub fn iterator(self: *Self) Iterator {
            return Iterator{ .sparse_set = self };
        }
        /// 获取所有已设置的键
        pub fn keys(self: *Self) []const usize {
            return self.index_to_key.items;
        }
        /// 获取所有值
        pub fn values(self: *Self) []T {
            return self.dense.items;
        }
        /// 获取已设置的键值对数量
        pub fn count(self: *Self) usize {
            return self.dense.items.len;
        }
        /// 检查是否为空
        pub fn isEmpty(self: *Self) bool {
            return self.dense.items.len == 0;
        }
    };
}
