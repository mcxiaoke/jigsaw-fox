# Hive 存储改造设计文档（v4.7）

> 日期：2026-09-02
> 版本：**v4.7（无迁移，直接改造 + 文件级备份/恢复；拍板 3 项落地细节）**
> 状态：**已就绪，可对照实施**

## 一、目标

1. 将所有业务数据从 SharedPreferences 改为存 Hive
2. SharedPreferences 仅保留真正的用户设置与 UI 状态（与游戏进度无关）
3. 统一 key 命名规范，box 名带版本后缀 `-v1`
4. 消除数据冗余：主线「`jigsaw_level_N`（水合 SSOT）+ `jigsaw_progress_v3_main_*`（聚合索引）」双路副本收敛为一个 SSOT（每日无独立副本，本就单路走 ProgressStore）
5. 消除 SharedPreferences 的结构性缺陷：单 key 大数组全量读写、N+1 读取、单文件全量 IO

**非目标**：不追求写入吞吐。本项目写入量级是「每次通关写 1–2 条」，选型理由是消除全量 IO 与获得同步读 API。

**边界**：无存量用户数据 → 无迁移逻辑、无双写、无兼容回退。

> **前提声明（v4.2）**：上述边界成立的依据是**游戏未发布、无任何存量用户**。现存 `MigrationService`（`migration_service.dart`，`game_repository.dart:104` 调用）只服务历史开发期的本地数据（`jigsaw_snapshots_v3_migrated` / `jigsaw_difficulty_v3_3_migrated` 两个标志，`migration_service.dart:19-20`），Phase 1 移除其调用、Phase 3 删除文件是安全的；两个迁移标志 key 随 §十三「SP 残留 key」一并保留不清理。若未来在**发布后**才实施本改造，必须先确认所有用户两标志均为 true 再移除，否则未迁移用户的老快照数据会丢失。

***

## 二、存储边界划分

### 2.1 保留在 SharedPreferences（不改 key 名）

| key                                  | 类型         | 默认值                    | 说明                                                                             |
| :----------------------------------- | :--------- | :--------------------- | :----------------------------------------------------------------------------- |
| `jigsaw_setting_sound`               | bool       | true                   | 音效开关                                                                           |
| `jigsaw_setting_haptic`              | bool       | true                   | 震动反馈开关                                                                         |
| `jigsaw_setting_grid_preview`        | bool       | true                   | 网格预览开关                                                                         |
| `jigsaw_setting_piece_scatter_mode`  | String     | `"tray"`               | 碎片排布：`"tray"` / `"tabletop"`                                                   |
| `jigsaw_setting_selected_background` | String     | `kBackgroundAssets[0]` | 选中背景图 asset 路径                                                                 |
| `skip_l2_gap_warning`                | bool       | false                  | L2 断层提示「不再显示」（`choose_difficulty_sheet.dart:288` 的 getBool；287 行为 getInstance） |
| `jigsaw_daily_fold_v1`               | StringList | 当月                     | 每日 Tab 展开的月份（纯 UI 状态，`tabs/daily_tab_view.dart:31`）                                 |

> 稳定采用 v2/v3 结论：以上 key **一律保留原名**，避免静默重置用户设置。

### 2.2 迁入 Hive

| 数据域      | 现 SharedPreferences key                                                                                     | 目标 box / key                                 | 值类型                 |
| :------- | :---------------------------------------------------------------------------------------------------------- | :------------------------------------------- | :------------------ |
| 主线关卡数据  | **`jigsaw_level_{i}`（完整 LevelItem JSON，`game_repository.dart:37`；`_initLevels():149-160` 读取水合、`updateLevelProgress():356`/解锁`:454` 写入）——主线进度的真实 SSOT** | `game-progress-v1` / `main:{NNN}`             | JSON String         |
| 进度索引（聚合/续玩） | `jigsaw_progress_v3_{safe}`（ProgressStore：聚合统计、续玩判断；`_initLevels()` **不读它**）                              | `game-progress-v1` / `{canonicalId}`（与上行收敛为同一份） | JSON String         |
| 每日挑战进度   | （**无独立 key**。现状经 `ProgressStore.getLevelProgress(daily:YYYYMMDD)` 即 `jigsaw_progress_v3_daily_*` 持久化，UI 水合已存在 `tabs/daily_tab_view.dart:170-178`——随 progress 域迁移**自动完成**，无需新增写入点） | `game-progress-v1` / `daily:{YYYYMMDD}`      | JSON String         |
| 自制拼图元数据  | `jigsaw_custom_list`                                                                                        | `game-collections-v1` / `custom:{id}`        | JSON String         |
| 收藏       | `jigsaw_favorites_v1`                                                                                       | `game-collections-v1` / `favorite:{cid}`     | JSON String         |
| 下载素材索引   | `cached_downloaded_images_v1`                                                                               | `game-collections-v1` / `material:{id}`      | JSON String         |
| 成就计数器    | `jigsaw_achievement_counters`（JSON Map）                                                                     | `app-state-v1` / `ach:counter:{metric}`      | **int**             |
| 成就解锁     | `jigsaw_achievement_unlocked`（JSON Map）                                                                     | `app-state-v1` / `ach:unlock:{id}`           | **String(ISO)**     |
| 成就已领     | `jigsaw_achievement_claimed`（**StringList**）                                                                | `app-state-v1` / `ach:claimed:{id}`          | **bool**            |
| 三星去重集    | `jigsaw_achievement_starred_puzzles`（**StringList**）                                                        | `app-state-v1` / `ach:starred:{cid}`         | **bool**            |
| 经济       | `jigsaw_economy_*`（5 个）                                                                                     | `app-state-v1` / `econ:*`                    | **int/String/bool** |
| 全局统计     | `jigsaw_stat_total_pieces_snapped`、`jigsaw_stat_total_play_time`                                            | `app-state-v1` / `stat:*`                    | **int**             |
| 自定义样例初始化 | （新增）                                                                                                        | `app-state-v1` / `custom:presetsInitialized` | **bool**            |

> **主线双路收敛（v4.5 关键澄清）**：现状主线是「`jigsaw_level_{i}` 整条 LevelItem JSON（水合 SSOT）+ `jigsaw_progress_v3_main_*`（ProgressStore 索引）」双写。改造后**两条路径合并为一**：`game-progress-v1` 的 `main:{NNN}` 同时承担水合与聚合（§3.3 内存索引），`jigsaw_level_{i}` 整条读写路径**删除**（§7.3 step3），不是保留并行。

### 2.3 废弃不入 Hive

| 项                                                                                                      | 处理                                                                                 |
| :----------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------- |
| **`jigsaw_level_{i}`（主线整条读写路径）**                                                                      | **删除**（v4.5 P0）：`_initLevels()` 的 prefs 读取分支与 `updateLevelProgress` 的两处 setString 全部移除，委托 §2.2 首行 |
| `jigsaw_stat_total_completed`                                                                          | 已 `@Deprecated`，由 `getTotalSolved()` 替代，**丢弃**                                        |
| `savedSnapshotJson`（LevelItem / CustomPuzzleItem）                                                       | 快照已由 SnapshotStore 文件级管理，**丢弃**                                                    |
| `LevelItem` 的 progressPercent / stars / bestTimeSeconds / completedPieceCounts / isCompleted           | 委托 `game-progress-v1`                                                              |
| `CustomPuzzleItem` 的 4 个进度字段                                                                           | 委托 `game-progress-v1` 的 `ugc:{id}`                                                 |
| LevelItem 的 title / assetPath / rows / cols / difficulty / tags / addedAt / unlockCoins / unlockCode   | 代码配置（`_initLevels()` 生成），不持久化                                                      |
| `jigsaw_achievement_*` 等领域 key 完成改造后                                                                   | 原 key 直接不再读写，无清理需求（无存量数据）                                                          |
| **LevelItem 的 isUnlocked（主线解锁）**                                                                       | **暂不建立** `unlock:*`。Phase0 全量可玩，恒为 true（见 §4.5），不持久化                               |

> **每日挑战现状澄清（v4.5，替代 v4.1 虚构）**：代码中**不存在** `jigsaw_daily_{date}` 持久化 key、`DailyChallengeItem` 类与 `_initDailyChallenges()` 方法（v4.1–v4.4 的相关行均为虚构）。每日内容由 `daily_content_pipeline.dart` 下载解压、UI 侧构建；进度经 `CanonicalId.forDaily` → ProgressStore 持久化，水合点在 `tabs/daily_tab_view.dart:170-178`（已存在，无需新建）。本改造中每日进度**随 Phase 1 progress 域迁移自动完成**，不设独立迁移项；未来若需新增每日写入点，走 `ProgressStore.updateProgress(canonicalId: CanonicalId.forDaily(date))`。

### 2.4 文件存储（保持现状，不走 Hive）

| 存储   | 路径                                  |
| :--- | :---------------------------------- |
| 快照文件 | `{appSupport}/snapshots/*.snapshot` |
| 主线缓存 | `{appSupport}/main_levels_cache.json`（v4.6 更正：`content_manager.dart:26` 用 appSupportDir，原文档误写 {appDoc}） |
| 活动缓存 | `{appSupport}/events_cache.json`（同上，`:35`） |
| 清单缓存 | `{appSupport}/manifest_cache.json`（`:22`；注：levels/daily/events 的**图片目录**在 `{appDoc}` 下，与缓存 JSON 不同） |

***

## 三、存储格式决策

### 3.1 分层决策

Hive（`hive_ce`）原生支持 `int / double / String / bool / List / Uint8List`，**重启不退化**；唯一会退化为 `_Map<dynamic,dynamic>` 的是**未注册 TypeAdapter 时直接存** **`Map<String, dynamic>`**（如外部对象 `toJson()` 产生的嵌套 Map）——写时是原生 Hive 帧，重启后类型信息丢失退化成 `Map<dynamic,dynamic>`，`as Map<String, dynamic>` 抛 CastError。据此分层：

| Box                   | 值类型                              | 理由                                                             |
| :-------------------- | :------------------------------- | :------------------------------------------------------------- |
| `game-progress-v1`    | JSON String（`jsonEncode`）        | 值是 `LevelProgress` 对象，含嵌套 `records` Map；JSON String 免疫退化       |
| `game-collections-v1` | JSON String（`jsonEncode`）        | 值是 `CustomPuzzleItem`/`FavoriteEntry`/`DownloadedImageItem` 对象 |
| `app-state-v1`        | **Hive 原生基本类型（int/bool/String）** | 值是标量，无嵌套 Map，原生类型绝不退化，无需包装                                     |

> **v4 变更（解除过度包装）**：`app-state-v1` **不用** `{"v":...}` 包装。理由：
>
> 1. §3.3 声明 `app-state-v1`「按 key get，无需索引」，本就没有遍历初始化循环，谈不上「循环内避免类型分支」；
> 2. Hive 原生类型不退化，包装是纯负担——每次累计/更新统计都要 `jsonDecode`/`jsonEncode` + GC 开销；
> 3. 与 §2.2 / §4.3 的类型说明（int/bool/String）保持一致。

### 3.2 对象型 box 的统一读写模式（progress / collections）

```dart
Future<void> putJson(Box box, String key, Map<String, dynamic> value) =>
    box.put(key, jsonEncode(value));
Map<String, dynamic>? getJson(Box box, String key) {
  final raw = box.get(key) as String?;
  return raw == null ? null : (jsonDecode(raw) as Map<String, dynamic>);
}
```

**收益**：`jsonDecode` 任何层级都返回 `Map<String, dynamic>`，无 Map 退化崩溃；`progress` 域冷启动一次性解码建索引（§5.1），热路径无解码。

### 3.3 读取侧策略与排序约定

- **`game-progress-v1`**：冷启动一次性 `jsonDecode` 建内存索引（`_index[cid]`），热路径 O(1) 命中。（§5.1）

- **`game-collections-v1`**：由各负责的 Store/Manager 在 `init()` 时**一次性读出对应 key 前缀，维护在自己的内存** **`ValueNotifier`** **缓存中**，日常读走纯内存，写/删直接同步触发 Hive 单 key 操作。不再「每次渲染遍历 box」。

  - `FavoriteStore`：维护 `_entriesCache` + `idsNotifier`（现状即如此）。

  - `DownloadManager`：维护 `itemsNotifier`（现状即如此）。

- **`app-state-v1`**：纯 KV 标量，日常按 key `get`/`put`。**例外（v4.3）**：`AchievementStore` 持有 4 个内存缓存（`_countersCache`/`_unlockedCache`/`_claimedCache`/`_starredCache`，`achievement_store.dart:22-25`），其 `init()` 须**一次性前缀扫描** `stateBox.keys` 中 `ach:*` 条目装满缓存（成就页需全量列表，`isUnlocked`/`isClaimed`/`hasStarred` 为同步方法），见 §4.3。

> **排序约定（v4 新增；v4.6 机理更正）**：`game-collections-v1` 拆为单条后，`box.keys` 按 **KeyComparator 决定的确定性顺序**（int 升序在前、String 字母升序在后，`keystore.dart:32` SkipList + `box_base.dart:57-60`）排列——**字母序 ≠ 业务时序**，同样不得直接按枚举顺序展示。聚合读取后必须显式排序：
>
> - `DownloadedImageItem`：按 `downloadedAt` **降序**
>
> - `FavoriteEntry`：按 `favoritedAt` **降序**（`sortOrder` 作为次优先级权重）
>
> 老代码中 `cached_downloaded_images_v1` / `jigsaw_favorites_v1` 是整 JSON 数组、天然有序，拆条后这个排序步骤不可省略。

> **写侧内存一致性（v4 补充）**：现状 `updateXxxProgress`（`game_repository.dart` 三处）都是「内存 `Item` `copyWith` + prefs 整条 JSON + `ProgressStore`」三写，UI 同步依赖内存 `Item`。改造后\*\*保留「同步更新内存 `Item` + 经 `ProgressStore` 写 box」\*\*的组合：先更新内存对象（UI 立即响应），再 `ProgressStore.save/_index` 更新 + `box.put`；prefs 整条 JSON 写入被 `box.put(cid, jsonEncode(...))` 替换。写侧必须维持内存优先，避免 UI 读内存、持久化走 box 的两套数据漂移。

***

## 四、Box 设计与归属

### 4.1 为什么是 3 个 box

`game-progress-v1` / `game-collections-v1` / `app-state-v1`。economy/stats 等微型域合并进 `app-state-v1`，避免过多独立 box 文件（各含 compaction 临时文件与锁文件）。

### 4.2 Box 归属表（权威依据）

| box                   | 数据域（归入本 box）                                          | key 规范                                                                  | 值类型         |
| :-------------------- | :---------------------------------------------------- | :---------------------------------------------------------------------- | :---------- |
| `game-progress-v1`    | 关卡进度、每日挑战进度（仅进度字段）                                    | `{canonicalId}`：`main:001`、`daily:20260902`、`ugc:xxx`、`pack:nature:001` | JSON String |
| `game-collections-v1` | 自制拼图元数据、收藏、下载素材索引                                     | `custom:{id}`、`favorite:{cid}`、`material:{id}`                          | JSON String |
| `app-state-v1`        | 成就（counter/unlock/claimed/starred）、经济、全局统计、自定义样例初始化标志 | `econ:*`、`ach:*`、`stat:*`、`custom:presetsInitialized`                   | 原生基本类型      |

> **daily-asset 不建（v4.5 修正依据）**：v4.1–v4.4 引用的 `DailyChallengeItem.assetPath` / `kBingDailyAll` 均为虚构（代码中不存在该类与该常量）。每日内容实际由 `daily_content_pipeline.dart` 按月下载解压（`dailyStorageBaseDir/{yyyyMm}/`），不持久化任何 asset 元数据进 Hive，本就无需废弃动作。

> **canonicalId 前缀规范（v4 补充）**：`{canonicalId}` 前缀由来源固定，`ProgressStore` 依据它生成主键：
>
> - `main:{NNN}` — 主线关卡（`GameRepository.canonicalForLevel`，`main:001`）
>
> - `daily:{yyyyMMdd}` — 每日挑战（`canonicalForDaily`，`daily:20260902`）
>
> - `ugc:{id}` — 自制拼图（`canonicalForCustom`，`ugc:xxx`）
>
> - `pack:{packId}:{fileName}` — 素材包（`canonicalForPack`，`pack:nature:001`，本工程内的关卡包/主题包场景）
>
> 其中 `pack:*` 当前主要是内容源预置，归属 `game-progress-v1` 仅当该包条目存在进度记录时才写入（无进度则不建 key）。

### 4.3 `app-state-v1` key 全表（原生类型）

| key                         | 类型          | 默认值   | 来源                                                                                                                                                                |
| :-------------------------- | :---------- | :---- | :---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `econ:coins`                | int         | **0** | `jigsaw_economy_coins`；**注意默认值为 0**，初始 100 由 novice 补发流程（`EconomyService.init` 的 `starterGranted` 分支）写入，**不得**用 `box.get(key, defaultValue: 100)` 硬编码 100，否则与补发冲突 |
| `econ:hintCoupons`          | int         | **0** | `jigsaw_economy_hint_coupons`；同理初始 5 由 starter 流程补发，get 默认 0                                                                                                      |
| `econ:dailyEarned`          | int         | 0     | `jigsaw_economy_daily_earned`                                                                                                                                     |
| `econ:dailyDate`            | String      | `""`  | `jigsaw_economy_daily_date`                                                                                                                                       |
| `econ:starterGranted`       | bool        | false | `jigsaw_economy_starter_granted`                                                                                                                                  |
| `ach:counter:{metric}`      | int         | 0     | `jigsaw_achievement_counters` 拆分；**`metric`** **内不得含冒号/点**（`ach:counter:` 前缀 + metric 整体即 key），与前缀匹配规则（见下注）自洽                                      |
| `ach:unlock:{id}`           | String(ISO) | —     | `jigsaw_achievement_unlocked` 拆分                                                                                                                                  |
| `ach:claimed:{id}`          | bool(＝true) | —     | `jigsaw_achievement_claimed`（原 StringList）；键存在且为 true 表示已领，缺失即未领                                                                                                  |
| `ach:starred:{cid}`         | bool(＝true) | —     | `jigsaw_achievement_starred_puzzles`（原 StringList）；同上                                                                                                             |
| `stat:totalPiecesSnapped`   | int         | 0     | `jigsaw_stat_total_pieces_snapped`                                                                                                                                |
| `stat:totalPlayTimeSeconds` | int         | 0     | `jigsaw_stat_total_play_time`                                                                                                                                     |
| `custom:presetsInitialized` | bool        | false | **新增**，自制样例是否已植入（§4.4）                                                                                                                                            |

> **key 解析规则（v4.3 重写）**：`ach:*` 的 key 含多段冒号（如 `ach:starred:main:002`、`ach:starred:pack:nature:001`）。**禁止任何 `split(':')` 方案**——按第一个冒号 split 首段恒为 `ach`，取不到子类型；按下标取值则被 cid 内嵌冒号击穿。一律用**显式前缀匹配**：`startsWith('ach:counter:')` / `startsWith('ach:unlock:')` / `startsWith('ach:claimed:')` / `startsWith('ach:starred:')`，命中后 `substring(前缀长度)` 取剩余整体作为 id/cid/metric，天然支持含冒号的 cid（`main:002` / `pack:nature:001`）。
>
> `AchievementStore.init()` 启动时按此前缀规则**一次性扫描** `stateBox.keys` 装满 4 个内存缓存（§3.3 例外）：
>
> ```dart
> final box = StorageManager.instance.state;
> for (final key in box.keys.cast<String>()) {
>   if (key.startsWith('ach:counter:')) {
>     final metric = key.substring('ach:counter:'.length);
>     _countersCache[metric] = box.get(key) as int? ?? 0;
>   } else if (key.startsWith('ach:unlock:')) {
>     final id = key.substring('ach:unlock:'.length);
>     final v = box.get(key) as String?;
>     if (v != null) _unlockedCache[id] = v;
>   } else if (key.startsWith('ach:claimed:')) {
>     if (box.get(key) == true) _claimedCache.add(key.substring('ach:claimed:'.length));
>   } else if (key.startsWith('ach:starred:')) {
>     if (box.get(key) == true) _starredCache.add(key.substring('ach:starred:'.length));
>   }
> }
> ```

### 4.4 自制样例初始化标志（解决「全删后死灰复燃」）

现状：首次启动注入 3 个默认样例（`sample_01~03`），靠 `jigsaw_custom_list` 键是否存在判断是否已初始化（用户删光后 Prefs 存 `[]`，重启不重生成）。

改单条 `custom:{id}` 后，空 box 无法区分「首次启动」与「用户删光」。**须加显式标志**：

```
key: custom:presetsInitialized  (bool, 默认 false)
```

- 启动 `_initCustomPuzzles()`：读 `custom:presetsInitialized`

  - `false`/缺失 → 植入 3 个默认样例，置 `true`

  - `true` → 不植入，直接加载已有 `custom:*`

- **失败语义（v4 明确）**：植入采用「**全部成功才置 true，任一失败保持 false**」。即先写 3 个 `custom:*`，三者都成功后最后才置 `custom:presetsInitialized = true`；若中途任一写入失败，标志保持 `false`，本次启动即使只植入部分也回滚重试，下次启动重新植入完整样例，避免「半套样例 + 永久跳过」的脏状态。

- 即使后续 user 删光样例，标志仍为 `true`，不会重新注入。

> **⚠ 跨 box 归属（v4 注明；v4.7 拍板）**：样例内容 `custom:*` 在 `game-collections-v1`，标志 `custom:presetsInitialized` 却在 `app-state-v1`，**同前缀跨 box**。凡对 `custom:` 前缀做扫描/清理的代码都要两处顾及：清样例不应清标志，读标志不要用 collections box。**v4.7 已拍板采用 `custom:presetsInitialized`（与 §4.3 表格及 §4.4/§7.6 全文统一），不再提供 `meta:presetsInitialized` 备选**，实施时无需再抉择。

### 4.5 `unlock:main` 决策

Phase0 全量可玩，`_initLevels()` 硬编码 `isUnlocked: true`。**决策：暂不建立** **`unlock:*`。** 理由：

1. Phase0 恒为 100 个 `true`，落盘纯冗余（每关 \~4B × 100 ≈ 400 B）。
2. 真正引入解锁墙（`unlockCoins`/`unlockCode`）时再新增，代价很小。
3. 一致判定，无二义。

> 若将来启用：`unlock:main:{n}`（bool，原生类型直接 put/get），写入时机由解锁逻辑触发。

***

## 五、字段定义

### 5.1 `game-progress-v1` 值结构（`LevelProgress.toJson()` 输出，原样保留）

| 字段                                                                       | 类型                | 必填 | 默认值   | 说明                   |
| :----------------------------------------------------------------------- | :---------------- | :- | :---- | :------------------- |
| `canonicalId`                                                            | String            | 是  | —     | 全局规范主键（与 box key 一致） |
| `progressPercent`                                                        | int               | 是  | 0     | 0–100                |
| `isCompleted`                                                            | bool              | 是  | false | 粘性，通关后永久 true        |
| `completedPieceCounts`                                                   | List<int>         | 是  | `[]`  | 已完成的碎片数集合            |
| `bestTimeSeconds`                                                        | int               | 是  | 0     | 跨难度最佳用时              |
| `stars`                                                                  | int               | 是  | 0     | 跨难度最高星级 0–3          |
| `hasSnapshot`                                                            | bool              | 是  | false | 有活跃快照（进行中）           |
| `activeDifficultyKey`                                                    | String            | 是  | `""`  | 当前活跃存档难度键            |
| `snapshotKeys`                                                           | List<String>      | 是  | `[]`  | 有快照的难度键列表            |
| `records`                                                                | Map\<String, Map> | 否  | 省略    | 嵌套档位记录               |
| `lastSavedAt` / `firstPlayedAt` / `firstCompletedAt` / `lastCompletedAt` | String(ISO)       | 否  | 省略    | 时间戳                  |

**嵌套** **`DifficultyRecord`**：`bestStars` / `bestTimeSeconds` / `isCompleted` / `playCount` / `minHintsUsed`（均必填），`firstCompletedAt` / `lastCompletedAt` / `firstPlayedAt` / `lastPlayedAt` / `minMoves`（可空省略）。

**Dart 侧 getter（不持久化）**：`lastPlayedAt`（= `lastSavedAt`）、`maxStars`、`hasAny3Star`、`totalPlayCount`、`completedDifficultyCount`、`allDifficultyStars`、`bestDifficultyKey`、`canResume`。

**可空字段约定**：null 时省略该键。`extra` 通道保留（未知键透传，完整往返）。

### 5.2 `custom:{id}` 值结构（只存元数据）

| 字段               | 类型          | 必填 | 默认值         |
| :--------------- | :---------- | :- | :---------- |
| `id`             | String      | 是  | —           |
| `title`          | String      | 是  | —           |
| `imagePathOrUrl` | String      | 是  | —           |
| `isLocalFile`    | bool        | 是  | false       |
| `rows` / `cols`  | int         | 是  | 4 / 4       |
| `sourceType`     | String      | 是  | `"gallery"` |
| `sourcePlatform` | String      | 是  | `"本地相册"`    |
| `createdAt`      | String(ISO) | 否  | 省略          |
| `sourceUrl`      | String      | 否  | 省略          |

**丢弃**：`isCompleted` / `progressPercent` / `bestTimeSeconds` / `completedPieceCounts` / `savedSnapshotJson` → 全部委托 `game-progress-v1` 的 `ugc:{id}`。

> **注意**：`rows`/`cols` 依赖 `PuzzleDifficulty.presets` 反查重建（`custom_puzzle_item.dart:112-119`）。非 presets 组合会 fallback 生成 label，丢失原 label。当前所有自定义难度都来自 presets，可接受，但需知悉。

### 5.3 `favorite:{cid}` 值结构（`FavoriteEntry.toJson()` 输出）

`canonicalId`、`favoritedAt`、`sourceLabelSnapshot`、`isLocalFileSnapshot`、`aspectRatioLabel`、`sortOrder` 为必填；`titleSnapshot`、`imageSnapshot`、`author`、`tags`、`preferredDifficultyKey` 可空省略。

### 5.4 `material:{id}` 值结构

`DownloadedImageItem.toJson()` 原样保留（原 `cached_downloaded_images_v1` 单 key 大数组改逐条），含 `downloadedAt`（用于 §3.3 排序）。

> **失效过滤必须保留（v4 补充）**：现状 `DownloadManager.init()`（`download_manager.dart:47-50`）会过滤 `localPath` 已不存在的项。拆条后 `init()` 读 `material:*` 时**仍需同样的失效过滤**，且对失效项要**同步删除对应 box key**（`box.delete('material:$id')`），否则失效项永久驻留 box。
>
> **遍历删除的安全写法（v4.4；v4.6 论据更正）**：hive_ce 的 `box.keys` 直传底层 keystore 的 SkipList 迭代器（`keystore.dart:118-120`）。该迭代器是裸链表遍历、**无 ConcurrentModificationError 防护**（`indexable_skip_list.dart:244-245`），迭代中 delete 的行为属**依赖实现细节的未定义行为**（当前实现恰好不抛不漏，但升级即可能改变）。作为不依赖实现细节的纪律，一律「先收集、后批量删」：
>
> ```dart
> final staleKeys = <String>[];
> for (final key in collectionsBox.keys.cast<String>()) {
>   if (!key.startsWith('material:')) continue;
>   final item = /* decode box.get(key) */;
>   if (!File(item.localPath).existsSync()) staleKeys.add(key);
> }
> for (final key in staleKeys) {
>   await collectionsBox.delete(key);
> }
> ```
> 本约定适用于**所有**「扫描 box.keys + 条件删除」的场景（含 §4.3 的 `ach:*` 扫描——只读不删，不受影响；一旦未来需要删除同守此约）。

***

## 六、命名规范

### 6.1 Box 命名

`{domain}-v{N}`，全小写，连字符分隔，版本后缀从 `-v1` 起。

### 6.2 Box 内 key 命名

| 场景      | 规则                                                | 示例                                        |
| :------ | :------------------------------------------------- | :---------------------------------------- |
| 单域 box  | 自然 ID，不带版本                                          | `main:001`、`daily:20260902`               |
| 混合域 box | `{type}:{id}`，**解析用显式前缀匹配，禁止 split**（见 §4.3 注）        | `custom:sample_01`、`ach:starred:main:002` |
| 单值      | camelCase 语义名                                       | `econ:coins`、`stat:totalPiecesSnapped`    |

### 6.3 值字段命名

camelCase；box 名已提供上下文，字段名不加域前缀；DateTime 存 ISO 8601 字符串；可空字段 null 时省略；嵌套对象存 `Map<String, dynamic>`。

### 6.4 版本升级规则

| 变更类型                   | 是否开新 box          |
| :--------------------- | :---------------- |
| 新增可选字段（有默认值）           | **否**，缺省取默认值      |
| 删除 / 改类型 / 改语义 / 重命名字段 | **是**，开 `-v2` 并重写 |

***

## 七、生命周期与启动流程

### 7.1 Box 由统一 StorageManager 打开

**单一打开点**，禁止各 Store 自由调用 `open/delete`，避免启动并发竞争与「一方捕获异常 deleteBox、另一方正在 open」的灾难场景。

```dart
// lib/data/storage_manager.dart —— 持有并注入 3 个 box
class StorageManager {
  // v4.3：非 final，测试可 setMockInstance 替换
  static StorageManager instance = StorageManager._();

  @visibleForTesting
  static void setMockInstance(StorageManager mock) => instance = mock;

  Box<dynamic>? progressBox, collectionsBox, stateBox;
  String? _homePathOverride; // v4.5 转正：测试实例判定依据（forTest 注入；生产恒 null）
  // v4.2：hive_ce 2.19.3 的 HiveInterface 没有 Hive.isInitialized，
  // 编译期就不存在该 API，改为自持标志
  bool _hiveReady = false;
  // v4.5：本次 openAll 期间被兜底重建过的 box 名（备份点 A 守卫用）
  final Set<String> _recreatedBoxes = <String>{};

  StorageManager._();

  /// v4.5：测试实例判定——本 Flutter SDK foundation 没有 kTestMode
  /// （constants.dart 仅 kReleaseMode/kProfileMode/kDebugMode/kIsWeb），
  /// §7.5/§7.8 的备份开关据此判定，不引入不存在的 API。
  bool get isTestInstance => _homePathOverride != null;

  /// v4.6：测试 tearDown 物理删除临时目录用（仅 forTest 实例非 null）
  @visibleForTesting
  String? get homePathForTest => _homePathOverride;

  /// 测试专用构造（v4.3）：注入临时目录并完成 Hive.init，
  /// 绕过 getApplicationSupportDirectory()（其在 flutter test 下抛 MissingPluginException）
  @visibleForTesting
  StorageManager.forTest(String homePath) {
    _homePathOverride = homePath;
    Hive.init(homePath);
    _hiveReady = true;
  }

  /// 强类型非空 getter（v4.3）：业务侧禁止散布 `!`，未 open 即访问直接 fail-fast
  Box<dynamic> get progress => progressBox ??
      (throw StateError('StorageManager.openAll() must be called first'));
  Box<dynamic> get collections => collectionsBox ??
      (throw StateError('StorageManager.openAll() must be called first'));
  Box<dynamic> get state => stateBox ??
      (throw StateError('StorageManager.openAll() must be called first'));

  /// 生产端显式指定 {appSupport}/hive_data。
  ///
  /// 注意（v4.2）：不用 Hive.initFlutter()——hive_ce_flutter 的 initFlutter
  /// 用 getApplicationDocumentsDirectory()（文档目录），不传 subDir 时 box
  /// 直接散落 {appDoc} 根目录，与 §7.8 的 {appSupport}/hive_data/ 约定矛盾；
  /// 本工程只存 int/bool/String/JSON String，也不需要它注册的 Color/TimeOfDay
  /// 适配器。hive_ce 打开 box 时会自动创建缺失的 home 目录
  /// （backend_manager.dart:42-44），此处显式 create 仅为防御。
  Future<void> _ensureHiveInit() async {
    if (_hiveReady) return;
    final dir = await getApplicationSupportDirectory();
    final hiveDir = Directory('${dir.path}/hive_data');
    if (!await hiveDir.exists()) await hiveDir.create(recursive: true);
    Hive.init(hiveDir.path);
    _hiveReady = true;
  }

  /// 唯一公开入口（v4.3）：损坏检测 + 备份恢复 + 空库兜底**全部内聚于此**。
  /// 调用方（main.dart）只需 `await StorageManager.instance.openAll()`，
  /// 永不接触 BoxCorruptException——v4.2 若由 main 直接捕获，
  /// 任何遗漏 try-catch 的调用路径都会启动闪退。
  Future<void> openAll() async {
    await _ensureHiveInit();
    const maxBackupTries = 2;
    // v4.4：按 box 独立计数。v4.3 的共享 tries 存在跨 box 污染——
    // 双 box 同时损坏（整机掉电场景）时，第二个 box 首次损坏即被传入
    // tryIndex:1 跳过最新备份；若本地仅 1 份备份，会误判「无备份」
    // 直接触发兜底删库重建，白白丢失可恢复数据。
    final restoreTriesPerBox = <String, int>{};
    // v4.5：兜底重建过的 box 记录于此。§7.8 备份点 A 读取它跳过整轮备份，
    // 否则重建出的空 box 会立刻覆盖历史备份（连续 5 次异常启动 → 备份全空，机制自毁）。
    _recreatedBoxes.clear();
    while (true) {
      try {
        progressBox = await safeOpenBox<dynamic>('game-progress-v1');
        collectionsBox = await safeOpenBox<dynamic>('game-collections-v1');
        stateBox = await safeOpenBox<dynamic>('app-state-v1');
        return; // 3 个全部打开成功
      } on BoxCorruptException catch (e, st) {
        AppLogger.repo.severe('Corrupt box detected: ${e.boxName}', e, st);
        // 1. 关闭所有已打开 box（含健康 box），释放 .hive/.lock 句柄
        await closeAll();
        _clearBoxRefs();
        // 2. v4.5 先判后做；v4.6 恢复流水线解耦（三个单一职责方法，见下方签名块）：
        //    _quarantineBox（改名留证+清 .lock，幂等）→ _restoreBoxFile（仅复制）
        //    → _fallbackRecreate（登记 _recreatedBoxes，不再自行 openBox）
        final boxTries = restoreTriesPerBox[e.boxName] ?? 0;
        if (boxTries >= maxBackupTries) {
          await _fallbackRecreate(e.boxName);
          continue;
        }
        await _quarantineBox(e.boxName); // 幂等：文件不存在则跳过
        final restored = await _restoreBoxFile(e.boxName, tryIndex: boxTries);
        restoreTriesPerBox[e.boxName] = boxTries + 1;
        if (restored) continue; // 还原成功 → 回到循环顶部重新打开 3 个 box
        // 3. 还原失败（无该 box 备份 / 复制异常）→ 兜底（不再二次改名，quarantine 已完成）
        await _fallbackRecreate(e.boxName);
        // 循环继续：重建后的空 box 必然能打开；若另一 box 也损坏，同流程再走一遍
      }
    }
  }

  /// 兜底（v4.6 重写）：登记 _recreatedBoxes（触发 §7.8 备份点 A 一次性守卫）。
  /// 不再自行 openBox——回到 while 顶部由 safeOpenBox 天然创建干净空 box；
  /// 也不再重复改名留证（_quarantineBox 已幂等完成），消除 v4.5 的
  /// PathNotFoundException（无备份时二次改名）与 .lock 残留锁冲突。
  Future<void> _fallbackRecreate(String boxName) async {
    AppLogger.repo.severe('Fallback: recreating empty box $boxName');
    _recreatedBoxes.add(boxName);
    try {
      await Hive.deleteBoxFromDisk(boxName); // 内部会 close + 删 .hive/.lock
    } catch (e, st) {
      AppLogger.repo.severe('deleteBoxFromDisk failed for $boxName', e, st);
      // 持续 IO 故障：向上抛由 main() 兜底，绝不死循环
      rethrow;
    }
  }

  void _clearBoxRefs() {
    progressBox = null;
    collectionsBox = null;
    stateBox = null;
  }

  Future<void> flushPendingWrites() async {
    // v4.5：逐 box try/catch——一个 box flush 失败不阻断其余
    final boxes = [progressBox, collectionsBox, stateBox].whereType<Box<dynamic>>();
    await Future.wait(boxes.map((b) async {
      try {
        await b.flush();
      } catch (e, st) {
        AppLogger.repo.warning('Box ${b.name} flush failed', e, st);
      }
    }));
  }

  /// 测试专用：置空 3 个 box 引用与初始化标志，避免单例状态跨测试串留（v4）
  @visibleForTesting
  void resetForTest() {
    _clearBoxRefs();
    _hiveReady = false;
    _homePathOverride = null;
    _recreatedBoxes.clear();
  }

  /// v4.5：hive_ce 的 Hive.close() **不 flush**——box_base_impl → keystore.close →
  /// backend.close → storage_backend_vm._closeInternal（:269-275）只 close 三个 RAF
  /// 并删 lock 文件，全程无 writeRaf.flush()。close 前必须先 flushPendingWrites()，
  /// 否则 Dart RandomAccessFile 缓冲中的尾部写入直接丢失。
  Future<void> closeAll() async {
    await flushPendingWrites(); // 逐 box try/catch，单 box 失败不阻断
    await Hive.close();
  }
}
```

> **启动接入点（v4；v4.2 补全成员）**：`main.dart` 组1 当前是 `Future.wait([ImageCacheManager.instance.init(), GameRepository.instance.init(), EconomyService.instance.init(), AchievementStore.instance.init(), FavoriteStore.instance.init()])`（`main.dart:61-67`）并行。改造后必须在**组1 之前**加一行 `await StorageManager.instance.openAll();`，否则各 Store 取 box 时尚未打开。`ImageCacheManager` 不依赖 Hive，初始化位置不动。`Hive.init` 的调用者唯一化于 `_ensureHiveInit()` 内部（惰性），各 Store 不得自行调用。

- `safeOpenBox` 第 1 行先 `if (Hive.isBoxOpen(name)) return Hive.box(name);`，避免重复 open。

- 各 Store/Service 通过 `StorageManager.instance.xxxBox` 获取 box，**不**自行 `openBox`/`deleteBoxFromDisk`。

> **§7.1/§7.8 代码引用的以下方法均为本次新建**（现状不存在，类似 §7.6 的 reset() 标注），最小签名约定（v4.6 按单一职责解耦重写；v4.7 补充可直接落地的简明实现参考）：
>
> ```dart
> /// 留证隔离（幂等）：{box}.hive 改名 .corrupt-{ts}（文件存在才改，3 次重试），
> /// 并删除残留的 {box}.lock（Hive 异常路径可能遗留，Windows 下引发锁冲突）。
> /// 不做还原、不重建——与 v4.5 的职责混杂版相反。
> Future<void> _quarantineBox(String boxName);
>
> /// 仅负责复制：从 hive_backups 第 tryIndex 新的 backup-*/ 把 {box}.hive
> /// 复制回 hive_data/。无可用备份 / 复制异常返回 false。不改名、不删源。
> Future<bool> _restoreBoxFile(String boxName, {required int tryIndex});
>
> /// 备份（v4.6 补链式锁）：原子目录备份（.tmp + 单次 rename，只复制 .hive）。
> /// isTestInstance 直接 return。锁串行化桌面端 onHide/onInactive/onExitRequested
> /// 的并发触发，防止边复制边写撕裂与同秒目录冲突。
> Future<void>? _backupLock; // 实例字段
> Future<void> backupNow() {
>   _backupLock = (_backupLock ?? Future.value())
>       .then((_) => _doBackup()); // _doBackup 含毫秒时间戳 + rename 前存在性校验
>   return _backupLock;
> }
> ```
>
> **v4.7 落地实现参考（直接按此编写，无需再抉择）**：
>
> ```dart
> /// _quarantineBox：检查 {hive_data}/{boxName}.hive 是否存在，存在则
> /// 重命名为 {boxName}.hive.corrupt-${DateTime.now().millisecondsSinceEpoch}
> ///（带 3 次延迟 50ms 重试，消化 Windows 异步句柄关闭的 sharing violation），
> /// 并删除同目录下残留的 {boxName}.lock（若存在）。幂等，不抛异常。
> Future<void> _quarantineBox(String boxName) async {
>   final hiveFile = File('${_hiveDir.path}/$boxName.hive');
>   if (await hiveFile.exists()) {
>     final ts = DateTime.now().millisecondsSinceEpoch;
>     final corruptFile = File('${hiveFile.path}.corrupt-$ts');
>     for (var i = 0; i < 3; i++) {
>       try { await hiveFile.rename(corruptFile.path); break; }
>       catch (_) { if (i == 2) rethrow; await Future.delayed(const Duration(milliseconds: 50)); }
>     }
>   }
>   final lockFile = File('${_hiveDir.path}/$boxName.lock');
>   if (await lockFile.exists()) { try { await lockFile.delete(); } catch (_) {} }
> }
>
> /// _restoreBoxFile：按名称倒序（即时间倒序）扫描 {appSupport}/hive_backups/backup-*/
> /// 目录，取第 tryIndex 个目录下的 {boxName}.hive 复制到 hive_data/。
> /// 无可用备份 / 复制异常返回 false。不改名、不删源。
> Future<bool> _restoreBoxFile(String boxName, {required int tryIndex}) async {
>   final backupsRoot = Directory('${_appSupport.path}/hive_backups');
>   if (!await backupsRoot.exists()) return false;
>   final dirs = (await backupsRoot.list().toList())
>       .whereType<Directory>()
>       .where((d) => p.basename(d.path).startsWith('backup-'))
>       .toList()..sort((a, b) => b.path.compareTo(a.path)); // 倒序：最新在前
>   if (tryIndex >= dirs.length) return false;
>   final src = File('${dirs[tryIndex].path}/$boxName.hive');
>   if (!await src.exists()) return false;
>   try { await src.copy('${_hiveDir.path}/$boxName.hive'); return true; }
>   catch (_) { return false; }
> }
>
> /// _doBackup：复制 3 个 box 的 .hive 到临时目录 .backup-${ts}.tmp/，
> /// 全部复制成功后单次 rename 为 backup-${ts}/ 正式目录（原子落位），
> /// 并保留最近 5 份备份（超出删最旧），清理残留 .tmp 目录。
> /// 仅复制 .hive，跳过 .lock；isTestInstance 直接 return。
> Future<void> _doBackup() async {
>   if (isTestInstance) return;
>   final ts = DateFormat('yyyyMMdd-HHmmss-SSS').format(DateTime.now());
>   var tmpDir = Directory('${_backupsRoot.path}/.backup-$ts.tmp');
>   // 毫秒时间戳冲突时追加随机 4 位后缀
>   if (await tmpDir.exists()) tmpDir = Directory('${tmpDir.path}-${Random().nextInt(10000).toString().padLeft(4, '0')}');
>   await tmpDir.create(recursive: true);
>   for (final name in ['game-progress-v1', 'game-collections-v1', 'app-state-v1']) {
>     final src = File('${_hiveDir.path}/$name.hive');
>     if (await src.exists() && await src.length() > 0) {
>       await src.copy('${tmpDir.path}/$name.hive');
>     }
>   }
>   final dst = Directory('${_backupsRoot.path}/backup-$ts');
>   if (await dst.exists()) { // 极小概率同毫秒冲突
>     await tmpDir.rename('${dst.path}-${Random().nextInt(10000).toString().padLeft(4, '0')}');
>   } else {
>     await tmpDir.rename(dst.path);
>   }
>   // 清理残留 .tmp
>   await for (final e in _backupsRoot.list()) {
>     if (e is Directory && p.basename(e.path).startsWith('.backup-') && p.basename(e.path).endsWith('.tmp')) {
>       try { await e.delete(recursive: true); } catch (_) {}
>     }
>   }
>   // 保留最近 5 份
>   final all = (await _backupsRoot.list().where((e) => e is Directory && p.basename(e.path).startsWith('backup-')).toList())
>     ..sort((a, b) => a.path.compareTo(b.path));
>   for (var i = 0; i < all.length - 5; i++) { try { await (all[i] as Directory).delete(recursive: true); } catch (_) {} }
> }
> ```

### 7.2 损坏检测（safeOpenBox）

> **v4.2 修订（职责收敛）**：本节只负责**检测**——区分「损坏」与「瞬时 I/O 错误」。损坏时抛专用异常上交 §7.8 统一恢复，**不再就地删盘重建**（v4.1 的就地重建会让 openAll「正常返回一个空 box」，§7.8 的备份恢复永远不会被触发，两级兜底名存实亡）。删盘重建仅在 §7.8 恢复备份连续失败后作为最终兜底执行。
>
> **crashRecovery 说明（v4.2）**：`Hive.openBox` 默认 `crashRecovery: true`，文件**尾部**的半写帧（断电/强杀残留）会被自动截断消化、不抛异常。因此本节的「损坏」实际只兜**文件头损坏 / 整文件损坏**这类 crashRecovery 救不回的场景，§7.8 对照表中的「单 key CRC 错」预期极少发生。

```dart
/// 损坏专用异常：safeOpenBox 检测到损坏时抛出，中断当前 open 尝试，
/// 由 openAll() 内部的恢复循环（v4.3，见 §7.1/§7.8）统一处理；
/// 对 main() 等调用方完全不可见。
class BoxCorruptException implements Exception {
  final String boxName;
  BoxCorruptException(this.boxName);
  @override
  String toString() => 'BoxCorruptException: $boxName';
}

/// v4.6：异常类型优先。注意类型层级——HiveError extends Error（hive_error.dart:5），
/// 而 FormatException implements Exception、RangeError extends ArgumentError，
/// 三者平级：on HiveError 根本接不住后两者（v4.2–v4.5 的 catch 范围过窄，
/// 文件头损坏/字节截断会直接穿透闪退）。
bool isCorruption(Object e) {
  if (e is FormatException) return true; // 文件头/帧格式不合法
  if (e is RangeError) return true; // 字节截断（binary_reader 'Not enough bytes'）
  if (e is HiveError) {
    final s = e.toString().toLowerCase();
    return s.contains('invalid file format') ||
        s.contains('crc') ||
        s.contains('corrupt') ||
        s.contains('truncated');
  }
  return false;
}

Future<Box<T>> safeOpenBox<T>(String name) async {
  if (Hive.isBoxOpen(name)) return Hive.box<T>(name);
  try {
    return await Hive.openBox<T>(name);
  } catch (e, st) {
    // v4.6：通用 catch——瞬时 IO 错（磁盘满/锁冲突）抛 FileSystemException，
    // 损坏抛 FormatException/RangeError/HiveError，均在此分流
    if (isCorruption(e)) {
      AppLogger.repo.severe('Box $name corrupted', e, st);
      throw BoxCorruptException(name); // 恢复决策上交 §7.8
    }
    // 非损坏：重试一次，绝不删盘；仍失败则向上抛，交上层决策
    // （保持 UI 可用的默认数据，绝不静默清空）
    AppLogger.repo.warning('Box $name open transient error, retry', e, st);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    try {
      return await Hive.openBox<T>(name);
    } catch (retryErr, retrySt) {
      if (isCorruption(retryErr)) {
        AppLogger.repo.severe('Box $name corrupted (retry)', retryErr, retrySt);
        throw BoxCorruptException(name);
      }
      rethrow; // 瞬时错误持续存在 → 由 main() 兜底提示用户
    }
  }
}
```

- 损坏现场留证（改名 `{box}.hive.corrupt-{ts}`）由 §7.8 恢复流程步骤 b 完成，本节不做任何磁盘变更。

- 非损坏重试仍失败时**不可删盘**，继续向上抛 / 记录，由 `main()` 兜底（提示用户或以默认数据启动）。

### 7.3 启动顺序（水合 Hydration 流程，v4 明确；v4.5 重写 step3）

> **依赖序 ≠ 执行序（v4.5 注记；v4.6 强化）**：下图是**数据依赖顺序**。实际 `main.dart` 中 openAll（+启动备份）完成后，组1 五个 init 仍是 `Future.wait` **并行**（`main.dart:61-67`）——这是安全的：`ProgressStore.init()` 在 `GameRepository.init()` **内部先行 await**（`game_repository.dart:97`），EconomyService 等不依赖 ProgressStore，无需也不应改成串行。

```
1. StorageManager.openAll()      ← 必须先于所有 Store 初始化（损坏时内部自动走 §7.8 两阶段恢复，调用方无感知）
1.5 启动备份（§7.8 备份点 A）    ← openAll 成功后、任何 Store init 之前复制 .hive（§7.1 _recreatedBoxes 守卫）
2. ProgressStore.init()          ← 建全量内存索引 _index[cid]
3. GameRepository.init() = _initLevels() / _initCustomPuzzles()
     ├─ _initLevels(): **删除 prefs 读取分支（v4.5 P0）**——现状 `game_repository.dart:149-160`
     │   读 `jigsaw_level_{i}` 整条 JSON 直接 `list.add(); continue;`，改造后该分支整体移除，
     │   统一为：静态生成 LevelItem → `getLevelProgress(canonicalForLevel(i))` 非空则 copyWith 回填
     │   进度字段（isCompleted/progressPercent/stars/bestTimeSeconds/completedPieceCounts）
     ├─ （无 _initDailyChallenges：该方法不存在。每日内容由 daily_content_pipeline 提供，
      │    进度水合点在 tabs/daily_tab_view.dart:170-178 且已走 ProgressStore，随迁自动完成，见 §2.2 注）
     └─ _initCustomPuzzles(): 依赖 §4.4 presetsInitialized 标志；加载 custom:* 元数据后
        **必须从 ProgressStore 回填 ugc:{id} 进度**（v4.3，见下注）
4. EconomyService / AchievementStore / FavoriteStore / DownloadManager 各自 init()，
   从 StorageManager box 前缀读入内存缓存（§3.3；AchievementStore 按 §4.3 前缀扫描 ach:*）
```

> **自制拼图水合（v4.3 补，此前遗漏）**：§5.2 已把 `CustomPuzzleItem` 的 4 个进度字段委托给 `game-progress-v1` 的 `ugc:{id}`，因此 `_initCustomPuzzles()` 从 collections box 加载元数据后**必须立即回填**，否则内存中自制拼图恒为默认值（`isCompleted=false`、`progressPercent=0`），通关状态重启后全部「回退」为未完成。注意实际 API 是 `getLevelProgress`（非空返回，无记录时给全新空 `LevelProgress`，`progress_store.dart:243-252`），空判断用「无任何落盘痕迹」：
>
> ```dart
> _customPuzzles = rawList.map((item) {
>   final prog = ProgressStore.instance.getLevelProgress(canonicalForCustom(item.id));
>   final hasRecord = prog.lastSavedAt != null || prog.isCompleted ||
>       prog.progressPercent > 0;
>   if (!hasRecord) return item;
>   return item.copyWith(
>     isCompleted: prog.isCompleted,
>     progressPercent: prog.progressPercent,
>     bestTimeSeconds: prog.bestTimeSeconds,
>     completedPieceCounts: prog.completedPieceCounts,
>   );
> }).toList();
> ```
>
> **级联删除（v4.3 同步补）**：现状 `deleteCustomPuzzle` 只清快照（`SnapshotStore.deleteAllFor` + `clearAllSnapshots`），**不清进度记录**。改造后须级联 `ProgressStore.instance.delete(canonicalForCustom(id))`（从 `_index` 与 `game-progress-v1` 一并移除），防止孤儿 `ugc:{id}` 进度永久残留、且重新创建同 id 拼图时旧进度错误复活。

> **关键**：`ProgressStore.init()` **必须先于** `_initLevels()`/`_initCustomPuzzles()`（同在 GameRepository.init 内串行保证）。UI（关卡列表、每日日历）读取的是 `level.isCompleted` / `progressPercent` / `stars`，需在 Item 构造时已回填，而非 UI 侧二次加载。

### 7.4 `get` 同步，`put` 异步

`box.get()` 同步；`box.put()` / `box.delete()` 返回 `Future<void>`（内存更新同步，刷盘异步）。

| 写入场景            | 是否 await                   | 理由     |
| :-------------- | :------------------------- | :----- |
| 通关结算、成就解锁、金币变动  | **必须 await**               | 丢写直接可见 |
| 自动生成进度 autosave | 可 `unawaited` + 退后台前 flush | 高频，可容忍 |
| 计数器累加           | `unawaited` + 定期 flush     | 同上     |

> 项目 lint（`flutter_lints 6.0.0` → `lints 6.1.0 recommended`）**未启用** **`unawaited_futures`**。需在 review 中人工核对，或显式包 `unawaited()` 表明「有意」。

### 7.5 Compaction 与关闭

- **Compaction**：append-only 写入，同 key 反复 put 累积废帧。高频 `ach:counter:*`、`stat:*` 与 autosave 会放大。策略：桌面 `onHide`（移动端 `onPause`，见下条触发点）时静默 `compact()` 或每 N 局一次；需实测默认策略频率后决定是否自定义 `compactionStrategy`。

- **退后台/退出 flush + 备份（v4.2 触发点；v4.3 改桌面语义）**：§7.4 允许 autosave / 计数累加走 `unawaited`，必须在统一挂载点刷盘并顺带备份（§7.8 备份点 B），保证恢复点新鲜到最后一次会话结束。**⚠ 本项目主力平台是 Windows 桌面**（`flutter build windows`），而 `AppLifecycleState.paused` **在桌面端永不触发**——桌面只有 `inactive`（失焦）/ `hidden`（最小化/切后台），关窗直接走 `detached`/进程终止。v4.2 基于 `paused` 的 `WidgetsBindingObserver` 方案在 Windows 上 flush 与备份**一次都不会执行**，故改用 Flutter 3.13+ 的 **`AppLifecycleListener`**（工程 SDK ^3.12.2 支持）：

  ```dart
  // main.dart 顶层（文件级）变量持有，绝不可写成 main() 内局部变量——
  // 局部引用随 main 栈帧结束后即可被 GC 静默回收，回调失效且无任何提示。
  // 注意：unawaited() 需 import 'dart:async'（main.dart 现无此 import）。
  AppLifecycleListener? _lifecycleListener;
  DateTime? _lastBackupTime;

  void _initLifecycleHooks() {
    _lifecycleListener = AppLifecycleListener(
      onHide: _handleBackgroundSync,     // Windows 最小化 / 切到后台
      onInactive: _handleBackgroundSync, // 失焦（有节流，防频繁磁盘复制）
      onPause: _handleBackgroundSync,    // 移动端退后台（桌面不触发，保留兼容）
      onExitRequested: () async {
        // 桌面端点 X / Alt+F4：进程终止前最后的同步机会。
        // v4.6：补 closeAll()——与「仅进程终止前 closeAll」声明对齐
        //（closeAll 内部先 flush 再 Hive.close，清理 .lock 文件）
        try {
          if (!StorageManager.instance.isTestInstance) {
            await StorageManager.instance.flushPendingWrites();
            await StorageManager.instance.backupNow();
          }
          await StorageManager.instance.closeAll();
        } catch (e, st) {
          AppLogger.system.warning('exit cleanup failed', e, st);
          // 清理失败不阻止退出
        }
        return AppExitResponse.exit;
      },
    );
  }

  void _handleBackgroundSync() {
    unawaited(StorageManager.instance.flushPendingWrites().then((_) {
      if (StorageManager.instance.isTestInstance) return; // v4.5：SDK 无 kTestMode
      final now = DateTime.now();
      if (_lastBackupTime != null &&
          now.difference(_lastBackupTime!) < const Duration(minutes: 5)) {
        return; // 节流：桌面反复切窗不放大磁盘复制
      }
      _lastBackupTime = now;
      StorageManager.instance.backupNow(); // §7.8 备份点 B
    }));
  }
  // main() 中、runApp() 之前调用一次 _initLifecycleHooks()
  ```

  **要点（v4.3；v4.4 示例改顶层声明）**：①`onExitRequested` 是桌面关窗时**唯一**可靠的收尾钩子（默认 `AppExitResponse.exit` 前完成 flush+备份）；②`backupNow()` 自带进程内互斥（§7.8），此处节流仅是减少无效排队；③监听器引用必须是 main.dart **顶层变量/静态字段**（示例中 `_lifecycleListener`），写成 `main()` 局部变量会被 GC 静默回收、回调失效。

  需要 flush 的写入点（汇总）：

  - autosave 进度（`ProgressStore` 高频未 await 写）

  - `ach:counter:*` / `stat:*` 计数累加

  - `DownloadManager` / `FavoriteStore` 未 await 的批量落盘

- **关闭**：退后台（paused）只 flush 不 close；**仅进程终止前** `StorageManager.closeAll()`。

### 7.6 `resetAllData()`

> **⚠ 行为声明（v4；v4.5 更正行号与样例语义）**：现状唯一入口 `settings_page.dart:326`，实现 `game_repository.dart:810-821` 直接 `_prefs?.clear()`，**连设置一起清掉**（与文案不符）。改造后新顺序**保留设置**（仅清进度数据），更贴合文案——这是**有意为之的行为变更**，需在 UI 文案与发版说明中显式标注。
>
> **⚠ 样例语义声明（v4.5，经源码核实）**：重置后 `_initCustomPuzzles()` 读 `custom:presetsInitialized` 缺失（步骤 1 已 clear）→ **重新植入 3 个默认样例**。这与**现状行为一致**（现状 `resetAllData` 清 prefs 后 `_initCustomPuzzles`（`game_repository.dart:188-204`）读 key 缺失同样重注入），即「重置 = 恢复出厂（含样例）」，**不是**新引入的行为变更。若未来想改成「重置后自制列表保持为空」，在步骤 1 的 clear 前读出该标志、clear 后原样写回即可（本版不采用）。

现状 `game_repository.dart:810-821` 直接 `_prefs?.clear()`。改造后新顺序（v4.4 删除历史残留步骤 0——其「`_prefs != null` 早返回需显式重建」的背景已随改造消失，重置入口必然已 init 过，直接从清 box 开始）：

```
1. 清空 3 个 Hive box（clear()，不 deleteFromDisk）
2. SnapshotStore.instance.clearAll()
3. ProgressStore.instance.reset()     // (v4 点名本人；亦为新建) 清 _index 并 refreshAggregatesCache()；
                                     // **末尾必须 `progressNotifier.value++` 广播（v4.3）**——「我的」中心等界面
                                     // 靠监听 progressNotifier 重绘（progress_store.dart:172），只清 _index 不通知
                                     // → UI 继续显示旧统计（总星数/通关数），直到下次任意进度写入
4. 重置各单例内存状态（**以下 4 个 `reset()` 方法均为本次新建，现状 lib/ 下不存在**——grep 仅 main.dart:69 的秒表 `sw.reset()`，实施时不可当作现成方法调用）：
     EconomyService.instance.reset()        // 新建：清 _prefs 引用；现状无内存值（getter 直读
                                           // _prefs，economy_service.dart:83-84），改造后改从 box
                                           // 同步 get，故 reset 内直接重发 starter 资产：
                                           // 写 econ:coins=100、econ:hintCoupons=5、
                                           // econ:starterGranted=true（box + 内存一致）——
                                           // 否则当前会话金币为 0，须杀进程重启才补发
     AchievementStore.instance.reset()      // 新建：清 counter/unlock/claimed/starred 4 个 Map/Set 内存缓存 + _prefs
     FavoriteStore.instance.reset()         // 新建：清 _entriesCache + idsNotifier
     DownloadManager.instance.reset()       // 新建：**直接清空 download_cache 目录（v4.6）**——
                                           // 物理文件有两种命名：本地导入 mat_{id}.{ext}（:115）与
                                           // 网络下载 img_{id}.jpg（:192，素材库主力来源），
                                           // v4.5 只扫 mat_*.* 会漏掉全部网络下载图片。该目录为
                                           // DownloadManager 独占，重置语义即归零，不做脆弱的前缀匹配：
                                           // ① 遍历 {appSupport}/download_cache/ 全部文件逐个删除
                                           //   （init() 在 main 组2 后台不 await，内存可能为空，
                                           //    扫盘天然覆盖）；② 清理 ImageCacheManager 缩略图缓存；
                                           // ③ 清 itemsNotifier + _initialized 标志
5. _initLevels() / _initCustomPuzzles()   // 含 §7.3 的进度水合；无 _initDailyChallenges（不存在，见 §7.3）
6. 仅在「同时清除设置」的入口才清 SharedPreferences 中的设置 key（设置域见 §2.1；仅清进度数据时不触发）
7. ProgressStore.instance.reconcileSnapshots()  // 新建（v4.6；v4.7 补充参考实现）：
   // 遍历 _index.values 中 hasSnapshot==true 的项，调用 SnapshotStore 快照键校正
   // （恢复/重置后防幽灵索引，见 §7.8 自愈说明）。v4.7 参考逻辑见下方代码块
```

> **v4.7 `reconcileSnapshots()` 参考实现（直接按此编写）**：
>
> ```dart
> /// 校正 _index 中 hasSnapshot/snapshotKeys 与物理快照的一致性。
> /// 在 init()/恢复/重置后调用，消除幽灵索引（索引称有快照但文件已无）
> /// 与 snapshotKeys 漂移。
> Future<void> reconcileSnapshots() async {
>   var dirty = false;
>   for (final cid in _index.keys.toList()) {
>     final p = _index[cid]!;
>     if (!p.hasSnapshot) continue;
>     // SnapshotStore 按 canonicalId 管理快照文件（见 snapshot_store.dart）
>     final actualKeys = await SnapshotStore.instance.listDifficultyKeys(cid);
>     // actualKeys 为空 → 物理快照已全部丢失；或与索引记录不一致 → 需校正
>     final indexedKeys = p.snapshotKeys;
>     final mismatch = actualKeys.isEmpty && p.hasSnapshot ||
>         actualKeys.length != indexedKeys.length ||
>         !actualKeys.toSet().containsAll(indexedKeys);
>     if (mismatch) {
>       final corrected = p.copyWith(
>         hasSnapshot: actualKeys.isNotEmpty,
>         snapshotKeys: actualKeys,
>         activeDifficultyKey: actualKeys.isNotEmpty ? p.activeDifficultyKey : '',
>       );
>       _index[cid] = corrected;
>       await _progressBox.put(cid, jsonEncode(corrected.toJson()));
>       dirty = true;
>     }
>   }
>   if (dirty) {
>     await refreshAggregatesCache();
>     progressNotifier.value++;
>   }
> }
> ```
>
> **要点**：① `listDifficultyKeys(cid)` 为 SnapshotStore 已有能力（扫描 `{appSupport}/snapshots/{cid}__*.snapshot`），无需新增文件扫描逻辑；② 有校正才写盘+刷新聚合，避免无谓 IO；③ 与 `deleteCustomPuzzle` 的级联删进度互补——此处只修快照索引，不删进度记录本身。

> **关键：ProgressStore 自身必须参与重置（v4 点名）**。改造后的 `ProgressStore.init()` 应保留与现状 `if (_prefs != null) return;`（`progress_store.dart:183`）等价的幂等守卫（如 `if (_index != null) return;`）——因此 `resetAllData()` 里调用 `init()` 不会重建索引，必须新建 `ProgressStore.reset()` 专门做「清空 `_index` → 重新 `refreshAggregatesCache()` → `progressNotifier.value++`」，否则重置后 `getTotalStars()`/`getTotalSolved()` 等仍返回旧统计。
>
> 无 `mig:*`，`clear()` 只清数据；重置后正常重建。

### 7.7 isolate 约束

Hive box **不是 isolate-safe**。现有 isolate 使用点：`thumbnail_generator.dart`（`compute`）、`image_upscaler.dart`（`Isolate.run`），当前只处理图像字节、不触碰 store，暂时安全。**架构约束**：box 只在主 isolate 打开，任何 isolate 回调内不得访问 box 或 Store。

### 7.8 备份与恢复（v4 新增，v4.2 重写恢复时序与备份粒度）

> 在 §7.2 损坏检测之上提供**文件级备份/恢复**，作为进度兜底。v4.2 修正 v4.1 两处结构性缺陷：①恢复改用「检测在 openAll 内、恢复在其后」的**两阶段流程**（检测抛 `BoxCorruptException` → close → 还原 → 重新 open），消除「restore 必须在 openAll 之前完成」与「openAll 内检测损坏」的自相矛盾；②备份/恢复改**按 box 文件粒度**——3 个 box 一起备份（同一时间戳目录），但只还原损坏的那个，单 box 损坏不回滚另外两个健康 box。

**目录约定**：

| 项          | 路径                                                    | 说明                                                             |
| :--------- | :---------------------------------------------------- | :------------------------------------------------------------- |
| 生产 Hive 数据 | `{appSupport}/hive_data/`                             | 所有 box 的 `.hive` / `.lock` 文件所在（§7.1 `_ensureHiveInit()` 显式指定） |
| 备份目录       | `{appSupport}/hive_backups/backup-{yyyyMMdd-HHmmss-SSS}/` | 平铺 3 个 `.hive` 文件（**不含** `.lock`）；毫秒时间戳（v4.6，防同秒 rename errno 183） |
| 损坏现场       | `{appSupport}/hive_data/{box}.hive.corrupt-{ts}`      | 恢复流程改名留证，不强删                                                   |

> 测试环境（`forTest` 构造的实例，`isTestInstance == true`，见 §7.1）不启用备份，避免拖慢测试。

**备份时机（两处，v4.2；v4.3 补原子性；v4.5 补空箱守卫；v4.6 守卫改一次性）**：

```
A. 启动备份：openAll() 成功后、任何 Store init 之前（main 组1 前）
   0. 【v4.6 一次性守卫】若 openAll 期间有 box 走过兜底重建（_recreatedBoxes 非空）：
      跳过本轮备份 A 并 severe 告警——否则刚重建的空 box 会立刻成为最新备份，
      配合「只留 5 份」轮转逐步覆盖历史好备份。注意：守卫仅作用于启动备份 A，
      不阻断会话备份 B（否则单 box 重建后用户整个会话的新进度永不备份，断电即失）。
      B 点的空箱防护由 backupNow() 自身承担：仅当 .hive 文件大小 > 0 才允许轮转
      （空 box 的 .hive 仅有文件头数十字节，可作阈值判断）
   1. openAll() 成功——此刻进程内尚无任何业务写入，openBox 期间的
      crashRecovery 截断 / compaction 均已完成，.hive 处于一致态
   2. 先复制 hive_data/*.hive → hive_backups/.backup-{ts}.tmp/（只复制 .hive，
      跳过 *.lock；不删除、不移动任何源文件——Windows 下 box 打开期间持有
      .lock 句柄，删除即 sharing violation）
   3. 3 个文件全部复制完成后，单次 rename 将 .tmp 目录原子改为
      backup-{ts}/（防复制中途被强杀留半成品；rename 前校验目标不存在，
      毫秒级时间戳冲突时追加随机 4 位后缀）
   4. 顺手清理历史残留的 .backup-*.tmp/ 目录
   5. 仅保留最近 N 份（默认 5），超出删最旧

B. 会话备份：桌面 onHide/onInactive、移动端 onPause、退出 onExitRequested 时，
   flushPendingWrites() 之后 await backupNow()（见 §7.5；v4.6：backupNow 自带
   链式互斥锁，串行化并发触发，防止边复制边写撕裂），保证恢复点新鲜到最后
   一次会话结束。§7.5 已含 5 分钟节流。
```

> **crashRecovery 截断的残留风险（v4.6 显式声明）**：帧 CRC 不匹配时 hive_ce 的 `readFrame` **返回 null 而非抛异常**（binary_reader_impl.dart:291-308），`crashRecovery: true` 下 storage_backend_vm.dart:131-136 **静默截断**至坏帧偏移——即最常见的物理损坏（中部帧 CRC 坏、尾部截断）不会抛异常、§7.8 两阶段恢复**不触发**，且截断 box 会被备份点 A 当作健康快照纳入轮转。此通路无法从公开 API 感知，可选缓解：挂接 `Logger` 捕获 `'Recovering corrupted box.'` 日志（hive_ce 内部截断时输出），命中则本会话标记「发生过截断」，走与 `_recreatedBoxes` 相同的点 A 守卫并告警；不挂接则接受「轮转 5 份对单次截断有容忍边界」的残余风险（截断只影响坏帧之后的数据，且旧备份仍可手工还原）。
>
> **物理文件与盒备份的非事务性（v4.6 声明）**：备份仅含 3 个 `.hive`；`download_cache/` 物理图片与 `snapshots/*.snapshot` **不随备份回滚**。恢复后可能出现 `material:{id}` 指向已删文件的幽灵索引（`DownloadManager.init()` 的失效过滤 §5.4 自愈）或 `hasSnapshot=true` 但快照文件缺失（新增 `ProgressStore.reconcileSnapshots()` 在 init/恢复后校正，见 §7.6 步骤 7）。孤儿快照文件（索引已回滚、文件仍在）由 SnapshotStore 启动清理兜底。接受该近似一致性——素材可重新下载、快照仅影响续玩。

> **为何启动备份不需要 close**：备份点 A 处于「box 已打开、但进程内零业务写入」的窗口，复制 `.hive` 读到的是一致快照，`.lock` 跳过不碰。若未来把备份挪到运行期任意时机，必须先 `closeAll()` 再复制（半写帧风险），完成后 `openAll()` 并重新 init 各 Store（Box 引用失效）——首版不采用。会话备份 B 在 flush 后执行，复制期间若恰有新的未 flush 写入，备份会略旧于内存（下次备份补齐）；极端撕裂的备份会在恢复时被 isCorruption 检出、自动落到次新备份，可接受。

**恢复时机（两阶段流程，v4.2；v4.3 内聚进 openAll 并修时序）**：

```
阶段一（检测，safeOpenBox 内部）：
  命中 isCorruption → 抛 BoxCorruptException(boxName)，
  当前 openAll 尝试中断（此刻 3 个 box 可能部分已打开，属预期，阶段二统一处理）

阶段二（恢复，openAll() 内部恢复循环，见 §7.1 代码；对 main() 完全透明）：
  每个损坏 box 独立尝试最近 2 份备份（restoreTriesPerBox 按 box 计数，v4.4，
  不被其他 box 的重试次数污染；v4.5 改先判后做修 off-by-one——超限直接走兜底，
  不再多复制一份即丢弃；防死循环）：
  a. closeAll()                            // 先 flushPendingWrites() 再 Hive.close()
     （v4.5：hive_ce 的 close 不 flush，直接 Hive.close() 会丢 RAF 缓冲尾部写入），
     释放 .hive/.lock 句柄
  b. 将损坏的 {box}.hive 改名 {box}.hive.corrupt-{ts} 留证
     （仅该 box；健康 box 文件不动）。改名带 3 次重试（间隔 50ms）——
     Windows 下 Hive backend 句柄关闭是异步流转，立即 rename 可能
     ERROR_SHARING_VIOLATION (errno 32)，重试即消化
  c. 从 backup-{ts}/ 复制该 box 的 .hive 还原到 hive_data/
  d. 回到 openAll 循环顶部重新打开 3 个 box（close 后 isBoxOpen 必为 false，
     正常走 openBox 路径——v4.2「幂等返回」的措辞有误，已删）
  e. 该 box 仍损坏 → 换次新备份重试 a–d

兜底（每个 box 最多试 2 份备份后仍失败，或无任何备份）：
  → 对该 box 执行「重建空 box」：closeAll() → Hive.deleteBoxFromDisk(name)
    → openBox 重建；其余健康 box 不动；记录 severe 日志并登记 _recreatedBoxes
    （触发 §7.8 备份点 A 的空箱守卫，v4.5）
```

> **恢复完成于任何 Store init 之前（v4.2 澄清）**：openAll 在 main 组1 之前执行，恢复结束时 ProgressStore / EconomyService 等尚未 init，**不存在「内存缓存与恢复后 box 数据不一致」的问题**，无需各 Store 重初始化。若未来引入运行期热恢复，才需要重放各 Store init——注意 `ProgressStore.init()` 有 `if (_prefs != null) return` 早返回（`progress_store.dart:183`），须先 `reset()` 再 `init()`（方法见 §7.6，均为新建）。

**与 §7.2 的关系**：

| 场景                | 处理路径                                              |
| :---------------- | :------------------------------------------------ |
| 尾部半写帧（断电/强杀残留）    | `crashRecovery: true` 自动截断，无需任何处理                 |
| 文件头/整文件损坏、冷启动读取异常 | §7.8 两阶段恢复（**优先**）；连续 2 份备份失败 → 重建空 box（**最终兜底**） |
| 锁冲突 / 磁盘满等瞬时错误    | §7.2 重试一次，不删盘、不恢复                                 |

**注意事项**：

- 备份为**目录级快照、box 级还原**：3 个 box 用同一时间戳一起备份，恢复只回写损坏的那个 box 文件；Hive 无跨 box 事务，接受「同一 open 周期内」的近似一致性。

- **恢复扫描只认 `backup-*` 目录**（v4.3）：跳过一切 `.` 开头或 `.tmp` 结尾的残缺目录；备份文件复制后可校验长度 > 0 再计入可用。

- 备份写失败或备份目录被清空时：**静默降级**，不阻塞启动；仅打日志。

- 备份/恢复操作都在主 isolate 串行执行，不放进 `compute` / `Isolate.run`（见 §7.7）。`backupNow()` 需做进程内互斥（串行化桌面端 onHide/onInactive/onExitRequested 的连续触发），用简单的 `Future` 链式锁即可。

***

## 八、API 映射

| 现状（SharedPreferences）                                             | 改造后                                                                      |
| :---------------------------------------------------------------- | :----------------------------------------------------------------------- |
| `prefs.getString('jigsaw_level_{i}')` + jsonDecode → 整条 LevelItem（**主线水合 SSOT**，`game_repository.dart:149-160`） | **删除该读取分支**：静态生成 → `getLevelProgress(canonicalForLevel(i))` 回填（§7.3）          |
| `prefs.setString('jigsaw_level_{i}', jsonEncode(item.toJson()))`（`updateLevelProgress`:356 / 解锁:454 两处） | **删除**：进度写 `ProgressStore` → `box.put` 一条路径（内存 Item copyWith 保留，§3.3 写侧一致性） |
| `prefs.getString('jigsaw_progress_v3_{safe}')` + jsonDecode       | `_index[cid]`（内存 O(1)）；init 时一次性解码                                       |
| `prefs.setString(...jsonEncode(p))`                               | `_index[cid] = p; await box.put(cid, jsonEncode(p.toJson()))`            |
| `prefs.getKeys().where(startsWith(prefix))`                       | `box.keys`                                                               |
| `prefs.setString('jigsaw_custom_list', jsonEncode(array))`        | `await box.put('custom:$id', jsonEncode(m))`                             |
| `prefs.getString('jigsaw_custom_list')` 整读 + 全删判定                 | 前缀读入 `List<CustomPuzzleItem>` 内存缓存；via `custom:presetsInitialized`（§4.4） |
| `prefs.setString('jigsaw_favorites_v1', ...)`                     | `await box.put('favorite:$cid', ...)`                                    |
| `prefs.getString('jigsaw_favorites_v1')` 整读                       | 前缀读入 `_entriesCache`（内存），聚合按 `favoritedAt` 倒序（§3.3）                      |
| `prefs.setString('cached_downloaded_images_v1', ...)`             | `await box.put('material:$id', ...)`                                     |
| `prefs.getString('cached_downloaded_images_v1')` 单 key 大数组整读      | 前缀读入 `itemsNotifier`（内存），聚合按 `downloadedAt` 倒序（§3.3）                     |
| `prefs.setString('jigsaw_achievement_counters', jsonEncode(map))` | `await box.put('ach:counter:$k', v)`                                     |
| `prefs.setStringList('jigsaw_achievement_claimed', list)`         | `await box.put('ach:claimed:$id', true)`                                 |
| `prefs.setInt('jigsaw_economy_coins', v)`                         | `await box.put('econ:coins', v)`                                         |
| `prefs.setInt('jigsaw_stat_total_pieces_snapped', v)`             | `await box.put('stat:totalPiecesSnapped', v)`                            |
| `prefs.setBool('jigsaw_setting_sound', v)`                        | **不变**                                                                   |

> **每日挑战无映射行（v4.5）**：现状无 `jigsaw_daily_{date}` 读写（不存在该 key），每日进度本就走 `ProgressStore`（`jigsaw_progress_v3_daily_*`），随首两行映射一并迁移。

> `app-state-v1` 全为原生类型，`put`/`get` 直接传标量，**无** **`jsonEncode`/`jsonDecode`**（区别于对象型 box）。

### 聚合缓存：保持内存

**结论**：不落盘派生聚合值（`_cachedDistinct3Star` / `_cachedTotalSolved` / `_cachedTotalStars`）。改造后 `getTotalPlayCount()`（`progress_store.dart:347`，现状每次实时 `loadAllProgress()` 遍历求和，**必须重写**为 `return _index.values.fold(0, (s, p) => s + p.totalPlayCount);`——v4.6 点名，否则遗留 O(N) 全量 jsonDecode）与各 `get` 聚合改走内存索引；`refreshAggregatesCache()` 同理遍历 `_index` 而非 `loadAllProgress()`。

**v4 修正后的理由**（此前论据有误，先澄清现状）：

- 现状**并无** `cachedTotalPlayCount` 这个落盘/缓存值；`getTotalPlayCount()` 是每次实时 `loadAllProgress()` 遍历求和，本就不落盘。

- 现状 `refreshAggregatesCache()` 在 `init()`（`progress_store.dart:182-186`）每次启动都全量重算，即使有内存缓存脏值也**只存活于单次会话**，重启即自愈——不存在「脏值跨重启存活」。

重写动机：

1. **纯派生、可重算**：这几个值是 `_index` 的纯函数，遍历内存对象即可得到，无需持久化，也不引入任何一致性维护成本（不存在「写 A 忘写 B」的双写快照失配）。
2. **读侧路径统一**：改造后 `progress` 域已有全量内存索引，`getTotalPlayCount()` 从「每次全量 `loadAllProgress`（解码）」变为「遍历内存对象」，避免每次聚合都重复 `jsonDecode`。
3. **不做条件刷新的持久化快照**：`refreshAggregatesCache()` 目前只在「通关或顶层 stars 提升」时触发（`progress_store.dart:523-526`，v4.6 校正行号），是为避免高频 O(N) 扫描而设计的**条件刷新**。一旦把其产物落盘，落盘值严格依赖刷新条件是否触发，任何漏触发都会让**落盘值长期失准且无法自愈**——这是比内存缓存更危险的一致性问题。保持内存缓存 + 重启重算，天然规避。

> **行号复核（v4 备注；v4.6 已批量校正）**：本文档引用行号以 2026-09-02 工作区为准（`game_repository.dart:104`、`progress_store.dart:347/:523-526` 等），实施前仍需以当前分支实际代码复核，防止行号漂移。

***

## 九、依赖

```yaml
dependencies:
  hive_ce: ^2.19.3          # 已确认存在，pub.dev 最新
  # path_provider: ^2.1.6   # 已有依赖，getApplicationSupportDirectory 用
```

**不引入** **`hive_ce_flutter`（v4.2）**：它只提供 `initFlutter()`（默认落 `{appDoc}`，见 §7.1 不采用的理由）与 Color/TimeOfDay 适配器（本工程不存这些类型）。§7.1 的 `_ensureHiveInit()` 直接用 hive\_ce 核心的 `Hive.init(path)` + `path_provider`，`Box.flush()/close()/deleteBoxFromDisk()` 等全部来自 hive\_ce 核心，零 Flutter 侧桥接需求。

不需要 `hive_ce_generator` / `build_runner`：progress/collections 存 JSON String，app-state 存原生标量，均无 TypeAdapter，零代码生成。

***

## 十、测试策略

### 10.1 影响面

实测 `test/` 下 **28 个测试文件中，13 个文件**直接或间接依赖 SharedPreferences，均需改造成 Hive。

### 10.2 基建（并行安全）

> **并行污染风险（v4 修订；v4.6 机理更正）**：`flutter test` 的并发是 **isolate 级隔离**（`--concurrency` 下每个测试文件独立 isolate，静态 `HiveImpl` 不共享），跨文件串写不会发生；真实风险是**同一测试文件内多个 test() 共享同一 isolate 的全局单例**——前者 `Hive.init` 被后者的目录覆盖、`Hive.deleteFromDisk()` 误删他测数据。**必须让每个测试拥有独立数据目录与独立 box 实例**。

```dart
// test/test_helper.dart —— 每个测试独立目录 + mock 单例（v4.3，替换 v4.2 不可编译的
// StorageManager.forDirectory —— 该构造从未在 §7.1 定义过）
Future<StorageManager> initTestStorage() async {
  final dir = await Directory.systemTemp.createTemp('jigsaw_test_');
  final sm = StorageManager.forTest(dir.path); // §7.1 定义的测试构造
  StorageManager.setMockInstance(sm);          // 替换全局单例，隔离被测代码
  await sm.openAll();                          // forTest 已 Hive.init，不会再触
                                               // getApplicationSupportDirectory()
  return sm;
}

Future<void> tearDownTestStorage(StorageManager sm) async {
  await Hive.deleteFromDisk();    // 关闭并删除当前所有打开的 box（须在 close 之前调，
                                  // close 后再调是 no-op）
  // v4.6：物理删除临时目录——若测试内验证过 closeAll()（如往返测试），
  // _boxes 已空、deleteFromDisk 是 no-op，不删目录会永久滞留系统临时文件夹
  final home = sm.homePathForTest;
  if (home != null) {
    final dir = Directory(home);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {} // best-effort
  }
  sm.resetForTest();              // 置空引用 + _hiveReady=false + 清 _homePathOverride
}
```

- `StorageManager` 构造时可注入目录与 box，测试环境不依赖全局单例（见 §7.1）。

- 若确有组件强依赖 `instance` 单例，则在 `setUp` 串行 `StorageManager.instance.resetForTest()` 置空 3 个 box 引用后再 `openAll()`（**#16**），不允许多测试共用一个 box 目录。

- 生产与测试统一走 `Hive.init(path)`（§7.1 不再使用 `initFlutter`，其 PlatformChannel 依赖在 `flutter test` 下本就会抛异常）：测试传 `Directory.systemTemp` 临时目录，生产传 `{appSupport}/hive_data`。`Hive.init` 可重复调用（直接覆盖 `homePath`，`hive_impl.dart:61`），但测试仍应每测独立目录 + `tearDown(Hive.deleteFromDisk)` 防串写。

### 10.3 强制用例

| 类别         | 用例                                                                                                                                                                 |
| :--------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 空数据        | prefs 设置空 → 正常初始化，box 为空                                                                                                                                           |
| 有数据        | 造齐改造后 4 个数据域（progress / collections / app-state / 保留设置）的数据 → 初始化后逐字段断言                                                                                             |
| **往返（强制）** | **写入 →** **`Hive.close()`** **→ 重新** **`openBox`** **→ 再读一遍校验**。唯一能暴露对象型 box JSON String 是否正确使用的手段，同会话测试会全绿                                                        |
| 原生类型       | 重启后 `econ:coins`/`ach:counter:*`/`stat:*` 等能按 `int`/`bool`/`String` 原样读出（无 `{"v":...}`，回归 §3.1）                                                                    |
| 排序         | collections 拆条后，素材按 `downloadedAt`、收藏按 `favoritedAt` 倒序（回归 §3.3）                                                                                                   |
| 样例初始化      | `custom:presetsInitialized=false` 时注入样例并置 true；删光后重启不重生成（回归 §4.4）；**`resetAllData()` 后样例重新植入（恢复出厂，现状行为一致，回归 §7.6 v4.5 声明）**                                                 |
| **主线水合**  | 写 `main:{NNN}` 进度 → 重启后 `_initLevels()` 静态生成 + `getLevelProgress` 回填 `isCompleted`/`stars` 等（回归 §7.3，v4.5）；**全库无 `jigsaw_level_` 读写残留**（回归 §2.3 删除项）                          |
| **重置语义**   | `resetAllData()` 后 box 清空、设置 key 保留（回归 §7.6 行为变更）、各 Store 内存重置、`ProgressStore` 聚合缓存刷新、**当前会话金币=100/券=5 不需重启**（starter 重发，v4.3）、`progressNotifier` 已广播（v4.3）                 |
| **经济默认值**  | `econ:coins`/`econ:hintCoupons` get 默认 0；starter 流程后为 100/5（回归 §4.3，防误用 `defaultValue:100`）                                                                        |
| key 处理     | 验证 `ach:starred:main:002` / `ach:starred:pack:nature:001` 按显式前缀匹配解析（cid 含冒号不击穿，禁止 split，v4.3）；`canonicalId` 缺失需跳过                                                    |
| 成就缓存加载    | 预置 `ach:*` 各类 key → `AchievementStore.init()` 一次性前缀扫描后 4 个内存缓存逐项断言（回归 §3.3/§4.3，v4.3）                                                                       |
| 自制进度水合     | 写 `ugc:{id}` 进度 → 重启后 `CustomPuzzleItem.isCompleted`/`progressPercent` 已回填；`deleteCustomPuzzle` 后 `ugc:{id}` 进度级联删除（回归 §7.3，v4.3）                                    |
| 违规防护       | `StorageManager` 未打开时非空 getter 抛 `StateError`（v4.3）；双 Store 不自行 open/delete（回归 §7.1）                                                                              |
| **损坏判定**   | `isCorruption`：`FormatException` 判损坏；非损坏 `HiveError`（如锁冲突模拟）仅重试不抛 `BoxCorruptException`、绝不删盘；损坏经 `openAll()` 内部恢复循环**静默自愈**、不向调用方抛异常（回归 §7.1/§7.2，v4.3）      |
| **备份/恢复**  | 启动备份在 Store init 前生成、目录内只有 3 个 `.hive` 无 `.lock`；**备份经 `.tmp` 目录 + 单次 rename 原子落位，恢复扫描跳过 `.tmp` 残留**（v4.3）；损坏 → `BoxCorruptException` → 只还原损坏 box、健康 box 数据不变；连续 2 份备份损坏 → 仅该 box 回落重建空 box（回归 §7.2/§7.8）；**双 box 同时损坏时各自从最新备份（tryIndex 0）开始恢复，不被前一 box 的重试次数污染**（v4.4，回归 §7.1 per-box 计数）；**兜底重建后跳过本轮备份，历史备份不被空箱覆盖**（v4.5，回归 §7.8 守卫）；**closeAll 前 flush，close 后无尾部丢写**（v4.5，回归 §7.1） |
| keys 迭代安全    | 在 `box.keys` 迭代中执行 delete 的写法不被允许（§5.4 约定）；失效过滤用例验证「先收集后批量删」无 `ConcurrentModificationError`、无漏删（v4.4）                                                                       |
| 重置物理清理     | `resetAllData()` 后 `{appSupport}/download_cache/` 下无残留 `mat_*.ext` 孤儿文件、缩略图缓存已清（回归 §7.6，v4.4）                                                                                              |
| 桌面生命周期     | `onExitRequested` 回调内完成 flush+backupNow 后返回 `AppExitResponse.exit`；`onHide`/`onInactive` 触发 `_handleBackgroundSync` 且 5 分钟节流生效（回归 §7.5，v4.3；桌面 `paused` 不触发，勿据其断言）      |

***

## 十一、实施阶段

| 阶段          | 范围                                                                                                                                                                                                                                                       | 验证                                               | 完成标准 DoD                                                                                                                                                           |
| :---------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :----------------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **准备**      | 加 Hive 依赖（仅 `hive_ce`，见 §9）；建 `StorageManager`（含 `_ensureHiveInit`/`forTest`/`setMockInstance`/非空 getter/`BoxCorruptException` + openAll 内聚恢复循环）+ `safeOpenBox` + `test_helper.dart`；实现 §7.8 备份/恢复基建（原子目录 `backupNow()` + 两阶段恢复）与 §7.5 `AppLifecycleListener`（桌面 onHide/onInactive/onExitRequested，持有引用防 GC）                                                                                  | `flutter analyze` / `flutter test` 基线通过          | 基线 0 新 error；3 个 box 可正常开/关；损坏判定/原子备份生成/两阶段恢复静默自愈用例通过                                                                    |
| **Phase 1** | `game-progress-v1`（progress + daily 进度）；**移除并删除** `MigrationService`（`game_repository.dart:104` 调用 + `migration_service.dart` 文件 + `migration_service_test.dart`——v4.6 从 Phase 3 提前：该测试直调 `ProgressStore.instance.init/save/load`，Phase 1 改造后必红，留着必阻塞「progress 相关测试通过」DoD）；**删除主线 `jigsaw_level_{i}` 整条读写路径**（`_initLevels`:149-160 读取分支 + `updateLevelProgress`:356/:454 两处 setString，改 ProgressStore 单路，v4.5 P0） | progress 相关测试通过；往返测试通过 | progress 域全部走 Hive；`grep -cE 'jigsaw_progress_v3|jigsaw_level_' lib/ test/` 计数为 0（v4.6：grep 用单引号免歧义；`jigsaw_level_` 是主线真实落盘源必须纳入，原 grep 漏查会假通过）；每日进度随迁自动完成，无独立项；往返测试通过；`flutter analyze` 0 error |
| **Phase 2** | `game-collections-v1`（custom + favorites + downloads，含前缀读入内存缓存 + 排序；`_initCustomPuzzles` 补 §7.3 ugc:{id} 水合；`deleteCustomPuzzle` 补级联删进度）                                                                                                                     | collections 相关测试通过                               | custom/favorite/material 前缀读入内存并按时序倒序；自制进度水合与级联删除用例通过；`custom:presetsInitialized` 用例通过；`grep jigsaw_custom_list / jigsaw_favorites_v1 / cached_downloaded_images_v1` = 0 命中        |
| **Phase 3** | `app-state-v1`（economy + achievements + stats + `custom:presetsInitialized`）；**新建** 5 个 reset()（`ProgressStore` + `EconomyService`/`AchievementStore`/`FavoriteStore`/`DownloadManager`，§7.6，现状均不存在）；`resetAllData()` 补齐内存重置（MigrationService 已在 Phase 1 删除，v4.6） | economy/achievement 测试通过 | app-state 原生类型读回正确；5 个 reset() 已新建且 `resetAllData()` 各单例内存已重置；`grep jigsaw_economy / jigsaw_achievement / jigsaw_stat` = 0 命中 |
| **清理**      | `git grep` 确认无残留 prefs 业务 key 读写；**移除 UI 层** **`savedSnapshotJson`** **fallback 死代码**（v4.6 修正为实际 3 处：home\_tab\_view\.dart:214、my\_puzzles\_tab\_view\.dart:202、game\_page\.dart:660——daily\_tab\_view 无此引用，原文为虚构；这些字段改造后恒为 null） | 全量 `flutter test` 通过                             | `grep -r jigsaw_ lib/` 仅剩 §2.1 保留的 7 个设置/UI key；`grep -r savedSnapshotJson lib/pages` 0 命中（或改为经 ProgressStore.canResume 判断）；全量测试绿；`flutter build windows debug` 通过 |

> 无存量数据，各 Phase 不共享旧数据格式，可独立落地、独立测试。
> **MigrationService（调用+文件+测试）v4.6 起整体在 Phase 1 删除**——其测试直调 ProgressStore，改造后必红；原「文件删除放 Phase 3」的安排会阻塞 Phase 1 的 DoD。

***

## 十二、容量估算

| 内容                 | 记录数（重度） | 单条      | 总量                |
| :----------------- | :------ | :------ | :---------------- |
| `game-progress-v1` | \~2000  | \~450 B | \~900 KB          |
| `custom:*`         | \~200   | \~200 B | \~40 KB           |
| `favorite:*`       | \~500   | \~230 B | \~115 KB          |
| `material:*`（下载素材） | 无上界     | \~300 B | 随下载量增长            |
| `app-state-v1`     | \~150   | \~20 B  | \~3 KB            |
| **合计**             | <br />  | <br />  | **\~1.1 MB + 素材** |

> 不再有 `daily-asset` 累积项（assetPath 不持久化）。当前实际规模远小于此：主线 100 + 每日 \~90 + 自制，约 200–300 条。

***

## 十三、风险

| 风险                    | 处置                                                                                                                                   |
| :-------------------- | :----------------------------------------------------------------------------------------------------------------------------------- |
| 对象型 box Map 退化        | progress/collections 存 JSON String 根除；§10.3 往返测试作回归防线                                                                                |
| `app-state` 类型误用      | 原生类型 + 专项用例回归（§10.3）                                                                                                                 |
| box 损坏                | `crashRecovery: true` 自动消化尾部坏帧；`isCorruption` 类型优先判定（§7.2）；`openAll()` 内聚恢复循环静默自愈（§7.1/§7.8），连续 2 份备份失败才重建空 box；非损坏（锁/I/O）重试不删盘 |
| 损坏检测消息漂移              | 字符串匹配仅作 `HiveError` 的兜底（类型优先已降险）；升级 hive\_ce 时回归 §10.3 损坏判定/备份恢复用例（§7.2）                                                             |
| 启动并发 open 竞争          | 统一 `StorageManager` 串行打开（§7.1）                                                                                                       |
| 未 await 导致丢写          | §7.4 表明确每类写入的 await 要求；§7.5 桌面 onHide/onInactive/onExitRequested 统一 flush + 备份（**Windows 桌面无 paused**，v4.3）                                    |
| 生命周期监听失效              | `AppLifecycleListener` 实例须顶层持有（防 GC 静默回收）；注册点唯一（`main()` 的 `runApp` 前），实施时专项自查（§7.5）                                                        |
| 隔离区                   | box 只在主 isolate；isolate 回调不碰 box（§7.7）                                                                                               |
| 备份半成品 / 句柄竞争          | `.tmp` 目录 + 单次 rename 原子落位，恢复只认 `backup-*`；损坏文件改名留证带 3 次重试消化 Windows 异步句柄关闭（§7.8，v4.3）                                                   |
| 多 box 同时损坏计数污染         | `openAll()` 恢复循环按 box 独立计数 `restoreTriesPerBox`，各 box 均从最新备份开始尝试（§7.1，v4.4）                                                                      |
| box.keys 迭代中 delete       | `box.keys` 是底层 SkipList 裸链表迭代器（无 CME 防护），迭代中 delete 属未定义行为；一律先收集后批量删（§5.4，v4.4；v4.6 论据更正）                                                              |
| **`jigsaw_level_` 残留双写**  | **v4.5 P0**：主线真实落盘源是 `jigsaw_level_{i}`（非 `jigsaw_progress_v3_*`）；Phase 1 必须整体删除该读写路径，DoD grep 已纳入（§11）；漏删 = 三副本变四副本且 DoD 假通过                  |
| 损坏异常类型穿透            | **v4.6**：`HiveError` 与 `FormatException`/`RangeError` 平级（Error vs Exception 体系）——safeOpenBox 用通用 catch + isCorruption 类型分流（§7.2）；瞬时 `FileSystemException` 重试后仍失败由 main 兜底 |
| `Hive.close()` 不 flush     | **v4.5**：`storage_backend_vm._closeInternal` 只 close RAF；`closeAll()` 先 `flushPendingWrites()`（逐 box try/catch）再 close（§7.1）；v4.6 `onExitRequested` 补 closeAll（§7.5）                                  |
| 兜底空箱覆盖备份              | **v4.5**：`_recreatedBoxes` 守卫——openAll 期间有 box 被兜底重建则跳过整轮备份 A，防止空箱轮转覆盖历史备份（§7.8）；**v4.6 守卫改一次性**（仅点 A），点 B 由 backupNow 文件大小自检，防「整会话新进度无备份」      |
| crashRecovery 静默截断        | **v4.6**：帧 CRC 坏不抛异常、被静默截断 → §7.8 不触发且截断快照污染轮转；可选 Logger 钩子守卫，否则接受 5 份轮转的容忍边界（§7.8 显式声明）                                                                      |
| 恢复路径自身故障              | **v4.6**：流水线解耦（quarantine 幂等/restore 仅复制/recreate 不 openBox），`deleteBoxFromDisk` 失败上抛 main 兜底，绝不死循环（§7.1）                                                                        |
| 备份/恢复失效               | 备份目录被清空/写失败 → **静默降级**不阻塞启动；恢复最多试最近 2 份、仅回滚损坏 box；均需日志留证（§7.8）；会话备份保证恢复点新鲜到最后会话（§7.5）                                                 |
| **SP 残留 key**         | 废弃的 `jigsaw_*` 业务 key（含 MigrationService 两标志，见 §一-前提声明）改造后不再读写，但会**永久留在 prefs 文件**（直至卸载或手动清理）；不构成功能问题，残留约几 KB，可作已知约定备注，无需迁移清理        |

***

## 附录：未决事项

1. `game-progress-v1` 是否引入 `openLazyBox` 或分片——当前规模不足，暂评估
2. compaction 触发阈值需实测后确定
3. `custom:presetsInitialized` 与「账号多端」假设无关；未来如需云同步再评估重置语义
4. **每日进度无界累积（v4 备注；v4.5 重写依据）**：每日内容由 `daily_content_pipeline.dart` 按月目录（`dailyStorageBaseDir/{yyyyMm}/`）管理，UI 只呈现管线当前覆盖的月份；超出覆盖窗口的旧 `daily:{YYYYMMDD}` 进度会**滞留在 box、UI 不可达**，长期游玩无界累积（v4.1 引用的 `kBingDailyAll`/`bing_daily_data.dart` 为虚构引用，已删）。可接受，但可评估按时间窗清理策略：`game-progress-v1` 引入 `daily:` 前缀按日期 < 某阈值批量 `box.delete`（先收集后批量删，§5.4；配合 compaction），作为可选的维护任务，首版可不做。
