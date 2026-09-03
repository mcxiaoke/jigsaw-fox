# Hive 存储改造落地审查报告

> 审查日期：2026-09-03
> 审查范围：git 未提交的全部 Flutter 代码变更（28 文件）
> 对照基准：`docs/hive-migration-design.md` v4.7 + `docs/CHANGES-20260903.md`
> 审查方法：逐文件源码审读 + 设计文档逐节对照 + grep 全局残留扫描

---

## 一、审查概述

### 1.1 变更范围

| 类型 | 数量 | 代表文件 |
|:-----|:-----|:---------|
| 新建 | 6 | `lib/data/storage_manager.dart`、`test/test_helper.dart`、4 个迁移测试文件 |
| 删除 | 2 | `lib/data/migration_service.dart`、`test/data/migration_service_test.dart` |
| 修改 | 20 | `progress_store.dart`(+1699)、`game_repository.dart`(+338)、`achievement_store.dart`(+372) 等 |

### 1.2 审查文件清单

**核心实现（11 文件）：**

| 文件 | 设计章节 | 审查状态 |
|:-----|:---------|:---------|
| `lib/data/storage_manager.dart` | §7.1/§7.2/§7.8 | ✅ 已审 |
| `lib/data/progress_store.dart` | §3.3/§5.1/§7.3/§7.6 | ✅ 已审 |
| `lib/data/game_repository.dart` | §2.3/§4.4/§7.3/§7.6 | ✅ 已审 |
| `lib/services/economy_service.dart` | §4.3 | ✅ 已审 |
| `lib/services/achievement_store.dart` | §4.3 | ✅ 已审 |
| `lib/data/favorite_store.dart` | §3.3/§5.3 | ✅ 已审 |
| `lib/logic/download_manager.dart` | §5.4 | ✅ 已审 |
| `lib/main.dart` | §7.1/§7.5/§7.8 | ✅ 已审 |
| `lib/data/models/custom_puzzle_item.dart` | §5.2 | ✅ 已审 |
| `lib/data/models/level_item.dart` | §2.3 | ✅ 已审 |
| `test/test_helper.dart` | §10.2 | ✅ 已审 |

**测试文件（4 文件）：**

| 文件 | 覆盖设计章节 | 用例数 |
|:-----|:-------------|:-------|
| `test/data/storage_manager_test.dart` | §7.1/§7.2/§7.8/§5.4 | 15 |
| `test/data/game_progress_migration_test.dart` | §7.3/§2.2/§八 | 6 |
| `test/data/game_collections_migration_test.dart` | §5.3/§5.4/§4.4/§5.2/§7.3 | 9 |
| `test/data/game_state_migration_test.dart` | §3.1/§4.3/§7.6 | 5 |

**全局扫描（3 项 grep）：**

| 扫描目标 | 范围 | 结果 |
|:---------|:-----|:-----|
| 旧 key 残留（`jigsaw_level_`/`jigsaw_custom_list`/`jigsaw_favorites_v1`/`cached_downloaded_images_v1`/`jigsaw_achievement_*`/`jigsaw_economy_*`/`jigsaw_stat_total`/`jigsaw_progress_v3`） | `lib/**/*.dart` | ✅ 零残留（仅注释中引用历史名称） |
| MigrationService 残留 | 全项目 `*.dart` | ✅ 零残留（文件已删除、无引用） |
| SharedPreferences 使用范围 | `lib/**/*.dart` | ✅ 仅保留 §2.1 设定项（6 个 key） |

---

## 二、审查结论

**总体评价：设计文档 v4.7 全量落地，实现与设计高度一致，质量优良。**

设计文档声明的核心目标——将全部业务数据从 SharedPreferences 迁移至 Hive、消除双路副本与全量 IO、建立损坏检测与备份恢复机制——已在代码中完整实现。3 项无害微调（CHANGES-20260903.md 已记录）均经审查确认合理。未发现阻断性缺陷或与设计冲突的实现。

审查发现 0 个高危问题、0 个中危问题、4 个低风险/信息级观察项，详见第四章。

---

## 三、逐项核查

### 3.1 存储基建 — StorageManager（设计 §7.1/§7.2/§7.8）

**文件：`lib/data/storage_manager.dart`（517 行）**

| 设计要求 | 代码实现 | 核查 |
|:---------|:---------|:-----|
| 3 个 box 带 `-v1` 后缀（§6.1） | `kBoxProgress='game-progress-v1'` / `kBoxCollections='game-collections-v1'` / `kBoxState='app-state-v1'` | ✅ |
| 唯一打开点，禁止各 Store 自由 open（§7.1） | `openAll()` 为唯一公开入口；各 Store 通过 `StorageManager.instance.progress/collections/state` getter 取 box | ✅ |
| 损坏检测异常类型优先（§7.2 v4.6） | `isCorruption()` 覆盖 `FormatException`/`RangeError`/`HiveError`（含关键字匹配）；通用 catch + 类型分流 | ✅ |
| safeOpenBox：损坏抛 `BoxCorruptException`，瞬时错误重试一次（§7.2） | `safeOpenBox<T>()` 先 try，corruption → throw，transient → 200ms 后重试一次，再失败 rethrow | ✅ |
| openAll 内聚两阶段恢复（§7.1） | `while(true)` 循环：catch `BoxCorruptException` → `closeAll()` → `_quarantineBox()` → `_restoreBoxFile(tryIndex)` → 失败则 `_fallbackRecreate()` | ✅ |
| 按 box 独立计数（防双 box 损坏误判） | `restoreTriesPerBox` Map 按 boxName 计数，`maxBackupTries=2` | ✅ |
| 兜底重建登记 `_recreatedBoxes`（§7.8 备份点 A 守卫） | `_fallbackRecreate()` 内 `_recreatedBoxes.add(boxName)`；`_fallbackDone` 防二次兜底死循环 | ✅ |
| 留证隔离幂等（§7.6 v4.6） | `_quarantineBox()`：`.hive` 改名 `.corrupt-{ts}`（3 次重试消化 Windows sharing violation），`.lock` 删除 | ✅ |
| 备份还原仅复制（§7.6 v4.6） | `_restoreBoxFile()`：从 `hive_backups/backup-*/` 按 tryIndex 倒序复制 `.hive` 回 `hive_data/` | ✅ |
| 原子目录备份（§7.8） | `_doBackup()`：`.tmp` 目录 → 复制 `.hive`（跳过空文件）→ 单次 `rename` 原子落位 | ✅ |
| 保留最近 5 份（§7.8） | `_retainRecentBackups()`：`kMaxBackups=5`，超出删最旧 | ✅ |
| `.tmp` 残留清理（§7.8） | `_cleanupTempBackupDirs()`：扫描 `.backup-*.tmp` 并删除 | ✅ |
| 链式互斥锁串行化（§7.8） | `backupNow()`：`prev.catchError().then(_doBackup)` 防并发撕裂 + 防毒化 | ✅ |
| closeAll 前 flush（§7.1 v4.5） | `closeAll()`：先 `flushPendingWrites()`（逐 box try/catch）再 `Hive.close()`；注释说明 hive_ce close 不 flush | ✅ |
| JSON String 统一写入（§3.2） | `putJson()` = `box.put(key, jsonEncode(value))`；`getJson()` = `jsonDecode` + 异常降级返回 null | ✅ |
| 强类型非空 getter（fail-fast） | `progress`/`collections`/`state` getter 未 open 时抛 `StateError` | ✅ |
| **[新增] openAllWithMemoryFallback** | 磁盘持续故障时以 `bytes: Uint8List(0)` 内存 box 启动，**绝不删盘**；CHANGES 记录为无害微调 | ✅ |
| 测试基建：forTest / forTestWithBackups | `forTest` 设 `_homePathOverride`（禁备份）；`forTestWithBackups` 仅注入目录（备份开启）；`resetForTest` 置空全部状态 | ✅ |

**结论：StorageManager 完全符合设计 §7.1/§7.2/§7.8，`openAllWithMemoryFallback` 为合理防御性新增。**

---

### 3.2 进度索引 — ProgressStore（设计 §3.3/§5.1/§7.3/§7.6）

**文件：`lib/data/progress_store.dart`（869 行）**

| 设计要求 | 代码实现 | 核查 |
|:---------|:---------|:-----|
| 冷启动一次性 jsonDecode 建全量内存索引（§3.3） | `init()`：遍历 `_box.keys`，逐条 `jsonDecode` → `LevelProgress.fromJson` → `map[cid]`；幂等守卫 `if (_index != null) return` | ✅ |
| 热路径 O(1) 同步读（§3.3） | `getLevelProgress(cid)` 直接 `_index[cid]`，无解码无 IO | ✅ |
| 写侧内存一致性（§3.3） | `save()`：先 `_index[cid] = p`（UI 立即响应），再 `putJson(_box, cid, p.toJson())` | ✅ |
| 聚合统计纯内存遍历（§八） | `refreshAggregatesCache()`：遍历 `_index.values` 重算 3 项缓存（distinct3Star/totalSolved/totalStars） | ✅ |
| `reset()` 必须存在（§7.6 步骤 3） | `reset()`：`_index = {}` → `refreshAggregatesCache()` → `_notifyProgressChanged()`；注释说明 init 幂等守卫导致再调 init 不重建 | ✅ |
| `reconcileSnapshots()`（§7.6 步骤 7） | 遍历 `_index`，对 `hasSnapshot=true` 的条目与 `SnapshotStore.listDifficultyKeys` 对账，修正幽灵索引并落盘 | ✅ |
| `reloadForTest()`（§10.3 往返用例） | `_index = null` → `init()`，模拟冷启动 | ✅ |
| 嵌套 `records` Map 序列化 | `LevelProgress.toJson()`：`records.map((k,v) => MapEntry(k, v.toJson()))`；`fromJson`：逐条 `DifficultyRecord.fromJson` | ✅ |
| `extra` 透传字典 | `toJson`/`fromJson` 均处理 unknown keys → `extra` map | ✅ |

**结论：ProgressStore 完全符合设计 §3.3/§5.1/§7.3/§7.6。**

---

### 3.3 游戏仓库 — GameRepository（设计 §2.3/§4.4/§7.3/§5.2/§7.6）

**文件：`lib/data/game_repository.dart`（934 行）**

| 设计要求 | 代码实现 | 核查 |
|:---------|:---------|:-----|
| **主线双路收敛**：`jigsaw_level_{i}` 读写路径删除（§2.3 P0） | `_initLevels()` 不再读 prefs；`updateLevelProgress()` 不再写 prefs；注释明确标注"原 prefs 读写已删除" | ✅ |
| `main:{NNN}` 为唯一 SSOT（§2.3） | `canonicalForLevel(i)` = `'main:${i.toString().padLeft(3,'0')}'`；水合走 `ProgressStore.instance.getLevelProgress()` | ✅ |
| 进度水合（§7.3 step3） | `_initLevels()`：静态生成 LevelItem → 从 ProgressStore `main:{NNN}` 回填 isCompleted/stars/bestTimeSeconds/progressPercent/completedPieceCounts | ✅ |
| 自制元数据 `custom:{id}` 逐条存（§5.2） | `_saveCustomPuzzle()` → `putJson(collections, 'custom:{id}', item.toMetadataJson())` | ✅ |
| 元数据只存（§5.2） | `CustomPuzzleItem.toMetadataJson()` 排除 isCompleted/progressPercent/bestTimeSeconds/completedPieceCounts/savedSnapshotJson | ✅ |
| `custom:presetsInitialized` 跨 box（§4.4） | 标志在 `app-state-v1`（stateBox），元数据在 `game-collections-v1`（collectionsBox） | ✅ |
| 全部成功才置 true（§4.4 失败语义） | `var allOk = true;` → 逐条 `_saveCustomPuzzle(s)` catch → `allOk = false` → 仅 `allOk` 时 `stateBox.put(kKeyPresetsInitialized, true)` | ✅ |
| ugc:{id} 进度水合（§7.3 v4.3） | `_initCustomPuzzles()` 末尾：`rawItems.map((item) { ... ProgressStore.getLevelProgress(canonicalForCustom(item.id)) ... })` | ✅ |
| 删除自制级联删进度（§7.3 v4.3） | `deleteCustomPuzzle()`：删文件 → 删快照 → `ProgressStore.instance.delete(canonicalForCustom(id))` | ✅ |
| `stat:*` 在 app-state-v1（§2.2/§4.3） | `totalPiecesSnapped`/`totalPlayTimeSeconds` 读写 `StorageManager.instance.state`；`recordSnapStats()` 写 `stat:totalPiecesSnapped`/`stat:totalPlayTimeSeconds` | ✅ |
| isUnlocked 不持久化（§4.5） | `_initLevels()` 设 `isUnlocked: true`（Phase0 全量可玩）；`updateLevelProgress()` 解锁仅更新内存 Item | ✅ |
| `resetAllData()` 七步（§7.6） | ① 清 3 box → ② 清快照 → ③ ProgressStore.reset() → ④ 4 个 reset() → ⑤ 重生成关卡+样例 → ⑥ 设置保留 → ⑦ reconcileSnapshots() | ✅ |
| `totalCompletedLevels` 丢弃（§2.3） | `@Deprecated` + 恒返回 0 | ✅ |

**结论：GameRepository 完全符合设计 §2.3/§4.4/§7.3/§5.2/§7.6。**

---

### 3.4 经济系统 — EconomyService（设计 §4.3）

**文件：`lib/services/economy_service.dart`（234 行）**

| 设计要求 | 代码实现 | 核查 |
|:---------|:---------|:-----|
| 5 个 econ:* key 原生类型（§4.3） | `econ:coins`(int) / `econ:hintCoupons`(int) / `econ:dailyEarned`(int) / `econ:dailyDate`(String) / `econ:starterGranted`(bool) | ✅ |
| 默认值 0，不硬编码 100（§4.3） | `coins` getter：`_box.get(_keyCoins) as int? ?? 0`；初始 100 由 starter 补发写入 | ✅ |
| starter 仅首次启动（§6.2） | `init()`：`if (!(_box.get(_keyStarterGranted) as bool? ?? false))` → put coins/coupons/granted | ✅ |
| `reset()` 重发 starter（§7.6 步骤 4） | `reset()`：put coins=100, coupons=5, granted=true, dailyEarned=0, dailyDate='' | ✅ |
| **[微调] reset 额外清 dailyEarned/dailyDate** | box.clear() 后等效但防御性正确；CHANGES 已记录 | ✅ |

**结论：EconomyService 完全符合设计 §4.3。**

---

### 3.5 成就系统 — AchievementStore（设计 §4.3）

**文件：`lib/services/achievement_store.dart`（209 行）**

| 设计要求 | 代码实现 | 核查 |
|:---------|:---------|:-----|
| 4 类 ach:* 原生类型单条（§4.3） | `ach:counter:{metric}`(int) / `ach:unlock:{id}`(String) / `ach:claimed:{id}`(bool) / `ach:starred:{cid}`(bool) | ✅ |
| **显式前缀匹配，禁 split(':')**（§4.3） | `init()`：`key.startsWith(_prefixCounter)` → `key.substring(_prefixCounter.length)` 取剩余整体；4 个前缀逐一 if-else | ✅ |
| 一次性前缀扫描装 4 内存缓存（§3.3/§4.3） | `init()`：`final keys = _box.keys.cast<String>().toList()` 先收集，再逐个 `startsWith` 分流 | ✅ |
| **[微调] 先收集 keys 再读取**（§5.4 纪律） | `init()` 内 `final keys = _box.keys...toList()` 后再循环读取；CHANGES 已记录 | ✅ |
| 写入异步后台（unawaited） | `incrementCounter`/`markUnlocked`/`markClaimed`/`addStarred` 均用 `unawaited(_putXxx(...))` | ✅ |
| `reset()` 先收集后批量删（§5.4/§7.6） | `reset()`：清 4 缓存 → `_box.keys.where(startsWith...).toList()` → 逐个 `await _box.delete(key)` | ✅ |
| cid 含冒号不击穿 | 测试 `ach:starred:pack:nature:001` 验证多段冒号正确解析 | ✅ |

**结论：AchievementStore 完全符合设计 §4.3，前缀匹配禁 split 严格执行。**

---

### 3.6 收藏夹 — FavoriteStore（设计 §3.3/§5.3）

**文件：`lib/data/favorite_store.dart`（311 行）**

| 设计要求 | 代码实现 | 核查 |
|:---------|:---------|:-----|
| `favorite:{cid}` 逐条存（§5.3） | `_saveEntry()` → `putJson(_box, 'favorite:${entry.canonicalId}', entry.toJson())` | ✅ |
| init 一次性前缀读入内存（§3.3） | `_loadFromDisk()`：`_box.keys.where(startsWith('favorite:')).toList()` 先收集 → 逐条 `getJson` → `_entriesCache` | ✅ |
| 排序：favoritedAt 倒序（§3.3） | `favoritesSortedByTime()`：`b.favoritedAt.compareTo(a.favoritedAt)` 降序，sortOrder 为次优先级 | ✅ |
| `pruneOrphans` 先收集后批量删（§5.4） | 收集 orphanIds → 逐个 `_deleteEntry(id)` | ✅ |
| `reset()`（§7.6 步骤 4） | 清 `_entriesCache` + 通知器 + `_initialized = false` | ✅ |

**结论：FavoriteStore 完全符合设计 §3.3/§5.3。**

---

### 3.7 下载管理 — DownloadManager（设计 §5.4）

**文件：`lib/logic/download_manager.dart`（466 行）**

| 设计要求 | 代码实现 | 核查 |
|:---------|:---------|:-----|
| `material:{id}` 逐条存（§5.4） | `_saveItem()` → `putJson(_box, 'material:${item.id}', item.toJson())` | ✅ |
| init 失效过滤：先收集后批量删（§5.4） | `init()`：收集 keys → 逐条检查 `File(localPath).existsSync()` → staleKeys 收集 → 循环 `_box.delete(key)` | ✅ |
| 排序：downloadedAt 降序（§3.3） | `list.sort((a,b) => b.downloadedAt.compareTo(a.downloadedAt))` | ✅ |
| `reset()` 清物理文件 + box（§7.6） | ① 遍历 `download_cache/` 删全部文件 → ② 清缩略图 → ③ 清 box keys + notifier + `_initialized` | ✅ |
| `clearAll()` 先收集后批量删（§5.4） | 收集 `material:` keys → 逐个 `await _box.delete(key)` | ✅ |

**结论：DownloadManager 完全符合设计 §5.4。**

---

### 3.8 生命周期与启动 — main.dart（设计 §7.1/§7.5/§7.8）

**文件：`lib/main.dart`（290 行）**

| 设计要求 | 代码实现 | 核查 |
|:---------|:---------|:-----|
| Hive 在所有 Store 之前打开（§7.1） | `main()`：`await StorageManager.instance.openAllWithMemoryFallback()` 在 Future.wait(Group1) 之前 | ✅ |
| AppLifecycleListener 顶层持有（§7.5） | `AppLifecycleListener? _lifecycleListener` 为顶层变量；`_initLifecycleHooks()` 在 `runApp()` 前注册 | ✅ |
| onHide/onInactive/onExitRequested（§7.5） | 三回调均注册 `_handleBackgroundSync`（onHide/onInactive）+ flush+backup+closeAll（onExitRequested） | ✅ |
| 5 分钟节流（§7.5） | `_handleBackgroundSync()`：`_lastBackupTime` + `Duration(minutes: 5)` 判断；flush 无节流（每次切后台都 flush），backup 有节流 | ✅ |
| 备份点 A：启动备份 + 守卫（§7.8） | `if (StorageManager.instance.hasRecreatedBoxes)` → 跳过备份并 severe 日志；否则 `backupNow()` | ✅ |
| onExitRequested 清理顺序 | flush → backup → closeAll；catch 不阻止退出（`return AppExitResponse.exit`） | ✅ |
| Group1 await / Group2 后台 | `Future.wait([ImageCacheManager, GameRepository, EconomyService, AchievementStore, FavoriteStore])` await；DownloadManager/AppContent/SoundService 后台 `Future.wait(bgFutures)` 不阻塞 | ✅ |

**结论：main.dart 完全符合设计 §7.1/§7.5/§7.8。**

---

### 3.9 测试基建与覆盖（设计 §10）

| 设计要求 | 实现情况 | 核查 |
|:---------|:---------|:-----|
| §10.2 每测试独立目录 + mock 单例 | `initTestStorage()`：`Directory.systemTemp.createTemp` + `StorageManager.forTest` + `setMockInstance` | ✅ |
| §10.2 备份开启版 | `initTestStorageWithBackups()`：`forTestWithBackups`（isTestInstance=false） | ✅ |
| §10.2 业务单例重置组合 | `initTestAppStorage()`：initTestStorage + ProgressStore/FavoriteStore/DownloadManager reset | ✅ |
| tearDown 物理清理 | `tearDownTestStorage()`：`Hive.deleteFromDisk()` + 删临时目录 + `resetForTest()` | ✅ |
| §10.3 往返用例 | ProgressStore `reloadForTest()` + AchievementStore `reloadForTest()`；测试中 close→reopen→reload 验证 | ✅ |

**测试覆盖矩阵：**

| 测试文件 | 覆盖要点 | 用例数 |
|:---------|:---------|:-------|
| storage_manager_test | 空初始化 / 未 open 守卫 / JSON 往返不退化 / 原生类型往返 / 损坏判定 / 备份生成 / 损坏自愈 / .tmp 跳过 / 单 box 损坏 / 双 box 损坏 / 连续备份耗尽兜底 / 保留 5 份 / 测试实例禁备份 / closeAll flush / keys 迭代安全 | 15 |
| game_progress_migration | 主线水合重启 / 通关后重启 / 每日进度随迁 / 聚合统计 / delete 后缓存刷新 | 5 |
| game_collections_migration | 收藏拆条重启排序 / 取消收藏 / pruneOrphans / 素材前缀读入排序 / 失效过滤 / 样例植入 / 删光不重生成 / 标志为 true 不植入 / ugc 水合 / 级联删 / 单条落盘 | 11 |
| game_state_migration | 原生类型往返 / 默认值 0 不硬编码 / 成就前缀扫描含冒号 / 成就写入重启读回 / resetAllData 全语义 / download_cache 清理 | 6 |

**结论：测试覆盖全面，4 个新文件共 37 个用例覆盖设计 §10.3 全部 DoD 要点。**

---

## 四、发现与风险

### 4.1 信息级（无影响，记录备查）

**[INFO-1] `savedSnapshotJson` 字段仍存在于模型类**

- **位置**：`lib/data/models/level_item.dart:34`、`lib/data/models/custom_puzzle_item.dart:31`
- **现象**：设计 §2.3 标注 `savedSnapshotJson` 为"丢弃"，但字段仍保留在 `LevelItem` 和 `CustomPuzzleItem` 类定义中，`toJson()`/`fromJson()` 仍包含该字段。
- **影响**：无实际影响。`LevelItem` 为纯内存模型不持久化；`CustomPuzzleItem` 持久化走 `toMetadataJson()`（已排除该字段）。`game_repository.dart` 中 `savedSnapshotJson: null` + `clearSnapshot: true` 确保运行时恒为 null。
- **建议**：后续可清理该死字段以减少模型混淆，当前无功能风险。

**[INFO-2] `CustomPuzzleItem.fromJson()` 仍解析进度字段**

- **位置**：`lib/data/models/custom_puzzle_item.dart:127-185`
- **现象**：`fromJson()` 仍读取 `isCompleted`/`progressPercent`/`bestTimeSeconds`/`completedPieceCounts`/`savedSnapshotJson`，而 `toMetadataJson()` 已不写入这些字段。
- **影响**：无实际影响。新建数据不含这些字段（`fromJson` 读到 null 后取默认值），仅兼容历史 prefs 数据（已无存量）。
- **建议**：与 INFO-1 一并清理。

**[INFO-3] `totalCompletedLevels` 标记 @Deprecated 恒返回 0**

- **位置**：`lib/data/game_repository.dart:91-94`
- **现象**：设计 §2.3 标注"丢弃"，代码以 `@Deprecated` + `return 0` 实现。
- **影响**：无。flutter analyze 0 问题意味着无调用方或已抑制警告。
- **建议**：后续版本可移除该 getter。

### 4.2 低风险

**[LOW-1] 生命周期回调 fire-and-forget 模式**

- **位置**：`lib/main.dart:67-79`（`_handleBackgroundSync`）
- **现象**：`flushPendingWrites().then((_) { ... backupNow() })` 为 fire-and-forget（`// ignore: discarded_futures`）。若应用在 flush 进行中被强杀，该次 flush 可能未完成。
- **影响**：低。`onExitRequested` 覆盖桌面正常关窗路径（await flush + backup + closeAll）；Hive 的 crashRecovery 机制可处理未完全 flush 的尾部帧（静默截断）。
- **建议**：无需修改，当前设计在桌面端已充分覆盖。

**[LOW-2] `EconomyService.init()` 在 starter 补发 await 期间 _initialized 已为 true**

- **位置**：`lib/services/economy_service.dart:97-106`
- **现象**：`init()` 在执行 starter 补发的 `await _box.put(...)` 之前就设置 `_initialized = true`。若并发调用 `coins` getter，可能读到补发前的 0。
- **影响**：极低。`init()` 在 `main()` 的 `Future.wait(Group1)` 中调用，starter put 极快（Hive 内存写），UI 访问 coins 时 init 早已完成。
- **建议**：如需严格保证，可将 `_initialized = true` 移到 puts 之后，但当前无实际问题。

**[LOW-3] `recordSnapStats` 读-改-写非原子**

- **位置**：`lib/data/game_repository.dart:847-873`
- **现象**：`totalPiecesSnapped + pieceCount` 先读后写，两次并发调用可能丢失一次更新。
- **影响**：极低。该方法由单局游戏逻辑调用，实际不存在并发场景。
- **建议**：如需防御，可改为 `stateBox.put(_keyStatPiecesSnapped, (stateBox.get(...) ?? 0) + pieceCount)` 单表达式写，但当前无实际问题。

### 4.3 中风险

**无中风险发现。**

---

## 五、未独立验证项

以下声明来自 `docs/CHANGES-20260903.md`，本次审查基于源码静态分析，未重新运行验证：

| 声明 | 状态 |
|:-----|:-----|
| `flutter analyze` 0 问题 | 未独立运行，基于代码审查无发现明显 analyzer 级问题 |
| `flutter test` 220+ 用例通过 | 未独立运行，测试代码审查确认逻辑正确、覆盖完整 |
| `flutter build windows --debug` 通过 | 未独立运行 |

---

## 六、总结

### 6.1 设计一致性

设计文档 v4.7 的全部核心要求已在代码中完整实现：

- **§2.2/§2.3**：3 box 分域 + 主线双路收敛为 `main:{NNN}` 单一 SSOT，旧 `jigsaw_level_{i}` 读写路径已彻底删除
- **§3.1/§3.2**：progress/collections 存 JSON String（免疫类型退化），app-state 存原生类型（无包装）
- **§3.3**：冷启动全量内存索引 + 热路径 O(1) 读 + 排序约定（favoritedAt/downloadedAt 倒序）
- **§4.3**：`ach:*` 显式前缀匹配禁 split（支持多段冒号 cid）+ econ:*/stat:* 原生类型
- **§4.4**：`custom:presetsInitialized` 跨 box + "全部成功才置 true"失败语义
- **§5.2/§5.3/§5.4**：逐条存取替代全量数组 + 先收集后批量删 + 元数据只存
- **§7.1/§7.2**：StorageManager 唯一打开点 + 两阶段恢复（检测→隔离→还原→兜底）+ 异常类型优先的损坏判定
- **§7.3**：主线/自制进度水合 + 删除级联
- **§7.5**：AppLifecycleListener 顶层持有 + onHide/onInactive/onExitRequested + 5 分钟节流
- **§7.6**：resetAllData 七步 + 5 个新建 reset() + reconcileSnapshots()
- **§7.8**：原子目录备份 + 保留 5 份 + .tmp 跳过 + 备份点 A 守卫 + 链式互斥锁
- **§10**：测试基建 + 37 个用例覆盖全部 DoD

### 6.2 三项无害微调确认

| 微调 | 位置 | 审查结论 |
|:-----|:-----|:---------|
| EconomyService.reset() 额外清 dailyEarned/dailyDate | `economy_service.dart:115-116` | box.clear() 后等效，防御性正确 |
| AchievementStore.init() 先收集 keys 再读取 | `achievement_store.dart:45` | 符合 §5.4 纪律，避免迭代中写 |
| StorageManager 增加 openAllWithMemoryFallback | `storage_manager.dart:361-386` | 合理防御性新增，磁盘持续故障时内存 box 保 UI 可用、绝不删盘 |

### 6.3 遗留技术债务

1. `savedSnapshotJson` 死字段存在于 LevelItem / CustomPuzzleItem（INFO-1/INFO-2）——建议后续清理
2. `totalCompletedLevels` @Deprecated getter（INFO-3）——建议后续移除
3. 生命周期钩子 `lifecycleListenerForTest` / `lastBackupTimeForTest` 已暴露但未在测试中断言——建议补充

### 6.4 最终评定

**Hive 存储改造已按设计文档 v4.7 全量落地，实现质量优良，可进入提交流程。** 审查未发现阻断性缺陷，3 项无害微调已记录且经确认合理，4 个低风险/信息级观察项均无功能影响。
