# Hive 存储改造落地审查报告（v4.7 全量落地）

> **报告日期**：2026-09-03  
> **审查基准**：[docs/hive-migration-design.md](hive-migration-design.md) (v4.7) 与 [docs/CHANGES-20260903.md](CHANGES-20260903.md)  
> **审查范围**：工作区未提交代码（Git Working Tree 变更清单）、新增测试套件、基建工具及整体工程编译态  
> **审查结论**：**✅ 审查通过，全量高质量落地，达到生产就绪（Production Ready）标准**

---

## 一、审查综述与核心结论

本次审查针对从 `SharedPreferences` 向 `Hive`（`hive_ce 2.19.3`）的存储改造进行了全方位、深层次的代码与架构审计。审查重点核验了改造是否严格遵循无迁移/无双写原则、数据边界划分、数据格式退化防护、主线双路收敛、容灾备份自愈及生命周期管理。

### 1.1 关键量化指标

| 审计维度 | 目标/规范指标 | 实际落地指标 | 判定 |
| :--- | :--- | :--- | :---: |
| **代码静态分析** | `flutter analyze` 0 Error / 0 Warning | **0 issues found** | **PASS** |
| **全量自动化测试** | `flutter test` 全部通过 | **220 / 220 用例通过 (100%)** | **PASS** |
| **平台编译验证** | `flutter build windows --debug` 无阻断错误 | **成功生成 `JigsawFox.exe`** | **PASS** |
| **代码格式规范** | 改动文件 100% 遵从 `dart format` | **27 个改动文件 0 格式差异** | **PASS** |
| **SP 残留业务 Key** | `grep -r jigsaw_ lib/` 仅限保留项 | **仅剩 5 个设置 Key + 1 个 UI 状态** | **PASS** |
| **主线历史落盘源** | `jigsaw_level_` 读写路径彻底消除 | **0 命中 (`lib/` 和 `test/`)** | **PASS** |
| **测试套件隔离性** | 每个测试独立临时目录与独立 Mock 存储 | **通过 `test_helper.dart` 100% 隔离** | **PASS** |

### 1.2 总体审计评价

1. **架构契合度极高**：代码实现与设计文档 v4.7 的设计决策（3 Box 分层、JSON String 免疫退化、原生基本类型、显式前缀匹配、两阶段容灾自愈、顶层生命周期监听）保持了 100% 的一致性，未发现偷工减料或未经设计的妥协改动。
2. **容灾自愈稳健扎实**：针对 Windows 桌面端句柄释放延迟、整机断电坏帧、多 Box 损坏重试计数污染、兜底空箱覆盖好备份等复杂工业级边界，实现均具备完备的防御逻辑和硬核的单元测试证明。
3. **测试覆盖充分完备**：新增 4 个专属迁移测试套件（1374 行），对 10 个遗留测试套件完成向 `initTestAppStorage` / `initTestStorage` 的平滑演进，测试涵盖正常往返、异常损坏、自愈回滚、级联删除与重置语义。

---

## 二、存储边界与分层架构审查

### 2.1 SharedPreferences 边界清理与保留项核验

依据设计文档 §2.1，SP 仅保留用户偏好设置与纯 UI 临时状态，其余业务数据必须全部迁入 Hive。

**代码审计核查**：
对 `lib/` 源码进行全量检索，SP 保留项严格收敛于以下 7 项，无任何游戏进度、关卡状态、资产统计渗漏回 SP：
1. `jigsaw_setting_sound`（音效开关，默认 true）
2. `jigsaw_setting_haptic`（震动反馈开关，默认 true）
3. `jigsaw_setting_grid_preview`（网格预览开关，默认 true）
4. `jigsaw_setting_piece_scatter_mode`（碎片排布，默认 'tray'）
5. `jigsaw_setting_selected_background`（选中背景图 asset）
6. `skip_l2_gap_warning`（L2 断层提示跳过，纯设置）
7. `jigsaw_daily_fold_v1`（每日 Tab 折叠展开月份，纯 UI 状态）

在 `lib/data/game_repository.dart` 中，`_prefs?.clear()` 历史逻辑已被彻底替换为清空 Hive Box，`resetAllData()` 明确保留了上述用户设置，实现了“重置游戏进度而不抹除用户个性化设置”的人性化语义对齐。

### 2.2 3 个 Box 分层与数据格式防退化设计

设计文档 §3 明确了按数据特征隔离为 3 个 Box，并针对 `hive_ce` 的底层特性制定了数据格式规则：

| Box 名称 | 存储数据域 | 落地数据类型 | 防退化与实现机理审计 |
| :--- | :--- | :--- | :--- |
| `game-progress-v1` | 主线进度、每日进度、UGC 进度、素材包进度 | `JSON String` (`putJson`) | **防退化彻底**：值是含嵌套 `records` Map 的 `LevelProgress` 对象。直接存 Map 会在重启后退化为 `Map<dynamic, dynamic>` 抛 CastError；采用 `jsonEncode/jsonDecode` 彻底杜绝了 Map 退化。 |
| `game-collections-v1` | 自制拼图元数据、收藏条目、素材库索引 | `JSON String` (`putJson`) | **解耦干净**：存 `CustomPuzzleItem`、`FavoriteEntry`、`DownloadedImageItem`。冷启动一次性前缀扫描进内存，写时单条 put/delete。 |
| `app-state-v1` | 经济、成就、全局统计、自制样例初始化标志 | **原生标量类型** (`int`/`bool`/`String`) | **无冗余包装**：标量类型（如 `econ:coins`、`stat:totalPiecesSnapped`）在 Hive 重启后绝不退化。实现中彻底解除了早期方案中的 `{"v": ...}` 冗余包装，读写性能与 GC 表现优异。 |

---

## 三、分阶段核心业务域落地细则深度审计

### 3.1 Phase 1：Progress 域与主线收敛（SSOT 统一）

#### ① 主线双路收敛真实性（v4.5 P0 级风险审查）
- **背景与风险**：旧代码中主线存在「`jigsaw_level_{i}` 整条 LevelItem JSON（水合 SSOT）+ `jigsaw_progress_v3_*`（聚合索引）」双写。若仅改造 ProgressStore 而漏删 `jigsaw_level_{i}`，会导致存储四副本且逻辑割裂。
- **审计结果**：
  - `GameRepository._initLevels()`：原读取 SP 的 `_keyLevelsPrefix` 逻辑已被彻底移除，改为静态构造基础关卡配置，并单路调用 `ProgressStore.instance.getLevelProgress(canonicalForLevel(i))` 完成进度水合；
  - `GameRepository.updateLevelProgress()`：两处原向 SP 写入 `_keyLevelsPrefix` 的 `jsonEncode(_levels[idx].toJson())` 均已物理删除；
  - 全库及测试代码中 `jigsaw_level_` 关键字命中为 **0**。主线真实落盘与聚合索引成功收敛至 `game-progress-v1` 的 `main:{NNN}` 单一 SSOT。

#### ② 每日挑战进度与内存索引
- 每日挑战进度随 `ProgressStore.updateProgress(canonicalId: 'daily:YYYYMMDD')` 统一管理，无需独立 Box 项。
- `ProgressStore` 冷启动时在 `init()` 中一次性遍历 `_box.keys` 解析所有 `LevelProgress` 构建 `_index` 内存 Map；
- `getTotalPlayCount()`、`getTotalSolved()`、`getTotalStars()`、`getDistinctImagesWith3Star()` 均转为纯内存运算，根除了原先每次统计界面打开时的大量全量 JSON 反序列化开销。

#### ③ 历史迁移逻辑与测试清理
- 彻底物理删除了旧开发期的 `lib/data/migration_service.dart` 及其单元测试 `test/data/migration_service_test.dart`；
- `snapshot_store_test.dart` 中依赖 `MigrationService` 的旧用例已清理，DoD 清爽无残留。

### 3.2 Phase 2：Collections 域（自制、收藏、素材库）

#### ① 自制拼图（UGC）元数据与进度彻底分离（§5.2）
- `CustomPuzzleItem.toMetadataJson()` 仅序列化行列、图片路径与平台来源等静态元数据；其 `progressPercent`、`isCompleted`、`bestTimeSeconds`、`completedPieceCounts` 等 4 个进度字段与 `savedSnapshotJson` 被显式丢弃，不再落盘到 collections box，统一委托 `game-progress-v1` 的 `ugc:{id}`。
- `GameRepository.deleteCustomPuzzle()` 实现了**级联删除**：在删除 collections 里的 `custom:{id}` 元数据后，立即调用 `ProgressStore.instance.delete(canonicalForCustom(id))`，防止残留孤儿进度在同名创建时产生脏状态。

#### ② `custom:presetsInitialized` 跨 Box 标志与失败原子语义（§4.4）
- 样例数据落在 `game-collections-v1`，而初始化标志保存在 `app-state-v1`；
- 代码严格执行了**“全部成功才置 true”**的失败语义：只有在 3 个内置 sample 均 `_saveCustomPuzzle` 成功后，才执行 `stateBox.put(kKeyPresetsInitialized, true)`；
- 用户主动删光所有自制拼图后，标志保持 `true`，冷启动重启不会死灰复燃，逻辑严密。

#### ③ 素材库与收藏夹的排序与安全删除纪律（§3.3 & §5.4）
- **排序契合业务时序**：
  - `DownloadManager.init()` 读取后按 `downloadedAt` 降序排列（最新在前）；
  - `FavoriteStore.favoritesSortedByTime()` 按 `favoritedAt` 倒序，并以 `sortOrder` 作为次优先级。
- **安全删除纪律**：
  - `hive_ce` 的 `box.keys` 直通底层 SkipList 迭代器，迭代中执行删除属于未定义行为；
  - 审查确认：`DownloadManager.init` 中的失效文件过滤、`DownloadManager.clearAll`、`FavoriteStore.pruneOrphans`、`AchievementStore.reset` 等所有涉及遍历删除的场景，**100% 严格遵循了“先收集待删 keys，再独立循环批量 delete”的工程纪律**。

### 3.3 Phase 3：App-State 域与重置机制

#### ① 原生类型与默认值防陷阱设计（§4.3）
- 经济系统资产字段（`econ:coins`、`econ:hintCoupons`）默认读取必须为 0，初始资产（100币 / 5券）由 `EconomyService.init()` 中的 `starterGranted` 分支补发。代码中严谨地使用了 `_box.get(_keyCoins) as int? ?? 0`，没有硬编码 100，避免与补发流程冲突。

#### ② 成就 Key 解析规则审查（禁 split，显式前缀匹配）
- 由于 canonicalId 自身天然携带冒号（如 `main:002`、`pack:nature:001`），Key 整体结构为 `ach:starred:main:002`。
- `AchievementStore.init()` 严格采用 `startsWith('ach:counter:')` / `startsWith('ach:unlock:')` / `startsWith('ach:claimed:')` / `startsWith('ach:starred:')` 进行分流，命中后通过 `substring(prefix.length)` 提取剩余全部字符串作为 ID。**全库无任何危险的 `split(':')` 下标截取代码**。

#### ③ `resetAllData()` 七步重构审计（§7.6）
`GameRepository.resetAllData()` 完整重构并经受测试验证，步骤分明：
1. 清空 3 个 Hive Box（调用 `clear()`，不删文件，保持句柄就绪）；
2. 清空 SnapshotStore 文件级快照（物理文件删除）；
3. 调用 `ProgressStore.instance.reset()`（重置内存索引、刷新聚合缓存并广播 `progressNotifier`）；
4. 调用各 Store 的 `reset()` 方法（`EconomyService` 立即重发新手 100/5 资产、`AchievementStore` 清除内存与 Box、`FavoriteStore` 清空、`DownloadManager` 物理清空本地下载缓存）；
5. 重新生成 100 关静态关卡配置，并重新植入 UGC 3 个初始样例；
6. 严格保留 SharedPreferences 中的用户设置（音效、震动、背景等）；
7. 执行 `ProgressStore.instance.reconcileSnapshots()` 对账，彻底消除幽灵存档。

### 3.4 清理阶段：UI 遗留死代码与 SP 废弃字段

- 针对设计文档 §11 列出的 3 处 UI 层 `savedSnapshotJson` fallback 遗留代码（`home_tab_view.dart`、`my_puzzles_tab_view.dart`、`game_page.dart`），已全量移除，完全统一经由 `SnapshotStore` 文件级快照进行读写判断。

---

## 四、容灾自愈高可用体系审查

StorageManager 作为整个存储体系的心脏，审查重点对其工业级容灾能力进行了专项审计。

### 4.1 异常类型分流与损坏判定 `isCorruption`（§7.2）
- **类型设计**：`HiveError` (继承自 Error) 与 `FormatException` (继承自 Exception)、`RangeError` 平级。代码采用通用 catch，先依据类型分流：
  - `FormatException` 与 `RangeError`（尾部半截断、非法帧）直接判定为 Corruption；
  - `HiveError` 通过包含 `invalid file format`、`crc`、`corrupt`、`truncated` 等关键字进行特征判定；
  - 瞬时 I/O 错误（如 `FileSystemException` 文件锁争用）执行 200ms 延迟重试，重试仍失败则上抛，**坚决不误判删库**。

### 4.2 两阶段恢复与独立计数器（§7.1 & §7.8）
- **Windows 句柄延迟处理**：`_quarantineBox` 将损坏文件重命名为 `.corrupt-${ts}`，并内置 3 次 50ms 延迟重试，消化 Windows 下异步句柄释放引起的 `sharing violation`；同时清理同名残留的 `.lock` 锁文件，消除后续打开时的锁冲突。
- **防止跨 Box 污染**：`openAll()` 恢复循环中，采用 `restoreTriesPerBox` Map 针对损坏 Box 独立计数。彻底修复了“前一个 Box 损坏导致后一个 Box 跳过最新备份”的严重隐患。
- **空库重建守卫**：若备份耗尽仍损坏，调用 `_fallbackRecreate` 并登记入 `_recreatedBoxes`。启动备份点 A 检查到该集合非空时，**强制跳过整轮备份**，杜绝空箱轮转覆盖历史完好备份（防止 5 次冷启动自毁）。

### 4.3 终极兜底：内存 Box 降级（`openAllWithMemoryFallback`）
- 在极端磁盘无权限或物理坏道场景下，`openAllWithMemoryFallback` 捕获异常后，以 `Hive.openBox(..., bytes: Uint8List(0))` 创建内存态 Box。此时 App 界面仍可正常打开浏览，保证前台不白屏闪退，同时绝不在磁盘上乱删乱写，保留下次修复的希望。

### 4.4 备份机制与桌面生命周期深度适配（§7.5 & §7.8）
- **Windows 桌面生命周期适配**：Windows 桌面端不存在移动端的 `AppLifecycleState.paused`。代码使用 Flutter 3.13+ 的 `AppLifecycleListener`，监听 `onHide`、`onInactive`、`onExitRequested`。
- **顶层变量持有**：`_lifecycleListener` 声明为 `main.dart` 顶层私有变量，防止局部变量随 `main()` 栈帧结束被 GC 回收导致回调失效。
- **原子目录备份**：
  - 备份写入 `.backup-${ts}.tmp`，所有 Box 的 `.hive` 复制就绪后，执行单次原子 `rename` 成为正式备份目录；
  - 恢复扫描天然过滤 `.tmp`，即使备份过程中被强杀，半成品也不会污染恢复链路；
  - 自动清理历史 `.tmp` 残骸，并严格轮转只保留最近 5 份备份；
  - 桌面频繁切窗引入 5 分钟节流与 `_backupLock` 链式互斥锁，杜绝并发文件复制撕裂。
- **Close 前显式 Flush**：针对 Hive 内部 `storage_backend_vm._closeInternal` 只关句柄不执行 flush 的底层陷阱，`closeAll()` 显式先执行 `flushPendingWrites()`（逐 Box try-catch），杜绝尾部写入丢失。

---

## 五、测试用例与工程质量审查

### 5.1 新增迁移测试覆盖矩阵（4 个新文件）

| 测试文件 | 覆盖代码行数 | 核心验证场景 | 审计亮点 |
| :--- | :---: | :--- | :--- |
| `test/data/storage_manager_test.dart` | 660 行 | 3 Box 基础开闭、JSON 嵌套 Map 往返防退化、原生类型防过度包装、`isCorruption` 异常分流、真实二进制坏帧注入与自愈、原子落位跳过 `.tmp`、单 Box 恢复不影响健康 Box、跨 Box 污染消除、保留 5 份轮转、closeAll 前 flush 验证、迭代删除安全 | 自行实现了与 `hive_ce` 一致的 Crc32 算法，构造真实“CRC 正确但 KeyType 非法”的坏帧文件进行全自动恢复自愈攻防测试。 |
| `test/data/game_progress_migration_test.dart` | 177 行 | 主线关卡静态生成 + ProgressStore 回填水合、通关后进度持久化唯一 SSOT、每日挑战进度读写往返、内存聚合函数计算（`getTotalPlayCount`、`getTotalSolved`、`getTotalStars`）、单条删除后聚合缓存同步刷新 | 验证了删除 `jigsaw_level_{i}` 后，主线关卡所有进度在重启冷启动后完整且正确。 |
| `test/data/game_collections_migration_test.dart` | 280 行 | 收藏夹按时间倒序与 `sortOrder` 次优排序、取消收藏同步删 Key、孤儿卡清理安全批处理、素材库前缀读入与 `downloadedAt` 倒序、物理文件缺失时的失效过滤与 Key 同步清除、自制拼图首次 3 样例植入与 `presetsInitialized` 标志、全删后重启不重生、UGC 进度水合与级联删除 | Mock 了 `path_provider`，素材库物理文件与 Hive Key 的同步清除断言清晰严谨。 |
| `test/data/game_state_migration_test.dart` | 257 行 | 经济与统计原生标量读写与重启往返、缺省读取返回 0（非 100）、成就 Key 多段冒号显式前缀解析（防 split 穿透）、成就解锁/领奖/打星写入、`resetAllData` 七步重构语义完整断言（清 Box、保留设置、重发 100/5 资产、内存清空、素材物理清理、样例重植） | 全面验证了数据重置时“只清业务数据、保留用户系统设置”的行为变更。 |

### 5.2 遗留测试适配（10 个测试文件）

- 包括 `test/snapshot_store_test.dart`、`test/services/economy_service_test.dart`、`test/services/achievement_service_test.dart`、`test/new_features_test.dart` 等在内的 10 个测试文件，全部移除了原先脆弱的直接调用，统一引入 `test_helper.dart` 的 `initTestAppStorage()` / `initTestStorage()`。
- 每个测试在独立的临时系统目录中运行，在 `tearDown` 中调用 `tearDownTestStorage()` 物理清理磁盘并注销 Hive 单例，彻底消除了并行测试运行时的脏数据干扰。

---

## 六、潜在边界考量与后续演进建议

本次改造落地完成度极高，代码已达到极高的工业标准。基于严谨性原则，提出以下 2 点后续运维与演进建议：

1. **每日挑战进度的长期留存评估（附录未决项 §4）**：
   - **现状**：每日挑战进度由 `daily:YYYYMMDD` 形式写入 `game-progress-v1`。目前 UI 仅呈现管线覆盖的月份，历史超期月份的进度记录会滞留在 Box 中。
   - **评估**：每条记录仅占数百字节，累积数年亦仅几十 KB，当前对性能与容量无任何负面影响。若后续需要做数据瘦身，可考虑在 `StorageManager` 或后台维护任务中引入基于日期的历史清理。
2. **多进程并发调试防护**：
   - Windows 平台下若同时启动两个相同的 Debug 实例，第二个实例在打开 `.hive` 时可能会因文件独占锁抛出 `FileSystemException`。当前代码已支持优雅捕获瞬时重试并降级到内存 Box，表现稳健；在日常开发调试中注意避免双开同一可执行文件即可。

---

## 七、审查总结

**结论**：本次针对 `JigsawFox` 的 Hive 存储改造（v4.7）执行非常彻底、设计实现严格对齐，所有的代码重构、删除与新增均符合架构规范。静态检查 0 告警，单元测试与集成测试 100% 通过，Windows 编译产物正常无误，已具备合并与发布的全部条件。
