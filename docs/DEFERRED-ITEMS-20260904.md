# 搁置项深度评估 2026-09-04

> **评审基准**：`docs/flutter-code-reviews-20260904.md`（精简版）`P10/P17/P23/P24/P25/P26/P05·P18·P21残余` 7 项  
> **状态**：主链 19 项已修复（`26b6539`/`bab9552`/`cbb80b6`，`flutter analyze 0`/`test 247`/`build windows --debug OK`），本 7 项因**影响面大/手感敏感/需真机压测**暂缓，单独立项研究。  
> **写入时间**：2026-09-04 18:17 GMT+8 · 供后续专项评审与压测

---

## 总览

| # | 编号 | 标题 | 原严重级 | 搁置类型 | 建议优先级 |
|---|---|---|---|---|---|
| 1 | **P10** | Flame 持续满帧能耗 | P2 | 性能/功耗权衡 | P2 中 |
| 2 | **P17** | 全分辨率三重常驻 OOM（难度感知解码） | P0 | 正确性×性能×手感 | **P0 高（首优）** |
| 3 | **P23** | `daily_tab_view` Build 内同步 I/O + 365 次查询 | P2 | 体验微优化 | P2 低 |
| 4 | **P24** | 散落重叠 / `epsilon` 固定 | P2 | 算法调优 | P2 低 |
| 5 | **P25** | 引擎 `O(N²)/O(N³)` + 渲染全量遍历 | P2 | 算法/渲染债务 | P2 中 |
| 6 | **P26** | 缓存非原子/无重试/Auto-GC误删/`minAppVersion`等长期项 | P2 | 技术债队列 | P2 低 |
| 7 | **P05·P18·P21 残余** | `stateBox` 零散 `put` / 完全流式解压 / `GameRepository` 内存回滚 | P1 | 残余分支 | P1 低 |

> 搁置≠不修；已在 `IMPLEMENTATION-REPORT-20260904.md` 第3阶段注明，本文展开**为何搁置、现况兜底、若强行修复的风险、正确落地路径与验收标准**。

---

## 1) P10 — Flame 持续满帧（`jigsaw_puzzle_game.dart` / `puzzle_piece_component.dart:183`）

**原文指控**：`FlameGame` 静置仍 `60/120 FPS` 循环，对数百个 `Piece` 执行 `clipPath`+`drawImageRect`+`shadow`，发热耗电。

**实测**：半属实。`JigsawPuzzleGame` 确无 `pauseEngine/resumeEngine`，但 `PuzzlePieceComponent:190-205` 已有**视锥剔除**：

```dart
// puzzle_piece_component.dart:190
final oh = shape.overhang; const margin = 4.0;
final left  = position.x - (oh.left  * size.x + margin) * scale.x;
...
if (right < 0 || left > game.size.x || bottom < 0 || top > game.size.y) return;
```

托盘模式屏外可剔 85%~90%，`isFilteredOut/hideBorders/isDragging/isHoldingCluster` 均早退，原“上万次 `clipPath`”高估 5~10 倍。

**现况兜底**：`_contactShadowPaint` 已去 `MaskFilter`（静止用 0.8px `Contact AO`），`_dragShadowPaint` 仅拖拽时 7px 模糊，已显著降 GPU。

**为何搁置**：正确修复需**空闲状态机**：`无交互 1s → pauseEngine()`，`onPanStart/onDragStart/scale` → `resumeEngine()`，且 `GamePage` 以 `Listener` 统管单指平移（`_onPointerMove:746`）规避 `Flame PanDetector` 竞技场冲突，暂停后 `zoomNotifier`/`panOffset`/`boardTopLeft` 需同步唤醒；另“已锁定集群合批底图（`PictureRecorder` 烘焙静态层，`Priority 5`）”需重分 `render` 层级，牵 `boardGhost`/`trayBg`/`_boardOutline`。改动涉游戏主循环，回归面广。

**强行风险**：暂停时机不当 → 首次手势丢帧/缩放中心漂移；合批时机不当 → 锁定集群与拖拽集群层级错乱。

**落地路径**：
1. 单开分支 `feature/pause-engine`，埋 `idleTimer` + 手势唤醒；
2. 合批仅对 `isLocked && !isFilteredOut` 集群，`PictureRecorder` 生成 `ui.Image` 缓存，`isSolved` 后 `hideBorders` 已有，增量收益；
3. 验收：`PerformanceOverlay` 静置帧率对比 + `batterystats` 10 分钟静置耗电，60Hz 设备目标静置降至 `~1 FPS`（Flame `autoPause`）。

---

## 2) P17 — 全分辨率三重 OOM（`decodeFlameImage` / `Image.memory` 二次解码）

**原文指控**：`lib/game/jigsaw_puzzle_game.dart:27 decodeFlameImage => decodeImageFromList(bytes)` 永不下采样。链路：`widget.imageBytes 1×`（`Uint8List` 常驻）→ `ui.Image RGBA 2048²×4≈16MB`（经 `ImageUpscaler 2×` 后 `4320²≈70MB`）→ `game_page.dart:1130 Image.memory` 覆盖预览触发 `ImageCache 150MB` 内二次解码，再 1×。3~4GB 机必 OOM。

**实测**：定性属实，量化收敛。游戏纹理**未走** `ImageUpscaler`（仅 `crop_puzzle_page.dart:364` 导出链路），`70MB` 需 `4320` 超分才到；但 `3840×2160` `~33MB +8MB+33MB≈74MB` 三重仍成立。`game_page:1130` 已 `cacheWidth:1440` 缓解覆盖预览 1×，仍剩 `bytes+RGBA` 双驻留；`main.dart:85 ImageCache 150MB` 为二次解码上限。

**文档二轮关键纠偏**：**不能按棋盘像素盲降采样**——棋盘纹理即拼图分辨率，`400 块` 每片仅几十像素，玩家会放大到单片占满屏比对接缝，盲缩到 `boardWidth` 会糊掉高难度。正确方向先清浪费、再难度感知。

**为何搁置**：涉及 `GamePage`/`image_source`/`jigsaw_puzzle_game`/`thumbnail` 全链路，需拆**双管线**：
- 游戏管线：按 `max(rows,cols)×48~64px` 预算得 `desiredMaxSide` 再 `clamp(1080,3072)` 封顶，`instantiateImageCodec(targetWidth/targetHeight)` 解码，成功后 `widget.imageBytes = null` 释放，覆盖预览复用已解码 `Texture`（不 `Image.memory`），不进 `2×` 超分；
- 导出管线：`crop` 保留 `ImageUpscaler` 2×；二者不得共用策略。

改动手感与清晰度敏感，阈值选小则高难度糊“无法拼”，选大则 `P01` 泄漏叠加继续峰值，需真机对比。

**强行风险**：`targetWidth` 以 `boardSize` 为基准会直接抹掉高难度细节；以 `rows*cols` 为基准未封顶则 `4320` 仍爆；`Image.memory` 去重需改 `BoardGhost` 复用 `image` 纹理，易改出黑屏。

**落地路径**：
1. 独立分支 `feature/diff-aware-decode`，先做无害部分：`decode` 后 `bytes` 置空 + `game_page 1130` 已做 `cacheWidth` 保留；
2. 后做 `clamp` 封顶 + `rows*cols` 自适应，补 `ImageDescriptor` 探测宽高（`ImmutableBuffer.fromUint8List` 轻量，不全解码）；
3. 验收：`2160/3072/4320` 三档在 3GB 低端机 `adb shell dumpsys meminfo` 峰值回归 + `400块` 放大接缝盲测（与 `crop` 超分对比）。

**当前兜底**：`P06/P14/P15` 已将网络链路 OOM 降至最低，主链路风险可控，`P17` 非热修阻塞。

---

## 3) P23 — `daily_tab_view.dart:107/275` Build 内同步 I/O + 365 次查询

**指控**：`_getAvailableMonths:107 existsSync/listSync` 在 `build:301` 每帧扫盘；`_calculateStreak:275 for offset 0..364` 循环 `365×ProgressStore.getLevelProgress` 在 `build:342`，与 `CustomScrollView` 滚动叠加掉帧。

**实测**：`listSync` 目录仅 `daily/2026MM` 数个，`ms` 级；`getLevelProgress` 为纯内存 `_index[cid]` 哈希 `O(1)`，非解码，热点但非瓶颈；`availableMonths` 已有 `monthSet` 去重，`build` 外层 `Future.wait` 异步，感知弱。

**为何搁置**：正确修复需 `initState` 异步缓存 `availableMonths`/`streak` + `contentUpdateNotifier` 失效刷新，引入异步状态与 `RefreshIndicator` 竞态（下拉刷新与 `AppContent.syncAll` 并发），为微优化引入状态复杂度，性价比低。

**落地路径**：与 `P10` 合并帧率 trace 后，若 `Timeline` 确有 `build` `>16ms` 再动；否则保留现状，补 `// build 内轻量同步，已评估` 注释。

---

## 4) P24 — 散落重叠 / `epsilon` 固定（`puzzle_engine.dart:47` `puzzle_state.dart:49` `puzzle_engine.dart:399` `puzzle_engine.dart:480`）

**指控**：
- `createInitialState:47 nx=-0.15+(c%2?-0.1:1.1)` 偶数列挤 `[-0.25,-0.15)` 0.1 宽，`24×24` 每行 12 块重叠不可选；
- `isSolved/merge` 固定 `epsilon 0.035` 对 `24×24`（`pieceW≈0.041`）阈值偏大，误判锁定/错位；
- `rotateCluster:480 minNx=1 maxNx=0` 对托盘区 `nx∈[-0.25,1.05)` 中心偏差 `~0.02`。

**为何搁置**：重叠仅 `tabletop` 散落模式初始布局拥挤，不影响可玩且 `onGameResize` 已有集群拉回；`epsilon` 改 `1/cols*0.48` 自适应与 `P17` 同源，需 `rows/cols` 维度回归；`rotateCluster` 仅 `rotationEnabled=true` + 集群在托盘时触发，默认 `false`。均为 `P2` 权衡，改值易改手感阈值。

**落地路径**：引擎调优 Epic，补 `24×24` 极端用例单测（`expect` 非重叠 + `isSolved` 临界），再按 `1/cols` 动态化。

---

## 5) P25 — 引擎 `O(N²)/O(N³)` + 渲染全量（`puzzle_state.dart:192` `puzzle_engine.dart:393` `jigsaw_puzzle_game.dart:1022/1872` `game_page.dart:271`）

**指控**：`pieceById` 线性扫 `O(N²)`（450 块 20 万次）、`_mergeAllAdjacentClusters:393 while(changed)双循环 O(N³)`（9000 万次）、`updateHoldingPiecePosition where(clusterId)` `200×120Hz≈48k/秒`、`organizeTray where+length 40k`、`onStateUpdated setState` 全页重建 `AppBar+背景+GameWidget`。

**实测**：`450 块` 为 `L5+` 极端规格（`15×15 225` 主流，`P1.5 36` 以内居多），`compute` 已将 `Zip` 主阻塞移走，`120Hz` 仅 `isTabletop` 散落；主流 `225 块` 实测 `ms` 级，未触发 `ANR`。

**为何搁置**：正确修复需 `Map<int,PieceState>` 索引 + 网格邻接表 + `ValueListenableBuilder` 局部刷新（`progressNotifier` 已有，但 `GamePage` 全 `setState` 需拆），重构 `PuzzleBoardState` 数据结构，回归面覆盖 `拖拽/吸附/撤销/提示/通关` 全链路，测试成本远高于耗时。

**落地路径**：与 `P10` 性能 Epic 合并，`profile` 定量（`Timeline` `resolveSnap` 耗时）后再动；`100 块` 以内不作优化。

---

## 6) P26 — 长期项（`P2-1~12` + 综合 `P1-5~9` 余项）

`snapshot_store.dart:183 saveSync 同步 I/O 阻塞`、`progress_store.dart:837 as int 硬转`、`favorite_store.dart:311 reset 只清内存`、`progress_store:199 init 无并发锁`、`reconcileSnapshots:618 单条 put 中断`（已在 `P21` 局部修复 1 处）、`mainContentPipeline:279 非原子 writeAsString`、`content_http_client:24 无重试`、`content_manager:84 eagerError`、`events_content_pipeline:131 Auto-GC 删使用中文件`、`daily_content_pipeline:31 listSync`、`root_manifest:39 minAppVersion 未用` 等。

**指控**：抽样全属实，多为健壮性/体验权衡，非阻断。

**为何搁置**：分散 `12+` 文件，单点 `P2`，需逐项补 `tmp+rename`/`whereType`（已做 8 处）/`Referer`/退避/`https` 白名单，使用中保护需 `holdingPiece` 状态感知。已在 `P06~P09/P20` 覆盖关键，其余列入技术债队列逐迭代消化，不随本次热修扩大。

---

## 7) P05·P18·P21 残余（已核心修复，残余分支搁置）

- **P05 残余**：`stateBox` 零散 `put`（`economy_service.dart:103 put econ:coins`/`achievement_store.dart:154 put`/`game_repository:859 stat`）未入 `_pendingWrites`。丢失仅影响金币/计数，非进度 `SSOT`（`game-progress-v1` 已闭环），已在 `IMPLEMENTATION-REPORT` 注明二期统一。
- **P18 残余**：3× 峰值已 `dio.download`+`compute` 削至 `~2×`，完全零拷贝需 `archive_io` 流式解压（`randomAccessFile` 流），引入新依赖与异步文件句柄，待 `P17` 分支一并验证。
- **P21 残余**：`GameRepository _levels/_custom` 内存先改回滚——牵 `LevelItem copyWith` + `progress_hydration` + `customPuzzlesNotifier`，需 `init` 水合单测覆盖，风险高于收益，已在 `ProgressStore` 核心回滚后降级。

---

## 验收建议（给研究同学）

| 搁置项 | 必做实验 | 通过标准 |
|---|---|---|
| **P17** | `rows×cols` 自适应 `1080/2160/3072` 三档真机内存峰值 + `400块` 放大接缝盲测 | 3GB 机峰值 `<200MB` 且高难度放大清晰度不劣于 `crop` 超分前 |
| P10 | 静置 10min `batterystats` + `PerformanceOverlay` | 静置 `~1 FPS` 且首手势无丢帧 |
| P25 | `Timeline` `resolveSnap`/`_merge` 耗时 | `450块` `resolveSnap <8ms` |
| P23/P24 | `24×24` 极端布局单测 + 滚动帧率 | `build <16ms` 且无重叠 |

> 关联提交：`26b6539`(P0) `bab9552`(P1) `cbb80b6`(P2) `355d8fe`(终验) `c26032d`(精简报告) 均未 `push`；原始逐行证据见 `IMPLEMENTATION-REPORT-20260904.md`，`flutter analyze 0`/`test 247`/`build windows --debug OK` 已在全量核对章固化。

