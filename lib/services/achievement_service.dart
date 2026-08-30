import 'economy_service.dart';
import 'dart:async';

import 'achievement_store.dart';
import 'app_logger.dart';
import 'sound_service.dart';

/// 成就类型
enum AchievementType {
  /// 累积计数型（如通关 10 局、吸附 500 片）
  accumulative,

  /// 单次条件型（如 0 提示通关、10分钟内完成 100 块）
  conditional,

  /// 派生集合型（如解锁其他全部 24 个成就）
  derived,
}

/// 静态不可变成就定义
class AchievementDefinition {
  const AchievementDefinition({
    required this.id,
    required this.title,
    required this.description,
    required this.type,
    required this.target,
    required this.metricKey,
    required this.coinReward,
  });

  final String id;
  final String title;
  final String description;
  final AchievementType type;
  final int target;
  final String metricKey;
  final int coinReward;
}

/// 成就服务核心引擎（25 项官方成就 SSOT）
class AchievementService {
  AchievementService._();
  static final AchievementService instance = AchievementService._();

  final AchievementStore _store = AchievementStore.instance;

  /// 全部 25 项成就定义（Dart const 静态表）
  static const List<AchievementDefinition> allAchievements = [
    // 1. 通关局数
    AchievementDefinition(
      id: 'first_win',
      title: '初露锋芒',
      description: '完成第一局拼图',
      type: AchievementType.accumulative,
      target: 1,
      metricKey: 'total_solved',
      coinReward: 20,
    ),
    AchievementDefinition(
      id: 'win_10',
      title: '熟能生巧',
      description: '累计完成 10 局拼图',
      type: AchievementType.accumulative,
      target: 10,
      metricKey: 'total_solved',
      coinReward: 50,
    ),
    AchievementDefinition(
      id: 'win_50',
      title: '拼图达人',
      description: '累计完成 50 局拼图',
      type: AchievementType.accumulative,
      target: 50,
      metricKey: 'total_solved',
      coinReward: 100,
    ),
    AchievementDefinition(
      id: 'win_100',
      title: '拼图大师',
      description: '累计完成 100 局拼图',
      type: AchievementType.accumulative,
      target: 100,
      metricKey: 'total_solved',
      coinReward: 200,
    ),

    // 2. 三星成就
    AchievementDefinition(
      id: 'star_1',
      title: '三星启航',
      description: '首次以 3 星评价完成拼图',
      type: AchievementType.accumulative,
      target: 1,
      metricKey: 'three_star_count',
      coinReward: 30,
    ),
    AchievementDefinition(
      id: 'star_10',
      title: '闪耀之星',
      description: '累计获得 10 个 3 星评价',
      type: AchievementType.accumulative,
      target: 10,
      metricKey: 'three_star_count',
      coinReward: 80,
    ),
    AchievementDefinition(
      id: 'star_30',
      title: '群星璀璨',
      description: '累计获得 30 个 3 星评价',
      type: AchievementType.accumulative,
      target: 30,
      metricKey: 'three_star_count',
      coinReward: 150,
    ),
    AchievementDefinition(
      id: 'star_50',
      title: '星光领主',
      description: '累计获得 50 个 3 星评价',
      type: AchievementType.accumulative,
      target: 50,
      metricKey: 'three_star_count',
      coinReward: 300,
    ),

    // 3. 难度档位突破
    AchievementDefinition(
      id: 'tier_l3',
      title: '中阶挑战',
      description: '完成一次中等（L3）及以上难度拼图',
      type: AchievementType.accumulative,
      target: 1,
      metricKey: 'tier_l3_solved',
      coinReward: 50,
    ),
    AchievementDefinition(
      id: 'tier_l4',
      title: '进阶高手',
      description: '完成一次进阶（L4）及以上难度拼图',
      type: AchievementType.accumulative,
      target: 1,
      metricKey: 'tier_l4_solved',
      coinReward: 80,
    ),
    AchievementDefinition(
      id: 'tier_l5',
      title: '困难征服',
      description: '完成一次困难（L5）及以上难度拼图',
      type: AchievementType.accumulative,
      target: 1,
      metricKey: 'tier_l5_solved',
      coinReward: 150,
    ),
    AchievementDefinition(
      id: 'tier_l6',
      title: '极限登顶',
      description: '完成一次极限（L6）难度拼图',
      type: AchievementType.accumulative,
      target: 1,
      metricKey: 'tier_l6_solved',
      coinReward: 300,
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
      title: '拼图发烧友',
      description: '累计游玩时间达到 2 小时',
      type: AchievementType.accumulative,
      target: 7200,
      metricKey: 'play_seconds',
      coinReward: 120,
    ),
    AchievementDefinition(
      id: 'time_10h',
      title: '岁月如歌',
      description: '累计游玩时间达到 10 小时',
      type: AchievementType.accumulative,
      target: 36000,
      metricKey: 'play_seconds',
      coinReward: 300,
    ),

    // 8. 每日挑战
    AchievementDefinition(
      id: 'daily_7',
      title: '日积月累',
      description: '累计完成 7 次每日挑战',
      type: AchievementType.accumulative,
      target: 7,
      metricKey: 'daily_solved',
      coinReward: 100,
    ),

    // 9. 大满贯
    AchievementDefinition(
      id: 'master_all',
      title: '拼图宗师',
      description: '达成以上全部 24 项成就',
      type: AchievementType.derived,
      target: 24,
      metricKey: 'master_all',
      coinReward: 1000,
    ),
  ];

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
        AppLogger.repo.info('Achievement unlocked: ${def.title} (${def.id})');
        SoundService.I.play(Sfx.coinsFly);
        _unlockStreamController.add(def);
        return true;
      }
    }
    return false;
  }

  /// 批量检查所有成就（纯内存极速评估）
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

  /// 游玩时长增量上报（设计 §8.1 生命周期口径）
  ///
  /// `playSeconds` 在对局生命周期增量上报：暂停/切后台/结算/退出时由
  /// GamePage 上报增量，弃局与挂机中途的时间同样计入；
  /// 通关结算路径不再重复累加（`onPuzzleSolved` 不含 play_seconds）。
  Future<void> onPlaySecondsElapsed(int deltaSeconds) async {
    if (deltaSeconds <= 0) return;
    await _store.init();
    await _store.incrementCounter('play_seconds', deltaSeconds);
  }

  /// 通关拼图事件触发器（纯内存处理与一次性评估）
  Future<List<AchievementDefinition>> onPuzzleSolved({
    required int actualPieces,
    required int elapsedSeconds,
    required int hintsUsed,
    required int stars,
    required String puzzleType, // 'main' | 'daily' | 'custom' | 'pack'
    required int tierIndex,
    required String canonicalId,
    bool isFirstNoHintWin = false,
  }) async {
    await _store.init();

    // 1. 局数累加
    await _store.incrementCounter('total_solved', 1);

    // 3. 3 星评级（按 canonicalId 去重：同一张图多档刷 3 星只计 1 次，设计 §8.3）
    if (stars >= 3 && canonicalId.isNotEmpty) {
      final isNew = await _store.addStarred(canonicalId);
      if (isNew) {
        await _store.incrementCounter('three_star_count', 1);
      }
    }

    // 4. 自制拼图
    if (puzzleType == 'custom') {
      await _store.incrementCounter('custom_solved', 1);
    }

    // 5. 每日挑战
    if (puzzleType == 'daily') {
      await _store.incrementCounter('daily_solved', 1);
    }

    // 6. 吸附碎片总数累加
    if (actualPieces > 0) {
      await _store.incrementCounter('total_snaps', actualPieces);
    }

    // 7. 条件型：0 提示
    if (hintsUsed == 0 || isFirstNoHintWin) {
      await _store.setCounter('no_hint_win', 1);
    }

    // 8. 条件型：疾风拼手（10 分钟内完成 ≥100 块）
    if (actualPieces >= 100 && elapsedSeconds <= 600) {
      await _store.setCounter('speed_10min', 1);
    }

    // 9. 条件型：夜猫子（22:00 ~ 05:00）
    final nowHour = DateTime.now().hour;
    if (nowHour >= 22 || nowHour < 5) {
      await _store.setCounter('night_owl', 1);
    }

    // 10. 档位突破
    if (tierIndex >= 3) await _store.setCounter('tier_l3_solved', 1);
    if (tierIndex >= 4) await _store.setCounter('tier_l4_solved', 1);
    if (tierIndex >= 5) await _store.setCounter('tier_l5_solved', 1);
    if (tierIndex >= 6) await _store.setCounter('tier_l6_solved', 1);

    return await _evaluateAll();
  }

  /// 领取成就金币奖励（计入每日 200 币软帽，设计 §6.1 "全渠道" + §8.1 日上限兜底）
  Future<bool> claimReward(String achievementId) async {
    await _store.init();
    if (!_store.isUnlocked(achievementId)) return false;
    if (_store.isClaimed(achievementId)) return false;

    final def = allAchievements.firstWhere((a) => a.id == achievementId);
    await _store.markClaimed(achievementId);
    await EconomyService.instance.init();
    await EconomyService.instance.addCoins(def.coinReward);
    return true;
  }
}
