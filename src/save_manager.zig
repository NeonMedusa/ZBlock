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
const Vec3i = @import("algebra.zig").Vec3i;
const ECS = @import("zigecs");
const Comps = @import("components.zig").Components;
const Hotbar = @import("inventory.zig").Hotbar;

pub const REGION_SIZE: i32 = 32; // 每个 region 包含 32×32 区块
const CHUNK_SIZE_X: u32 = BW.CHUNK_SIZE_X;
const CHUNK_SIZE_Y: u32 = BW.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z: u32 = BW.CHUNK_SIZE_Z;
const CHUNK_BLOCKS: usize = CHUNK_SIZE_X * CHUNK_SIZE_Y * CHUNK_SIZE_Z;

/// 按区块坐标计算所在的 region 坐标
fn chunkToRegion(cx: i32, cz: i32) struct { i32, i32 } {
    return .{ @divFloor(cx, REGION_SIZE), @divFloor(cz, REGION_SIZE) };
}

/// 将 256KB 区块方块数据打包为 blob（每方块 4 字节：低 28 位 block_id，高 4 位 facing）
fn packBlocks(blocks: *const [CHUNK_SIZE_X][CHUNK_SIZE_Y][CHUNK_SIZE_Z]BlockState, buf: []u8) void {
    var i: usize = 0;
    for (blocks) |*plane| {
        for (plane) |*col| {
            for (col) |bs| {
                const v = @as(u32, @intCast(@intFromEnum(bs.block_id) & 0x0FFFFFFF)) |
                    (@as(u32, @intCast(@intFromEnum(bs.facing))) << 28);
                std.mem.writeInt(u32, buf[i..][0..4], v, .little);
                i += 4;
            }
        }
    }
}

fn unpackBlocks(buf: []const u8, blocks: *[CHUNK_SIZE_X][CHUNK_SIZE_Y][CHUNK_SIZE_Z]BlockState) void {
    var i: usize = 0;
    for (blocks) |*plane| {
        for (plane) |*col| {
            for (col) |*bs| {
                const v = std.mem.readInt(u32, buf[i..][0..4], .little);
                bs.* = BlockState.init(BlockId.fromInt(v & 0x0FFFFFFF));
                bs.facing = @enumFromInt((v >> 28) & 0xF);
                i += 4;
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════
//  世界元数据（world.db）
// ═══════════════════════════════════════════════════════════

const WorldRow = struct {
    id: ?i64 = null,
    schema_version: u32,
    game_version: []const u8,
    created_at: []const u8,
    last_played: []const u8,
    player_pos_x: ?f32, player_pos_y: ?f32, player_pos_z: ?f32,
    player_health: ?f32,
    spawn_pos_x: ?f32, spawn_pos_y: ?f32, spawn_pos_z: ?f32,
};

const HotbarRow = struct {
    id: ?i64 = null,
    slot: u32,
    block_id: []const u8,
    count: u32,
};

const EntityRow = struct {
    id: ?i64 = null,
    type_id: []const u8,
    pos_x: f32, pos_y: f32, pos_z: f32,
    health: f32,
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
            \\  schema_version INTEGER NOT NULL DEFAULT 1, game_version TEXT NOT NULL DEFAULT '',
            \\  created_at TEXT NOT NULL DEFAULT (datetime('now')),
            \\  last_played TEXT NOT NULL DEFAULT (datetime('now')),
            \\  player_pos_x REAL, player_pos_y REAL, player_pos_z REAL,
            \\  player_health REAL,
            \\  spawn_pos_x REAL, spawn_pos_y REAL, spawn_pos_z REAL
            \\);
            \\CREATE TABLE IF NOT EXISTS "HotbarRow" (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT, slot INTEGER NOT NULL,
            \\  block_id TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 1
            \\);
            \\CREATE TABLE IF NOT EXISTS "EntityRow" (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT, type_id TEXT NOT NULL,
            \\  pos_x REAL NOT NULL, pos_y REAL NOT NULL, pos_z REAL NOT NULL,
            \\  health REAL NOT NULL DEFAULT 100.0
            \\);
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

    pub fn savePlayer(self: *SaveManager, hotbar: *const Hotbar, registry: *ECS.Registry) !void {
        // 清空旧的 Hotbar
        {
            var stmt = try self.world_db.conn.prepare("DELETE FROM HotbarRow", &.{});
            defer stmt.deinit();
            try stmt.exec();
        }
        // 写入热键栏
        for (&hotbar.slots, 0..) |*item, i| {
            if (@intFromEnum(item.block_id) == 0) continue;
            var ins = try self.world_db.conn.prepare("INSERT INTO HotbarRow (slot, block_id, count) VALUES (?, ?, ?)", &.{});
            defer ins.deinit();
            try ins.bind(0, fr.Value{ .int = @as(i64, @intCast(i)) });
            try ins.bind(1, fr.Value{ .string = item.block_id.name() });
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
            var ins = try self.world_db.conn.prepare(
                \\INSERT INTO WorldRow (schema_version, game_version, created_at, last_played,
                \\  player_pos_x, player_pos_y, player_pos_z, player_health) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            , &.{});
            defer ins.deinit();
            try ins.bind(0, fr.Value{ .int = 1 });
            try ins.bind(1, fr.Value{ .string = "0.1" });
            try ins.bind(2, fr.Value{ .string = "" });
            try ins.bind(3, fr.Value{ .string = "" });
            try ins.bind(4, fr.Value{ .float = @as(f64, @floatCast(pos.vec.x)) });
            try ins.bind(5, fr.Value{ .float = @as(f64, @floatCast(pos.vec.y)) });
            try ins.bind(6, fr.Value{ .float = @as(f64, @floatCast(pos.vec.z)) });
            try ins.bind(7, fr.Value{ .float = @as(f64, @floatCast(hp.current)) });
            try ins.exec();
        }
    }

    pub fn loadPlayer(self: *SaveManager, hotbar: *Hotbar, registry: *ECS.Registry) !void {
        // WorldInfo — 恢复位置
        {
            const rows = try self.world_db.query(WorldRow).findAll();
            if (rows.len > 0 and rows[0].player_pos_x != null) {
                const info = rows[0];
                var view = registry.view(.{ Comps.Player, Comps.Position }, .{});
                var iter = view.entityIterator();
                if (iter.next()) |entity| {
                    var pos = view.get(Comps.Position, entity);
                    pos.vec = Vec3.new(
                        info.player_pos_x.?,
                        info.player_pos_y.?,
                        info.player_pos_z.?,
                    );
                }
            }
            if (rows.len > 0 and rows[0].player_health != null) {
                var view = registry.view(.{ Comps.Player, Comps.Health }, .{});
                var iter = view.entityIterator();
                if (iter.next()) |entity| {
                    var health = view.get(Comps.Health, entity);
                    health.current = rows[0].player_health.?;
                }
            }
        }

        // Hotbar
        {
            const slots = try self.world_db.query(HotbarRow).findAll();
            for (slots) |s| {
                if (s.slot < 9) {
                        hotbar.slots[@as(usize, @intCast(s.slot))] = .{
                            .block_id = blockIdFromName(s.block_id) orelse BlockId.fromName("air"),
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
        _ = registry;
        const rows = try self.world_db.query(EntityRow).findAll();
        _ = rows;
    }

    // ── 区块（经 region 分片） ──

    pub fn saveChunk(self: *SaveManager, cx: i32, cz: i32, chunk: *const Chunk) !void {
        const rx, const rz = chunkToRegion(cx, cz);
        var buf: [CHUNK_BLOCKS * 4]u8 = undefined;
        packBlocks(&chunk.blocks, &buf);

        var db = try self.getOrOpenRegion(rx, rz);
        var stmt = try db.conn.prepare("INSERT OR REPLACE INTO Chunks (x,z,data) VALUES (?,?,?)", &.{});
        defer stmt.deinit();
        try stmt.bind(0, fr.Value{ .int = cx });
        try stmt.bind(1, fr.Value{ .int = cz });
        try stmt.bind(2, fr.Value{ .blob = buf[0..] });
        try stmt.exec();
    }

    /// 尝试从存档恢复区块。返回 true 表示成功恢复，false 表示无存档需重新生成。
    pub fn loadChunk(self: *SaveManager, cx: i32, cz: i32, chunk: *Chunk) !bool {
        const rx, const rz = chunkToRegion(cx, cz);
        var db = try self.getOrOpenRegion(rx, rz);
        var stmt = try db.conn.prepare("SELECT data FROM Chunks WHERE x=? AND z=?", &.{});
        defer stmt.deinit();
        try stmt.bind(0, fr.Value{ .int = cx });
        try stmt.bind(1, fr.Value{ .int = cz });
        if (try stmt.step()) {
            const col = try stmt.column(0);
            if (col == .blob) {
                unpackBlocks(col.blob, &chunk.blocks);
                return true;
            }
        }
        return false;
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

    /// 删除整个存档（「新游戏」用）
    pub fn deleteSave(save_name: []const u8) !void {
        const dir = try std.fs.path.join(std.heap.page_allocator, &.{ "saves", save_name });
        defer std.heap.page_allocator.free(dir);
        std.fs.cwd().deleteTree(dir) catch {};
    }
};

/// 运行时按字符串名查找 BlockId（fromName 是 comptime 的）
fn blockIdFromName(name: []const u8) ?BlockId {
    for (BlockRegistry.block_infos, 0..) |info, i| {
        if (std.mem.eql(u8, info.name, name)) return @enumFromInt(i);
    }
    return null;
}
