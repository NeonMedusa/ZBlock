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

fn buildDropsFlat(comptime InfosType: type, infos: InfosType) [blk: {
    @setEvalBranchQuota(5000);
    var total: usize = 0;
    for (infos) |info| total += info.drops.len;
    break :blk total;
}]ResolvedDrop {
    @setEvalBranchQuota(5000);
    var total: usize = 0;
    for (infos) |info| total += info.drops.len;
    var flat: [total]ResolvedDrop = undefined;
    var offset: usize = 0;
    for (infos) |info| {
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
    return flat;
}

pub const block_drops_flat = buildDropsFlat(@TypeOf(block_registry.block_infos), block_registry.block_infos);
pub const entity_drops_flat = buildDropsFlat(@TypeOf(entity_registry.entity_infos), entity_registry.entity_infos);

fn getDrops(comptime InfosType: type, infos: InfosType, flat: []const ResolvedDrop, idx: usize) []const ResolvedDrop {
    var start: usize = 0;
    for (infos, 0..) |_, i| {
        if (i == idx) break;
        start += infos[i].drops.len;
    }
    const count = infos[idx].drops.len;
    return flat[start..start + count];
}

pub fn getBlockDrops(block_idx: usize) []const ResolvedDrop {
    return getDrops(@TypeOf(block_registry.block_infos), block_registry.block_infos, block_drops_flat[0..], block_idx);
}

pub fn getEntityDrops(entity_idx: usize) []const ResolvedDrop {
    return getDrops(@TypeOf(entity_registry.entity_infos), entity_registry.entity_infos, entity_drops_flat[0..], entity_idx);
}
