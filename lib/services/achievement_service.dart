import 'dart:async';

import 'achievement_store.dart';
import 'app_logger.dart';
import 'economy_service.dart';
import 'sound_service.dart';

enum AchievementType {
  accumulative,
  conditional,
  derived,
}

/// 成就静态定义（v3.3.1 设计）
class AchievementDefinition {
  const AchievementDefinition({
    required this.id,
    required this.title,
    required this.description,
    required this.type,
    required this.target,
    this.metricKey = '',
    this.coinReward = 0,
    this.couponReward = 0,
    this.iconAsset = 'assets/icons/cup.png',
  });

  final String id;
  final String title;
  final String description;
  final AchievementType type;
  final int target;
  final String metricKey;
  final int coinReward;
  final int couponReward;
  final String iconAsset;
}

/// 成就系统业务服务（数据驱动，25项里程碑）
class AchievementService {
  AchievementService._();
  static final AchievementService instance = AchievementService._();

  static const List<AchievementDefinition> allAchievements = [
    // 1. 局数累加
    AchievementDefinition(
      id: 'first_win',
      title: '初露锋芒',
      description: '完成任意 1 局拼图',
      type: AchievementType.accumulative,
      target: 1,
      metricKey: 'total_solved',
      coinReward: 20,
    ),
    AchievementDefinition(
      id: 'win_10',
      title: '熟能生巧',
      description: '完成 10 局拼图',
      type: AchievementType.accumulative,
      target: 10,
      metricKey: 'total_solved',
      coinReward: 50,
    ),
    AchievementDefinition(
      id: 'win_50',
      title: '拼图达人',
      description: '完成 50 局拼图',
      type: AchievementType.accumulative,
      target: 50,
      metricKey: 'total_solved',
      coinReward: 150,
    ),
    AchievementDefinition(
      id: 'win_100',
      title: '拼图大师',
      description: '完成 100 局拼图',
      type: AchievementType.accumulative,
      target: 100,
      metricKey: 'total_solved',
      coinReward: 300,
    ),

    // 2. 3 星累加
    AchievementDefinition(
      id: 'three_star_1',
      title: '完美开局',
      description: '首次获得 3 星评价',
      type: AchievementType.accumulative,
      target: 1,
      metricKey: 'three_star_count',
      coinReward: 30,
    ),
    AchievementDefinition(
      id: 'three_star_10',
      title: '十全十美',
      description: '累计获得 10 个 3 星评价',
      type: AchievementType.accumulative,
      target: 10,
      metricKey: 'three_star_count',
      coinReward: 100,
    ),
    AchievementDefinition(
      id: 'three_star_30',
      title: '摘星大师',
      description: '累计获得 30 个 3 星评价',
      type: AchievementType.accumulative,
      target: 30,
      metricKey: 'three_star_count',
      coinReward: 250,
    ),

    // 3. 每日挑战
    AchievementDefinition(
      id: 'daily_1',
      title: '每日打卡',
      description: '完成 1 次每日挑战',
      type: AchievementType.accumulative,
      target: 1,
      metricKey: 'daily_solved',
      coinReward: 30,
    ),
    AchievementDefinition(
      id: 'daily_7',
      title: '坚持不懈',
      description: '完成 7 次每日挑战',
      type: AchievementType.accumulative,
      target: 7,
      metricKey: 'daily_solved',
      coinReward: 100,
    ),
    AchievementDefinition(
      id: 'daily_30',
      title: '月度全勤',
      description: '完成 30 次每日挑战',
      type: AchievementType.accumulative,
      target: 30,
      metricKey: 'daily_solved',
      coinReward: 300,
    ),
    AchievementDefinition(
      id: 'streak_3',
      title: '三连胜',
      description: '连续 3 天完成每日挑战',
      type: AchievementType.accumulative,
      target: 3,
      metricKey: 'daily_streak',
      coinReward: 50,
    ),
    AchievementDefinition(
      id: 'streak_7',
      title: '每日习惯',
      description: '连续 7 天完成每日挑战',
      type: AchievementType.accumulative,
      target: 7,
      metricKey: 'daily_streak',
      coinReward: 120,
    ),
    AchievementDefinition(
      id: 'streak_14',
      title: '毅力勋章',
      description: '连续 14 天完成每日挑战',
      type: AchievementType.accumulative,
      target: 14,
      metricKey: 'daily_streak',
      coinReward: 250,
    ),

    // 4. 自制拼图
    AchievementDefinition(
      id: 'custom_1',
      title: '创作者',
      description: '完成 1 次自制拼图',
      type: AchievementType.accumulative,
      target: 1,
      metricKey: 'custom_solved',
      coinReward: 30,
    ),
    AchievementDefinition(
      id: 'custom_5',
      title: '创意无限',
      description: '完成 5 次自制拼图',
      type: AchievementType.accumulative,
      target: 5,
      metricKey: 'custom_solved',
      coinReward: 100,
    ),

    // 5. 条件型成就
    AchievementDefinition(
      id: 'no_hint_win',
      title: '心灵手巧',
      description: '不使用任何提示完成一局拼图',
      type: AchievementType.conditional,
      target: 1,
      metricKey: 'no_hint_win',
      coinReward: 50,
    ),
    AchievementDefinition(
      id: 'speed_10min',
      title: '疾风拼手',
      description: '10 分钟内完成 ≥100 片的拼图',
      type: AchievementType.conditional,
      target: 1,
      metricKey: 'speed_10min',
      coinReward: 80,
    ),
    AchievementDefinition(
      id: 'night_owl',
      title: '夜猫子',
      description: '在夜间 22:00 ~ 05:00 间完成一局拼图',
      type: AchievementType.conditional,
      target: 1,
      metricKey: 'night_owl',
      coinReward: 30,
    ),

    // 6. 吸附碎片数
    AchievementDefinition(
      id: 'snap_100',
      title: '初试身手',
      description: '累计吸附 100 片碎片',
      type: AchievementType.accumulative,
      target: 100,
      metricKey: 'total_snaps',
      coinReward: 30,
    ),
    AchievementDefinition(
      id: 'snap_500',
      title: '渐入佳境',
      description: '累计吸附 500 片碎片',
      type: AchievementType.accumulative,
      target: 500,
      metricKey: 'total_snaps',
      coinReward: 80,
    ),
    AchievementDefinition(
      id: 'snap_2000',
      title: '千锤百炼',
      description: '累计吸附 2000 片碎片',
      type: AchievementType.accumulative,
      target: 2000,
      metricKey: 'total_snaps',
      coinReward: 200,
    ),

    // 7. 游玩时长
    AchievementDefinition(
      id: 'time_30m',
      title: '沉浸其中',
      description: '累计游玩时间达到 30 分钟',
      type: AchievementType.accumulative,
      target: 1800,
      metricKey: 'play_seconds',
      coinReward: 50,
    ),
    AchievementDefinition(
      id: 'time_2h',
      title: '专注时光',
      description: '累计游玩时间达到 2 小时',
      type: AchievementType.accumulative,
      target: 7200,
      metricKey: 'play_seconds',
      coinReward: 150,
    ),

    // 8. 7 档难度全通
    AchievementDefinition(
      id: 'diff_master',
      title: '全能选手',
      description: '在全部 7 个难度档位均至少通关 1 次',
      type: AchievementType.accumulative,
      target: 7,
      metricKey: 'distinct_tiers',
      coinReward: 200,
    ),

    // 9. 派生大满贯
    AchievementDefinition(
      id: 'master_all',
      title: '终极全成就',
      description: '完成全部其他 24 项成就',
      type: AchievementType.derived,
      target: 24,
      metricKey: 'master_all',
      coinReward: 500,
    ),
  ];

  final _store = AchievementStore.instance;

  /// 成就解锁广播通知流
  final _unlockStreamController = StreamController<AchievementDefinition>.broadcast();
  Stream<AchievementDefinition> get onAchievementUnlocked => _unlockStreamController.stream;

  /// 检查某项成就是否可解锁并触发
  Future<bool> _checkAndUnlock(AchievementDefinition def) async {
    if (_store.isUnlocked(def.id)) return false;

    bool reached = false;
    if (def.type == AchievementType.derived && def.id == 'master_all') {
      final unlockedCount = allAchievements.where((a) => a.id != 'master_all' && _store.isUnlocked(a.id)).length;
      reached = unlockedCount >= 24;
    } else {
      final current = _store.getCounter(def.metricKey);
      reached = current >= def.target;
    }

    if (reached) {
      final success = await _store.markUnlocked(def.id);
      if (success) {
        AppLogger.repo.info('Achievement unlocked:  ()');
        SoundService.I.play(Sfx.coinsFly);
        _unlockStreamController.add(def);
        return true;
      }
    }
    return false;
  }

  /// 批量检查所有成就
  Future<List<AchievementDefinition>> _evaluateAll() async {
    final newlyUnlocked = <AchievementDefinition>[];
    for (final def in allAchievements) {
      if (await _checkAndUnlock(def)) {
        newlyUnlocked.add(def);
      }
    }
    // 二次评估派生成就
    for (final def in allAchievements.where((a) => a.type == AchievementType.derived)) {
      if (await _checkAndUnlock(def)) {
        newlyUnlocked.add(def);
      }
    }
    return newlyUnlocked;
  }

  /// 通关拼图事件触发器
  Future<List<AchievementDefinition>> onPuzzleSolved({
    required int actualPieces,
    required int elapsedSeconds,
    required int hintsUsed,
    required int stars,
    required String puzzleType, // 'main' | 'daily' | 'custom' | 'pack'
    required int tierIndex,
    bool isFirstNoHintWin = false,
  }) async {
    await _store.init();

    // 1. 局数累加
    await _store.incrementCounter('total_solved', 1);

    // 2. 游玩时长累加
    if (elapsedSeconds > 0) {
      await _store.incrementCounter('play_seconds', elapsedSeconds);
    }

    // 3. 3 星评级
    if (stars >= 3) {
      await _store.incrementCounter('three_star_count', 1);
    }

    // 4. 自制拼图
    if (puzzleType == 'custom') {
      await _store.incrementCounter('custom_solved', 1);
    }

    // 5. 条件型：0 提示
    if (hintsUsed == 0 || isFirstNoHintWin) {
      await _store.setCounter('no_hint_win', 1);
    }

    // 6. 条件型：10 分钟内完成 ≥100 片
    if (actualPieces >= 100 && elapsedSeconds <= 600) {
      await _store.setCounter('speed_10min', 1);
    }

    // 7. 条件型：夜猫子 (22:00 ~ 05:00)
    final hour = DateTime.now().hour;
    if (hour >= 22 || hour < 5) {
      await _store.setCounter('night_owl', 1);
    }

    // 8. 档位覆盖
    await _store.incrementCounter('tier_played_', 1);
    var distinctTiers = 0;
    for (var i = 0; i < 7; i++) {
      if (_store.getCounter('tier_played_') > 0) {
        distinctTiers++;
      }
    }
    await _store.setCounter('distinct_tiers', distinctTiers);

    return await _evaluateAll();
  }

  /// 吸附碎片计数触发器
  Future<List<AchievementDefinition>> onPieceSnapped([int count = 1]) async {
    await _store.init();
    await _store.incrementCounter('total_snaps', count);
    return await _evaluateAll();
  }

  /// 每日挑战完成触发器
  Future<List<AchievementDefinition>> onDailyCompleted({required int streak}) async {
    await _store.init();
    await _store.incrementCounter('daily_solved', 1);
    final curStreak = _store.getCounter('daily_streak');
    if (streak > curStreak) {
      await _store.setCounter('daily_streak', streak);
    }
    return await _evaluateAll();
  }

  /// 领取成就奖励（金币与道具券）
  Future<bool> claimReward(String achievementId) async {
    await _store.init();
    if (!_store.isUnlocked(achievementId) || _store.isClaimed(achievementId)) {
      return false;
    }

    final def = allAchievements.firstWhere((a) => a.id == achievementId, orElse: () => throw 'Unknown achievement ');
    await _store.markClaimed(achievementId);

    if (def.coinReward > 0) {
      await EconomyService.instance.addCoins(def.coinReward, bypassCap: true);
    }
    if (def.couponReward > 0) {
      await EconomyService.instance.addHintCoupons(def.couponReward);
    }

    AppLogger.repo.info('Claimed reward for achievement:  (+ coins)');
    return true;
  }
}
