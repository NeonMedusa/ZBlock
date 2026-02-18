const std = @import("std");

// 稀疏集，也可以称为组件存储器，用usize最大值表示空
const NULL_INDEX = std.math.maxInt(usize);
pub fn SparseSet(comptime T: type, comptime MAX_ENTITIES: usize) type {
    return struct {
        const Self = @This();
        dense: std.ArrayList(T),
        sparse: [MAX_ENTITIES]usize = [_]usize{NULL_INDEX} ** MAX_ENTITIES,
        index_to_key: std.ArrayList(usize),
        /// 初始化在栈上
        pub fn init() Self {
            return Self{
                .dense = std.ArrayList(T){},
                .sparse = [_]usize{NULL_INDEX} ** MAX_ENTITIES, // 初始化为NULL_INDEX
                .index_to_key = std.ArrayList(usize){},
            };
        }
        /// 在栈上销毁
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.dense.deinit(allocator);
            self.index_to_key.deinit(allocator);
        }
        /// 初始化在堆上
        pub fn create(allocator: std.mem.Allocator) !*Self {
            const ptr = try allocator.create(Self);
            ptr.* = Self.init();
            return ptr;
        }
        /// 在堆上销毁
        pub fn destory(self: *Self, allocator: std.mem.Allocator) void {
            self.deinit(allocator);
            allocator.destroy(self);
        }
        /// 设置组件
        pub fn set(self: *Self, allocator: std.mem.Allocator, key: usize, value: T) !void {
            const existing_idx = self.sparse[key];
            // 如果组件已存在则更新
            if (existing_idx != NULL_INDEX) {
                self.dense.items[existing_idx] = value;
            } else { // 否则添加新组件
                const new_index = self.dense.items.len;
                try self.dense.append(allocator, value);
                try self.index_to_key.append(allocator, key);
                // 更新稀疏数组
                self.sparse[key] = new_index;
            }
        }
        /// 获取组件
        pub fn getPtr(self: *Self, key: usize) ?*T {
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

/// FNV-1哈希算法，用于尽可能为每种类型分配唯一ID
pub fn typeId(T: type) u32 {
    const type_name = @typeName(T);
    const prime_num = 16777619;
    var value: u32 = 2166136261;
    for (type_name) |char|
        value = (value ^ @as(u32, @intCast(char))) *% prime_num;
    return value;
}

/// 组件管理器（也可以称为世界），内含多个不同类型的组件存储器
const CompManager = struct {
    allocator: std.mem.Allocator,
    storages: std.AutoHashMapUnmanaged(usize, struct {
        ptr: *anyopaque,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    }) = .{},

    pub fn set(self: *CompManager, entity_id: usize, comp: anytype) !void {
        const T = @TypeOf(comp);
        const type_id = typeId(T);
        const entry = try self.storages.getOrPut(self.allocator, type_id);
        if (!entry.found_existing) {
            const storage = try SparseSet(T, 8192).create(self.allocator);
            entry.value_ptr.* = .{
                .ptr = storage,
                .deinit = struct {
                    fn deinit(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                        const comp_storage: *SparseSet(T, 8192) = @ptrCast(@alignCast(ptr));
                        comp_storage.destory(alloc);
                    }
                }.deinit,
            };
        }
        const storage: *SparseSet(T, 8192) = @ptrCast(@alignCast(entry.value_ptr.ptr));
        try storage.set(self.allocator, entity_id, comp);
    }

    pub fn getPtr(self: *CompManager, entity_id: usize, comptime T: type) ?*T {
        const type_id = typeId(T);
        const entry = self.storages.getPtr(type_id) orelse return null;
        const storage: *SparseSet(T, 8192) = @ptrCast(@alignCast(entry.ptr));
        return storage.getPtr(entity_id);
    }

    pub fn deinit(self: *CompManager) void {
        var it = self.storages.valueIterator();
        while (it.next()) |entry|
            entry.deinit(entry.ptr, self.allocator);
        self.storages.deinit(self.allocator);
    }
};

// 测试用组件
const Position = struct { x: f32, y: f32 };
const Velocity = struct { x: f32, y: f32 };

// 用例
test "example" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = CompManager{ .allocator = allocator };
    defer manager.deinit();

    try manager.set(1, Position{ .x = 1, .y = 2 });
    try manager.set(1, Velocity{ .x = 3, .y = 4 });

    if (manager.getPtr(1, Position)) |pos|
        std.debug.print("\nPosition: ({d}, {d})\n", .{ pos.x, pos.y });

    if (manager.getPtr(1, Velocity)) |vel|
        std.debug.print("Velocity: ({d}, {d})\n", .{ vel.x, vel.y });
}
