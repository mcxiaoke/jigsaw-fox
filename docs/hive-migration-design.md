# Hive 迁移设计文档

> 日期：2026-09-02
> 关联文档：`docs/puzzle-missing-fields-audit.md`（字段缺口审计）、`docs/puzzle-my-tab-and-daily-fold-plan-v2.md`（实施方案 v2.1）
> 状态：**方案评审稿**，用户审阅后再决定是否实施
> 选型：`hive_ce` 2.19.3 + `hive_ce_flutter`（纯 Dart，零原生依赖，详见上一轮评估结论）

---

## 一、目标

1. 将所有业务数据从 SharedPreferences 迁移到 Hive KV 存储
2. SharedPreferences 仅保留真正的用户设置（布尔/字符串/枚举，与游戏进度无关）
3. 统一 Hive key 命名规范：所有 box 名称带版本后缀 `-v1`，schema 破坏性变更时开新 box `-v2`
4. 统一字段定义：消除现有数据冗余（`jigsaw_level_N` vs `jigsaw_progress_v3_main_N` 重复存储进度字段），确立 SSOT
5. 消除 SharedPreferences 的结构性缺陷：单 key 大数组全量读写、N+1 缓存刷新、单文件全量 IO

---

## 二、存储边界划分

### 保留在 SharedPreferences 的数据（纯设置，业务无关）

| key | 类型 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `setting.sound` | bool | true | 音效开关 |
| `setting.haptic` | bool | true | 震动反馈开关 |
| `setting.gridPreview` | bool | true | 网格预览开关 |
| `setting.pieceScatterMode` | String | `"tray"` | 碎片排布模式：`"tray"` / `"tabletop"` |
| `setting.selectedBackground` | String | `"assets/bg/tile_000.webp"` | 选中背景图 asset 路径 |
| `hive.migrated` | bool | false | Hive 迁移是否已完成（一次性标志） |

> **原则**：SharedPreferences 只存「用户可在设置页面切换的、与游戏进度/数据无关的偏好」。经济、统计、成就等业务数据即使很小也迁入 Hive，保证数据一致性。

### 迁入 Hive 的数据

| 数据域 | 当前 SharedPreferences key 模式 | Hive box | 说明 |
| :--- | :--- | :--- | :--- |
| 关卡进度 | `jigsaw_progress_v3_{cid}` | `progress-v1` | 逐条 key，消除 N+1 |
| 自制拼图元数据 | `jigsaw_custom_list`（单 key 大数组） | `custom-puzzles-v1` | 逐条 key，消除全量读写 |
| 收藏列表 | `jigsaw_favorites_v1`（单 key 大数组） | `favorites-v1` | 逐条 key，消除全量读写 |
| 成就系统 | `jigsaw_achievement_*`（4 个 key） | `achievements-v1` | 拆为逐条 key |
| 经济系统 | `jigsaw_economy_*`（5 个 key） | `economy-v1` | 小量 KV，统一管理 |
| 全局统计 | `jigsaw_stat_*`（2 个 key） | `stats-v1` | 含缓存聚合值 |
| 主线解锁状态 | `jigsaw_level_{n}`（100 个 key） | `level-unlocks-v1` | 仅保留 isUnlocked，其余字段委托 ProgressStore |
| 旧迁移标志 | `jigsaw_snapshots_v3_migrated` / `jigsaw_difficulty_v3_3_migrated` | 迁移后删除 | 旧迁移已完成，不需要保留 |

### 不迁移的文件存储（已正确设计）

| 存储 | 路径 | 说明 |
| :--- | :--- | :--- |
| 快照文件 | `{appSupport}/snapshots/*.snapshot` | SnapshotStore 文件级存储，保持不变 |
| 主线缓存 | `{appDoc}/main_levels_cache.json` | 服务端关卡清单，独立文件缓存 |
| 活动缓存 | `{appDoc}/events_cache.json` | 服务端活动列表，独立文件缓存 |
| 清单缓存 | `{appDoc}/manifest_cache.json` | 服务端应用清单，独立文件缓存 |

---

## 三、Hive 命名规范

### 3.1 Box 命名

```
格式：{domain}-v{N}
示例：progress-v1、custom-puzzles-v1、favorites-v1、achievements-v1
```

| 规则 | 说明 |
| :--- | :--- |
| 全小写 | box 名一律小写 |
| 连字符分隔 | 多词用 `-` 连接，如 `custom-puzzles` |
| 版本后缀 | 必须带 `-v{N}`，N 从 1 起 |
| 语义命名 | domain 反映数据域，不反映技术实现 |

### 3.2 Box 内 key 命名

| 场景 | key 规则 | 示例 |
| :--- | :--- | :--- |
| 逐条记录 box | 自然 ID，不带版本 | `main:001`、`daily:20260902`、`ugc:sample_01` |
| 混合类型 box | `{type}:{id}` 前缀区分 | `counter:play_seconds`、`unlock:first_win`、`starred:main:001` |
| 单值 box | camelCase 语义名 | `coins`、`hintCoupons`、`dailyEarned` |

### 3.3 Value 字段命名

| 规则 | 说明 | 示例 |
| :--- | :--- | :--- |
| camelCase | 与 Dart 字段名一致 | `progressPercent`、`bestTimeSeconds` |
| 无前缀后缀 | box 名已提供上下文，字段名不加域前缀 | `stars` 而非 `progressStars` |
| DateTime | 存 ISO 8601 字符串 | `"2026-09-02T16:25:11.293460"` |
| 可空字段 | null 时省略该键（与现有 toJson 一致） | `firstPlayedAt` 为 null 则不出现在 Map 中 |
| 嵌套对象 | 存为 `Map<String, dynamic>` | `records` → `{"4x6": {bestStars: 1, ...}}` |

### 3.4 版本升级规则

| 变更类型 | 是否需要新 box | 说明 |
| :--- | :--- | :--- |
| 新增可选字段（有默认值） | **否** | 旧记录缺失该字段 → fromJson 时取默认值，向前兼容 |
| 删除字段 | **是** | 开 `-v2`，迁移时丢弃该字段 |
| 字段改类型 | **是** | 开 `-v2`，迁移时做类型转换 |
| 字段改语义（同名不同义） | **是** | 开 `-v2`，迁移时按新语义重映射 |
| 字段重命名 | **是** | 开 `-v2`，迁移时按新名写入 |

> 与现有 `extra` 通道互补：`extra` 保证「旧版本 App 读新数据不丢字段」，box 版本号保证「新版本 App 不读旧 schema 数据」。两者叠加 = 全向前向后兼容。

---

## 四、Box 设计与字段定义

### 4.1 `progress-v1` — 关卡进度

**Box key**：canonicalId（如 `main:001`、`daily:20260902`、`ugc:sample_01`、`pack:nature:001`）
**Value**：`Map<String, dynamic>`（`LevelProgress.toJson()` 的输出）

| 字段名 | 类型 | 必填 | 默认值 | 说明 |
| :--- | :--- | :-- | :--- | :--- |
| `canonicalId` | String | 是 | — | 全局规范主键（与 box key 一致） |
| `progressPercent` | int | 是 | `0` | 当前进度百分比 0–100 |
| `isCompleted` | bool | 是 | `false` | 是否通关（粘性，通关后永久 true） |
| `completedPieceCounts` | List\<int\> | 是 | `[]` | 已完成的碎片数集合（按难度 pieceCount 去重） |
| `bestTimeSeconds` | int | 是 | `0` | 跨所有难度的最佳用时（秒） |
| `stars` | int | 是 | `0` | 跨所有难度的最高星级 0–3 |
| `hasSnapshot` | bool | 是 | `false` | 是否有活跃快照（进行中标记） |
| `activeDifficultyKey` | String | 是 | `""` | 当前活跃存档的难度键（如 `"4x6"`） |
| `snapshotKeys` | List\<String\> | 是 | `[]` | 有快照的难度键列表 |
| `records` | Map\<String, Map\> | 否 | 省略 | 嵌套档位记录，key 为难度键 |
| `lastSavedAt` | String(ISO) | 否 | 省略 | 最后保存时间（任意 save 均刷新） |
| `firstPlayedAt` | String(ISO) | 否 | 省略 | 首次游玩时间（首次 save 时写入，不可恢复） |
| `firstCompletedAt` | String(ISO) | 否 | 省略 | 首次通关时间（任意难度） |
| `lastCompletedAt` | String(ISO) | 否 | 省略 | 最近通关时间（任意难度） |

**嵌套 records 值结构（`DifficultyRecord`）**：

| 字段名 | 类型 | 必填 | 默认值 | 说明 |
| :--- | :--- | :-- | :--- | :--- |
| `bestStars` | int | 是 | `0` | 该难度最高星级 0–3 |
| `bestTimeSeconds` | int | 是 | `0` | 该难度最佳用时 |
| `isCompleted` | bool | 是 | `false` | 该难度是否通关 |
| `playCount` | int | 是 | `0` | 该难度游玩次数 |
| `minHintsUsed` | int | 是 | `-1` | 该难度历史最少提示次数（-1 = 从未使用） |
| `firstCompletedAt` | String(ISO) | 否 | 省略 | 该难度首次通关时间 |
| `lastCompletedAt` | String(ISO) | 否 | 省略 | 该难度最近通关时间 |
| `firstPlayedAt` | String(ISO) | 否 | 省略 | 该难度首次游玩时间 |
| `lastPlayedAt` | String(ISO) | 否 | 省略 | 该难度最近游玩时间 |
| `minMoves` | int | 否 | 省略/-1 | 该难度历史最少有效步数（-1 = 未记录） |

> **extra 通道保留**：toJson 输出的 Map 中，`extra` 里的未知键会自动合并到顶层（现有行为），Hive 存 Map 时原样保留。fromJson 时已知键进 known 集合，未知键进 extra。**迁移到 Hive 后 extra 机制不变**。

**Dart 侧 getter（不持久化，从已知字段计算）**：

| getter | 返回类型 | 计算方式 |
| :--- | :--- | :--- |
| `lastPlayedAt` | DateTime? | 语义别名 = `lastSavedAt` |
| `maxStars` | int | `max(stars, records.values.map(bestStars).max)` |
| `hasAny3Star` | bool | `maxStars >= 3 \|\| records.values.any(bestStars >= 3)` |
| `totalPlayCount` | int | `records.values.fold(0, (s, r) => s + r.playCount)` |
| `completedDifficultyCount` | int | `records.values.where(isCompleted).length` |
| `allDifficultyStars` | Map\<String, int\> | `records.map((k, v) => k → v.bestStars)` |
| `bestDifficultyKey` | String | `records.entries.maxBy(bestStars).key` |
| `canResume` | bool | `hasSnapshot && !isCompleted` |

### 4.2 `custom-puzzles-v1` — 自制拼图元数据

**Box key**：customId（如 `sample_01`、`1787548651000`）
**Value**：`Map<String, dynamic>`

> **设计变更**：原 `CustomPuzzleItem` 含进度字段（isCompleted、progressPercent、bestTimeSeconds、completedPieceCounts、savedSnapshotJson），这些与 ProgressStore 重复。迁移后此 box **只存元数据**，进度数据统一从 `progress-v1` box 按 `ugc:{customId}` 读取。

| 字段名 | 类型 | 必填 | 默认值 | 说明 |
| :--- | :--- | :-- | :--- | :--- |
| `id` | String | 是 | — | 自制拼图 ID（与 box key 一致） |
| `title` | String | 是 | — | 用户给拼图起的标题 |
| `imagePathOrUrl` | String | 是 | — | 图片路径：asset 路径 / 本地文件路径 / 网络 URL |
| `isLocalFile` | bool | 是 | `false` | 是否本地文件（决定走 FileImage 还是 AssetImage/网络） |
| `rows` | int | 是 | `4` | 难度行数 |
| `cols` | int | 是 | `4` | 难度列数 |
| `createdAt` | String(ISO) | 否 | 省略 | 创建时间 |
| `sourceType` | String | 是 | `"gallery"` | 来源类型：`"gallery"` / `"online"` / `"preset"` |
| `sourcePlatform` | String | 是 | `"本地相册"` | 来源平台显示名 |
| `sourceUrl` | String | 否 | 省略 | 原始图片 URL 或本地源路径 |

**废弃字段（迁移时丢弃，不写入 Hive）**：

| 废弃字段 | 原因 |
| :--- | :--- |
| `isCompleted` | 委托 `progress-v1` 的 `ugc:{id}` 记录 |
| `progressPercent` | 同上 |
| `bestTimeSeconds` | 同上 |
| `completedPieceCounts` | 同上 |
| `savedSnapshotJson` | 快照已由 SnapshotStore 文件级存储管理 |

### 4.3 `favorites-v1` — 收藏列表

**Box key**：canonicalId（如 `main:004`、`daily:20260902`）
**Value**：`Map<String, dynamic>`（`FavoriteEntry.toJson()` 的输出）

| 字段名 | 类型 | 必填 | 默认值 | 说明 |
| :--- | :--- | :-- | :--- | :--- |
| `canonicalId` | String | 是 | — | 全局规范主键（与 box key 一致） |
| `favoritedAt` | String(ISO) | 是 | — | 收藏时间（收藏子 Tab 排序主键） |
| `titleSnapshot` | String | 否 | 省略 | 标题快照（源删除后兜底显示） |
| `imageSnapshot` | String | 否 | 省略 | 缩略图路径/URL 快照 |
| `sourceLabelSnapshot` | String | 是 | `"主线"` | 来源标签快照：主线/每日/活动/扩展包/自制 |
| `isLocalFileSnapshot` | bool | 是 | `false` | 图片路由快照（决定 FileImage 还是 AssetImage/网络） |
| `aspectRatioLabel` | String | 是 | `"square1x1"` | 宽高比标签快照（孤儿卡布局防错位） |
| `author` | String | 否 | 省略 | 创作者/出处署名 |
| `tags` | List\<String\> | 否 | `[]` | 标签列表（预留筛选） |
| `preferredDifficultyKey` | String | 否 | 省略 | 收藏时选中的偏好难度键 |
| `sortOrder` | int | 是 | `0` | 用户自定义排序权重（预留拖拽置顶） |

> **extra 通道保留**：同 progress-v1，未知键透传。

### 4.4 `achievements-v1` — 成就系统

**Box key**：`{type}:{id}` 前缀区分四种数据
**Value**：int / String / bool（按类型不同）

| key 模式 | value 类型 | 说明 | 示例 |
| :--- | :--- | :--- | :--- |
| `counter:{metric}` | int | 成就计数器（累加值） | `counter:play_seconds` → `160` |
| `counter:total_solved` | int | 累计通关数 | → `1` |
| `counter:total_snaps` | int | 累计拼正确碎片数 | → `24` |
| `counter:no_hint_win` | int | 无提示通关次数 | → `1` |
| `unlock:{achievementId}` | String(ISO) | 成就解锁时间 | `unlock:first_win` → `"2026-09-02T16:27:37"` |
| `claimed:{achievementId}` | bool(true) | 奖励是否已领取（存在即 true） | `claimed:first_win` → `true` |
| `starred:{canonicalId}` | bool(true) | 已计 3 星的图（去重集合，存在即 true） | `starred:main:002` → `true` |

> **设计优势**：原 AchievementStore 用 4 个 SharedPreferences key 存 4 种不同结构的数据，每次更新一种都要序列化/反序列化整个 Map。拆为逐条 key 后，`incrementCounter` 只写一个 int，`markUnlocked` 只写一个 string，互不干扰。

### 4.5 `economy-v1` — 经济系统

**Box key**：camelCase 语义名
**Value**：int / bool / String

| key | value 类型 | 默认值 | 说明 |
| :--- | :--- | :--- | :--- |
| `coins` | int | `100` | 金币余额（新手赠送 100） |
| `hintCoupons` | int | `5` | 免费提示券数量（新手赠送 5） |
| `dailyEarned` | int | `0` | 今日已获得金币数 |
| `dailyDate` | String | `""` | 今日日期 `YYYY-MM-DD`（用于 dailyEarned 重置判断） |
| `starterGranted` | bool | `false` | 新手赠送是否已发放（一次性） |

> 数据量极小（5 个 KV），但属于业务数据，迁入 Hive 统一管理。内存缓存模式可保留（AchievementStore 已有的纯内存缓存 + 异步落盘模式）。

### 4.6 `stats-v1` — 全局统计

**Box key**：camelCase 语义名
**Value**：int

| key | value 类型 | 默认值 | 说明 | 来源 |
| :--- | :--- | :--- | :--- | :--- |
| `totalPiecesSnapped` | int | `0` | 累计拼正确碎片数 | 原 `jigsaw_stat_total_pieces_snapped` |
| `totalPlayTimeSeconds` | int | `0` | 累计游玩总时长（秒） | 原 `jigsaw_stat_total_play_time` |
| `cachedTotalSolved` | int | `0` | 缓存：已通关不同图数 | ProgressStore.refreshAggregatesCache 计算 |
| `cachedTotalStars` | int | `0` | 缓存：所有难度 bestStars 求和 | 同上 |
| `cachedDistinct3Star` | int | `0` | 缓存：获得 3 星的不同图数 | 同上 |
| `cachedTotalPlayCount` | int | `0` | 缓存：跨所有图×难度的总游玩次数 | 同上 |

> **设计变更**：原 `jigsaw_stat_total_completed` 已废弃（代码标记 @Deprecated），迁移时不保留。新增 4 个缓存字段替代 ProgressStore 的内存缓存——Hive 读写是同步的，缓存可直接读 Hive，不需要额外内存层。`refreshAggregatesCache` 改为遍历 `progress-v1` box 的 `box.values` 后写入这 4 个缓存 key。

### 4.7 `level-unlocks-v1` — 主线解锁状态

**Box key**：canonicalId（如 `main:001`）
**Value**：bool(true)（存在即解锁）

> **设计变更**：原 `jigsaw_level_{n}` 存储 16 个字段（含进度、快照、标签等），其中大部分与 ProgressStore 重复或属于静态配置。迁移后此 box **只存解锁状态**（一个 bool），其余数据来源如下：

| 原字段 | 迁移后数据来源 |
| :--- | :--- |
| `isUnlocked` | **本 box**（`level-unlocks-v1`） |
| `isCompleted` | `progress-v1` 的 `main:{N}` 记录 |
| `progressPercent` | 同上 |
| `stars` | 同上 |
| `bestTimeSeconds` | 同上 |
| `completedPieceCounts` | 同上 |
| `savedSnapshotJson` | 废弃（SnapshotStore 管理） |
| `title` / `assetPath` / `rows` / `cols` / `difficulty` / `tags` / `addedAt` / `unlockCoins` / `unlockCode` | 代码配置（`_initLevels()` 生成，不持久化） |

> 默认解锁第 1 关。迁移时从旧 `jigsaw_level_{n}` 的 `isUnlocked` 字段提取解锁状态写入此 box。

---

## 五、版本化与迁移策略

### 5.1 何时开新 box 版本

| 场景 | 操作 | 示例 |
| :--- | :--- | :--- |
| 新增可选字段 | 直接加到现有 box | `progress-v1` 新增 `lastSessionElapsedSeconds`，旧记录缺失→默认 0 |
| 删除字段 | 开 `-v2`，迁移时丢弃 | `custom-puzzles-v2` 不再含 `savedSnapshotJson` |
| 改字段类型 | 开 `-v2`，迁移时转换 | `progress-v2` 的 `progressPercent` 从 int 改 double |
| 改字段语义 | 开 `-v2`，迁移时重映射 | `favorites-v2` 的 `sortOrder` 语义变更 |

### 5.2 box 版本迁移流程（以 `progress-v1` → `progress-v2` 为例）

```
1. 打开 v2 box（若不存在则自动创建空 box）
2. 检查 v2 box 是否已有数据（box.isNotEmpty）
3. 若 v2 为空且 v1 存在：
   a. 遍历 v1 box：for (final key in v1Box.keys)
   b. 读取 v1 值：final v1Map = v1Box.get(key)
   c. 转换为 v2 schema：final v2Map = transformV1toV2(v1Map)
   d. 写入 v2：await v2Box.put(key, v2Map)
   e. 写迁移完成标志：await metaBox.put('progress-v2-migrated', true)
4. 后续读写全部走 v2
5. 可选：await v1Box.deleteFromDisk()（确认 v2 稳定后清理）
```

### 5.3 初始迁移（SharedPreferences → Hive）

```
1. 检查 SharedPreferences 的 hive.migrated 标志
2. 若未迁移：
   a. 打开所有 Hive boxes
   b. 迁移 progress：遍历 prefs keys 匹配 jigsaw_progress_v3_ 前缀
      → 逐条 jsonDecode → put 到 progress-v1
   c. 迁移 custom-puzzles：jsonDecode jigsaw_custom_list 数组
      → 逐条提取元数据字段 → put 到 custom-puzzles-v1（丢弃进度字段）
   d. 迁移 favorites：jsonDecode jigsaw_favorites_v1 数组
      → 逐条 put 到 favorites-v1
   e. 迁移 achievements：jsonDecode 4 个 key
      → 拆为逐条 counter:/unlock:/claimed:/starred: key → put 到 achievements-v1
   f. 迁移 economy：读 5 个 prefs key → put 到 economy-v1
   g. 迁移 stats：读 2 个 prefs key + 计算 4 个缓存值 → put 到 stats-v1
   h. 迁移 level-unlocks：遍历 jigsaw_level_{n} 提取 isUnlocked → put 到 level-unlocks-v1
   i. 设置 SharedPreferences 的 hive.migrated = true
3. 迁移完成后旧 SharedPreferences key 可保留不删（用户回退旧版本时仍可用）
   也可在确认稳定后通过 MigrationService 清理
```

---

## 六、API 映射表

### 6.1 存储操作映射

| 当前 API（SharedPreferences） | 迁移后 API（Hive） | 变化 |
| :--- | :--- | :--- |
| `prefs.setString('jigsaw_progress_v3_{cid}', jsonEncode(json))` | `progressBox.put(cid, json)` | 去掉 jsonEncode，直接存 Map |
| `prefs.getString('jigsaw_progress_v3_{cid}')` → jsonDecode | `progressBox.get(cid)` | 去掉 jsonDecode，直接拿 Map |
| `prefs.remove('jigsaw_progress_v3_{cid}')` | `progressBox.delete(cid)` | 语义对应 |
| `prefs.getKeys().where(startsWith(prefix))` | `progressBox.keys` | 从全量过滤变成原生迭代 |
| `prefs.setString('jigsaw_custom_list', jsonEncode(array))` | `customBox.put(id, itemMap)` | 从单 key 全量写变成逐条写 |
| `prefs.setString('jigsaw_favorites_v1', jsonEncode(array))` | `favBox.put(cid, entryMap)` | 同上 |
| `prefs.setString('jigsaw_achievement_counters', jsonEncode(map))` | `achBox.put('counter:$metric', value)` | 从整体序列化变成逐条写 |
| `prefs.setInt('jigsaw_economy_coins', value)` | `econBox.put('coins', value)` | 语义对应 |
| `prefs.setBool('jigsaw_setting_sound', value)` | **保留 SharedPreferences** | 设置数据不迁移 |

### 6.2 聚合缓存映射

| 当前模式 | 迁移后模式 | 变化 |
| :--- | :--- | :--- |
| `refreshAggregatesCache()` 遍历 prefs keys 做 N+1 jsonDecode | 遍历 `progressBox.values`（Hive lazy read） | 消除 jsonDecode，Hive value 直接是 Map |
| `_cachedDistinct3Star` 内存变量 | `statsBox.get('cachedDistinct3Star')` | 缓存落盘，重启不丢 |
| `_cachedTotalSolved` 内存变量 | `statsBox.get('cachedTotalSolved')` | 同上 |
| `_cachedTotalStars` 内存变量 | `statsBox.get('cachedTotalStars')` | 同上 |
| 无（`getTotalPlayCount` 每次全量加载） | `statsBox.get('cachedTotalPlayCount')` | 新增缓存，消除全量加载 |

### 6.3 初始化映射

| 当前 | 迁移后 |
| :--- | :--- |
| `SharedPreferences.getInstance()` | `Hive.initFlutter()` + `await Hive.openBox('progress-v1')` 等 |
| `ProgressStore.instance.init()` → `refreshAggregatesCache()` | `HiveStore.instance.init()` → 打开所有 box → 刷新缓存到 `stats-v1` |
| `FavoriteStore.instance.init()` → `_loadFromDisk()` | `favBox = Hive.box('favorites-v1')` → 内存缓存从 `favBox.toMap()` 构建 |
| `AchievementStore.instance.init()` → 4 个 jsonDecode | `achBox = Hive.box('achievements-v1')` → 内存缓存从 `achBox` 逐条构建 |

---

## 七、Box 初始化清单

```dart
// main() 中初始化
await Hive.initFlutter();

// 打开所有 box（Hive 会自动创建不存在的 box）
final boxes = await Future.wait([
  Hive.openBox('progress-v1'),
  Hive.openBox('custom-puzzles-v1'),
  Hive.openBox('favorites-v1'),
  Hive.openBox('achievements-v1'),
  Hive.openBox('economy-v1'),
  Hive.openBox('stats-v1'),
  Hive.openBox('level-unlocks-v1'),
]);
```

> Hive box 打开后驻留内存，读写同步无 async。不需要每次操作 `await`——除了首次 `openBox`。

---

## 八、现有类改造清单

### 8.1 `ProgressStore`（progress_store.dart）

| 改造项 | 说明 |
| :--- | :--- |
| `SharedPreferences? _prefs` → `Box? _box` | 依赖从 SharedPreferences 换成 Hive box |
| `_keyFor(cid)` 方法删除 | box key 就是 canonicalId，不需要前缀转换 |
| `save()` 中 `jsonEncode` → 直接 `box.put(cid, p.toJson())` | 去掉序列化 |
| `load()` 中 `jsonDecode` → 直接 `box.get(cid)` | 去掉反序列化 |
| `listAllCanonicalIds()` → `box.keys.toList()` | 原生迭代，不读文件内容 |
| `loadAllProgress()` → `box.toMap()` | 原生方法 |
| `refreshAggregatesCache()` → 遍历 `box.values` | 消除 N+1 jsonDecode，Hive value 直接是 Map |
| `_cachedXxx` 内存变量 → `statsBox.get/set` | 缓存落盘 |
| `getTotalPlayCount()` → 读 `statsBox.get('cachedTotalPlayCount')` | 消除全量加载 |

### 8.2 `GameRepository`（game_repository.dart）

| 改造项 | 说明 |
| :--- | :--- |
| `_keyCustomList` → `customBox` | 自制列表从单 key 数组改为 box 逐条 |
| `_saveCustomPuzzles()` → 逐条 `customBox.put(id, metadataMap)` | 消除全量读写 |
| `_initCustomPuzzles()` → `customBox.toMap()` | 启动加载从 box 读取 |
| `_keyLevelPrefix` → `unlockBox` | 关卡状态从逐条 prefs key 改为 box |
| `jigsaw_level_{n}` 写入逻辑 → 只写 `unlockBox.put(canonicalId, true)` | 只存解锁状态 |
| 关卡配置（title/assetPath/rows/cols/tags/addedAt 等） → 代码生成，不持久化 | 消除静态配置冗余存储 |
| `updateLevelProgress()` → 委托 ProgressStore | 进度字段不再写 LevelItem |
| 统计 key `_keyTotalCompleted`（@Deprecated）→ 删除 | 废弃字段 |
| 统计 key `_keyTotalPiecesSnapped` → `statsBox.put('totalPiecesSnapped', v)` | 迁移到 Hive |
| 统计 key `_keyTotalPlayTimeSeconds` → `statsBox.put('totalPlayTimeSeconds', v)` | 迁移到 Hive |

### 8.3 `FavoriteStore`（favorite_store.dart）

| 改造项 | 说明 |
| :--- | :--- |
| `SharedPreferences? _prefs` → `Box? _box` | 依赖切换 |
| `_saveToDisk()` → 逐条 `favBox.put(cid, entry.toJson())` | 消除全量读写 |
| `_loadFromDisk()` → `favBox.toMap()` | 启动加载从 box 读取 |
| `_storageKey` 常量删除 | box 名 `favorites-v1` 在 HiveStore 统一管理 |

### 8.4 `AchievementStore`（achievement_store.dart）

| 改造项 | 说明 |
| :--- | :--- |
| `SharedPreferences? _prefs` → `Box? _box` | 依赖切换 |
| `_flushCounters()` → 逐条 `achBox.put('counter:$k', v)` | 从整体序列化改为逐条写 |
| `_flushUnlocked()` → 逐条 `achBox.put('unlock:$k', v)` | 同上 |
| `_flushClaimed()` → 逐条 `achBox.put('claimed:$k', true)` | 同上 |
| `_flushStarred()` → 逐条 `achBox.put('starred:$cid', true)` | 同上 |
| `init()` 中 4 个 jsonDecode → `achBox` 逐条读取 | 消除反序列化 |

### 8.5 `EconomyService`（economy_service.dart）

| 改造项 | 说明 |
| :--- | :--- |
| `SharedPreferences? _prefs` → `Box? _box` | 依赖切换 |
| `coins` getter → `econBox.get('coins') ?? 100` | 同步读 |
| `addCoins()` → `econBox.put('coins', newTotal)` | 同步写 |
| `_keyStarterGranted` → `econBox.get('starterGranted')` | 同上 |
| 5 个 `_keyXxx` 常量删除 | key 名在 HiveStore 统一管理 |

---

## 九、废弃字段清理清单

| 废弃字段/key | 来源 | 废弃原因 | 迁移处理 |
| :--- | :--- | :--- | :--- |
| `savedSnapshotJson` | LevelItem / CustomPuzzleItem | 快照已由 SnapshotStore 文件级管理 | 迁移时不写入 Hive |
| `jigsaw_stat_total_completed` | GameRepository | 已标记 @Deprecated，由 ProgressStore.getTotalSolved() 替代 | 迁移时不保留 |
| `jigsaw_snapshots_v3_migrated` | SharedPreferences | 旧迁移已完成 | 迁移后删除 |
| `jigsaw_difficulty_v3_3_migrated` | SharedPreferences | 旧迁移已完成 | 迁移后删除 |
| `LevelItem.isCompleted` | LevelItem | 与 ProgressStore 重复，SSOT 应为 ProgressStore | 委托 ProgressStore |
| `LevelItem.progressPercent` | LevelItem | 同上 | 委托 ProgressStore |
| `LevelItem.stars` | LevelItem | 同上 | 委托 ProgressStore |
| `LevelItem.bestTimeSeconds` | LevelItem | 同上 | 委托 ProgressStore |
| `LevelItem.completedPieceCounts` | LevelItem | 同上 | 委托 ProgressStore |
| `CustomPuzzleItem.isCompleted` | CustomPuzzleItem | 同上 | 委托 ProgressStore |
| `CustomPuzzleItem.progressPercent` | CustomPuzzleItem | 同上 | 委托 ProgressStore |
| `CustomPuzzleItem.bestTimeSeconds` | CustomPuzzleItem | 同上 | 委托 ProgressStore |
| `CustomPuzzleItem.completedPieceCounts` | CustomPuzzleItem | 同上 | 委托 ProgressStore |
| `CustomPuzzleItem.savedSnapshotJson` | CustomPuzzleItem | 同上 | 废弃 |

---

## 十、依赖变更

### pubspec.yaml 新增

```yaml
dependencies:
  hive_ce: ^2.19.3
  hive_ce_flutter: ^2.24.0  # 提供 Hive.initFlutter()

dev_dependencies:
  # 仅当后续需要 Type Adapter 代码生成时添加
  # 当前方案使用 raw Map 存储，不需要 build_runner
  # hive_ce_generator: ^2.0.0
```

> `hive_ce_flutter` 仅依赖 `path_provider`（项目已有）和 `hive_ce`，不引入任何新原生依赖。

---

## 十一、存储用量预估

| Box | 记录数（重度用户） | 单条大小 | 总量 |
| :--- | :--- | :--- | :--- |
| `progress-v1` | ~2000 | ~450 B | ~900 KB |
| `custom-puzzles-v1` | ~200 | ~200 B | ~40 KB |
| `favorites-v1` | ~500 | ~230 B | ~115 KB |
| `achievements-v1` | ~100 | ~50 B | ~5 KB |
| `economy-v1` | 5 | ~10 B | ~50 B |
| `stats-v1` | 6 | ~10 B | ~60 B |
| `level-unlocks-v1` | ~100 | ~1 B | ~100 B |
| **合计** | | | **~1.06 MB** |

> 对比：SharedPreferences 单文件方案在同等数据量下约 1.2MB+，且每次写入全量 IO。Hive 每个 box 独立文件，写入只碰一个 box 文件。

---

## 十二、实施前置条件与风险

| 项 | 说明 |
| :--- | :--- |
| 未发布 | 当前 App 未发布，无线上用户数据迁移风险，可一步到位 |
| 迁移测试 | 需验证：SharedPreferences 有数据时迁移正确；无数据时正常初始化 |
| 快照不迁移 | SnapshotStore 文件级存储保持不变，Hive 只管进度索引 |
| extra 通道兼容 | Hive 存 raw Map，extra 透传机制天然保留 |
| 回退方案 | 迁移后旧 SharedPreferences key 保留不删，回退旧版本仍可读 |
| 无 Type Adapter | 初始方案用 raw Map 存储，零代码生成；后续需要强类型时可加 |
