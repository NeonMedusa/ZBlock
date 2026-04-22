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

pub const Algebra = @import("algebra.zig");
pub const Vec2 = Algebra.Vec2;
pub const Vec2u = Algebra.Vec2u;
pub const Vec3 = Algebra.Vec3;
pub const Vec3u = Algebra.Vec3u;
pub const Vec3i = Algebra.Vec3i;
pub const Vec4 = Algebra.Vec4;
pub const Quat = Algebra.Quat;
pub const Mat4 = Algebra.Mat4;

pub const Window = @import("window.zig");
pub const Gltf = @import("zgltf").Gltf;
pub const zigimg = @import("zigimg");
pub const ECS = @import("zigecs");
pub const Game = @import("game.zig");
pub const RendCTX = @import("rend_ctx.zig");
pub const RenderPipeline = @import("render_pipeline.zig");

pub const Comps = @import("components.zig").Components;
pub const Render = @import("render.zig");
pub const Camera3D = @import("camera3d.zig");
pub const UiSystem = @import("ui_system.zig");
pub const Input = @import("input.zig");
