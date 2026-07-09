// i18n.zig — 运行时国际化（JSON 文件驱动）
// 加载流程：以英文为底图，叠上目标语言（缺失的 key 自动回退到英文）。
const std = @import("std");
const io = @import("imports.zig").io;

var map: std.StringHashMap([]const u8) = undefined;
var fallback: std.StringHashMap([]const u8) = undefined;
var allocator: std.mem.Allocator = undefined;
var initialized: bool = false;
var shared: bool = false; // map == fallback（目标语言就是英文时）

fn loadJson(alloc: std.mem.Allocator, language: []const u8) !std.StringHashMap([]const u8) {
    const path = try std.fmt.allocPrint(alloc, "resources/lang/{s}.json", .{language});
    defer alloc.free(path);

    const buffer = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(buffer);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, buffer, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var m = std.StringHashMap([]const u8).init(alloc);
    const obj = parsed.value.object;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = try alloc.dupe(u8, entry.key_ptr.*);
        const val = try alloc.dupe(u8, entry.value_ptr.*.string);
        try m.put(key, val);
    }
    return m;
}

pub fn init(alloc: std.mem.Allocator, language: []const u8) !void {
    allocator = alloc;
    errdefer initialized = false;

    fallback = try loadJson(alloc, "en");

    if (std.mem.eql(u8, language, "en")) {
        map = fallback;
        shared = true;
    } else {
        map = try loadJson(alloc, language);
        shared = false;
    }
    initialized = true;
}

pub fn deinit() void {
    if (!initialized) return;
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
    if (!shared) {
        var it2 = fallback.iterator();
        while (it2.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        fallback.deinit();
    }
    initialized = false;
}

/// 按 key 查表：目标语言 → 英文 → key 本身
pub fn tr(key: []const u8) []const u8 {
    if (!initialized) return key;
    if (map.get(key)) |v| return v;
    if (fallback.get(key)) |v| return v;
    return key;
}
