import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/models/puzzle_state.dart';

void main() {
  group('Snapshot v2 Tests', () {
    test('JSON serialization round-trip', () {
      const original = PuzzleBoardState(
        rows: 3,
        cols: 4,
        seed: 8888,
        rotationEnabled: true,
        elapsedSeconds: 120,
        hintsUsed: 2,
        levelId: 'level_05',
        pieces: [
          PieceState(
            id: 0,
            r: 0,
            c: 0,
            nx: 0.1234,
            ny: 0.5678,
            clusterId: 3,
            rot: 2,
          ),
          PieceState(
            id: 1,
            r: 0,
            c: 1,
            nx: 0.25,
            ny: 0.0,
            clusterId: 3,
            rot: 2,
          ),
        ],
      );

      final json = original.toJson();
      expect(json['version'], 2);
      expect(json['levelId'], 'level_05');
      expect(json['seed'], 8888);
      expect(json['rotationEnabled'], isTrue);

      final restored = PuzzleBoardState.fromJson(json);
      expect(restored.rows, 3);
      expect(restored.cols, 4);
      expect(restored.seed, 8888);
      expect(restored.rotationEnabled, isTrue);
      expect(restored.elapsedSeconds, 120);
      expect(restored.hintsUsed, 2);
      expect(restored.pieces.length, 2);

      final p0 = restored.pieceById(0);
      expect(p0.id, 0);
      expect(p0.r, 0);
      expect(p0.c, 0);
      expect(p0.nx, 0.1234);
      expect(p0.ny, 0.5678);
      expect(p0.clusterId, 3);
      expect(p0.rot, 2);
    });
  });
}
