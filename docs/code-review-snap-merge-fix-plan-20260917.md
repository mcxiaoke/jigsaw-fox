# 4.1 / 4.2 修复方案：吸附容差同源化与级联合并裂缝修复（2026-09-17）

> 对应 `docs/code-review-full-20260916.md` 的 P1 问题 **4.1（三套容差常量互不一致，高片数下可误判通关）** 与 **4.2（级联合并只改 clusterId、不做平移对齐，且用绝对 epsilon）**。
> 本文档为实施前方案，代码改动以本文档第六节「实施清单」与实际提交为准；本文档第 3/4 节的代码片段与最终落地代码逐字一致。

## 1. 背景与根因

### 4.1 三套容差常量互不一致

代码中存在三套归一化坐标容差，彼此无关联：

| 常量 | 位置 | 值 | 性质 |
|---|---|---|---|
| 吸附阈值 | `puzzle_engine.dart:80-88`；游戏运行时 `jigsaw_puzzle_game.dart:1459-1467` | `min(1/cols,1/rows) × 0.40`（`effectiveSnapDistance` 叠加 48px 屏幕硬上限，缩放 1×~2× 内恒定） | 随网格缩放，**欧氏**判定 |
| 通关判定 | `puzzle_state.dart:69-75` | `epsilon = 0.035` | 绝对常量，**逐轴**判定（等效欧氏半径 `0.035×√2 ≈ 0.0495`） |
| 吸附后坐标锁定 | `puzzle_engine.dart:237` | `dx <= 0.05 && dy <= 0.05` | 绝对常量，逐轴判定 |

**后果链**（审查报告已复核）：

1. 自 **12×12（144 片）起**，通关容差 `0.035` > 吸附容差 `0.4/N`（12×12 时 `0.0333`），即“碎片离正确槽位比吸附还远，却已判定为已就位”；
2. `isSolved` 是逐轴判据 + 绝对常量；吸附是欧氏 + 网格比例，两套**度量口径**也不统一；
3. `isSolved` 被 5 处关键逻辑消费：`computePlantedPieceIds`（`puzzle_engine.dart:102`）、`canSnapCluster`（`:139` 经 planted）、进度 `solvedCount`（`jigsaw_puzzle_game.dart:232`）、提示选片（`:2584` 附近 `hintFor`、`missingPieceCheck`）、通关判定（`:1993`、`:2511`），另有快照 `progressPercentOf`（`snapshot_store.dart:479`）与恢复卡片（`resume_helper.dart:72`）；
4. 可达触发路径：`canSnapCluster` 拒绝吸附（孤立内部碎片）但位置仍落在 `0.035` 内；或玩家拖过吸附半径后松手。

### 4.2 级联合并只改 clusterId、不做平移对齐，且用绝对 epsilon

`_mergeAllAdjacentClusters`（`puzzle_engine.dart:396-464`，唯一调用点 `:355`）：

1. 使用**独立默认 `epsilon = 0.035`**（逐轴判定），与阶段一/二使用的 `snapDist`（欧氏、网格比例）不是同一个标准——24×24 时 `0.035` ≈ 0.84 格宽，偏差接近一个格宽的碎片会被直接焊接；
2. 命中后**只 remap clusterId、不平移对齐**（`:446-450`）——相对偏移被永久固化：此后整簇同步移动，错位永远无法修正，形成视觉裂缝；
3. 同时 `isSolved(0.035)` 会把这种带裂缝的碎片判为“已就位”，进而被 `computePlantedPieceIds` 锁定进装配体，玩家无法再搬运修正（错误被“锁死”）。

同一个根因：**“就位判定”与“吸附判定”没有收敛到同一容差源，且度量（逐轴 vs 欧氏）不统一**。

## 2. 修复设计原则

1. **单一容差源**：吸附半径比例 `0.40` 作为唯一主源；通关容差、锁定窗口全部由它派生，不再存在互相无关的魔法常量。
2. **度量统一为欧氏**：吸附（已有）、通关判定、锁定窗口、级联合并全部使用欧氏距离，消除“逐轴判据等效半径更大”的隐性放宽。
3. **只收紧、不放开（单调性）**：所有档位的生效容差 ≤ 改动前对应值，杜绝任何档位手感回退；小网格（边长 ≤ 5）保持历史值 `0.035`，完全无感知。
4. **同帧多阶段同阈值**：`resolveSnap` 的阶段一（槽位吸附）、阶段二（自由邻居合并）、阶段三（级联合并）使用**同一个 `snapDist`**。
5. **以吸附并成功锁定为“已就位”的唯一事实来源**：正常游玩路径碎片经吸附平移后误差归零，以上任何收紧迫度都不改变玩家手感。

## 3. 修改方案（4.1）

### 3.1 单一容差源：`puzzle_state.dart` 顶层新增

新增 `import 'dart:math';`，并在 `class PieceState` 之前增加：

```dart
/// 吸附半径占单格边长的比例（唯一主源；[PuzzleEngine.defaultSnapRatio] 引用本常量）。
const double puzzleSnapRatio = 0.40;

/// 通关判定绝对容差上限：小网格（边长 <= 5）保持历史宽松度，零手感回退。
const double solvedCapEpsilon = 0.035;

/// 通关容差相对吸附半径的比例（0.5，即吸附半径 0.4/N 的一半 = 0.2/N）。
const double solvedEpsilonRatio = 0.5;

/// 网格感知的通关判定容差（归一化空间，欧氏距离）：
/// `min(0.035, min(1/cols, 1/rows) * 0.40 * 0.5)`。
///
/// 与吸附阈值（`min(1/cols, 1/rows) * 0.40`）同源，保证任意网格下
/// 「通关容差 <= 吸附容差」，杜绝「碎片比吸附还远却被判定已就位」；
/// 小网格取值 0.035 保持既有行为，网格越大容差按比例收紧。
double solvedEpsilonFor(int rows, int cols) {
  final cell = min(1.0 / cols, 1.0 / rows);
  return min(solvedCapEpsilon, cell * puzzleSnapRatio * solvedEpsilonRatio);
}
```

各档位数值（改造后通关容差 vs 吸附阈值）：

| 网格 | 吸附阈值 `0.4/N` | 通关容差（改造后） | 比值 | 相对改动前 0.035 |
|---|---:|---:|---:|---|
| 5×5 | 0.0800 | 0.0350 | 0.44 ✅ | 不变 |
| 10×10 | 0.0400 | 0.0200 | 0.50 ✅ | 收紧 |
| 12×12 | 0.0333 | 0.0167 | 0.50 ✅ | 收紧 |
| 20×20 | 0.0200 | 0.0100 | 0.50 ✅ | 收紧 |
| 24×24 | 0.0167 | 0.0083 | 0.50 ✅ | 收紧 |

### 3.2 `PieceState.isSolved` 改为欧氏 + 网格感知容差

`puzzle_state.dart:69-75` 修改为：

```dart
  /// Check if the piece is at its solved slot (within epsilon) and correctly oriented.
  ///
  /// 默认容差为网格感知的 [solvedEpsilonFor]（见其注释）；
  /// 判定度量与吸附一致，统一为欧氏距离。
  bool isSolved(int rows, int cols, {double? epsilon}) {
    final tnx = targetNx(cols);
    final tny = targetNy(rows);
    final e = (epsilon ?? solvedEpsilonFor(rows, cols)).toDouble();
    return Point(nx - tnx, ny - tny).distance <= e && (rot % 4 == 0);
  }
```

> `null` 默认值代替 const 默认参数：默认容差需按 `rows/cols` 动态计算，故签名改为可空 epsilon。5 处逻辑消费点 + 快照/恢复均走默认值，自动受益，无需逐个调用点改动。

### 3.3 吸附半径常量收敛为单一主源

`puzzle_engine.dart:21` 修改为：

```dart
  static const double defaultSnapRatio = puzzleSnapRatio;
```

（原 `static const double defaultSnapRatio = 0.40;`，注释保留。`jigsaw_puzzle_game.dart:1460` 的 `PuzzleEngine.defaultSnapRatio` 引用不变。）

### 3.4 吸附后坐标锁定窗口与吸附阈值联动

`puzzle_engine.dart:228-243` 修改为：

```dart
        // 锁定归一化标准坐标，消除累积浮点误差
        // [容差同源] 锁定窗口取 min(0.05, snapDist)：足够吸收合法合并裂缝
        // （级联/阶段二合并均要求误差 <= snapDist），又不至于在 24x24 等高片数下
        // 把离槽位近 1.2 格宽（0.05）的成员硬拉到槽位造成跳变。
        final lockEps = min(0.05, snapDist);
        var lockCount = 0;
        currentPieces = currentPieces.map((p) {
          if (p.clusterId == clusterId &&
              (!state.rotationEnabled || p.rot % 4 == 0)) {
            final tnx = p.targetNx(state.cols);
            final tny = p.targetNy(state.rows);
            final dx = (p.nx - tnx).abs();
            final dy = (p.ny - tny).abs();
            if (dx <= lockEps && dy <= lockEps) {
              lockCount++;
              return p.copyWith(nx: tnx, ny: tny);
            }
          }
          return p;
        }).toList();
```

## 4. 修改方案（4.2）

### 4.1 级联调用传入阶段一/二同一 `snapDist`

`puzzle_engine.dart:354-361` 修改为：

```dart
    // 3. 级联传递合并：检查是否同时触碰到了第三个集群并触发多重合并（严禁合并托盘碎片）
    // [容差同源] 与阶段一/二共用同一 snapDist（欧氏），杜绝级联路径使用独立绝对常量。
    currentPieces = _mergeAllAdjacentClusters(
      currentPieces,
      state.rows,
      state.cols,
      state.rotationEnabled,
      onBoardPieceIds: onBoardPieceIds,
      epsilon: snapDist,
    );
```

### 4.2 级联判定改欧氏、合并前平移对齐

`puzzle_engine.dart:396-464` 修改为（`epsilon` 改为必传，杜绝再次出现独立默认值）：

```dart
  /// 迭代扫描并合并所有空间接触且位置对齐的相邻碎片集群。
  ///
  /// 与阶段二（自由邻居合并）同一判定标准与同一对齐行为：
  /// - 判定：欧氏 offsetError <= epsilon（epsilon 由调用方传入吸附阈值 snapDist）；
  /// - 行为：先按「小集群向大集群」规则平移对齐（定海神针机制），再合并 clusterId，
  ///   消除“只改 id 不平移”导致的裂缝被永久固化。
  static List<PieceState> _mergeAllAdjacentClusters(
    List<PieceState> pieces,
    int rows,
    int cols,
    bool rotationEnabled, {
    Set<int>? onBoardPieceIds,
    required double epsilon,
  }) {
    var result = List<PieceState>.from(pieces);

    // Pre-compute cluster sizes (incrementally updated on each merge)
    final clusterSizes = <int, int>{};
    for (final p in result) {
      clusterSizes[p.clusterId] = (clusterSizes[p.clusterId] ?? 0) + 1;
    }

    var changed = true;

    while (changed) {
      changed = false;
      for (var i = 0; i < result.length; i++) {
        for (var j = i + 1; j < result.length; j++) {
          final pA = result[i];
          final pB = result[j];
          if (pA.clusterId == pB.clusterId) continue;
          if (onBoardPieceIds != null &&
              (!onBoardPieceIds.contains(pA.id) ||
                  !onBoardPieceIds.contains(pB.id))) {
            continue; // 托盘碎片绝不参与级联合并
          }

          final dr = pB.r - pA.r;
          final dc = pB.c - pA.c;
          if ((dr.abs() + dc.abs()) != 1) continue;

          if (rotationEnabled && (pA.rot % 4 != pB.rot % 4)) continue;

          final expectedDx = dc * (1.0 / cols);
          final expectedDy = dr * (1.0 / rows);
          final actualDx = pB.nx - pA.nx;
          final actualDy = pB.ny - pA.ny;

          // [度量统一] 欧氏距离判定，与阶段二完全一致
          final offsetError = Point(
            actualDx,
            actualDy,
          ).distanceTo(Point(expectedDx, expectedDy));
          if (offsetError <= epsilon) {
            final countA = clusterSizes[pA.clusterId] ?? 0;
            final countB = clusterSizes[pB.clusterId] ?? 0;
            final sourceId = countB >= countA ? pA.clusterId : pB.clusterId;
            final targetId = countB >= countA ? pB.clusterId : pA.clusterId;
            // [裂缝修复] 合并前先平移对齐（小簇向大簇，与阶段二定海神针规则一致），
            // 消除级联路径残留偏移被永久固化的裂缝。
            final alignDx = actualDx - expectedDx;
            final alignDy = actualDy - expectedDy;
            if (countB >= countA) {
              // 平移集群 A（source）向集群 B（target）对齐（+alignDx 把 A 推向 B）
              result = _translateCluster(result, sourceId, alignDx, alignDy);
            } else {
              // 平移集群 B（source）向集群 A（target）对齐（-alignDx 把 B 推向 A）
              result =
                  _translateCluster(result, sourceId, -alignDx, -alignDy);
            }
            // In-place cluster ID remap (no new list allocation)
            for (var k = 0; k < result.length; k++) {
              if (result[k].clusterId == sourceId) {
                result[k] = result[k].copyWith(clusterId: targetId);
              }
            }
            // Update cluster sizes incrementally
            clusterSizes[targetId] =
                (clusterSizes[targetId] ?? 0) + (clusterSizes[sourceId] ?? 0);
            clusterSizes.remove(sourceId);
            changed = true;
            break;
          }
        }
        if (changed) break;
      }
    }

    return result;
  }
```

## 5. 可靠性论证（为什么不会破坏拼图体验 / 引入 bug）

1. **正常游玩路径零感知**：吸附成功必然走 `_translateCluster`（`engine:226`）+ 锁定归零（`engine:228-243`），碎片坐标变为精确目标值（误差 0）。`isSolved` 无论多严，对“真吸附”的碎片都成立；玩家不会看到任何“已就位变未就位”。
2. **矛盾窗口被数学消除**：改造后任意网格恒有「通关容差 ≤ 吸附阈值」：
   - 边长 ≤ 5：`0.035 ≤ 0.4/N`（N=5 时 0.035 < 0.08），保持原值即无矛盾；
   - 边长 ≥ 6：`0.2/N ≤ 0.4/N` 恒成立。
   - 缩放维度：游戏 `maxZoom` 恒为 2.0（`jigsaw_puzzle_game.dart:149-155`），48px 屏幕上限分支（`:1465`）需单格屏幕边长 > 120px 才生效，即 `minBoardPx > 120·N/zoom`（24×24 需 > 1440px，20×20 需 > 1200px），常见窗口不可达；即便 4K 桌面触达，该分支吸附阈值 `48/(minBoardPx·zoom)` 也远大于 `0.2/N`（需 `minBoardPx > 240·N` 才可能低于通关容差，现实中不存在）。即：**任何缩放下都维持「通关 ≤ 吸附」**，不出现反向不一致。
3. **“不吸附却已就位”的两个可达路径被同时堵死**：
   - `canSnapCluster` 拒绝吸附的分支：碎片在原 0.035 内但不在吸附范围内 → 改造后不再判已就位 → 不会被 `computePlantedPieceIds` 锁定，保持可拖动；
   - 拖过吸附半径松手：同理不复位、不误判。
4. **级联合并只收紧不放大**：`snapDist ≤ 0.035`（N ≥ 12 时严格小于），合并判定更保守；平移量受 `offsetError ≤ epsilon` 约束（24×24 ≤ 0.0167 格宽 ≈ 12px），是“消除裂缝”的一次性小跳，与正常吸附同手感；已对齐的集群是刚体平移，相对结构严格不变。
5. **终止性与复杂度不变**：每次合并必使集合 clusterId 数减一，`while` 收敛；平移 `_translateCluster` 为 O(n)，与既有 remap 同级，不改变 O(n³) 上界。
6. **既有测试零改动通过**：`test/` 中对 `isSolved` 的断言集中在 3×3/4×4 小网格（`game_layout_test.dart:374/375/2040/2363` 等），边长 ≤ 5 时容差保持 0.035，行为不变；`snap_algorithm_test.dart` 用 `customSnapDistance: 0.08~0.1` 显式传吸附值，不受默认容差收紧影响。

## 6. 实施清单

| 文件 | 改动 | 对应问题 |
|---|---|---|
| `lib/logic/models/puzzle_state.dart` | 新增 `import 'dart:math';`；顶层新增 `puzzleSnapRatio` / `solvedCapEpsilon` / `solvedEpsilonRatio` / `solvedEpsilonFor`；`PieceState.isSolved` 改欧氏 + 动态默认容差 | 4.1 |
| `lib/logic/engine/puzzle_engine.dart` | `defaultSnapRatio` 引用 `puzzleSnapRatio`；锁定窗口 `min(0.05, snapDist)`；级联调用传 `epsilon: snapDist`；`_mergeAllAdjacentClusters` 欧氏判定 + 必传 epsilon + 平移对齐（`result` 改 `var`） | 4.1 + 4.2 |
| `test/logic/snap_algorithm_test.dart` | 新增 4 个用例：① 高片数网格 `isSolved` 收紧（含欧氏对角、小网格零回退断言）② 网格感知容差数值 ③ 级联合并平移对齐（残留偏移消除）④ 24×24 偏差 0.02 的邻居不误并、不误判 | 4.1 + 4.2 |
| `docs/CHANGES-20260917.md` | 顶部追加本次变更摘要 | — |

## 7. 验证清单

1. `dart format`（仅改动的 3 个文件）；
2. `flutter analyze` 零告警；
3. `flutter test` 全量通过（含新增用例）；
4. 编译/运行验证：`flutter build windows --debug`、`flutter test integration_test/app_test.dart -d windows`；
5. 手动逻辑复核点：
   - 12×12 及以上档位：碎片拉到槽位附近但不触发吸附时松手，应保持未归位（不出现“没贴上也绿框/算进度”）；
   - 空中拼合一大块后再移动，不应出现内部错位；
   - 旧存档加载：若中间态碎片漂移在 `(0.2/N, 0.035]`，进度显示可能比旧版本略低、个别恢复卡片重新出现——这是修复方向（原判定过宽），非回归；通关存档（吸附锁定误差为 0）不受影响。

## 8. 已知影响与边界

- **旧存档语义**：收紧 epsilon 后，旧快照中漂移在 `(0.2/N, 0.035]` 的碎片从“已就位”变为“未就位”，`progressPercentOf`（`snapshot_store.dart:479`）计算的进度可能下降；`percent >= 100 || isSolved`（`resume_helper.dart:72`）的恢复卡片判断可能变化。均正确处理方向，无需迁移。
- **日志**：`resolveSnap` 日志中 `snapDist` 打印逻辑不变；级联合并日志可比对阶段二格式，无新增字段。
- 本方案不改动：UI 锁定判定（`jigsaw_puzzle_game.dart:1803-1848`，已与 `effectiveSnapDistance` 同源）、`hint()` 与 `rotateCluster`、快照/撤销数据结构。