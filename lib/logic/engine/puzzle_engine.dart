import 'dart:math';

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
  static const double defaultSnapRatio = 0.48;

  /// 生成打散后的初始拼图棋盘状态（Scatter Pieces）。
  ///
  /// 【算法过程】：
  /// 1. 使用固定关卡种子 [seed] 初始化 PRNG；
  /// 2. 若启用旋转难度（[rotationEnabled]），随机分配 0~3 次 90° 初始旋转；
  /// 3. 将碎片散落在棋盘四周的边缘托盘区域，并做防重叠校验，确保不会开局直接落在正确答案槽位上。
  static PuzzleBoardState createInitialState({
    required int rows,
    required int cols,
    required int seed,
    bool rotationEnabled = false,
    String levelId = 'default_level',
  }) {
    final rng = Random(seed);
    final pieces = <PieceState>[];

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final id = r * cols + c;
        final rot = rotationEnabled ? rng.nextInt(4) : 0;

        // 打散位置尝试：避免开局直接落入正确槽位
        double sx, sy;
        for (var attempt = 0; attempt < 100; attempt++) {
          sx = -0.2 + rng.nextDouble() * 1.4;
          sy = -0.2 + rng.nextDouble() * 1.4;
          final tnx = c / cols;
          final tny = r / rows;
          if ((sx - tnx).abs() > 0.15 || (sy - tny).abs() > 0.15) {
            break;
          }
        }

        pieces.add(
          PieceState(
            id: id,
            r: r,
            c: c,
            nx: -0.15 + (c % 2 == 0 ? -0.1 : 1.1) + rng.nextDouble() * 0.1,
            ny: (r / rows) + (rng.nextDouble() - 0.5) * 0.1,
            clusterId: id,
            rot: rot,
          ),
        );
      }
    }

    return PuzzleBoardState(
      rows: rows,
      cols: cols,
      seed: seed,
      rotationEnabled: rotationEnabled,
      pieces: pieces,
      levelId: levelId,
    );
  }

  /// 计算归一化坐标系下的实际吸附距离阈值。
  ///
  /// 【公式】：`min(1.0 / cols, 1.0 / rows) * ratio`
  static double calculateSnapThreshold(int rows, int cols, [double ratio = defaultSnapRatio]) {
    final pieceW = 1.0 / cols;
    final pieceH = 1.0 / rows;
    return min(pieceW, pieceH) * ratio;
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

    final draggedPiece = state.pieceById(draggedPieceId);
    final clusterId = draggedPiece.clusterId;
    final clusterPieces = state.piecesInCluster(clusterId);

    // 如果指定了棋盘有效碎片且当前被拖拽碎片不在其中，直接返回
    if (onBoardPieceIds != null && !onBoardPieceIds.contains(draggedPieceId)) {
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
    for (final piece in clusterPieces) {
      if (state.rotationEnabled && piece.rot % 4 != 0) {
        continue; // 角度未摆正无法吸附进槽位
      }
      final targetNx = piece.targetNx(state.cols);
      final targetNy = piece.targetNy(state.rows);
      final dist = Point(piece.nx, piece.ny).distanceTo(Point(targetNx, targetNy));

      if (dist <= snapDist) {
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
        currentPieces = currentPieces.map((p) {
          if (p.clusterId == clusterId && (!state.rotationEnabled || p.rot % 4 == 0)) {
            final tnx = p.targetNx(state.cols);
            final tny = p.targetNy(state.rows);
            if ((p.nx - tnx).abs() <= 0.05 && (p.ny - tny).abs() <= 0.05) {
              return p.copyWith(nx: tnx, ny: tny);
            }
          }
          return p;
        }).toList();

        didSnap = true;
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

          currentPieces = _translateCluster(
            currentPieces,
            clusterId,
            alignDx,
            alignDy,
          );

          // 并查集合并：将当前集群所有成员并入目标集群 targetClusterId
          final targetClusterId = pB.clusterId;
          currentPieces = currentPieces.map((p) {
            if (p.clusterId == clusterId) {
              return p.copyWith(clusterId: targetClusterId);
            }
            return p;
          }).toList();

          didSnap = true;
          didMerge = true;
          affectedIds.addAll(currentPieces.where((p) => p.clusterId == targetClusterId).map((p) => p.id));
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

          if ((actualDx - expectedDx).abs() <= epsilon &&
              (actualDy - expectedDy).abs() <= epsilon) {
            final oldId = pB.clusterId;
            final newId = pA.clusterId;
            result = result.map((p) => p.clusterId == oldId ? p.copyWith(clusterId: newId) : p).toList();
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
      return HintResult(pieceId: state.pieces.first.id, targetNx: 0, targetNy: 0);
    }

    // 2. 策略优先级排序：角块 (Corner) > 边块 (Border) > 内部块 (Center)
    unplaced.sort((a, b) {
      final aEdges = EdgeLayout(rows: state.rows, cols: state.cols, seed: state.seed).edgesFor(a.r, a.c);
      final bEdges = EdgeLayout(rows: state.rows, cols: state.cols, seed: state.seed).edgesFor(b.r, b.c);
      if (aEdges.isCorner && !bEdges.isCorner) return -1;
      if (!aEdges.isCorner && bEdges.isCorner) return 1;
      if (aEdges.isBorder && !bEdges.isBorder) return -1;
      if (!aEdges.isBorder && bEdges.isBorder) return 1;
      return a.id.compareTo(b.id);
    });

    final targetPiece = unplaced.first;
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
