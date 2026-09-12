import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/resume_helper.dart';
import 'package:jigsawpuzzle/data/snapshot_store.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/content/models/canonical_id.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/pages/game_page.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';
import 'package:jigsawpuzzle/services/recommend_service.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:jigsawpuzzle/widgets/app_cached_image.dart';
import 'package:jigsawpuzzle/widgets/choose_difficulty_sheet.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DailyTabView extends StatefulWidget {
  const DailyTabView({super.key});

  @override
  State<DailyTabView> createState() => _DailyTabViewState();
}

class _DailyTabViewState extends State<DailyTabView> {
  static const String _keyDailyFoldPrefs = 'jigsaw_daily_fold_v1';
  final Set<String> _expandedMonthKeys = {};
  final Set<String> _loadingMonths = {};
  final Set<String> _failedMonths = {};

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final curMonth = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    _expandedMonthKeys.add(curMonth);
    unawaited(_loadFoldPrefs());
    AppContent.instance.contentUpdateNotifier.addListener(_onContentUpdate);
    LocaleService.instance.addListener(_onLocaleChanged);
    _ensureDailyIndexMetadata();
  }

  void _ensureDailyIndexMetadata() {
    if (!AppContent.instance.isInitialized) return;
    final manager = AppContent.instance.manager;
    if (manager.availableDailyMonths.isEmpty) {
      unawaited(
        manager.fetchDailyIndexMetadata().then((_) {
          if (mounted) {
            _cleanInvalidFoldPrefs();
            setState(() {});
          }
        }),
      );
    }
  }

  @override
  void dispose() {
    LocaleService.instance.removeListener(_onLocaleChanged);
    AppContent.instance.contentUpdateNotifier.removeListener(_onContentUpdate);
    super.dispose();
  }

  void _onLocaleChanged() {
    if (mounted) setState(() {});
  }

  void _onContentUpdate() {
    AppLogger.daily.info('DailyTabView: contentUpdateNotifier triggered');
    _cleanInvalidFoldPrefs();
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
    _cleanInvalidFoldPrefs();
    AppLogger.daily.info(
      'DailyTabView: Loaded fold preferences: $_expandedMonthKeys',
    );
    if (mounted) setState(() {});

    // 针对用户历史记录已展开的月份，若本地尚无关卡，按需异步触发下载
    for (final monthKey in _expandedMonthKeys) {
      final yyyyMm = monthKey.replaceAll('-', '');
      if (yyyyMm.length == 6) {
        unawaited(_ensureMonthDownloaded(yyyyMm));
      }
    }
  }

  void _cleanInvalidFoldPrefs() {
    final availableMonths = _getAvailableMonths();
    final availableKeys = availableMonths.map(_formatMonthKey).toSet();
    _expandedMonthKeys.removeWhere((k) => !availableKeys.contains(k));
  }

  Future<void> _toggleMonth(String monthKey) async {
    final isExpanding = !_expandedMonthKeys.contains(monthKey);
    setState(() {
      if (isExpanding) {
        _expandedMonthKeys.add(monthKey);
      } else {
        _expandedMonthKeys.remove(monthKey);
      }
    });
    AppLogger.daily.info(
      'DailyTabView: Month $monthKey ${isExpanding ? "expanded" : "collapsed"} (all expanded: $_expandedMonthKeys)',
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyDailyFoldPrefs, _expandedMonthKeys.toList());

    if (isExpanding) {
      final yyyyMm = monthKey.replaceAll('-', '');
      if (yyyyMm.length == 6) {
        unawaited(_ensureMonthDownloaded(yyyyMm));
      }
    }
  }

  /// 确保历史月份关卡资源下载就绪
  Future<void> _ensureMonthDownloaded(String yyyyMm) async {
    if (_loadingMonths.contains(yyyyMm)) {
      AppLogger.daily.info(
        'DailyTabView: Month $yyyyMm download already in progress, skipping duplicate trigger',
      );
      return;
    }

    final now = DateTime.now();
    if (_isFutureMonth(yyyyMm, now)) {
      AppLogger.daily.fine(
        'DailyTabView: Month $yyyyMm is in the future, skipping download',
      );
      return;
    }

    if (AppContent.instance.isInitialized) {
      final manager = AppContent.instance.manager;
      final existing = manager
          .getDailyLevelsForMonth(yyyyMm)
          .where((lvl) => !lvl.isTimeLocked)
          .toList();
      if (existing.isNotEmpty) {
        AppLogger.daily.info(
          'DailyTabView: Month $yyyyMm already ready with ${existing.length} levels, skipping download',
        );
        return;
      }

      // 关键防线：若远端 daily/index.json 中没有该月份，绝不触发下载，避免 404 与报错展示
      if (!manager.isDailyMonthAvailable(yyyyMm)) {
        AppLogger.daily.warning(
          'DailyTabView: Month $yyyyMm is not available in daily index, skipping download',
        );
        return;
      }
    }

    setState(() {
      _loadingMonths.add(yyyyMm);
      _failedMonths.remove(yyyyMm);
    });
    AppLogger.daily.info(
      'DailyTabView: Triggering on-demand download for month $yyyyMm...',
    );
    final sw = Stopwatch()..start();

    try {
      var success = false;
      if (AppContent.instance.isInitialized) {
        success = await AppContent.instance.manager.ensureDailyMonthReady(
          yyyyMm,
        );
      }
      AppLogger.daily.info(
        'DailyTabView: ensureDailyMonthReady for $yyyyMm completed in ${sw.elapsedMilliseconds}ms, success=$success',
      );
      if (!success) {
        _failedMonths.add(yyyyMm);
      }
      // best-effort：记录后降级继续
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      _failedMonths.add(yyyyMm);
      AppLogger.daily.severe(
        'DailyTabView: Error downloading month $yyyyMm',
        e,
        st,
      );
    } finally {
      if (mounted) {
        setState(() {
          _loadingMonths.remove(yyyyMm);
        });
      }
    }
  }

  /// 格式化 YYYYMM -> YYYY-MM
  String _formatMonthKey(String yyyyMm) {
    if (yyyyMm.length == 6) {
      return '${yyyyMm.substring(0, 4)}-${yyyyMm.substring(4, 6)}';
    }
    return yyyyMm;
  }

  /// 判断某月份字符串（如 202610 或 2026-10）是否为未到来的未来月份
  bool _isFutureMonth(String yyyyMm, DateTime now) {
    final clean = yyyyMm.replaceAll('-', '');
    if (clean.length < 6) return false;
    final year = int.tryParse(clean.substring(0, 4)) ?? 0;
    final month = int.tryParse(clean.substring(4, 6)) ?? 0;
    if (year <= 0 || month < 1 || month > 12) return false;
    return DateTime(year, month).isAfter(DateTime(now.year, now.month));
  }

  /// 获取所有可用月份列表 (降序排列)
  ///
  /// 严格以权威数据源为准，杜绝盲目推断不存在的历史月份：
  /// 1. 远端 daily/index.json 中声明的有效月份 (availableDailyMonths)
  /// 2. 本地已存在且关卡文件非空的有效历史月份 (过滤空目录残留)
  /// 3. 若远端索引未拉取且本地无历史数据，仅以 manifest 的 currentMonth 或当月作为最小兜底展示
  /// 4. 严格过滤：未到达的未来月份一律不展示 (即便远端提前发布，也绝不对用户展示)
  List<String> _getAvailableMonths() {
    final monthSet = <String>{};

    if (AppContent.instance.isInitialized) {
      final manager = AppContent.instance.manager;

      // 1. 权威远端每日索引声明的所有月份
      monthSet.addAll(manager.availableDailyMonths);

      // 2. 本地已解压且关卡有效非空的历史月份 (由管线统一负责探测与过滤空目录)
      monthSet.addAll(manager.localReadyDailyMonths);

      // 3. 极端冷启动兜底：若远端索引尚未返回且本地无任何月份，仅允许当前配置的 currentMonth
      if (monthSet.isEmpty) {
        final manifestMonth = manager.currentManifest?.dailyModule.currentMonth;
        if (manifestMonth != null && manifestMonth.isNotEmpty) {
          monthSet.add(manifestMonth);
        }
      }
    }

    // 4. 极端保底（AppContent 未初始化或全为空时，仅保留当月单个月份，绝不臆造历史月份）
    final now = DateTime.now();
    if (monthSet.isEmpty) {
      final nowMm = '${now.year}${now.month.toString().padLeft(2, '0')}';
      monthSet.add(nowMm);
    }

    // 5. 严格剔除未到来的未来月份
    final list = monthSet.where((m) => !_isFutureMonth(m, now)).toList()
      ..sort((a, b) => b.compareTo(a));
    return list;
  }

  int _extractDayNumber(String? dailyDate) {
    if (dailyDate == null || dailyDate.length < 8) return 1;
    return int.tryParse(dailyDate.substring(6, 8)) ?? 1;
  }

  String _formatDailyDateDisplay(String? dailyDate) {
    if (dailyDate == null || dailyDate.length < 8) return t.daily.todayFallback;
    final m = int.tryParse(dailyDate.substring(4, 6)) ?? 1;
    final d = int.tryParse(dailyDate.substring(6, 8)) ?? 1;
    return t.daily.dateChallenge(month: m, day: d);
  }

  Future<void> _openDaily(PuzzleLevelItem level) async {
    AppLogger.daily.info(
      'DailyTabView: _openDaily level=${level.id} date=${level.dailyDate} isLocked=${level.isTimeLocked} localPath=${level.localPath}',
    );
    if (level.isTimeLocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t.daily.notUnlocked),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    Uint8List imgBytes;
    try {
      if (level.localPath != null && File(level.localPath!).existsSync()) {
        imgBytes = await File(level.localPath!).readAsBytes();
      } else {
        AppLogger.daily.warning(
          'Daily level file does not exist: ${level.localPath}',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                t.daily.loadMonthFailed(month: level.dailyDate ?? ''),
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        return;
      }
      // best-effort：记录后降级继续
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      AppLogger.daily.severe('Failed to read daily level file bytes', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t.daily.loadMonthFailed(month: level.dailyDate ?? ''),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    if (!mounted) return;

    final canonicalId = level.id;
    final progress = ProgressStore.instance.getLevelProgress(canonicalId);
    // 默认难度 = 全局推荐档（按 1:1 假定，面板解码后按实际比例校正）
    final fallbackDifficulty = RecommendService.instance.squareDifficulty;
    final title = _formatDailyDateDisplay(level.dailyDate);

    final handled = await ResumeHelper.tryHandleResumeFlow(
      context: context,
      canonicalId: canonicalId,
      fallbackDifficulty: fallbackDifficulty,
      title: title,
      imageBytes: imgBytes,
      onClearRepo: (k) => GameRepository.instance.updateGenericProgress(
        canonicalId: canonicalId,
        progressPercent: 0,
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
      isCompleted: progress.isCompleted,
    );
    if (!mounted) return;

    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: fallbackDifficulty,
      completedPieceCounts: progress.completedPieceCounts.toSet(),
      canonicalId: canonicalId,
      title: title,
      imagePathOrUrl: level.displayPath,
      savedProgressPercent: displayPercent == 0 ? null : displayPercent,
      onResetProgress: () async {
        final prog = await ResumeHelper.loadProgress(canonicalId);
        if (prog.activeDifficultyKey.isNotEmpty) {
          await ResumeHelper.clearResume(canonicalId, prog.activeDifficultyKey);
        }
        await GameRepository.instance.updateGenericProgress(
          canonicalId: canonicalId,
          progressPercent: 0,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes,
              difficulty: fallbackDifficulty,
              canonicalId: canonicalId,
              dailyDateStr: level.dailyDate,
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
    final monthGroups = <String, List<PuzzleLevelItem>>{};

    PuzzleLevelItem? dailyBannerItem;
    if (AppContent.instance.isInitialized) {
      dailyBannerItem = AppContent.instance.manager.getDailyBannerLevel();
    }

    var totalCompletedCount = 0;
    var totalVisibleCount = 0;

    for (final monthMm in availableMonths) {
      final monthKey = _formatMonthKey(monthMm);
      var levels = <PuzzleLevelItem>[];
      if (AppContent.instance.isInitialized) {
        levels = AppContent.instance.manager
            .getDailyLevelsForMonth(monthMm)
            .where((lvl) => !lvl.isTimeLocked)
            .toList();
        // 每月挑战倒序排列：最新的日期在最前面
        levels.sort((a, b) => (b.dailyDate ?? '').compareTo(a.dailyDate ?? ''));
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
    AppLogger.daily.info(
      'DailyTabView: build availableMonths=$availableMonths, expanded=$_expandedMonthKeys, loading=$_loadingMonths, levels={${monthGroups.entries.map((e) => '${e.key}:${e.value.length}').join(', ')}}',
    );

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
          // Today's Challenge Banner (当且仅当存在今日关卡或本地历史推导关卡时展示)
          if (dailyBannerItem != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Container(
                  decoration: BoxDecoration(
                    color: palette.surfaceContainer,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: palette.brand.withValues(alpha: 0.2),
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
                                  Expanded(
                                    child: Text(
                                      t.daily.dateCaption(
                                        month: now.month,
                                        day: now.day,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: styles.caption.copyWith(
                                        color: palette.secondaryText,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                t.daily.todayTitle(
                                  month: now.month,
                                  day: now.day,
                                ),
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
                                      .getLevelProgress(dailyBannerItem!.id);
                                  return FilledButton.icon(
                                    onPressed: () =>
                                        _openDaily(dailyBannerItem!),
                                    icon: Icon(
                                      prog.isCompleted
                                          ? PhosphorIconsBold.arrowsClockwise
                                          : PhosphorIconsFill.play,
                                      size: 18,
                                    ),
                                    label: Text(
                                      prog.isCompleted
                                          ? t.daily.btnClearedReplay
                                          : (prog.progressPercent > 0
                                                ? t.daily.btnResume
                                                : t.daily.btnStart),
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
                              imagePathOrUrl: dailyBannerItem.displayPath,
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
                  border: Border.all(color: palette.divider),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Icon(
                            PhosphorIconsFill.trophy,
                            color: palette.brand,
                            size: 20,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              totalVisibleCount > 0
                                  ? t.daily.totalProgress(
                                      done: totalCompletedCount,
                                      total: totalVisibleCount,
                                    )
                                  : t.daily.todayFallback,
                              style: styles.bodyBold,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
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
                            t.daily.streakDays(count: streak),
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
          for (final entry in monthGroups.entries)
            ..._buildMonthSection(
              monthKey: entry.key,
              levels: entry.value,
              palette: palette,
              styles: styles,
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  List<Widget> _buildMonthSection({
    required String monthKey,
    required List<PuzzleLevelItem> levels,
    required AppPalette palette,
    required AppTextStyles styles,
  }) {
    final yyyyMm = monthKey.replaceAll('-', '');
    final isLoading = _loadingMonths.contains(yyyyMm);
    final isFailed = _failedMonths.contains(yyyyMm);
    final isExpanded = _expandedMonthKeys.contains(monthKey);

    return [
      SliverToBoxAdapter(
        child: _buildMonthHeader(
          monthKey,
          levels,
          palette,
          styles,
          isExpanded: isExpanded,
          isLoading: isLoading,
          onToggle: () => _toggleMonth(monthKey),
        ),
      ),
      if (isExpanded) ...[
        if (isLoading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 36),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: palette.brand,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      t.daily.loadingMonth(month: monthKey),
                      style: TextStyle(
                        color: palette.secondaryText,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (levels.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isFailed
                          ? t.daily.loadMonthFailed(month: monthKey)
                          : t.daily.emptyMonth(month: monthKey),
                      style: TextStyle(
                        color: palette.secondaryText,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 10),
                    FilledButton.tonalIcon(
                      onPressed: () => _ensureMonthDownloaded(yyyyMm),
                      icon: const Icon(
                        PhosphorIconsBold.downloadSimple,
                        size: 16,
                      ),
                      label: Text(t.daily.downloadMonth),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = levels[index];
                return _buildDailyCard(item, palette, styles);
              }, childCount: levels.length),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    ];
  }

  Widget _buildMonthHeader(
    String monthKey,
    List<PuzzleLevelItem> monthItems,
    AppPalette palette,
    AppTextStyles styles, {
    required bool isExpanded,
    required VoidCallback onToggle,
    bool isLoading = false,
  }) {
    final parts = monthKey.split('-');
    final year = parts.isNotEmpty ? parts[0] : '';
    final month = parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : 1;
    final headerTitle = t.daily.monthTitle(month: month, year: year);

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
                if (isLoading)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: palette.brand,
                      ),
                    ),
                  )
                else if (monthItems.isNotEmpty)
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
                      t.daily.monthCompleted(
                        done: completedCount,
                        total: monthItems.length,
                      ),
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
    final isNew = item.isNew && !progress.isCompleted;

    return InkWell(
      onTap: () => _openDaily(item),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: palette.divider),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AppCachedImage(
              imagePathOrUrl: item.displayPath,
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
            if (isNew)
              Positioned(
                bottom: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFC97A2E),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'New',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      fontStyle: FontStyle.italic,
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
