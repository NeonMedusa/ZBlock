//main.zig:

pub fn main() !void {
    // 创建内存分配器
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试STB
    // 1. 将整个TTF文件读入内存
    const font_path = "resources/fonts/FiraCode-Light.ttf"; // 示例，确保此文件存在
    const font_data = try std.fs.cwd().readFileAllocOptions(
        allocator,
        font_path,
        std.math.maxInt(usize),
        null,
        .@"8",
        null,
    );
    defer allocator.free(font_data);
    std.debug.print("Successfully loaded font file,size:{} byte\n", .{font_data.len});

    // 4. 初始化字体信息结构体
    var font_info: Stb.stbtt_fontinfo = undefined;
    const init_result = Stb.stbtt_InitFont(&font_info, font_data.ptr, 0);
    if (init_result == 0) {
        std.debug.print("Error: Unable to initialize font\n", .{});
        return error.FontInitFailed;
    }
    std.debug.print("Successfully initialized font\n", .{});

    // 5. 测试获取字符 'A' (ASCII 65) 的度量信息
    const codepoint: c_int = 65; // 'A'
    var advanceWidth: c_int = undefined;
    var leftSideBearing: c_int = undefined;
    Stb.stbtt_GetCodepointHMetrics(&font_info, codepoint, &advanceWidth, &leftSideBearing);

    var x0: c_int = undefined;
    var y0: c_int = undefined;
    var x1: c_int = undefined;
    var y1: c_int = undefined;
    Stb.stbtt_GetCodepointBitmapBox(&font_info, codepoint, 1.0, 1.0, &x0, &y0, &x1, &y1);

    // 6. 打印结果
    std.debug.print("metric information for character 'A':\n", .{});
    std.debug.print("  advanceWidth:{}\n", .{advanceWidth});
    std.debug.print("  leftSideBearing: {}\n", .{leftSideBearing});
    std.debug.print("  bitmap bounding box (in pixels): x0={}, y0={}, x1={}, y1={}\n", .{ x0, y0, x1, y1 });
    std.debug.print("  Calculated width: {}, height:{}\n", .{ x1 - x0, y1 - y0 });

    // 7. (可选) 尝试光栅化一个字符到位图，这是文字渲染的真正第一步
    const bitmap_width: c_int = @intCast(x1 - x0);
    const bitmap_height: c_int = @intCast(y1 - y0);

    if (bitmap_width <= 0 and bitmap_height <= 0) return;

    const bitmap = try allocator.alloc(u8, @as(usize, @intCast(bitmap_width * bitmap_height)));
    defer allocator.free(bitmap);

    // 调用光栅化函数
    Stb.stbtt_MakeCodepointBitmap(
        &font_info,
        bitmap.ptr,
        bitmap_width,
        bitmap_height,
        bitmap_width, // stride (每行字节数)
        1.0, // scale_x
        1.0, // scale_y
        codepoint,
    );
    std.debug.print("Successfully generated bitmap for character 'A', size: {}x{}\n", .{ bitmap_width, bitmap_height });

    // 1. 创建并配置一个 Image 对象
    const width = @as(usize, @intCast(bitmap_width));
    const height = @as(usize, @intCast(bitmap_height));
    const total_pixels = width * height;
    var img = try zigimg.Image.create(allocator, width, height, .rgba32);
    defer img.deinit(allocator);
    // 2. 获取像素数组
    const pixels = img.pixels.rgba32;
    // 3. 使用单一循环，更高效
    for (0..total_pixels) |i| {
        const gray_value = bitmap[i];
        pixels[i] = .{
            .r = gray_value,
            .g = gray_value,
            .b = gray_value,
            .a = 255,
        };
    }
    // 4. 写入文件
    const file = try std.fs.cwd().createFile("zig-out/output.png", .{});
    defer file.close();
    var write_buffer: [4096]u8 = undefined;
    try img.writeToFile(allocator, file, &write_buffer, .{ .png = .{} });
    std.debug.print("\nThe stb_truetype test was successful! The library has been properly integrated and is working.\n", .{});

    // 初始化游戏
    var game = try Game.init(allocator);
    defer game.deinit();
    try game.start();
}

const std = @import("std");
const Game = @import("game.zig");
const zigimg = @import("zigimg");
const Stb = @import("stb").c;
