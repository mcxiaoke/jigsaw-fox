// P1-4：服务层 best-effort：功能失败降级，不阻断主流程
// ignore_for_file: avoid_catches_without_on_clauses
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

  /// 8 档难度解锁所需的 3 星不同图片数量门槛（当前设计：零限制体验，所有难度默认已解锁）
  /// [L1, L1.5, L2, L3, L4, L5, L6, L7]
  static const List<int> kDifficultyStarImageRequirements = [
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ];

  /// 每日挑战所需主线通关数
  static const int kDailyUnlockRequiredMainLevels = 1;

  /// 活动与扩展包所需主线通关数
  static const int kEventUnlockRequiredMainLevels = 5;

  /// 已通关的网络主线关卡数（main:xxx，来自 ProgressStore 全量索引）。
  /// demo 关卡停用后 GameRepository.levels 恒空，不能再作为完成度来源。
  Future<int> _completedMainLevelCount() async {
    try {
      final all = await ProgressStore.instance.loadAllProgress();
      return all.values
          .where(
            (p) =>
                p.canonicalId.startsWith('main:') &&
                (p.isCompleted || p.records.values.any((r) => r.isCompleted)),
          )
          .length;
    } catch (_) {
      return 0;
    }
  }

  /// 同步检查特定难度档位（0~7）是否已解锁（零门槛设计：全部默认已解锁）
  UnlockStatus checkDifficultyUnlockSync(int tierIndex) {
    return const UnlockStatus(isUnlocked: true);
  }

  /// 检查特定难度档位（0~7）是否已解锁（异步完整版，零门槛设计：全部默认已解锁）
  Future<UnlockStatus> checkDifficultyUnlock(int tierIndex) async {
    return const UnlockStatus(isUnlocked: true);
  }

  /// 检查每日挑战是否已解锁
  Future<UnlockStatus> checkDailyChallengeUnlock() async {
    final completedCount = await _completedMainLevelCount();
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
    final completedCount = await _completedMainLevelCount();
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

  /// 检查主线关卡是否解锁。
  ///
  /// ⚠️ levelIndex 制随 demo 关卡停用而废弃（网络关卡无数组下标语义）；
  /// 当前 Phase0 零限制全解锁，恒返回 true。若未来要按序解锁网络关卡，
  /// 需改为按 canonical `main:NNN` order 校验上一关完成状态，勿沿用本签名。
  bool checkLevelUnlock(int levelIndex) => true;
}
