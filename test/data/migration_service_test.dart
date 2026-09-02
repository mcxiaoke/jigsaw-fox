import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/migration_service.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/snapshot_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SnapshotStore.instance.init();
    await ProgressStore.instance.init();
  });

  group('MigrationService v3.3.1 Tests', () {
    test(
      '16-piece (4x4) merges into 25-piece (5x5) taking best values and deletes 4x4',
      () async {
        final prefs = await SharedPreferences.getInstance();
        const cid = 'main:005';

        // Setup initial progress with 4x4 (3 stars, 40s) and 5x5 (2 stars, 60s)
        final initial = LevelProgress(
          canonicalId: cid,
          records: const {
            '4x4': DifficultyRecord(
              bestStars: 3,
              bestTimeSeconds: 40,
              isCompleted: true,
              playCount: 2,
              minHintsUsed: 0,
            ),
            '5x5': DifficultyRecord(
              bestStars: 2,
              bestTimeSeconds: 60,
              isCompleted: true,
              playCount: 1,
              minHintsUsed: 1,
            ),
          },
        );
        await ProgressStore.instance.save(initial);

        // Perform migration
        await MigrationService.instance.migrateIfNeeded(
          prefs: prefs,
          levels: const [],
          dailyChallenges: const [],
          customPuzzles: const [],
        );

        final migrated = await ProgressStore.instance.load(cid);
        expect(migrated.records.containsKey('4x4'), isFalse);
        expect(migrated.records.containsKey('5x5'), isTrue);

        final r25 = migrated.records['5x5']!;
        expect(r25.bestStars, equals(3)); // max(3, 2)
        expect(r25.bestTimeSeconds, equals(40)); // min(40, 60)
        expect(r25.minHintsUsed, equals(0)); // min(0, 1)
        expect(r25.playCount, equals(3)); // 2 + 1
        expect(r25.isCompleted, isTrue);
      },
    );

    test(
      'Ghost difficulty cleanup keeps completed stars and deletes uncompleted snapshots',
      () async {
        final prefs = await SharedPreferences.getInstance();
        const cid = 'main:008';

        // Setup progress with completed 6x8 (legacy 3:4) and uncompleted 9x12
        final initial = LevelProgress(
          canonicalId: cid,
          records: const {
            '6x8': DifficultyRecord(
              bestStars: 3,
              bestTimeSeconds: 120,
              isCompleted: true,
              playCount: 1,
            ),
            '9x12': DifficultyRecord(
              bestStars: 0,
              bestTimeSeconds: 0,
              isCompleted: false,
              playCount: 1,
            ),
          },
        );
        await ProgressStore.instance.save(initial);

        // Perform migration
        await MigrationService.instance.migrateIfNeeded(
          prefs: prefs,
          levels: const [],
          dailyChallenges: const [],
          customPuzzles: const [],
        );

        final migrated = await ProgressStore.instance.load(cid);
        // Completed 6x8 retains its stars in records
        expect(migrated.records.containsKey('6x8'), isTrue);
        expect(migrated.records['6x8']!.bestStars, equals(3));

        // Uncompleted 9x12 record is cleaned up
        expect(migrated.records.containsKey('9x12'), isFalse);
      },
    );
  });
}
