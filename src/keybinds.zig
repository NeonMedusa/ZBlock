// keybinds.zig — 按键绑定系统，支持配置文件
const std = @import("std");
const Allocator = std.mem.Allocator;
const Input = @import("input.zig");

/// 所有可配置的逻辑动作
pub const Action = enum {
    // 移动
    forward, back, left, right,
    // 动作
    jump, fly_toggle,
    sprint_toggle, sneak, swim_down,
    // UI
    pause_menu,
    toggle_inventory,
    // 鼠标
    break_block, place_block, pick_block,
    // 物品栏
    hotbar_1, hotbar_2, hotbar_3, hotbar_4, hotbar_5,
    hotbar_6, hotbar_7, hotbar_8, hotbar_9,
    hotbar_scroll_up, hotbar_scroll_down,

    fn count() comptime_int {
        return @typeInfo(Action).@"enum".fields.len;
    }
};

/// 一个逻辑动作可以绑到：键盘键 / 鼠标键 / 滚轮
pub const Binding = union(enum) {
    key: Input.Key,
    mouse: Input.MouseButton,
    scroll_up,
    scroll_down,
};

// 内置默认键位表
fn default(action: Action) Binding {
    return switch (action) {
        .forward => .{ .key = .w },
        .back => .{ .key = .s },
        .left => .{ .key = .a },
        .right => .{ .key = .d },
        .jump => .{ .key = .space },
        .fly_toggle => .{ .key = .space },
        .sprint_toggle => .{ .key = .left_shift },
        .sneak => .{ .key = .left_control },
        .swim_down => .{ .key = .left_control },
        .pause_menu => .{ .key = .escape },
        .toggle_inventory => .{ .key = .b },
        .break_block => .{ .mouse = .mouse_left },
        .place_block => .{ .mouse = .mouse_right },
        .pick_block => .{ .mouse = .mouse_middle },
        .hotbar_1 => .{ .key = .num1 },
        .hotbar_2 => .{ .key = .num2 },
        .hotbar_3 => .{ .key = .num3 },
        .hotbar_4 => .{ .key = .num4 },
        .hotbar_5 => .{ .key = .num5 },
        .hotbar_6 => .{ .key = .num6 },
        .hotbar_7 => .{ .key = .num7 },
        .hotbar_8 => .{ .key = .num8 },
        .hotbar_9 => .{ .key = .num9 },
        .hotbar_scroll_up => .scroll_up,
        .hotbar_scroll_down => .scroll_down,
    };
}

pub const Keybinds = struct {
    bindings: [Action.count()]Binding = undefined, // 按 Action 枚举索引的绑定表

    pub fn init() Keybinds {
        var kb: Keybinds = undefined;
        inline for (@typeInfo(Action).@"enum".fields, 0..) |_, i| {
            const action: Action = @enumFromInt(i);
            kb.bindings[i] = default(action);
        }
        return kb;
    }

    pub fn get(self: *const Keybinds, action: Action) Binding {
        return self.bindings[@intFromEnum(action)];
    }

    /// 边缘触发检测：按键「刚按下」、鼠标「刚点击」、滚轮「刚滚动」
    pub fn isJustPressed(self: *const Keybinds, input: *Input, action: Action) bool {
        const b = self.get(action);
        return switch (b) {
            .key => input.isKeyJustPressed(b.key),
            .mouse => input.isMouseJustPressed(b.mouse),
            .scroll_up => input.getScrollDelta().y > 0,
            .scroll_down => input.getScrollDelta().y < 0,
        };
    }

    /// 持续触发检测：按住不松
    pub fn isHeld(self: *const Keybinds, input: *Input, action: Action) bool {
        const b = self.get(action);
        return switch (b) {
            .key => input.isKeyHeld(b.key),
            .mouse => input.isMouseHeld(b.mouse),
            else => false,
        };
    }

    /// 从 JSON 文件加载，文件不存在时生成默认配置文件
    pub fn load(allocator: Allocator, path: []const u8) !Keybinds {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err != error.FileNotFound) return error.FailedToOpenConfig;
            const defaults = Keybinds.init();
            try defaults.save(path);
            return defaults;
        };
        defer file.close();
        const data = try file.readToEndAlloc(allocator, 1_000_000);
        defer allocator.free(data);

        const root = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
        defer root.deinit();
        const obj = root.value.object;

        var kb = Keybinds.init();
        var it = obj.iterator();
        while (it.next()) |entry| {
            const action = std.meta.stringToEnum(Action, entry.key_ptr.*) orelse continue;
            const val = entry.value_ptr.*;
            if (val != .string) continue;
            const b = parseBinding(val.string) orelse continue;
            kb.bindings[@intFromEnum(action)] = b;
        }
        return kb;
    }

    /// 保存当前绑定到 JSON 文件
    pub fn save(self: *const Keybinds, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll("{\n");
        inline for (@typeInfo(Action).@"enum".fields, 0..) |field, i| {
            const b = self.bindings[i];
            try file.writeAll("    \"");
            try file.writeAll(field.name);
            try file.writeAll("\": \"");
            try file.writeAll(bindingName(b));
            try file.writeAll("\"");
            if (i < Action.count() - 1) try file.writeAll(",");
            try file.writeAll("\n");
        }
        try file.writeAll("}\n");
    }

    /// 恢复默认键位并写入配置文件
    pub fn resetDefaults(path: []const u8) !void {
        const kb = Keybinds.init();
        try kb.save(path);
    }
};

fn bindingName(b: Binding) []const u8 {
    return switch (b) {
        .key => @tagName(b.key),
        .mouse => @tagName(b.mouse),
        .scroll_up => "scroll_up",
        .scroll_down => "scroll_down",
    };
}

fn parseBinding(s: []const u8) ?Binding {
    if (std.mem.eql(u8, s, "scroll_up")) return .scroll_up;
    if (std.mem.eql(u8, s, "scroll_down")) return .scroll_down;
    if (std.meta.stringToEnum(Input.Key, s)) |k| return .{ .key = k };
    if (std.meta.stringToEnum(Input.MouseButton, s)) |m| return .{ .mouse = m };
    return null;
}
