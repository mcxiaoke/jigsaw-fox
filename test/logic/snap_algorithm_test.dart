import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/engine/puzzle_engine.dart';
import 'package:jigsawpuzzle/logic/models/puzzle_state.dart';

void main() {
  group('Snap & Cluster Merging Tests', () {
    test('Snap to board target slot when near correct position', () {
      final initialPieces = [
        const PieceState(id: 0, r: 0, c: 0, nx: 0.02, ny: 0.02, clusterId: 0),
        const PieceState(id: 1, r: 0, c: 1, nx: 0.8, ny: 0.8, clusterId: 1),
      ];

      final boardState = PuzzleBoardState(
        rows: 1,
        cols: 2,
        seed: 1,
        pieces: initialPieces,
      );

      final result = PuzzleEngine.resolveSnap(
        state: boardState,
        draggedPieceId: 0,
        customSnapDistance: 0.1,
      );

      expect(result.didSnap, isTrue);
      final snappedPiece = result.state.pieceById(0);
      expect(snappedPiece.nx, 0.0);
      expect(snappedPiece.ny, 0.0);
    });

    test('Snap and merge two adjacent neighbor pieces', () {
      // Piece 0 at (0, 0) and Piece 1 at (0, 1) in 2x2 board
      // Expected relative dx is 0.5 (1 / 2 cols)
      // Place Piece 0 at (0.3, 0.3), Piece 1 at (0.82, 0.31) -> error ~ 0.022
      final pieces = [
        const PieceState(id: 0, r: 0, c: 0, nx: 0.30, ny: 0.30, clusterId: 0),
        const PieceState(id: 1, r: 0, c: 1, nx: 0.82, ny: 0.31, clusterId: 1),
      ];

      final boardState = PuzzleBoardState(
        rows: 1,
        cols: 2,
        seed: 1,
        pieces: pieces,
      );

      final result = PuzzleEngine.resolveSnap(
        state: boardState,
        draggedPieceId: 0,
        customSnapDistance: 0.08,
      );

      expect(result.didSnap, isTrue);
      expect(result.didMerge, isTrue);

      final p0 = result.state.pieceById(0);
      final p1 = result.state.pieceById(1);

      // Now both pieces share the same clusterId
      expect(p0.clusterId, equals(p1.clusterId));
      // Relative offset is exact: p1.nx - p0.nx == 0.5
      expect((p1.nx - p0.nx - 0.5).abs() < 0.001, isTrue);
      expect((p1.ny - p0.ny).abs() < 0.001, isTrue);
    });

    test('Solved detection when all pieces are correctly aligned', () {
      final solvedPieces = [
        const PieceState(id: 0, r: 0, c: 0, nx: 0.0, ny: 0.0, clusterId: 0),
        const PieceState(id: 1, r: 0, c: 1, nx: 0.5, ny: 0.0, clusterId: 0),
        const PieceState(id: 2, r: 1, c: 0, nx: 0.0, ny: 0.5, clusterId: 0),
        const PieceState(id: 3, r: 1, c: 1, nx: 0.5, ny: 0.5, clusterId: 0),
      ];

      final boardState = PuzzleBoardState(
        rows: 2,
        cols: 2,
        seed: 1,
        pieces: solvedPieces,
      );

      expect(boardState.isSolved, isTrue);
    });
  });
}
