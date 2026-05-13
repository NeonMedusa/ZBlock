// inventory.zig — 物品数据模型与物品栏

/// 一组物品（ID + 数量），item_id = 0 表示空气/空
pub const ItemStack = struct {
    item_id: u32 = 0,
    count: u32 = 0,
};

/// 27 格背包（3 行 × 9 列）
pub const PlayerInventory = struct {
    slots: [27]ItemStack = .{ItemStack{}} ** 27,
};

/// 9 格物品栏（ID 值：0=air, 1=grass, 2=stone, 3=dirt, 4=sand, 5=water, 6=snow, 7=foo）
pub const Hotbar = struct {
    slots: [9]ItemStack = .{
        ItemStack{ .item_id = 1, .count = 1 },
        ItemStack{ .item_id = 2, .count = 1 },
        ItemStack{ .item_id = 3, .count = 1 },
        ItemStack{ .item_id = 4, .count = 1 },
        ItemStack{ .item_id = 5, .count = 1 },
        ItemStack{ .item_id = 6, .count = 1 },
        ItemStack{ .item_id = 7, .count = 1 },
        ItemStack{ .item_id = 0, .count = 0 },
        ItemStack{ .item_id = 0, .count = 0 },
    },
    selected: u32 = 0, // 0-8
};
