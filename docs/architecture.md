# 项目架构

## 模块总览

```
src/
├── main.zig               — 入口（DebugAllocator）
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
├── bvh.zig                — 动态 AABB 树（BVH 宽相位碰撞检测，含测试）
├── algebra.zig            — 线性代数类型（Vec3/Mat4/Quat）
├── direction.zig          — 朝向枚举（6 方向）
├── sparse_set.zig         — 稀疏集（SparseIndexSet 用于 mesh/material 管理）
├── imports.zig            — 统一导出层（libs + 全局 Io 实例 `io`）
├── winsock.zig            — Windows 原生 socket 封装（ws2_32 extern）
```

## E/S 彻底分离（2026-06-17）

### 架构概述

服务端逻辑（物理、AI、动画）在独立线程运行，与渲染/输入完全分离。
所有玩家（主机和远程客机）的输入通过统一的 `pushInput` 队列进入服务端线程。

```
主线程:
  collectPlayerInput(player_id) → pushInput(队列)
  tick(): clientReceivePackets() (客机) / host 逻辑
  渲染: getSnapPos() → lerp(snap_prev, snap_curr, accumulator/TICK_DT)

服务端线程(独立线程, 固定 30Hz):
  1. Sleep 到下一个 tick 截止时间
  2. drain 所有输入
  3. 处理每个输入 → MoveIntent/朝向/break/place/fly
  4. updatePhysics (30Hz 固定)
  5. updateAI → updateEntities → updateChunks
  6. publishSnapshot → 快照缓冲区(mutex)

网络线程(仅 host 模式):
  accept → 创建远程玩家实体
  循环: recvInput → pushInput(player_id=1)
        读 server.snapshots → sendState
        读 server.pending_chunks → sendChunk
        读 server.pending_unloads → sendChunkUnload
```

### 玩家平等

| 操作 | 主机 | 远程客机 |
|------|------|---------|
| 输入来源 | `collectPlayerInput → pushInput` | TCP → 网络线程 → `pushInput` |
| MoveIntent/朝向/飞行 | 服务端 tick | 服务端 tick |
| break/place | 服务端 tick | 服务端 tick |
| 区块加载 | `updateChunks`（磁盘） | `updateChunks`（网络发送） |
| 渲染 | `lerp(render_prev, render_vec, time_alpha)`
  主机：遍历 `render_snapshots`（避免 ECS view 迭代器与服务端线程竞态）
  客机：ECS view 迭代（无服务端线程，安全）
  相机：主机用 render_prev/render_vec + time_alpha，客机用 prev/vec + accumulator/TICK_DT | 同主机 |

### 快照与插值

```
服务端 tick 结束 → publishSnapshot()
  → snapshots[64] (mutex 保护, 含 Entity + 位置/朝向)
  → 网络线程读 snapshots → sendState
  → 主线程:
      主机: pollServerSnapshot()
        → 复制到 render_snapshots 缓冲区
        → 推入实体 3 槽环形缓冲区（按 entity 精确匹配）
      客机: clientReceivePackets()
        → 复制到 render_snapshots 缓冲区
        → 推入实体 3 槽环形缓冲区
  → 渲染（主机/客机统一）:
      实体 & 相机: 搜索 3 槽环缓冲，render_time = now - 33ms
        → 找到 bracket → lerp(pos[older], pos[newer], alpha)
        → 缓冲区不足（count < 2）→ 返回最新原始位置
```

注意：`EntitySnapshot` 存储完整 `ECS.Entity{index, version}` 而非仅 `entity_idx`，
确保精确匹配不被回收实体干扰。

动画相关：
- `allocBoneSlot` 只在主线程调用（initGame / pollServerSnapshot / clientReceivePackets）
- 服务端线程和网络线程不分配骨骼槽，避免竞态
- `animation_system.update` 只在主线程调用（pollServerSnapshot / clientReceivePackets）

### 动态区块加载/卸载

- `updateChunks` 遍历所有玩家，主机从磁盘加载/卸载
- 远程玩家：计算所需区块范围，与已发送列表对比
  - 未发送的区块 → `enqueueChunkUpdate`（网络线程发 `sendChunk`）
  - 已远离的区块 → `enqueueChunkUnload`（网络线程发 `sendChunkUnload`）
- 主机卸载前检查是否有其他玩家仍然需要该区块

### 客机收包

- `clientReceivePackets()` 每帧非阻塞调用（`poll(0)`）
- 统一处理 tag=2（chunk）、tag=1（state）、tag=3（unload）
- 解决 `clientTick` 只能 30Hz 收包导致的插值停顿

---

## 注册表系统

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
  └─ 保存当前状态 → block_world.deinit()
  └─ 释放 Server 内部容器（input_queue/pending_chunks/player_chunks）
  └─ registry.deinit() + 重建（zig-ecs handles 有 128B 泄漏，但不清空会导致实体残留）
  └─ game_cleaned = true, save_initialized = false

deinit()
  └─ server.deinit()  ← 始终释放（不论 game_cleaned）
  └─ animation_system.deinit()
  └─ registries.deinit()
  └─ 客机: disconnectClient()（直接关窗口时自动调用）
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
| **IO** | 存档加载/保存（SQLite region 分片） | `io_queue_mutex` + `io_cond` 保护 `pending_saves` / `pending_loads` |

### Worker 空闲阻塞机制

三个 worker 在无任务时均使用**条件变量**（`std.Io.Condition`）阻塞等待，而非轮询：

- 有新任务入队时，入队方持有对应 mutex 并调用 `signal()` 唤醒 worker；worker 醒来后在 `while (队列空 and running)` 循环中重新判断，防止虚假唤醒
- 避免了 `yield()` 空转（线程立即被重新调度，占满 CPU）和 `sleep()` 轮询（醒来后可能仍无任务）的问题
- `deinit()` 停止 worker 时：先设 `running = false`，再 `signal()` 确保卡在 `wait()` 上的 worker 能退出
- 三条 worker 独立使用各自的锁 + 条件变量：`mesh_mutex`+`mesh_cond`、`astar_pending_mutex`+`astar_cond`、`io_queue_mutex`+`io_cond`

### IO Worker 细节

- 同时处理 save 和 load，通过 `pending_io_count` 原子计数器跟踪未完成任务
- 两条队列共用一把 `io_queue_mutex`：`pending_saves` 和 `pending_loads` 在同一锁保护下访问，省去跨锁双重检查
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
frame_timer (Timestamp.now) → dt → accumulator
while accumulator >= TICK_DT:
    tick_count += 1
    physics / AI / animation     ← 固定 TICK_DT 步长
    accumulator -= TICK_DT
render(alpha = accumulator / TICK_DT)  ← 插值渲染

客机：
  clientTick() 30Hz 发输入
  clientReceivePackets() 每帧收包（独立于 30Hz tick）
```

- `tick_count: u64` — 逻辑 tick 计数，1 tick = 1/30s
- `frame_timer` 使用 `std.Io.Timestamp.now(io, .awake)`，独立于 GLFW
- `accumulator` 上限 `TICK_DT × 5`（CPU 跟不上时降速不崩盘）
- 天空时间 = `tick_count × TICK_DT + accumulator`，与渲染插值一致
- 多人模式下暂停时相机继续跟随

### 实体碰撞检测与射线检测（BVH）

使用**动态 AABB 树（BVH）**加速实体间碰撞和射线检测（`src/bvh.zig`）：

- **排斥力宽相位**：每个物理 tick 开头清空并重建 BVH，遍历所有实体插入紧凑 AABB
  - 胖 AABB（margin=50%）粗筛候选对 → 紧凑 AABB 二次精筛 → 施加排斥力
  - 将 O(n²) 降至接近 O(n log n)
- **射线检测**：物理 tick 之间 BVH 保持有效，射线遍历树（O(log n)）取代线性扫描全部实体
  - BVH 节点 AABB 粗筛 → 叶子节点的紧凑 AABB 精测 → 返回最近实体
- 树结构采用增量插入 + SAH 启发式搜索兄弟节点
- BVH 叶子节点存储完整的 `ECS.Entity`（含 version），不再丢失 zig-ecs 版本号信息

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
