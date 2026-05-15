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
pub const ItemNames = blk: {
    var fields: [MAX_ITEMS]std.builtin.Type.EnumField = undefined;
    for (&fields, item_infos, 0..) |*f, info, i|
        f.* = .{ .name = info.name, .value = i };
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = u32,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

/// 编译期物品名→ID
pub fn itemFromName(comptime name: [:0]const u8) u32 {
    return @intFromEnum(@field(ItemNames, name));
}

/// 物品 ID
pub const ItemId = enum(u32) {
    _,
    pub fn fromInt(i: anytype) ItemId {
        return @enumFromInt(i);
    }
};
