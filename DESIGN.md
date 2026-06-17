# DESIGN.md

## 当前架构（2026-06-17）

### 进程架构

所有模式（单人/主机/客机）共享同一份可执行文件。三种运行模式由 `Game.network_mode` 区分：

| 模式 | `network_mode` | 服务端线程 | 网络线程 | 渲染 |
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
  1. timedWait 等够 33ms
  2. drain 所有输入
  3. 处理每个输入 → MoveIntent/朝向/break/place/fly
  4. updatePhysics (30Hz 固定, 与输入数量无关)
  5. updateAI (最近玩家追踪)
  6. animation_system.update
  7. updateEntities (生命值/消失)
  8. updateChunks (所有玩家的区块加载/卸载)
  9. publishSnapshot → 快照缓冲区(mutex保护)

网络线程(独立线程, 仅 host 模式):
  accept → 创建远程玩家实体
  循环: recvInput → pushInput(player_id=1)
        读 server.snapshots → sendState
        读 server.pending_chunks → sendChunk
        读 server.pending_unloads → sendChunkUnload
```

### 玩家平等性

主机玩家和远程客机的输入路径完全统一：

- **输入**：`collectPlayerInput` → `pushInput`（主机走队列，客机走 TCP → 网络线程 → 队列）
- **处理**：服务端线程根据 `input.player_id` 找到对应实体，统一处理 MoveIntent/朝向/break/place/fly
- **渲染**：都从快照缓冲区读数，用 `accumulator/TICK_DT` 做累计器插值
- **区块**：`updateChunks` 遍历所有玩家，主机从磁盘加载/卸载，远程通过 `pending_chunks` 发送

### 快照与插值

```
服务端 tick 结束 → publishSnapshot() → snapshots[64] (mutex 保护, 含所有实体的位置/朝向)
  ↓
网络线程: 读 snapshots → 组 state 包 → 发客机
主线程:  pollServerSnapshot() (主机) / clientTick state (客机)
  → pushSnapshot() → snap_prev, snap_curr
  → 渲染: lerp(snap_prev, snap_curr, accumulator/TICK_DT)
```

### 联机数据流

```
主机:
  clientTick (30Hz): sendInput → clientReceivePackets (每帧)
  clientReceivePackets: poll(0) → peekTag → 收 state/chunk/unload → 更新插值

客机收到: state 包 (tag=1) → 更新 snap_prev/snap_curr → 累计器插值
          chunk 包 (tag=2) → insertChunkFromNetwork → enqueueMeshBuild
          unload 包 (tag=3) → unloadChunk
```

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
- 记录所有在 Boss 战期间被修改的方块坐标 + 旧方块 ID
- 战斗结束时逐格恢复

这样快照体积小、速度快。

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
| `position` | Vec3 (12B) | 30 Hz | 实体位置 |
| `yaw` | f32 (4B) | 30 Hz | 水平朝向 |
| `pitch` | f32 (4B) | 30 Hz | 垂直朝向 |

每实体 ≈ 20 字节，50 实体 = 1KB/tick = **30KB/s**。

#### 第二层：运动状态（按需添加）

| 字段 | 类型 | 频率 | 说明 |
|------|------|------|------|
| `velocity` | Vec3 (12B) | 30 Hz | 用于客机本地插值预测 |
| `on_ground` | bool (1B) | 30 Hz | 接地状态，影响动画切换 |
| `health` | f32 (4B) | 事件触发 | 受伤/治疗时发送 |

#### 第三层：动画状态（将来）

| 字段 | 类型 | 频率 | 说明 |
|------|------|------|------|
| `clip_name` | u8 (1B) | 切换时 | 动画剪辑索引（idle/walk/run/jump/attack） |
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

1. **当前**：TCP，全量状态每 tick 发送（30Hz）
2. **短期**：增加 delta 压缩（只发送变化的字段）
3. **中期**：迁移到 UDP，序列号 + ACK，支持丢包重传
4. **长期**：状态同步 + 事件帧双通道（可靠通道发状态，不可靠通道发位置更新）

### 讨论记录

- 2026-06-15：决定骨骼动画在客机本地计算，不传输矩阵。状态同步为主机权威。物理物体按重要性分层处理。

