// code_generator.zig
const std = @import("std");
const Components = @import("components.zig").Components;

// 辅助函数：写入格式化字符串
fn writeFmt(writer: anytype, comptime format: []const u8, args: anytype) !void {
    var buffer: [512]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buffer, format, args);
    try writer.writeAll(formatted);
}

// 将 PascalCase 转换为 snake_case 并添加 's' 后缀
fn toSnakeCaseWithS(allocator: std.mem.Allocator, pascal_case: []const u8) ![]const u8 {
    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);
    const writer = result.writer(allocator);
    var first_char = true;
    for (pascal_case, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            // 不是第一个字符，并且前一个字符不是大写字母（处理连续大写的情况）
            if (!first_char and (i == 0 or !std.ascii.isUpper(pascal_case[i - 1])))
                try writer.writeByte('_');
            // 将大写字母转换为小写
            try writer.writeByte(std.ascii.toLower(c));
        } else {
            try writer.writeByte(c);
        }
        first_char = false;
    }
    // 添加 's' 后缀
    try writer.writeByte('s');
    return result.toOwnedSlice(allocator);
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
        \\const ComponentStorage = @import("component_storage.zig").ComponentStorage;
        \\const Components = @import("components.zig").Components;
        \\
    );

    // 获取组件信息
    const components_info = @typeInfo(Components);
    const decls = components_info.@"struct".decls;
    const component_count = decls.len;

    // 1. 生成 EntityId
    try writer.writeAll("pub const EntityId = u32;\n\n");

    // 2. 生成 ComponentType 枚举
    try writer.writeAll("// 组件类型枚举\n");
    try writer.writeAll("pub const ComponentType = enum(u16) {\n");

    for (decls) |decl|
        try writeFmt(writer, "    {s},\n", .{decl.name});

    try writer.writeAll("};\n\n");

    // 3. 生成组件数量常量
    try writer.writeAll("// 组件数量\n");
    try writeFmt(writer, "pub const component_count = {d};\n\n", .{component_count});

    // 4. 生成 Signature 类型别名
    try writer.writeAll("// 组件签名（bitset）\n");
    try writer.writeAll("pub const Signature = std.StaticBitSet(component_count);\n\n");

    // 5. 生成类型到枚举的映射函数
    try writer.writeAll("// 从组件类型获取枚举值\n");
    try writer.writeAll("pub inline fn getComponentType(comptime T: type) ComponentType {\n");
    try writer.writeAll("    return switch (T) {\n");

    // 为每个组件生成 case
    inline for (decls) |decl|
        try writeFmt(writer, "        Components.{s} => .{s},\n", .{ decl.name, decl.name });

    try writer.writeAll("        else => @compileError(\"不支持的组件类型: \" ++ @typeName(T)),\n");
    try writer.writeAll("    };\n");
    try writer.writeAll("}\n\n");

    // 6. 生成 World 结构体
    try writer.writeAll("// 世界\n");
    try writer.writeAll("pub const World = struct {\n");
    try writer.writeAll("    allocator: std.mem.Allocator,\n");
    try writer.writeAll("    next_entity_id: EntityId = 0,\n");
    try writer.writeAll("    available_ids: std.ArrayList(EntityId), // 可用ID池\n");
    try writer.writeAll("    signatures: std.ArrayList(Signature), // 实体签名存储\n\n");

    // 生成组件存储字段
    try writer.writeAll("    // 组件存储\n");

    // 预计算所有组件的 snake_case 名称
    var snake_names = std.ArrayList([]const u8){};
    defer {
        for (snake_names.items) |name| {
            allocator.free(name);
        }
        snake_names.deinit(allocator);
    }

    for (decls) |decl| {
        const snake_name = try toSnakeCaseWithS(allocator, decl.name);
        try snake_names.append(allocator, snake_name);
        try writeFmt(writer, "    {s}: ComponentStorage(Components.{s}), // {s}\n", .{ snake_name, decl.name, std.ascii.allocLowerString(allocator, decl.name) catch unreachable });
    }

    try writer.writeAll("\n");

    // 生成初始化函数
    try writer.writeAll("    // 初始化\n");
    try writer.writeAll("    pub fn init(allocator: std.mem.Allocator) World {\n");
    try writer.writeAll("        return .{\n");
    try writer.writeAll("            .allocator = allocator,\n");
    try writer.writeAll("            .available_ids = std.ArrayList(EntityId){},\n");
    try writer.writeAll("            .signatures = std.ArrayList(Signature){},\n");

    // 初始化每个组件存储
    for (decls, 0..) |decl, i|
        try writeFmt(writer, "            .{s} = ComponentStorage(Components.{s}).init(allocator),\n", .{ snake_names.items[i], decl.name });

    try writer.writeAll("        };\n");
    try writer.writeAll("    }\n\n");

    // 生成析构函数
    try writer.writeAll("    // 析构\n");
    try writer.writeAll("    pub fn deinit(self: *World) void {\n");
    try writer.writeAll("        self.available_ids.deinit(self.allocator);\n");
    try writer.writeAll("        self.signatures.deinit(self.allocator);\n");

    // 析构每个组件存储
    for (snake_names.items) |snake_name| {
        try writeFmt(writer, "        self.{s}.deinit(self.allocator);\n", .{snake_name});
    }

    try writer.writeAll("    }\n\n");

    // 生成设置组件函数
    try writer.writeAll("    // 设置组件并更新签名\n");
    try writer.writeAll("    pub fn setComponent(self: *World, entity: EntityId, component: anytype) !void {\n");
    try writer.writeAll("        const T = @TypeOf(component);\n");
    try writer.writeAll("        const comp_type = getComponentType(T);\n");
    try writer.writeAll("        // 存储组件数据\n");
    try writer.writeAll("        switch (comp_type) {\n");

    // 为每个组件生成 case
    for (decls, 0..) |decl, i|
        try writeFmt(writer, "            .{s} => try self.{s}.set(entity, component),\n", .{ decl.name, snake_names.items[i] });

    try writer.writeAll("        }\n");
    try writer.writeAll("        // 更新实体签名（设置对应位为1）\n");
    try writer.writeAll("        var sig = self.signatures.items[entity];\n");
    try writer.writeAll("        sig.set(@intFromEnum(comp_type));\n");
    try writer.writeAll("        self.signatures.items[entity] = sig;\n");
    try writer.writeAll("    }\n\n");

    // 生成移除组件函数
    try writer.writeAll("    // 移除组件并更新签名\n");
    try writer.writeAll("    pub fn removeComponent(self: *World, entity: EntityId, comp_type: ComponentType) bool {\n");
    try writer.writeAll("        var removed = false;\n");
    try writer.writeAll("        switch (comp_type) {\n");

    // 为每个组件生成 case
    for (decls, 0..) |decl, i|
        try writeFmt(writer, "            .{s} => removed = self.{s}.remove(entity),\n", .{ decl.name, snake_names.items[i] });

    try writer.writeAll("        }\n");
    try writer.writeAll("        // 更新实体签名（清除对应位）\n");
    try writer.writeAll("        if (removed) {\n");
    try writer.writeAll("            var sig = self.signatures.items[entity];\n");
    try writer.writeAll("            sig.unset(@intFromEnum(comp_type));\n");
    try writer.writeAll("            self.signatures.items[entity] = sig;\n");
    try writer.writeAll("        }\n");
    try writer.writeAll("        return removed;\n");
    try writer.writeAll("    }\n\n");

    // 生成创建实体函数
    try writer.writeAll("    // 创建实体\n");
    try writer.writeAll("    pub fn createEntity(self: *World) !EntityId {\n");
    try writer.writeAll("        // 复用已删除的实体ID\n");
    try writer.writeAll("        if (self.available_ids.pop()) |id| return id;\n");
    try writer.writeAll("        // 如果无可复用ID，则分配新ID并初始化一个空的组件签名\n");
    try writer.writeAll("        const id = self.next_entity_id;\n");
    try writer.writeAll("        self.next_entity_id += 1;\n");
    try writer.writeAll("        try self.signatures.append(self.allocator, Signature.initEmpty());\n");
    try writer.writeAll("        return id;\n");
    try writer.writeAll("    }\n\n");

    // 生成移除实体函数
    try writer.writeAll("    // 移除实体\n");
    try writer.writeAll("    pub fn removeEntity(self: *World, entity: EntityId) !void {\n");
    try writer.writeAll("        // 将ID归还给可用ID池\n");
    try writer.writeAll("        try self.available_ids.append(self.allocator, entity);\n");
    try writer.writeAll("        // 清空组件签名\n");
    try writer.writeAll("        self.signatures.items[entity] = Signature.initEmpty();\n");
    try writer.writeAll("        // 清理所有组件\n");
    for (snake_names.items) |snake_name|
        try writeFmt(writer, "        _ = self.{s}.remove(entity);\n", .{snake_name});
    try writer.writeAll("    }\n\n");

    // 生成获取组件函数
    try writer.writeAll("    // 获取实体组件\n");
    try writer.writeAll("    pub fn getComponent(self: *World, entity_id: EntityId, T: type) ?*T {\n");
    try writer.writeAll("        var comp_storage = self.getStorage(T);\n");
    try writer.writeAll("        return comp_storage.get(entity_id);\n");
    try writer.writeAll("    }\n\n");

    // 生成获取组件容器函数
    try writer.writeAll("    // 获取组件容器\n");
    try writer.writeAll("    pub inline fn getStorage(self: *World, T: type) *ComponentStorage(T) {\n");
    try writer.writeAll("        return switch (T) {\n");
    for (decls, 0..) |decl, i|
        try writeFmt(writer, "            Components.{s} => &self.{s},\n", .{ decl.name, snake_names.items[i] });
    try writer.writeAll("            else => @compileError(\"不支持的组件类型: \" ++ @typeName(T)),\n");
    try writer.writeAll("        };\n");
    try writer.writeAll("    }\n\n");

    // 生成检测组件函数
    try writer.writeAll("    // 检测实体是否包含组件\n");
    try writer.writeAll("    pub fn hasComponent(self: *World, entity_id: EntityId, comp_type: ComponentType) bool {\n");
    try writer.writeAll("        return switch (comp_type) {\n");
    for (decls, 0..) |decl, i|
        try writeFmt(writer, "            .{s} => self.{s}.has(entity_id),\n", .{ decl.name, snake_names.items[i] });
    try writer.writeAll("        };\n");
    try writer.writeAll("    }\n");

    // World类结尾
    try writer.writeAll("};\n");

    // 写入文件
    try output_file.writeAll(buffer.items);

    std.debug.print("✅ 成功生成 generated_ecs.zig 文件，包含 {} 个组件\n", .{component_count});
}

// 暂时先使用test生成代码
test "generate" {
    try generate();
}
