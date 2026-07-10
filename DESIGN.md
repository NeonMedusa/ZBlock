# DESIGN.md

## 当前架构（2026-06-18）

### 环境

| 组件 | 版本 |
|------|------|
| Zig | 0.16.0 |
| ECS | prime31/zig-ecs (master, 2026-05-18) |
| SQLite | fridge (zig16 branch, 2026-05-07) |
| GLFW | 3.4 |
| WGPU | wgpu-native (x86_64-windows) |
| zgltf | 最新 master |
| zigimg | 最新 master (zig16 适配) |

### 与 0.15.2 的关键迁移差异

| 旧 API | 新 API | 说明 |
|--------|--------|------|
| `std.Thread.Mutex` | `std.Io.Mutex` | 需要传 `io` 参数 |
| `std.Thread.Condition` | `std.Io.Condition` | `timedWait` 被移除，改用 sleep 轮询 |
| `std.Thread.RwLock` | `std.Io.RwLock` | 需要传 `io` 参数 |
| `std.time.Timer` / `nanoTimestamp` | `std.Io.Timestamp.now(io, .awake)` | |
| `std.fs.cwd()` | `std.Io.Dir.cwd(io)` | |
| `ArrayListUnmanaged = .{},` | `= .empty` | |
| `GeneralPurposeAllocator` | `DebugAllocator(.{})` | |
| `std.crypto.random` | `Io.random(buf)` 或 PRNG | |
| `std.posix.socket/bind/...` | 手写 `winsock.zig` (Windows) | 0.16 移除了中等抽象层 |

### 进程架构

所有模式（单人/主机/客机）共享同一份可执行文件。三种运行模式由 `game.network.mode` 区分：

| 模式 | `network.mode` | 服务端线程 | 网络线程 | 渲染 |
|------|---------------|-----------|---------|------|
| 单人 | `.single` | 运行（物理/AI/动画） | 无 | 同步相机 |
| 主机 | `.host` | 运行 | 接受 TCP + 收发 | 同步相机 |
| 客机 | `.client` | 运行（仅 tick） | 无（TCP 在主线程收） | state 包驱动 |

### 线程模型

```
主线程:
  collectPlayerInput(player_id) → pushInput(队列)
  tick(): clientReceivePackets() / host 逻辑
  渲染: getSnapPos() → lerp(prev, curr, accumulator/TICK_DT)

服务端线程(独立线程, 固定 30Hz):
  1. Sleep 到下一个 tick 截止时间（分块 1~5ms，可响应停止信号）
  2. drain 所有输入
  3. 处理每个输入 → MoveIntent/朝向/break/place/fly
  4. updatePhysics (30Hz 固定, 与输入数量无关)
  5. updateAI (最近玩家追踪)
  6. animation_system.update
  7. updateEntities (生命值/消失)
  8. updateChunks (所有玩家的区块加载/卸载)
  9. publishSnapshot → 快照缓冲区(mutex保护)
  10. 推进 next_tick 截止时间，落后时不补帧

网络线程(独立线程, 仅 host 模式):
  accept → 创建远程玩家实体
  循环: recvInput → pushInput(player_id=1)
        读 server.snapshots → sendState
        读 server.pending_chunks → sendChunk
        读 server.pending_unloads → sendChunkUnload
```

### 玩家移动分工

- **客机玩家**：`produceMoveIntent` → 本地 `updatePhysics` → 每 tick 提交位置给服务器
- **主机玩家**：`produceMoveIntent` → 服务端 `updatePhysics`，不经过网络
- **服务端**：远程客机直接应用提交的位置（不跑物理），AI 实体继续跑物理和寻路
- **动作**（break/place/fly/camera）：主机和客机都提交目标坐标，服务端执行并广播 block_update
- **输入队列**：仅用于主机玩家的动作，移动字段已移除

### 快照与插值

```
服务端 tick 结束 → publishSnapshot()
  → snapshots[64] (mutex 保护, 含完整 ECS.Entity{index,version} + 位置/朝向)
  → hostNetworkThread 读 snapshots 组包
  → sendState(tick_count, host_time, entities)

主线程:
  主机: pollServerSnapshot()
    → 复制到 render_snapshots 缓冲区
    → 推入实体 3 槽环形缓冲区
  客机: clientReceivePackets()（每帧非阻塞）
    → 复制到 render_snapshots 缓冲区
    → 推入实体 3 槽环形缓冲区

  渲染（主机/客机统一）:
    搜索 3 槽环缓冲，render_time = now - 33ms
    → 找到 bracket → lerp(pos[older], pos[newer], alpha)
    → 缓冲区不足（count < 2）→ 返回最新原始位置
```

注：3 槽环缓冲无需持久化时间参考，alpha 永不为零，无速度断续感。
`EntitySnapshot.entity` 存储完整 {index, version}，不被回收实体干扰。

### 实体攻击与掉落

**流程（信任客机）：**

1. 客机本地 raycast 检测实体（遍历 Position+Collider，不依赖 BVH）
2. 命中非自身实体 → 设置 attack_entity + attack_target_raw 发给服务端
3. 服务端 `handleActionAttack`：直接扣血，死亡时计算掉落
4. 掉落写入 `pending_drops[]` → 网络线程过滤写入 `ServerState.drops`
5. 客机收到后匹配 `target_player_id` → `tryItemToInventory`

**主机模式**：伤害/掉落全在 `predictBlockAction` 本地完成，不经过网络。

**防双拿**：掉落由服务端计算，`target_player_id` 唯一指定归属，客机不做本地掉落预测。

### 客机收包

- `clientTick()` 30Hz 发位置/速度（物理在本地跑）
- `clientReceivePackets()` 每帧非阻塞收包
- 统一处理 tag=2（chunk）、tag=1（state）、tag=3（unload）
- state 内含 entities + block_updates + drops
- 所有实体通过 3 槽环缓冲做插值渲染

---

设计文档：方块物理精细化相关议题。

---

## 议题一：不完整方块与朝向感知的 AABB 碰撞

### 目标

支持栅栏、半砖、楼梯等非 1×1×1 方块，且正确处理方块朝向。

### 现状

- 所有方块在碰撞系统中均为边长为 1 的完整立方体
- `BlockProtoType` 只有 `is_solid` 布尔值，没有形状数据
- `BlockState` 已有 `facing: Direction` 字段，mesh 构建已实现朝向旋转
- 碰撞系统（`getCollidingBlocks`、`moveEntity`）假设方块填满整格
- `hasGroundUnder` 通过扫描 `floor(pos.y) - 1` 层的 `is_solid` 判断接地

### 设计

#### 新增 AABB 字段

`BlockProtoType` 新增 `collision_boxes: []const AABB`（comptime 切片），默认值 `[{0,1, 0,1, 0,1}]`（完整方块）。

**为什么是切片（多个 AABB）**：
部分方块无法用单个轴对齐盒描述其碰撞形状：
- 栅栏：中心柱 + 横向连接杆 = 3~5 个 AABB
- L 形楼梯：至少 2 个 AABB（踏步 + 踢面）
- 炼药锅、花盆等：空心盒体可能需要 4 面薄壁 AABB

每个 AABB 在局部坐标系中定义（默认 `facing = up`）。

#### 运行时获取方块世界 AABB

```
getBlockWorldAABB(x, y, z, block_state) -> []AABB
```

逻辑：
1. 取 `BlockState.facing`
2. 对 `collision_boxes` 中的每个局部 AABB，取其 8 个顶点
3. 用 `facing.rotation().rotate(vertex)` 旋转每个顶点
4. 取旋转后 8 顶点的 min/max → 世界坐标系下的 AABB
5. 将 AABB 平移到方块中心 `(x+0.5, y+0.5, z+0.5)`

因所有 6 个朝向均为 90° 旋转，结果必为轴对齐 AABB，无需 OBB。

#### 重构 hasGroundUnder 为射线检测

从实体 AABB 底面四个角向下发射射线段（长度 0.5），射线穿过方块列时，对该列方块的每个世界 AABB 做线段-AABB 相交测试。任意射线命中 → 有地面支撑。

射线段长度 0.5 可支持潜行状态上下半格台阶。

#### 重构 moveEntity 碰撞系统

`getCollidingBlocks` 改用 `getBlockWorldAABB()` 获取精确方块 AABB，代替当前的整格假设。

### 分步路线

1. `BlockProtoType` 加 `collision_boxes` 字段（默认值向后兼容）
2. 工具函数 `getBlockWorldAABB(x, y, z, block_state) -> []const AABB`
3. 重构 `getCollidingBlocks` 使用步骤 2
4. 重构 `hasGroundUnder` 为射线-AABB 检测
5. 添加半砖、栅栏等测试方块验证

---

## 议题二：1/8 比例方块（等效"迷你方块"）

### 目标

用现有 1 米方块系统实现更高细节度的建筑，无需真正缩小方块。

### 核心思路

不改变方块大小。将实体 AABB 的长宽翻倍（如 `1.2×1.8` → `2.4×3.6`），视觉上等效于方块变为了边长为 0.5 米的迷你方块。

### 收益

- 半砖：用一个迷你方块层（0.5m 高）直接实现，无需不完整方块概念
- 楼梯：用逐级堆叠的迷你方块构建
- 与议题一互补：复杂形状仍可用不完整方块 AABB 定义

### 代价

- 寻路系统需适配翻倍后的实体尺寸（通道宽度、门洞高度等）
- 玩家碰撞箱变大，需要调整视觉规范或提供 crouch 缩小碰撞箱
- 现有世界中的所有建筑比例感会改变

### 与议题一的关系

两者独立但互补。议题一解决"一个方块内可定义任意形状"，本议题解决"用更小方块构建更精细的结构"。

---

## 议题三：斜坡方块

### 目标

支持倾斜面，实现平滑的上下坡移动，而非逐级跳跃。

### 可能的实现方向

**方向 A：特殊 AABB 定义 + 物理系统适配**

方块定义中包含斜面法向量，碰撞系统沿斜面滑动而非垂直反弹。需要将 AABB 碰撞改为支持斜面 clip。

**方向 B：视觉斜坡 + 逻辑台阶**

方块渲染为斜坡，但碰撞体仍为阶梯状迷你方块。实现简单但上下坡手感差。

### 与议题一、二的关系

如果议题二的 1/8 方块实现，斜坡可自然地用层叠迷你方块构建，此时本议题变为纯渲染优化（让阶梯看起来是平滑斜面）。

---

## 议题四：Boss 战地形快照与回退

### 目标

实现 Boss 战中怪物破坏地形的震撼视觉效果，战斗结束后地形自动恢复。

### 设计

1. **Boss 战开始前**：对当前存档做一份快照（仅备份受影响的区块）
2. **战斗中**：怪物可以破坏地形（方块被破坏时无掉落物）
3. **战斗结束后**：将快照覆盖回来，地形回退到战斗前状态

### 实现思路

快照不需要复制整个地图。可以：

---

## 待办：多客机支持

内容已合并到上方网络协议演进方向阶段二中，此处不再重复。

---

## 议题五：世界垂直高度扩展

### 目标

支持超过当前 255 格的垂直高度，为深地底和高空建筑预留空间。

### 当前设计（已落实）

- `CHUNK_HEIGHT = 255`（方块层 0~254，共 255 层）
- `ChunkVertex.by: u8`（0~255），顶点 Y 范围 (0~255) 恰好用满
- `chunks` 的 key 是 `Vec3i`（含 y 分量），架构上支持垂直分片

### 两种扩展方案（将来选择）

#### 方案 A：增高区块（调大 CHUNK_HEIGHT）

增大 `CHUNK_HEIGHT`（如 384 或 512），所有 chunk 变高：每 chunk 数据量等比例增加、索引位宽度不变。同时需要增加 `ChunkVertex.by` 的位数（当前 `u8` 最大 255 → 提高到 `u9` / `u10` 等，`_pad` 有 9 位可借用）。

**优点**：区块数量不变、Y 方向跨区块移动无断点
**缺点**：内存/显存等比例增长、噪声生成范围增大

#### 方案 B：垂直分层区块（用 Vec3i.y 分片）

保持 `CHUNK_HEIGHT = 255`，Y 方向超出部分用新的 chunk 层叠。`chunks` 的 key 已用 `Vec3i`，origin 的 y 分量指示该 chunk 在垂直方向的位置（如 `y=0` 为底层，`y=256` 为上层）。

**优点**：现有数据结构和渲染管线基本不变、可按需只加载玩家所在层的区块
**缺点**：跨层移动有衔接问题、噪声生成需处理层间连续性

---

## 议题四：联机物理状态同步策略

### 背景

当前实现中，主机通过 TCP 每 tick（30Hz）发送所有实体的 `(position, yaw, pitch)`，客机收到后创建/更新本地 ECS 实体，且**骨骼动画在客机本地计算**（主机不传骨骼矩阵）。

### 现状

- ✅ 客机相机跟随主机第一人称视角
- ✅ 实体位置/朝向同步（主机→客机）
- ✅ 实体模型渲染（CesiumMan/zombie）
- ✅ 骨骼动画在客机本地用 `animation_system.update()` 计算
- ❌ 没有物理交互同步（推力、击飞、攀爬等）
- ❌ 没有动画状态同步（clip 切换、播放速度）

### 设计目标

- **带宽优先**：让 LAN 联机也能流畅运行，未来扩展到公网
- **主机权威**（Server Authoritative）：主机是物理和游戏的最终裁决者，客机不做预测
- **客机本地动画**：骨骼姿势由 clip + 时间决定，不需要同步矩阵

### 同步分层

#### 第一层：刚性变换（已实现）

| 字段 | 类型 | 频率 | 说明 |
|------|------|------|------|
| `entity_type_id` | u32 (4B) | 30 Hz | 实体类型索引（客机据此选模型/collider） |
| `clip_name_id` | u8 (1B) | 30 Hz | 动画剪辑索引（0=idle 1=walk 2=run ...） |
| `position` | Vec3 (12B) | 30 Hz | 实体位置 |
| `yaw` | f32 (4B) | 30 Hz | 水平朝向 |
| `pitch` | f32 (4B) | 30 Hz | 垂直朝向 |

每实体 ≈ 29 字节，50 实体 = 1.4KB/tick = **43KB/s**。

#### 第二层：运动状态（按需添加）

| 字段 | 类型 | 频率 | 说明 |
|------|------|------|------|
| `velocity` | Vec3 (12B) | 30 Hz | 用于客机本地插值预测 |
| `on_ground` | bool (1B) | 30 Hz | 接地状态，影响动画切换 |
| `health` | f32 (4B) | 事件触发 | 受伤/治疗时发送 |

#### 第三层：动画状态（将来）

| 字段 | 类型 | 频率 | 说明 |
|------|------|------|------|
| `clip_name_id` | u8 (1B) | 30 Hz | ✅ 已实现，每 tick 嵌入 `EntitySnapshot` |
| `time` | f32 (4B) | 定期校对 | 动画时间戳，避免漂移 |
| `speed` | f32 (4B) | 切换时 | 播放倍率 |

### 物理约束同步策略

参考 Source Engine 的做法，按实体重要性分层：

#### 玩家 / 重要实体（主机权威，状态同步）

- **主机**：运行完整物理模拟（重力、碰撞、推力），每 tick 发送 position + velocity
- **客机**：收到后直接设置 position，velocity 可用于插值（可选）
- 不做客户端预测（避免实现复杂度），100ms 以内的延迟对 LAN 玩家可接受

#### 小型物理物体（客机本地模拟）

- 石头、瓶子、碎片等不影响玩法的物体
- **不通过网络同步**，客机各自独立模拟
- `EntityTypeInfo` 中加 `physics_mode` 字段：`.server` / `.client`
- 条件：体积小于阈值（如 0.5³）、质量小于阈值（如 10kg）

#### 物理动画事件（叠加动画）

- 受击、爆炸、攀爬等触发式效果
- 主机发送事件包（`event_type, direction, force`）
- 客机收到后在当前动画上叠加物理效果（如受击后仰、爆炸飞出去）
- 用 `AnimationState.blend_weight` 控制叠加权重

### 网络协议演进方向

#### 阶段一（当前）—— TCP 全量同步
- 每 tick 发送所有实体的完整 `EntitySnapshot`（位置/朝向）
- 区块加载全量 chunk（`sendChunk`）
- 方块变更嵌入 state 包（`block_updates[]`）
- 单 socket，单客户端

#### 阶段二——增量同步 + 多客户端
- 实体位置只发变化的（entity_id + delta），而非全快照
- 多客户端：`select()` 轮询多个 `client_fd`
  - `hostNetworkThread` 替换单 `client_fd`/`remote_player` 为 `clients: ArrayList(ClientInfo)`
    ```zig
    pub const ClientInfo = struct {
        fd: socket_t,
        entity: ECS.Entity,
        player_id: u32,
        disconnect: bool,
    };
    ```
  - 断线标记 per-client（非单个 `client_disconnected`）
- 每客户端独立的 `pending_chunks` 队列（各自位置不同）
- 玩家 ID 从 0（主机）递增分配，上限 8 人
- 不改 UDP（仍用 TCP），玩家数量上限暂定 8 人

#### 阶段三——UDP 迁移
- Laminar / enet 可靠 UDP，分离可靠/不可靠通道
- 状态同步走不可靠通道（丢包等下帧覆盖）
- 方块操作、权限验证走可靠通道
- 序列号 + ACK + 重传

#### 阶段四——客户端预测 + 服务端仲裁（终极形态）

**架构分层：**

逻辑层（保证规则正确）：
```
权威服务器
  ↓
输入保持（防丢包导致走走停停）
  ↓
客户端预测（本地立即模拟，零延迟手感）
  ↓
服务端分级校正 + 输入重放
  ↓
快照广播
  ↓
延迟补偿（Server Rewind，命中判定公平）
  ↓
可靠事件（重要消息不丢）
  ↓
兴趣管理（按距离过滤实体，省带宽）
```

表现层（保证视觉稳定）：
```
小数Tick连续采样
  ↓
动态插值缓冲（根据网络状况调整）
  ↓
速度衰减外推（缺包时不停顿）
  ↓
平滑追随目标（校正时不突兀）
```

**客户端流程：**
1. 输入 → 本地立即预测（零延迟）
2. 同时将输入发给服务器
3. 服务器权威运算 → 返回状态快照
4. 客户端收到后：对比预测 → 分级校正 → 重放未确认输入
5. 远端玩家通过快照插值渲染（50ms延迟缓冲）
6. 事件（方块操作、命中）走可靠通道，确保送达
7. 实体位置走不可靠通道（丢包等下帧覆盖）

**多通道拆分：**
| 通道 | 内容 | 可靠性 |
|------|------|--------|
| 不可靠 | 实体位置更新 | 丢包不重传，下帧覆盖 |
| 可靠 | 方块操作、命中确认、玩家出入 | 超时重传 + 幂等去重 |
| 可靠(有序) | 聊天、系统消息 | 保证顺序 |

**必要前提：**
- 确定性模拟（同样的输入 → 同样的输出，不能有随机数）
- 客机侧保存最近 N 帧输入历史（用于重放）
- 服务端保留最近 N 帧快照历史（用于延迟补偿）
- 客机有独立的本地物理/逻辑副本（预测回路）
- 需要可靠 UDP 库（Laminar/enet）或多通道 TCP 改造

### 非完整方块 mesh 架构

水面是游戏中第一个非完整方块，采用独立的渲染管线和顶点格式：

- **不透明方块**：`ChunkVertex`（4B），非索引（6 顶点/面），共享 bind group 1（材质纹理），`pipeline_chunk`
- **树叶/半透明方块**：`ChunkVertex`（4B），非索引（6 顶点/面），独立 `pipeline_foliage`
  - `cullMode = Back`，`depthWrite = true`，`depthCompare = GreaterEqual`
  - 片段着色器 `fs_foliage`：`alpha < 0.5 → discard`，利用 `GreaterEqual` 遮挡水
  - 渲染顺序：Pass1 实心块 → Pass2 水 → 树叶（在 Pass2 内水之后绘制）
- **水面**：`StaticVertex`（32B），索引（4 顶点+6 索引/面），独立管线，Alpha blend + 波纹动画

树叶使用独立管线的原因：
1. 需要 alpha discard（`fs_foliage`）防止半透明像素写深度
2. 需要 `depthCompare = GreaterEqual` 而非 `Greater`，以正确遮挡水
3. 需要 `depthWrite = true` 确保树叶间前后正确排序

水面使用独立管线的原因：
1. Alpha 混合（`SrcAlpha / OneMinusSrcAlpha`）需要单独的 blend state
2. 顶点着色器需要波纹位移（其他方块不需要）
3. 片元着色器需要水色 + 透明度

**水面 mesh 生成**（`chunk_mesh.zig`）：

每个水面方块在 `buildChunkMeshCPU` 中独立生成顶点数据，存入 `water_vertices`/`water_indices`。
相对于不透明方块（`ChunkVertex` 4B 压缩 + 非索引 6 顶/面），水面 mesh 的不同之处：

- `StaticVertex`（32B/顶点）：完整浮点坐标，精确支持 0.8 格高度
- `u32` 索引画法（4 顶点 + 6 索引/面）：节省顶点 buffer 带宽
- 顶面斜坡：邻接满高水方块时抬升至 1.0，否则降至 0.8
- 跨区块查询：通过 `nb_west/east/north/south` 指针查邻居 chunk

**水面着色器**（`water_shader.wgsl`）：
- **波浪**：旋转UV + 3层噪声 + 有限差分法线（Sildurs 式）
- **统一反射层**：`scene_reflect = mix(天空颜色, SSR颜色, ssr_fade)`
- **Fresnel**：Schlick `0.02+0.98*(1-NdotV)^5`，混合 `refracted` 与 `lit_water + scene_reflect`
- **折射**：场景纹理采样 + 线性深度吸收（水深→深蓝）
- **阴影响应**：`shadow_darken = mix(0.75, 1.0, shadow)` 乘法暗化；日月高光乘 `shadow`
- **SSR**：10 步指数步进 + 5 步二分搜索，边缘淡出 + 假阳性抑制，竖直水面跳过
- **日月高光**：`smoothstep(0.995, 1.0)` 窄反射峰，`shadow_vp` 白天太阳、晚上月亮

后续非完整方块（半砖、楼梯、栅栏等）的 mesh 复杂度更高，可能需要更灵活的方块模型系统。

---

### 讨论记录

- 2026-06-15：决定骨骼动画在客机本地计算，不传输矩阵。状态同步为主机权威。物理物体按重要性分层处理。
- 2026-06-19：发现 zig-ecs 并非线程安全，服务端线程写 Position 会踩坏 AnimationState 的 bone_offset。
  当前方案：pollServerSnapshot 中检测非法 bone_offset 并重新分配。
  将来做物理骨骼动画时，要么给 zig-ecs 加读写锁，要么换支持并发的 ECS（如 EnTT）。
- 2026-06-19：chunk 顶点编码修复。`ChunkVertex.bx/by/bz` 在 `@intFromFloat` 前加 `+ 0.01` epsilon。
  根因推测：x/y/z 为 0 时，浮点运算引入的微小负数误差被 `@intFromFloat` 向零截断后，
  与相邻面的正数值坍缩到相同整数，导致退化三角形（零面积面）。
  epsilon 将这些值推到远离零的稳定区域，保证每个面的顶点落在正确整数位置。
  注：`ZBlock_内存调色板` 分支也需要此修复，届时手动改 `chunk_mesh.zig` 三行即可。

- 2026-06-27：ReleaseFast 下 `resolveClip` 遍历 `model.animations` 读 `clip.name` 偶发崩溃。
  根因疑似编译器优化导致 `clip.name` 的内存读取被跳过。
  修复：用 `@memcpy` 将 `clip.name` 拷贝到局部变量再访问，强制编译器做真实内存读取。
  简单测试无法复现，需要完整项目环境（多线程 ECS + 复杂调用链）才能触发。
- 2026-07-09：程序化榕树生成（`tree_gen.zig`）。`pipeline_foliage` 独立管线（`fs_foliage` + alpha discard + `cullMode=Back` + `depthWrite=true` + `depthCompare=GreaterEqual`）。
- 2026-07-10：根因定位 ~0.1MB/s 内存泄漏：`render.zig` 阴影 pass 缺少 `wgpuRenderPassEncoderRelease`（~1-4KB/帧，60fps → 60-240KB/s）。
- 2026-07-10：`NeighborChunks` 结构体统一管理四邻域指针，`neighborAtXZ` helper 消除跨区块查询重复代码。
- 2026-07-10：`disconnectClient` → `returnToMenu` 合并，消除断线双重释放竞态。
- 2026-07-10：`pending_unloads` 消费修复，主机模式下客机现在能正确卸载远离的区块。
- 2026-07-10：`orderedRemove(0)` 改为 swap 整列（O(n²) → O(1)）。多处 `catch {}` 泄漏修复。

---

## 议题六：区块两阶段生成（Terrain → Populate）

### 问题

树在区块交界处被切开，因为 `populateBanyan` 在 IO worker 中「生成地形后立即执行」，只知道自己区块内的方块数据，不知道邻居区块处是否有树冠伸过来。之前的方案（`estimateSurfaceHeight` 噪声估算）在非 grass 地形边界处不准确，会产生无源树叶。

### 目标

实现类似 Minecraft 的两阶段生成：

1. **Terrain（地形）**：当前 `Chunk.generate()`——只放石头、泥土、沙、水、grass、洞穴、基岩
2. **Populate（填充）**：种树、放草、石头等——延迟到所有邻居区块的地形都生成完再执行

### 核心思路

```
IO worker 加载/生成地形 → 标记 terrain_generated = true
  → 检查自己和 4 个邻居是否全部 terrain_generated
    → 是 → 执行 populate（种树）+ 推入 completed_loads
    → 否 → 暂存 pending_populate
当任何一个新 chunk 完成地形生成时 → 再次检查邻居
```

### 数据结构

#### `LoadedChunk` 新增字段

```zig
const LoadedChunk = struct {
    chunk: *Chunk,
    meshes: std.AutoHashMap(MaterialIdx, ChunkMesh),
    foliage_meshes: std.AutoHashMap(MaterialIdx, ChunkMesh),
    water_mesh: ChunkMesh,
    build_lock: std.atomic.Value(bool),
    dirty: bool,
    terrain_generated: bool = false,  // <-- 新增：标记地形是否已生成
    populate_done: bool = false,       // <-- 新增：标记 populate 是否已完成
};
```

#### `BlockWorld` 新增字段

```zig
pending_populate: std.AutoHashMap(Vec3i, *Chunk),  // IO worker 独占，无需 mutex
```

### IO worker 流程

```
当前: Chunk.generate(o, chunk) → [立即] tree_gen.populateBanyan(chunk, o)
改为:
  1. chunk.* = Chunk.init(pa) + Chunk.generate(o, chunk)
  2. chunk.terrain_generated = true
  3. pending_populate.put(o, chunk)
  4. 遍历 (o + 四邻居) 共 5 个坐标:
     for each candidate in [o, o+west, o+east, o+north, o+south]:
       if candidate 在 pending_populate 中且邻居们都 terrain_generated:
         → pop candidate
         → 调 tree_gen.populateWithNeighbors(candidate, ...)
         → 标记 populate_done = true
         → 推入 completed_loads
  5. 如果当前 chunk 仍未 populate（条件不满足）
      → 不推入 completed_loads，留在 pending_populate
```

### 判断条件

```zig
fn canPopulate(world: *BlockWorld, origin: Vec3i) bool {
    const offsets = [_]struct { x: i32, z: i32 }{
        .{ .x = 0, .z = 0 },
        .{ .x = -1, .z = 0 },  // west
        .{ .x = 1, .z = 0 },   // east
        .{ .x = 0, .z = -1 },  // north
        .{ .x = 0, .z = 1 },   // south
    };
    for (offsets) |off| {
        const nb_origin = Vec3i.new(origin.x + off.x * CHUNK_WIDTH_I32, 0, origin.z + off.z * CHUNK_WIDTH_I32);
        const entry = world.pending_populate.get(nb_origin) orelse return false;
        if (!entry.terrain_generated) return false;
    }
    return true;
}
```

### Populate 阶段的树种树

```zig
fn tryPopulate(world: *BlockWorld, origin: Vec3i) void {
    if (!canPopulate(world, origin)) return;
    _ = world.pending_populate.remove(origin);
    const chunk = world.pending_populate.get(origin).?;  // 已取

    // 查邻居 chunk 指针
    const nb_west  = world.pending_populate.get(Vec3i.new(...));
    const nb_east  = world.pending_populate.get(Vec3i.new(...));
    const nb_north = world.pending_populate.get(Vec3i.new(...));
    const nb_south = world.pending_populate.get(Vec3i.new(...));

    tree_gen.populateWithNeighbors(chunk, origin, nb_west, nb_east, nb_north, nb_south);
    chunk.populate_done = true;

    // 推入 completed_loads（主线程接收）
    world.completed_loads_mutex.lockUncancelable(io);
    world.completed_loads.append(world.allocator, .{ .origin = origin, .chunk = chunk }) catch {};
    world.completed_loads_mutex.unlock(io);
}
```

### `tree_gen.populateWithNeighbors`

签名变化：
```zig
pub fn populateWithNeighbors(
    chunk: *Chunk,
    world_origin: Vec3i,
    nb_west: ?*const Chunk,
    nb_east: ?*const Chunk,
    nb_north: ?*const Chunk,
    nb_south: ?*const Chunk,
) void
```

不再需要 `estimateSurfaceHeight`。判断地表类型时，查邻居 chunk 的 `getBlockId`。

### 世界边缘处理

最外层区块永远等不到所有邻居 → IO worker 空闲时扫 pending_populate，设定超时机制：

```
每处理完一批 load 任务后：
  for each origin in pending_populate:
    if (当前时间 - origin 入队时间) > 超时阈值(如 500ms)
      → 强制 populate（只用自己的数据）
      → 推入 completed_loads
```

或者更简单：每次 IO worker 空闲（`io_cond.wait` 前），扫一遍 pending_populate 强制全部 populate。

### 存档兼容性

- **旧存档**：没有 populate 标记 → 加载后视为 terrain_generated = true，在 `processCompletedLoads` 中触发 populate
- **新存档**：存 `populate_done = true`（1 bit per chunk，可放进 chunk 元数据）
- **崩溃恢复**：如果 `populate_done = false`，下次加载时重新 populate

### 多人游戏

- `completed_loads` 是主线程接收新 chunk 的唯一入口
- `sendChunk` 在 `processCompletedLoads` 中触发
- 因为 populate 在进入 `completed_loads` 前已完成
- **客机天然只收到 populate 完成的 chunk**，无需额外同步

### 与现有异步系统的关系

```
IO worker:
  generate terrain → pending_populate → 检查邻居 → 
    [成熟] populate → completed_loads
    [不成熟] 留在 pending_populate

Mesh worker:  不变，从 pending 取 origin → 从 chunks 读数据
主线程:       processCompletedLoads → chunks.put（populate 已完成）
```

**无需新 mutex**：pending_populate 是 IO worker 独占。

### 分步实施

| 步骤 | 改动 | 文件 |
|:----|:-----|:-----|
| 1 | LoadedChunk: 加 `terrain_generated` / `populate_done` | `block_world.zig` |
| 2 | BlockWorld: 加 `pending_populate: std.AutoHashMap(Vec3i, *Chunk)` + deinit 清理 | `block_world.zig` |
| 3 | IO worker 地形生成后标记 + 入队 pending_populate | `block_world.zig` |
| 4 | `canPopulate` / `tryPopulate` 实现 | `block_world.zig` |
| 5 | `populateWithNeighbors` 替代 `populateBanyan` | `tree_gen.zig` |
| 6 | 世界边缘兜底：超时/空闲强制 populate | `block_world.zig` |
| 7 | 存档 save/load `populate_done` | `save_manager.zig` |

### 未来扩展

这套 populate 机制不限于树：

| 填充物 | 条件 | 优先级 |
|:-------|:-----|:------|
| 树（榕树） | grass、海拔 < 80、噪声密度 | P0—当前 |
| 贴图草 | grass、noise | P1 |
| 花 | grass、small noise | P2 |
| 蘑菇（洞穴） | cave air、低光 | P2 |
| 矿石团 | stone 内部 | P3（可走 terrain） |
| 建筑预制 | 额外邻居范围 | P3 |

### 武器系统方案

**目标**：第一人称持枪（手部动画、换弹、切枪），Mod 支持自定义武器。

**方案**（2026-07-07）：
- 手部模型 + 骨骼 + 网格在 ``hands.glb`` 中定义，所有武器共用同一套骨架
- 每把武器独立 glTF（仅枪械网格 + 动画 clip），不包含骨骼
- 加载武器动画时：``node name -> hand skeleton joint index`` 重映射
  - zgltf 提供了 ``node.name`` 和 ``channel.target.node``（node index）
  - 加载时根据武器 node 名查 hand skeleton 的 name->index 表
- 饰品（手套/戒指）直接在 ``hands.glb`` 中加 mesh，蒙皮到同一骨骼
- Mod：丢一个 ``pistol_foo.glb`` 进去，动画名用约定（``idle``/``reload``/``fire``）

**所需改动**：
- ``rend_ctx.zig``：``Skeleton`` 加 ``joint_names: [][]const u8``
- ``rend_ctx.zig``：``Model.load()`` 加可选 ``parent_skeleton``，武器加载时重映射

---

## 待办事项


