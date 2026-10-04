# code-review-20261003.md 核对结论与分批修复计划 · 2026-10-04

> 核对方式：3 个只读子代理并行，逐条对照当前 HEAD `7282ef8` 的实际代码（报告写于 10-03，
> 之后无新代码提交，行号几乎零漂移）。
> 结论速览：**G-1~G-10、D-1~D-7 共 17 条全部属实**，其中 G-1 / G-5 / G-10 的触发条件或
> 表述需修正（见 §2）；工程质量声称基本属实（仅"两个 render()"不可复现）。

---

## 1. 逐条核对结论

| 编号 | 级别 | 结论 | 核对要点（当前行号） |
|---|---|---|---|
| G-1 | 高 | 属实（触发条件需修正） | 三套判据并存：`puzzle_state.dart:21-24,110-116`（solvedEpsilonFor）、`jigsaw_puzzle_game.dart:1517-1525`（effectiveSnapDistance，除以 `minBoardPx×zoom`）、`:1907-1913`（锁定混合判据）、`:2200`（生产下传）、`:1938-1944`（dragStart 只查 isLocked）。死区真实存在 |
| G-2 | 中 | 属实 | `organizeTray:2452` 先 animateTo 槽位 → `:2460` pullback 读旧 `comp.position`（`:2340-2345`）→ `:2389` 二次 animateTo 移除前一 effect（`puzzle_piece_component.dart:487`）并回写错误坐标。仅影响**整理前越界**的碎片——恰是"扫把"最该收拾的对象；对照组 `missingPieceCheck:2971-2973` 有 clearMoveEffects |
| G-3 | 中 | 属实 | `handlePieceDragEnd:2169-2188` 对所有 !isInTray 碎片读瞬时位置；`exportSnapshotJson:2558` 同（经 `game_page.dart:454` _flushSync **会落盘**）；`_syncResizeTransform` 实际在 `:560/613-614/652-653`（报告行号小幅漂移），写 position 不清在途 effect。0.15s 吸附动画期间拖他片松手即可复现写入中间值。注：`_realignTrayPieces` 因托盘碎片有豁免、实际危害有限 |
| G-4 | 中 | 属实 | `puzzle_engine.dart:435-546`：while(changed)（:455）包 O(n²) 双循环（:457-458），每次合并 break 重启（:536-541）；`:487-492` 两次 O(n) any 扫描；`canSnapCluster:148-150` 内层全表线性查找。正常玩法实测无感（4.9ms），属构造场景风险 |
| G-5 | 低 | 属实（表述修正） | 两套阈值：`:2096`（`trayY - pieceSize.y×0.25`）vs `:1474-1477`（`trayY - 20.0`）。修正：pieceSize 是**未缩放基准格尺寸**（`:902/925`），非缩放视觉尺寸；粗网格（≤6 行/列）下 pieceSize.y≥100px 必然越过，分歧带 [trayY−25, trayY−20) 内 dragEnd 写托盘哨兵 ny≥2.0 而 exportSnapshot 判为棋盘碎片，后果具体可复现 |
| G-6 | 低 | 属实 | `rotationEnabled` 唯一构造点 `game_page.dart:355-379` 未传；render 不读 rot（仅 `:73/:196`）；rotateCluster/rotateClockwise/tipRatio 零调用方；`resolveSnap:208/277`（另有 :237/:472）按 rot 拒吸附；isSolved 要求 rot%4==0 且无 UI 可归零 → **开启即永久无法通关** |
| G-7 | 低 | 属实 | undo/redo/resetCurrentGame（`:2585/:2596/:1797`）零调用方；`:2213`（另 hint `:2823`）每次 snap record；`undo_manager.dart:5` 默认 30 份完整 PuzzleBoardState |
| G-8 | 低 | 属实 | hideBorders 全仓仅 3 处：定义 `:76`、render 守卫 `:202`、唯一赋值 `:1861` 置 false，永不置 true |
| G-9 | 低 | 属实 | `:2079-2080` snapCount=affectedIds.length；级联把整簇成员计入（`puzzle_engine.dart:532-534`）；`game_page.dart:406-407` 双通道喂统计；`achievement_service.dart:284-310` 三档 100/500/2000 |
| G-10 | 低 | 属实 | `_maxZoom = max(2, 72/pieceMaxSide)`（`:930-931`，定义 `:146-156`）动态计算，密集拼图可 >2；`:1257` 注释"各难度恒为 2.0"与代码矛盾（但 `_maxZoom≥2` 恒真，注释结论不受影响，仅前提错误） |
| D-1 | 中 | 属实 | save/saveSync 成功即删 .bak（`:197-201/:265-269`）；读失败 `:325-334/:372-374` 仅 FormatException/TypeError 时**直接删正式文件**，全仓无 .bak 提升分支；`.bak` rename 失败被 `:193` 静默吞掉。注：`_cleanupTempFiles:93-103` 只覆盖文件**缺失**场景，不覆盖内容损坏 |
| D-2 | 中 | 属实 | `progress_store.dart:272-294` save 失败回滚内存不 rethrow；`:419` 之后仍返回 playCount+1 的 updatedRecord（`:389/:428-434`）；`game_page.dart:711` 据此判 isFirstCompletion |
| D-3 | 中 | 属实 | `economy_service.dart:208-221` 读改写跨 await；`game_page.dart:789` 无锁、`:1152` 无重入闸门；同仓 `game_repository.dart:774/783` 已有 `_snapStatsLock` 现成模式 |
| D-4 | 低 | 属实 | 3 星按 canonicalId 去重（`:458-464`），daily/custom 裸 incrementCounter（`:467-474`）；daily_7（`:342-350`）可刷；领奖 bypassCap:true（`:565`，注释明确是设计决策） |
| D-5 | 低 | 属实 | `puzzle_state.dart:200/401-402` default_level 回落；守卫只拦空串（`snapshot_store.dart:168-173/:243`）；`game_page.dart:466` saveSync 在 canonicalId 守卫之外**无条件执行** |
| D-6 | 低 | 属实 | reconcileSnapshots 全仓唯一调用 `game_repository.dart:867`（resetAllData）；启动 Group1（`main.dart:173-180`）与 GameRepository.init（`:118-138`）均不对账；自愈仅在玩家点进关卡时触发 |
| D-7 | 低 | 属实 | `resume_helper.dart:72` percent≥100/isSolved 直接 return null，不删文件不清索引；与 `:30-32` 注释语义存在张力，正常路径难达成但与 G-1 耦合后是潜在陷阱 |

**工程质量声称**：98 处 ignore（属实）；无 CI / release.py 不跑 analyze+test / check_local.py 可跳过（属实）；game_layout_test.dart 恰 2915 行（属实）；mainAssemblyPieceIds/clusterCount/maxOverhangRatio 零调用方（属实）；引擎打散坐标在 onLoad 被 `:415` copyWith 整体覆盖（属实，方法现名 `createInitialState`，报告写 `generateScatterState` 为旧名）；3 个 jigsawdata verify 测试静默假绿（属实，实际在 `test/logic/`）；日志 21 处 .info（game 14 + engine 7，属实，AppLogger 实际在 `lib/services/app_logger.dart`，release 下 INFO+ 直接 print 且文件落盘）；输入分发层 0 测试（属实）；"两个 render()"（**不可复现**，test/ 下 0 处 render 调用）。

---

## 2. 对报告的三处修正（修复时需按修正后的理解）

1. **G-1 死区触发条件**：不是"任意 zoom>1"。死区要求 48px 硬上限生效且 `48/(短边×zoom) < solvedEpsilon`，
   即 **短边×zoom > ~1371px（粗网格，solvedEps=0.035）或 cellPx > 240px（细网格）**。
   zoom=1 的大棋盘（短边>1371px）同样可触发；结合 `_maxZoom` 动态（可 >2），大屏放大态必然可达。修复紧迫性不变。
2. **G-5 的 pieceSize**：是未缩放基准格尺寸（boardH/rows），不是随 zoom 缩放的视觉尺寸；
   统一阈值时应以"松手判定语义（回托盘判定带）"为准绳抽单一方法。
3. **G-2 影响面**：pullback 只覆盖**整理前位置越界**的碎片（界内 shift=0 不受影响），
   多片集群收拢本身是预期行为；误伤对象是刚分配了干净槽位的越界散落单片。

---

## 3. 分批修复计划（按"改动小 → 大、收益大 → 小、风险低 → 高"排序）

每批完成后统一验证：`flutter analyze` + `flutter test` + `flutter build windows --debug`；
涉及核心交互的批次加跑 `flutter test .\integration_test\app_test.dart -d windows`。
按仓库规则：代码改动概要追加至 `docs/CHANGES-20261004.md` 顶部，改动文件跑 `dart format`（仅改动文件）。

### 批次 1：小改动、高收益、低风险（建议先做，合计约 80 行）

| # | 项 | 改动点 | 方案 | 风险 |
|---|---|---|---|---|
| 1.1 | **D-1 存档回滚** | `snapshot_store.dart` load `:323-343` / loadJsonString `:364-383` | 读失败（FormatException/TypeError）时：先尝试用 `.bak` 走同一解析，成功则把 .bak 复制回正式文件并返回；失败才处理正式文件——且把 `file.delete()` 改为 rename 成 `.corrupt`（保留人工恢复机会）。save 成功后仍可删 .bak（维持现状） | 低。注意 saveSync 同步路径同样处理；.bak 解析失败时不要误删 .bak |
| 1.2 | **D-3 提示并发** | `economy_service.dart:205-233` + `game_page.dart:785-812/:1152` | EconomyService 加 `_opLock`（复用 `_snapStatsLock` 的 `future = future.then(...)` 模式）串行化 consumeHint；GamePage 加 `_isHintInFlight` 闸门（入口判、finally 释放），按钮 onPressed 纳入判定 | 低。锁内不要再 await 同一把锁的操作 |
| 1.3 | **D-5 孤儿快照** | `game_page.dart:460-466` | `saveSync` 移入 `canonicalId.isNotEmpty` 守卫（与下一行 updateGenericProgress 对齐）；空 cid 时记 warning 跳过 | 极低 |
| 1.4 | **日志降级** | `jigsaw_puzzle_game.dart` 14 处 + `puzzle_engine.dart` 7 处 `.info` | 拖拽/吸附/pullback 常规 trace 降为 `.fine`；保留初始化、通关、异常为 info/warning。收益：release 下不再每次拖拽产生 print + 文件 I/O | 低。降级前确认这些点不承担里程碑语义 |
| 1.5 | **假绿测试改 skip** | `test/logic/jigsawdata_{local,remote,three_channel}_verify_test.dart` | `debugPrint('SKIP'); return;` 改为 `test(..., skip: cond ? null : '原因')`，让跳过在测试报告可见 | 极低 |
| 1.6 | **G-10 注释修正** | `jigsaw_puzzle_game.dart:1257` | 注释"各难度 maxZoom 恒为 2.0"改为"_maxZoom = max(2, 72/pieceMaxSide)，恒 ≥ 2"（对齐 `:930-931` 实际公式） | 零 |

### 批次 2：核心交互正确性（中等改动，约 150 行 + 测试）

| # | 项 | 改动点 | 方案 | 风险 |
|---|---|---|---|---|
| 2.1 | **G-2+G-3 settledPosition（同根，一次修）** | `puzzle_piece_component.dart` + `jigsaw_puzzle_game.dart` | 组件新增动画终点概念：`animateTo` 记录 `_moveTarget`，effect 完成（onComplete）/`clearMoveEffects` 时清空；暴露 `settledPosition => _moveTarget ?? position`。改读点：`handlePieceDragEnd:2169-2188`、`exportSnapshotJson:2558`、`_pullback*` 包围盒（`:2340-2345`）与目标计算（`:2384-2399`，target=settledPosition+shift，先 clearMoveEffects 再 animateTo）、`_syncResizeTransform:560` 写 position 前 clearMoveEffects。这同时根治 G-2（pullback 基于散落目标位计算 shift，不再覆盖槽位） | 中。需确认 Flame MoveEffect onComplete 可靠；debug 下 `_debugAssertClusterGridInvariant` 会立刻暴露遗漏的读点，是天然验收器 |
| 2.2 | **G-1 统一"就位"判据（最小方案）** | `jigsaw_puzzle_game.dart:1907-1913` + solvedCount 统计处 | 两步：① 锁定容差改 `snappedDist <= max(snapDistLock, solvedEpsilonFor(rows,cols))`——保证"判为已就位（isSolved/planted）必可锁定"，消除"已就位但可拖走/拖走整簇"；② 进度口径（solvedCount/progressPercent 分子）改为只统计 planted（锁定）碎片，与吸附手感一致。**不动 `isSolved` 本身**（引擎 planted 种子筛选与吸附逻辑依赖它，避免连锁） | 中。进度数字语义会微调；补回归测试："生产容差表 + isSolved⟹可锁定 + planted⟺计入进度"进 `snap_algorithm_test.dart` |
| 2.3 | **D-2 落盘失败判定** | `progress_store.dart:272-294/:419-434` + `game_page.dart:711` | save 增加成功回报（新增 `Future<bool> trySave` 或可选 out 参数，不动现有签名）；`recordDifficultyCompletion` 保存失败时返回 `savedSuccessfully:false`（record 维持旧值不 +1）；`_handleSolved` 的 isFirstCompletion 增加该条件 | 低 |
| 2.4 | **D-6 启动对账** | `game_repository.dart:118-138`（init 末尾） | init 完成 `unawaited(reconcileSnapshots())` 后台对账（不阻塞启动），替代"等玩家点进关卡才自愈" | 低。确认对账失败仅记日志不抛 |
| 2.5 | **D-7 100% 僵尸快照清理** | `resume_helper.dart:72` | percent≥100/isSolved 分支 return null 前先删快照文件 + 清 hasSnapshot/activeDifficultyKey（复用 `:64-71` 清理路径）。实施前确认 `:30-32` "已通关残局可续玩"注释的产品意图——若需保留该语义则改为仅清索引不清文件 | 低 |

批次 2 附带补测试（报告 P1-6）：`effectiveSnapDistance` 生产容差表（覆盖 48px 上限与死区边界）、`_clampDragTarget` 边界、`updatePieceVisibility` 筛选态。

### 批次 3：统计口径与性能（低优先，可按需做）

| # | 项 | 改动点 | 方案 | 风险 |
|---|---|---|---|---|
| 3.1 | **G-9 吸附统计口径** | `jigsaw_puzzle_game.dart:2079-2080` | snapCount 改为"本步新进入 isSolved 且 planted"的碎片数（用 `_applySnapSettlement` 已在作用域内的 prevState 对比过滤） | 低。只影响未来累计，不回收已达成成就 |
| 3.2 | **D-4 daily_solved 去重** | `achievement_service.dart:467-474` | daily 改用按 canonicalId 的 starred 去重（对齐 3 星逻辑）；**需先定语义**："完成 7 次每日挑战"按次数还是按图；老玩家已累计计数是否迁移 | 低（语义需拍板） |
| 3.3 | **G-4 引擎优化（可选）** | `puzzle_engine.dart:136-154/:435-546` | ① 增量维护 `clusterHasSolved` 消除 `:487-492` 的 O(n) any；② `canSnapCluster` 用 `r*cols+c → clusterId` 空间哈希替代线性查找；③ while(changed) 重启改队列传播。**正常玩法实测 4.9ms 无感，仅超大集群场景有感**，改核心算法需基准对比（复刻 PROBE-3/8/13 探针）后再合入 | 中。核心算法，需全量测试 + 探针回归 |

### 批次 4：需产品决策的死代码 + 工程基建

| # | 项 | 决策点 | 建议 |
|---|---|---|---|
| 4.1 | **G-6 旋转链路** | 删除整链 vs 补齐（渲染旋转+交互+测试） | 建议删除（`rotationEnabled` 参数、`resolveSnap` 的 rot 分支、`rotateCluster`、`PieceEdges.rotateClockwise`、`PieceShape(tipRatio:)`）；至少先做一行保险：`rotationEnabled=true` 时断言/强制 false，杜绝"打开即坏" |
| 4.2 | **G-7 undo/redo** | 接 UI（撤销按钮，拼图核心预期功能）vs 摘掉 record（1 行，省 30×576 个 PieceState 常驻内存） | 建议先摘 record（`:2213/:2823`）止血，撤销功能单独立项 |
| 4.3 | **G-8 hideBorders 接线** | 前提：验证底板确实在通关后渲染整图 | 若验证成立，`onSolved` 时置 true（真实 GPU 收益：576 次 clipPath → 1 次整图）；否则删除字段与注释 |
| 4.4 | **CI 门禁** | `.github/workflows/ci.yml` 跑 analyze+test；`scripts/release.py` 加前置 | 建议做，成本极低 |
| 4.5 | **死代码清理** | `mainAssemblyPieceIds`/`clusterCount`/`maxOverhangRatio`、`resetCurrentGame`、`createInitialState` 废算坐标 | 按第 6 节表格逐项删或接 |
| 4.6 | **P3 重构** | 拆 `jigsaw_puzzle_game.dart`（2996 行）/ `game_layout_test.dart`（2915 行） | 单独立项，不与本轮修复混做 |

---

## 4. 风险提示

- 批次 2.1（settledPosition）与 2.2（判据统一）触及核心交互与进度语义，**必须**配回归测试并过集成测试；
  两项各自独立成 commit，便于回滚。
- G-1 的进度口径修正会让进度数字与旧版本有细微差异（更保守），属预期行为。
- D-1 改动后建议补 3 条单测：正式文件损坏+.bak 完好→恢复；两者皆坏→.corrupt 保留+返回空；
  正常保存后 .bak 清理行为不变。
