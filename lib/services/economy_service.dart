import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// 经济与奖励结算结果
class SettlementRewardResult {
  const SettlementRewardResult({
    required this.baseCoins,
    required this.starCoins,
    required this.earnedCoins,
    required this.isCapped,
    required this.dailyEarnedTotal,
  });

  final int baseCoins;
  final int starCoins;
  final int earnedCoins;
  final bool isCapped;
  final int dailyEarnedTotal;
}

/// 经济与道具系统服务（v3.3.1 设计）
///
/// 管理金币、免费提示券、通关增量发奖、日收益上限（200币）与提示扣费。
class EconomyService {
  EconomyService._();
  static final EconomyService instance = EconomyService._();

  static const String _keyCoins = 'jigsaw_economy_coins';
  static const String _keyCoupons = 'jigsaw_economy_hint_coupons';
  static const String _keyDailyEarned = 'jigsaw_economy_daily_earned';
  static const String _keyDailyDate = 'jigsaw_economy_daily_date';

  /// 7 档难度基准金币：[L1, L1.5, L2, L3, L4, L5, L6]
  static const List<int> kDifficultyBaseCoins = [10, 15, 20, 30, 45, 60, 80];

  /// 7 档难度提示定价：[L1, L1.5, L2, L3, L4, L5, L6]
  static const List<int> kHintPrices = [5, 6, 10, 15, 20, 25, 35];

  /// 每日金币获取上限
  static const int kDailyCoinCap = 200;

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  int get coins => _prefs?.getInt(_keyCoins) ?? 0;
  int get hintCoupons => _prefs?.getInt(_keyCoupons) ?? 3; // 初始赠送 3 张券

  String _todayDateStr() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  int get dailyEarnedCoins {
    final today = _todayDateStr();
    final savedDate = _prefs?.getString(_keyDailyDate) ?? '';
    if (savedDate != today) return 0;
    return _prefs?.getInt(_keyDailyEarned) ?? 0;
  }

  /// 增加金币（受日上限控制）
  Future<int> addCoins(int amount, {bool bypassCap = false}) async {
    await init();
    if (amount <= 0) return 0;

    final today = _todayDateStr();
    final savedDate = _prefs?.getString(_keyDailyDate) ?? '';
    var currentDaily = (savedDate == today) ? (_prefs?.getInt(_keyDailyEarned) ?? 0) : 0;

    int actualEarned;
    if (bypassCap) {
      actualEarned = amount;
    } else {
      final remainingCap = math.max(0, kDailyCoinCap - currentDaily);
      actualEarned = math.min(amount, remainingCap);
      currentDaily += actualEarned;
      await _prefs?.setString(_keyDailyDate, today);
      await _prefs?.setInt(_keyDailyEarned, currentDaily);
    }

    final newTotal = coins + actualEarned;
    await _prefs?.setInt(_keyCoins, newTotal);
    AppLogger.repo.info('EconomyService.addCoins + (total= daily=/ bypass=)');
    return actualEarned;
  }

  /// 增加/赠送免费提示券
  Future<void> addHintCoupons(int count) async {
    await init();
    if (count <= 0) return;
    final newTotal = hintCoupons + count;
    await _prefs?.setInt(_keyCoupons, newTotal);
    AppLogger.repo.info('EconomyService.addHintCoupons + (total=)');
  }

  /// 通关结算发奖（增量制 + 复玩保底 20% Base + 日上限 200）
  Future<SettlementRewardResult> calculateAndAwardCompletion({
    required int tierIndex,
    required int stars,
    required bool isFirstCompletion,
    required int deltaStars,
  }) async {
    final safeTier = tierIndex.clamp(0, kDifficultyBaseCoins.length - 1);
    final baseCoins = kDifficultyBaseCoins[safeTier];

    int targetAmount;
    if (isFirstCompletion) {
      // 首次通关：Base + StarBonus (每星 +5)
      targetAmount = baseCoins + (stars * 5);
    } else if (deltaStars > 0) {
      // 提升星级增量：每增 1 星 +5 币
      targetAmount = deltaStars * 5;
    } else {
      // 重复通关且无星数突破：保底奖励 20% Base（向下取整，防死锁）
      targetAmount = math.max(1, (baseCoins * 0.2).floor());
    }

    final actualEarned = await addCoins(targetAmount);
    final isCapped = actualEarned < targetAmount;

    return SettlementRewardResult(
      baseCoins: baseCoins,
      starCoins: stars * 5,
      earnedCoins: actualEarned,
      isCapped: isCapped,
      dailyEarnedTotal: dailyEarnedCoins,
    );
  }

  /// 提示消费判定与扣费（优先级：免费券 -> 金币 -> 失败）
  Future<bool> consumeHint({required int tierIndex}) async {
    await init();
    // 1. 优先扣免费提示券
    if (hintCoupons > 0) {
      await _prefs?.setInt(_keyCoupons, hintCoupons - 1);
      AppLogger.repo.info('EconomyService.consumeHint used coupon (remaining=)');
      return true;
    }

    // 2. 扣金币
    final safeTier = tierIndex.clamp(0, kHintPrices.length - 1);
    final price = kHintPrices[safeTier];
    if (coins >= price) {
      final newTotal = coins - price;
      await _prefs?.setInt(_keyCoins, newTotal);
      AppLogger.repo.info('EconomyService.consumeHint used  coins (remaining=)');
      return true;
    }

    // 3. 余额不足
    AppLogger.repo.info('EconomyService.consumeHint fail: coins= < price=');
    return false;
  }
}
