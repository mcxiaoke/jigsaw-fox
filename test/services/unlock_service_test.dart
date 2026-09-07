import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/storage_manager.dart';
import 'package:jigsawpuzzle/services/unlock_service.dart';

import '../test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StorageManager sm;

  setUp(() async {
    sm = await initTestAppStorage();
    await ProgressStore.instance.init();
    await GameRepository.instance.init();
  });

  tearDown(() async {
    await tearDownTestStorage(sm);
  });

  group('UnlockService Unit Tests', () {
    test(
      'All difficulty tiers (0 to 7) are unlocked by default (sync and async)',
      () async {
        final unlock = UnlockService.instance;
        for (var i = 0; i <= 7; i++) {
          final syncStatus = unlock.checkDifficultyUnlockSync(i);
          expect(syncStatus.isUnlocked, isTrue);

          final asyncStatus = await unlock.checkDifficultyUnlock(i);
          expect(asyncStatus.isUnlocked, isTrue);
        }
      },
    );

    test('Daily challenge unlock requires main level completion', () async {
      final unlock = UnlockService.instance;
      final status = await unlock.checkDailyChallengeUnlock();
      expect(status.targetRequired, equals(1));
    });

    test('Event unlock requires 5 main level completions', () async {
      final unlock = UnlockService.instance;
      final status = await unlock.checkEventUnlock();
      expect(status.targetRequired, equals(5));
    });
  });
}
