// 模型名称
pub const ModelName = enum {
    Avocado,
    BarramundiFish,
    CesiumMan,
    Wolf,
    foo,
};
// 定义逻辑动画类型（游戏逻辑关心的）
pub const ActionType = enum {
    idle,
    walk,
    run,
    attack,
    die,
    _count,
};
// 每个模型拥有自己的动画映射配置
pub const ModelAnimConfig = struct {
    model_name: ModelName, // 模型名称
    animations: std.EnumMap(ActionType, AnimInfo),
    pub const AnimInfo = struct {
        anim_name: []const u8, // 实际动画文件中的名称
        clip_index: u32, // 动画剪辑索引
        duration: f32, // 动画时长
        looping: bool = true, // 是否循环
        default_speed: f32 = 1.0,
    };
};
// 在World中集中管理所有模型的动画配置
pub const AnimationManager = struct {
    allocator: std.mem.Allocator,
    model_configs: std.StringHashMap(ModelAnimConfig), // 模型名 -> 配置
    pub fn init(allocator: std.mem.Allocator) AnimationManager {
        return .{
            .allocator = allocator,
            .model_configs = std.StringHashMap(ModelAnimConfig).init(allocator),
        };
    }
    // 加载模型时同时加载动画配置
    pub fn loadModelConfig(self: *AnimationManager, model_name: []const u8, config_path: []const u8) !void {
        // 从JSON/二进制文件加载配置
        const config = try loadConfigFromFile(config_path);
        try self.model_configs.put(model_name, config);
    }
    // 获取特定模型的动画信息
    pub fn getAnimInfo(self: *AnimationManager, model_name: []const u8, logic_anim: ActionType) ?ModelAnimConfig.AnimInfo {
        if (self.model_configs.get(model_name)) |config|
            return config.animations.get(logic_anim);
        return null;
    }
};
pub fn loadConfigFromFile(config_path: []const u8) !ModelAnimConfig {
    _ = config_path;
    return undefined;
}
// 实体动画状态组件
pub const AnimationState = struct {
    // 逻辑层面的动画状态
    current_logic_anim: ActionType = .idle,
    logic_anim_time: f32 = 0, // 归一化时间 [0, 1]
    // 实际动画信息（运行时查询）
    actual_anim_name: ?[]const u8 = null,
    actual_clip_index: ?u32 = null,
    // 动画参数
    speed: f32 = 1.0,
    weight: f32 = 1.0,
    looping: bool = true,
};

const std = @import("std");
