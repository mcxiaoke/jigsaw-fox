import 'dart:math';

import '../geometry/edge_layout.dart';
import '../models/puzzle_state.dart';

/// Pure domain puzzle engine handling snapping, cluster merging, hints, and solved state checks.
class PuzzleEngine {
  /// Default snap threshold as a ratio of single piece size.
  static const double defaultSnapRatio = 0.48;

  /// Creates a new puzzle board state with scattered pieces.
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

        // Scatter pieces across a normalized margin [-0.25, 1.25]
        double sx, sy;
        for (var attempt = 0; attempt < 100; attempt++) {
          sx = -0.2 + rng.nextDouble() * 1.4;
          sy = -0.2 + rng.nextDouble() * 1.4;
          // Avoid immediately landing in correct spot
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

  /// Calculates the default snap distance in normalized coordinates.
  static double calculateSnapThreshold(int rows, int cols, [double ratio = defaultSnapRatio]) {
    final pieceW = 1.0 / cols;
    final pieceH = 1.0 / rows;
    return min(pieceW, pieceH) * ratio;
  }

  /// Resolves snapping and cluster merging after a cluster of pieces finishes moving.
  static BoardTransitionResult resolveSnap({
    required PuzzleBoardState state,
    required int draggedPieceId,
    double? customSnapDistance,
  }) {
    final snapDist = customSnapDistance ??
        calculateSnapThreshold(state.rows, state.cols);

    final draggedPiece = state.pieceById(draggedPieceId);
    final clusterId = draggedPiece.clusterId;
    final clusterPieces = state.piecesInCluster(clusterId);

    var currentPieces = List<PieceState>.from(state.pieces);
    var didSnap = false;
    var didMerge = false;
    final affectedIds = <int>{...clusterPieces.map((p) => p.id)};

    // 1. Check Snap to Board Target Slots
    for (final piece in clusterPieces) {
      if (state.rotationEnabled && piece.rot % 4 != 0) {
        continue;
      }
      final targetNx = piece.targetNx(state.cols);
      final targetNy = piece.targetNy(state.rows);
      final dist = Point(piece.nx, piece.ny).distanceTo(Point(targetNx, targetNy));

      if (dist <= snapDist) {
        // Compute displacement to snap entire cluster to board
        final dx = targetNx - piece.nx;
        final dy = targetNy - piece.ny;

        currentPieces = _translateCluster(
          currentPieces,
          clusterId,
          dx,
          dy,
        );

        // Lock in exact normalized coordinates for pieces in this aligned cluster
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

    // 2. Check Snap to Neighbors (both on-board and free-floating)
    final activeClusterPieces = currentPieces.where((p) => p.clusterId == clusterId).toList();

    for (final pA in activeClusterPieces) {
      for (final pB in currentPieces) {
        if (pB.clusterId == clusterId) continue; // Same cluster, skip

        final dr = pB.r - pA.r;
        final dc = pB.c - pA.c;
        final isOrthogonalNeighbor = (dr.abs() + dc.abs()) == 1;
        if (!isOrthogonalNeighbor) continue;

        if (state.rotationEnabled && (pA.rot % 4 != pB.rot % 4)) {
          continue;
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

    // 3. Also check if multiple neighbor clusters now touch and should be merged
    currentPieces = _mergeAllAdjacentClusters(currentPieces, state.rows, state.cols, state.rotationEnabled);

    final newState = state.copyWith(pieces: currentPieces);
    return BoardTransitionResult(
      state: newState,
      didSnap: didSnap,
      didMerge: didMerge,
      affectedPieceIds: affectedIds.toList(),
      isCompleted: newState.isSolved,
    );
  }

  /// Translates all pieces in a cluster by (dx, dy).
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

  /// Checks and merges any adjacent aligned pieces into unified clusters.
  static List<PieceState> _mergeAllAdjacentClusters(
    List<PieceState> pieces,
    int rows,
    int cols,
    bool rotationEnabled, {
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

  /// Rotates a single piece or its entire cluster clockwise by 90°.
  static PuzzleBoardState rotateCluster({
    required PuzzleBoardState state,
    required int pieceId,
  }) {
    final targetPiece = state.pieceById(pieceId);
    final clusterId = targetPiece.clusterId;
    final clusterPieces = state.piecesInCluster(clusterId);

    // Compute center of cluster for rotation
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

      // 90° clockwise rotation: (x, y) -> (-y, x)
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

  /// Provides an intelligent hint by identifying the most strategic unplaced piece.
  static HintResult hintFor(PuzzleBoardState state) {
    // 1. Find all pieces not currently at their target slot
    final unplaced = state.pieces.where((p) => !p.isSolved(state.rows, state.cols)).toList();
    if (unplaced.isEmpty) {
      return HintResult(pieceId: state.pieces.first.id, targetNx: 0, targetNy: 0);
    }

    // 2. Prefer border / corner pieces, or pieces adjacent to already placed clusters
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

/// Result returned after resolving a piece placement transition.
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

/// Target coordinate result for a hint operation.
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
