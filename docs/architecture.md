# 项目架构

## 模块总览

```
src/
├── main.zig               — 入口（GPA.thread_safe = true）
├── game.zig               — 核心循环、固定 tick 物理（30tick/s）、状态机、延迟初始化
├── registries.zig         — 注册表聚合层（编译期解析掉落物 + 运行时哈希表）
├── block_registry.zig     — 方块注册表 & BlockId（u16）
├── item_registry.zig      — 物品注册表 & ItemId
├── entity_registry.zig    — 实体注册表 & EntityTypeId
├── save_manager.zig       — SQLite 存档引擎（仅世界元数据：玩家/背包/实体）
│
├── camera3d.zig           — 3D 相机（yaw/pitch/射线）
├── input.zig              — 键盘鼠标输入
├── window.zig             — GLFW 窗口管理
├── keybinds.zig           — 按键绑定（JSON 配置）
│
├── ui_system.zig          — UI 系统（SDF 文字 + 矩形渲染）
├── ui/
│   ├── main_menu.zig
│   ├── pause_menu.zig
│   ├── save_menu.zig
│   └── inventory_screen.zig
│
├── icon_atlas.zig         — 方块/物品图标纹理图集
│
├── render.zig             — 帧渲染管线编排
├── render_pipeline.zig    — 3D 渲染管线
├── shadow.zig             — ShadowPipeline（阴影贴图方向光）
├── wireframe_pipeline.zig — 线框渲染管线
├── rend_ctx.zig           — SceneUniform / GPU 统一缓冲区定义
├── sky.zig                — 程序化天空盒（全屏三角、昼夜循环、星空）
├── gctx.zig               — WGPU 上下文
│
├── animation.zig          — 骨骼动画系统（CPU 更新 + storage buffer 蒙皮）
├── frustum.zig            — 视锥体裁剪
├── bitstream.zig          — 位读写工具（调色板索引编码用）
│
├── block_world.zig        — 方块世界（chunk 管理 + 3 异步 worker 线程）
├── chunk_mesh.zig         — chunk 网格生成（greedy mesh）
├── noise.zig              — 地形噪声生成
├── raycast.zig            — 射线检测（方块 + 实体）
├── pathfind.zig           — A* 寻路
│
├── inventory.zig          — 物品栏数据结构
├── components.zig         — ECS 组件定义
├── systems.zig            — ECS 系统注册
├── systems/
│   └── health_system.zig  — 实体伤害/回复系统
│
├── aabb.zig               — 轴对齐包围盒
├── algebra.zig            — 线性代数类型（Vec3/Mat4/Quat）
├── direction.zig          — 朝向枚举（6 方向）
├── sparse_set.zig         — 稀疏集（ECS 底层存储）
├── imports.zig            — 统一 re-export（Vec3, ECS 等）
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
- `BlockId` 为 `u16`（原 `u32`），配合每 chunk 调色板可覆盖 65536 种方块类型

### 存档引擎

详见 [save_format.md](save_format.md)

### 渲染管线

详见 [rendering_3d.md](rendering_3d.md)、[rendering_sky.md](rendering_sky.md) 和 [rendering_ui.md](rendering_ui.md)

---

## 游戏生命周期（延迟初始化）

游戏启动时**不创建存档**，直接进入主菜单。选存档后初始化 gameplay 子系统：

```
main()
  └─ Game.init()          ← 只初始化窗口/UI/渲染/输入
      └─ Game.start()     ← 主循环，显示主菜单
          └─ 用户选存档
              └─ startSave(name)  ← 初始化存档 + BlockWorld + worker 线程
                  └─ initGame()   ← 加载玩家/实体/区块

returnToMenu()
  └─ 保存当前状态 → registry.deinit() → block_world.deinit()
  └─ game_cleaned = true, save_initialized = false

deinit()
  └─ if !game_cleaned: registry.deinit()  ← 防止双重释放
  └─ registries.deinit()
```

- `save_initialized: bool` — 主循环中判断是否运行物理/渲染
- `game_cleaned: bool` — `returnToMenu` 后标记，防止 `deinit` 重复释放 `registry`
- 解决了"启动→进主菜单→直接退出"的数据丢失问题

---

## 区块系统与异步 Worker

`BlockWorld` 管理所有 chunk，使用**3 条独立 worker 线程**处理异步任务：

| Worker | 职责 | 通信方式 |
|--------|------|---------|
| **Mesh** | 脏区块 → 生成 greedy mesh → 上传 vertex/index buffer | `pending_builds` → `completed_builds` |
| **A\*** | 异步寻路计算 | `pending_pathfind` → `completed_paths` |
| **IO** | 存档加载/保存（SQLite region 分片） | `pending_loads` + `pending_saves` → 统一 `pending_io_count` |

### IO Worker 细节

- 同时处理 save 和 load，通过 `pending_io_count` 原子计数器跟踪未完成任务
- 按 region（32×32 chunks）缓存 SQLite 连接（`region_caches` HashMap）
- `saveAllChunks` + `flushIO()` 模式确保退出前所有脏数据落盘
- 保存不执行 WAL checkpoint（已验证非必要开销）

### Per-Chunk 调色板编码

每个 chunk 独立维护调色板（`palette: ArrayList(BlockState)`）+ 变长位索引：

```
palette: ["air", "stone_0", "grass_0", "dirt_0", ...]
index_bits: ceil(log2(palette_size))  // 1-5 bits
index_data: bit-packed u8[]           // 每个方块 palette_index
```

- `BlockState` 包含 `block_id: BlockId(u16)` + `facing: Direction`
- 朝向信息编码在调色板条目名称中（`"stone_5"`），存档自描述、版本无关
- 相比固定 `u32` 方案，内存占用减少约 **237MB**（65k 区块场景）

---

## 固定 tick 游戏循环

物理、AI、动画以固定速率运行（30 tick/s），与渲染帧率无关。

```
frame_timer (std.time.Instant) → dt → accumulator
while accumulator >= TICK_DT:
    tick_count += 1
    physics / AI / animation     ← 固定 TICK_DT 步长
    accumulator -= TICK_DT
render(alpha = accumulator / TICK_DT)  ← 插值渲染
```

- `tick_count: u64` — 逻辑 tick 计数，1 tick = 1/30s
- `frame_timer` 使用 `std.time.Instant`，独立于 GLFW
- `accumulator` 上限 `TICK_DT × 5`（CPU 跟不上时降速不崩盘）
- 天空时间 = `tick_count × TICK_DT + accumulator`，与渲染插值一致
- Pause 模式下 `tick_count` 不递增，时间冻结
- Inventory 模式下时间继续，`syncCameraFromPlayer` 同步视角

---

## 性能分析计时器

关键路径加入耗时 >100ms 的 `[TIMER]` 日志，用于定位卡顿瓶颈：

| 位置 | 计时点 | 典型耗时 |
|------|--------|---------|
| `game.zig` | `updateChunks` | 通常 <16ms |
| `block_world.zig` | `processCompletedBuilds` | 通常 <5ms |
| `block_world.zig` | `enqueueSaveTask` | 调色板序列化，通常 <1ms |
| `block_world.zig` | `unloadChunk` | **100ms-2.5s**（GPU wgpuBufferRelease 同步） |

`unloadChunk` 的高耗时是 wgpu-native 驱动架构限制：`wgpuBufferRelease` 会强制 drain GPU 队列，无法在应用层消除。调试时保留计时器可区分 GPU 同步与 CPU 逻辑的卡顿来源。
