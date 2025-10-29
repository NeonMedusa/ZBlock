_window: *glfw.GLFWwindow,

pub fn init(window: *glfw.GLFWwindow) @This() {
    return .{ ._window = window };
}

pub fn isKeyPressed(self: @This(), key: Key) bool {
    return glfw.glfwGetKey(self._window, @intFromEnum(key)) == glfw.GLFW_PRESS;
}

pub const Key = enum(i32) {
    // 字母键
    a = glfw.GLFW_KEY_A,
    b = glfw.GLFW_KEY_B,
    c = glfw.GLFW_KEY_C,
    d = glfw.GLFW_KEY_D,
    e = glfw.GLFW_KEY_E,
    f = glfw.GLFW_KEY_F,
    g = glfw.GLFW_KEY_G,
    h = glfw.GLFW_KEY_H,
    i = glfw.GLFW_KEY_I,
    j = glfw.GLFW_KEY_J,
    k = glfw.GLFW_KEY_K,
    l = glfw.GLFW_KEY_L,
    m = glfw.GLFW_KEY_M,
    n = glfw.GLFW_KEY_N,
    o = glfw.GLFW_KEY_O,
    p = glfw.GLFW_KEY_P,
    q = glfw.GLFW_KEY_Q,
    r = glfw.GLFW_KEY_R,
    s = glfw.GLFW_KEY_S,
    t = glfw.GLFW_KEY_T,
    u = glfw.GLFW_KEY_U,
    v = glfw.GLFW_KEY_V,
    w = glfw.GLFW_KEY_W,
    x = glfw.GLFW_KEY_X,
    y = glfw.GLFW_KEY_Y,
    z = glfw.GLFW_KEY_Z,

    // 数字键
    num0 = glfw.GLFW_KEY_0,
    num1 = glfw.GLFW_KEY_1,
    num2 = glfw.GLFW_KEY_2,
    num3 = glfw.GLFW_KEY_3,
    num4 = glfw.GLFW_KEY_4,
    num5 = glfw.GLFW_KEY_5,
    num6 = glfw.GLFW_KEY_6,
    num7 = glfw.GLFW_KEY_7,
    num8 = glfw.GLFW_KEY_8,
    num9 = glfw.GLFW_KEY_9,

    // 功能键
    space = glfw.GLFW_KEY_SPACE,
    escape = glfw.GLFW_KEY_ESCAPE,
    enter = glfw.GLFW_KEY_ENTER,
    tab = glfw.GLFW_KEY_TAB,
    backspace = glfw.GLFW_KEY_BACKSPACE,
    insert = glfw.GLFW_KEY_INSERT,
    delete = glfw.GLFW_KEY_DELETE,
    right = glfw.GLFW_KEY_RIGHT,
    left = glfw.GLFW_KEY_LEFT,
    down = glfw.GLFW_KEY_DOWN,
    up = glfw.GLFW_KEY_UP,
    page_up = glfw.GLFW_KEY_PAGE_UP,
    page_down = glfw.GLFW_KEY_PAGE_DOWN,
    home = glfw.GLFW_KEY_HOME,
    end = glfw.GLFW_KEY_END,
    caps_lock = glfw.GLFW_KEY_CAPS_LOCK,
    scroll_lock = glfw.GLFW_KEY_SCROLL_LOCK,
    num_lock = glfw.GLFW_KEY_NUM_LOCK,
    print_screen = glfw.GLFW_KEY_PRINT_SCREEN,
    pause = glfw.GLFW_KEY_PAUSE,

    // 修饰键
    left_shift = glfw.GLFW_KEY_LEFT_SHIFT,
    left_control = glfw.GLFW_KEY_LEFT_CONTROL,
    left_alt = glfw.GLFW_KEY_LEFT_ALT,
    left_super = glfw.GLFW_KEY_LEFT_SUPER,
    right_shift = glfw.GLFW_KEY_RIGHT_SHIFT,
    right_control = glfw.GLFW_KEY_RIGHT_CONTROL,
    right_alt = glfw.GLFW_KEY_RIGHT_ALT,
    right_super = glfw.GLFW_KEY_RIGHT_SUPER,

    // F 键
    f1 = glfw.GLFW_KEY_F1,
    f2 = glfw.GLFW_KEY_F2,
    f3 = glfw.GLFW_KEY_F3,
    f4 = glfw.GLFW_KEY_F4,
    f5 = glfw.GLFW_KEY_F5,
    f6 = glfw.GLFW_KEY_F6,
    f7 = glfw.GLFW_KEY_F7,
    f8 = glfw.GLFW_KEY_F8,
    f9 = glfw.GLFW_KEY_F9,
    f10 = glfw.GLFW_KEY_F10,
    f11 = glfw.GLFW_KEY_F11,
    f12 = glfw.GLFW_KEY_F12,

    // 其他键
    grave_accent = glfw.GLFW_KEY_GRAVE_ACCENT,
    minus = glfw.GLFW_KEY_MINUS,
    equal = glfw.GLFW_KEY_EQUAL,
    left_bracket = glfw.GLFW_KEY_LEFT_BRACKET,
    right_bracket = glfw.GLFW_KEY_RIGHT_BRACKET,
    backslash = glfw.GLFW_KEY_BACKSLASH,
    semicolon = glfw.GLFW_KEY_SEMICOLON,
    apostrophe = glfw.GLFW_KEY_APOSTROPHE,
    comma = glfw.GLFW_KEY_COMMA,
    period = glfw.GLFW_KEY_PERIOD,
    slash = glfw.GLFW_KEY_SLASH,
    world_1 = glfw.GLFW_KEY_WORLD_1,
    world_2 = glfw.GLFW_KEY_WORLD_2,

    pub fn fromGlfwKey(glfw_key: i32) ?Key {
        return @enumFromInt(glfw_key);
    }
};
const glfw = @import("cimports.zig").glfw;
