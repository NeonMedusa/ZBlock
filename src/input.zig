// input.zig:
const Input = @This();
game_ptr: *Game,
// 当前键鼠状态
key_states: [512]KeyState = [_]KeyState{.up} ** 512,
mouse_states: [8]KeyState = [_]KeyState{.up} ** 8,
// 上一帧键鼠状态
prev_key_states: [512]KeyState = [_]KeyState{.up} ** 512,
prev_mouse_states: [8]KeyState = [_]KeyState{.up} ** 8,
mouse_x: f64 = 0,
mouse_y: f64 = 0,
prev_mouse_x: f64 = 0,
prev_mouse_y: f64 = 0,
mouse_dx: f64 = 0,
mouse_dy: f64 = 0,
scroll_x: f64 = 0,
scroll_y: f64 = 0,
//初始化
pub fn init(game: *Game) @This() {
    return .{ .game_ptr = game };
}
// 帧开始时重置状态
pub fn beginFrame(self: *Input) void {
    @memcpy(&self.prev_key_states, &self.key_states);
    @memcpy(&self.prev_mouse_states, &self.mouse_states);
    self.prev_mouse_x = self.mouse_x;
    self.prev_mouse_y = self.mouse_y;
    self.mouse_dx = 0;
    self.mouse_dy = 0;
    self.scroll_x = 0;
    self.scroll_y = 0;
}
// 更新按键状态（在GLFW回调中调用）
pub fn updateKeyState(self: *Input, key: i32, action: i32) void {
    if (key < 0 or key >= self.key_states.len) return;
    const state: KeyState = switch (action) {
        Glfw.GLFW_PRESS => .down,
        Glfw.GLFW_RELEASE => .up,
        Glfw.GLFW_REPEAT => .down, // 重复按键视为按住
        else => return,
    };
    self.key_states[@as(usize, @intCast(key))] = state;
}
// 更新鼠标按钮状态（在GLFW回调中调用）
pub fn updateMouseButtonState(self: *Input, button: i32, action: i32) void {
    if (button < 0 or button >= self.mouse_states.len) return;
    const state: KeyState = switch (action) {
        Glfw.GLFW_PRESS => .down,
        Glfw.GLFW_RELEASE => .up,
        else => return,
    };
    self.mouse_states[@as(usize, @intCast(button))] = state;
}
// 更新鼠标光标状态（在GLFW回调中调用）
pub fn updateMousePos(self: *Input, x: f64, y: f64) void {
    // 计算鼠标移动量
    self.mouse_dx = x - self.mouse_x;
    self.mouse_dy = y - self.mouse_y;
    self.mouse_x = x;
    self.mouse_y = y;
}
// 更新鼠标滚轮状态（在GLFW回调中调用）
pub fn updateScroll(self: *Input, xoffset: f64, yoffset: f64) void {
    self.scroll_x = xoffset;
    self.scroll_y = yoffset;
}

// 按键状态查询函数（可在游戏循环中调用）
pub fn isKeyDown(self: *const Input, key: Key) bool {
    const keyCode = @intFromEnum(key);
    if (keyCode < 0 or keyCode >= self.key_states.len) return false;
    const idx = @as(usize, @intCast(keyCode));
    return (self.key_states[idx] == .down and self.prev_key_states[idx] == .up);
}
pub fn isKeyPressed(self: *const Input, key: Key) bool {
    const keyCode = @intFromEnum(key);
    if (keyCode < 0 or keyCode >= self.key_states.len) return false;
    return self.key_states[@as(usize, @intCast(keyCode))] == .down;
}
pub fn isKeyUp(self: *const Input, key: Key) bool {
    const keyCode = @intFromEnum(key);
    if (keyCode < 0 or keyCode >= self.key_states.len) return false;
    const idx = @as(usize, @intCast(keyCode));
    return (self.key_states[idx] == .up and self.prev_key_states[idx] == .down);
}
// 鼠标状态查询函数（可在游戏循环中调用）
pub fn isMouseButtonPressed(self: *const Input, mouse_button: MouseButton) bool {
    const mouse_button_code = @intFromEnum(mouse_button);
    if (mouse_button_code < 0 or mouse_button_code >= self.mouse_states.len) return false;
    const idx = @as(usize, @intCast(mouse_button_code));
    return (self.mouse_states[idx] == .down and self.prev_mouse_states[idx] == .up);
}
pub fn isMouseButtonDown(self: *const Input, mouse_button: MouseButton) bool {
    const mouse_button_code = @intFromEnum(mouse_button);
    if (mouse_button_code < 0 or mouse_button_code >= self.mouse_states.len) return false;
    return self.mouse_states[@as(usize, @intCast(mouse_button_code))] == .down;
}
pub fn isMouseButtonReleased(self: *const Input, mouse_button: MouseButton) bool {
    const mouse_button_code = @intFromEnum(mouse_button);
    if (mouse_button_code < 0 or mouse_button_code >= self.mouse_states.len) return false;
    const idx = @as(usize, @intCast(mouse_button_code));
    return (self.mouse_states[idx] == .up and self.prev_mouse_states[idx] == .down);
}
/// 以GLFW回调的方式获取的鼠标位置，或许相较于getCursorPosThroughPolling函数的延迟更低
pub fn getCursorPos(self: *const Input) struct { x: f64, y: f64 } {
    return .{ .x = self.mouse_x, .y = self.mouse_y };
}
///以轮询的方式获取的鼠标位置，或许相较于getCursorPos函数的延迟更高，不推荐使用
pub fn getCursorPosThroughPolling(self: @This()) struct { x: f64, y: f64 } {
    var x: f64 = 0;
    var y: f64 = 0;
    Glfw.glfwGetCursorPos(self.game_ptr.window.handle, &x, &y);
    return .{ .x = x, .y = y };
}
///返回光标上一帧和这一帧之间的位置差距，注意：调用setCursorPos和setCursorToCenter函数会触发cursorPosCallback，从而影响到此函数的返回结果
pub fn getCursorDelta(self: *const Input) struct { x: f64, y: f64 } {
    return .{ .x = self.mouse_dx, .y = self.mouse_dy };
}
pub fn getScroll(self: *const Input) struct { x: f64, y: f64 } {
    return .{ .x = self.scroll_x, .y = self.scroll_y };
}
///注意：调用此数会触发cursorPosCallback，从而影响到getMouseDelta函数的返回结果
pub fn setCursorPos(self: @This(), xpos: f64, ypos: f64) void {
    Glfw.glfwSetCursorPos(self.game_ptr.window.handle, xpos, ypos);
}
///注意：调用此数会触发cursorPosCallback，从而影响到getMouseDelta函数的返回结果
pub fn setCursorToCenter(self: @This()) void {
    self.setCursorPos(self.game_ptr.window.center_x, self.game_ptr.window.center_y);
}
// 按键状态
pub const KeyState = enum {
    up, // 按键未按下
    down, // 按键被按下（可能已经持续多帧）
};
// 鼠标按键
pub const MouseButton = enum(i32) {
    mouse_left = Glfw.GLFW_MOUSE_BUTTON_LEFT,
    mouse_right = Glfw.GLFW_MOUSE_BUTTON_RIGHT,
};
// 键盘按键
pub const Key = enum(i32) {
    // 字母键
    a = Glfw.GLFW_KEY_A,
    b = Glfw.GLFW_KEY_B,
    c = Glfw.GLFW_KEY_C,
    d = Glfw.GLFW_KEY_D,
    e = Glfw.GLFW_KEY_E,
    f = Glfw.GLFW_KEY_F,
    g = Glfw.GLFW_KEY_G,
    h = Glfw.GLFW_KEY_H,
    i = Glfw.GLFW_KEY_I,
    j = Glfw.GLFW_KEY_J,
    k = Glfw.GLFW_KEY_K,
    l = Glfw.GLFW_KEY_L,
    m = Glfw.GLFW_KEY_M,
    n = Glfw.GLFW_KEY_N,
    o = Glfw.GLFW_KEY_O,
    p = Glfw.GLFW_KEY_P,
    q = Glfw.GLFW_KEY_Q,
    r = Glfw.GLFW_KEY_R,
    s = Glfw.GLFW_KEY_S,
    t = Glfw.GLFW_KEY_T,
    u = Glfw.GLFW_KEY_U,
    v = Glfw.GLFW_KEY_V,
    w = Glfw.GLFW_KEY_W,
    x = Glfw.GLFW_KEY_X,
    y = Glfw.GLFW_KEY_Y,
    z = Glfw.GLFW_KEY_Z,
    // 数字键
    num0 = Glfw.GLFW_KEY_0,
    num1 = Glfw.GLFW_KEY_1,
    num2 = Glfw.GLFW_KEY_2,
    num3 = Glfw.GLFW_KEY_3,
    num4 = Glfw.GLFW_KEY_4,
    num5 = Glfw.GLFW_KEY_5,
    num6 = Glfw.GLFW_KEY_6,
    num7 = Glfw.GLFW_KEY_7,
    num8 = Glfw.GLFW_KEY_8,
    num9 = Glfw.GLFW_KEY_9,
    // 功能键
    space = Glfw.GLFW_KEY_SPACE,
    escape = Glfw.GLFW_KEY_ESCAPE,
    enter = Glfw.GLFW_KEY_ENTER,
    tab = Glfw.GLFW_KEY_TAB,
    backspace = Glfw.GLFW_KEY_BACKSPACE,
    insert = Glfw.GLFW_KEY_INSERT,
    delete = Glfw.GLFW_KEY_DELETE,
    right = Glfw.GLFW_KEY_RIGHT,
    left = Glfw.GLFW_KEY_LEFT,
    down = Glfw.GLFW_KEY_DOWN,
    up = Glfw.GLFW_KEY_UP,
    page_up = Glfw.GLFW_KEY_PAGE_UP,
    page_down = Glfw.GLFW_KEY_PAGE_DOWN,
    home = Glfw.GLFW_KEY_HOME,
    end = Glfw.GLFW_KEY_END,
    caps_lock = Glfw.GLFW_KEY_CAPS_LOCK,
    scroll_lock = Glfw.GLFW_KEY_SCROLL_LOCK,
    num_lock = Glfw.GLFW_KEY_NUM_LOCK,
    print_screen = Glfw.GLFW_KEY_PRINT_SCREEN,
    pause = Glfw.GLFW_KEY_PAUSE,
    // 修饰键
    left_shift = Glfw.GLFW_KEY_LEFT_SHIFT,
    left_control = Glfw.GLFW_KEY_LEFT_CONTROL,
    left_alt = Glfw.GLFW_KEY_LEFT_ALT,
    left_super = Glfw.GLFW_KEY_LEFT_SUPER,
    right_shift = Glfw.GLFW_KEY_RIGHT_SHIFT,
    right_control = Glfw.GLFW_KEY_RIGHT_CONTROL,
    right_alt = Glfw.GLFW_KEY_RIGHT_ALT,
    right_super = Glfw.GLFW_KEY_RIGHT_SUPER,
    // F 键
    f1 = Glfw.GLFW_KEY_F1,
    f2 = Glfw.GLFW_KEY_F2,
    f3 = Glfw.GLFW_KEY_F3,
    f4 = Glfw.GLFW_KEY_F4,
    f5 = Glfw.GLFW_KEY_F5,
    f6 = Glfw.GLFW_KEY_F6,
    f7 = Glfw.GLFW_KEY_F7,
    f8 = Glfw.GLFW_KEY_F8,
    f9 = Glfw.GLFW_KEY_F9,
    f10 = Glfw.GLFW_KEY_F10,
    f11 = Glfw.GLFW_KEY_F11,
    f12 = Glfw.GLFW_KEY_F12,
    // 其他键
    grave_accent = Glfw.GLFW_KEY_GRAVE_ACCENT,
    minus = Glfw.GLFW_KEY_MINUS,
    equal = Glfw.GLFW_KEY_EQUAL,
    left_bracket = Glfw.GLFW_KEY_LEFT_BRACKET,
    right_bracket = Glfw.GLFW_KEY_RIGHT_BRACKET,
    backslash = Glfw.GLFW_KEY_BACKSLASH,
    semicolon = Glfw.GLFW_KEY_SEMICOLON,
    apostrophe = Glfw.GLFW_KEY_APOSTROPHE,
    comma = Glfw.GLFW_KEY_COMMA,
    period = Glfw.GLFW_KEY_PERIOD,
    slash = Glfw.GLFW_KEY_SLASH,
    world_1 = Glfw.GLFW_KEY_WORLD_1,
    world_2 = Glfw.GLFW_KEY_WORLD_2,
};

const std = @import("std");
const Glfw = @import("imports.zig").Glfw;
const Window = @import("window.zig");
const Game = @import("game.zig");
