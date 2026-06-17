// build.zig:
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

    // GLFW需要libc
    exe.root_module.link_libc = true;

    // GLFW
    exe.root_module.addIncludePath(b.path("libs/glfw-3.4.bin.WIN64/include/GLFW/"));
    exe.root_module.addLibraryPath(b.path("libs/glfw-3.4.bin.WIN64/lib-vc2022"));
    exe.root_module.linkSystemLibrary("glfw3", .{});
    exe.root_module.linkSystemLibrary("ws2_32", .{});
    const copy_glfw_dll = b.addInstallFile(
        b.path("libs/glfw-3.4.bin.WIN64/lib-vc2022/glfw3.dll"),
        "bin/glfw3.dll",
    );
    exe.step.dependOn(&copy_glfw_dll.step);

    // WGPU
    exe.root_module.addIncludePath(b.path("libs/wgpu-windows-x86_64-gnu-release/include/webgpu"));
    exe.root_module.addLibraryPath(b.path("libs/wgpu-windows-x86_64-gnu-release/lib"));
    exe.root_module.linkSystemLibrary("wgpu_native", .{});
    const copy_wgpu_dll = b.addInstallFile(
        b.path("libs/wgpu-windows-x86_64-gnu-release/lib/wgpu_native.dll"),
        "bin/wgpu_native.dll",
    );
    exe.step.dependOn(&copy_wgpu_dll.step);

    // stb
    const stb_module = b.createModule(.{
        .root_source_file = b.path("libs/stb-master/stb.zig"),
    });
    stb_module.addIncludePath(b.path("libs/stb-master"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("libs/stb-master/stb_impl.c"),
        .flags = &[_][]const u8{},
    });
    exe.root_module.addImport("stb", stb_module);

    // zgltf
    const zgltf_dep = b.dependency("zgltf", .{
        .target = target,
        .optimize = optimize,
    });
    const zgltf_module = zgltf_dep.module("zgltf");
    exe.root_module.addImport("zgltf", zgltf_module);

    // zigimg
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    const zigimg_module = zigimg_dep.module("zigimg");
    exe.root_module.addImport("zigimg", zigimg_module);

    // ECS — prime31/zig-ecs
    const ecs_module = b.createModule(.{
        .root_source_file = b.path("libs/zig-ecs-master/src/ecs.zig"),
    });
    exe.root_module.addImport("zigecs", ecs_module);

    // fridge (SQLite ORM)
    const fridge_dep = b.dependency("fridge", .{
        .target = target,
        .optimize = optimize,
        .bundle = true,
    });
    exe.root_module.addImport("fridge", fridge_dep.module("fridge"));

    // ─── 测试 ───
    const test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bvh.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_test = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run BVH tests");
    test_step.dependOn(&run_test.step);

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
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
