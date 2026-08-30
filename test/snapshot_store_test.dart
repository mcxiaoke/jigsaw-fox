import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/migration_service.dart';
import 'package:jigsawpuzzle/data/models/level_item.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/resume_helper.dart';
import 'package:jigsawpuzzle/data/snapshot_store.dart';
import 'package:jigsawpuzzle/logic/models/puzzle_state.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SnapshotStore & ProgressStore & Migration Tests', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await SnapshotStore.instance.init();
      await ProgressStore.instance.init();
    });

    test('SnapshotStore atomic save, load, and single-difficulty retention', () async {
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

      // 再次保存 3x3，验证同关卡只留最新残局（2x2 应被清理）
      final state2 = PuzzleBoardState(
        canonicalId: cid,
        difficultyKey: '3x3',
        rows: 3,
        cols: 3,
        seed: 200,
        pieces: List.generate(
          9,
          (i) => PieceState(id: i, r: i ~/ 3, c: i % 3, nx: 0.0, ny: 0.0, clusterId: i),
        ),
      );
      await SnapshotStore.instance.save(state2);

      final keys = await SnapshotStore.instance.listDifficultyKeys(cid);
      expect(keys, contains('3x3'));
      expect(keys, isNot(contains('2x2')));

      final oldSnapshot = await SnapshotStore.instance.load(cid, '2x2');
      expect(oldSnapshot, isNull);

      final newSnapshot = await SnapshotStore.instance.load(cid, '3x3');
      expect(newSnapshot, isNotNull);
      expect(newSnapshot!.rows, 3);
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

    test('MigrationService migrates legacy savedSnapshotJson', () async {
      final prefs = await SharedPreferences.getInstance();
      const legacyState = PuzzleBoardState(
        rows: 2,
        cols: 2,
        seed: 1234,
        pieces: [
          PieceState(id: 0, r: 0, c: 0, nx: 0.0, ny: 0.0, clusterId: 0),
          PieceState(id: 1, r: 0, c: 1, nx: 0.5, ny: 0.0, clusterId: 1),
          PieceState(id: 2, r: 1, c: 0, nx: 0.0, ny: 0.5, clusterId: 2),
          PieceState(id: 3, r: 1, c: 1, nx: 0.5, ny: 0.5, clusterId: 3),
        ],
      );
      final jsonStr = jsonEncode(legacyState.toJson());

      final levels = [
        LevelItem(
          id: 'level_1',
          index: 1,
          title: '第 1 关',
          assetPath: 'assets/sample.webp',
          difficulty: const PuzzleDifficulty(label: '2x2', rows: 2, cols: 2),
          isUnlocked: true,
          isCompleted: false,
          progressPercent: 25,
          savedSnapshotJson: jsonStr,
        ),
      ];

      await MigrationService.instance.migrateIfNeeded(
        prefs: prefs,
        levels: levels,
        dailyChallenges: const [],
        customPuzzles: const [],
      );

      final cid = GameRepository.canonicalForLevel(1);
      final prog = await ProgressStore.instance.load(cid);
      expect(prog.hasSnapshot, isTrue);
      expect(prog.progressPercent, 25);
      expect(prog.activeDifficultyKey, '2x2');

      final snap = await SnapshotStore.instance.load(cid, '2x2');
      expect(snap, isNotNull);
      expect(snap!.pieces.length, 4);
    });

    test('ResumeHelper filters trivial initial entries and accepts free placement', () async {
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
      expect(info, isNull, reason: 'Trivial snapshot within 2s and no moves should be filtered');

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
      expect(info, isNotNull, reason: 'Free placement with elapsed >= 5s should be resumable');
      expect(info!.percent, 0);
    });
  });
}
