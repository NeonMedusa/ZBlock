# 项目架构

## 模块总览

```
src/
├── main.zig            — 入口
├── game.zig            — 核心循环、状态机、掉落逻辑、动画集成
├── registries.zig      — 注册表聚合层（编译期解析掉落物 + 运行时哈希表）
├── block_registry.zig   — 方块注册表 & BlockId
├── item_registry.zig    — 物品注册表 & ItemId
├── entity_registry.zig  — 实体注册表 & EntityTypeId
├── save_manager.zig     — SQLite 存档引擎（palette + bit-packed）
│
├── camera3d.zig        — 3D 相机（yaw/pitch/射线）
├── input.zig           — 键盘鼠标输入
├── window.zig          — GLFW 窗口管理
│
├── ui_system.zig       — UI 系统（SDF 文字 + 矩形渲染）
├── ui/
│   ├── main_menu.zig
│   ├── pause_menu.zig
│   ├── save_menu.zig
│   └── inventory_screen.zig
│
├── icon_atlas.zig      — 方块/物品图标纹理图集
│
├── render.zig          — 帧渲染管线编排
├── render_pipeline.zig — 3D 渲染管线
├── gctx.zig            — WGPU 上下文
│
├── animation.zig       — 骨骼动画系统（CPU 更新 + storage buffer 蒙皮）
├── frustum.zig         — 视锥体裁剪
├── bitstream.zig       — 位读写工具（存档调色板编码用）
│
├── block_world.zig     — 方块世界（chunk 管理、物理、AI 寻路）
├── chunk_mesh.zig      — chunk 网格生成
├── raycast.zig         — 射线检测（方块 + 实体）
│
├── inventory.zig       — 物品栏数据结构
├── keybinds.zig        — 按键绑定（JSON 配置）
└── components.zig      — ECS 组件定义
```

## 核心架构设计

### 注册表系统

三张独立注册表 + 一个聚合层：

```
block_registry.zig   ────  registries.zig  ────  item_registry.zig
    ▲                      （编译期解析）             ▲
    │                                                │
    └─────────────────  entity_registry.zig  ────────┘
```

- 三张表不相互引用，没有循环依赖
- `registries.zig` 在编译期解析所有 `drops` 中的字符串名→整数 ID
- 运行时掉落消费端直接拿到 `ResolvedDrop.item_id: u32`，零字符串操作

### 存档引擎

详见 [save_format.md](save_format.md)

### 渲染管线

详见 [rendering.md](rendering.md)
