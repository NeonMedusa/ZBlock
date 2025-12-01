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
    if (Glfw.glfwRawMouseMotionSupported() == Glfw.GLFW_TRUE) {
        Glfw.glfwSetInputMode(window, Glfw.GLFW_RAW_MOUSE_MOTION, Glfw.GLFW_TRUE);
    }

    return @This(){
        .handle = window,
        .width = width,
        .height = height,
        .widthF = @floatFromInt(width),
        .heightF = @floatFromInt(height),
    };
}

pub fn isKeyPressed(self: @This(), key: Input.Key) bool {
    return Glfw.glfwGetKey(self.handle, @intFromEnum(key)) == Glfw.GLFW_PRESS;
}

pub fn isMousePressed(self: @This(), mouse_button: Input.MouseButton) bool {
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

const Glfw = @import("cimports.zig").Glfw;
const Gctx = @import("gctx.zig");
const Algebra = @import("zalgebra");
const Vec2_f64 = Algebra.Vec2_f64;
const Input = @import("input.zig");
