import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/logic/models/puzzle_state.dart';

void main() {
  group('Snapshot v3 Tests', () {
    test('v3 JSON serialization round-trip with forward compat', () {
      const original = PuzzleBoardState(
        rows: 3,
        cols: 4,
        seed: 8888,
        rotationEnabled: true,
        elapsedSeconds: 120,
        hintsUsed: 2,
        levelId: 'level_05',
        canonicalId: 'main:005',
        difficultyKey: '4x3',
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
      expect(json['version'], PuzzleBoardState.currentVersion);
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
      expect(restored.canonicalId, 'main:005');
      expect(restored.difficultyKey, '4x3');
    });

    test('v2 snapshot still readable (backward compat)', () {
      final v2Json = {
        'version': 2,
        'levelId': 'level_07',
        'seed': 1234,
        'rows': 2,
        'cols': 2,
        'rotationEnabled': false,
        'elapsedSeconds': 10,
        'hintsUsed': 0,
        'pieces': [
          {'id': 0, 'r': 0, 'c': 0, 'nx': 0.0, 'ny': 0.0, 'g': 0, 'rot': 0},
          {'id': 1, 'r': 0, 'c': 1, 'nx': 0.5, 'ny': 0.0, 'g': 1, 'rot': 0},
          {'id': 2, 'r': 1, 'c': 0, 'nx': 0.0, 'ny': 0.5, 'g': 2, 'rot': 0},
          {'id': 3, 'r': 1, 'c': 1, 'nx': 0.5, 'ny': 0.5, 'g': 3, 'rot': 0},
        ],
      };
      final s = PuzzleBoardState.fromJson(v2Json);
      expect(s.rows, 2);
      expect(s.cols, 2);
      expect(s.canonicalId, 'level_07');
      expect(s.difficultyKey, '2x2');
      // v2 读取后保留原 version，直接 toJson 仍为 2；经 SnapshotStore.save 会升级到 currentVersion
      final json3 = s.toJson();
      expect(json3['version'], 2);
      expect(json3['canonicalId'], 'level_07');
      // 手动升级后
      final upgraded = s.copyWith(version: PuzzleBoardState.currentVersion).toJson();
      expect(upgraded['version'], PuzzleBoardState.currentVersion);
    });

    test('extra fields preserved for forward compat', () {
      final jsonWithFuture = {
        'version': 99,
        'levelId': 'level_99',
        'canonicalId': 'main:099',
        'difficultyKey': '10x10',
        'seed': 9999,
        'rows': 2,
        'cols': 2,
        'rotationEnabled': false,
        'elapsedSeconds': 5,
        'hintsUsed': 0,
        'futureField': 'futureValue',
        'futureObj': {'a': 1},
        'pieces': [
          {'id': 0, 'r': 0, 'c': 0, 'nx': 0.0, 'ny': 0.0, 'g': 0, 'rot': 0, 'futurePieceField': 123},
        ],
      };
      final s = PuzzleBoardState.fromJson(jsonWithFuture);
      expect(s.extra['futureField'], 'futureValue');
      expect(s.extra['futureObj'], {'a': 1});
      expect(s.pieces.first.extra['futurePieceField'], 123);
      // 透传回写
      final out = s.toJson();
      expect(out['futureField'], 'futureValue');
      expect(out['pieces'][0]['futurePieceField'], 123);
      // 再次解析不丢
      final s2 = PuzzleBoardState.fromJson(out);
      expect(s2.extra['futureField'], 'futureValue');
    });
  });
}
