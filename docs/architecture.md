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
│   ├── loading_screen.zig — 世界生成/加载等待界面（仅文字提示）
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
                  └─ initGame()   ← ①创建玩家 → ②loadPlayer(恢复位置)
                                    → ③以玩家位置为中心加载区块(同步等待)
                                    → ④loadAllEntities → ⑤游戏循环启动

**关键：先恢复玩家位置，再加载区块。**
否则区块会围绕硬编码的 (8,8) 加载，玩家实际位置附近无区块 → 自由落体。

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
| **Mesh** | 脏区块 → 生成 greedy mesh → 上传 vertex buffer（非索引，4B/顶点） | `pending` → `completed` |
| **A\*** | 异步寻路计算 | `astar_pending` → `astar_completed` |
| **IO** | 存档加载/保存（SQLite region 分片） | `pending_loads` / `pending_saves` → 统一 `pending_io_count` |

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

### 区块顶点压缩（ChunkVertex）

每个方块面的顶点压缩到单个 `u32`（4 字节），位置/法线/UV 均通过 shader 推导：

```
packed_pos (32 bits):
  [0-4]   bx           — chunk 局部 X (0~16)
  [5-12]  by           — 垂直 Y (0~255)
  [13-17] bz           — chunk 局部 Z (0~16)
  [18-20] face_dir     — 局部面方向（UV用）
  [21-23] world_dir    — 世界面方向（法线用）
  [24-25] corner       — quad 角索引 (0-3)
  [26-31] unused
```

- **无索引画法**：每 quad 写入 6 个顶点（24B），比索引画法（4 顶点+6 索引=40B）省 40%
- **UV 推论**：`computeChunkUV()` 根据 `face_dir` + `corner` 在 shader 中计算 UV，不占用顶点空间
- **对比原 32B `StaticVertex`**：显存占用降至 **87.5%**，全加载场景下节省约 **1.3GB**

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
| `game.zig` | `updateChunks` | 加载/卸载循环，含锁等待 |
| `block_world.zig` | `processCompletedBuilds` | 通常 <5ms |
| `block_world.zig` | `enqueueSaveTask` | 调色板序列化，通常 <1ms |
| `block_world.zig` | `unloadChunk` | 修复后无 >100ms 输出 |

### 卡顿修复历史

`unloadChunk` 曾经在加载完全部区块后移动时触发 100ms-2.5s 的大卡顿。

**根因：** 主线程 `unloadChunk` 和 mesh worker 争抢 `mesh_mutex`。`unloadChunk` 中通过 `pending.contains(origin)` 检查 chunk 是否在 mesh 构建队列中，这需要持 `mesh_mutex`。与此同时，`processCompletedLoads` 每处理一个 IO 加载结果就要调 5 次 `enqueueMeshBuild`（自身+4邻居），每次都要抢 `mesh_mutex`。当主线程遍历卸载几十个 chunk 时，不断与 worker 线程锁争抢，每次切换都延迟上百毫秒。

**修复：**
1. 移除 `unloadChunk` 中的 `pending.contains` 检查（改用 `build_lock` + `chunk_mutex` 保证安全），不再碰 `mesh_mutex`
2. `processCompletedLoads` 将每帧几十次的逐个 `enqueueMeshBuild` 改为一次 `enqueueMeshBuildBatch` 批量入队，减少锁操作次数
