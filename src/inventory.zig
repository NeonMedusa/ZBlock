// inventory.zig — 物品数据模型与物品栏
const BlockRegistry = @import("block_registry.zig");
const BlockId = BlockRegistry.BlockId;

/// 一组物品（方块 + 数量，未来可扩展耐久、NBT 等）
pub const ItemStack = struct {
    block_id: BlockId = BlockId.fromName("air"),
    count: u32 = 0,
};

/// 9 格物品栏
pub const Hotbar = struct {
    slots: [9]ItemStack = .{
        ItemStack{ .block_id = .fromName("stone"), .count = 1 },
        ItemStack{ .block_id = .fromName("dirt"), .count = 1 },
        ItemStack{ .block_id = .fromName("grass"), .count = 1 },
        ItemStack{ .block_id = .fromName("sand"), .count = 1 },
        ItemStack{ .block_id = .fromName("water"), .count = 1 },
        ItemStack{ .block_id = .fromName("snow"), .count = 1 },
        ItemStack{ .block_id = .fromName("foo"), .count = 1 },
        ItemStack{ .block_id = .fromName("stone"), .count = 1 },
        ItemStack{ .block_id = .fromName("dirt"), .count = 1 },
    },
    selected: u32 = 0, // 0-8

    pub fn selectedBlock(self: *const Hotbar) BlockId {
        return self.slots[self.selected].block_id;
    }
};

/// 为方块分配一个易于辨识的颜色，用于物品栏色块图标
pub fn blockColor(block_id: BlockId) [4]f32 {
    const id = @intFromEnum(block_id);
    return if (id == @intFromEnum(BlockId.fromName("air"))) .{ 0, 0, 0, 0 }
    else if (id == @intFromEnum(BlockId.fromName("grass"))) .{ 0.3, 0.7, 0.2, 1.0 }
    else if (id == @intFromEnum(BlockId.fromName("stone"))) .{ 0.5, 0.5, 0.5, 1.0 }
    else if (id == @intFromEnum(BlockId.fromName("dirt"))) .{ 0.53, 0.35, 0.18, 1.0 }
    else if (id == @intFromEnum(BlockId.fromName("sand"))) .{ 0.76, 0.70, 0.50, 1.0 }
    else if (id == @intFromEnum(BlockId.fromName("water"))) .{ 0.2, 0.4, 0.8, 0.7 }
    else if (id == @intFromEnum(BlockId.fromName("snow"))) .{ 0.95, 0.95, 1.0, 1.0 }
    else if (id == @intFromEnum(BlockId.fromName("foo"))) .{ 0.8, 0.3, 0.3, 1.0 }
    else .{ 0.6, 0.4, 0.8, 1.0 };
}
