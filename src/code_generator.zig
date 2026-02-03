// code_generator.zig
const std = @import("std");
const Components = @import("components.zig").Components;

// 辅助函数：写入格式化字符串
fn writeFmt(writer: anytype, comptime format: []const u8, args: anytype) !void {
    var buffer: [512]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buffer, format, args);
    try writer.writeAll(formatted);
}

// 生成 generated_ecs.zig 文件
pub fn generate() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 打开或创建生成的文件
    const output_file = try std.fs.cwd().createFile("src/generated_ecs.zig", .{});
    defer output_file.close();

    // 使用缓冲写入器
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);
    const writer = buffer.writer(allocator);

    // 写入文件头部
    try writer.writeAll(
        \\// generated_ecs.zig
        \\// 此文件由 code_generator.zig 自动生成
        \\// 请勿手动修改此文件
        \\
        \\const std = @import("std");
        \\const Components = @import("components.zig").Components;
        \\
        \\
    );

    // 获取组件信息
    const components_info = @typeInfo(Components);
    const decls = components_info.@"struct".decls;
    const component_count = decls.len;

    // 1. 生成 ComponentType 枚举
    try writer.writeAll("// 组件类型枚举\n");
    try writer.writeAll("pub const ComponentType = enum(u16) {\n");

    for (decls) |decl| {
        try writeFmt(writer, "    {s},\n", .{decl.name});
    }
    try writer.writeAll("};\n\n");

    // 2. 生成组件数量常量
    try writer.writeAll("// 组件数量\n");
    try writeFmt(writer, "pub const component_count = {d};\n\n", .{component_count});

    // 3. 生成 Signature 类型别名
    try writer.writeAll("// 组件签名（bitset）\n");
    try writer.writeAll("pub const Signature = std.StaticBitSet(component_count);\n\n");

    // 4. 生成类型到枚举的映射函数
    try writer.writeAll("// 从组件类型获取枚举值\n");
    try writer.writeAll("pub inline fn getComponentType(comptime T: type) ComponentType {\n");
    try writer.writeAll("    return switch (T) {\n");

    // 为每个组件生成 case
    inline for (decls) |decl| {
        try writeFmt(writer, "        Components.{s} => .{s},\n", .{ decl.name, decl.name });
    }

    try writer.writeAll("        else => @compileError(\"不支持的组件类型: \" ++ @typeName(T)),\n");
    try writer.writeAll("    };\n");
    try writer.writeAll("}\n\n");

    // 5. 生成从枚举值到类型名的映射函数
    try writer.writeAll("// 从枚举值获取类型名\n");
    try writer.writeAll("pub fn getComponentTypeName(comp_type: ComponentType) []const u8 {\n");
    try writer.writeAll("    return switch (comp_type) {\n");

    for (decls) |decl| {
        try writeFmt(writer, "        .{s} => \"{s}\",\n", .{ decl.name, decl.name });
    }
    try writer.writeAll("    };\n");
    try writer.writeAll("}\n\n");

    // 写入文件
    try output_file.writeAll(buffer.items);

    std.debug.print("✅ 成功生成 generated_ecs.zig 文件，包含 {} 个组件\n", .{component_count});
}

// 暂时先使用test生成代码
test "generate" {
    try generate();
}
