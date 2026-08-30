import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/services/achievement_service.dart';
import 'package:jigsawpuzzle/services/achievement_store.dart';
import 'package:jigsawpuzzle/services/economy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AchievementStore.instance.init();
    await EconomyService.instance.init();
  });

  group('AchievementService Unit Tests', () {
    test('onPuzzleSolved triggers first_win, star_1, and no_hint_win', () async {
      final ach = AchievementService.instance;
      final store = AchievementStore.instance;

      final unlocked = await ach.onPuzzleSolved(
        actualPieces: 25,
        elapsedSeconds: 45,
        hintsUsed: 0,
        stars: 3,
        puzzleType: 'main',
        tierIndex: 0,
        canonicalId: 'main:001',
        isFirstNoHintWin: true,
      );

      final ids = unlocked.map((a) => a.id).toSet();
      expect(ids.contains('first_win'), isTrue);
      expect(ids.contains('star_1'), isTrue);
      expect(ids.contains('no_hint_win'), isTrue);

      expect(store.isUnlocked('first_win'), isTrue);
      expect(store.isUnlocked('star_1'), isTrue);
      expect(store.isUnlocked('no_hint_win'), isTrue);
    });

    test('speed_10min triggers only when pieces >= 100 and seconds <= 600', () async {
      final ach = AchievementService.instance;
      final store = AchievementStore.instance;

      // 64 pieces in 300s -> speed_10min not triggered
      await ach.onPuzzleSolved(
        actualPieces: 64,
        elapsedSeconds: 300,
        hintsUsed: 1,
        stars: 2,
        puzzleType: 'main',
        tierIndex: 2,
        canonicalId: 'main:002',
      );
      expect(store.isUnlocked('speed_10min'), isFalse);

      // 100 pieces in 400s -> speed_10min triggered!
      final unlocked = await ach.onPuzzleSolved(
        actualPieces: 100,
        elapsedSeconds: 400,
        hintsUsed: 1,
        stars: 2,
        puzzleType: 'main',
        tierIndex: 3,
        canonicalId: 'main:003',
      );
      expect(unlocked.any((a) => a.id == 'speed_10min'), isTrue);
      expect(store.isUnlocked('speed_10min'), isTrue);
    });

    test('Claiming reward grants coins and prevents duplicate claims', () async {
      final ach = AchievementService.instance;
      final store = AchievementStore.instance;
      final eco = EconomyService.instance;

      // Unlock first_win (20 coins reward)
      await ach.onPuzzleSolved(
        actualPieces: 25,
        elapsedSeconds: 50,
        hintsUsed: 1,
        stars: 2,
        puzzleType: 'main',
        tierIndex: 0,
        canonicalId: 'main:004',
      );
      expect(store.isUnlocked('first_win'), isTrue);
      final coinsBefore = eco.coins; // 含新手赠送 100 币

      // Claim reward -> +20 coins
      final claimOk = await ach.claimReward('first_win');
      expect(claimOk, isTrue);
      expect(eco.coins - coinsBefore, equals(20));
      expect(store.isClaimed('first_win'), isTrue);

      // Duplicate claim -> returns false and does not grant coins again
      final claimAgain = await ach.claimReward('first_win');
      expect(claimAgain, isFalse);
      expect(eco.coins - coinsBefore, equals(20));
    });

    test('three_star_count deduplicates by canonicalId (design §8.3)', () async {
      final ach = AchievementService.instance;
      final store = AchievementStore.instance;

      // 同一张图在两个档位拿 3 星 -> 只计 1 次（防单图灌水）
      await ach.onPuzzleSolved(
        actualPieces: 25,
        elapsedSeconds: 40,
        hintsUsed: 0,
        stars: 3,
        puzzleType: 'main',
        tierIndex: 0,
        canonicalId: 'main:010',
      );
      expect(store.getCounter('three_star_count'), 1);

      await ach.onPuzzleSolved(
        actualPieces: 64,
        elapsedSeconds: 100,
        hintsUsed: 0,
        stars: 3,
        puzzleType: 'main',
        tierIndex: 2,
        canonicalId: 'main:010',
      );
      expect(store.getCounter('three_star_count'), 1);
      expect(store.starredPuzzleCount, 1);

      // 不同图拿 3 星 -> +1
      await ach.onPuzzleSolved(
        actualPieces: 100,
        elapsedSeconds: 200,
        hintsUsed: 0,
        stars: 3,
        puzzleType: 'main',
        tierIndex: 3,
        canonicalId: 'main:011',
      );
      expect(store.getCounter('three_star_count'), 2);
      expect(store.starredPuzzleCount, 2);
    });

    test('playSeconds accumulates via lifecycle increments incl. abandoned games (§8.1)', () async {
      final ach = AchievementService.instance;
      final store = AchievementStore.instance;

      // 切后台上报增量
      await ach.onPlaySecondsElapsed(120);
      // 结算上报剩余时长
      await ach.onPlaySecondsElapsed(180);
      // 弃局/退出上报
      await ach.onPlaySecondsElapsed(45);

      expect(store.getCounter('play_seconds'), equals(120 + 180 + 45));
      // 通关事件不再重复累加时长（避免双通道重复计数）
      await ach.onPuzzleSolved(
        actualPieces: 25,
        elapsedSeconds: 999, // 通关事件不累计 play_seconds
        hintsUsed: 1,
        stars: 2,
        puzzleType: 'main',
        tierIndex: 0,
        canonicalId: 'main:020',
      );
      expect(store.getCounter('play_seconds'), equals(120 + 180 + 45));

      // 负值/零忽略
      await ach.onPlaySecondsElapsed(0);
      await ach.onPlaySecondsElapsed(-5);
      expect(store.getCounter('play_seconds'), equals(120 + 180 + 45));
    });
  });
}
