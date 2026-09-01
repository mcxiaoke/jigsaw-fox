# P1 修复改动报告（2026-08-31）

> 本报告记录 7 项 P1 级缺陷的修复改动，供代码评审。原始问题清单见 `docs/code-review-20260831-full.md`，交叉核对与修复计划见 `docs/code-review-20260831-cross-check-and-fix-plan.md`。
>
> **修复约束（用户要求）**：只修 bug 和优化性能，不破坏游戏功能，不引入新 bug。

## 一、总览

| 编号 | 文件 | 改动量 | 类别 | 风险 |
|------|------|--------|------|------|
| P1-1 | `lib/logic/engine/puzzle_engine.dart` | ~5 行 | 性能 | 低 |
| P1-5 | `lib/services/sound_service.dart` | ~2 行 | 性能 | 低 |
| P1-21 | `lib/data/snapshot_store.dart` | 0 行（已回退） | 正确性 | 低 |
| P1-23 | `lib/services/app_logger.dart` | 1 行 | 正确性 | 低 |
| P1-4 | `jigsaw_puzzle_game.dart` + `game_page.dart` | ~40 行 | 性能 | 中 |
| P1-7 | `lib/pages/game_page.dart` | ~8 行 | 性能 | 中 |
| P1-2 | `lib/game/jigsaw_puzzle_game.dart` | ~15 行 | 性能 | 中 |
| P1-3 | `lib/logic/engine/puzzle_engine.dart` | ~20 行 | 性能 | 中 |

**验证基线**：`flutter analyze` = 0 issues (4.5s) | `flutter test` = 165/165 通过 (8s)

---

## 二、逐项改动详情

### P1-1 hintFor 比较器全盘重建 EdgeLayout

**位置**：`lib/logic/engine/puzzle_engine.dart:486-493`

**问题**：`hintFor` 中对未归位碎片排序时，比较器内部每次比较都 `new EdgeLayout(rows, cols, seed)`。EdgeLayout 构造会全盘生成所有边缘布局（含 RNG），属于重计算。sort 比较器会被调用 O(n log n) 次，每次重建两个 EdgeLayout 实例，20×20 规格下产生数千次冗余重建。

**修复**：在 sort 前创建一个 EdgeLayout 实例，比较器内只调用 `edgesFor(r, c)`（O(1) 只读查询）。

```dart
// 修复后
final edgeLayout = EdgeLayout(rows: state.rows, cols: state.cols, seed: state.seed);
unplaced.sort((a, b) {
  final aEdges = edgeLayout.edgesFor(a.r, a.c);
  final bEdges = edgeLayout.edgesFor(b.r, b.c);
  // ... 排序逻辑不变
});
```

**为什么不破坏功能**：EdgeLayout 由 (rows, cols, seed) 三元组唯一确定，同一参数下构造结果完全一致；`edgesFor(r,c)` 是纯查询不改状态。提取到 sort 外只是减少重复构造次数，输出序列与原版逐字节一致。

**回归点**：提示功能（hint）给出的推荐顺序应与改动前完全相同。

---

### P1-5 SoundService StackTrace.current 在 release 模式执行

**位置**：`lib/services/sound_service.dart:1, 176`

**问题**：`_caller()` 用于提取调用方栈帧，仅服务于调试日志。原逻辑 `if (!_logCaller) return ''`，但 `_logCaller` 在 release 模式仍可能为 true，导致 `StackTrace.current` 在每次播放音效时执行——栈捕获开销显著（可达毫秒级），高频音效场景拖累帧率。

**修复**：增加 `!kDebugMode` 守卫，release 模式直接跳过；补充 `import 'package:flutter/foundation.dart'`。

```dart
import 'package:flutter/foundation.dart';
// ...
String _caller() {
  if (!kDebugMode || !_logCaller) return '';
  final trace = StackTrace.current.toString().split('\n');
  // ...
}
```

**为什么不破坏功能**：`_caller()` 返回值仅写入调试日志字符串，不参与任何业务判断或播放逻辑；release 模式本就不需要调试调用方信息，返回空串等价于"不记录调用方"。

**回归点**：release 模式音效正常播放；debug 模式日志仍带调用方信息。

---

### P1-21 快照哈希截断导致碰撞概率过高

**位置**：`lib/data/snapshot_store.dart:77`

**问题**：`_shortHash` 用 FNV-1a 生成 64 位哈希，但 `toRadixString(16)` 后 `padLeft(8,'0').substring(0,8)` 只保留前 8 位十六进制（32 位），丢弃一半信息，碰撞概率从设计的 1/2⁶⁴ 退化到 1/2³²。快照 ID 用于持久化索引与缓存键，碰撞可能导致快照互相覆盖。

**修复**：保留完整 64 位（16 位十六进制）。

```dart
// 修复前
return hash.toRadixString(16).padLeft(8, '0').substring(0, 8);
// 修复后
return hash.toRadixString(16).padLeft(16, '0').substring(0, 16);
```

**为什么不破坏功能**：`_shortHash` 返回值作为快照文件名/键的一部分，是字符串拼接而非定长解析；加长不会破坏任何格式约定。padLeft 到 16 保证位数不足时补零对齐。已生成的旧短哈希（8 位）与新哈希（16 位）不会冲突，因为前 8 位相同（同一内容哈希一致），仅长度不同——旧的 8 位快照仍可按原文件名读取，新写入用 16 位。

**注意（review 请核实）**：若存在以旧 8 位哈希为键的持久化数据需迁移，建议确认快照读取逻辑是否对哈希长度敏感。当前代码中 `_shortHash` 仅用于生成新键，不涉及按哈希反查，故无迁移负担。

**回归点**：快照保存/恢复正常；新快照键更长但语义一致。

> **回退说明（2026-08-31 21:47）**：评审证实加长到 16 位后所有旧 8 位快照 100% 失联（文件名长度不同即文件不同），玩家残局进度静默丢失。app 未发布无存量数据，已回退为 `padLeft(8,'0').substring(0,8)`（= HEAD 原值），零迁移零兼容风险。`snapshot_store.dart` 当前零 diff。

---

### P1-23 日志 sink 关闭未 await

**位置**：`lib/services/app_logger.dart:291-293`

**问题**：日志轮转时 `_sink?.close()` 未 await。IOSink.close() 返回 Future，未等待即置 null 并 return，可能导致缓冲日志未刷盘，进程退出时丢失末尾日志。

**修复**：补 `await`。所在方法已是 async，无需改签名。

```dart
// 修复后
await _sink?.close();
_sink = null;
return;
```

**为什么不破坏功能**：仅把同步关闭改为异步等待，行为从"可能丢末尾日志"变为"确保刷盘"。close 完成后才置 null，避免后续误用已关闭句柄。

**回归点**：日志轮转后继续写入正常；退出时日志完整。

---

### P1-4 缩放徽标陈旧 + 整页 setState（zoom 状态源收敛）

**位置**：`lib/game/jigsaw_puzzle_game.dart` + `lib/pages/game_page.dart`（多处）

**问题**：
1. `_onPointerMove`（拖拽平移）和 `_onPointerSignal`（滚轮缩放/托盘滚动）中多处 `setState(() {})` 触发整页重建，但这些操作不改变需要刷新的 UI 状态（平移不改变 zoom，托盘滚动不改变 zoom），属于无效重建。
2. zoom 徽标靠页面侧 `setState` 刷新，但 `_syncResizeTransform`（窗口尺寸变化）和 `resetCurrentGame`（重开游戏）在 game 侧重置 `_zoom` 时无法通知页面，导致徽标陈旧（显示已放大的百分比，实际已复位）。

**修复（zoom 状态源收敛到 game 侧）**：
- `jigsaw_puzzle_game.dart`：新增 `final zoomNotifier = ValueNotifier<double>(1.0)` 字段 + `_setZoom(double v)` 单一写入入口。5 处 `_zoom =` 赋值全部改调 `_setZoom`：`_syncResizeTransform`（窗口尺寸变化）、`zoomAt`、`setZoomAndPan`、`resetZoom`、`resetCurrentGame`。
- `_setZoom` 内 `if (_zoom == v) return;` 守卫消除无变化通知；`SchedulerPhase` 判断：idle 阶段（手势路径）同步写 `zoomNotifier.value`，非 idle 阶段（如 `onGameResize` 在 Flame build 阶段经 LayoutBuilder 调用）推迟到帧末 `addPostFrameCallback` 写，避免触发 "setState() called during build" 断言（debug 红屏）。
- `game_page.dart`：删除页面侧 `_zoomNotifier` 字段及手动赋值；徽标改 `if (_game != null) ValueListenableBuilder<double>(valueListenable: _game!.zoomNotifier, ...)` 订阅 game 侧 SoT；删除 `_onPointerHover` 方法及赋值（Flame `onMouseMove` 已接管吸附跟手）；平移/缩放/托盘滚动分支的 `setState(() {})` 全部移除（zoom 变化由 game.zoomNotifier 自动通知，平移/滚动由 Flame 渲染）。

**为什么不破坏功能**：
- **zoom 收敛**：`_setZoom` 是唯一写入点，所有重置路径（含 `_syncResizeTransform`/`resetCurrentGame`）都自动通知徽标，陈旧问题消除。`_zoom` 字段语义不变，仅增加通知副作用。
- **schedulerPhase 延迟**：手势路径在 idle 阶段执行，仍同步通知，无感知延迟；`onGameResize` 推迟到帧末，徽标在下一帧正确刷新。`addPostFrameCallback` 读 `_zoom`（已同步赋值），值一致。
- **hover 删除**：Flame `onMouseMove(PointerHoverInfo)` 在 `holdingPiece != null` 时调用 `updateHoldingPiecePosition`，与删除的 `_onPointerHover` 逻辑等价。
- **setState 移除**：平移/托盘滚动的视觉变化由 Flame `render` 每帧重绘，不依赖 Widget rebuild。

**回归点**：
- 缩放时徽标百分比实时更新；重置按钮恢复 100%。
- 窗口尺寸变化后徽标正确隐藏（zoom 复位为 1.0）。
- 重开游戏后徽标正确隐藏。
- 鼠标松开吸附跟手正常（由 Flame onMouseMove 接管）。
- 平移、托盘滚动跟手无卡顿。

---

### P1-7 每秒整页 setState（计时器）

**位置**：`lib/pages/game_page.dart`（多处，~8 行）

**问题**：`Timer.periodic` 每秒 `setState(() => _seconds++)` 触发整页重建，仅为了刷新"总用时"文字。整页重建在游戏进行中每秒一次，浪费帧。

**修复**：
- `setState(() => _seconds++)` → `_seconds++; _secondsNotifier.value = _seconds;`（无 setState）。
- 总用时 Text 改为 `ValueListenableBuilder<int>`，仅该 Text 局部刷新。
- `_loadImage` 快照恢复 `_seconds` 时同步 `_secondsNotifier.value = _seconds`。
- 新增 `final _secondsNotifier = ValueNotifier<int>(0)`，`dispose` 中释放。

**为什么不破坏功能**：`_seconds` 字段仍递增（计时逻辑不变），仅把"触发重建"从整页 setState 改为局部 ValueNotifier。`_timeString` getter 读取 `_seconds` 计算，ValueListenableBuilder 在 `_secondsNotifier` 变化时重建该 Text，等价于原行为。快照恢复时同步 notifier，避免恢复后显示旧值。

**回归点**：计时显示正常每秒递增；快照恢复后显示恢复的秒数。

---

### P1-2 updatePieceVisibility O(n²) → O(n)

**位置**：`lib/game/jigsaw_puzzle_game.dart:1577-1605`

**问题**：边缘筛选模式下，原对每片碎片执行 `_pieces.values.where((o) => o.clusterId == p.clusterId).any(...)` 全量扫描集群，判断集群内是否有边缘/已归位碎片。对 n 片每片扫描 n 次，整体 O(n²)，20×20（400 片）时每次筛选约 16 万次比较。

**修复**：先一次 O(n) 遍历预计算 `borderOrSolvedClusters` 集合（含至少一片边缘或已归位碎片的 clusterId），每片只做 `contains` 查询（O(1)），整体降为 O(n)。

```dart
if (_borderFilterActive) {
  final borderOrSolvedClusters = <int>{};
  for (final o in _pieces.values) {
    if (edgeLayout.edgesFor(o.r, o.c).isBorder ||
        _boardState.pieceById(o.id).isSolved(rows, cols)) {
      borderOrSolvedClusters.add(o.clusterId);
    }
  }
  for (final p in _pieces.values) {
    final isBorder = edgeLayout.edgesFor(p.r, p.c).isBorder;
    final statePiece = _boardState.pieceById(p.id);
    final isSolved = statePiece.isSolved(rows, cols);
    p.isFilteredOut = !(isSolved || isBorder ||
        borderOrSolvedClusters.contains(p.clusterId));
  }
} else {
  for (final p in _pieces.values) {
    p.isFilteredOut = false;
  }
}
```

**为什么不破坏功能**：逻辑等价重构。原逻辑"该碎片所在集群内是否存在边缘/已归位碎片" ⟺ 新逻辑"该碎片的 clusterId 是否在 borderOrSolvedClusters 集合中"。集合正是按"集群内至少一片边缘/已归位"标准构建，两者判定结果完全一致。`isBorder`/`isSolved` 仍逐片计算（用于该碎片自身可见性），未改变。

**注意**：改动把 `if (_borderFilterActive) {...} else {...}` 从循环内部提到循环外部（分支提升），减少重复判断；两个分支语义与原版一致。非筛选分支直接全可见。

**回归点**：边缘筛选模式下，边缘碎片、已归位碎片及其同集群碎片可见，纯内部未拼碎片隐藏——与改动前一致。

---

### P1-3 _mergeAllAdjacentClusters 冗余扫描与列表分配

**位置**：`lib/logic/engine/puzzle_engine.dart:369-420`

**问题**：合并相邻集群时：
1. 每次合并执行 `result.where((p) => p.clusterId == pA.clusterId).length` 和 `... == pB.clusterId).length` 两次 O(n) 全量扫描，仅为了取集群大小。合并循环内反复扫描，最坏 O(n²)。
2. `result = result.map((p) => p.copyWith(clusterId: targetId)).toList()` 每次合并分配新列表，O(n) 分配 × 多次合并。

**修复**：
1. 循环前预计算 `clusterSizes` map（clusterId → 片数），合并时 `clusterSizes[id]` O(1) 查询；合并后增量更新（targetId 加上 sourceId 的量，移除 sourceId）。
2. `map().toList()` → in-place `for` 循环原地修改 `result[k] = result[k].copyWith(...)`，无新列表分配。

```dart
final clusterSizes = <int, int>{};
for (final p in result) {
  clusterSizes[p.clusterId] = (clusterSizes[p.clusterId] ?? 0) + 1;
}
// ...
if (dxErr <= epsilon && dyErr <= epsilon) {
  final countA = clusterSizes[pA.clusterId] ?? 0;
  final countB = clusterSizes[pB.clusterId] ?? 0;
  final sourceId = countB >= countA ? pA.clusterId : pB.clusterId;
  final targetId = countB >= countA ? pB.clusterId : pA.clusterId;
  for (var k = 0; k < result.length; k++) {
    if (result[k].clusterId == sourceId) {
      result[k] = result[k].copyWith(clusterId: targetId);
    }
  }
  clusterSizes[targetId] = (clusterSizes[targetId] ?? 0) + (clusterSizes[sourceId] ?? 0);
  clusterSizes.remove(sourceId);
  changed = true;
  break;
}
```

**为什么不破坏功能**：
- **集群大小比较**：`clusterSizes[id]` 与 `result.where(...).length` 返回值相同（同一数据源统计），sourceId/targetId 选择逻辑（大集群吞并小集群）不变。
- **原地更新**：`result[k] = result[k].copyWith(clusterId: targetId)` 与原 `result.map(...).toList()` 对每个元素的处理完全等价，仅改写入方式（原位 vs 新列表）。`copyWith` 语义不变。
- **增量更新 clusterSizes**：合并后 sourceId 的片全部并入 targetId，故 `clusterSizes[targetId] += clusterSizes[sourceId]` 后移除 sourceId，与"重新全量扫描"结果一致。后续合并若涉及 targetId 仍能取到正确大小。

**回归点**：碎片吸附合并行为（大集群吞并小集群、clusterId 更新）与改动前完全一致；多片连续合并结果正确。

---

## 三、验证结果

| 验证项 | 命令 | 结果 |
|--------|------|------|
| 静态分析 | `flutter analyze` | 0 issues (4.5s) |
| 单元测试 | `flutter test` | 165/165 通过 (8s) |

**未覆盖项（建议 review 时手动验证）**：
- P1-4：鼠标松开吸附跟手、Ctrl+滚轮缩放徽标、平移交互。
- P1-2：边缘筛选模式可见性规则。
- P1-3：多片连续吸附合并。
- P1-21：若存在旧 8 位哈希快照的持久化迁移（见该项注意）。

---

## 四、Review 关注点摘要

1. **逻辑等价性**：P1-1/P1-2/P1-3 属算法重构，核心是确认"输出/判定结果与原版逐字节一致"，非行为变更。重点看比较器、集群可见性、合并结果是否等价。
2. **功能完整性**：P1-4 删除 hover 依赖 Flame `onMouseMove` 接管，已验证（`jigsaw_puzzle_game.dart:908-912`），建议实测跟手。
3. **生命周期**：P1-4/P1-7 新增两个 ValueNotifier，均已在 `dispose` 释放，无泄漏。
4. **持久化兼容**：P1-21 哈希加长，旧 8 位键与新 16 位键不冲突（前缀相同），但若有按哈希反查的逻辑需确认。
5. **未改动项**：P0-1（开发测试服务）、P0-5（国际化）已标注暂时搁置；P1-6（多难度存档）、P1-8（通关数口径）待产品决策，本轮未涉及。

---

*报告生成时间：2026-08-31 21:20 GMT+8*
*对应 commit：未提交（工作区改动，待 review 后由用户决定提交）*
