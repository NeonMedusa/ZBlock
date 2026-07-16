const io = @import("imports.zig").io;
// config.zig — 用户设置（语言/用户名），自动加载与保存 JSON
const std = @import("std");
const Allocator = std.mem.Allocator;

/// 语言枚举（当前支持 zh/en，扩展只需加枚举值 + 翻译资源）
pub const Language = enum {
    zh,
    en,

    pub fn fromString(s: []const u8) Language {
        return std.meta.stringToEnum(Language, s) orelse .zh;
    }

    pub fn toString(self: Language) []const u8 {
        return @tagName(self);
    }
};

/// 用户设置
pub const Settings = struct {
    language: Language = .zh,
    player_name: []const u8 = "", // 留空 = 运行时随机生成
    chunk_radius: i32 = 16, // 区块加载半径（4=小地图/低配, 16=默认, 32=大地图/高显存）

    const path = "config/settings.json";

    /// 从配置文件加载，文件不存在时生成默认配置
    pub fn load(allocator: Allocator) !Settings {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096)) catch |err| {
            if (err != error.FileNotFound) return error.FailedToOpenConfig;
            const defaults = Settings{};
            try defaults.save();
            return defaults;
        };
        defer allocator.free(data);

        const root = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
        defer root.deinit();
        const obj = root.value.object;

        const lang = if (obj.get("language")) |v|
            if (v == .string) Language.fromString(v.string) else Language.zh
        else
            Language.zh;

        const name = if (obj.get("player_name")) |v|
            if (v == .string) try allocator.dupe(u8, v.string) else ""
        else
            "";

        const radius = if (obj.get("chunk_radius")) |v|
            if (v == .integer) @as(i32, @intCast(v.integer)) else @as(i32, 16)
        else
            @as(i32, 16);

        return Settings{ .language = lang, .player_name = name, .chunk_radius = radius };
    }

    /// 保存设置到配置文件
    pub fn save(self: *const Settings) !void {
        std.Io.Dir.cwd().createDirPath(io, "config") catch {};
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(std.heap.page_allocator);
        const a = std.heap.page_allocator;
        try buf.appendSlice(a, "{\n");
        try buf.appendSlice(a, "    \"language\": \"");
        try buf.appendSlice(a, self.language.toString());
        try buf.appendSlice(a, "\",\n");
        try buf.appendSlice(a, "    \"player_name\": \"");
        try buf.appendSlice(a, self.player_name);
        try buf.appendSlice(a, "\",\n");
        {
            var rad_buf: [16]u8 = undefined;
            const rad_str = try std.fmt.bufPrint(&rad_buf, "{}", .{self.chunk_radius});
            try buf.appendSlice(a, "    \"chunk_radius\": ");
            try buf.appendSlice(a, rad_str);
            try buf.appendSlice(a, "\n");
        }
        try buf.appendSlice(a, "}\n");
        try file.writeStreamingAll(io, buf.items);
    }

    /// 回到默认并写入文件
    pub fn resetDefaults() !void {
        const defaults = Settings{};
        try defaults.save();
    }
};
