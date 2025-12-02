//window.zig
handle: *Glfw.GLFWwindow,
width: u32,
height: u32,
widthF: f32,
heightF: f32,
pub fn init(title: [:0]const u8, width: u32, height: u32) !@This() {
    if (Glfw.glfwInit() == 0) return error.GLFWInitFailed;
    errdefer Glfw.glfwTerminate();

    Glfw.glfwWindowHint(Glfw.GLFW_CLIENT_API, Glfw.GLFW_NO_API);
    const window = Glfw.glfwCreateWindow(
        @intCast(width),
        @intCast(height),
        title,
        null,
        null,
    ) orelse return error.WindowCreateFailed;
    errdefer Glfw.glfwDestroyWindow(window);

    // 启用原生鼠标输入（如果支持）
    if (Glfw.glfwRawMouseMotionSupported() == Glfw.GLFW_TRUE)
        Glfw.glfwSetInputMode(window, Glfw.GLFW_RAW_MOUSE_MOTION, Glfw.GLFW_TRUE);

    return @This(){
        .handle = window,
        .width = width,
        .height = height,
        .widthF = @floatFromInt(width),
        .heightF = @floatFromInt(height),
    };
}

pub fn isKeyPressed(self: @This(), key: Key) bool {
    return Glfw.glfwGetKey(self.handle, @intFromEnum(key)) == Glfw.GLFW_PRESS;
}

pub fn isMousePressed(self: @This(), mouse_button: MouseButton) bool {
    return Glfw.glfwGetMouseButton(self.handle, @intFromEnum(mouse_button)) == Glfw.GLFW_PRESS;
}

pub fn deinit(self: @This()) void {
    Glfw.glfwDestroyWindow(self.handle);
    Glfw.glfwTerminate();
}

pub fn shouldClose(self: @This()) bool {
    return Glfw.glfwWindowShouldClose(self.handle) == 0;
}

pub fn getCursorPos(self: @This()) struct { x: f64, y: f64 } {
    var x: f64 = undefined;
    var y: f64 = undefined;
    Glfw.glfwGetCursorPos(self.handle, &x, &y);
    return .{ .x = x, .y = y };
}

pub fn setCursorPos(self: @This(), xpos: f64, ypos: f64) void {
    Glfw.glfwSetCursorPos(self.handle, xpos, ypos);
}

pub fn setWindowShouldClose(self: @This()) void {
    Glfw.glfwSetWindowShouldClose(self.handle, 1);
}

pub fn pollEvents() void {
    Glfw.glfwPollEvents();
}

pub const MouseButton = enum(i32) {
    mouse_left = Glfw.GLFW_MOUSE_BUTTON_LEFT,
    mouse_right = Glfw.GLFW_MOUSE_BUTTON_RIGHT,
};
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

const Glfw = @import("cimports.zig").Glfw;
const Gctx = @import("gctx.zig");
const Algebra = @import("zalgebra");
const Vec2_f64 = Algebra.Vec2_f64;
