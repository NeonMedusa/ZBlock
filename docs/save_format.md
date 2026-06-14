# 存档格式

## 总览

存档分为三层存储：

- **world.db** — 世界元数据（tick_count、创建时间、实体）
- **players/\<player_id\>.dat** — 玩家数据（位置、血量、热栏、背包）
- **regions/r\_x\_z.db** — 区块数据（按 32×32 chunk 分片）

所有方块/物品/实体均按**字符串名称**存储，不依赖游戏版本号。

---

## 世界元数据（world.db）

### WorldMeta

```sql
CREATE TABLE "WorldMeta" (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    last_played TEXT NOT NULL DEFAULT (datetime('now')),
    tick_count  INTEGER NOT NULL DEFAULT 0
);
```

存储单行世界数据（不含玩家信息）。每次保存先 `DELETE` 再 `INSERT`。

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

存储 AI 实体（非玩家）。

---

## 玩家数据（players/\<用户名\>.json）

每个玩家一个独立文件，以玩家名命名（如 `players/NeonMedsua.json`），自定义文本格式：

用户名由 `config/user_name.json` 配置：`{ "name": "NeonMedsua" }`，首次启动自动生成 `user_\<随机数字\>`。

```
pos:8.0,130.0,8.0
health:100.0
flying:false
facing:0.0000,0.0000
h0:stone,64
h1:
h2:dirt,32
h3:
h4:
h5:
h6:
h7:
h8:
i0:
i1:
...（共 27 行背包）
i26:
```

- `pos`: 脚底坐标 x,y,z
- `flying`: `true` / `false`
- `facing`: yaw, pitch（弧度）
- `h0` ~ `h8`: 热栏 9 格，`h0:stone,64` 表示物品名称和数量，`h0:` 表示空格
- `i0` ~ `i26`: 背包 27 格，格式同上
- 物品用字符串名称（非整数 ID），保证版本兼容

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
- `palette`: JSON 字符串数组，列出该 chunk 中出现的所有方块类型名称（含朝向后缀）
- `data`: bit-packed 二进制块，存储 65536 个方块的调色板索引

### 每个 chunk 一个 palette（per-chunk palette）

每个 chunk 保存时全量重建自己的 palette。只包含当前 chunk 出现的 `BlockState`（方块种类 + 朝向的组合）：

```json
["air", "water", "grass_0", "sand", "stone", "dirt", "snow"]
```

- 每项格式 `blockName_facingInt`，如 `"stone_5"` 表示 stone 的第 5 个朝向
- palette 行数 ≤ 方块数 × 6 朝向（当前最多 8 × 6 = 48 种）
- palette 是**自描述的**：加载时不依赖游戏版本的 `block_infos` 定义

### 自动清理幽灵条目

因为每次 `saveChunk` 都是**全量重建 + `INSERT OR REPLACE`**：

1. 将 chunk 的运行时 palette 序列化为 JSON（无需遍历 65536 个方块）
2. 将运行时 `index_data` 直接复制为 data BLOB
3. 写入 DB 替换旧数据

如果某个方块类型在游戏更新中被删除，下次保存该 chunk 时 palette 中自然不再包含它。**不需要额外的压缩工具或引用计数。**

### Data BLOB 格式

`data` 是一个连续的比特流，每方块存储 `palette_index`（不单独存储朝向——朝向已编码到 palette 的 facing 后缀中）：

```
每个方块占用 bits = bits_per_index

bits_per_index = ceil(log2(palette_size))
                 palette_size=1 时特判为 1
```

排列方式：按 `[x][y][z]` 顺序逐块排列，总共 65536 组，无分隔符。

| palette_size | bits_per_index | 每方块总位 | 每 chunk data 体积 |
|-------------|----------------|-----------|-------------------|
| 1           | 1              | 1         | ~8KB              |
| 2-3         | 2              | 2         | ~16KB             |
| 4-7         | 3              | 3         | ~24KB             |
| 8-15        | 4              | 4         | **32KB**          |
| 16-31       | 5              | 5         | ~40KB             |

相比旧方案固定 256KB/chunk，体积缩小约 6-32 倍。

### 保存流程（saveChunk）

```
1. 将 chunk.palette 序列化为 JSON 名称数组
   → 遍历 5-48 条记录，每条格式 "blockName_facingInt"
   → JSON 序列化：["air","grass_0","stone_0","dirt_0",...]

2. 计算 bits_per_index = ceil(log2(palette_size))

3. 将 index_data 的前 N 字节直接写入 data BLOB
   → 大小 = (65536 * bits_per_index + 7) / 8
   → 0 次 BitWriter

4. INSERT OR REPLACE INTO Chunks (x, z, palette, data)
```

### 加载流程（loadChunk）

```
1. SELECT palette, data FROM Chunks

2. 解析 palette JSON → 名称字符串数组
   对于每个名称，解析 "blockName_facingInt"：
   → 找到最后一个 '_'：左侧为 block_name，右侧为 facing 数字
   → 无 '_' 时自动降级为 facing=0（兼容旧格式）

3. 从名称直接构建运行时 palette（含 facing）
   → runtime_palette[i] = BlockState{ block_id, facing }
   → 0 次 BitReader 解包

4. 计算 bits_per_index，分配 index_data
   → 将 data BLOB 直接 @memcpy 到 index_data
   → 0 次 BitReader，0 次 writeBits
```

### 版本兼容

- palette 是自描述的字符串数组，不依赖游戏版本的 `block_infos` 定义
- 旧格式 palette（无 facing 后缀的纯名称列表）仍可正常加载：缺失 `_` 时默认 facing = 0（up）
- 加载时 `registries.block_name_to_id.get(name)` 返回 `null` → 自动作为空气处理
- 新版本增加方块 → 旧存档正常读取
- 新版本删除方块 → 旧存档中该方块加载时变为空气，下次保存时从 palette 中自动消失

**不需要版本号、不需要迁移工具、不需要外部映射文件。**
