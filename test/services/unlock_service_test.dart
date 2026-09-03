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
    test('L1 to L3 are unlocked by default', () async {
      final unlock = UnlockService.instance;
      for (var i = 0; i <= 3; i++) {
        final status = await unlock.checkDifficultyUnlock(i);
        expect(status.isUnlocked, isTrue);
      }
    });

    test('L4 requires 2 distinct 3-star images', () async {
      final unlock = UnlockService.instance;
      final store = ProgressStore.instance;

      // 0 images -> locked
      var status = await unlock.checkDifficultyUnlock(4);
      expect(status.isUnlocked, isFalse);
      expect(status.targetRequired, equals(2));

      // 1 image with 3 stars -> still locked
      await store.recordDifficultyCompletion(
        canonicalId: 'main:001',
        difficultyKey: '5x5',
        stars: 3,
        timeSeconds: 50,
        hintsUsed: 0,
      );
      status = await unlock.checkDifficultyUnlock(4);
      expect(status.isUnlocked, isFalse);

      // 2 images with 3 stars -> unlocked!
      await store.recordDifficultyCompletion(
        canonicalId: 'main:002',
        difficultyKey: '5x5',
        stars: 3,
        timeSeconds: 50,
        hintsUsed: 0,
      );
      status = await unlock.checkDifficultyUnlock(4);
      expect(status.isUnlocked, isTrue);
    });

    test('L5 requires 5 distinct 3-star images and L6 requires 10', () async {
      final unlock = UnlockService.instance;
      final statusL5 = await unlock.checkDifficultyUnlock(5);
      expect(statusL5.isUnlocked, isFalse);
      expect(statusL5.targetRequired, equals(5));

      final statusL6 = await unlock.checkDifficultyUnlock(6);
      expect(statusL6.isUnlocked, isFalse);
      expect(statusL6.targetRequired, equals(10));
    });
  });
}
