import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ProgressStore.instance.init();
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
  });
}
