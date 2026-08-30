# 代码评审：commit 8040f70 存档/续玩实现

> **日期**：2026-08-30 13:32 GMT+8
> **评审对象**：`8040f70 feat(save): file-based snapshot v3 with forward compat and resume helper`
> **对照基准**：`docs/save-resume-continue-design-20260830.md`
> **校验状态**：`flutter analyze` 9 issues（全为 info 级 `use_build_context_synchronously`）；`flutter test` 113/113 通过

---

## 0. 结论

方向正确，实现完成度约 60%。

已经真正落地的：文件级快照（`SnapshotStore`）、轻量索引（`ProgressStore`）、`PuzzleBoardState v3 + extra` 前瞻兼容、三处模型的 `copyWith` 清档修复、`GamePage` 生命周期观察者与防抖、`ContinueDialog` 显式二选一、`ResumeHelper` 去重（四个 tab 共省约 1200 行）。

但有 **3 个会让"保存/继续"在真实场景下失效**的缺陷，以及设计文档 §5.1 / §6.2 / §6.3 / §8 / §10 五个章节未落地。建议先修 P0 再继续往下做功能。

---

## 1. 必改缺陷

### P0-1 存档难度与请求难度不匹配时静默丢弃 → "继续"等于"重开"

- `lib/pages/game_page.dart:159-161`：`_effectiveDifficulty = widget.difficulty.adaptiveForSize(w, h)` 会按图片宽高比重选档位，**覆盖调用方传入的难度**。
- `lib/game/jigsaw_puzzle_game.dart:1758-1764`：`_applyBoardState` 在 `rows/cols/pieces.length` 任一不一致时直接 `return`，无日志、无回调、无 UI 提示。
- 设计 §6.3 明确要求：不匹配时提示"存档与所选难度不匹配"并提供"切换到存档难度"按钮 —— 未实现。

**后果**：用户点"继续"看到全新散落；更糟的是后续 `_doSave()` 以新的 `_effectiveDifficulty` 生成 dkey 写盘，旧存档文件变成永不 GC 的孤儿。

### P0-2 用 pieceCount 反查难度有歧义 → 通关清档删错档

- `lib/data/game_repository.dart:378-381`、`499`、`589`：
  `PuzzleDifficulty.presets.firstWhere((d) => d.pieceCount == completedPieceCount)`。
- `lib/logic/puzzle_model.dart:235-262`：presets 中 24 / 48 / 54 / 96 / 108 / 150 / 192 / 216 / 300 各有横竖两项（如 `rows:6,cols:4` 与 `rows:4,cols:6`，dkey 分别是 `6x4` 和 `4x6`）。`firstWhere` 固定命中先出现的那一个。

**后果**：玩的是 `4x6`、清的是 `6x4`。真正的进行中存档被留成孤儿，该清的没清 → 通关后仍然弹"继续"。

**修法**：`GamePage` 已持有 `_effectiveDifficulty`，把 dkey 作为参数显式传进 `updateXxxProgress`，彻底删除 pieceCount 反查。

### P0-3 保存是异步 fire-and-forget → "退出必存"实际不保证

- `lib/pages/game_page.dart:224-227`：`_flushSave()` 调 `_doSave()`，`_doSave()` 返回 `void`，`fut.whenComplete` 无人 `await`。
- 于是 `Navigator.pop()` 立即执行 → `dispose()` → `dispose` 里再调一次 `_doSave()`；此时若 `_isSaving == true`，会新建 `Timer(300ms, _doSave)`，而 `dispose` 已在调 `_doSave()` **之前**就 `cancel()` 过 `_saveDebounce`，该 Timer 无人取消 → 逃逸到已卸载的 State 上继续写盘。
- `didChangeAppLifecycleState` 无法 `await`，`paused/detached` 只能发起、不能保证落盘。
- 设计 §6.1 要求"前台→后台立即同步写（`await flush()`）"、"dispose 中 `saveSnapshot(sync:true)` 兜底"。

**修法**：增加 `flushSync()` 路径 —— `exportSnapshotJson()` + `File.writeAsStringSync()` + 复用已缓存的 `SharedPreferences` 实例 `setString`；`dispose` 只调一次且不再创建 Timer。

> 附带结论：`PopScope(canPop:false)` 只拦截"用户发起的返回"（经 `Navigator.maybePop` → `Route.popDisposition`）。AppBar 里的 `Navigator.of(context).pop()` 是命令式 pop，**直接绕过 `canPop`**（`navigator.dart:5606` 的 `pop()` 不读 `popDisposition`）。所以当前代码不会死循环（AppBar 自己存了），但这个 PopScope 在 Windows 上基本无意义，只在 Android 手势/物理返回时生效。

---

## 2. 应该改进（P1）

| # | 问题 | 证据 | 说明 |
|---|---|---|---|
| P1-4 | **多难度并存只做了一半** | `progress_store.dart:73` `snapshotKeys: snapshotKeys ?? cur.snapshotKeys` 是覆盖式赋值；`resume_helper.dart:83` `difficulties: [info.dkey]` 只传 1 项 | 文件层确实并存，但索引里永远只有 1 个难度，`ContinueDialog` 的 `SegmentedButton` 是死代码。设计 §5.1 的"同关多难度并存"、§6.2 的"多难度 Tab"未落地 |
| P1-5 | **自由摆放的存档永远不会被"继续"** | `_doSave` 的 percent 只算 `solvedCount`；`resume_helper.dart:60` `percent <= 0` 直接 `return null` | 设计 §2.2 的 P0「自由摆放丢失」只修了写、没修读：拖了 30 块没吸附 → 文件写了、percent=0 → 不弹对话框、文件也不清 → 孤儿累积 |
| P1-6 | **双写未收敛，旧大 JSON 仍在 prefs** | `game_repository.dart:346-352`（`savedSnapshotJson` + `setString('jigsaw_level_N')`）、`578` `_saveCustomPuzzles()` 整表重写 | 同一份快照现在有 prefs + file 两份，IO 翻倍。设计 §2.2 P2「单大JSON膨胀」原封未动，§4 要求的"逐步废弃"没有任何动作（连 `@deprecated` 都没有） |
| P1-7 | **无迁移 → 老用户升级即丢进行中存档** | `game_repository.dart:93` 注释"无迁移，直接可用" | 设计 §10 的 `MigrationService` 未实现。老存档在 `jigsaw_level_N.savedSnapshotJson`，新链路只认 `snapshots/*.snapshot`；只有 `home_tab_view.dart:132` 的 `fallbackLegacy` 兜住主线一档，每日/自制无兜底 |
| P1-8 | **索引与文件两个真相源，无对账** | `ProgressStore.hasSnapshot` 是 prefs 布尔标记，文件才是真数据 | 任一侧丢失即永久不一致。`SnapshotStore.hasAnySnapshot`（扫文件系统）已写好却无人调用。建议 `load()` 未命中且标记为 true 时自动校正 |

---

## 3. 优化建议（P2）

| # | 问题 | 位置 |
|---|---|---|
| P2-9 | **原子写不原子**：`if (exists) delete(); tmp.rename(target)` 存在"零文件窗口"，且 rename 失败时旧档已被删 —— 从"可能损坏"退化为"必然丢失"。设计 §5.2 的 checksum、§5.2 的 gzip（>32KB）均未实现 | `snapshot_store.dart:86-94` |
| P2-10 | **`listDifficultyKeys` 有死代码**：先算 `inner.replaceAll('_','x').replaceAll('xx','x')` 再立刻覆盖成 `inner`（残留实验代码） | `snapshot_store.dart:171-175` |
| P2-11 | **`listSync()` 同步列目录**跑在 UI isolate，`deleteAllFor` / `fetchResume` 兜底路径都会触发；文件多时掉帧 | `snapshot_store.dart:152,167` |
| P2-12 | **canonicalId 安全化有损**：`pack:a.b:c` 与 `pack:a:b.c` 都变成 `pack_a_b_c`，会串档。建议 `sanitize + 8 位短哈希` 后缀 | `snapshot_store.dart:47` |
| P2-13 | `copyWith` 无法清空 `canonicalId` / `difficultyKey`（与刚修的 `savedSnapshotJson` 同类 `??` 陷阱） | `puzzle_state.dart:256-290` |
| P2-14 | `minSupportedVersion` 声明未使用；`fromJson` 不校验 `pieces.length == rows*cols`，也不处理 `version > currentVersion`（读未来版本静默接受，无任何 warning） | `puzzle_state.dart:140,316` |
| P2-15 | `.tmp` 残留文件无清理；`resetAllData` 只删 `.snapshot` | `game_repository.dart:713` |
| P2-16 | `fetchResume` 里 `ProgressStore.load` 调了两次（37 行 / 62 行），注释说"保证 active 键一致"，实际两次之间没有任何写入，纯多余 IO | `resume_helper.dart:37,62` |
| P2-17 | `loadJsonString` 是 `readAsString → jsonDecode → toJson → jsonEncode`，白跑一趟编解码，直接 `readAsString()` 即可 | `snapshot_store.dart:136-140` |
| P2-18 | 本次新增 9 条 `use_build_context_synchronously`：`game_page.dart:411`、`pack_levels_page.dart:129,150`、`daily_tab_view.dart:58,78`、`home_tab_view.dart:111,133`、`my_puzzles_tab_view.dart:115,144` | — |

---

## 4. 更好的方案（三选一）

| 方案 | 做法 | 改动量 | 收益 | 风险 |
|---|---|---|---|---|
| **A. 打补丁** | 只修 P0-1/2/3 + P1-4/5 | 小（约 5 个文件） | 立刻可用，风险最低 | 双写与两真相源的架构债仍在 |
| **B. 文件为唯一真相源**（推荐） | 快照文件是真数据；`ProgressStore` 降为"可重建缓存"，提供 `reconcile(cid)`：扫目录→校正 `snapshotKeys/hasSnapshot`。停止向 prefs 写 `savedSnapshotJson`，只保留读（迁移用） | 中（约 8 个文件） | 消灭双写与不一致；列表页渲染仍走索引，性能不变 | 需要一次启动期目录扫描（可懒执行 + 结果缓存） |
| **C. 全面重构** | 抽 `SaveCoordinator` + `SnapshotBackend` 接口 + `MigrationService` + 完整测试矩阵 | 大 | 一步到位满足设计 §9 扩展性 | 与当前处在快速迭代期的代码冲突大，不建议一次做完 |

**推荐 B，并附带三个具体做法：**

1. **难度键显式化**。所有写盘统一用 `_effectiveDifficulty` 的 dkey 参数传入，删除全部 `pieceCount → difficulty` 反查。`GamePage` 进入前先用 `SnapshotStore.load()` 拿到快照并比对 dkey，不一致就按设计 §6.3 弹提示 + 提供"切到存档难度"。
2. **`SaveCoordinator` 取代 GamePage 内联 debounce**。内部持有 `pendingKey` + 串行 `Future _tail`，对外只暴露 `requestSave()` / `flush()` / `flushSync()`。生命周期回调与退出路径只调 `flushSync()`。GamePage 不再持有 `Timer` 与 `_isSaving`，顺带消除 dispose 逃逸 Timer。
3. **索引可重建 + 孤儿 GC**。`reconcile()` 修正索引；启动时清理 `.tmp` 与"文件在、索引无"的孤儿快照；`snapshots/` 超阈值按 `updatedAt` LRU 清理未完成的档（设计 §8 配额）。

---

## 5. 建议落地顺序

1. **P0-1 + P0-2**（难度键显式化）—— 1 个模型思路 + 3 处调用，收益最大
2. **P0-3**（`flushSync()` + dispose 逃逸 Timer）
3. **P1-4 + P1-5**（索引合并 `snapshotKeys`；`percent == 0` 但有位移也应允许续玩）
4. **P1-6 + P1-7**（停止双写 + `MigrationService`）
5. **P2 清理**（原子写加固、死代码、同步 IO、lint）

---

*评审基于 `8040f70` 全量 diff + 现状代码；Flutter 3.44.8 / Dart 3.12.2，Windows 目标平台。*
