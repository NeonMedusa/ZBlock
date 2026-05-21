# 存档格式

## 总览

游戏存档使用 SQLite 数据库，分两层存储：

- **world.db** — 世界元数据（玩家、热栏、背包、实体）
- **region/r\_x\_z.db** — 区块数据（按 32×32 chunk 分片）

所有方块/物品/实体均按**字符串名称**存储，不依赖游戏版本号。任何版本的游戏都能正确读取任何版本的存档。

---

## 世界元数据（world.db）

### WorldRow

```sql
CREATE TABLE "WorldRow" (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    last_played TEXT NOT NULL DEFAULT (datetime('now')),
    player_pos_x  REAL NOT NULL,
    player_pos_y  REAL NOT NULL,
    player_pos_z  REAL NOT NULL,
    player_health REAL NOT NULL,
    is_flying   INTEGER NOT NULL DEFAULT 0,
    tick_count  INTEGER NOT NULL DEFAULT 0,
    player_facing_yaw   REAL NOT NULL DEFAULT 0,
    player_facing_pitch REAL NOT NULL DEFAULT 0
);
```

存储单行玩家状态。每次保存先 `DELETE` 再 `INSERT`，始终保持一行。

### HotbarRow

```sql
CREATE TABLE "HotbarRow" (
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    slot   INTEGER NOT NULL,
    item_name TEXT NOT NULL,
    count  INTEGER NOT NULL DEFAULT 1
);
```

- `slot`: 0-8，对应热栏 9 格
- `item_name`: 字符串名称（如 `"stone"`、`"apple"`），非整数 ID

### InventoryRow

```sql
CREATE TABLE "InventoryRow" (
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    slot   INTEGER NOT NULL,
    item_name TEXT NOT NULL,
    count  INTEGER NOT NULL DEFAULT 1
);
```

- `slot`: 0-26，对应背包 27 格

### EntityRow

```sql
CREATE TABLE "EntityRow" (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    type_name TEXT NOT NULL,
    pos_x    REAL NOT NULL,
    pos_y    REAL NOT NULL,
    pos_z    REAL NOT NULL,
    health   REAL NOT NULL DEFAULT 100.0,
    facing_yaw   REAL NOT NULL DEFAULT 0,
    facing_pitch REAL NOT NULL DEFAULT 0
);
```

- `type_name`: 实体类型字符串名称（如 `"zombie"`、`"wolf"`），非整数 ID
- `facing_yaw` / `facing_pitch`: 实体朝向（弧度），`DEFAULT 0` 兼容旧存档

### 版本兼容

背包、热栏、实体不存整数 ID。游戏版本升级时，即使 `block_infos` / `item_infos` / `entity_infos` 发生增删改，加载时通过 `fromNameRuntime` 查找：

- 名称存在 → 正常加载
- 名称不存在（已被删除）→ 跳过或替代为空气

**不需要任何迁移工具或版本号。**

---

## 区块数据（region/r\_x\_z.db）

### Region 分片

每 32×32 个 chunk 为一个 region（约 512×512 方块），各 region 独立 `r_{rx}_{rz}.db` 文件。

### Chunks 表

```sql
CREATE TABLE "Chunks" (
    x       INTEGER NOT NULL,
    z       INTEGER NOT NULL,
    palette TEXT NOT NULL,
    data    BLOB NOT NULL,
    PRIMARY KEY (x, z)
);
```

- `x`, `z`: chunk 坐标（一个 chunk = 16×256×16 方块）
- `palette`: JSON 字符串数组，列出该 chunk 中出现的所有方块类型名称
- `data`: bit-packed 二进制块，存储 65536 个方块的调色板索引 + 朝向值

### 每个 chunk 一个 palette（per-chunk palette）

每个 chunk 保存时全量重建自己的 palette。只包含当前 chunk 出现的方块类型：

```json
["air", "grass", "stone", "dirt", "water"]
```

- palette 行数 = 当前 chunk 的独特方块数量（地表 ~5-15 种，地下 ~3-8 种）
- palette 是**自描述的**：加载时不依赖游戏版本的 `block_infos` 定义

### 自动清理幽灵条目

因为每次 `saveChunk` 都是**全量重建 + `INSERT OR REPLACE`**：

1. 扫描当前 65536 个方块，收集 unique 的 block_id
2. 构建 palette（只含当前存在的方块类型）
3. 写入 DB 替换旧数据

如果某个方块类型在游戏更新中被删除，下次保存该 chunk 时 palette 中自然不再包含它。**不需要额外的压缩工具或引用计数。**

### Data BLOB 格式

`data` 是一个连续的比特流，每方块存储 `[palette_index | facing]` 的紧凑位序列：

```
每个方块占用 bits = bits_per_index + 4

bits_per_index = ceil(log2(palette_size))
                 palette_size=1 时特判为 1

facing = 4 bits（0-5，对应 Direction 枚举的 6 个朝向）
```

排列方式：按 `[x][y][z]` 顺序逐块排列，总共 65536 组，无分隔符。

| palette_size | bits_per_index | 每方块总位 | 每 chunk data 体积 |
|-------------|----------------|-----------|-------------------|
| 1           | 1              | 5         | ~40KB             |
| 2-3         | 2              | 6         | ~48KB             |
| 4-7         | 3              | 7         | ~56KB             |
| 8-15        | 4              | 8         | **64KB**          |
| 16-31       | 5              | 9         | ~72KB             |

相比旧方案固定 256KB/chunk，体积缩小约 4-6 倍。

### 比特流编码细节

使用 `BitWriter` / `BitReader` 工具：

```zig
const BitWriter = struct {
    buf: []u8,
    byte_pos: usize,
    bit_pos: u4,     // 当前 byte 中下一个可写入的 bit 位置

    fn write(self, value: u32, bits: u32) void;
    fn finish(self) usize;  // 返回实际占用字节数
};

const BitReader = struct {
    buf: []const u8,
    byte_pos: usize,
    bit_pos: u4,

    fn read(self, bits: u32) u32;
};
```

实现要点：

- 跨字节边界写入：当 `bit_pos + bits > 8` 时，拆分到相邻字节
- 不设字节序——按位逐字节处理，无歧义
- `finish` 返回向上取整的字节数（最后不足一字节也计为一字节）

### 保存流程（saveChunk）

```
1. 扫描 65536 个方块
   → AutoHashMap<block_id, palette_index>（去重 + 分配索引）

2. 构建 palette 名称数组
   → 用 block_infos[block_id].name 收集
   → JSON 序列化：["air","grass","stone",...]

3. 计算 bits_per_index = ceil(log2(palette_size))

4. 分配 data 缓冲区
   → 大小 = (65536 * (bits_per_index + 4) + 7) / 8

5. BitWriter 逐块写入：
   → write(palette_index, bits_per_index)
   → write(facing_enum, 4)

6. INSERT OR REPLACE INTO Chunks (x, z, palette, data)
```

### 加载流程（loadChunk）

```
1. SELECT palette, data FROM Chunks

2. 解析 palette JSON → 字符串数组

3. 分配 runtime_ids[palette_size]
   → for each name: runtime_ids[i] = blockNameToId(name)
   → 找不到的名称对应 ID=0（air）

4. 计算 bits_per_index = ceil(log2(palette_size))

5. BitReader 逐块解包：
   → pal_idx  = read(bits_per_index)
   → facing   = read(4)
   → blocks[i] = BlockState{ block_id = runtime_ids[pal_idx], facing }
```

### 版本兼容

- palette 是自描述的字符串数组，不依赖游戏版本的 `block_infos`
- 加载时 `BlockId.fromNameRuntime(name)` 返回 `null` → 自动作为空气处理
- 新版本增加方块 → 旧存档正常读取（区块中不会出现该方块名字，除非被新版本编辑过）
- 新版本删除方块 → 旧存档中该方块加载时变为空气，下次保存时从 palette 中自动消失

**不需要版本号、不需要迁移工具、不需要外部映射文件。**
