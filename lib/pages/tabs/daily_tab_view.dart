import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/game_repository.dart';
import '../../data/progress_store.dart';
import '../../data/resume_helper.dart';
import '../../data/snapshot_store.dart';
import '../../logic/content/app_content.dart';
import '../../logic/content/models/canonical_id.dart';
import '../../logic/content/models/puzzle_level_item.dart';
import '../../logic/image_source.dart';
import '../../logic/puzzle_model.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_text_styles.dart';
import '../../widgets/app_cached_image.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../game_page.dart';

class DailyTabView extends StatefulWidget {
  const DailyTabView({super.key});

  @override
  State<DailyTabView> createState() => _DailyTabViewState();
}

class _DailyTabViewState extends State<DailyTabView> {
  static const String _keyDailyFoldPrefs = 'jigsaw_daily_fold_v1';
  final Set<String> _expandedMonthKeys = {};

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final curMonth = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    _expandedMonthKeys.add(curMonth);
    _loadFoldPrefs();
    AppContent.instance.contentUpdateNotifier.addListener(_onContentUpdate);
  }

  @override
  void dispose() {
    AppContent.instance.contentUpdateNotifier.removeListener(_onContentUpdate);
    super.dispose();
  }

  void _onContentUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _loadFoldPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_keyDailyFoldPrefs);
    final now = DateTime.now();
    final curMonth = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    if (saved != null && saved.isNotEmpty) {
      _expandedMonthKeys
        ..clear()
        ..addAll(saved);
    } else {
      _expandedMonthKeys
        ..clear()
        ..add(curMonth);
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleMonth(String monthKey) async {
    setState(() {
      if (_expandedMonthKeys.contains(monthKey)) {
        _expandedMonthKeys.remove(monthKey);
      } else {
        _expandedMonthKeys.add(monthKey);
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyDailyFoldPrefs, _expandedMonthKeys.toList());
  }

  /// 格式化 YYYYMM -> YYYY-MM
  String _formatMonthKey(String yyyyMm) {
    if (yyyyMm.length == 6) {
      return '${yyyyMm.substring(0, 4)}-${yyyyMm.substring(4, 6)}';
    }
    return yyyyMm;
  }

  /// 获取所有可用月份列表 (降序排列)
  List<String> _getAvailableMonths() {
    final now = DateTime.now();
    final nowMm = '${now.year}${now.month.toString().padLeft(2, '0')}';
    final monthSet = <String>{nowMm};
    // 默认展示近3个月（当月及前2个月）
    for (var i = 1; i <= 2; i++) {
      final prevDate = DateTime(now.year, now.month - i, 1);
      final prevMm =
          '${prevDate.year}${prevDate.month.toString().padLeft(2, '0')}';
      monthSet.add(prevMm);
    }

    if (AppContent.instance.isInitialized) {
      final pipeline = AppContent.instance.manager.dailyPipeline;
      final baseDir = Directory(pipeline.dailyStorageBaseDir);
      if (baseDir.existsSync()) {
        try {
          for (final entity in baseDir.listSync()) {
            if (entity is Directory) {
              final name = p.basename(entity.path);
              if (RegExp(r'^\d{6}$').hasMatch(name)) {
                monthSet.add(name);
              }
            }
          }
        } catch (_) {}
      }

      final manifestMonth =
          AppContent.instance.manager.currentManifest?.dailyModule.currentMonth;
      if (manifestMonth != null && manifestMonth.isNotEmpty) {
        monthSet.add(manifestMonth);
      }
    }

    final list = monthSet.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }

  int _extractDayNumber(String? dailyDate) {
    if (dailyDate == null || dailyDate.length < 8) return 1;
    return int.tryParse(dailyDate.substring(6, 8)) ?? 1;
  }

  String _formatDailyDateDisplay(String? dailyDate) {
    if (dailyDate == null || dailyDate.length < 8) return '今日挑战';
    final m = int.tryParse(dailyDate.substring(4, 6)) ?? 1;
    final d = int.tryParse(dailyDate.substring(6, 8)) ?? 1;
    return '$m月$d日 挑战';
  }

  Future<void> _openDaily(PuzzleLevelItem level) async {
    if (level.isTimeLocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⏳ 未到解锁时间，敬请期待！'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    Uint8List imgBytes;
    try {
      final file = File(level.imagePathOrUrl);
      if (await file.exists()) {
        imgBytes = await file.readAsBytes();
      } else {
        final bytes = await rootBundle.load(assetSamples[0]);
        imgBytes = bytes.buffer.asUint8List();
      }
    } catch (_) {
      final bytes = await rootBundle.load(assetSamples[0]);
      imgBytes = bytes.buffer.asUint8List();
    }
    if (!mounted) return;

    final canonicalId = level.id;
    final progress = ProgressStore.instance.getLevelProgress(canonicalId);
    final fallbackDifficulty = PuzzleAspectRatio.square1x1.tiers
        .firstWhere((t) => t.difficulty.recommended)
        .difficulty;
    final title = _formatDailyDateDisplay(level.dailyDate);

    final handled = await ResumeHelper.tryHandleResumeFlow(
      context: context,
      canonicalId: canonicalId,
      fallbackDifficulty: fallbackDifficulty,
      isCompleted: progress.isCompleted,
      title: title,
      imageBytes: imgBytes,
      onClearRepo: (k) => GameRepository.instance.updateGenericProgress(
        canonicalId: canonicalId,
        progressPercent: 0,
        snapshotJson: null,
      ),
      onPushGame: (diff, jsonStr) async {
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes,
              difficulty: diff,
              canonicalId: canonicalId,
              dailyDateStr: level.dailyDate,
              initialSnapshotJson: jsonStr,
            ),
          ),
        );
      },
      onCancelled: () {
        if (mounted) setState(() {});
      },
    );
    if (handled) {
      if (mounted) setState(() {});
      return;
    }
    if (!mounted) return;

    final displayPercent = ResumeHelper.displayProgress(
      progress,
      progress.progressPercent,
      progress.isCompleted,
    );
    if (!mounted) return;

    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: fallbackDifficulty,
      completedPieceCounts: progress.completedPieceCounts.toSet(),
      canonicalId: canonicalId,
      title: title,
      imagePathOrUrl: level.imagePathOrUrl,
      savedProgressPercent: displayPercent == 0 ? null : displayPercent,
      onResetProgress: () async {
        final prog = await ResumeHelper.loadProgress(canonicalId);
        if (prog.activeDifficultyKey.isNotEmpty) {
          await ResumeHelper.clearResume(canonicalId, prog.activeDifficultyKey);
        }
        await GameRepository.instance.updateGenericProgress(
          canonicalId: canonicalId,
          progressPercent: 0,
          snapshotJson: null,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes,
              difficulty: fallbackDifficulty,
              canonicalId: canonicalId,
              dailyDateStr: level.dailyDate,
              initialSnapshotJson: null,
            ),
          ),
        );
        setState(() {});
      },
      onStart: (diff) async {
        final dkey = SnapshotStore.difficultyKeyFor(diff);
        final snapJson = await SnapshotStore.instance.loadJsonString(
          canonicalId,
          dkey,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes,
              difficulty: diff,
              canonicalId: canonicalId,
              dailyDateStr: level.dailyDate,
              initialSnapshotJson: snapJson,
            ),
          ),
        );
        setState(() {});
      },
    );
  }

  int _calculateStreak() {
    var streak = 0;
    final now = DateTime.now();
    for (var offset = 0; offset < 365; offset++) {
      final date = now.subtract(Duration(days: offset));
      final dateStr =
          '${date.year.toString().padLeft(4, '0')}'
          '${date.month.toString().padLeft(2, '0')}'
          '${date.day.toString().padLeft(2, '0')}';
      final cid = CanonicalId.forDaily(dateStr);
      final prog = ProgressStore.instance.getLevelProgress(cid);
      if (prog.isCompleted) {
        streak++;
      } else if (offset > 0) {
        break;
      }
    }
    return streak;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final now = DateTime.now();

    final availableMonths = _getAvailableMonths();
    final Map<String, List<PuzzleLevelItem>> monthGroups = {};

    PuzzleLevelItem? todayItem;
    if (AppContent.instance.isInitialized) {
      todayItem = AppContent.instance.manager.getTodayDailyLevel();
    }
    final todayStr =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final effectiveTodayItem =
        todayItem ??
        PuzzleLevelItem(
          id: CanonicalId.forDaily(todayStr),
          dailyDate: todayStr,
          imagePathOrUrl: assetSamples[0],
          isLocalFile: true,
          isTimeLocked: false,
        );

    var totalCompletedCount = 0;
    var totalVisibleCount = 0;

    for (final monthMm in availableMonths) {
      final monthKey = _formatMonthKey(monthMm);
      List<PuzzleLevelItem> levels = [];
      if (AppContent.instance.isInitialized) {
        levels = AppContent.instance.manager
            .getDailyLevelsForMonth(monthMm)
            .where((lvl) => !lvl.isTimeLocked)
            .toList();
      }
      monthGroups[monthKey] = levels;

      for (final lvl in levels) {
        totalVisibleCount++;
        if (ProgressStore.instance.getLevelProgress(lvl.id).isCompleted) {
          totalCompletedCount++;
        }
      }
    }

    final streak = _calculateStreak();

    return RefreshIndicator(
      onRefresh: () async {
        if (AppContent.instance.isInitialized) {
          await AppContent.instance.syncAll();
        }
        if (mounted) setState(() {});
      },
      color: palette.brand,
      child: CustomScrollView(
        slivers: [
          // Today's Challenge Banner
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Container(
                decoration: BoxDecoration(
                  color: palette.surfaceContainer,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: palette.brand.withValues(alpha: 0.2),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: palette.brand.withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: palette.brand.withValues(
                                      alpha: 0.12,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'TODAY',
                                    style: TextStyle(
                                      color: palette.brand,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${now.month} 月 ${now.day} 日',
                                  style: styles.caption.copyWith(
                                    color: palette.secondaryText,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${now.month}月${now.day}日 · 今日挑战',
                              style: styles.h2.copyWith(
                                color: palette.primaryText,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 14),
                            Builder(
                              builder: (context) {
                                final prog = ProgressStore.instance
                                    .getLevelProgress(effectiveTodayItem.id);
                                return FilledButton.icon(
                                  onPressed: () =>
                                      _openDaily(effectiveTodayItem),
                                  icon: Icon(
                                    prog.isCompleted
                                        ? PhosphorIconsBold.arrowsClockwise
                                        : PhosphorIconsFill.play,
                                    size: 18,
                                  ),
                                  label: Text(
                                    prog.isCompleted
                                        ? '已通关 (重玩)'
                                        : (prog.progressPercent > 0
                                              ? '继续挑战'
                                              : '开始挑战'),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: palette.brand,
                                    foregroundColor: palette.surface,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 18,
                                      vertical: 8,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(
                          width: 130,
                          height: 120,
                          child: AppCachedImage(
                            imagePathOrUrl: effectiveTodayItem.imagePathOrUrl,
                            fit: BoxFit.cover,
                            errorWidget: Image.asset(
                              assetSamples[0],
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Stats Bar
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: palette.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: palette.divider, width: 1),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          PhosphorIconsFill.trophy,
                          color: palette.brand,
                          size: 20,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          totalVisibleCount > 0
                              ? '每日总进度: $totalCompletedCount/$totalVisibleCount'
                              : '每日挑战',
                          style: styles.bodyBold,
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: palette.warning.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            PhosphorIconsFill.fire,
                            color: palette.warning,
                            size: 16,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '连胜 $streak 天',
                            style: TextStyle(
                              color: palette.warning,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),

          // Monthly Grids
          for (final entry in monthGroups.entries) ...[
            SliverToBoxAdapter(
              child: _buildMonthHeader(
                entry.key,
                entry.value,
                palette,
                styles,
                isExpanded: _expandedMonthKeys.contains(entry.key),
                onToggle: () => _toggleMonth(entry.key),
              ),
            ),
            if (_expandedMonthKeys.contains(entry.key)) ...[
              if (entry.value.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        '暂无当月挑战关卡',
                        style: TextStyle(
                          color: palette.secondaryText,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 14,
                          childAspectRatio: 1.0,
                        ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final item = entry.value[index];
                      return _buildDailyCard(item, palette, styles);
                    }, childCount: entry.value.length),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
            ],
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  Widget _buildMonthHeader(
    String monthKey,
    List<PuzzleLevelItem> monthItems,
    AppPalette palette,
    AppTextStyles styles, {
    required bool isExpanded,
    required VoidCallback onToggle,
  }) {
    final parts = monthKey.split('-');
    final year = parts.isNotEmpty ? parts[0] : '';
    final month = parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : 1;
    final headerTitle = '$year年$month月';

    var completedCount = 0;
    for (final item in monthItems) {
      if (ProgressStore.instance.getLevelProgress(item.id).isCompleted) {
        completedCount++;
      }
    }

    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 16,
                  decoration: BoxDecoration(
                    color: palette.brand,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(headerTitle, style: styles.h3.copyWith(fontSize: 16)),
              ],
            ),
            Row(
              children: [
                if (monthItems.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: palette.surfaceContainer,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: palette.divider, width: 0.8),
                    ),
                    child: Text(
                      '已完成 $completedCount/${monthItems.length}',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: palette.secondaryText,
                      ),
                    ),
                  ),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: isExpanded ? 0 : 0.5,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    PhosphorIconsBold.caretUp,
                    size: 16,
                    color: palette.secondaryText,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDailyCard(
    PuzzleLevelItem item,
    AppPalette palette,
    AppTextStyles styles,
  ) {
    final progress = ProgressStore.instance.getLevelProgress(item.id);
    final dayNumber = _extractDayNumber(item.dailyDate);

    return InkWell(
      onTap: () => _openDaily(item),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: palette.divider, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AppCachedImage(
              imagePathOrUrl: item.imagePathOrUrl,
              fit: BoxFit.cover,
              errorWidget: Image.asset(assetSamples[0], fit: BoxFit.cover),
            ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.35),
                    Colors.transparent,
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                ),
              ),
            ),
            Positioned(
              top: 10,
              left: 10,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: palette.surface.withValues(alpha: 0.94),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '$dayNumber',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: palette.primaryText,
                  ),
                ),
              ),
            ),
            if (progress.isCompleted)
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: palette.success,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    PhosphorIconsBold.check,
                    color: palette.surface,
                    size: 14,
                  ),
                ),
              )
            else if (progress.progressPercent > 0)
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: palette.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${progress.progressPercent}%',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: palette.brand,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
