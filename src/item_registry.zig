// item_registry.zig — 物品注册表与原型
const std = @import("std");
const block_infos = @import("block_registry.zig").block_infos;

pub const ItemCategory = enum {
    block,
    tool,
    weapon,
    armor,
    food,
    material,
};

/// 物品原型
pub const ItemProtoType = struct {
    name: [:0]const u8,
    category: ItemCategory = .material,
    max_stack: u32 = 64,
};

/// 掉落物配置（用于方块/实体掉落）
pub const ItemDrop = struct {
    item: u32, // ItemId 原始值，运行时通过 ItemId.fromInt 转换
    min_count: u32 = 1,
    max_count: u32 = 1,
    probability: f32 = 1.0,
};

/// 物品注册表（前段 = 方块，后段 = 非方块物品）
pub const item_infos = blk: {
    const block_count = block_infos.len;
    const extras = .{
        ItemProtoType{ .name = "apple", .category = .food, .max_stack = 64 },
    };
    var result: [block_count + extras.len]ItemProtoType = undefined;
    for (0..block_count) |i| {
        result[i] = .{ .name = block_infos[i].name, .category = .block };
    }
    for (result[block_count..], extras) |*info, extra| {
        info.* = extra;
    }
    break :blk result;
};

pub const MAX_ITEMS = item_infos.len;

/// 物品 ID（不声明 variant，全部通过 fromInt 构造）
pub const ItemId = enum(u32) {
    _,
    pub fn fromInt(i: anytype) ItemId {
        return @enumFromInt(i);
    }
    pub fn info(self: ItemId) ItemProtoType {
        return item_infos[@intFromEnum(self)];
    }
    pub fn name(self: ItemId) [:0]const u8 {
        return self.info().name;
    }
    /// 如果 ID 对应一个方块，返回 BlockId
    pub fn toBlockId(self: ItemId) ?@import("block_registry.zig").BlockId {
        const v = @intFromEnum(self);
        if (v < block_infos.len) return @import("block_registry.zig").BlockId.fromInt(v);
        return null;
    }
};

/// 快捷构造常用物品 ID
pub const predefined = struct {
    pub fn apple() ItemId { return ItemId.fromInt(block_infos.len + 0); }
};
