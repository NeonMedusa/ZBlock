// 这里是 stb.zig 的内容
pub const c = @cImport({
    @cInclude("stb_truetype.h");
});

// 你可以在这里添加Zig风格的包装函数和类型定义
pub const PackedChar = c.stbtt_packedchar;
// ... 其他你需要的定义
