import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/game_repository.dart';
import '../data/progress_store.dart';
import '../services/achievement_service.dart';
import '../services/achievement_store.dart';
import '../services/economy_service.dart';
import '../services/sound_service.dart';
import '../theme/app_palette.dart';
import '../theme/app_text_styles.dart';
import '../widgets/game_toast.dart';

/// 全屏成就勋章与游戏数据统计页面（品牌化重设计）
class AchievementsPage extends StatefulWidget {
  const AchievementsPage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AchievementsPage()));
  }

  @override
  State<AchievementsPage> createState() => _AchievementsPageState();
}

class _AchievementsPageState extends State<AchievementsPage> {
  final _repo = GameRepository.instance;
  final _store = AchievementStore.instance;
  final _eco = EconomyService.instance;
  final _achService = AchievementService.instance;

  StreamSubscription<AchievementDefinition>? _unlockSub;
  int _distinct3Star = 0;
  int _totalStars = 0;
  int _totalSolved = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAsyncStats();
    _unlockSub = _achService.onAchievementUnlocked.listen((_) {
      if (mounted) _loadAsyncStats();
    });
  }

  @override
  void dispose() {
    _unlockSub?.cancel();
    super.dispose();
  }

  Future<void> _loadAsyncStats() async {
    await ProgressStore.instance.init();
    await _store.init();
    await _eco.init();

    final d3 = await ProgressStore.instance.getDistinctImagesWith3Star();
    final ts = await ProgressStore.instance.getTotalStars();
    final sv = await ProgressStore.instance.getTotalSolved();

    if (mounted) {
      setState(() {
        _distinct3Star = d3;
        _totalStars = ts > 0
            ? ts
            : _repo.levels.fold<int>(0, (sum, l) => sum + l.stars);
        _totalSolved = sv;
        _loading = false;
      });
    }
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m < 60) return '$m 分 $s 秒';
    final h = m ~/ 60;
    final remM = m % 60;
    return '$h 小时 $remM 分';
  }

  Future<void> _claimReward(AchievementDefinition def) async {
    final ok = await _achService.claimReward(def.id);
    if (ok && mounted) {
      SoundService.I.play(Sfx.coinsFly);
      GameToast.show(
        context,
        icon: Icons.monetization_on,
        message: '成功领取成就奖励：+${def.coinReward} 金币！',
        type: GameToastType.success,
      );
      _loadAsyncStats();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final completed = _totalSolved;
    final snapped = _repo.totalPiecesSnapped;
    final timeSec = _repo.totalPlayTimeSeconds;
    final coins = _eco.coins;

    final allDefs = AchievementService.allAchievements;
    final unlockedCount = allDefs.where((a) => _store.isUnlocked(a.id)).length;

    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(
        backgroundColor: palette.surface,
        foregroundColor: palette.primaryText,
        elevation: 0.5,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PhosphorIconsFill.trophy, color: palette.brand, size: 24),
            const SizedBox(width: 8),
            Text('成就与统计', style: styles.h3.copyWith(fontSize: 19)),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: palette.brand.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: palette.brand.withValues(alpha: 0.35)),
            ),
            child: Text(
              '$unlockedCount / ${allDefs.length} 已解锁',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: palette.brand,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            children: [
              // Section header
              _SectionHeader(title: '数据统计看板', palette: palette, styles: styles),
              const SizedBox(height: 10),

              // Stats Grid
              LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= 500;
                  final crossAxisCount = isWide ? 3 : 2;
                  return GridView.count(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: isWide ? 1.9 : 1.6,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      _StatCard(
                        label: '关卡累积星星',
                        value: '$_totalStars',
                        icon: PhosphorIconsFill.star,
                        color: palette.gold,
                        palette: palette,
                        styles: styles,
                      ),
                      _StatCard(
                        label: '3星拼图数',
                        value: '$_distinct3Star 张',
                        icon: PhosphorIconsFill.trophy,
                        color: palette.brand,
                        palette: palette,
                        styles: styles,
                      ),
                      _StatCard(
                        label: '已通关图数',
                        value: '$completed 张',
                        icon: PhosphorIconsBold.checkCircle,
                        color: palette.success,
                        palette: palette,
                        styles: styles,
                      ),
                      _StatCard(
                        label: '拥有金币',
                        value: '$coins',
                        icon: PhosphorIconsFill.coins,
                        color: palette.gold,
                        palette: palette,
                        styles: styles,
                      ),
                      _StatCard(
                        label: '已拼碎片',
                        value: '$snapped',
                        icon: PhosphorIconsFill.puzzlePiece,
                        color: palette.info,
                        palette: palette,
                        styles: styles,
                      ),
                      _StatCard(
                        label: '总游玩时长',
                        value: _formatDuration(timeSec),
                        icon: PhosphorIconsBold.timer,
                        color: const Color(0xFFA56BC0),
                        palette: palette,
                        styles: styles,
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 24),

              // Achievements section header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _SectionHeader(
                    title: '成就勋章墙',
                    palette: palette,
                    styles: styles,
                  ),
                  Text('共 ${allDefs.length} 项成就', style: styles.caption),
                ],
              ),
              const SizedBox(height: 12),

              // Achievements list
              if (_loading)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: CircularProgressIndicator(color: palette.brand),
                  ),
                )
              else
                for (final def in allDefs) ...[
                  _AchievementCard(
                    def: def,
                    store: _store,
                    palette: palette,
                    styles: styles,
                    onClaim: () => _claimReward(def),
                  ),
                  const SizedBox(height: 10),
                ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Section Header ──────────────────────────
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.palette,
    required this.styles,
  });
  final String title;
  final AppPalette palette;
  final AppTextStyles styles;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: styles.captionBold.copyWith(
        color: palette.secondaryText,
        letterSpacing: 0.5,
      ),
    );
  }
}

// ── Stat Card ───────────────────────────────
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.palette,
    required this.styles,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final AppPalette palette;
  final AppTextStyles styles;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color: palette.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: styles.monoSmall.copyWith(color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ── Achievement Card ──────────────────────
class _AchievementCard extends StatelessWidget {
  const _AchievementCard({
    required this.def,
    required this.store,
    required this.palette,
    required this.styles,
    required this.onClaim,
  });

  final AchievementDefinition def;
  final AchievementStore store;
  final AppPalette palette;
  final AppTextStyles styles;
  final VoidCallback onClaim;

  @override
  Widget build(BuildContext context) {
    final isUnlocked = store.isUnlocked(def.id);
    final isClaimed = store.isClaimed(def.id);
    final current = def.type == AchievementType.derived
        ? (AchievementService.allAchievements
              .where((a) => a.id != 'master_all' && store.isUnlocked(a.id))
              .length)
        : store.getCounter(def.metricKey);
    final progress = (current / def.target).clamp(0.0, 1.0);

    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isUnlocked
              ? (isClaimed
                    ? palette.success.withValues(alpha: 0.3)
                    : palette.brand.withValues(alpha: 0.4))
              : palette.divider,
          width: isUnlocked ? 1.4 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            // Icon
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isUnlocked
                    ? palette.brand.withValues(alpha: 0.12)
                    : palette.divider.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: isUnlocked
                  ? Icon(
                      PhosphorIconsFill.trophy,
                      color: palette.brand,
                      size: 24,
                    )
                  : Icon(
                      PhosphorIconsFill.lockKey,
                      color: palette.disabledText,
                      size: 20,
                    ),
            ),
            const SizedBox(width: 14),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        def.title,
                        style: styles.bodyBold.copyWith(
                          color: isUnlocked
                              ? palette.primaryText
                              : palette.disabledText,
                        ),
                      ),
                      if (isUnlocked)
                        isClaimed
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    PhosphorIconsFill.checkCircle,
                                    color: palette.success,
                                    size: 15,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    '已领取',
                                    style: styles.captionBold.copyWith(
                                      color: palette.success,
                                    ),
                                  ),
                                ],
                              )
                            : GestureDetector(
                                onTap: onClaim,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: AppPalette.brandGradient,
                                    borderRadius: BorderRadius.circular(10),
                                    boxShadow: [
                                      BoxShadow(
                                        color: palette.brand.withValues(
                                          alpha: 0.25,
                                        ),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Text(
                                    '领 +${def.coinReward} 🪙',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: palette.surface,
                                    ),
                                  ),
                                ),
                              )
                      else
                        Text(
                          def.metricKey == 'play_seconds'
                              ? '${(current ~/ 60)}/${(def.target ~/ 60)}分'
                              : '$current/${def.target}',
                          style: styles.caption.copyWith(
                            color: palette.disabledText,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(def.description, style: styles.caption),
                  if (!isUnlocked) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 5,
                        backgroundColor: palette.divider,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          palette.success,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${(progress * 100).toInt()}%',
                      style: styles.caption.copyWith(
                        fontSize: 10,
                        color: palette.secondaryText,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
