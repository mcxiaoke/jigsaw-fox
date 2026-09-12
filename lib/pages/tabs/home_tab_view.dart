import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jigsawpuzzle/data/constants/puzzle_tags.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/resume_helper.dart';
import 'package:jigsawpuzzle/data/snapshot_store.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/cache/level_image_resolver.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/pages/event_levels_page.dart';
import 'package:jigsawpuzzle/pages/game_page.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';
import 'package:jigsawpuzzle/services/recommend_service.dart';
import 'package:jigsawpuzzle/services/sound_service.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:jigsawpuzzle/utils/locale_helper.dart';
import 'package:jigsawpuzzle/widgets/adaptive_hero_banner.dart';
import 'package:jigsawpuzzle/widgets/choose_difficulty_sheet.dart';
import 'package:jigsawpuzzle/widgets/download_badge.dart';
import 'package:jigsawpuzzle/widgets/game_toast.dart';
import 'package:jigsawpuzzle/widgets/lazy_level_image.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

class HomeTabView extends StatefulWidget {
  const HomeTabView({required this.onSwitchToDaily, super.key});

  final VoidCallback onSwitchToDaily;

  @override
  State<HomeTabView> createState() => _HomeTabViewState();
}

class _HomeTabViewState extends State<HomeTabView> {
  String _selectedTag = 'all';
  final ScrollController _scrollController = ScrollController();
  final ScrollController _tagScrollController = ScrollController();
  final Map<String, GlobalKey> _tagKeys = {
    for (final t in kHomeTags) t['id']!: GlobalKey(),
  };

  @override
  void initState() {
    super.initState();
    LocaleService.instance.addListener(_onLocaleChanged);
    // 网络内容（新批次/换图）与玩家进度（通关返回）变化时刷新网格
    AppContent.instance.contentUpdateNotifier.addListener(_onContentChanged);
    ProgressStore.instance.progressNotifier.addListener(_onContentChanged);
  }

  void _onContentChanged() {
    if (mounted) setState(() {});
  }

  void _onLocaleChanged() {
    if (mounted) setState(() {});
  }

  /// 首页关卡数据源：网络 main 模块（manifest → main/index + batches 懒同步）
  /// BootGate 已保证进入本页时 AppContent 初始化完成；未初始化（测试等）返回空。
  List<PuzzleLevelItem> _getLevels() {
    if (!AppContent.instance.isInitialized) return const [];
    return AppContent.instance.manager.getMainLevels();
  }

  List<PuzzleLevelItem> _getFilteredLevels(List<PuzzleLevelItem> all) {
    if (_selectedTag == 'all') return all;
    final selLower = _selectedTag.toLowerCase();
    return all.where((l) {
      // 网络关卡无 tags 时归入 Others 兜底分类
      final tags = l.tags.isEmpty ? const ['Others'] : l.tags;
      return tags.any((t) {
        final tLower = t.toLowerCase();
        if (tLower == selLower) return true;
        final mappedEn = kTagZhToId[t]?.toLowerCase();
        if (mappedEn != null && mappedEn == selLower) return true;
        final mappedZh = kTagIdToZh[t]?.toLowerCase();
        if (mappedZh != null && mappedZh == selLower) return true;
        return false;
      });
    }).toList();
  }

  void _onTagSelected(String tag) {
    if (_selectedTag == tag) return;
    setState(() => _selectedTag = tag);
    // 过滤后回顶
    if (_scrollController.hasClients) {
      unawaited(
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        ),
      );
    }
    // 横滑 Tag 栏滚动到选中项可见
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _tagKeys[tag];
      if (key?.currentContext != null) {
        unawaited(
          Scrollable.ensureVisible(
            key!.currentContext!,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            alignment: 0.5,
          ),
        );
      }
    });
  }

  Future<void> _showAllTagsSheet() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AllTagsSheet(selectedTag: _selectedTag),
    );
    if (selected != null && selected != _selectedTag) {
      _onTagSelected(selected);
    }
  }

  Future<void> _openLevel(PuzzleLevelItem level) async {
    // 网络关卡：统一经 LevelImageResolver 懒下载原图落盘（见缩略必可玩），
    // 与 event_levels_page 同一套路径
    Uint8List? imgBytes;
    try {
      final localPath = await LevelImageResolver.instance.resolveLevelLocalPath(
        level,
      );
      if (localPath.startsWith('http')) {
        if (mounted) {
          GameToast.show(
            context,
            icon: PhosphorIconsRegular.warning,
            message: t.levels.networkFail,
            type: GameToastType.error,
          );
        }
        return;
      }
      if (!mounted) return;
      if (localPath.startsWith('assets/')) {
        final data = await DefaultAssetBundle.of(context).load(localPath);
        imgBytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
      } else if (File(localPath).existsSync()) {
        imgBytes = await File(localPath).readAsBytes();
      }
      // best-effort：记录后降级继续
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      AppLogger.game.warning(
        'Home openLevel image fail id=${level.id}',
        e,
        st,
      );
      if (mounted) {
        GameToast.show(
          context,
          icon: PhosphorIconsRegular.warning,
          message: t.levels.imgLoadFailed(error: e),
          type: GameToastType.error,
        );
      }
      return;
    }
    // 兜底：非 http 但本地文件不存在等静默空路径，给用户明确失败反馈
    if (imgBytes == null) {
      if (mounted) {
        GameToast.show(
          context,
          icon: PhosphorIconsRegular.warning,
          message: t.levels.imgLoadFailed(error: Exception('no local file')),
          type: GameToastType.error,
        );
      }
      return;
    }
    if (!mounted) return;

    final canonicalId = level.id;
    final prog = ProgressStore.instance.getLevelProgress(canonicalId);
    AppLogger.game.info(
      'Home openLevel canonical=$canonicalId order=${level.order}',
    );
    // D7：数据未下发 difficulty 前默认全局推荐档（按 1:1 假定；
    // 面板内解码图片后会对非 square 图按实际比例校正到推荐档）
    final fallbackDifficulty = RecommendService.instance.squareDifficulty;
    final title = level.displayTitle;

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
              imageBytes: imgBytes!,
              difficulty: diff,
              canonicalId: canonicalId,
              packTitle: title,
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
      prog,
      prog.progressPercent,
      isCompleted: prog.isCompleted,
    );
    if (!mounted) return;
    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: fallbackDifficulty,
      completedPieceCounts: prog.completedPieceCounts.toSet(),
      canonicalId: canonicalId,
      title: title,
      imagePathOrUrl: level.displayPath,
      savedProgressPercent: displayPercent == 0 ? null : displayPercent,
      onResetProgress: () async {
        final p = await ResumeHelper.loadProgress(canonicalId);
        if (p.activeDifficultyKey.isNotEmpty) {
          await ResumeHelper.clearResume(canonicalId, p.activeDifficultyKey);
        }
        await GameRepository.instance.updateGenericProgress(
          canonicalId: canonicalId,
          progressPercent: 0,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes!,
              difficulty: fallbackDifficulty,
              canonicalId: canonicalId,
              packTitle: title,
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
              imageBytes: imgBytes!,
              difficulty: diff,
              canonicalId: canonicalId,
              packTitle: title,
              initialSnapshotJson: snapJson,
            ),
          ),
        );
        setState(() {});
      },
    );
  }

  @override
  void dispose() {
    LocaleService.instance.removeListener(_onLocaleChanged);
    AppContent.instance.contentUpdateNotifier.removeListener(_onContentChanged);
    ProgressStore.instance.progressNotifier.removeListener(_onContentChanged);
    _scrollController.dispose();
    _tagScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final allLevels = _getLevels();
    final filteredLevels = _getFilteredLevels(allLevels);
    final now = DateTime.now();
    final dailyBannerItem = AppContent.instance.isInitialized
        ? AppContent.instance.manager.getDailyBannerLevel()
        : null;

    return RefreshIndicator(
      color: palette.brand,
      backgroundColor: palette.surfaceContainer,
      onRefresh: () async {
        // 下拉触发轻量网络增量（main/events/collections 元数据 + daily index，
        // 不下 daily 月度 zip）。若后台全量轮（含 zip）正在进行，直接结束下拉，
        // 内容稍后由 contentUpdateNotifier 刷新，避免在互斥锁上干等几十秒。
        if (AppContent.instance.isInitialized) {
          if (AppContent.instance.isSyncing) {
            AppLogger.content.info(
              'Home pull-refresh skipped: background sync in progress',
            );
          } else {
            await AppContent.instance.syncAll(includeDailyZip: false);
          }
        }
        if (mounted) setState(() {});
      },
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // ── Header 可横滑（每日+活动），不吸顶，随滚动
          SliverToBoxAdapter(
            child: _HeaderCarousel(
              dailyBannerItem: dailyBannerItem,
              now: now,
              palette: palette,
              styles: styles,
              onTapDaily: widget.onSwitchToDaily,
            ),
          ),

          // ── Tag栏 单行吸顶 44dp ─────────────────
          SliverPersistentHeader(
            pinned: true,
            delegate: _TagBarDelegate(
              selectedTag: _selectedTag,
              palette: palette,
              tagKeys: _tagKeys,
              tagScrollController: _tagScrollController,
              onTagSelected: _onTagSelected,
              onShowAll: _showAllTagsSheet,
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 8)),

          // ── Level Grid 纯图卡 ───────────────────
          if (filteredLevels.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Column(
                    children: [
                      const Text('🦊', style: TextStyle(fontSize: 44)),
                      const SizedBox(height: 8),
                      Text(
                        t.home.emptyCategory,
                        style: styles.caption.copyWith(fontSize: 14),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => _onTagSelected('all'),
                        style: FilledButton.styleFrom(
                          backgroundColor: palette.brand,
                        ),
                        child: Text(t.home.viewAll),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final level = filteredLevels[index];
                  return _LevelCard(
                    level: level,
                    palette: palette,
                    onTap: () => _openLevel(level),
                  );
                }, childCount: filteredLevels.length),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
// Header Carousel: 每日 + 活动 PageView，不吸顶
// ═══════════════════════════════════════════════════
class _HeaderCarousel extends StatefulWidget {
  const _HeaderCarousel({
    required this.dailyBannerItem,
    required this.now,
    required this.palette,
    required this.styles,
    required this.onTapDaily,
  });

  final PuzzleLevelItem? dailyBannerItem;
  final DateTime now;
  final AppPalette palette;
  final AppTextStyles styles;
  final VoidCallback onTapDaily;

  @override
  State<_HeaderCarousel> createState() => _HeaderCarouselState();
}

class _HeaderCarouselState extends State<_HeaderCarousel> {
  @override
  void initState() {
    super.initState();
    AppContent.instance.contentUpdateNotifier.addListener(_onContentUpdate);
    AppContent.instance.events.updateNotifier.addListener(_onContentUpdate);
    AppContent.instance.events.progressNotifier.addListener(_onContentUpdate);
  }

  void _onContentUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppContent.instance.contentUpdateNotifier.removeListener(_onContentUpdate);
    AppContent.instance.events.updateNotifier.removeListener(_onContentUpdate);
    AppContent.instance.events.progressNotifier.removeListener(
      _onContentUpdate,
    );
    super.dispose();
  }

  Future<void> _startDownloadEvent(PuzzleEventItem item) async {
    SoundService.I.play(Sfx.tap);
    AppLogger.events.info(
      'Home start download event id=${item.id} title=${item.displayTitle} isZip=${item.isZipType}',
    );
    try {
      final ok = await AppContent.instance.events.ensureEventDownloaded(item);
      if (mounted) {
        if (ok) {
          AppLogger.events.info('Home download event ok id=${item.id}');
          GameToast.show(
            context,
            icon: PhosphorIconsFill.checkCircle,
            message: t.collections.toastReady(title: item.displayTitle),
            type: GameToastType.success,
          );
        } else {
          AppLogger.events.warning(
            'Home download event failed id=${item.id}',
          );
          GameToast.show(
            context,
            icon: PhosphorIconsRegular.warning,
            message: t.collections.toastFailed,
            type: GameToastType.error,
          );
        }
      }
      // best-effort：记录后降级继续
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      AppLogger.events.warning(
        'Home download event exception id=${item.id}',
        e,
        st,
      );
      if (mounted) {
        GameToast.show(
          context,
          icon: PhosphorIconsRegular.warning,
          message: t.collections.toastError(error: '$e'),
          type: GameToastType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = AppContent.instance.isInitialized
        ? AppContent.instance.manager.getVisibleEvents().take(4).toList()
        : <PuzzleEventItem>[];

    final bannerItems = <HeroBannerItem>[
      // 1. 每日挑战焦点卡片 (当且仅当存在今日关卡或历史推导关卡时展示，严禁使用内置样本 demo 图)
      if (widget.dailyBannerItem != null)
        HeroBannerItem(
          id: 'daily_${widget.now.toIso8601String()}',
          title: t.home.bannerDailyTitle(
            month: widget.now.month,
            day: widget.now.day,
          ),
          subtitle: t.home.bannerDailySub,
          imagePathOrUrl: widget.dailyBannerItem!.imagePathOrUrl,
          badgeText: t.home.bannerDailyBadge,
          badgeEmoji: '🔥',
          badgeColor: widget.palette.brand,
          onTap: () {
            SoundService.I.play(Sfx.tap);
            widget.onTapDaily();
          },
        ),
      // 2. 活跃活动卡片
      for (final ev in events)
        () {
          final isDownloaded = AppContent.instance.manager.isEventDownloaded(
            ev,
          );
          final isDownloading = AppContent.instance.events.isDownloading(ev.id);
          final downloadProgress = AppContent.instance.events
              .getDownloadProgress(ev.id);

          return HeroBannerItem(
            id: ev.id,
            title: ev.displayTitle,
            subtitle: ev.displayDesc.isNotEmpty
                ? ev.displayDesc
                : t.events.subFallback,
            imagePathOrUrl:
                ev.coverUrl ?? (ev.levels.isNotEmpty ? ev.levels.first : ''),
            badgeText: t.events.badgeLimited,
            badgeEmoji: '⭐',
            badgeColor: const Color(0xFFD97706),
            topRightBadge: DownloadBadge(
              isDownloaded: isDownloaded,
              isDownloading: isDownloading,
              downloadProgress: downloadProgress,
              isZipType: ev.isZipType,
              displayFileSize: ev.displayFileSize,
            ),
            onTap: () {
              SoundService.I.play(Sfx.tap);
              // 未下载的 Zip 活动禁止进入关卡页，点击就地触发下载
              if (ev.isZipType && !isDownloaded) {
                if (isDownloading) {
                  GameToast.show(
                    context,
                    icon: PhosphorIconsRegular.downloadSimple,
                    message: t.collections.downloading(
                      title: ev.displayTitle,
                      percent: (downloadProgress * 100).toInt(),
                    ),
                  );
                } else {
                  GameToast.show(
                    context,
                    icon: PhosphorIconsRegular.downloadSimple,
                    message: t.collections.startDownload(
                      title: ev.displayTitle,
                    ),
                  );
                  unawaited(_startDownloadEvent(ev));
                }
                return;
              }

              unawaited(EventLevelsPage.open(context, ev));
            },
          );
        }(),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: AdaptiveHeroBanner(
        items: bannerItems,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
// Tag栏 吸顶 Delegate 44dp 单行横滑 + 固定入口
// ═══════════════════════════════════════════════════
class _TagBarDelegate extends SliverPersistentHeaderDelegate {
  _TagBarDelegate({
    required this.selectedTag,
    required this.palette,
    required this.tagKeys,
    required this.tagScrollController,
    required this.onTagSelected,
    required this.onShowAll,
  });

  final String selectedTag;
  final AppPalette palette;
  final Map<String, GlobalKey> tagKeys;
  final ScrollController tagScrollController;
  final ValueChanged<String> onTagSelected;
  final VoidCallback onShowAll;

  @override
  double get minExtent => 44;
  @override
  double get maxExtent => 44;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      height: 44,
      color: palette.surface,
      // 垂直居中：Container 44dp 内所有子元素居中
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 横滑区 占满高度并居中
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(right: 48),
              child: SingleChildScrollView(
                controller: tagScrollController,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    for (final entry in getLocalizedHomeTags()) ...[
                      Container(
                        key: tagKeys[entry['id']],
                        child: _TagChip(
                          label: entry['label']!,
                          isActive:
                              selectedTag.toLowerCase() ==
                              entry['id']!.toLowerCase(),
                          palette: palette,
                          onTap: () => onTagSelected(entry['id']!),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // 固定入口 + 右侧渐变遮罩，垂直居中
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Container(
              width: 48,
              decoration: BoxDecoration(color: palette.surface),
              // 渐变遮罩在底层，避免遮挡点击
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 渐变
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            palette.surface.withValues(alpha: 0),
                            palette.surface,
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 按钮 严格居中
                  Center(
                    child: IconButton(
                      icon: Icon(
                        PhosphorIconsBold.list,
                        size: 20,
                        color: palette.secondaryText,
                      ),
                      tooltip: t.home.allCategories,
                      onPressed: onShowAll,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _TagBarDelegate oldDelegate) => true;
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.label,
    required this.isActive,
    required this.palette,
    required this.onTap,
  });
  final String label;
  final bool isActive;
  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: isActive ? palette.brand : palette.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isActive ? palette.brand : palette.divider,
          ),
          boxShadow: isActive
              ? [
                  BoxShadow(
                    color: palette.brand.withValues(alpha: 0.18),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            color: isActive ? palette.surface : palette.secondaryText,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
// 全部 Sheet 3列
// ═══════════════════════════════════════════════════
class _AllTagsSheet extends StatelessWidget {
  const _AllTagsSheet({required this.selectedTag});
  final String selectedTag;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFFF2F2F2),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: GridView.count(
              shrinkWrap: true,
              crossAxisCount: 3,
              childAspectRatio: 2.8,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: getLocalizedHomeTags().map((e) {
                final id = e['id']!;
                final label = e['label']!;
                final isActive = selectedTag.toLowerCase() == id.toLowerCase();
                return Material(
                  color: isActive ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    onTap: () => Navigator.of(context).pop(id),
                    borderRadius: BorderRadius.circular(12),
                    hoverColor: Colors.white,
                    highlightColor: Colors.white,
                    splashColor: const Color(
                      0xFF6B4EFF,
                    ).withValues(alpha: 0.12),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 15,
                          color: isActive
                              ? const Color(0xFF6B4EFF)
                              : Colors.black87,
                          fontWeight: isActive
                              ? FontWeight.w700
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
// Level Card 纯图 + NEW 飘带
// ═══════════════════════════════════════════════════
class _LevelCard extends StatelessWidget {
  const _LevelCard({
    required this.level,
    required this.palette,
    required this.onTap,
  });
  final PuzzleLevelItem level;
  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 网络关卡：NEW 用 addedAt（7 天内）；进度/完成角标实时读 ProgressStore
    final prog = ProgressStore.instance.getLevelProgress(level.id);
    final isNew = level.isNew && !prog.isCompleted;
    final hasProgress = prog.progressPercent > 0 && !prog.isCompleted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            LazyLevelImage(level: level),
            if (isNew)
              Positioned(
                left: 0,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0xFFC97A2E),
                    borderRadius: BorderRadius.only(
                      topRight: Radius.circular(4),
                      bottomRight: Radius.circular(4),
                    ),
                  ),
                  child: const Text(
                    'New',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ),
            if (hasProgress)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${prog.progressPercent}%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            // 可选：最高块数（首期不显示，二期启用）
            // Positioned(right:6, bottom:6, child: Container(padding: EdgeInsets.symmetric(horizontal:6, vertical:2), decoration:BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)), child: Text('◈ ${level.difficulty.pieceCount}', style: TextStyle(color: Colors.white, fontSize:10))))
          ],
        ),
      ),
    );
  }
}
