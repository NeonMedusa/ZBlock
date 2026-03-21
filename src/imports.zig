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

pub const std = @import("std");
pub const Gctx = @import("gctx.zig");
pub const Algebra = @import("zalgebra");
pub const Vec3 = Algebra.Vec3;
pub const Mat4 = Algebra.Mat4;
pub const Vec4 = Algebra.Vec4;
pub const Quat = Algebra.Quat;
pub const Window = @import("window.zig");
pub const Gltf = @import("zgltf").Gltf;
pub const zigimg = @import("zigimg");
pub const ECS = @import("zigecs");
pub const Game = @import("game.zig");
