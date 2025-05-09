handle: *glfw.GLFWwindow,
width: u32,
height: u32,
widthF: f32,
heightF: f32,
input: Input,
pub fn init(title: [:0]const u8, width: u32, height: u32) !@This() {
    if (glfw.glfwInit() == 0) return error.GLFWInitFailed;
    errdefer glfw.glfwTerminate();

    glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
    const window = glfw.glfwCreateWindow(
        @intCast(width),
        @intCast(height),
        title,
        null,
        null,
    ) orelse return error.WindowCreateFailed;
    errdefer glfw.glfwDestroyWindow(window);

    // 启用原生鼠标输入（如果支持）
    if (glfw.glfwRawMouseMotionSupported() == glfw.GLFW_TRUE) {
        glfw.glfwSetInputMode(window, glfw.GLFW_RAW_MOUSE_MOTION, glfw.GLFW_TRUE);
    }

    return @This(){
        .handle = window,
        .width = width,
        .height = height,
        .widthF = @floatFromInt(width),
        .heightF = @floatFromInt(height),
        .input = Input.init(window),
    };
}

pub fn deinit(self: @This()) void {
    glfw.glfwDestroyWindow(self.handle);
    glfw.glfwTerminate();
}

pub fn shouldClose(self: @This()) bool {
    return glfw.glfwWindowShouldClose(self.handle) == 0;
}

pub fn getCursorPos(self: @This()) struct { x: f64, y: f64 } {
    var x: f64 = undefined;
    var y: f64 = undefined;
    glfw.glfwGetCursorPos(self.handle, &x, &y);
    return .{ .x = x, .y = y };
}

pub fn setCursorPos(self: @This(), xpos: f64, ypos: f64) void {
    glfw.glfwSetCursorPos(self.handle, xpos, ypos);
}

pub fn setWindowShouldClose(self: @This()) void {
    glfw.glfwSetWindowShouldClose(self.handle, 1);
}

pub fn pollEvents() void {
    glfw.glfwPollEvents();
}

const glfw = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cDefine("GLFW_EXPOSE_NATIVE_WIN32", "1");
    @cInclude("glfw3.h");
    @cInclude("glfw3native.h");
});
const Gctx = @import("gctx.zig");
const algebra = @import("zalgebra");
const Vec2_f64 = algebra.Vec2_f64;
const Input = @import("input.zig");
