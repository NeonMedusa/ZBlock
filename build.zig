const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // 创建主程序
    const exe = b.addExecutable(.{
        .name = "ZigGame",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // GLFW
    exe.linkLibC(); // glfw需要libc
    exe.addIncludePath(b.path("libs/glfw-3.4.bin.WIN64/include/GLFW/"));
    exe.addLibraryPath(b.path("libs/glfw-3.4.bin.WIN64/lib-vc2022"));
    exe.linkSystemLibrary("glfw3");
    const copy_glfw_dll = b.addInstallFile(
        b.path("libs/glfw-3.4.bin.WIN64/lib-vc2022/glfw3.dll"),
        "bin/glfw3.dll",
    );
    exe.step.dependOn(&copy_glfw_dll.step);

    // WGPU
    exe.addIncludePath(b.path("libs/wgpu-windows-x86_64-msvc-release/include/webgpu"));
    exe.addLibraryPath(b.path("libs/wgpu-windows-x86_64-msvc-release/lib"));
    exe.linkSystemLibrary("wgpu_native");
    const copy_wgpu_dll = b.addInstallFile(
        b.path("libs/wgpu-windows-x86_64-msvc-release/lib/wgpu_native.dll"),
        "bin/wgpu_native.dll",
    );
    exe.step.dependOn(&copy_wgpu_dll.step);

    // zalgebra
    const zalgebra = b.dependency("zalgebra", .{
        .target = target,
        .optimize = optimize,
    });
    const zalgebra_module = zalgebra.module("zalgebra");
    exe.root_module.addImport("zalgebra", zalgebra_module);

    // zgltf
    const zgltf_dep = b.dependency("zgltf", .{
        .target = target,
        .optimize = optimize,
    });
    const zgltf_module = zgltf_dep.module("zgltf");
    exe.root_module.addImport("zgltf", zgltf_module);

    // 复制资源文件
    b.installDirectory(.{
        .source_dir = b.path("resources"),
        .install_dir = .{ .custom = "bin/resources" },
        .install_subdir = "",
    });

    // 安装并运行
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args|
        run_cmd.addArgs(args);
    const run_step = b.step("run", "运行程序");
    run_step.dependOn(&run_cmd.step);
}
