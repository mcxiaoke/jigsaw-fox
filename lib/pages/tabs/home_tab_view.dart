import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../data/game_repository.dart';
import '../../data/models/level_item.dart';
import '../../data/resume_helper.dart';
import '../../data/snapshot_store.dart';
import '../../logic/cache/image_cache_manager.dart';
import '../../logic/content/app_content.dart';
import '../../logic/image_source.dart';
import '../../services/app_logger.dart';
import '../../services/sound_service.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_text_styles.dart';
import '../../widgets/adaptive_hero_banner.dart';
import '../../widgets/app_cached_image.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../../widgets/game_toast.dart';
import '../event_levels_page.dart';
import '../game_page.dart';

import '../../data/constants/puzzle_tags.dart';
import '../../l10n/gen/strings.g.dart';
import '../../services/locale_service.dart';
import '../../utils/locale_helper.dart';

// 热门N个（横滑常驻，末位固定入口之后展开全部 18 个黄金矩阵标签）
const List<String> kHotTagIds = [
  'Pets',
  'Landscapes',
  'Flowers',
  'Structures',
  'Food',
  'Art',
];

class HomeTabView extends StatefulWidget {
  const HomeTabView({super.key, required this.onSwitchToDaily});

  final VoidCallback onSwitchToDaily;

  @override
  State<HomeTabView> createState() => _HomeTabViewState();
}

class _HomeTabViewState extends State<HomeTabView> {
  final _repo = GameRepository.instance;
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
  }

  void _onLocaleChanged() {
    if (mounted) setState(() {});
  }

  // 标签解析：优先使用素材自身 tags，若为空则按 index 轮转兜底
  String _resolveTag(LevelItem l) {
    if (l.tags.isNotEmpty) return l.tags.first;
    final idx = (l.index - 1) % (kHomeTags.length - 1);
    return kHomeTags[idx + 1]['id']!;
  }

  List<LevelItem> _getFilteredLevels(List<LevelItem> all) {
    if (_selectedTag == 'all') return all;
    final selLower = _selectedTag.toLowerCase();
    return all
        .where(
          (l) => l.tags.isNotEmpty
              ? l.tags.any((t) {
                  final tLower = t.toLowerCase();
                  if (tLower == selLower) return true;
                  final mappedEn = kTagZhToId[t]?.toLowerCase();
                  if (mappedEn != null && mappedEn == selLower) return true;
                  final mappedZh = kTagIdToZh[t]?.toLowerCase();
                  if (mappedZh != null && mappedZh == selLower) return true;
                  return false;
                })
              : _resolveTag(l).toLowerCase() == selLower,
        )
        .toList();
  }

  void _onTagSelected(String tag) {
    if (_selectedTag == tag) return;
    setState(() => _selectedTag = tag);
    // 过滤后回顶
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
    // 横滑 Tag 栏滚动到选中项可见
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _tagKeys[tag];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          alignment: 0.5,
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

  Future<void> _openLevel(LevelItem level) async {
    Uint8List imgBytes;
    try {
      final bytes = await rootBundle.load(level.assetPath);
      imgBytes = bytes.buffer.asUint8List(
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );
    } catch (e, st) {
      AppLogger.game.warning(
        'Home openLevel asset load failed index=${level.index} path=${level.assetPath}',
        e,
        st,
      );
      if (mounted) {
        GameToast.show(
          context,
          message: '关卡图片加载失败，请重试',
          type: GameToastType.error,
        );
      }
      return;
    }
    AppLogger.game.info(
      'Home openLevel index=${level.index} canonical=${GameRepository.canonicalForLevel(level.index)}',
    );
    if (!mounted) return;
    final canonicalId = GameRepository.canonicalForLevel(level.index);
    final handled = await ResumeHelper.tryHandleResumeFlow(
      context: context,
      canonicalId: canonicalId,
      fallbackDifficulty: level.difficulty,
      isCompleted: level.isCompleted,
      title: '拼图',
      imageBytes: imgBytes,
      onClearRepo: (k) => _repo.updateLevelProgress(
        levelIndex: level.index,
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
              levelIndex: level.index,
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
    final progress = await ResumeHelper.loadProgress(canonicalId);
    final displayPercent = ResumeHelper.displayProgress(
      progress,
      level.progressPercent,
      level.isCompleted,
    );
    if (!mounted) return;
    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: level.difficulty,
      completedPieceCounts: level.completedPieceCounts.toSet(),
      canonicalId: canonicalId,
      isUnlocked: true,
      title: level.title,
      imagePathOrUrl: level.assetPath,
      savedProgressPercent: displayPercent == 0 ? null : displayPercent,
      onResetProgress: () async {
        final prog = await ResumeHelper.loadProgress(canonicalId);
        if (prog.activeDifficultyKey.isNotEmpty) {
          await ResumeHelper.clearResume(canonicalId, prog.activeDifficultyKey);
        }
        await _repo.updateLevelProgress(
          levelIndex: level.index,
          progressPercent: 0,
          snapshotJson: null,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes,
              difficulty: level.difficulty,
              levelIndex: level.index,
              initialSnapshotJson: null,
            ),
          ),
        );
        setState(() {});
      },
      onStart: (diff) async {
        final dkey = SnapshotStore.difficultyKeyFor(diff);
        // 快照由 SnapshotStore 文件级管理；Item 旧快照字段
        // 遗留 fallback 已移除（改造后恒为 null，清理阶段 §11）
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
              levelIndex: level.index,
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
    _scrollController.dispose();
    _tagScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final allLevels = _repo.levels;
    final filteredLevels = _getFilteredLevels(allLevels);
    final now = DateTime.now();
    final todayDaily = AppContent.instance.isInitialized
        ? AppContent.instance.manager.getTodayDailyLevel()
        : null;

    return RefreshIndicator(
      color: palette.brand,
      backgroundColor: palette.surfaceContainer,
      onRefresh: () async => setState(() {}),
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // ── Header 可横滑（每日+活动），不吸顶，随滚动
          SliverToBoxAdapter(
            child: _HeaderCarousel(
              todayDaily: todayDaily,
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
                  childAspectRatio: 1.0,
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
    required this.todayDaily,
    required this.now,
    required this.palette,
    required this.styles,
    required this.onTapDaily,
  });

  final dynamic todayDaily;
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
  }

  void _onContentUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppContent.instance.contentUpdateNotifier.removeListener(_onContentUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final events = AppContent.instance.isInitialized
        ? AppContent.instance.manager.getVisibleEvents().take(4).toList()
        : [];

    final bannerItems = <HeroBannerItem>[
      // 1. 每日挑战焦点卡片
      HeroBannerItem(
        id: 'daily_${widget.now.toIso8601String()}',
        title: t.home.bannerDailyTitle(
          month: widget.now.month,
          day: widget.now.day,
        ),
        subtitle: t.home.bannerDailySub,
        imagePathOrUrl: widget.todayDaily?.imagePathOrUrl ?? assetSamples[0],
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
        HeroBannerItem(
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
          onTap: () {
            SoundService.I.play(Sfx.tap);
            EventLevelsPage.open(context, ev);
          },
        ),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: AdaptiveHeroBanner(
        items: bannerItems,
        cardWidth: 290,
        cardHeight: 156,
        padding: const EdgeInsets.symmetric(horizontal: 16),
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
                  crossAxisAlignment: CrossAxisAlignment.center,
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
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
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
            width: 1,
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
  final LevelItem level;
  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isNew = level.isNew;
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
            AppCachedImage(
              imagePathOrUrl: level.assetPath,
              fit: BoxFit.cover,
              targetDimension: ThumbnailDimension.card,
            ),
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
            if (level.progressPercent > 0 && !level.isCompleted)
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
                    '${level.progressPercent}%',
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
