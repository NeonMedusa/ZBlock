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
        ItemStack{ .block_id = .fromName("grass"), .count = 1 },
        ItemStack{ .block_id = .fromName("stone"), .count = 1 },
        ItemStack{ .block_id = .fromName("dirt"), .count = 1 },
        ItemStack{ .block_id = .fromName("sand"), .count = 1 },
        ItemStack{ .block_id = .fromName("water"), .count = 1 },
        ItemStack{ .block_id = .fromName("snow"), .count = 1 },
        ItemStack{ .block_id = .fromName("foo"), .count = 1 },
        ItemStack{ .block_id = .fromName("air"), .count = 0 },
        ItemStack{ .block_id = .fromName("air"), .count = 0 },
    },
    selected: u32 = 0, // 0-8

    pub fn selectedBlock(self: *const Hotbar) BlockId {
        return self.slots[self.selected].block_id;
    }
};
