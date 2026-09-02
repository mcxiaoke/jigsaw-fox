import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../data/game_repository.dart';
import '../../data/models/level_item.dart';
import '../../data/resume_helper.dart';
import '../../data/snapshot_store.dart';
import '../../logic/cache/image_cache_manager.dart';
import '../../logic/content/app_content.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_text_styles.dart';
import '../../widgets/app_cached_image.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../game_page.dart';

// 21 Primary Tags（对齐 jigsaw-image-tagging-specification.md v1.1）
const List<Map<String, String>> kHomeTags = [
  {'id': 'all', 'label': '全部'},
  {'id': 'Pets', 'label': '宠物'},
  {'id': 'Animals', 'label': '动物'},
  {'id': 'Birds', 'label': '鸟类'},
  {'id': 'Nature', 'label': '自然'},
  {'id': 'Landscapes', 'label': '风景'},
  {'id': 'Flowers', 'label': '花卉'},
  {'id': 'Ocean', 'label': '海洋'},
  {'id': 'Cities', 'label': '城市'},
  {'id': 'Architecture', 'label': '建筑'},
  {'id': 'Food', 'label': '美食'},
  {'id': 'Art', 'label': '艺术'},
  {'id': 'Fantasy', 'label': '奇幻'},
  {'id': 'Space', 'label': '太空'},
  {'id': 'Transportation', 'label': '交通'},
  {'id': 'People', 'label': '人物'},
  {'id': 'Sports', 'label': '运动'},
  {'id': 'Seasons', 'label': '四季'},
  {'id': 'Holidays', 'label': '节日'},
  {'id': 'Abstract', 'label': '抽象'},
  {'id': 'Cartoon', 'label': '卡通'},
  {'id': 'Others', 'label': '其他'},
];

// 热门N个（横滑常驻，末位固定入口之后展开全部21）
const List<String> kHotTagIds = [
  'Pets',
  'Landscapes',
  'Flowers',
  'Architecture',
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

  // 伪Tag映射（数据未接入前兜底，按index%21分配，便于过滤演示）
  String _resolveTag(LevelItem l) {
    if (l.tags.isNotEmpty) return l.tags.first;
    // 映射到 21 中的一个（跳过 'all'）
    final idx = (l.index - 1) % 20;
    return kHomeTags[idx + 1]['id']!;
  }

  List<LevelItem> _getFilteredLevels(List<LevelItem> all) {
    if (_selectedTag == 'all') return all;
    return all
        .where(
          (l) => _resolveTag(l).toLowerCase() == _selectedTag.toLowerCase(),
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
    final bytes = await rootBundle.load(level.assetPath);
    final imgBytes = bytes.buffer.asUint8List();
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
        final snapJson = await SnapshotStore.instance.loadJsonString(
          canonicalId,
          dkey,
        );
        final fallbackLegacy =
            (diff.pieceCount == level.difficulty.pieceCount &&
                !level.isCompleted)
            ? level.savedSnapshotJson
            : null;
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes,
              difficulty: diff,
              levelIndex: level.index,
              initialSnapshotJson: snapJson ?? fallbackLegacy,
            ),
          ),
        );
        setState(() {});
      },
    );
  }

  @override
  void dispose() {
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
    final todayStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final todayDaily = _repo.dailyChallenges.firstWhere(
      (d) => d.date == todayStr,
      orElse: () => _repo.dailyChallenges.first,
    );

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
                        '小狐狸没找到该分类的关卡',
                        style: styles.caption.copyWith(fontSize: 14),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => _onTagSelected('all'),
                        style: FilledButton.styleFrom(
                          backgroundColor: palette.brand,
                        ),
                        child: const Text('查看全部'),
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
  late final PageController _pc;

  @override
  void initState() {
    super.initState();
    _pc = PageController(viewportFraction: 0.96);
    AppContent.instance.contentUpdateNotifier.addListener(_onContentUpdate);
  }

  void _onContentUpdate() {
    if (mounted) setState(() {});
  }

  int _idx = 0;

  @override
  void dispose() {
    AppContent.instance.contentUpdateNotifier.removeListener(_onContentUpdate);
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final events = AppContent.instance.isInitialized
        ? AppContent.instance.manager.getVisibleEvents().take(3).toList()
        : [];
    final pageCount = 1 + events.length;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Column(
        children: [
          SizedBox(
            height: 160,
            child: PageView.builder(
              controller: _pc,
              onPageChanged: (i) => setState(() => _idx = i),
              physics: const BouncingScrollPhysics(),
              clipBehavior: Clip.none,
              itemCount: pageCount,
              itemBuilder: (_, i) {
                final card = i == 0
                    ? _DailyBanner(
                        todayDaily: widget.todayDaily,
                        now: widget.now,
                        palette: widget.palette,
                        styles: widget.styles,
                        onTap: widget.onTapDaily,
                      )
                    : _EventBannerCard(event: events[i - 1]);
                // 水平 4dp 间距，viewportFraction 0.96 => 侧边距12dp，卡间距8dp，居中等宽
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: card,
                );
              },
            ),
          ),
          if (pageCount > 1) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(pageCount, (i) {
                final sel = i == _idx;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: sel ? 18 : 8,
                  height: 4,
                  decoration: BoxDecoration(
                    color: sel ? Colors.black87 : Colors.black26,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
          ],
        ],
      ),
    );
  }
}

class _EventBannerCard extends StatelessWidget {
  const _EventBannerCard({required this.event});
  final dynamic event;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AppCachedImage(
            imagePathOrUrl:
                event.coverUrl ??
                (event.levels.isNotEmpty ? event.levels.first : ''),
            fit: BoxFit.cover,
            targetDimension: ThumbnailDimension.eventCover,
          ),
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.black54, Colors.transparent],
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
              ),
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 12,
            child: Text(
              event.title ?? '精选活动',
              style: styles.h3.copyWith(color: Colors.white, fontSize: 16),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Positioned(
            left: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: palette.brand,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '活动',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
// Daily Banner (保持现有简洁样式)
// ═══════════════════════════════════════════════════
class _DailyBanner extends StatelessWidget {
  const _DailyBanner({
    required this.todayDaily,
    required this.now,
    required this.palette,
    required this.styles,
    required this.onTap,
  });

  final dynamic todayDaily;
  final DateTime now;
  final AppPalette palette;
  final AppTextStyles styles;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AppCachedImage(
              imagePathOrUrl: todayDaily.assetPath,
              fit: BoxFit.cover,
              targetDimension: ThumbnailDimension.eventCover,
            ),
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black54, Colors.transparent],
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: palette.brand,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('🔥', style: TextStyle(fontSize: 10)),
                        const SizedBox(width: 4),
                        Text(
                          '每日挑战',
                          style: TextStyle(
                            color: palette.surface,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${now.month}月${now.day}日 · 今日专属',
                    style: styles.h3.copyWith(
                      color: Colors.white,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
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
                    for (final entry in kHomeTags) ...[
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
                      tooltip: '全部分类',
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
  bool shouldRebuild(covariant _TagBarDelegate oldDelegate) =>
      oldDelegate.selectedTag != selectedTag || oldDelegate.palette != palette;
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
              children: kHomeTags.map((e) {
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
            // 可选：最高块数（首期不显示，二期启用）
            // Positioned(right:6, bottom:6, child: Container(padding: EdgeInsets.symmetric(horizontal:6, vertical:2), decoration:BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)), child: Text('◈ ${level.difficulty.pieceCount}', style: TextStyle(color: Colors.white, fontSize:10))))
          ],
        ),
      ),
    );
  }
}
