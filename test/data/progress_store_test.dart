import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';

import '../test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageManager sm;

  setUp(() async {
    // 每个测试独立 Hive 目录 + 内存索引清零（等价全新 init）
    sm = await initTestStorage();
    await ProgressStore.instance.reset();
  });

  tearDown(() async {
    await tearDownTestStorage(sm);
  });

  group('ProgressStore & DifficultyRecord Unit Tests', () {
    test('DifficultyRecord serialization and default values', () {
      const rec = DifficultyRecord(
        bestStars: 3,
        bestTimeSeconds: 45,
        isCompleted: true,
        playCount: 2,
        minHintsUsed: 0,
      );

      final json = rec.toJson();
      expect(json['bestStars'], equals(3));
      expect(json['bestTimeSeconds'], equals(45));
      expect(json['minHintsUsed'], equals(0));

      final fromJson = DifficultyRecord.fromJson(json);
      expect(fromJson.bestStars, equals(3));
      expect(fromJson.bestTimeSeconds, equals(45));
      expect(fromJson.isCompleted, isTrue);
      expect(fromJson.minHintsUsed, equals(0));
    });

    test(
      'recordDifficultyCompletion updates records and minHintsUsed state machine',
      () async {
        const cid = 'main:001';
        final store = ProgressStore.instance;

        // 1. First play with 2 hints, 2 stars, 60s
        final res1 = await store.recordDifficultyCompletion(
          canonicalId: cid,
          difficultyKey: '5x5',
          stars: 2,
          timeSeconds: 60,
          hintsUsed: 2,
          completedPieceCount: 25,
        );

        expect(res1.stars, equals(2));
        expect(res1.isNewBestStars, isTrue);
        expect(res1.deltaStars, equals(2));
        expect(res1.isFirstNoHintWin, isFalse);
        expect(res1.record.minHintsUsed, equals(2));
        expect(res1.record.playCount, equals(1));

        // 2. Second play with 0 hints, 3 stars, 40s -> triggers first noHintWin!
        final res2 = await store.recordDifficultyCompletion(
          canonicalId: cid,
          difficultyKey: '5x5',
          stars: 3,
          timeSeconds: 40,
          hintsUsed: 0,
        );

        expect(res2.stars, equals(3));
        expect(res2.isNewBestStars, isTrue);
        expect(res2.deltaStars, equals(1)); // 3 - 2 = 1
        expect(res2.isFirstNoHintWin, isTrue);
        expect(res2.record.minHintsUsed, equals(0));
        expect(res2.record.playCount, equals(2));
        expect(res2.record.bestTimeSeconds, equals(40));

        // 3. Third play with 0 hints again -> does not trigger first noHintWin again
        final res3 = await store.recordDifficultyCompletion(
          canonicalId: cid,
          difficultyKey: '5x5',
          stars: 3,
          timeSeconds: 38,
          hintsUsed: 0,
        );
        expect(res3.isNewBestStars, isFalse);
        expect(res3.deltaStars, equals(0));
        expect(res3.isFirstNoHintWin, isFalse);
        expect(res3.record.playCount, equals(3));
        expect(res3.record.bestTimeSeconds, equals(38));
      },
    );

    test('Aggregate metrics: distinctImagesWith3Star and totalStars', () async {
      final store = ProgressStore.instance;

      // Image 1: 3 stars in 5x5, 2 stars in 6x6
      await store.recordDifficultyCompletion(
        canonicalId: 'main:001',
        difficultyKey: '5x5',
        stars: 3,
        timeSeconds: 50,
        hintsUsed: 0,
      );
      await store.recordDifficultyCompletion(
        canonicalId: 'main:001',
        difficultyKey: '6x6',
        stars: 2,
        timeSeconds: 80,
        hintsUsed: 1,
      );

      // Image 2: 2 stars in 5x5
      await store.recordDifficultyCompletion(
        canonicalId: 'main:002',
        difficultyKey: '5x5',
        stars: 2,
        timeSeconds: 60,
        hintsUsed: 1,
      );

      // Image 3: 3 stars in 8x8
      await store.recordDifficultyCompletion(
        canonicalId: 'daily:20260830',
        difficultyKey: '8x8',
        stars: 3,
        timeSeconds: 200,
        hintsUsed: 0,
      );

      // distinctImagesWith3Star = 2 (main:001 and daily:20260830)
      expect(await store.getDistinctImagesWith3Star(), equals(2));

      // totalStars = (3+2) + 2 + 3 = 10
      expect(await store.getTotalStars(), equals(10));

      // totalSolved = 3 images
      expect(await store.getTotalSolved(), equals(3));
    });

    test('Timestamp fields and batch loadAllProgress', () async {
      final store = ProgressStore.instance;
      const cid = 'main:999';

      await store.recordDifficultyCompletion(
        canonicalId: cid,
        difficultyKey: '4x4',
        stars: 3,
        timeSeconds: 30,
        hintsUsed: 0,
      );

      final p = await store.load(cid);
      expect(p.firstPlayedAt, isNotNull);
      expect(p.lastCompletedAt, isNotNull);
      expect(p.firstCompletedAt, isNotNull);
      expect(p.lastPlayedAt, isNotNull);
      expect(p.completedDifficultyCount, equals(1));
      expect(p.bestDifficultyKey, equals('4x4'));
      expect(p.allDifficultyStars['4x4'], equals(3));
      expect(p.totalPlayCount, equals(1));

      final rec = p.records['4x4']!;
      expect(rec.isPerfect, isTrue);
      expect(rec.firstCompletedAt, isNotNull);
      expect(rec.lastCompletedAt, isNotNull);

      // 验证 loadAllProgress 批量加载
      final all = await store.loadAllProgress();
      expect(all.containsKey(cid), isTrue);
      expect(all[cid]!.maxStars, equals(3));
      expect(await store.getTotalPlayCount(), greaterThanOrEqualTo(1));
    });

    test('minMoves records minimum moves and delete clears record', () async {
      final store = ProgressStore.instance;
      const cid = 'main:min_moves_test';

      // 1. First win with 80 moves
      await store.recordDifficultyCompletion(
        canonicalId: cid,
        difficultyKey: '5x5',
        stars: 3,
        timeSeconds: 40,
        hintsUsed: 0,
        moves: 80,
      );
      var p = await store.load(cid);
      expect(p.records['5x5']!.minMoves, equals(80));

      // 2. Second win with 65 moves -> updates minMoves
      await store.recordDifficultyCompletion(
        canonicalId: cid,
        difficultyKey: '5x5',
        stars: 3,
        timeSeconds: 35,
        hintsUsed: 0,
        moves: 65,
      );
      p = await store.load(cid);
      expect(p.records['5x5']!.minMoves, equals(65));

      // 3. Third win with 90 moves -> retains 65
      await store.recordDifficultyCompletion(
        canonicalId: cid,
        difficultyKey: '5x5',
        stars: 3,
        timeSeconds: 50,
        hintsUsed: 0,
        moves: 90,
      );
      p = await store.load(cid);
      expect(p.records['5x5']!.minMoves, equals(65));

      // 4. Test delete
      await store.delete(cid);
      final allAfter = await store.loadAllProgress();
      expect(allAfter.containsKey(cid), isFalse);
    });
  });
}
