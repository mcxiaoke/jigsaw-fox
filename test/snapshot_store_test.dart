import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/resume_helper.dart';
import 'package:jigsawpuzzle/data/snapshot_store.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/logic/models/puzzle_state.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';

import 'test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageManager sm;

  group('SnapshotStore & ProgressStore Tests', () {
    setUp(() async {
      sm = await initTestStorage();
      await SnapshotStore.instance.init();
      // 每个测试独立 box：清空内存索引（box 本身为空，等价全新 init）
      await ProgressStore.instance.reset();
    });

    tearDown(() async {
      await tearDownTestStorage(sm);
    });

    test('SnapshotStore atomic save, load, and explicit delete', () async {
      const cid = 'main:001';
      final state1 = PuzzleBoardState(
        canonicalId: cid,
        difficultyKey: '2x2',
        rows: 2,
        cols: 2,
        seed: 100,
        pieces: const [
          PieceState(id: 0, r: 0, c: 0, nx: 0.0, ny: 0.0, clusterId: 0),
          PieceState(id: 1, r: 0, c: 1, nx: 0.5, ny: 0.0, clusterId: 1),
          PieceState(id: 2, r: 1, c: 0, nx: 0.0, ny: 0.5, clusterId: 2),
          PieceState(id: 3, r: 1, c: 1, nx: 0.5, ny: 0.5, clusterId: 3),
        ],
      );

      // 保存 2x2
      await SnapshotStore.instance.save(state1);
      final loaded1 = await SnapshotStore.instance.load(cid, '2x2');
      expect(loaded1, isNotNull);
      expect(loaded1!.rows, 2);
      expect(loaded1.cols, 2);

      // 方案 A：save 专注做单文件高效原子落盘（移出热路径自动强删）
      final state2 = PuzzleBoardState(
        canonicalId: cid,
        difficultyKey: '3x3',
        rows: 3,
        cols: 3,
        seed: 200,
        pieces: List.generate(
          9,
          (i) => PieceState(
            id: i,
            r: i ~/ 3,
            c: i % 3,
            nx: 0.0,
            ny: 0.0,
            clusterId: i,
          ),
        ),
      );
      await SnapshotStore.instance.save(state2);

      final loaded2 = await SnapshotStore.instance.load(cid, '3x3');
      expect(loaded2, isNotNull);
      expect(loaded2!.rows, 3);

      // 显式清理旧难度快照
      await SnapshotStore.instance.delete(cid, '2x2');
      final keys = await SnapshotStore.instance.listDifficultyKeys(cid);
      expect(keys, contains('3x3'));
      expect(keys, isNot(contains('2x2')));

      final oldSnapshot = await SnapshotStore.instance.load(cid, '2x2');
      expect(oldSnapshot, isNull);
    });

    test('ProgressStore reconcile self-heals when file missing', () async {
      const cid = 'main:002';
      await ProgressStore.instance.updateProgress(
        canonicalId: cid,
        progressPercent: 50,
        hasSnapshot: true,
        activeDifficultyKey: '4x4',
        snapshotKeys: ['4x4'],
      );

      var p = await ProgressStore.instance.load(cid);
      expect(p.hasSnapshot, isTrue);

      // 无对应快照文件，执行对账
      await ProgressStore.instance.reconcile(cid);
      p = await ProgressStore.instance.load(cid);
      expect(p.hasSnapshot, isFalse);
      expect(p.activeDifficultyKey, isEmpty);
    });

    test(
      'ResumeHelper filters trivial initial entries and accepts free placement',
      () async {
        const cid = 'main:003';
        const fallbackDiff = PuzzleDifficulty(label: '2x2', rows: 2, cols: 2);

        // 1. Trivial: 0%, 0 hints, 0s elapsed, all pieces unmerged
        final trivialState = PuzzleBoardState(
          canonicalId: cid,
          difficultyKey: '2x2',
          rows: 2,
          cols: 2,
          seed: 111,
          elapsedSeconds: 2,
          hintsUsed: 0,
          pieces: const [
            PieceState(id: 0, r: 0, c: 0, nx: 0.0, ny: 0.0, clusterId: 0),
            PieceState(id: 1, r: 0, c: 1, nx: 0.5, ny: 0.0, clusterId: 1),
            PieceState(id: 2, r: 1, c: 0, nx: 0.0, ny: 0.5, clusterId: 2),
            PieceState(id: 3, r: 1, c: 1, nx: 0.5, ny: 0.5, clusterId: 3),
          ],
        );
        await SnapshotStore.instance.save(trivialState);
        await ProgressStore.instance.updateProgress(
          canonicalId: cid,
          progressPercent: 0,
          hasSnapshot: true,
          activeDifficultyKey: '2x2',
          snapshotKeys: ['2x2'],
        );

        var info = await ResumeHelper.fetchResume(cid, fallbackDiff);
        expect(
          info,
          isNull,
          reason: 'Trivial snapshot within 2s and no moves should be filtered',
        );

        // 2. Free placement: 0% solved, but elapsedSeconds >= 5 or has merged clusters
        final freePlacementState = PuzzleBoardState(
          canonicalId: cid,
          difficultyKey: '2x2',
          rows: 2,
          cols: 2,
          seed: 111,
          elapsedSeconds: 15,
          hintsUsed: 0,
          pieces: const [
            PieceState(id: 0, r: 0, c: 0, nx: 0.1, ny: 0.1, clusterId: 0),
            PieceState(id: 1, r: 0, c: 1, nx: 0.6, ny: 0.1, clusterId: 1),
            PieceState(id: 2, r: 1, c: 0, nx: 0.1, ny: 0.6, clusterId: 2),
            PieceState(id: 3, r: 1, c: 1, nx: 0.6, ny: 0.6, clusterId: 3),
          ],
        );
        await SnapshotStore.instance.save(freePlacementState);
        await ProgressStore.instance.updateProgress(
          canonicalId: cid,
          progressPercent: 0,
          hasSnapshot: true,
          activeDifficultyKey: '2x2',
          snapshotKeys: ['2x2'],
        );

        info = await ResumeHelper.fetchResume(cid, fallbackDiff);
        expect(
          info,
          isNotNull,
          reason: 'Free placement with elapsed >= 5s should be resumable',
        );
        expect(info!.percent, 0);
      },
    );

    test(
      'Free floating pieces on board maintain accurate normalized coords on resume',
      () async {
        const cid = 'main:005';
        final freeFloatingState = PuzzleBoardState(
          canonicalId: cid,
          difficultyKey: '3x3',
          rows: 3,
          cols: 3,
          seed: 42,
          elapsedSeconds: 20,
          pieces: [
            // Piece 0 at center (free floating on board, not snapped)
            const PieceState(
              id: 0,
              r: 0,
              c: 0,
              nx: 0.42,
              ny: 0.48,
              clusterId: 0,
            ),
            // Piece 1 in tray (ny > 1.10)
            const PieceState(
              id: 1,
              r: 0,
              c: 1,
              nx: 0.10,
              ny: 1.45,
              clusterId: 1,
            ),
            // Remaining pieces
            ...List.generate(
              7,
              (i) => PieceState(
                id: i + 2,
                r: (i + 2) ~/ 3,
                c: (i + 2) % 3,
                nx: 0.2,
                ny: 1.5,
                clusterId: i + 2,
              ),
            ),
          ],
        );

        await SnapshotStore.instance.save(freeFloatingState);
        final loaded = await SnapshotStore.instance.load(cid, '3x3');
        expect(loaded, isNotNull);
        final p0 = loaded!.pieceById(0);
        expect(p0.nx, closeTo(0.42, 0.0001));
        expect(p0.ny, closeTo(0.48, 0.0001));
        expect(
          p0.nx >= -0.05 && p0.nx <= 1.05 && p0.ny >= -0.05 && p0.ny <= 1.05,
          isTrue,
          reason: 'Floating piece on board is within valid board domain',
        );

        final p1 = loaded.pieceById(1);
        expect(
          p1.ny > 1.10,
          isTrue,
          reason: 'Piece 1 is properly recognized as in tray',
        );
      },
    );
  });
}
