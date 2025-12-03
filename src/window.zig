//window.zig
const Window = @This();
handle: *Glfw.GLFWwindow,
width_u: u32,
height_u: u32,
width: f32,
height: f32,
center_x: f32,
center_y: f32,
time: f32 = 0,
prev_frame_time: f32 = 0,
delta_time: f32 = 0,
input: Input,
// 或许将来我们可以通过添加引用的方式订阅事件，但现在暂时就这样吧 X_X
// ui_system: ?*UiSystem = null,
pub fn init(allocator: std.mem.Allocator, title: [:0]const u8, width: u32, height: u32) !*@This() {
    // 如果Glfw初始化失败则返回错误并释放资源
    if (Glfw.glfwInit() == 0) return error.GLFWInitFailed;
    errdefer Glfw.glfwTerminate();
    // 创建窗口（设置NO_API模式以适配WGPU）
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
    // 在堆上创建window自身
    const self = try allocator.create(@This());
    self.* = .{
        .handle = window,
        .width_u = width,
        .height_u = height,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
        .input = Input.init(self),
        .center_x = @as(f32, @floatFromInt(width)) / 2,
        .center_y = @as(f32, @floatFromInt(height)) / 2,
    };
    // 将用户数据设置为自身的引用，在回调时解引用便可传递数据
    Glfw.glfwSetWindowUserPointer(window, self);
    // 设置回调
    self.setupCallbacks();
    return self;
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    // 销毁窗口
    Glfw.glfwDestroyWindow(self.handle);
    // 释放资源
    Glfw.glfwTerminate();
    // 销毁包装
    allocator.destroy(self);
}

fn setupCallbacks(window: *@This()) void {
    _ = Glfw.glfwSetKeyCallback(window.handle, keyCallback);
    _ = Glfw.glfwSetMouseButtonCallback(window.handle, mouseButtonCallback);
    _ = Glfw.glfwSetCursorPosCallback(window.handle, cursorPosCallback);
    _ = Glfw.glfwSetScrollCallback(window.handle, scrollCallback);
    _ = Glfw.glfwSetWindowCloseCallback(window.handle, windowCloseCallback);
    _ = Glfw.glfwSetWindowSizeCallback(window.handle, windowSizeCallback);
}

// 回调函数
fn keyCallback(glfw_window: ?*Glfw.GLFWwindow, key: i32, scancode: i32, action: i32, mods: i32) callconv(.c) void {
    if (glfw_window) |glfw_win| {
        if (Glfw.glfwGetWindowUserPointer(glfw_win)) |ptr| {
            // 解引用得到window自身
            const window: *Window = @ptrCast(@alignCast(ptr));
            const input = &window.input;
            // 更新window.input的按键状态
            input.updateKeyState(key, action);
        }
    }
    _ = scancode;
    _ = mods;
}
fn mouseButtonCallback(glfw_window: ?*Glfw.GLFWwindow, button: i32, action: i32, mods: i32) callconv(.c) void {
    if (glfw_window) |glfw_win| {
        // 解引用得到window自身
        if (Glfw.glfwGetWindowUserPointer(glfw_win)) |ptr| {
            const window: *Window = @ptrCast(@alignCast(ptr));
            const input = &window.input;
            // 更新window.input的鼠标状态
            input.updateMouseButtonState(button, action);
        }
    }
    _ = mods;
}
fn cursorPosCallback(glfw_window: ?*Glfw.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
    if (glfw_window) |glfw_win| {
        // 解引用得到window自身
        if (Glfw.glfwGetWindowUserPointer(glfw_win)) |ptr| {
            const window: *Window = @ptrCast(@alignCast(ptr));
            const input = &window.input;
            // 更新window.input的鼠标状态
            input.updateMousePos(xpos, ypos);
        }
    }
}
fn scrollCallback(glfw_window: ?*Glfw.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
    if (glfw_window) |glfw_win| {
        // 解引用得到window自身
        if (Glfw.glfwGetWindowUserPointer(glfw_win)) |ptr| {
            const window: *Window = @ptrCast(@alignCast(ptr));
            const input = &window.input;
            // 更新window.input的鼠标滚轮状态
            input.updateScroll(xoffset, yoffset);
        }
    }
}
fn windowSizeCallback(glfw_window: ?*Glfw.GLFWwindow, width: i32, height: i32) callconv(.c) void {
    if (glfw_window) |glfw_win| {
        // 解引用得到window自身
        if (Glfw.glfwGetWindowUserPointer(glfw_win)) |ptr| {
            const window: *Window = @ptrCast(@alignCast(ptr));
            // 更新window的尺寸
            window.width_u = @intCast(width);
            window.height_u = @intCast(height);
            window.width = @floatFromInt(width);
            window.height = @floatFromInt(height);
            // TODO:在此处重建交换链
        }
    }
}
fn windowCloseCallback(glfw_window: ?*Glfw.GLFWwindow) callconv(.c) void {
    if (glfw_window) |glfw_win| {
        // 解引用得到window自身
        if (Glfw.glfwGetWindowUserPointer(glfw_win)) |ptr| {
            const window: *Window = @ptrCast(@alignCast(ptr));
            // 暂时不做任何事情
            _ = window;
        }
    }
}
// 常用函数
pub fn pollEvents(self: *@This()) void {
    // 先重置输入状态再更新事件
    self.input.beginFrame();
    Glfw.glfwPollEvents();
    // 更新时间
    self.time = @floatCast(Glfw.glfwGetTime());
    self.delta_time = self.time - self.prev_frame_time;
    self.prev_frame_time = self.time;
}
pub fn shouldClose(self: @This()) bool {
    return Glfw.glfwWindowShouldClose(self.handle) != 0;
}
pub fn setWindowShouldClose(self: @This()) void {
    Glfw.glfwSetWindowShouldClose(self.handle, 1);
}

const Glfw = @import("cimports.zig").Glfw;
const Gctx = @import("gctx.zig");
const Algebra = @import("zalgebra");
const Vec2_f64 = Algebra.Vec2_f64;
const Input = @import("input.zig");
const std = @import("std");
