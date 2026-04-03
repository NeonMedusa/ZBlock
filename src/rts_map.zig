// rts_map.zig
const std = @import("std");
const Imports = @import("imports.zig");
const Wgpu = Imports.Wgpu;
const Gctx = Imports.Gctx;
const RendCTX = Imports.RendCTX;
const VertexAttribute = @import("rend_ctx.zig").VertexAttribute;
const Material = @import("rend_ctx.zig").Material;
const MaterialConstants = RendCTX.MaterialConstants;
const RenderPipeline = Imports.RenderPipeline;
const Vec2 = Imports.Vec2;
const Vec3 = Imports.Vec3;
const Vec4 = Imports.Vec4;
const Mat4 = Imports.Mat4;
const Terrain = Imports.Terrain;
pub const RTSMap = struct {
    allocator: std.mem.Allocator,
    width: u32, // 格子列数
    height: u32, // 格子行数
    cell_size: f32, // 每个格子世界单位长度（固定）
    cells: []Cell,
    terrain: Terrain, // 视觉地形

    pub const MAX_LAYER = 10;

    pub const Cell = struct {
        passable: bool = true,
        layer: u32 = 0,
        slope: ?SlopeInfo = null,
    };

    pub const SlopeInfo = struct {
        from_layer: u32,
        to_layer: u32,
        direction: Vec2,
        length: f32,
    };

    // 创建地图，同时创建对应的地形
    pub fn init(allocator: std.mem.Allocator, gctx: *Gctx, width: u32, height: u32, cell_size: f32, max_height: f32, render_pipeline: *RenderPipeline) !RTSMap {
        const terrain_size_x = @as(f32, @floatFromInt(width)) * cell_size;
        const terrain_size_z = @as(f32, @floatFromInt(height)) * cell_size;
        const segments = width * 4;
        const terrain = try Terrain.init(allocator, gctx, Vec3.zero, 0, terrain_size_x, terrain_size_z, segments, max_height, render_pipeline);
        const cells = try allocator.alloc(Cell, width * height);
        for (cells) |*c| c.* = .{};
        return RTSMap{
            .allocator = allocator,
            .width = width,
            .height = height,
            .cell_size = cell_size,
            .cells = cells,
            .terrain = terrain, // ✅ 直接赋值
        };
    }

    pub fn deinit(self: *RTSMap) void {
        self.terrain.deinit();
        self.allocator.free(self.cells);
    }

    // 世界坐标 -> 格子索引
    pub fn worldToCell(self: *RTSMap, world_x: f32, world_z: f32) ?struct { x: u32, z: u32 } {
        const half_size_x = @as(f32, @floatFromInt(self.width)) * self.cell_size * 0.5;
        const half_size_z = @as(f32, @floatFromInt(self.height)) * self.cell_size * 0.5;
        const local_x = world_x + half_size_x;
        const local_z = world_z + half_size_z;
        if (local_x < 0 or local_z < 0) return null;
        const x = @as(u32, @intFromFloat(@floor(local_x / self.cell_size)));
        const z = @as(u32, @intFromFloat(@floor(local_z / self.cell_size)));
        if (x >= self.width or z >= self.height) return null;
        return .{ .x = x, .z = z };
    }

    // 格子中心的世界坐标
    pub fn cellToWorld(self: *RTSMap, x: u32, z: u32) struct { x: f32, z: f32 } {
        const half_size_x = @as(f32, @floatFromInt(self.width)) * self.cell_size * 0.5;
        const half_size_z = @as(f32, @floatFromInt(self.height)) * self.cell_size * 0.5;
        const center_x = -half_size_x + (@as(f32, @floatFromInt(x)) + 0.5) * self.cell_size;
        const center_z = -half_size_z + (@as(f32, @floatFromInt(z)) + 0.5) * self.cell_size;
        return .{ .x = center_x, .z = center_z };
    }

    // 根据层级获取归一化高度（0-1）
    fn getNormalizedFromLayer(layer: u32) f32 {
        const step = 1.0 / @as(f32, @floatFromInt(MAX_LAYER));
        return @as(f32, @floatFromInt(layer)) * step + step * 0.5;
    }

    // 设置圆形区域内的所有格子层级，并同步修改地形高度
    pub fn setLayer(self: *RTSMap, center_x: f32, center_z: f32, radius: f32, target_layer: u32) void {
        // 1. 更新逻辑层 cells
        const cell_radius_f = radius / self.cell_size;
        const cell_radius = @as(u32, @intFromFloat(@ceil(cell_radius_f)));
        const center_cell = self.worldToCell(center_x, center_z) orelse return;

        // 计算矩形范围
        const min_x = if (center_cell.x >= cell_radius) center_cell.x - cell_radius else 0;
        const max_x = @min(center_cell.x + cell_radius, self.width - 1);
        const min_z = if (center_cell.z >= cell_radius) center_cell.z - cell_radius else 0;
        const max_z = @min(center_cell.z + cell_radius, self.height - 1);

        for (min_z..max_z + 1) |z| {
            for (min_x..max_x + 1) |x| {
                const world_pos = self.cellToWorld(@intCast(x), @intCast(z));
                const dx = world_pos.x - center_x;
                const dz = world_pos.z - center_z;
                const dist = @sqrt(dx * dx + dz * dz);
                if (dist <= radius) {
                    self.cells[z * self.width + x].layer = target_layer;
                }
            }
        }

        // 2. 更新地形高度
        const target_normalized = getNormalizedFromLayer(target_layer);
        const local_center = self.terrain.worldToLocal(center_x, center_z);
        const segments_f = @as(f32, @floatFromInt(self.terrain.segments));
        for (0..self.terrain.segments + 1) |z| {
            for (0..self.terrain.segments + 1) |x| {
                const u = @as(f32, @floatFromInt(x)) / segments_f;
                const v = @as(f32, @floatFromInt(z)) / segments_f;
                const local_x = (u - 0.5) * self.terrain.size_x;
                const local_z = (v - 0.5) * self.terrain.size_z;
                const dx = local_x - local_center.x;
                const dz = local_z - local_center.z;
                const dist = @sqrt(dx * dx + dz * dz);
                if (dist <= radius) {
                    const idx = z * (self.terrain.segments + 1) + x;
                    self.terrain.heights[idx] = target_normalized;
                }
            }
        }
        self.terrain.calculateNormals();
        self.terrain.generateColors();
        self.terrain.updateBuffers() catch {};
    }

    /// 标记圆形区域内的所有格子为不可达
    pub fn markUnreachable(self: *RTSMap, center_x: f32, center_z: f32, radius: f32) void {
        const cell_radius = @ceil(radius / self.cell_size);
        const center_cell = self.worldToCell(center_x, center_z) orelse return;
        const radius_usize = @as(usize, @intFromFloat(cell_radius));
        for (0..radius_usize) |dz| {
            for (0..radius_usize) |dx| {
                for (0..2) |sign_z| {
                    for (0..2) |sign_x| {
                        const z_offset = if (sign_z == 0) center_cell.z - dz else center_cell.z + dz;
                        const x_offset = if (sign_x == 0) center_cell.x - dx else center_cell.x + dx;
                        if (x_offset < self.width and z_offset < self.height) {
                            // 精确判断是否在圆形内（基于世界坐标）
                            const world_pos = self.cellToWorld(@intCast(x_offset), @intCast(z_offset));
                            const dx_world = world_pos.x - center_x;
                            const dz_world = world_pos.z - center_z;
                            const dist = @sqrt(dx_world * dx_world + dz_world * dz_world);
                            if (dist <= radius) {
                                self.cells[z_offset * self.width + x_offset].passable = false;
                            }
                        }
                    }
                }
            }
        }
    }

    /// 雕刻地形并标记区域不可达（编辑器功能）
    pub fn sculptAndBlock(self: *RTSMap, center_x: f32, center_z: f32, radius: f32, strength: f32) void {
        // 1. 视觉上提升地形
        self.terrain.modifyHeightWorld(center_x, center_z, radius, strength);
        // 2. 逻辑上标记不可达
        self.markUnreachable(center_x, center_z, radius);
    }
};
