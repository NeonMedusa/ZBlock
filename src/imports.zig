// imports.zig — 统一导入层
// 只放外部库（libs/）和全局 Io 实例，不放项目内部模块。
// 项目模块直接 @import，避免循环依赖和编译膨胀。

pub const Glfw = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cDefine("GLFW_EXPOSE_NATIVE_WIN32", "1");
    @cInclude("glfw3.h");
    @cInclude("glfw3native.h");
});

pub const Wgpu = @cImport({
    @cInclude("wgpu.h");
});

pub const Stb = @cImport({
    @cInclude("stb_truetype.h");
});

pub const Gltf = @import("zgltf").Gltf;
pub const zigimg = @import("zigimg");
pub const ECS = @import("zigecs");

const std = @import("std");
pub const io: std.Io = std.Io.Threaded.global_single_threaded.io();
