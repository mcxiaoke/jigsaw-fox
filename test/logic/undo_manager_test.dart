import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/engine/undo_manager.dart';
import 'package:jigsawpuzzle/logic/models/puzzle_state.dart';

void main() {
  group('UndoManager Tests', () {
    test('Basic Undo and Redo flow', () {
      final manager = UndoManager(maxHistory: 5);

      final state1 = const PuzzleBoardState(
        rows: 2,
        cols: 2,
        seed: 1,
        pieces: [PieceState(id: 0, r: 0, c: 0, nx: 0.1, ny: 0.1, clusterId: 0)],
      );

      final state2 = const PuzzleBoardState(
        rows: 2,
        cols: 2,
        seed: 1,
        pieces: [PieceState(id: 0, r: 0, c: 0, nx: 0.2, ny: 0.2, clusterId: 0)],
      );

      final state3 = const PuzzleBoardState(
        rows: 2,
        cols: 2,
        seed: 1,
        pieces: [PieceState(id: 0, r: 0, c: 0, nx: 0.3, ny: 0.3, clusterId: 0)],
      );

      manager.record(state1);
      manager.record(state2);

      expect(manager.canUndo, isTrue);
      expect(manager.canRedo, isFalse);

      // Undo state3 -> returns state2, redo stack gets state3
      final undone = manager.undo(state3);
      expect(undone, equals(state2));
      expect(manager.canRedo, isTrue);

      // Redo state2 -> returns state3
      final redone = manager.redo(undone!);
      expect(redone, equals(state3));
    });

    test('Max history limitation is respected', () {
      final manager = UndoManager(maxHistory: 3);

      for (var i = 0; i < 10; i++) {
        manager.record(
          PuzzleBoardState(
            rows: 2,
            cols: 2,
            seed: 1,
            pieces: [
              PieceState(id: 0, r: 0, c: 0, nx: i * 0.1, ny: 0, clusterId: 0),
            ],
          ),
        );
      }

      expect(manager.undoCount, equals(3));
    });
  });
}
