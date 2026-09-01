import 'dart:math';

import 'package:logging/logging.dart';

import '../../services/app_logger.dart';
import '../geometry/edge_layout.dart';
import '../models/puzzle_state.dart';

/// 纯领域逻辑拼图核心引擎（Pure Domain Logic Engine）。
///
/// 【职责范围】：
/// 独立于 UI 渲染层与游戏引擎，负责拼图网格拓扑状态计算、
/// 碎片网格槽位吸附（Board Slot Snapping）、碎片集群自由合并（Cluster Merging / Disjoint Set）、
/// 碎片旋转中心计算、智能提示（Hint）及最终通关判定（Solved State Check）。
class PuzzleEngine {
  /// 默认吸附容差阈值比例（单块碎片尺寸的 48%）。
  /// 【选值依据】：
  /// 48% 是经过大量手感测试的黄金手感比例：既能保证玩家拖到目标附近时有清晰痛快的“自动就位吸附感”，
  /// 又不会在密集拖动时误触发旁边不相干的槽位。
  static const double defaultSnapRatio = 0.40;

  /// 生成打散后的初始拼图棋盘状态（Scatter Pieces）。
  ///
  /// 【算法过程】：
  /// 1. 使用固定关卡种子 [seed] 初始化 PRNG；
  /// 2. 若启用旋转难度（[rotationEnabled]），随机分配 0~3 次 90° 初始旋转；
  /// 3. 将碎片初始散落分布在棋盘两侧的边缘区域，确保不会开局直接落在正确答案槽位上。
  static PuzzleBoardState createInitialState({
    required int rows,
    required int cols,
    required int seed,
    bool rotationEnabled = false,
    String levelId = 'default_level',
  }) {
    AppLogger.engine.info('createInitialState rows=$rows cols=$cols seed=$seed rotation=$rotationEnabled levelId=$levelId');
    final rng = Random(seed);
    final pieces = <PieceState>[];

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final id = r * cols + c;
        final rot = rotationEnabled ? rng.nextInt(4) : 0;

        // 初始散落位置分布在棋盘两侧（左侧/右侧），避免开局直接落入正确槽位
        final nx = -0.15 + (c % 2 == 0 ? -0.1 : 1.1) + rng.nextDouble() * 0.1;
        final ny = (r / rows) + (rng.nextDouble() - 0.5) * 0.1;

        pieces.add(
          PieceState(
            id: id,
            r: r,
            c: c,
            nx: nx,
            ny: ny,
            clusterId: id,
            rot: rot,
          ),
        );
      }
    }

    final state = PuzzleBoardState(
      rows: rows,
      cols: cols,
      seed: seed,
      rotationEnabled: rotationEnabled,
      pieces: pieces,
      levelId: levelId,
    );
    AppLogger.engine.fine('createInitialState done pieces=${pieces.length}');
    return state;
  }

  /// 计算归一化坐标系下的实际吸附距离阈值。
  ///
  /// 【公式】：`min(1.0 / cols, 1.0 / rows) * ratio`
  static double calculateSnapThreshold(int rows, int cols, [double ratio = defaultSnapRatio]) {
    final pieceW = 1.0 / cols;
    final pieceH = 1.0 / rows;
    return min(pieceW, pieceH) * ratio;
  }

  /// 判断 [pieceId] 是否处于棋盘边缘。
  static bool isBorderPiece(int rows, int cols, int r, int c) =>
      r == 0 || r == rows - 1 || c == 0 || c == cols - 1;

  /// 返回“已就位装配体”所覆盖的碎片 id 集合（连通到棋盘边缘的吸附片）。
  ///
  /// 【现实拼图/WebJigex 连通规则】：以 4-连通对“已正确就位（isSolved）”的碎片分连通分量，
  /// 当某连通分量内含**至少一个边缘碎片**（即该装配体真正触碰并长出棋盘边框）时，
  /// 该分量的所有成员视为“已植入/不可移动”；否则（空中孤岛）保持游离可拖动。
  static Set<int> computePlantedPieceIds(PuzzleBoardState state) {
    final rows = state.rows, cols = state.cols;
    final snapped = state.pieces.where((p) => p.isSolved(rows, cols)).toList();
    final byCell = {for (final p in snapped) '${p.r},${p.c}': p.id};
    const offsets = [( -1, 0), (1, 0), (0, -1), (0, 1)];
    final planted = <int>{};
    final visited = <int>{};
    for (final seed in snapped) {
      if (visited.contains(seed.id)) continue;
      // 对一个连通分量做 BFS
      final component = <int>{};
      final queue = <int>[seed.id];
      visited.add(seed.id);
      var qi = 0;
      var touchesBorder = false;
      while (qi < queue.length) {
        final id = queue[qi++];
        final cur = state.pieceById(id);
        component.add(id);
        if (isBorderPiece(rows, cols, cur.r, cur.c)) touchesBorder = true;
        for (final (dr, dc) in offsets) {
          final nid = byCell['${cur.r + dr},${cur.c + dc}'];
          if (nid != null && visited.add(nid)) queue.add(nid);
        }
      }
      if (touchesBorder) planted.addAll(component);
    }
    return planted;
  }

  /// 判断目标集群是否“可以被吸附”到棋盘槽位（连通到已就位装配体）。
  ///
  /// 允许吸附需满足：集群含**边缘碎片**（触边），或集群某成员的目标正交邻格
  /// 已被“已植入装配体”占据（能顺势接上边框长出的装配体）。孤立内部碎片/岛屿
  /// 既不在边缘也不邻接已植入装配体 → 拒绝吸附，保持自由拖动（对应 WebJigex 的“无邻居不吸附”）。
  static bool canSnapCluster(PuzzleBoardState state, Iterable<PieceState> clusterPieces) {
    final planted = computePlantedPieceIds(state);
    const offsets = [( -1, 0), (1, 0), (0, -1), (0, 1)];
    for (final p in clusterPieces) {
      if (isBorderPiece(state.rows, state.cols, p.r, p.c)) return true;
      for (final (dr, dc) in offsets) {
        final nr = p.r + dr, nc = p.c + dc;
        if (nr < 0 || nr >= state.rows || nc < 0 || nc >= state.cols) continue;
        for (final q in state.pieces) {
          if (q.r == nr && q.c == nc && planted.contains(q.id)) return true;
        }
      }
    }
    return false;
  }

  /// 在玩家松手释放碎片后，执行吸附计算与集群合并（Snap & Cluster Merging）。
  ///
  /// 【核心两阶段吸附判定】：
  /// 1. **阶段一：棋盘标准槽位吸附（Board Slot Snapping）**
  ///    - 遍历拖拽集群中的每块碎片，检查是否与棋盘上的目标绝对位置槽位 `(targetNx, targetNy)` 距离小于 [snapDist]；
  ///    - 若满足且角度归零，则将整个集群平移就位并锁定精确坐标。
  /// 2. **阶段二：自由邻居碎片合并（Free-floating Neighbor Merging）**
  ///    - 若未吸附到棋盘槽位，检查是否与空中其他同角度邻居碎片（上/下/左/右正交邻居）发生碰撞；
  ///    - 若相对间距误差小于 [snapDist]，将两组碎片精准对齐并合并为一个新的大集群（统一 clusterId）。
  static BoardTransitionResult resolveSnap({
    required PuzzleBoardState state,
    required int draggedPieceId,
    Set<int>? onBoardPieceIds,
    double? customSnapDistance,
  }) {
    final snapDist = customSnapDistance ??
        calculateSnapThreshold(state.rows, state.cols);
    if (AppLogger.engine.isLoggable(Level.FINE)) {
      AppLogger.engine.fine('resolveSnap start dragged=$draggedPieceId cluster snapDist=$snapDist onBoard=${onBoardPieceIds?.length ?? 0} rows=${state.rows} cols=${state.cols}');
    }

    final draggedPiece = state.pieceById(draggedPieceId);
    final clusterId = draggedPiece.clusterId;
    final clusterPieces = state.piecesInCluster(clusterId);

    // 如果指定了棋盘有效碎片且当前被拖拽碎片不在其中，直接返回
    if (onBoardPieceIds != null && !onBoardPieceIds.contains(draggedPieceId)) {
      AppLogger.engine.fine('resolveSnap skipped piece $draggedPieceId not on board (tray)');
      return BoardTransitionResult(
        state: state,
        didSnap: false,
        didMerge: false,
        affectedPieceIds: [draggedPieceId],
        isCompleted: state.isSolved,
      );
    }

    var currentPieces = List<PieceState>.from(state.pieces);
    var didSnap = false;
    var didMerge = false;
    final affectedIds = <int>{...clusterPieces.map((p) => p.id)};

    // 1. 检查是否吸附到棋盘槽位
    // [连通规则] 先判定整簇是否可与“已就位装配体（连通到边缘）”接上。
    // 未连通（孤立内部碎片/岛屿）的集群禁止吸附到槽位，保持自由可拖动 →
    // 不仅修复“孤立片位正却锁死”，也符合 WebJigex“无邻居不吸附”的手感。
    final snapAllowed = canSnapCluster(state, clusterPieces);
    for (final piece in clusterPieces) {
      if (state.rotationEnabled && piece.rot % 4 != 0) {
        continue; // 角度未摆正无法吸附进槽位
      }
      final targetNx = piece.targetNx(state.cols);
      final targetNy = piece.targetNy(state.rows);
      final dist = Point(piece.nx, piece.ny).distanceTo(Point(targetNx, targetNy));

      if (dist <= snapDist) {
        // 集群未与边缘装配体连通 → 拒绝吸附到槽位，保持游离可移动（仍可走阶段二与邻居试合并）
        if (!snapAllowed) {
          break;
        }
        // 计算平移差量并移动整个集群
        final dx = targetNx - piece.nx;
        final dy = targetNy - piece.ny;

        currentPieces = _translateCluster(
          currentPieces,
          clusterId,
          dx,
          dy,
        );

        // 锁定归一化标准坐标，消除累积浮点误差
        var lockCount = 0;
        currentPieces = currentPieces.map((p) {
          if (p.clusterId == clusterId && (!state.rotationEnabled || p.rot % 4 == 0)) {
            final tnx = p.targetNx(state.cols);
            final tny = p.targetNy(state.rows);
            final dx = (p.nx - tnx).abs();
            final dy = (p.ny - tny).abs();
            if (dx <= 0.05 && dy <= 0.05) {
              lockCount++;
              return p.copyWith(nx: tnx, ny: tny);
            }
          }
          return p;
        }).toList();

        didSnap = true;
        AppLogger.engine.info('BoardSlot snap piece=${piece.id} r=${piece.r} c=${piece.c} dist=${dist.toStringAsFixed(4)} snapDist=${snapDist.toStringAsFixed(4)} cluster=$clusterId lockCascadeCount=$lockCount');
        break;
      }
    }

    // 2. 检查与空中其他碎片的邻居正交相对吸附与集群合并（严禁合并托盘碎片）
    final activeClusterPieces = currentPieces.where((p) => p.clusterId == clusterId).toList();

    for (final pA in activeClusterPieces) {
      for (final pB in currentPieces) {
        if (pB.clusterId == clusterId) continue; // 同一集群，跳过
        if (onBoardPieceIds != null && !onBoardPieceIds.contains(pB.id)) {
          continue; // 托盘中的碎片严禁参与空间邻居合并
        }

        final dr = pB.r - pA.r;
        final dc = pB.c - pA.c;
        final isOrthogonalNeighbor = (dr.abs() + dc.abs()) == 1;
        if (!isOrthogonalNeighbor) continue;

        if (state.rotationEnabled && (pA.rot % 4 != pB.rot % 4)) {
          continue; // 旋转角度不一致无法拼合
        }

        final expectedDx = dc * (1.0 / state.cols);
        final expectedDy = dr * (1.0 / state.rows);

        final actualDx = pB.nx - pA.nx;
        final actualDy = pB.ny - pA.ny;

        final offsetError = Point(actualDx, actualDy).distanceTo(Point(expectedDx, expectedDy));

        if (offsetError <= snapDist) {
          final alignDx = actualDx - expectedDx;
          final alignDy = actualDy - expectedDy;

          // 主装配体保护判定：小集群平移对齐向大集群（定海神针机制）
          final countA = activeClusterPieces.length;
          final countB = currentPieces.where((p) => p.clusterId == pB.clusterId).length;

          if (countB >= countA) {
            // 集群 B 规模更大（为主装配体），平移集群 A 向集群 B 对齐
            currentPieces = _translateCluster(
              currentPieces,
              clusterId,
              alignDx,
              alignDy,
            );

            // 将集群 A 并入集群 B
            final targetClusterId = pB.clusterId;
            currentPieces = currentPieces.map((p) {
              if (p.clusterId == clusterId) {
                return p.copyWith(clusterId: targetClusterId);
              }
              return p;
            }).toList();

            affectedIds.addAll(currentPieces.where((p) => p.clusterId == targetClusterId).map((p) => p.id));
          } else {
            // 集群 A 规模更大（为主装配体），平移小集群 B 向集群 A 对齐，集群 A 纹丝不动
            currentPieces = _translateCluster(
              currentPieces,
              pB.clusterId,
              -alignDx,
              -alignDy,
            );

            // 将小集群 B 并入集群 A
            final sourceClusterId = pB.clusterId;
            currentPieces = currentPieces.map((p) {
              if (p.clusterId == sourceClusterId) {
                return p.copyWith(clusterId: clusterId);
              }
              return p;
            }).toList();

            affectedIds.addAll(currentPieces.where((p) => p.clusterId == clusterId).map((p) => p.id));
          }

          didSnap = true;
          didMerge = true;
          AppLogger.engine.info('ClusterMerge pA=${pA.id}(${pA.r},${pA.c}) pB=${pB.id}(${pB.r},${pB.c}) offsetErr=${offsetError.toStringAsFixed(4)} snapDist=${snapDist.toStringAsFixed(4)} countA=$countA countB=$countB');
          break;
        }
      }
      if (didMerge) break;
    }

    // 3. 级联传递合并：检查是否同时触碰到了第三个集群并触发多重合并（严禁合并托盘碎片）
    currentPieces = _mergeAllAdjacentClusters(
      currentPieces,
      state.rows,
      state.cols,
      state.rotationEnabled,
      onBoardPieceIds: onBoardPieceIds,
    );

    final newState = state.copyWith(pieces: currentPieces);
    if (didSnap || didMerge || newState.isSolved) {
      AppLogger.engine.info('resolveSnap result dragged=$draggedPieceId didSnap=$didSnap didMerge=$didMerge affected=${affectedIds.length} isCompleted=${newState.isSolved}');
    } else if (AppLogger.engine.isLoggable(Level.FINE)) {
      AppLogger.engine.fine('resolveSnap no snap dragged=$draggedPieceId');
    }
    return BoardTransitionResult(
      state: newState,
      didSnap: didSnap,
      didMerge: didMerge,
      affectedPieceIds: affectedIds.toList(),
      isCompleted: newState.isSolved,
    );
  }

  /// 将指定集群 [clusterId] 内的所有碎片整体平移 (dx, dy)。
  static List<PieceState> _translateCluster(
    List<PieceState> pieces,
    int clusterId,
    double dx,
    double dy,
  ) {
    return pieces.map((p) {
      if (p.clusterId == clusterId) {
        return p.copyWith(
          nx: p.nx + dx,
          ny: p.ny + dy,
        );
      }
      return p;
    }).toList();
  }

  /// 迭代扫描并合并所有空间接触且位置对齐的相邻碎片集群。
  static List<PieceState> _mergeAllAdjacentClusters(
    List<PieceState> pieces,
    int rows,
    int cols,
    bool rotationEnabled, {
    Set<int>? onBoardPieceIds,
    double epsilon = 0.035,
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
              (!onBoardPieceIds.contains(pA.id) || !onBoardPieceIds.contains(pB.id))) {
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

          final dxErr = (actualDx - expectedDx).abs();
          final dyErr = (actualDy - expectedDy).abs();
          if (dxErr <= epsilon && dyErr <= epsilon) {
            final countA = clusterSizes[pA.clusterId] ?? 0;
            final countB = clusterSizes[pB.clusterId] ?? 0;
            final sourceId = countB >= countA ? pA.clusterId : pB.clusterId;
            final targetId = countB >= countA ? pB.clusterId : pA.clusterId;
            // In-place cluster ID remap (no new list allocation)
            for (var k = 0; k < result.length; k++) {
              if (result[k].clusterId == sourceId) {
                result[k] = result[k].copyWith(clusterId: targetId);
              }
            }
            // Update cluster sizes incrementally
            clusterSizes[targetId] = (clusterSizes[targetId] ?? 0) + (clusterSizes[sourceId] ?? 0);
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

  /// 将单块碎片或其所属的整个集群顺时针旋转 90°。
  ///
  /// 【旋转几何中心】：
  /// 计算整个集群的包围盒几何中心点 `(centerNx, centerNy)`，
  /// 所有成员绕此中心应用标准 2D 旋转矩阵 `(x, y) -> (-y, x)` 进行坐标更新。
  static PuzzleBoardState rotateCluster({
    required PuzzleBoardState state,
    required int pieceId,
  }) {
    final targetPiece = state.pieceById(pieceId);
    final clusterId = targetPiece.clusterId;
    final clusterPieces = state.piecesInCluster(clusterId);
    AppLogger.engine.info('rotateCluster piece=$pieceId cluster=$clusterId size=${clusterPieces.length}');

    // 计算集群几何中心
    var minNx = 1.0, maxNx = 0.0, minNy = 1.0, maxNy = 0.0;
    for (final p in clusterPieces) {
      minNx = min(minNx, p.nx);
      maxNx = max(maxNx, p.nx + 1.0 / state.cols);
      minNy = min(minNy, p.ny);
      maxNy = max(maxNy, p.ny + 1.0 / state.rows);
    }
    final centerNx = (minNx + maxNx) / 2.0;
    final centerNy = (minNy + maxNy) / 2.0;

    final updated = state.pieces.map((p) {
      if (p.clusterId != clusterId) return p;

      final relX = p.nx + (0.5 / state.cols) - centerNx;
      final relY = p.ny + (0.5 / state.rows) - centerNy;

      // 顺时针 90° 旋转: (x, y) -> (-y, x)
      final newRelX = -relY;
      final newRelY = relX;

      final newNx = centerNx + newRelX - (0.5 / state.cols);
      final newNy = centerNy + newRelY - (0.5 / state.rows);

      return p.copyWith(
        nx: newNx,
        ny: newNy,
        rot: (p.rot + 1) % 4,
      );
    }).toList();

    return state.copyWith(pieces: updated);
  }

  /// 智能提示（Hint）算法：优先挑选最具策略价值的未归位碎片（如角块、边块）。
  static HintResult hintFor(PuzzleBoardState state) {
    // 1. 找出所有未到达目标正确槽位的碎片
    final unplaced = state.pieces.where((p) => !p.isSolved(state.rows, state.cols)).toList();
    if (unplaced.isEmpty) {
      AppLogger.engine.info('hintFor all solved pieces=${state.pieces.length}');
      return HintResult(pieceId: state.pieces.first.id, targetNx: 0, targetNy: 0);
    }

    // 2. 策略优先级排序：角块 (Corner) > 边块 (Border) > 内部块 (Center)
    final edgeLayout = EdgeLayout(rows: state.rows, cols: state.cols, seed: state.seed);
    unplaced.sort((a, b) {
      final aEdges = edgeLayout.edgesFor(a.r, a.c);
      final bEdges = edgeLayout.edgesFor(b.r, b.c);
      if (aEdges.isCorner && !bEdges.isCorner) return -1;
      if (!aEdges.isCorner && bEdges.isCorner) return 1;
      if (aEdges.isBorder && !bEdges.isBorder) return -1;
      if (!aEdges.isBorder && bEdges.isBorder) return 1;
      return a.id.compareTo(b.id);
    });

    final targetPiece = unplaced.first;
    AppLogger.engine.info('hintFor target=${targetPiece.id} r=${targetPiece.r} c=${targetPiece.c} unplaced=${unplaced.length}');
    return HintResult(
      pieceId: targetPiece.id,
      targetNx: targetPiece.targetNx(state.cols),
      targetNy: targetPiece.targetNy(state.rows),
    );
  }
}

/// 碎片移动放置计算结果对象
class BoardTransitionResult {
  const BoardTransitionResult({
    required this.state,
    required this.didSnap,
    required this.didMerge,
    required this.affectedPieceIds,
    required this.isCompleted,
  });

  final PuzzleBoardState state;
  final bool didSnap;
  final bool didMerge;
  final List<int> affectedPieceIds;
  final bool isCompleted;
}

/// 智能提示目标坐标与目标碎片结构体
class HintResult {
  const HintResult({
    required this.pieceId,
    required this.targetNx,
    required this.targetNy,
  });

  final int pieceId;
  final double targetNx;
  final double targetNy;
}
