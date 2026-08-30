import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/services/economy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await EconomyService.instance.init();
  });

  group('EconomyService Unit Tests', () {
    test('First completion reward equals Base + StarBonus', () async {
      final eco = EconomyService.instance;

      // L1 (tier 0): Base = 10, 3 stars -> 10 + 15 = 25 coins
      final res = await eco.calculateAndAwardCompletion(
        tierIndex: 0,
        stars: 3,
        isFirstCompletion: true,
        deltaStars: 3,
      );

      expect(res.baseCoins, equals(10));
      expect(res.starCoins, equals(15));
      expect(res.earnedCoins, equals(25));
      expect(eco.coins, equals(25));
    });

    test('Incremental star completion reward awards 5 coins per star', () async {
      final eco = EconomyService.instance;
      await eco.calculateAndAwardCompletion(
        tierIndex: 0,
        stars: 2,
        isFirstCompletion: true,
        deltaStars: 2,
      ); // 10 + 10 = 20 coins

      // Improve from 2 stars to 3 stars (deltaStars = 1)
      final res2 = await eco.calculateAndAwardCompletion(
        tierIndex: 0,
        stars: 3,
        isFirstCompletion: false,
        deltaStars: 1,
      );
      expect(res2.earnedCoins, equals(5));
      expect(eco.coins, equals(25));
    });

    test('Repeat play with same stars awards guaranteed 20% Base', () async {
      final eco = EconomyService.instance;
      // L3 (tier 3): Base = 30 -> 20% = 6 coins
      final res = await eco.calculateAndAwardCompletion(
        tierIndex: 3,
        stars: 3,
        isFirstCompletion: false,
        deltaStars: 0,
      );
      expect(res.earnedCoins, equals(6));
      expect(eco.coins, equals(6));
    });

    test('Daily coin cap 200 is strictly enforced', () async {
      final eco = EconomyService.instance;
      // Add 190 coins
      await eco.addCoins(190);
      expect(eco.dailyEarnedCoins, equals(190));

      // Add 25 coins -> only 10 should be awarded due to cap
      final res = await eco.calculateAndAwardCompletion(
        tierIndex: 0,
        stars: 3,
        isFirstCompletion: true,
        deltaStars: 3,
      );
      expect(res.earnedCoins, equals(10));
      expect(res.isCapped, isTrue);
      expect(eco.dailyEarnedCoins, equals(200));
      expect(eco.coins, equals(200));
    });

    test('Hint consumption priority: Coupon first, then Coins', () async {
      final eco = EconomyService.instance;
      expect(eco.hintCoupons, equals(3));

      // 1. Consume 3 coupons first
      expect(await eco.consumeHint(tierIndex: 0), isTrue);
      expect(eco.hintCoupons, equals(2));
      expect(await eco.consumeHint(tierIndex: 0), isTrue);
      expect(eco.hintCoupons, equals(1));
      expect(await eco.consumeHint(tierIndex: 0), isTrue);
      expect(eco.hintCoupons, equals(0));

      // 2. Next hint fails when coins = 0
      expect(await eco.consumeHint(tierIndex: 0), isFalse);

      // 3. Add 10 coins, L1 hint costs 5 coins -> succeeds and leaves 5
      await eco.addCoins(10);
      expect(await eco.consumeHint(tierIndex: 0), isTrue);
      expect(eco.coins, equals(5));
    });
  });
}
