# 存档与续玩（继续 / 重新开始）长期最优设计方案

> **状态**：已落地（8040f70）· 2026-08-30 13:38 增补“只留最新残局”简化  
> **日期**：2026-08-30 10:38 GMT+8（初版）/ 2026-08-30 13:38 增补  
> **作者**：OpenCode / Muse Spark  
> **关联现状**：`lib/data/game_repository.dart`、`lib/logic/models/puzzle_state.dart:114`、`lib/game/jigsaw_puzzle_game.dart:1799`、`lib/pages/game_page.dart:192`、`lib/widgets/choose_difficulty_sheet.dart:554`、`docs/data-architecture-current.md`、`docs/puzzle-content-storage-and-expansion-design.md:6`  
> **增补决策（2026-08-30 13:38）**：按用户要求“多难度并存不做，只保留最新一次残局”，`snapshotKeys` 仅保留 `activeDifficultyKey` 单值，`ContinueDialog` 多难度 Tab 保留但仅传单值，`ProgressStore` 覆盖写而非追加。

---

## 1. 背景与目标

### 1.1 需求

- 玩家“玩到一半退出（返回/切后台/杀进程/关窗口）”，再次进入**同一关卡同一难度**时，必须出现显式二选一：**[继续]** / **[重新开始]**。
- 覆盖全部关卡来源：主线 100 关、每日挑战、自制 UGC、扩展包/活动（`pack`/`event`）。当前仅主线/每日/自制已打通，扩展包完全无存档。
- 要求长期可扩展、可靠：支持多难度并存存档、跨设备/跨版本迁移、未来云同步预留；做到原子写入、后台容灾、损坏自愈。

### 1.2 非目标

- 不做实时多人协同；不做关卡内容本身的云端动态下发（由 `ManifestRouter` 负责）。

---

## 2. 现状与已识别缺陷

### 2.1 现有链路

```
列表页(HomeTabView/DailyTabView/MyPuzzlesTabView)
 -> ChooseDifficultySheet(内嵌"继续游玩 xx%"+“放弃并重开”)
 -> GamePage(initialSnapshotJson?)
 -> JigsawPuzzleGame(rows/cols/seed) --exportSnapshotJson()--> GameRepository.updateXxxProgress()
 -> SharedPreferences: jigsaw_level_<N>/jigsaw_daily_<date>/jigsaw_custom_list(JSON Array)
```

- 快照本体为 `PuzzleBoardState:114` + `PieceState:1`，以 JSON 字符串嵌在 `LevelItem:30 savedSnapshotJson` 等字段内。
- 写入仅在 `GamePage:192 _autoSaveProgress()`（`onProgressChanged:162` 吸附成功时）触发；通关时以 `savedSnapshotJson:null` 试图清档（`game_repository.dart:320/377/420`）。
- 恢复在 `JigsawPuzzleGame:328` `fromJson` -> `_applyBoardState:1850` 校验 `rows/cols/len` 不一致静默丢弃；`GamePage:142` 恢复 `elapsedSeconds`。

### 2.2 缺陷清单

| 级别 | 现象 | 根因定位 |
|---|---|---|
| **P0** 清档永不生效 | 通关/放弃后下次仍提示继续 | `LevelItem:42 copyWith` / `Daily:42` / `Custom:61` 用 `?? this.savedSnapshotJson`，传 `null` 被忽略；`game_repository.dart:320` 无效 |
| **P0** 自由摆放丢失 | 拖到棋盘未吸附即退出，位移丢失 | `_autoSaveProgress` 仅绑 `solvedCount` 变化 |
| **P0** 后台杀进程丢档 | 切后台/划掉进程回到上次吸附点 | 无 `WidgetsBindingObserver/AppLifecycleListener/PopScope`，`dispose:721` 不存档 |
| **P1** 难度切换误导 | 切难度仍显示旧 `xx%`，进游戏全新散落无提示 | `isSameDiff` 按 `pieceCount` 判，`adaptiveForSize:puzzle_model.dart:218` 改 `rows/cols` 后 `_applyBoardState:1851` 静默 `return` |
| **P1** 单存档覆盖 | 同关多难度共用一条 `savedSnapshotJson`，只能存一档进行中 | 模型一对一 |
| **P1** 扩展包无存档 | `PackLevelsPage:101` 每局 `4x4` 新局，不读不写 | 未接入存档 |
| **P2** 单大JSON膨胀 | `jigsaw_custom_list` 含多份快照（225块~10KB/份），启动全量 `jsonDecode` | `initCustomPuzzles:192` |
| **P2** 无节流高频IO | 每次吸附即 `setString` | - |
| **P2** 退出路径不全 | 手势/系统返回不走保存 | 缺 `PopScope` |

> 现有 `puzzle-content-storage-and-expansion-design.md:329` 已提出 `snapshots/*.snapshot` 独立文件隔离，但当前代码仍走 `SharedPreferences` 大字符串，未落地。

---

## 3. 设计原则

1. **可靠性优先**：原子写入 + 校验 + 容灾 + 可回滚；任何一次崩溃不污染全局进度。
2. **扩展性**：关卡来源可插拔（`main/daily/event/pack/ugc`）、存储后端可插拔（本地文件/SharedPreferences/未来云）、难度维度正交。
3. **可观测**：存档读写全链路 `AppLogger` 分级埋点，损坏可定位。
4. **性能**：增量/节流写入，百KB快照不阻塞 UI；启动不全量解析。
5. **兼容**：旧 `SharedPreferences` 存档自动迁移，跨版本 `version` 兼容。

---

## 4. 总体架构

```
┌─ UI层 ───────────────────────────────┐
│ Home/Daily/My/Pack/Event 列表        │  ① 查 ProgressStore.hasSnapshot?
│ ChooseDifficultySheet / ContinueDialog│ ─┤ ② 选难度 -> 查 SnapshotStore
└──────────────┬───────────────────────┘  │
               │                          ▼
┌─ 领域/存档层 ──────────────────────────┐
│ ProgressStore (轻量进度索引)          │  SharedPreferences  JSON
│  key: progress:<canonicalId>          │  {isCompleted, completedPieceCounts, bestTime, stars, lastSavedAt, hasSnapshot}
│ SnapshotStore (重型快照)              │  File: <AppSupport>/snapshots/<safeId>_<RxC>.snapshot(.gz)
│  key: <canonicalId>:<RxC>  version:3 │  + 内存 LRU + 写入队列(去重/限流)
│ MigrationService (旧->新)             │
└──────────────┬───────────────────────┘
               │  PuzzleBoardState v3
┌─ 引擎层 ─────────────────────────────┐
│ JigsawPuzzleGame                      │  exportSnapshotJson(v3) / applyBoardState(v3)
│ GamePage + SaveLifecycleObserver      │  防抖保存、后台保存、退出拦截
└────────────────────────────────────┘
```

*与现有 `GameRepository` 关系*：保留 `GameRepository` 作为门面（Facade），内部委托给 `ProgressStore` + `SnapshotStore`；对外 API 保持兼容，逐步废弃对 `LevelItem.savedSnapshotJson` 的直接读写，转为通过 `SnapshotStore` 按需加载。

---

## 5. 数据模型

### 5.1 唯一主键

沿用 `docs/puzzle-content-storage-and-expansion-design.md:2` 的 **CanonicalId**

```
main:<index>              例 main:001
daily:<YYYYMMDD>          例 daily:20260827
event:<eventId>:<file>    例 event:cyberpunk:01_rain
pack:<packId>:<file>      例 pack:world_art:mona_lisa
ugc:<timestamp|hash>      例 ugc:1725000000000
```

**难度键**：`difficultyKey = "${rows}x${cols}"`（如 `15x15`），与 `PuzzleDifficulty:201` 的 `rows/cols` 强绑定，不以 `label` 为准。

**存档主键**：`<canonicalId>::<difficultyKey>`。同一关卡不同难度并存多份进行中存档，互不覆盖；通关记录 `completedPieceCounts` 仍按 `pieceCount` 聚合展示。

### 5.2 Snapshot v3（文件）

```dart
// lib/logic/models/puzzle_state.dart 升级
PuzzleBoardState {
  version: 3,                 // int, 2->3 迁移
  canonicalId: String,        // 如 main:042
  difficultyKey: String,      // 如 10x10
  aspectRatio: String,        // square1x1 / portrait3x4 ... 供校验
  seed: int,
  rows/cols: int,
  rotationEnabled: bool,
  elapsedSeconds: int,
  hintsUsed: int,
  createdAt: String,          // ISO8601
  pieces: List<PieceState>,   // 同 v2，g/clusterId/rot/nx/ny
  checksum: String,           // 可选 crc32(JSON without checksum)，损坏检测
}
```

- `toJson` 输出含 `version/difficultyKey/canonicalId`；`fromJson` 按 `version` 分支，`version==2` 自动补 `canonicalId/difficultyKey` 并校验 `rows*cols == pieces.length`。
- 压缩：写入时 `jsonEncode` -> `gzip` -> `base64` 可选（阈值 >32KB 时启用），读时自动识别。
- 大小：225块约 9~14KB JSON，gzip 后 ~3KB。

### 5.3 Progress 索引（SharedPreferences 轻量）

```json
// key: jigsaw_progress_<canonicalId>  // 例 jigsaw_progress_main:042
{
  "canonicalId": "main:042",
  "isUnlocked": true,
  "isCompleted": false,
  "completedPieceCounts": [16, 36],
  "bestTimeSeconds": 342,
  "stars": 2,
  "hasSnapshot": true,                 // 是否存在对应快照文件
  "activeDifficultyKey": "10x10",      // 最近一次进行中的难度
  "snapshotKeys": ["6x6","10x10"],     // 存在快照的难度列表
  "lastSavedAt": "2026-08-30T10:38:00+08:00",
  "lastProgressPercent": 37
}
```

*收益*：列表页无需读大快照即可渲染 `xx%`、继续入口；`hasSnapshot` 驱动 UI 是否显示“继续”。

### 5.4 存储后端

| 类型 | 路径/Key | 说明 |
|---|---|---|
| **Progress 索引** | `SharedPreferences jigsaw_progress_<safeCanonicalId>` | 单关一条，小 JSON |
| **Snapshot 文件** | `<AppSupport>/snapshots/<safeCanonicalId>_<RxC>.snapshot` | `path_provider.getApplicationSupportDirectory()`，Windows/macOS/Linux 均可用；文件名经 `sanitize`（`:`->`_`） |
| **旧兼容** | `jigsaw_level_<N>` 等 | 仅迁移时读取，迁移后删除或标记 `migrated` |
| **统计/设置** | `jigsaw_stat_*` / `jigsaw_setting_*` | 保留 |

> 为何文件而非继续 SharedPreferences：快照 10KB+，多关多难度易超 `SharedPreferences` 单值/事务限制；文件可原子重命名、易 gzip、易按关按难度独立 GC。

---

## 6. 关键流程

### 6.1 保存时机（SaveLifecycleObserver）

`GamePage` 混入 `WidgetsBindingObserver` + `PopScope`：

- **即时**（去重限流）：`handlePieceDragEnd` 结束后、自由摆放落盘后，入 `SnapshotWriteQueue`（800ms debounce，`isSolved` 时立即刷）。
- **空闲**：棋盘静止 2s 定时器补一次（捕获“拖来拖去未吸附”的自由位置）。
- **前台→后台**：`didChangeAppLifecycleState(AppLifecycleState.paused/hidden/detached)` 立即同步写（`await flush()`）。
- **退出拦截**：`PopScope(canPop:false, onPopInvokedWithResult:)` + AppBar返回 + 暂停菜单“保存并退出” + 系统手势返回，统一 `await saveSnapshot()` 再 `pop`。
- **dispose**：`dispose` 中 `saveSnapshot(sync:true)` 兜底。

*写入原子性*：`writeTempFile(<id>.tmp) -> fsync -> rename(<id>.snapshot)`，避免半写损坏；`checksum` 写入，读时校验失败则视为无存档并埋点 `warning`。

### 6.2 读取与“继续/重开”分流

```
用户点击关卡卡片
 -> ProgressStore.get(canonicalId) -> hasSnapshot? && lastProgressPercent>0 && !isCompleted
    ├─ 否 -> 直接弹 ChooseDifficultySheet（现逻辑）
    └─ 是 -> 弹 ContinueDialog（新）
           ┌─────────────────────────────────────────┐
           │ 缩略图  标题 #42  规格 10x10  已拼 37/100 │
           │ 进度条 37%  用时 04:12  难度 10x10       │
           │ [继续] [重新开始]                       │
           └─────────────────────────────────────────┘
           继续 -> GamePage(canonicalId, difficulty=activeDifficultyKey, snapshot=SnapshotStore.load(...))
           重开 -> 二次确认“将清除此难度进度，不可恢复” -> SnapshotStore.delete(canonicalId, difficultyKey)
                    + ProgressStore.clearSnapshot(canonicalId, difficultyKey) -> GamePage(null)
```

*多难度*：若该关存在多个 `snapshotKeys`，`ContinueDialog` 顶部以 `SegmentedButton` 展示可继续的难度Tab，默认选中 `activeDifficultyKey`，切换Tab即切换预览数据。

*扩展包*：`PackLevelsPage` 同样走 `canonicalId=pack:<packId>:<file>`，复用同一 Dialog。

### 6.3 难度切换与自适应

- 存档加载前严格校验：`snapshot.rows==requested.rows && snapshot.cols==requested.cols && snapshot.pieces.length==rows*cols`，不一致则不注入 `initialSnapshotJson`，而是弹提示“存档与所选难度不匹配，已为你开启新局”，并提供“切换到存档难度”快捷按钮。
- `GamePage._loadImage` 的 `adaptiveForSize` 结果若与请求难度 `pieceCount` 不等，视为请求难度无效，自动回落到存档难度或 `recommended`。

---

## 7. 模块与 API 草案

```dart
// lib/data/snapshot_store.dart
class SnapshotStore {
  static final SnapshotStore instance = SnapshotStore._();
  Future<PuzzleBoardState?> load(String canonicalId, String difficultyKey);
  Future<void> save(String canonicalId, PuzzleBoardState state); // 原子 + gzip
  Future<void> delete(String canonicalId, String difficultyKey);
  Future<void> deleteAllFor(String canonicalId);
  Future<List<String>> listDifficultyKeys(String canonicalId);
}

// lib/data/progress_store.dart
class ProgressStore {
  static final ProgressStore instance = ProgressStore._();
  Future<LevelProgress> get(String canonicalId);
  Future<void> upsertProgress(String canonicalId, {int progressPercent, bool isCompleted, int stars, int timeSeconds, String? activeDifficultyKey});
  Future<void> setHasSnapshot(String canonicalId, String difficultyKey, bool has);
  Future<void> clearSnapshot(String canonicalId, String difficultyKey);
}

// lib/data/game_repository.dart 保留门面
class GameRepository {
  // 旧 API 委托 + 标记 @deprecated
  Future<void> updateLevelProgress({...}) => ProgressStore + SnapshotStore
  // 新 API
  Future<PuzzleBoardState?> loadSnapshot(String canonicalId, PuzzleDifficulty diff);
}
```

*Engine*：`JigsawPuzzleGame.exportSnapshotJson({required String canonicalId, required String difficultyKey, int? elapsedSeconds})` 产出 v3；`_applyBoardState` 增加 `AppLogger.game.warning` 可观测错误。

---

## 8. 可靠性保障

- **原子写**：临时文件 + `rename`，Windows 下 `File.rename` 已原子。
- **损坏自愈**：读时 `try/catch` + `checksum` 校验失败 -> 删除损坏文件 -> 回退新局 -> `AppLogger.game.warning` 上报，不崩溃。
- **限流**：`SnapshotWriteQueue` 单关单难度合并请求，`debounce 800ms`，后台/退出时 `flush`。
- **配额**：单快照 >200KB 拒绝写入并埋点；`snapshots/` 目录总大小超 50MB 时 LRU 清理最旧未完成快照（保留通关索引）。
- **备份**：`GameRepository` 写入 `SharedPreferences` 前 `setString` 失败重试 1 次并 `severe` 日志。

---

## 9. 扩展性预留

- **存储可插拔**：`SnapshotStore` 定义 `SnapshotBackend` 接口，默认 `FileBackend`，未来可注入 `EncryptedFileBackend` / `CloudBackend`（如 Firebase/S3）。
- **云同步钩子**：`ProgressStore` 暴露 `onProgressChanged Stream`，`SyncService` 订阅后以 `canonicalId+difficultyKey` 为粒度增量上传；冲突策略“最后写入 wins + 本地快照保留副本”。
- **新关卡来源**：任意遵守 `CanonicalId` 规范的来源（`main/daily/event/pack/ugc`）零改动接入存档。
- **版本演进**：`version` 字段 + `MigrationService`，v3 -> v4 仅增量补字段。

---

## 10. 兼容与迁移

1. **首次启动检测**：`MigrationService.migrateIfNeeded()` 扫描旧 Key `jigsaw_level_*` / `jigsaw_daily_*` / `jigsaw_custom_list`。
2. **逐条迁移**：对每条含 `savedSnapshotJson` 的旧记录：
   - 解析 `PuzzleBoardState v2`，补 `canonicalId = CanonicalId.fromLegacy(LevelItem)`、`difficultyKey = "${rows}x${cols}"`。
   - 写入 `SnapshotStore.save()` + `ProgressStore.upsert(hasSnapshot:true)`。
   - 旧记录 `savedSnapshotJson` 置 `null` 并写回，避免重复迁移；或加 `jigsaw_migrated_v3=true` 标记。
3. **回滚**：迁移失败单条跳过并 `warning`，不阻塞其它关卡。
4. **测试**：提供 `test/migration_test.dart` 覆盖 v2->v3、多难度、损坏JSON。

---

## 11. UI/交互规范

- **ContinueDialog**（新文件 `lib/widgets/continue_resume_dialog.dart`）：
  - 顶部缩略图（`AppCachedImage:360`）+ 标题 `displayTitle` + 难度标签 `DifficultyTier.tag` + 用时 `mm:ss` + 进度 `xx%`（`LinearProgressIndicator`）。
  - 主按钮 `[继续]`（绿底 `0xFF2E7D32`），次按钮 `[重新开始]`（白底红字，需二次确认 `AlertDialog`）。
  - 多难度时顶部 `SegmentedButton` 切换。
- **ChooseDifficultySheet** 保留，但当 `hasSnapshot` 且选中难度==存档难度时，底部主按钮文案为 `继续游玩 (xx%)`，否则为 `开始/重玩`；切到无存档难度时提示“该难度无存档，将开启新局”。
- **列表卡片**：`HomeTabView:413` / `Daily:395` / `MyPuzzles:450` 的右上角已显示 `xx%`，保持；对 `hasSnapshot` 的卡片加“续玩”角标。

---

## 12. 性能与边界

- 列表页不读快照文件，仅读 `ProgressStore` 轻量索引；快照仅在点击后按需 `load`。
- `exportSnapshotJson` 在 `Isolate` 外仅做 JSON 编码（<5ms/100块），gzip 可选后台。
- 极端 15x15=225块 快照 ~14KB，100关全存 ~1.4MB，文件方案无压力。

---

## 13. 测试策略

- **单测**：`snapshot_store_test.dart`（原子写/损坏/压缩）、`migration_test.dart`（v2->v3）、`progress_store_test.dart`（多难度隔离）、`continue_dialog_test.dart`（Widget）。
- **集成**：`game_layout_test.dart` 追加“自由摆放后后台保存再恢复”“难度不匹配回退”用例。
- **手动**：覆盖“吸附后返回/切后台/杀进程/扩展包/切难度”四象限。

---

## 14. 分阶段落地

| 阶段 | 内容 | 产出 |
|---|---|---|
| **P1** | `SnapshotStore` + `ProgressStore` + `MigrationService` + `Snapshot v3` | 存档底座 |
| **P2** | `GamePage SaveLifecycleObserver` + `SnapshotWriteQueue` + 原子写 | 可靠保存 |
| **P3** | `ContinueDialog` + `ChooseDifficultySheet` 多难度 + 列表角标 | 显式二选一 |
| **P4** | `Pack/Event` 接入 + 全量迁移 + 埋点 | 全来源覆盖 |
| **P5** | 压测/配额/LRU + 云同步接口预留 | 加固与扩展 |

---

## 15. 关键文件变更清单

- 新增：`lib/data/snapshot_store.dart`、`lib/data/progress_store.dart`、`lib/data/migration_service.dart`、`lib/widgets/continue_resume_dialog.dart`、`lib/logic/models/puzzle_state.dart` (v3)
- 修改：`lib/data/game_repository.dart`（门面委托）、`lib/pages/game_page.dart`（生命周期）、`lib/game/jigsaw_puzzle_game.dart`（v3 导入导出）、`lib/widgets/choose_difficulty_sheet.dart`（多难度）、`lib/pages/pack_levels_page.dart` / `event_levels_page.dart`（接入）

---

## 16. 风险与对策

- **迁移期双写不一致**：灰度期对新旧两处双写，新读优先读新，失败回退旧。
- **Windows 文件锁**：`rename` 前确保无句柄占用，捕获 `FileSystemException` 重试。
- **用户误删**：重新开始需二次确认，且可考虑“最近删除” 7 天内可恢复（`snapshots/.trash/`）。

---

*本设计与 `puzzle-content-storage-and-expansion-design.md:7.2` 的 `snapshots/*.snapshot` 隔离思想一致，将其从文档落到实现，并以 `CanonicalId + difficultyKey` 解决多难度覆盖与扩展包缺档两大扩展性短板。*
