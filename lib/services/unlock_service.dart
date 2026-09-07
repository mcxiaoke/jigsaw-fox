import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';

/// 解锁状态详细信息
class UnlockStatus {
  const UnlockStatus({
    required this.isUnlocked,
    this.reason = '',
    this.currentProgress = 0,
    this.targetRequired = 0,
  });

  final bool isUnlocked;
  final String reason;
  final int currentProgress;
  final int targetRequired;
}

/// 内容与难度解锁规则引擎（SSOT 架构，v3.3.1 设计）
///
/// 遵循休闲宽松原则，直接从 ProgressStore 与 GameRepository 获取真实状态，
/// 零冗余持久化字段。
class UnlockService {
  UnlockService._();
  static final UnlockService instance = UnlockService._();

  /// 8 档难度解锁所需的 3 星不同图片数量门槛
  /// [L1, L1.5, L2, L3, L4, L5, L6, L7]
  static const List<int> kDifficultyStarImageRequirements = [
    0,
    0,
    0,
    0,
    2,
    5,
    10,
    15,
  ];

  /// 每日挑战所需主线通关数
  static const int kDailyUnlockRequiredMainLevels = 1;

  /// 活动与扩展包所需主线通关数
  static const int kEventUnlockRequiredMainLevels = 5;

  /// 同步检查特定难度档位（0~7）是否已解锁（避免首帧渲染跳变）
  UnlockStatus checkDifficultyUnlockSync(int tierIndex) {
    final safeTier = tierIndex.clamp(
      0,
      kDifficultyStarImageRequirements.length - 1,
    );
    final req = kDifficultyStarImageRequirements[safeTier];
    if (req <= 0) {
      return const UnlockStatus(isUnlocked: true);
    }

    final count3Star = ProgressStore.instance.cachedDistinct3StarCount;
    if (count3Star >= req) {
      return UnlockStatus(
        isUnlocked: true,
        currentProgress: count3Star,
        targetRequired: req,
      );
    }

    return UnlockStatus(
      isUnlocked: false,
      reason: LocaleSettings.instance.currentTranslations.unlock.stars3(
        req: req,
        current: count3Star,
      ),
      currentProgress: count3Star,
      targetRequired: req,
    );
  }

  /// 检查特定难度档位（0~7）是否已解锁（异步完整版）
  Future<UnlockStatus> checkDifficultyUnlock(int tierIndex) async {
    final safeTier = tierIndex.clamp(
      0,
      kDifficultyStarImageRequirements.length - 1,
    );
    final req = kDifficultyStarImageRequirements[safeTier];
    if (req <= 0) {
      return const UnlockStatus(isUnlocked: true);
    }

    final count3Star = await ProgressStore.instance
        .getDistinctImagesWith3Star();
    if (count3Star >= req) {
      return UnlockStatus(
        isUnlocked: true,
        currentProgress: count3Star,
        targetRequired: req,
      );
    }

    return UnlockStatus(
      isUnlocked: false,
      reason: LocaleSettings.instance.currentTranslations.unlock.stars3(
        req: req,
        current: count3Star,
      ),
      currentProgress: count3Star,
      targetRequired: req,
    );
  }

  /// 检查每日挑战是否已解锁
  Future<UnlockStatus> checkDailyChallengeUnlock() async {
    final completedCount = GameRepository.instance.levels
        .where((l) => l.isCompleted)
        .length;
    if (completedCount >= kDailyUnlockRequiredMainLevels) {
      return UnlockStatus(
        isUnlocked: true,
        currentProgress: completedCount,
        targetRequired: kDailyUnlockRequiredMainLevels,
      );
    }

    return UnlockStatus(
      isUnlocked: false,
      reason: LocaleSettings.instance.currentTranslations.unlock.daily,
      currentProgress: completedCount,
      targetRequired: kDailyUnlockRequiredMainLevels,
    );
  }

  /// 检查活动与图包是否已解锁
  Future<UnlockStatus> checkEventUnlock() async {
    final completedCount = GameRepository.instance.levels
        .where((l) => l.isCompleted)
        .length;
    if (completedCount >= kEventUnlockRequiredMainLevels) {
      return UnlockStatus(
        isUnlocked: true,
        currentProgress: completedCount,
        targetRequired: kEventUnlockRequiredMainLevels,
      );
    }

    return UnlockStatus(
      isUnlocked: false,
      reason: LocaleSettings.instance.currentTranslations.unlock.eventPack(
        req: kEventUnlockRequiredMainLevels,
        current: completedCount,
      ),
      currentProgress: completedCount,
      targetRequired: kEventUnlockRequiredMainLevels,
    );
  }

  /// 检查主线关卡是否解锁（第 1 关默认开，通关上一关解锁下一关）
  bool checkLevelUnlock(int levelIndex) {
    if (levelIndex <= 1) return true;
    final levels = GameRepository.instance.levels;
    if (levelIndex - 2 < levels.length) {
      return levels[levelIndex - 2].isCompleted;
    }
    return false;
  }
}
