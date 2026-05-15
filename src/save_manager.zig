// save_manager.zig — Region 分片存档引擎 (fridge/SQLite)
const std = @import("std");
const Allocator = std.mem.Allocator;
const fr = @import("fridge");
const BlockRegistry = @import("block_registry.zig");
const BlockId = BlockRegistry.BlockId;
const BlockState = BlockRegistry.BlockState;
const BW = @import("block_world.zig");
const BlockWorld = BW.BlockWorld;
const Chunk = BW.Chunk;
const Vec3 = @import("algebra.zig").Vec3;
const ECS = @import("zigecs");
const Comps = @import("components.zig").Components;
const Hotbar = @import("inventory.zig").Hotbar;
const PlayerInventory = @import("inventory.zig").PlayerInventory;
const EntityTypeId = @import("entity_registry.zig").EntityTypeId;
const ItemId = @import("item_registry.zig").ItemId;
const item_infos = @import("item_registry.zig").item_infos;

pub const REGION_SIZE: i32 = 32; // 每个 region 包含 32×32 区块
const CHUNK_SIZE_X: u32 = BW.CHUNK_SIZE_X;
const CHUNK_SIZE_Y: u32 = BW.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z: u32 = BW.CHUNK_SIZE_Z;
const CHUNK_BLOCKS: usize = CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z;

const bitstream = @import("bitstream.zig");
const BitWriter = bitstream.BitWriter;
const BitReader = bitstream.BitReader;

/// 按区块坐标计算所在的 region 坐标
fn chunkToRegion(cx: i32, cz: i32) struct { i32, i32 } {
    return .{ @divFloor(cx, REGION_SIZE), @divFloor(cz, REGION_SIZE) };
}

// ═══════════════════════════════════════════════════════════
//  世界元数据（world.db）
// ═══════════════════════════════════════════════════════════

const WorldRow = struct {
    id: ?i64 = null,
    created_at: []const u8,
    last_played: []const u8,
    player_pos_x: f32,
    player_pos_y: f32,
    player_pos_z: f32,
    player_health: f32,
    is_flying: i64,
};

const HotbarRow = struct {
    id: ?i64 = null,
    slot: u32,
    item_name: []const u8,
    count: u32,
};

const InventoryRow = struct {
    id: ?i64 = null,
    slot: u32,
    item_name: []const u8,
    count: u32,
};

const EntityRow = struct {
    id: ?i64 = null,
    type_id: []const u8,
    pos_x: f32,
    pos_y: f32,
    pos_z: f32,
    health: f32,
};

/// 存档列表条目
pub const SaveEntry = struct {
    name: []const u8,
    last_played: []const u8,
};

// ═══════════════════════════════════════════════════════════
//  SaveManager
// ═══════════════════════════════════════════════════════════

pub const SaveManager = struct {
    allocator: Allocator,
    save_dir: []const u8,
    world_db: fr.Session,
    /// 已打开的 region 数据库连接（key = 打包的 (rx,rz)）
    region_caches: std.AutoHashMap(i64, fr.Session),

    pub fn init(allocator: Allocator, save_name: []const u8) !SaveManager {
        const save_dir = try std.fs.path.join(allocator, &.{ "saves", save_name });
        std.fs.cwd().makePath(save_dir) catch {};
        const reg_dir = try std.fs.path.join(allocator, &.{ save_dir, "regions" });
        defer allocator.free(reg_dir);
        std.fs.cwd().makePath(reg_dir) catch {};

        const world_tmp = try std.fs.path.join(allocator, &.{ save_dir, "world.db" });
        defer allocator.free(world_tmp);
        const world_path = try allocator.dupeZ(u8, world_tmp);
        defer allocator.free(world_path);
        var wdb = try fr.Session.open(fr.SQLite3, allocator, .{ .filename = world_path });
        try wdb.conn.execAll(
            \\CREATE TABLE IF NOT EXISTS "WorldRow" (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  created_at TEXT NOT NULL DEFAULT (datetime('now')),
            \\  last_played TEXT NOT NULL DEFAULT (datetime('now')),
            \\  player_pos_x REAL NOT NULL, player_pos_y REAL NOT NULL, player_pos_z REAL NOT NULL,
            \\  player_health REAL NOT NULL,
            \\  is_flying INTEGER NOT NULL DEFAULT 0);
            \\CREATE TABLE IF NOT EXISTS "HotbarRow" (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT, slot INTEGER NOT NULL,
            \\  item_name TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 1);
            \\CREATE TABLE IF NOT EXISTS "InventoryRow" (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT, slot INTEGER NOT NULL,
            \\  item_name TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 1);
            \\CREATE TABLE IF NOT EXISTS "EntityRow" (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT, type_id TEXT NOT NULL,
            \\  pos_x REAL NOT NULL, pos_y REAL NOT NULL, pos_z REAL NOT NULL,
            \\  health REAL NOT NULL DEFAULT 100.0);
            \\PRAGMA journal_mode=WAL;
            \\PRAGMA synchronous=NORMAL;
        );

        return SaveManager{
            .allocator = allocator,
            .save_dir = save_dir,
            .world_db = wdb,
            .region_caches = std.AutoHashMap(i64, fr.Session).init(allocator),
        };
    }

    pub fn deinit(self: *SaveManager) void {
        var it = self.region_caches.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        self.region_caches.deinit();
        self.allocator.free(self.save_dir);
        self.world_db.deinit();
    }

    // ── 玩家 ──

    pub fn savePlayer(self: *SaveManager, hotbar: *const Hotbar, inventory: *const PlayerInventory, registry: *ECS.Registry) !void {
        // 清空旧的 Hotbar
        {
            var stmt = try self.world_db.conn.prepare("DELETE FROM HotbarRow", &.{});
            defer stmt.deinit();
            try stmt.exec();
        }
        // 写入热键栏
        for (&hotbar.slots, 0..) |*item, i| {
            if (item.item_id == 0) continue;
            var ins = try self.world_db.conn.prepare("INSERT INTO HotbarRow (slot, item_name, count) VALUES (?, ?, ?)", &.{});
            defer ins.deinit();
            try ins.bind(0, fr.Value{ .int = @as(i64, @intCast(i)) });
            try ins.bind(1, fr.Value{ .string = item_infos[item.item_id].name });
            try ins.bind(2, fr.Value{ .int = @as(i64, @intCast(item.count)) });
            try ins.exec();
        }

        // 写入背包
        {
            var del = try self.world_db.conn.prepare("DELETE FROM InventoryRow", &.{});
            defer del.deinit();
            try del.exec();
        }
        for (&inventory.slots, 0..) |*item, i| {
            if (item.item_id == 0) continue;
            var ins = try self.world_db.conn.prepare("INSERT INTO InventoryRow (slot, item_name, count) VALUES (?, ?, ?)", &.{});
            defer ins.deinit();
            try ins.bind(0, fr.Value{ .int = @as(i64, @intCast(i)) });
            try ins.bind(1, fr.Value{ .string = item_infos[item.item_id].name });
            try ins.bind(2, fr.Value{ .int = @as(i64, @intCast(item.count)) });
            try ins.exec();
        }

        // 查找玩家实体获取位置和生命（先删后插，保持单行）
        {
            var del = try self.world_db.conn.prepare("DELETE FROM WorldRow", &.{});
            defer del.deinit();
            try del.exec();
        }
        var view = registry.view(.{ Comps.Player, Comps.Position, Comps.Health }, .{});
        var iter = view.entityIterator();
        if (iter.next()) |entity| {
            const pos = view.get(Comps.Position, entity);
            const hp = view.get(Comps.Health, entity);
            const flying: i64 = @intFromBool(registry.has(Comps.Flying, entity));
            var ins = try self.world_db.conn.prepare(
                \\INSERT INTO WorldRow (created_at, last_played,
                \\  player_pos_x, player_pos_y, player_pos_z, player_health, is_flying)
                \\  VALUES (datetime('now'), datetime('now'), ?, ?, ?, ?, ?)
            , &.{});
            defer ins.deinit();
            try ins.bind(0, fr.Value{ .float = @as(f64, @floatCast(pos.vec.x)) });
            try ins.bind(1, fr.Value{ .float = @as(f64, @floatCast(pos.vec.y)) });
            try ins.bind(2, fr.Value{ .float = @as(f64, @floatCast(pos.vec.z)) });
            try ins.bind(3, fr.Value{ .float = @as(f64, @floatCast(hp.current)) });
            try ins.bind(4, fr.Value{ .int = flying });
            try ins.exec();
        }
    }

    pub fn loadPlayer(self: *SaveManager, hotbar: *Hotbar, inventory: *PlayerInventory, registry: *ECS.Registry) !void {
        // WorldInfo — 恢复位置、血量、飞行、物理状态
        const rows = try self.world_db.query(WorldRow).findAll();
        if (rows.len > 0) {
            const info = rows[0];
            var view = registry.view(.{ Comps.Player, Comps.Position, Comps.Health }, .{});
            var iter = view.entityIterator();
            if (iter.next()) |entity| {
                var pos = view.get(Comps.Position, entity);
                pos.vec = Vec3.new(info.player_pos_x, info.player_pos_y + 0.01, info.player_pos_z);
                // +0.01 避免浮点舍入使玩家刚好嵌在方块表面，第一帧被重力拉进方块
                var health = view.get(Comps.Health, entity);
                health.current = info.player_health;
                if (registry.tryGet(Comps.Velocity, entity)) |vel| vel.vec = Vec3.zero;
                if (registry.tryGet(Comps.OnGround, entity)) |og| og.value = true;
                if (info.is_flying != 0) registry.add(entity, Comps.Flying{});
            }
        }

        // Hotbar
        {
            const slots = try self.world_db.query(HotbarRow).findAll();
            for (slots) |s| {
                if (s.slot < 9) {
                    const id = if (ItemId.fromNameRuntime(s.item_name)) |iid| @intFromEnum(iid) else 0;
                    hotbar.slots[@as(usize, @intCast(s.slot))] = .{
                        .item_id = id,
                        .count = s.count,
                    };
                }
            }
        }

        // 背包
        {
            const slots = try self.world_db.query(InventoryRow).findAll();
            for (slots) |s| {
                if (s.slot < 27) {
                    const id = if (ItemId.fromNameRuntime(s.item_name)) |iid| @intFromEnum(iid) else 0;
                    inventory.slots[@as(usize, @intCast(s.slot))] = .{
                        .item_id = id,
                        .count = s.count,
                    };
                }
            }
        }
    }

    // ── 实体 ──

    pub fn saveAllEntities(self: *SaveManager, registry: *ECS.Registry) !void {
        {
            var stmt = try self.world_db.conn.prepare("DELETE FROM EntityRow", &.{});
            defer stmt.deinit();
            try stmt.exec();
        }
        var view = registry.view(.{ Comps.AIAgent, Comps.Position, Comps.Health }, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const agent = view.get(Comps.AIAgent, entity);
            const pos = view.get(Comps.Position, entity);
            const hp = view.get(Comps.Health, entity);
            var ins = try self.world_db.conn.prepare("INSERT INTO EntityRow (type_id, pos_x, pos_y, pos_z, health) VALUES (?, ?, ?, ?, ?)", &.{});
            defer ins.deinit();
            try ins.bind(0, fr.Value{ .string = agent.type_id.info().name });
            try ins.bind(1, fr.Value{ .float = @as(f64, @floatCast(pos.vec.x)) });
            try ins.bind(2, fr.Value{ .float = @as(f64, @floatCast(pos.vec.y)) });
            try ins.bind(3, fr.Value{ .float = @as(f64, @floatCast(pos.vec.z)) });
            try ins.bind(4, fr.Value{ .float = @as(f64, @floatCast(hp.current)) });
            try ins.exec();
        }
    }

    pub fn loadAllEntities(self: *SaveManager, registry: *ECS.Registry) !void {
        const rows = try self.world_db.query(EntityRow).findAll();
        for (rows) |row| {
            const eid = EntityTypeId.fromNameRuntime(row.type_id) orelse continue;
            const info = eid.info();
            const pos = Vec3.new(row.pos_x, row.pos_y, row.pos_z);
            const entity = registry.create();
            registry.add(entity, Comps.AIAgent{ .type_id = eid, .target = pos });
            registry.add(entity, Comps.ModelName{ .id = info.model_id });
            registry.add(entity, Comps.Position{ .vec = pos, .prev = pos });
            registry.add(entity, Comps.Velocity{ .vec = Vec3.zero });
            registry.add(entity, Comps.Collider{ .width = info.collider_width, .height = info.collider_height });
            registry.add(entity, Comps.MoveSpeed{ .value = info.move_speed });
            registry.add(entity, Comps.JumpVelocity{ .value = info.jump_vel });
            registry.add(entity, Comps.OnGround{ .value = false });
            registry.add(entity, Comps.MoveIntent{});
            registry.add(entity, Comps.Health{ .current = row.health, .max = info.health });
            registry.add(entity, Comps.AttackCooldown{ .interval = info.attack_interval });
        }
    }

    // ── 区块（per-chunk palette + bit-packed data）──

    pub fn saveChunk(self: *SaveManager, cx: i32, cz: i32, chunk: *const Chunk) !void {
        const rx, const rz = chunkToRegion(cx, cz);
        var db = try self.getOrOpenRegion(rx, rz);

        // 1. 扫描 65536 个方块，构建 block_id → palette_index 映射
        var palette_map = std.AutoHashMap(u32, u32).init(self.allocator);
        defer palette_map.deinit();
        for (chunk.blocks) |plane|
            for (plane) |col|
                for (col) |bs|
                    if (!palette_map.contains(@intFromEnum(bs.block_id)))
                        try palette_map.put(@intFromEnum(bs.block_id), @intCast(palette_map.count()));

        const palette_count = palette_map.count();

        // 2. 收集 palette 名字列表（临时数组按索引写入）
        var name_ptrs = try self.allocator.alloc([]const u8, palette_count);
        defer self.allocator.free(name_ptrs);
        var iter = palette_map.iterator();
        while (iter.next()) |entry|
            name_ptrs[entry.value_ptr.*] = BlockRegistry.block_infos[entry.key_ptr.*].name;

        // 序列化 palette: JSON 字符串数组
        var json_parts = try std.ArrayListUnmanaged(u8).initCapacity(self.allocator, 256);
        defer json_parts.deinit(self.allocator);
        try json_parts.append(self.allocator, '[');
        for (name_ptrs, 0..) |name, i| {
            if (i > 0) try json_parts.append(self.allocator, ',');
            try json_parts.append(self.allocator, '"');
            try json_parts.appendSlice(self.allocator, name);
            try json_parts.append(self.allocator, '"');
        }
        try json_parts.append(self.allocator, ']');
        const palette_json = try json_parts.toOwnedSlice(self.allocator);
        defer self.allocator.free(palette_json);

        // 3. 计算 bits_per_index
        const bpi = if (palette_count <= 1) 1 else @as(u32, @intCast(std.math.log2_int(usize, palette_count - 1) + 1));
        const total_bits = CHUNK_BLOCKS * (bpi + 4);
        const buf_size = (total_bits + 7) / 8;

        // 4. Bit-pack data
        var buf = try self.allocator.alloc(u8, buf_size);
        defer self.allocator.free(buf);
        @memset(buf, 0);
        var w = BitWriter{ .buf = buf };
        for (chunk.blocks) |plane|
            for (plane) |col|
                for (col) |bs| {
                    w.write(palette_map.get(@intFromEnum(bs.block_id)).?, bpi);
                    w.write(@intFromEnum(bs.facing), 4);
                };
        const actual = w.finish();

        // 5. 写入 DB
        var stmt = try db.conn.prepare("INSERT OR REPLACE INTO Chunks (x,z,palette,data) VALUES (?,?,?,?)", &.{});
        defer stmt.deinit();
        try stmt.bind(0, fr.Value{ .int = cx });
        try stmt.bind(1, fr.Value{ .int = cz });
        try stmt.bind(2, fr.Value{ .string = palette_json });
        try stmt.bind(3, fr.Value{ .blob = buf[0..actual] });
        try stmt.exec();
    }

    /// 尝试从存档恢复区块。返回 true 表示成功恢复，false 表示无存档需重新生成。
    pub fn loadChunk(self: *SaveManager, cx: i32, cz: i32, chunk: *Chunk) !bool {
        const rx, const rz = chunkToRegion(cx, cz);
        var db = try self.getOrOpenRegion(rx, rz);
        var stmt = try db.conn.prepare("SELECT palette, data FROM Chunks WHERE x=? AND z=?", &.{});
        defer stmt.deinit();
        try stmt.bind(0, fr.Value{ .int = cx });
        try stmt.bind(1, fr.Value{ .int = cz });
        if (!try stmt.step()) return false;

        // 1. 解析 palette（JSON 字符串数组：["grass","stone","dirt"]）
        const col0 = try stmt.column(0);
        const src = col0.string;
        // 简单 JSON 数组解析：跳过 [ 和 "，按 "," 分割
        var palette_names = std.ArrayListUnmanaged([]const u8){};
        defer palette_names.deinit(self.allocator);
        {
            var i: usize = 1;
            while (i < src.len and src[i] != ']') : (i += 1) {
                if (src[i] == '"') {
                    const start = i + 1;
                    const end = std.mem.indexOfScalarPos(u8, src, start, '"') orelse break;
                    try palette_names.append(self.allocator, src[start..end]);
                    i = end;
                }
            }
        }

        const palette_size = palette_names.items.len;
        const runtime_ids = try self.allocator.alloc(u32, palette_size);
        defer self.allocator.free(runtime_ids);
        for (palette_names.items, 0..) |name, i| {
            runtime_ids[i] = if (BlockId.fromNameRuntime(name)) |id| @intFromEnum(id) else 0;
        }

        // 2. 计算 bits_per_index
        const bpi = if (palette_size <= 1) 1 else @as(u32, @intCast(std.math.log2_int(usize, palette_size - 1) + 1));

        // 3. 解包 data
        const col1 = try stmt.column(1);
        var r = BitReader{ .buf = col1.blob };
        for (&chunk.blocks) |*plane|
            for (plane) |*col|
                for (col) |*bs| {
                    const pal_idx = r.read(bpi);
                    const facing_val = r.read(4);
                    const id = if (pal_idx < palette_size) runtime_ids[pal_idx] else 0;
                    bs.* = BlockState.init(BlockId.fromInt(id));
                    bs.facing = @enumFromInt(facing_val);
                };

        return true;
    }

    pub fn saveAllChunks(self: *SaveManager, world: *BlockWorld) !void {
        var it = world.chunks.iterator();
        while (it.next()) |entry| {
            const loaded = &entry.value_ptr.*;
            if (loaded.dirty) {
                const cx = @divExact(entry.key_ptr.x, 16);
                const cz = @divExact(entry.key_ptr.z, 16);
                try self.saveChunk(cx, cz, loaded.chunk);
                loaded.dirty = false;
            }
        }
    }

    // ── 内部：region 连接管理 ──

    fn getOrOpenRegion(self: *SaveManager, rx: i32, rz: i32) !*fr.Session {
        const key: i64 = (@as(i64, @intCast(rx)) << 32) | @as(i64, @intCast(rz)) & 0xFFFFFFFF;
        if (self.region_caches.getPtr(key)) |sess| return sess;

        const print_path = try std.fmt.allocPrint(self.allocator, "{s}/regions/r_{d}_{d}.db", .{ self.save_dir, rx, rz });
        defer self.allocator.free(print_path);
        const path = try self.allocator.dupeZ(u8, print_path);
        defer self.allocator.free(path);

        var sess = try fr.Session.open(fr.SQLite3, self.allocator, .{ .filename = path });
        try sess.conn.execAll(
            \\CREATE TABLE IF NOT EXISTS "Chunks" (
            \\  x INTEGER NOT NULL, z INTEGER NOT NULL,
            \\  palette TEXT NOT NULL,
            \\  data BLOB NOT NULL,
            \\  PRIMARY KEY (x, z)
            \\);
            \\PRAGMA journal_mode=WAL;
            \\PRAGMA synchronous=NORMAL;
        );
        try self.region_caches.put(key, sess);
        return self.region_caches.getPtr(key) orelse unreachable;
    }

    /// 世界是否已有存档（用于主菜单「继续游戏」按钮）
    pub fn exists(save_name: []const u8) bool {
        const path = std.fs.path.join(std.heap.page_allocator, &.{ "saves", save_name, "world.db" }) catch return false;
        defer std.heap.page_allocator.free(path);
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    /// 删除整个存档
    pub fn deleteSave(save_name: []const u8) !void {
        const dir = try std.fs.path.join(std.heap.page_allocator, &.{ "saves", save_name });
        defer std.heap.page_allocator.free(dir);
        std.fs.cwd().deleteTree(dir) catch {};
    }

    /// 列出所有存档（按最后游玩时间降序）
    pub fn listSaves(allocator: Allocator) ![]SaveEntry {
        var list = std.ArrayListUnmanaged(SaveEntry){};
        errdefer list.deinit(allocator);

        var dir = std.fs.cwd().openDir("saves", .{ .iterate = true }) catch return &.{};
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            const db_path = try std.fs.path.join(allocator, &.{ "saves", entry.name, "world.db" });
            const last_played = getLastPlayed(db_path) orelse "";
            allocator.free(db_path);
            try list.append(allocator, SaveEntry{
                .name = try allocator.dupe(u8, entry.name),
                .last_played = try allocator.dupe(u8, last_played),
            });
        }
        // 按 last_played 降序
        std.mem.sort(SaveEntry, list.items, {}, struct {
            fn less(_: void, a: SaveEntry, b: SaveEntry) bool {
                return std.mem.order(u8, a.last_played, b.last_played) == .gt;
            }
        }.less);
        return list.toOwnedSlice(allocator);
    }

    /// 自动生成下一个存档名（world_1, world_2, …）
    pub fn autoName(allocator: Allocator) ![]const u8 {
        var max_n: u32 = 0;
        var dir = std.fs.cwd().openDir("saves", .{ .iterate = true }) catch return allocator.dupe(u8, "world_1");
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.startsWith(u8, entry.name, "world_")) {
                const num_str = entry.name["world_".len..];
                const n = std.fmt.parseInt(u32, num_str, 10) catch continue;
                if (n > max_n) max_n = n;
            }
        }
        return std.fmt.allocPrint(allocator, "world_{d}", .{max_n + 1});
    }

    /// 从存档的 world.db 读取最后游玩时间
    fn getLastPlayed(path: []const u8) ?[]const u8 {
        const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return null;
        defer std.heap.page_allocator.free(path_z);
        var db = fr.Session.open(fr.SQLite3, std.heap.page_allocator, .{ .filename = path_z }) catch return null;
        defer db.deinit();
        const rows = db.query(WorldRow).findAll() catch return null;
        if (rows.len == 0) return null;
        return std.heap.page_allocator.dupe(u8, rows[0].last_played) catch null;
    }
};
