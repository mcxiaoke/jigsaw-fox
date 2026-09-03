# Hive 存储改造落地审查报告（v4.7）

> **审查日期**：2026-09-03  
> **审查分支**：`hive-store-dev`（Git Working Tree 未提交改动）  
> **审查基准**：[docs/hive-migration-design.md](hive-migration-design.md)（v4.7 设计文档）与 [docs/CHANGES-20260903.md](CHANGES-20260903.md)  
> **审查方法**：逐文件代码通读 + 设计文档逐条对照 + 客观命令复跑验证（analyze / test / build / format / DoD grep）  
> **审查性质**：独立、审慎、可复现。本报告所有量化结论均来自本次会话中实际执行的命令。

---

## 〇、总体结论

**改造已高质量落地，主体实现与设计文档 v4.7 保持高度一致，达到生产可用（Production Ready）标准，无阻断级或高级别缺陷。**

本次审查对设计文档的关键约束（3 Box 分层、主线双路收敛、原生类型 state box、对象型 box 防退化、`custom:presetsInitialized` 跨 box 全有或全无、`ach:*` 显式前缀匹配、`resetAllData` 七步、容灾自愈与两阶段备份、顶层生命周期监听、`box.keys` 先收集后删、测试隔离基建）逐一核验，确认均已正确实现。

客观指标三项（analyze 0 问题、220 用例通过、Windows debug 编译通过）经本会话**独立复跑全部为真**；DoD 旧 key 残留 grep 命中为 0（1 处为临时目录名误报）；`MigrationService` 已彻底删除且全仓无残留引用。

发现的问题均为**低级别（Low / 信息级）**，属工程健壮性打磨建议，均非阻塞项，详见第四节。

> **与既有报告的关系说明**：工作区已存在 `docs/hive-migration-audit-report-20260903.md`（正面结论、未附验证过程）。本报告不覆盖该文件，而是在独立复跑验证其三项核心指标均为真的基础上，补充其遗漏的低级别观察，形成可复现、带证据链的审查记录。

---

## 一、客观验证结果（本会话独立执行）

| 验证项 | 命令 | 结果 | 判定 |
| :--- | :--- | :--- | :---: |
| 静态分析 | `flutter analyze` | `No issues found! (ran in 6.3s)` | **PASS** |
| 全量测试 | `flutter test` | `All tests passed!` 末尾计数 `+220` | **PASS（220/220）** |
| 平台编译 | `flutter build windows --debug` | `√ Built build\windows\x64\runner\Debug\JigsawFox.exe` | **PASS** |
| 代码格式 | `dart format --set-exit-if-changed`（21 个已改 dart 文件） | `Formatted 21 files (0 changed)` | **PASS** |
| 旧 key 残留（设计 §11 DoD） | `grep -rn jigsaw_level_ / jigsaw_progress_v3 / jigsaw_custom_list / jigsaw_favorites_v1 / cached_downloaded_images_v1 / jigsaw_economy / jigsaw_achievement / jigsaw_stat lib/ test/` | 7 项 0 命中；`jigsaw_stat` 1 命中为 `createTemp('jigsaw_state_test_')` 误报（非 key） | **PASS** |
| 迁移服务删除 | `grep -rn MigrationService lib/` | 0 引用（文件已 `D`，无残留 import/调用） | **PASS** |

---

## 二、设计文档符合性核验（关键约束逐条）

### 2.1 SharedPreferences 边界清理（§2.1）
- 业务数据（进度/收藏/素材/自制定制/经济/成就/统计）已全部迁入 Hive。
- `game_repository.dart` 中仅保留 `_prefs` 用于 **7 个设置/UI key**（`soundEnabled`/`hapticEnabled`/`gridPreviewEnabled`/`pieceScatterMode`/`selectedBackground` 等），符合 §2.1 保留项。其余 `_prefs?.getInt/getString` 调用仅剩 2 处纯 UI 设置读取，无业务数据残留。
- 其他 SP 使用点（`daily_tab_view.dart`、`choose_difficulty_sheet.dart`）均属设置/UI 范畴，在保留范围内。

### 2.2 / 2.3 主线双路收敛 → `main:{NNN}` 单 SSOT
- 原 `jigsaw_level_{i}` 整条读写路径已删除（grep `jigsaw_level_` 命中 0）。
- `game_repository._initLevels()` 改为从 `ProgressStore.instance.getLevelProgress(canonicalForLevel(i))` 回填进度字段；`ProgressStore` 以 `_index` 内存索引 + `main:{NNN}` box key 为唯一真源。
- 累计通关数 `totalCompletedLevels` 原 prefs 累加 key 按 §2.3 丢弃，改为 `@Deprecated` 返回 0 的桩，SSOT 迁移至 `ProgressStore.instance.getTotalSolved()`（ProgressStore:324，已被 achievements/settings/achievement-service 使用，无孤立调用）。**属正确清理，非回归。**

### 2.4 原生类型 state box + 对象型 box 防退化
- `app-state-v1`（`state` box）存放 `econ:*` / `ach:*` / `stat:*` 原生 int/bool/String，无 `jsonEncode`。
- `game-progress-v1`（`progress` box）：`main:{NNN}` 存 JSON String。
- `game-collections-v1`（`collections` box）：`custom:*` / `favorite:*` / `material:*` 存 JSON String（根除 Map 退化）。
- Box 路由实测一致：`progress_store→progress`、`favorite_store→collections`、`game_repository(custom)→collections` + `game_repository(stat)→state`、`economy_service→state`、`achievement_store→state`、`download_manager→collections`。

### 2.5 `custom:presetsInitialized` 跨 box 全有或全无（§4.4）
- 标志存于 `state` box（`stateBox.put(kKeyPresetsInitialized, true)`，game_repository:261/267），内容 `custom:{id}` 存于 `collections` box —— 与设计"内容在 collections、标志在 state"一致。
- 逻辑：`presetsInitialized != true && rawItems.isEmpty` 才植入 3 个样例（全有或全无）；有历史数据但标志缺失时防御性补写。注释在 game_repository:44 明确标注"同前缀跨 box"，且 `custom:` 前缀过滤（`collectionsBox.keys.startsWith('custom:')`）不会误命中 state box 中的标志，无冲突。

### 2.6 经济默认 0 + 新手赠送（§4.3 / §6.2）
- `econ:coins` 默认 `0`：`coins => _initialized ? (_box.get(_keyCoins) as int? ?? 0) : 0`，**未使用 `defaultValue: 100`**（代码注释 economy_service:78-79 明确禁止）。
- 新手赠送由 `econ:starterGranted` 标志守卫，仅首次补发 100 金币 / 5 券，符合 §6.2。

### 2.7 `ach:*` 显式前缀匹配（§4.3）
- 代码注释（achievement_store:16）明确**禁止 `split(':')`**；`init()` 用 `startsWith(_prefixCounter/_prefixUnlock/_prefixClaimed/_prefixStarred)` 显式分流（achievement_store:48-59）。实测无 `split(':')` 调用。

### 2.8 排序约定（§3.3）
- 收藏 `favoritesSortedByTime`：先按 `favoritedAt` 降序，再按 `sortOrder` 降序。
- 素材 `download_manager`：`downloadedAt` 降序加载。
- 均符合 §3.3。

### 2.9 容灾自愈与两阶段备份（§7.1 / §7.2 / §7.8）
- `isCorruption` 识别 `FormatException` / `RangeError` / `HiveError`（字符串匹配）+ `BoxCorruptException`。
- `openAll()` 内聚恢复循环 + 按 box 计数的 `restoreTriesPerBox` + `_recreatedBoxes` 备份点 A 守卫 + `_fallbackRecreate`（带 `_fallbackDone` 防死循环）+ `_quarantineBox` / `_restoreBoxFile` + `openAllWithMemoryFallback`。
- 两阶段备份：`backupNow`（链式互斥锁 + `catchError` 防毒化）、`_doBackup`（`.tmp` + `rename` 原子落位）、`_retainRecentBackups`（`kMaxBackups=5`）。
- 桌面 `AppLifecycleListener` 顶层持有（onHide/onInactive/onExitRequested），5 分钟节流备份（§7.5）—— main.dart 忠实实现。
- 单测 `storage_manager_test.dart` 19 例覆盖：空数据初始化、往返不退化、损坏判定、备份恢复（§7.8）、`closeAll` 前 flush（§7.1）、`keys` 迭代安全（§5.4）、quarantine 等。

### 2.10 `resetAllData()` 七步（§7.6）
- 重写为：① 清三 box → ② 清快照文件 → ③ `ProgressStore.reset()` → ④ 五个 `reset()`（favorite/economy/achievement/download + 状态）→ ⑤ 重植样例/水合 → ⑥ 不碰设置 → ⑦ `reconcileSnapshots()`（含幽灵快照校正）。
- `economy.reset()` 重发 starter（金币=100/券=5，会话内即时生效，无需重启补发）——见 economy_service:108-117。

### 2.11 `box.keys` 先收集后批量删（§5.4）
- `favorite_store.pruneOrphans`、`achievement_store.reset()`、`download_manager` 失效过滤、`game_repository._initCustomPuzzles` 均遵循"先收集 keys 再批量操作"，规避迭代中写未定义行为。

### 2.12 测试基建隔离（§10.2）
- `test/test_helper.dart`：每个测试独立临时目录 + `StorageManager.setMockInstance` + `forTest/forTestWithBackups` + `tearDownTestStorage`（deleteFromDisk + 物理删目录 + `resetForTest`），10 个遗留测试套件已平滑迁移至 `initTestStorage/initTestAppStorage`。

---

## 三、测试覆盖评估

新增 4 个专属迁移测试套件，共 **41 个用例 / 约 1370 行**：

| 文件 | 用例数 | 覆盖场景 |
| :--- | :---: | :--- |
| `test/data/storage_manager_test.dart` | 19 | 空初始化、往返不退化、损坏判定、备份恢复(§7.8)、closeAll flush(§7.1)、keys 安全(§5.4)、quarantine |
| `test/data/game_progress_migration_test.dart` | 5 | 主线水合(§7.3)、每日进度随迁(§2.2)、聚合统计走内存索引(§八) |
| `test/data/game_collections_migration_test.dart` | 11 | 收藏(§5.3/§3.3)、素材库(§5.4)、自制定制(§4.4/§5.2/§7.3) 含删除/重置 |
| `test/data/game_state_migration_test.dart` | 6 | 原生类型(§3.1/§4.3)、成就前缀扫描(§4.3)、resetAllData 语义(§7.6) |

关键风险面（损坏自愈、备份恢复、跨 box 标志、级联删除、重置语义）均有对应单测；全仓 `flutter test` 220/220 通过。**覆盖充分。**

**容灾链路测试尤为扎实**（已逐条核读断言，非"空过"）：
- `storage_manager_test.dart` 手工复刻 hive 的 CRC32 算法（:15-308），构造「CRC 合法但 keyType 非法」的**真实损坏帧**——此类损坏连 `crashRecovery` 的尾部半写帧静默截断也救不回，却能稳定触发 `BoxCorruptException`，证明 `isCorruption` 判定与 `openAll()` 自愈入口真实有效。
- 单 box 损坏：仅还原该 box、健康 box 不动、现场改名留证（quarantine）、`hasRecreatedBoxes=false`（备份点 A 守卫不误触发）—— :507-534。
- 连续 2 份备份均损坏 → 该 box 兜底重建空箱且 `hasRecreatedBoxes=true`（备份点 A 守卫正确触发，防止空箱覆盖历史备份）—— :536-568。
- 双 box 同时损坏：各自从最新备份还原且**不被另一 box 的重试计数污染**（`restoreTriesPerBox` 按 box 隔离验证）—— :570-584。
- 保留最近 5 份、超出删最旧；`forTest` 实例不产生备份—— :586-611。
- 上述断言覆盖了设计 §7.2 / §7.8 的工业级边界，属高质量证据。**

---

## 四、发现的问题与风险（按严重级别）

### 高 / 中：无

未识别阻断级或高级别缺陷。所有核心数据路径、容灾链路、边界清理经静态分析 + 全量测试 + 逐文件通读确认正确。

### 低（Low）/ 信息级 —— 工程健壮性打磨建议（均非阻塞）

**L1. `progress_store.dart` 写操作吞异常（仅 warning 日志，不向上抛）**
- 位置：`save()`（:278-285）、`delete()`（:291-300）、`recordDifficultyCompletion()`、`updateProgress()`。
- 现状：失败仅 `AppLogger.repo.warning`，内存 `_index` 已先行更新（内存优先，UI 即时响应）。下次 `save()` 会重试落盘，故正常流不会丢数据；但若写失败后进程立即退出，该次变更可能未持久化且无上层感知。
- 评估：符合 §3.3"内存优先"取舍，属可接受权衡。**建议**：对关键路径（如首次通关保存）考虑 rethrow 或上报上层以便用户提示；当前不影响功能正确性，优先级低。

**L2. `game_repository` 的 `stat` getter 由 null 安全改为 fail-fast（已受测覆盖，设计自洽）**
- 位置：`totalPiecesSnapped` / `totalPlayTimeSeconds`（game_repository:95-98）现直接 `StorageManager.instance.state.get(...)`。
- 现状：原 `_prefs?.getInt(...) ?? 0` 在 prefs 未就绪时返回 0；现若 `openAll()` 未执行则 `state` getter 抛 `StateError`（storage_manager:179-181）。
- 评估：`main()` 已 `await openAllWithMemoryFallback()` 后再 `runApp`，生产路径安全；`recordSnapStats` 仅在 `init()` 后调用。属 fail-fast 改进（更早暴露未初始化误用）。
- **复核结论（降级为信息级）**：该 fail-fast 并非疏漏，而是**有意设计的违规防护**，且已有专门单测断言——`storage_manager_test.dart:337-345`（`未 openAll 时非空 getter 抛 StateError（违规防护）`）。故原"补注释"建议降级为可选，设计自洽、无需改动。

**L3. `favorite_store.reset()` 不自行清 box，依赖 `resetAllData` 步骤 1**
- 位置：favorite_store:305-310（清 `_entriesCache` + `idsNotifier` + `_initialized=false`，未清 `collections` box）。
- 现状：`resetAllData` 步骤 1 先 `collections.clear()`，故正常链路无残留；该 reset 与 economy/achievement/download 的 reset 行为一致（均为"清内存 + 依赖步骤 1 清盘"），设计自洽。
- 评估：仅当 `reset()` 被**单独**调用（脱离 `resetAllData`）才会留盘上孤儿 key。**建议**：若未来存在独立调用场景，在注释中显式标注"须先清 box"或内部补 `await _box.clear()`。当前无独立调用方，风险极低。

**L4.（信息）`totalCompletedLevels` 已 `@Deprecated` 返回 0**
- 位置：game_repository:89-94。无调用方，SSOT 已迁 `ProgressStore.getTotalSolved()`。正确清理，非回归，仅作记录。

---

## 五、最终判定与建议

**判定：✅ 通过 —— Hive 存储改造（v4.7）全量高质量落地，符合设计文档，达到生产可用标准。**

客观指标（analyze 0 / test 220 / build OK / format OK / DoD 0 残留 / MigrationService 删除）全部经独立复跑验证为真；设计关键约束逐条核对一致；测试覆盖充分；唯一问题均为低级别工程打磨，不阻塞发布。

**建议（非阻塞，仅 L1/L3 为可选工程打磨）**：
1. （可选）L1：评估关键写路径的错误可见性（rethrow / 上层提示）—— 当前内存优先 + 下次 save 重试已保证正常流不丢数据，优先级低。
2. （可选）L3：为 standalone `reset()` 调用场景补清盘或显式注释 —— 当前无独立调用方，风险极低。
3. L2 经复核为**有意且已受测的违规防护**，无需改动。
4. 既有 `docs/hive-migration-audit-report-20260903.md` 结论正面但缺少验证过程，建议以本报告（含可复现证据）为准或合并二者。

---

*审查人：WorkBuddy（独立代码审查）｜证据命令：`flutter analyze` / `flutter test` / `flutter build windows --debug` / `dart format --set-exit-if-changed` / `grep` DoD 旧 key / `grep` MigrationService 残留。*
