import 'dart:math' as math;

import 'package:hive_ce/hive_ce.dart';

import 'app_logger.dart';
import '../data/storage_manager.dart';

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

  /// 7 档难度基准金币：[L1, L1.5, L2, L3, L4, L5, L6]（设计 §6.1 压缩倍率表）
  static const List<int> kDifficultyBaseCoins = [5, 6, 8, 12, 15, 20, 25];

  /// 阶梯星数加成表（设计 §6.1）：每档数组下标 0=1星、1=2星、2=3星；
  /// 1 星不加成（+0），2 星 / 3 星按档位阶梯递增。
  /// 3 星总收益 = Base + 3星加成（L1=10 ... L6=55，高低档倍率 5.5×）。
  static const List<List<int>> kStarBonusTable = [
    [0, 2, 5], // L1
    [0, 3, 6], // L1.5
    [0, 4, 7], // L2
    [0, 5, 10], // L3
    [0, 7, 15], // L4
    [0, 10, 20], // L5
    [0, 15, 30], // L6
  ];

  /// 纯函数：某档位某星级的总通关收益 = Base + StarBonus（设计 §6.1）
  static int rewardFor(int tierIndex, int stars) {
    final safeTier = tierIndex.clamp(0, kDifficultyBaseCoins.length - 1);
    final safeStars = stars.clamp(1, 3);
    final bonus = kStarBonusTable[safeTier][safeStars - 1];
    return kDifficultyBaseCoins[safeTier] + bonus;
  }

  /// 7 档难度提示定价：[L1, L1.5, L2, L3, L4, L5, L6]
  static const List<int> kHintPrices = [5, 6, 10, 15, 20, 25, 35];

  /// 每日金币获取上限
  static const int kDailyCoinCap = 200;

  /// 新手赠送：免费提示券数量 + 初始金币（设计 §6.2 新手赠送 5 券 + 100 金币）
  static const int kInitialHintCoupons = 5;
  static const int kInitialCoins = 100;

  // 存储迁移（§2.2 / §4.3）：原 5 个 经济 prefs key prefs key 改为
  // app-state-v1 的原生类型 key（int/String/bool 直接 put/get，无 jsonEncode）
  static const String _keyCoins = 'econ:coins';
  static const String _keyCoupons = 'econ:hintCoupons';
  static const String _keyDailyEarned = 'econ:dailyEarned';
  static const String _keyDailyDate = 'econ:dailyDate';
  static const String _keyStarterGranted = 'econ:starterGranted';

  Box<dynamic> get _box => StorageManager.instance.state;

  bool _initialized = false;

  /// **注意默认值为 0**（§4.3）：初始 100 由 starter 补发流程写入，
  /// 不得用 `box.get(key, defaultValue: 100)` 硬编码 100，否则与补发冲突
  int get coins => _initialized ? (_box.get(_keyCoins) as int? ?? 0) : 0;
  int get hintCoupons =>
      _initialized ? (_box.get(_keyCoupons) as int? ?? 0) : 0; // 初始赠送见 init()

  String _todayDateStr() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  int get dailyEarnedCoins {
    if (!_initialized) return 0;
    final today = _todayDateStr();
    final savedDate = _box.get(_keyDailyDate) as String? ?? '';
    if (savedDate != today) return 0;
    return _box.get(_keyDailyEarned) as int? ?? 0;
  }

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    // 新手赠送（仅首次启动一次，标记防重复）：5 券 + 100 金币（设计 §6.2）
    if (!(_box.get(_keyStarterGranted) as bool? ?? false)) {
      await _box.put(_keyCoins, kInitialCoins);
      await _box.put(_keyCoupons, kInitialHintCoupons);
      await _box.put(_keyStarterGranted, true);
    }
  }

  /// 重置（§7.6 步骤 4，本次新建）：直接重发 starter 资产，
  /// 保证 resetAllData 后当前会话金币=100/券=5，无需杀进程重启补发
  Future<void> reset() async {
    _initialized = true;
    await _box.put(_keyCoins, kInitialCoins);
    await _box.put(_keyCoupons, kInitialHintCoupons);
    await _box.put(_keyStarterGranted, true);
    await _box.put(_keyDailyEarned, 0);
    await _box.put(_keyDailyDate, '');
    AppLogger.repo.info('EconomyService.reset done (starter re-granted)');
  }

  /// 增加金币（受日上限控制）
  Future<int> addCoins(int amount, {bool bypassCap = false}) async {
    await init();
    if (amount <= 0) return 0;

    final today = _todayDateStr();
    final savedDate = _box.get(_keyDailyDate) as String? ?? '';
    var currentDaily = savedDate == today
        ? (_box.get(_keyDailyEarned) as int? ?? 0)
        : 0;

    int actualEarned;
    if (bypassCap) {
      actualEarned = amount;
    } else {
      final remainingCap = math.max(0, kDailyCoinCap - currentDaily);
      actualEarned = math.min(amount, remainingCap);
      currentDaily += actualEarned;
      await _box.put(_keyDailyDate, today);
      await _box.put(_keyDailyEarned, currentDaily);
    }

    final newTotal = coins + actualEarned;
    await _box.put(_keyCoins, newTotal);
    AppLogger.repo.info(
      'EconomyService.addCoins +$actualEarned (total=$newTotal daily=$currentDaily bypass=$bypassCap)',
    );
    return actualEarned;
  }

  /// 增加/赠送免费提示券
  Future<void> addHintCoupons(int count) async {
    await init();
    if (count <= 0) return;
    final newTotal = hintCoupons + count;
    await _box.put(_keyCoupons, newTotal);
    AppLogger.repo.info(
      'EconomyService.addHintCoupons +$count (total=$newTotal)',
    );
  }

  /// 通关结算发奖（增量制 + 复玩保底 20% Base + 日上限 200）
  ///
  /// 发放规则（设计 §6.1）：
  /// - 首次通关：全额 `rewardFor(tier, stars)`（Base + StarBonus）
  /// - 破星纪录：增量 `rewardFor(tier, newStars) - rewardFor(tier, bestStars)`
  ///   （`bestStars = stars - deltaStars` 由调用方传入的 deltaStars 推导）
  /// - 复玩未破纪录：保底 `floor(Base × 20%)`（≥1，防死锁）
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
      // 首次通关：Base + StarBonus（阶梯表）
      targetAmount = rewardFor(safeTier, stars);
    } else if (deltaStars > 0) {
      // 提升星级增量：rewardFor(newStars) - rewardFor(bestStars)
      final bestStars = stars - deltaStars;
      targetAmount =
          rewardFor(safeTier, stars) - rewardFor(safeTier, bestStars);
      if (targetAmount < 0) targetAmount = 0;
    } else {
      // 重复通关且无星数突破：保底奖励 20% Base（向下取整，防死锁）
      targetAmount = math.max(1, (baseCoins * 0.2).floor());
    }

    final actualEarned = await addCoins(targetAmount);
    final isCapped = actualEarned < targetAmount;

    return SettlementRewardResult(
      baseCoins: baseCoins,
      starCoins: rewardFor(safeTier, stars) - baseCoins,
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
      await _box.put(_keyCoupons, hintCoupons - 1);
      AppLogger.repo.info(
        'EconomyService.consumeHint used coupon (remaining=${hintCoupons - 1})',
      );
      return true;
    }

    // 2. 扣金币
    final safeTier = tierIndex.clamp(0, kHintPrices.length - 1);
    final price = kHintPrices[safeTier];
    if (coins >= price) {
      final newTotal = coins - price;
      await _box.put(_keyCoins, newTotal);
      AppLogger.repo.info(
        'EconomyService.consumeHint used coins -$price (remaining=$newTotal)',
      );
      return true;
    }

    // 3. 余额不足
    AppLogger.repo.info(
      'EconomyService.consumeHint fail: coins=$coins < price=$price',
    );
    return false;
  }
}
