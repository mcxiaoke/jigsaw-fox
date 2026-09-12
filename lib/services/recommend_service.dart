// P1-4：服务层 best-effort：功能失败降级，不阻断主流程
// ignore_for_file: avoid_catches_without_on_clauses
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';

/// 推荐难度规则（纯静态，可独立单测）
///
/// 档位序 0~7 = [L1, L1.5, L2, L3, L4, L5, L6, L7]。
/// 产品决策（2026-09-09）：
/// - 默认推荐 **2 档（L2）**，从不推荐 1/1.5 档；
/// - 升档阈值按「**该档位及以上**」的后缀累计完成数判定：2→3 累计 5 张，
///   3→4 累计 10 张，4→5 累计 10 张（熟练用户可能一开始就选高难关卡，
///   直接玩 L3+ / L4+ 同样计入该档位及以上的征服进度）；
/// - **最高推荐 5 档（L5）**，永不推荐 6 档（7 档未启用）；
/// - 只上推、不下降：从高到低取首个达标的累计档位 + 1。
class RecommendRule {
  RecommendRule._();

  /// 默认（新玩家 / 兜底）推荐档
  static const int defaultTierIndex = 2;

  /// 推荐档下限（永不推荐 L1 / L1.5）
  static const int minTierIndex = 2;

  /// 推荐档上限（永不推荐 L6 / L7）
  static const int maxTierIndex = 5;

  /// 升档阈值：某档位「及以上的后缀累计完成数」≥ 对应张图 → 推荐上移一档
  static const Map<int, int> promoteThresholds = {
    2: 5, // L2 及以上累计 5 张 → 推荐 L3
    3: 10, // L3 及以上累计 10 张 → 推荐 L4
    4: 10, // L4 及以上累计 10 张 → 推荐 L5
  };

  static const List<String> tierLevels = [
    'L1',
    'L1.5',
    'L2',
    'L3',
    'L4',
    'L5',
    'L6',
    'L7',
  ];

  /// 档位序 → tierLevel 字符串（越界回退 'L2'）
  static String levelOf(int tierIndex) {
    if (tierIndex < 0 || tierIndex >= tierLevels.length) {
      return tierLevels[defaultTierIndex];
    }
    return tierLevels[tierIndex];
  }

  /// 解析难度 key（`SnapshotStore.difficultyKeyFor` 的 `'rowsxcols'` 格式）
  /// 为该局的档位序；无法解析返回 -1（调用方应跳过，不计入统计）。
  static int tierIndexOfKey(String difficultyKey) {
    final parts = difficultyKey.split('x');
    if (parts.length != 2) return -1;
    final r = int.tryParse(parts[0].trim());
    final c = int.tryParse(parts[1].trim());
    if (r == null || c == null || r <= 0 || c <= 0) return -1;
    // PuzzleDifficulty.tierIndex 仅依赖 rows/cols，label 用占位串
    return PuzzleDifficulty(rows: r, cols: c, label: difficultyKey).tierIndex;
  }

  /// 由「各档位已完成关卡数」计算推荐档（doneByTier 长度 ≥ 5，按下标 0..7）。
  ///
  /// 先把各档完成数转成**后缀累计**（该档及以上合计），再从高到低取
  /// 首个达标的累计档位 + 1：只上推、不下降，封顶 [maxTierIndex]。
  /// 例如玩家只玩高难：L2=0、L3=5、L4=6 → L3 及以上累计 11 ≥ 10 → 推荐 4 档；
  /// 不至于因“没刷低档”而被卡在默认档。
  static int computeRecommendedTierIndex(List<int> doneByTier) {
    final len = RecommendRule.tierLevels.length;
    final cum = List<int>.filled(len, 0);
    var acc = 0;
    for (var i = len - 1; i >= 0; i--) {
      acc += i < doneByTier.length ? doneByTier[i] : 0;
      cum[i] = acc;
    }
    for (var t = maxTierIndex - 1; t >= minTierIndex; t--) {
      final need = promoteThresholds[t];
      if (need == null) continue;
      if (cum[t] >= need) return t + 1;
    }
    return defaultTierIndex;
  }
}

/// 推荐难度全局服务（2026-09-09 设计）
///
/// - **只在 app 启动后计算一次**（`main()` 组1 init 后调用 [ensureComputed]），
///   进程内恒定：玩家此后连续游玩再多的关卡也不重算，下次冷启动才刷新；
/// - 消费方（难度面板默认档 / 各关卡入口默认难度）一律同步读 [recommendedTierIndex]，
///   不再各自遍历进度现算。
class RecommendService {
  RecommendService._();
  static final RecommendService instance = RecommendService._();

  int _recommendedTierIndex = RecommendRule.defaultTierIndex;
  bool _computed = false;

  /// 全局推荐档位序（2~5），未计算时返回默认 2（L2）
  int get recommendedTierIndex => _recommendedTierIndex;

  /// 全局推荐档 tierLevel（'L2' ~ 'L5'）
  String get recommendedTierLevel =>
      RecommendRule.levelOf(_recommendedTierIndex);

  /// 是否已完成过统计
  bool get isComputed => _computed;

  /// app 启动后调用一次；幂等，进程内不会重算
  Future<void> ensureComputed() async {
    if (_computed) return;
    try {
      final all = await ProgressStore.instance.loadAllProgress();
      final done = List<int>.filled(RecommendRule.tierLevels.length, 0);
      for (final p in all.values) {
        for (final e in p.records.entries) {
          if (!e.value.isCompleted) continue;
          final t = RecommendRule.tierIndexOfKey(e.key);
          if (t >= 0 && t < done.length) done[t]++;
        }
      }
      _recommendedTierIndex = RecommendRule.computeRecommendedTierIndex(done);
    } catch (e, st) {
      AppLogger.system.warning(
        'RecommendService.ensureComputed failed, fallback to default',
        e,
        st,
      );
      _recommendedTierIndex = RecommendRule.defaultTierIndex;
    }
    _computed = true;
    AppLogger.system.info(
      'RecommendService computed tierIndex=$_recommendedTierIndex level=$recommendedTierLevel',
    );
  }

  /// 推荐档在该图片比例下对应的具体难度（tiers 中精确命中档位；
  /// 防御性回退：推荐档缺失时落该比例原 recommended 档，再落第一档）
  PuzzleDifficulty difficultyForAspect(PuzzleAspectRatio aspect) {
    final prefLevel = recommendedTierLevel;
    return aspect.tiers
        .firstWhere(
          (t) => t.tierLevel == prefLevel,
          orElse: () => aspect.tiers.firstWhere(
            (t) => t.difficulty.recommended,
            orElse: () => aspect.tiers.first,
          ),
        )
        .difficulty;
  }

  /// 图片比例未知时的安全默认（沿用 main/daily/pack 内容按 1:1 下发的假定）
  PuzzleDifficulty get squareDifficulty =>
      difficultyForAspect(PuzzleAspectRatio.square1x1);
}
