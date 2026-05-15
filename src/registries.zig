// registries.zig — 注册表聚合层，编译期解析所有掉落物 name→id
const std = @import("std");
const block_registry = @import("block_registry.zig");
const entity_registry = @import("entity_registry.zig");
const item_registry = @import("item_registry.zig");

const ItemDropVal = block_registry.ItemDropVal;

pub const ResolvedDrop = struct {
    item_id: u32,
    min_count: u32,
    max_count: u32,
    probability: f32,
};

pub const block_drops_flat = blk: {
    @setEvalBranchQuota(5000);
    var total: usize = 0;
    for (block_registry.block_infos) |info| total += info.drops.len;

    var flat: [total]ResolvedDrop = undefined;
    var offset: usize = 0;
    for (block_registry.block_infos) |info| {
        for (info.drops, 0..) |raw_d, i| {
            flat[offset + i] = .{
                .item_id = @intFromEnum(@field(item_registry.ItemNames, raw_d.item_name)),
                .min_count = raw_d.min_count,
                .max_count = raw_d.max_count,
                .probability = raw_d.probability,
            };
        }
        offset += info.drops.len;
    }
    break :blk flat;
};

pub const entity_drops_flat = blk: {
    @setEvalBranchQuota(5000);
    var total: usize = 0;
    for (entity_registry.entity_infos) |info| total += info.drops.len;

    var flat: [total]ResolvedDrop = undefined;
    var offset: usize = 0;
    for (entity_registry.entity_infos) |info| {
        for (info.drops, 0..) |raw_d, i| {
            flat[offset + i] = .{
                .item_id = @intFromEnum(@field(item_registry.ItemNames, raw_d.item_name)),
                .min_count = raw_d.min_count,
                .max_count = raw_d.max_count,
                .probability = raw_d.probability,
            };
        }
        offset += info.drops.len;
    }
    break :blk flat;
};

pub fn getBlockDrops(block_idx: usize) []const ResolvedDrop {
    var start: usize = 0;
    for (block_registry.block_infos, 0..) |_, i| {
        if (i == block_idx) break;
        start += block_registry.block_infos[i].drops.len;
    }
    const count = block_registry.block_infos[block_idx].drops.len;
    return block_drops_flat[start..start + count];
}

pub fn getEntityDrops(entity_idx: usize) []const ResolvedDrop {
    var start: usize = 0;
    for (entity_registry.entity_infos, 0..) |_, i| {
        if (i == entity_idx) break;
        start += entity_registry.entity_infos[i].drops.len;
    }
    const count = entity_registry.entity_infos[entity_idx].drops.len;
    return entity_drops_flat[start..start + count];
}
