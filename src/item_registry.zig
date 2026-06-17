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
    max_stack: u32 = 9999,
};

/// 物品注册表（前段 = 方块，后段 = 非方块物品）
pub const item_infos = blk: {
    const block_count = block_infos.len;
    const extras = .{
        ItemProtoType{ .name = "apple", .category = .food },
    };
    var result: [block_count + extras.len]ItemProtoType = undefined;
    for (0..block_count) |i| result[i] = .{ .name = block_infos[i].name, .category = .block };
    for (result[block_count..], extras) |*r, e| r.* = e;
    break :blk result;
};

pub const MAX_ITEMS = item_infos.len;

/// 物品名称枚举（编译期查找用）
/// 编译期物品名→ID
pub fn itemFromName(comptime name: [:0]const u8) u32 {
    inline for (&item_infos, 0..) |info, i| {
        if (comptime std.mem.eql(u8, info.name, name)) return i;
    }
    @compileError("unknown item: " ++ name);
}

/// 物品 ID
pub const ItemId = packed struct(u32) {
    id: u32,
    pub fn fromInt(i: anytype) ItemId {
        return @enumFromInt(i);
    }
    pub fn fromNameRuntime(item_name: []const u8) ?ItemId {
        for (&item_infos, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, item_name)) return @enumFromInt(i);
        }
        return null;
    }
};
