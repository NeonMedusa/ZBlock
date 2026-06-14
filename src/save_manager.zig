// save_manager.zig — Region 分片存档引擎 (fridge/SQLite)
const std = @import("std");
const Allocator = std.mem.Allocator;
const fr = @import("fridge");
const BlockWorld = @import("block_world.zig").BlockWorld;
const Vec3 = @import("algebra.zig").Vec3;
const ECS = @import("zigecs");
const Comps = @import("components.zig").Components;
const Hotbar = @import("inventory.zig").Hotbar;
const PlayerInventory = @import("inventory.zig").PlayerInventory;
const EntityTypeId = @import("entity_registry.zig").EntityTypeId;
const item_infos = @import("item_registry.zig").item_infos;
const registries = @import("registries.zig");

pub const REGION_SIZE: i32 = 32;

/// 按区块坐标计算所在的 region 坐标
fn chunkToRegion(cx: i32, cz: i32) struct { i32, i32 } {
    return .{ @divFloor(cx, REGION_SIZE), @divFloor(cz, REGION_SIZE) };
}

// ═══════════════════════════════════════════════════════════
//  玩家数据 JSON 格式
// ═══════════════════════════════════════════════════════════

const PlayerJson = struct {
    pos: [3]f32,
    health: f32,
    flying: bool,
    facing: [2]f32,
    hotbar: [9]?ItemSlotJson,
    inventory: [27]?ItemSlotJson,
};

const ItemSlotJson = struct {
    id: []const u8,
    count: u32,
};

// ═══════════════════════════════════════════════════════════
//  世界元数据（world.db）
// ═══════════════════════════════════════════════════════════

const WorldMeta = struct {
    id: ?i64 = null,
    created_at: []const u8,
    last_played: []const u8,
    tick_count: i64 = 0,
};

const EntityRow = struct {
    id: ?i64 = null,
    type_id: []const u8,
    pos_x: f32,
    pos_y: f32,
    pos_z: f32,
    health: f32,
    facing_yaw: f32 = 0,
    facing_pitch: f32 = 0,
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
        const players_dir = try std.fs.path.join(allocator, &.{ save_dir, "players" });
        defer allocator.free(players_dir);
        std.fs.cwd().makePath(players_dir) catch {};

        const world_tmp = try std.fs.path.join(allocator, &.{ save_dir, "world.db" });
        defer allocator.free(world_tmp);
        const world_path = try allocator.dupeZ(u8, world_tmp);
        defer allocator.free(world_path);
        var wdb = try fr.Session.open(fr.SQLite3, allocator, .{ .filename = world_path });
        try wdb.conn.execAll(
            \\CREATE TABLE IF NOT EXISTS "WorldMeta" (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  created_at TEXT NOT NULL DEFAULT (datetime('now')),
            \\  last_played TEXT NOT NULL DEFAULT (datetime('now')),
            \\  tick_count INTEGER NOT NULL DEFAULT 0);
            \\CREATE TABLE IF NOT EXISTS "EntityRow" (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT, type_id TEXT NOT NULL,
            \\  pos_x REAL NOT NULL, pos_y REAL NOT NULL, pos_z REAL NOT NULL,
            \\  health REAL NOT NULL DEFAULT 100.0,
            \\  facing_yaw REAL NOT NULL DEFAULT 0, facing_pitch REAL NOT NULL DEFAULT 0);
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

    // ── 玩家（JSON 文件：players/<player_id>.json）──

    fn playerPath(self: *const SaveManager, player_id: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/players/{s}.json", .{ self.save_dir, player_id });
    }

    pub fn savePlayer(self: *SaveManager, player_id: []const u8, hotbar: *const Hotbar, inventory: *const PlayerInventory, registry: *ECS.Registry, tick_count: u64) !void {
        var pj = PlayerJson{
            .pos = undefined,
            .health = 100,
            .flying = false,
            .facing = .{ 0, 0 },
            .hotbar = .{null} ** 9,
            .inventory = .{null} ** 27,
        };

        var view = registry.view(.{ Comps.Player, Comps.Position, Comps.Health }, .{});
        var iter = view.entityIterator();
        if (iter.next()) |entity| {
            const pos = view.get(Comps.Position, entity);
            const hp = view.get(Comps.Health, entity);
            pj.pos = .{ pos.vec.x, pos.vec.y, pos.vec.z };
            pj.health = hp.current;
            pj.flying = registry.has(Comps.Flying, entity);
            if (registry.tryGet(Comps.Facing, entity)) |f| {
                pj.facing = .{ f.yaw, f.pitch };
            }
        }

        for (&hotbar.slots, 0..) |*item, i| {
            if (item.item_id == 0) continue;
            pj.hotbar[i] = ItemSlotJson{ .id = item_infos[item.item_id].name, .count = item.count };
        }
        for (&inventory.slots, 0..) |*item, i| {
            if (item.item_id == 0) continue;
            pj.inventory[i] = ItemSlotJson{ .id = item_infos[item.item_id].name, .count = item.count };
        }

        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);
        try w.print("pos:{d:.1},{d:.1},{d:.1}\n", .{ pj.pos[0], pj.pos[1], pj.pos[2] });
        try w.print("health:{d:.1}\n", .{pj.health});
        try w.print("flying:{}\n", .{pj.flying});
        try w.print("facing:{d:.4},{d:.4}\n", .{ pj.facing[0], pj.facing[1] });
        for (&pj.hotbar, 0..) |*slot, i| {
            try w.print("h{}", .{i});
            if (slot.*) |s| {
                try w.print(":{s},{d}\n", .{ s.id, s.count });
            } else {
                try w.print(":\n", .{});
            }
        }
        for (&pj.inventory, 0..) |*slot, i| {
            try w.print("i{}", .{i});
            if (slot.*) |s| {
                try w.print(":{s},{d}\n", .{ s.id, s.count });
            } else {
                try w.print(":\n", .{});
            }
        }
        const bytes = try buf.toOwnedSlice(self.allocator);

        const path = try self.playerPath(player_id);
        defer self.allocator.free(path);

        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(bytes);
        self.allocator.free(bytes);

        // 更新世界元数据的 last_played 和 tick_count
        {
            var del = try self.world_db.conn.prepare("DELETE FROM WorldMeta", &.{});
            defer del.deinit();
            try del.exec();
        }
        var ins = try self.world_db.conn.prepare(
            \\INSERT INTO WorldMeta (created_at, last_played, tick_count)
            \\  VALUES (datetime('now'), datetime('now'), ?)
        , &.{});
        defer ins.deinit();
        try ins.bind(0, fr.Value{ .int = @as(i64, @intCast(tick_count)) });
        try ins.exec();
    }

    /// 加载玩家数据，返回 tick_count（如果存档有记录）
    pub fn loadPlayer(self: *SaveManager, player_id: []const u8, hotbar: *Hotbar, inventory: *PlayerInventory, registry: *ECS.Registry) !?u64 {
        const path = blk: {
            const p = self.playerPath(player_id) catch |err| {
                std.debug.print("loadPlayer path error: {}\n", .{err});
                break :blk null;
            };
            break :blk p;
        };
        if (path) |p| {
            defer self.allocator.free(p);
            const file = std.fs.cwd().readFileAlloc(self.allocator, p, 1024 * 64) catch {
                return self.loadWorldTickCount();
            };
            defer self.allocator.free(file);

            var pj = PlayerJson{
                .pos = .{ 8, 130, 8 },
                .health = 100,
                .flying = false,
                .facing = .{ 0, 0 },
                .hotbar = .{null} ** 9,
                .inventory = .{null} ** 27,
            };
            // 解析前清空，确保未在文件中出现的槽位保持空
            @memset(hotbar.slots[0..], @import("inventory.zig").ItemStack{});
            @memset(inventory.slots[0..], @import("inventory.zig").ItemStack{});
            var lines = std.mem.splitScalar(u8, file, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                if (std.mem.startsWith(u8, line, "pos:")) {
                    var parts = std.mem.splitScalar(u8, line[4..], ',');
                    pj.pos[0] = std.fmt.parseFloat(f32, parts.next() orelse "0") catch 0;
                    pj.pos[1] = std.fmt.parseFloat(f32, parts.next() orelse "0") catch 0;
                    pj.pos[2] = std.fmt.parseFloat(f32, parts.next() orelse "0") catch 0;
                } else if (std.mem.startsWith(u8, line, "health:")) {
                    pj.health = std.fmt.parseFloat(f32, line[7..]) catch 100;
                } else if (std.mem.startsWith(u8, line, "flying:")) {
                    pj.flying = std.mem.eql(u8, line[7..], "true");
                } else if (std.mem.startsWith(u8, line, "facing:")) {
                    var parts = std.mem.splitScalar(u8, line[7..], ',');
                    pj.facing[0] = std.fmt.parseFloat(f32, parts.next() orelse "0") catch 0;
                    pj.facing[1] = std.fmt.parseFloat(f32, parts.next() orelse "0") catch 0;
                } else if (line.len > 1 and line[0] == 'h' and line[1] >= '0' and line[1] <= '8') {
                    const idx = line[1] - '0';
                    if (line.len > 3 and line[2] == ':') {
                        var parts = std.mem.splitScalar(u8, line[3..], ',');
                        pj.hotbar[idx] = ItemSlotJson{ .id = parts.next() orelse "", .count = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0 };
                    }
                } else if (line.len > 1 and line[0] == 'i') {
                    const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                    const idx = std.fmt.parseInt(u5, line[1..colon_pos], 10) catch continue;
                    if (idx >= 27) continue;
                    const after_colon = line[colon_pos + 1 ..];
                    if (after_colon.len > 0) {
                        var parts = std.mem.splitScalar(u8, after_colon, ',');
                        pj.inventory[idx] = ItemSlotJson{ .id = parts.next() orelse "", .count = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0 };
                    }
                }
            }

            var view = registry.view(.{ Comps.Player, Comps.Position, Comps.Health }, .{});
            var iter = view.entityIterator();
            if (iter.next()) |entity| {
                var pos = view.get(Comps.Position, entity);
                pos.vec = Vec3.new(pj.pos[0], pj.pos[1] + 0.01, pj.pos[2]);
                var health = view.get(Comps.Health, entity);
                health.current = pj.health;
                if (registry.tryGet(Comps.Velocity, entity)) |vel| vel.vec = Vec3.zero;
                if (registry.tryGet(Comps.OnGround, entity)) |og| og.value = true;
                if (registry.tryGet(Comps.Facing, entity)) |facing| {
                    facing.yaw = pj.facing[0];
                    facing.pitch = pj.facing[1];
                }
                if (pj.flying) registry.add(entity, Comps.Flying{});
            }

            for (pj.hotbar, 0..) |maybe_slot, i| {
                if (maybe_slot) |slot| {
                    const id = registries.item_name_to_id.get(slot.id) orelse 0;
                    hotbar.slots[i] = .{ .item_id = id, .count = slot.count };
                }
            }
            for (pj.inventory, 0..) |maybe_slot, i| {
                if (maybe_slot) |slot| {
                    const id = registries.item_name_to_id.get(slot.id) orelse 0;
                    inventory.slots[i] = .{ .item_id = id, .count = slot.count };
                }
            }

            return self.loadWorldTickCount();
        }
        return self.loadWorldTickCount();
    }

    /// 从世界元数据读取 tick_count（无玩家文件时也调用）
    fn loadWorldTickCount(self: *SaveManager) ?u64 {
        const rows = self.world_db.query(WorldMeta).findAll() catch return null;
        if (rows.len > 0) return @intCast(rows[0].tick_count);
        return null;
    }

    // ── 实体 ──

    pub fn saveAllEntities(self: *SaveManager, registry: *ECS.Registry) !void {
        {
            var stmt = try self.world_db.conn.prepare("DELETE FROM EntityRow", &.{});
            defer stmt.deinit();
            try stmt.exec();
        }
        var view = registry.view(.{ Comps.AIAgent, Comps.Position, Comps.Health, Comps.Facing }, .{});
        var iter = view.entityIterator();
        while (iter.next()) |entity| {
            const agent = view.get(Comps.AIAgent, entity);
            const pos = view.get(Comps.Position, entity);
            const hp = view.get(Comps.Health, entity);
            const facing = view.get(Comps.Facing, entity);
            var ins = try self.world_db.conn.prepare(
                \\INSERT INTO EntityRow (type_id, pos_x, pos_y, pos_z, health, facing_yaw, facing_pitch)
                \\  VALUES (?, ?, ?, ?, ?, ?, ?)
            , &.{});
            defer ins.deinit();
            try ins.bind(0, fr.Value{ .string = agent.type_id.info().name });
            try ins.bind(1, fr.Value{ .float = @as(f64, @floatCast(pos.vec.x)) });
            try ins.bind(2, fr.Value{ .float = @as(f64, @floatCast(pos.vec.y)) });
            try ins.bind(3, fr.Value{ .float = @as(f64, @floatCast(pos.vec.z)) });
            try ins.bind(4, fr.Value{ .float = @as(f64, @floatCast(hp.current)) });
            try ins.bind(5, fr.Value{ .float = @as(f64, @floatCast(facing.yaw)) });
            try ins.bind(6, fr.Value{ .float = @as(f64, @floatCast(facing.pitch)) });
            try ins.exec();
        }
    }

    pub fn loadAllEntities(self: *SaveManager, registry: *ECS.Registry) !void {
        const rows = try self.world_db.query(EntityRow).findAll();
        for (rows) |row| {
            const eid = EntityTypeId.fromInt(registries.entity_name_to_id.get(row.type_id) orelse continue);
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
            registry.add(entity, Comps.Facing{ .yaw = row.facing_yaw, .pitch = row.facing_pitch });
        }
    }

    // ── 区块（由 IO worker 异步处理 save/load，主线程不直接调用）──

    pub fn saveAllChunks(_: *SaveManager, world: *BlockWorld) !void {
        var save_count: u32 = 0;
        var it = world.chunks.iterator();
        while (it.next()) |entry| {
            const loaded = &entry.value_ptr.*;
            if (loaded.dirty) {
                world.enqueueSaveTask(entry.key_ptr.*, loaded.chunk) catch |err| {
                    std.debug.print("saveChunk enqueue error: {}\n", .{err});
                    continue;
                };
                loaded.dirty = false;
                save_count += 1;
            }
        }
        world.flushIO();
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
            \\PRAGMA busy_timeout=5000;
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
        const rows = db.query(WorldMeta).findAll() catch return null;
        if (rows.len == 0) return null;
        return std.heap.page_allocator.dupe(u8, rows[0].last_played) catch null;
    }
};
