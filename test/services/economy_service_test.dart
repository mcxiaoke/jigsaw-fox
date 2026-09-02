import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/services/economy_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await EconomyService.instance.init();
  });

  group('EconomyService §6.1 Design Table', () {
    test('rewardFor matches design §6.1 3-star total reward (5.5x ratio)', () {
      expect(EconomyService.rewardFor(0, 3), 10); // L1
      expect(EconomyService.rewardFor(1, 3), 12); // L1.5
      expect(EconomyService.rewardFor(2, 3), 15); // L2
      expect(EconomyService.rewardFor(3, 3), 22); // L3
      expect(EconomyService.rewardFor(4, 3), 30); // L4
      expect(EconomyService.rewardFor(5, 3), 40); // L5
      expect(EconomyService.rewardFor(6, 3), 55); // L6

      // D5 压缩倍率：高低档 3 星总收益 5.5×
      expect(55 / 10, closeTo(5.5, 0.001));
    });

    test('1-star adds zero bonus, 2-star and 3-star use tier ladder', () {
      expect(EconomyService.rewardFor(0, 1), 5); // L1 1星 = Base
      expect(EconomyService.rewardFor(0, 2), 7); // L1 +2星
      expect(EconomyService.rewardFor(6, 1), 25); // L6 1星 = Base
      expect(EconomyService.rewardFor(6, 2), 40); // L6 +2星
      expect(EconomyService.rewardFor(6, 3), 55); // L6 +3星
    });

    test(
      'Hint price invariant: hintPrice <= 2-star reward for all tiers (§6.2)',
      () {
        for (var t = 0; t < 7; t++) {
          final twoStarReward = EconomyService.rewardFor(t, 2);
          expect(
            EconomyService.kHintPrices[t],
            lessThanOrEqualTo(twoStarReward),
            reason:
                'tier $t hint price ${EconomyService.kHintPrices[t]} exceeds 2-star reward $twoStarReward',
          );
        }
      },
    );
  });

  group('EconomyService Settlement', () {
    test(
      'First completion pays full Base + StarBonus (L1 3-star = 10 coins)',
      () async {
        final eco = EconomyService.instance;
        final before = eco.coins;

        final res = await eco.calculateAndAwardCompletion(
          tierIndex: 0,
          stars: 3,
          isFirstCompletion: true,
          deltaStars: 3,
        );

        expect(res.baseCoins, equals(5));
        expect(res.starCoins, equals(5)); // +3星 阶梯加成
        expect(res.earnedCoins, equals(10));
        expect(eco.coins - before, equals(10));
      },
    );

    test(
      'Incremental star reward = rewardFor(new) - rewardFor(best)',
      () async {
        final eco = EconomyService.instance;
        final before = eco.coins;

        // L1 首通 2 星 = 5 + 2 = 7
        final r1 = await eco.calculateAndAwardCompletion(
          tierIndex: 0,
          stars: 2,
          isFirstCompletion: true,
          deltaStars: 2,
        );
        expect(r1.earnedCoins, equals(7));

        // 2星 -> 3星：增量 = rewardFor(3) - rewardFor(2) = 10 - 7 = 3
        final r2 = await eco.calculateAndAwardCompletion(
          tierIndex: 0,
          stars: 3,
          isFirstCompletion: false,
          deltaStars: 1,
        );
        expect(r2.earnedCoins, equals(3));
        // 两局合计增量 = 7 + 3 = 10（不重复发 1 星 0 加成）
        expect(eco.coins - before, equals(10));
      },
    );

    test(
      'Repeat play with same stars awards guaranteed 20% Base (L3 = 2 coins)',
      () async {
        final eco = EconomyService.instance;
        // L3 (tier 3): Base = 12 -> 20% = 2.4 floor = 2（设计 §6.1 复玩保底）
        final res = await eco.calculateAndAwardCompletion(
          tierIndex: 3,
          stars: 3,
          isFirstCompletion: false,
          deltaStars: 0,
        );
        expect(res.earnedCoins, equals(2));
        expect(res.starCoins, equals(10)); // 22 - 12
      },
    );

    test('Daily coin cap 200 is strictly enforced', () async {
      final eco = EconomyService.instance;
      // 已获 195 币
      await eco.addCoins(195);
      expect(eco.dailyEarnedCoins, equals(195));

      // L1 3星 10 币 -> 剩余额度 5，只发 5
      final res = await eco.calculateAndAwardCompletion(
        tierIndex: 0,
        stars: 3,
        isFirstCompletion: true,
        deltaStars: 3,
      );
      expect(res.earnedCoins, equals(5));
      expect(res.isCapped, isTrue);
      expect(eco.dailyEarnedCoins, equals(200));
    });
  });

  group('EconomyService Hint & Starter Gift', () {
    test(
      'Starter gift grants 5 hint coupons + 100 coins on first init (§6.2)',
      () async {
        final eco = EconomyService.instance;
        expect(eco.hintCoupons, equals(5));
        expect(eco.coins, equals(100));
      },
    );

    test('Hint consumption priority: Coupon first, then Coins', () async {
      final eco = EconomyService.instance;
      expect(eco.hintCoupons, equals(5));

      // 1. 5 张免费券优先消耗
      for (var i = 0; i < 5; i++) {
        expect(await eco.consumeHint(tierIndex: 0), isTrue);
      }
      expect(eco.hintCoupons, equals(0));

      // 2. 券耗尽后走金币：L1 提示价 5 币，扣 5 剩 95
      final coinsBefore = eco.coins;
      expect(await eco.consumeHint(tierIndex: 0), isTrue);
      expect(eco.coins, equals(coinsBefore - 5));

      // 3. 金币不足时失败（预置已赠送标记避免 init 重复发新手礼）
      SharedPreferences.setMockInitialValues({
        'jigsaw_economy_coins': 0,
        'jigsaw_economy_hint_coupons': 0,
        'jigsaw_economy_starter_granted': true,
      });
      await eco.init();
      expect(await eco.consumeHint(tierIndex: 0), isFalse);
    });
  });
}
