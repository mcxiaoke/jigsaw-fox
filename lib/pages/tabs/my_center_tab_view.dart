import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../data/favorite_store.dart';
import '../../data/game_repository.dart';
import '../../data/progress_store.dart';
import '../../data/resume_helper.dart';
import '../../data/snapshot_store.dart';
import '../../logic/catalog_index.dart';
import '../../logic/content/app_content.dart';
import '../../logic/puzzle_model.dart';
import '../../logic/unified_puzzle_resolver.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_text_styles.dart';
import '../../widgets/app_cached_image.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../game_page.dart';

/// 全新“我的”中心 Tab 视图（聚合进行中、收藏与已完成拼图）
class MyCenterTabView extends StatefulWidget {
  const MyCenterTabView({super.key, this.onGoExplore, this.isActive = true});

  /// 当点击“去图库挑挑看”时回调（切回主页 Tab 0）
  final VoidCallback? onGoExplore;

  /// 当前 Tab 是否处于活跃可见状态（在 IndexedStack 切换时触发增量刷新）
  final bool isActive;

  @override
  State<MyCenterTabView> createState() => _MyCenterTabViewState();
}

class _MyCenterTabViewState extends State<MyCenterTabView> {
  bool _isLoading = true;
  List<UnifiedPuzzleCardData> _inProgressList = [];
  List<UnifiedPuzzleCardData> _favoritesList = [];
  List<UnifiedPuzzleCardData> _completedList = [];
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadAllData();
    ProgressStore.instance.progressNotifier.addListener(_onExternalChanged);
    FavoriteStore.instance.idsNotifier.addListener(_onExternalChanged);
    GameRepository.instance.customPuzzlesNotifier.addListener(
      _onContentChanged,
    );
    AppContent.instance.contentUpdateNotifier.addListener(_onContentChanged);
  }

  void _onContentChanged() {
    UnifiedCatalogIndex.invalidate();
    _onExternalChanged();
  }

  @override
  void didUpdateWidget(covariant MyCenterTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _loadAllData();
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    ProgressStore.instance.progressNotifier.removeListener(_onExternalChanged);
    FavoriteStore.instance.idsNotifier.removeListener(_onExternalChanged);
    GameRepository.instance.customPuzzlesNotifier.removeListener(
      _onContentChanged,
    );
    AppContent.instance.contentUpdateNotifier.removeListener(_onContentChanged);
    super.dispose();
  }

  void _onExternalChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) {
        _loadAllData();
      }
    });
  }

  Future<void> _loadAllData() async {
    final catalogIndex = await UnifiedCatalogIndex.current();
    final progressMap = await ProgressStore.instance.loadAllProgress();
    final favoriteEntries = await FavoriteStore.instance
        .favoritesSortedByTime();
    final resolver = UnifiedPuzzleResolver(catalogIndex);

    // 1. 进行中列表（规则乙：hasSnapshot || progressPercent > 0）
    final inProgress = <UnifiedPuzzleCardData>[];
    for (final p in progressMap.values) {
      if (p.hasSnapshot || p.progressPercent > 0) {
        final card = resolver.resolve(canonicalId: p.canonicalId, progress: p);
        inProgress.add(card);
      }
    }
    // 排序：按最近活跃/游玩时间倒序
    inProgress.sort((a, b) {
      final ta = a.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final tb = b.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return tb.compareTo(ta);
    });

    // 2. 已完成列表（isCompleted == true，允许与进行中重叠）
    final completed = <UnifiedPuzzleCardData>[];
    for (final p in progressMap.values) {
      if (p.isCompleted) {
        final card = resolver.resolve(canonicalId: p.canonicalId, progress: p);
        completed.add(card);
      }
    }
    // 排序：按最近完成时间倒序（null 降级 lastSavedAt）
    completed.sort((a, b) {
      final ta =
          a.lastCompletedAt ??
          a.lastSavedAt ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final tb =
          b.lastCompletedAt ??
          b.lastSavedAt ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return tb.compareTo(ta);
    });

    // 3. 收藏列表（从 FavoriteStore 条目装配，已按 favoritedAt 倒序）
    final favorites = <UnifiedPuzzleCardData>[];
    for (final fav in favoriteEntries) {
      final p = progressMap[fav.canonicalId];
      final card = resolver.resolve(
        canonicalId: fav.canonicalId,
        progress: p,
        favoriteEntry: fav,
      );
      favorites.add(card);
    }

    if (mounted) {
      setState(() {
        _inProgressList = inProgress;
        _completedList = completed;
        _favoritesList = favorites;
        _isLoading = false;
      });
    }
  }

  Future<Uint8List> _resolveImageBytes(UnifiedPuzzleCardData card) async {
    try {
      if (card.isLocalFile) {
        final file = File(card.imagePathOrUrl);
        if (file.existsSync()) {
          return await file.readAsBytes();
        }
      }
      if (card.imagePathOrUrl.startsWith('assets/')) {
        final data = await rootBundle.load(card.imagePathOrUrl);
        return data.buffer.asUint8List();
      }
      if (card.imagePathOrUrl.startsWith('http://') ||
          card.imagePathOrUrl.startsWith('https://')) {
        final uri = Uri.tryParse(card.imagePathOrUrl);
        if (uri != null) {
          final client = HttpClient();
          final req = await client.getUrl(uri);
          final res = await req.close();
          if (res.statusCode == 200) {
            return await consolidateHttpClientResponseBytes(res);
          }
        }
      }
    } catch (_) {}
    // 兜底图
    final data = await rootBundle.load('assets/samples/animal_01.webp');
    return data.buffer.asUint8List();
  }

  Future<void> _handleCardClick(UnifiedPuzzleCardData card) async {
    if (card.isOrphan) {
      await _cleanOrphan(card);
      return;
    }

    final imgBytes = await _resolveImageBytes(card);
    if (!mounted) return;

    // 1. 若有残局快照，优先走续玩流
    if (card.hasActiveSnapshot) {
      final fallbackDiff = PuzzleDifficulty.presets.firstWhere(
        (d) => SnapshotStore.difficultyKeyFor(d) == card.activeDifficultyKey,
        orElse: () => PuzzleAspectRatio.square1x1.tiers
            .firstWhere((t) => t.difficulty.recommended)
            .difficulty,
      );
      final handled = await ResumeHelper.tryHandleResumeFlow(
        context: context,
        canonicalId: card.canonicalId,
        fallbackDifficulty: fallbackDiff,
        title: card.title,
        imageBytes: imgBytes,
        onClearRepo: (dkey) async {
          await ProgressStore.instance.clearSnapshot(card.canonicalId, dkey);
          await SnapshotStore.instance.delete(card.canonicalId, dkey);
          _loadAllData();
        },
        onPushGame: (diff, jsonStr) async {
          if (!mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => GamePage(
                imageBytes: imgBytes,
                difficulty: diff,
                canonicalId: card.canonicalId,
                initialSnapshotJson: jsonStr,
              ),
            ),
          );
          _loadAllData();
        },
        onCancelled: () {
          if (mounted) _loadAllData();
        },
      );
      if (handled) return;
    }

    // 2. 无快照或点“重选难度”，打开难度选择面板
    final initialDiff = PuzzleDifficulty.presets.firstWhere(
      (d) => SnapshotStore.difficultyKeyFor(d) == card.activeDifficultyKey,
      orElse: () => PuzzleAspectRatio.square1x1.tiers
          .firstWhere((t) => t.difficulty.recommended)
          .difficulty,
    );

    if (!mounted) return;
    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: initialDiff,
      title: card.title,
      canonicalId: card.canonicalId,
      imagePathOrUrl: card.imagePathOrUrl,
      sourcePlatform: card.sourceLabel,
      completedPieceCounts: card.completedPieceCounts,
      onStart: (diff) async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes,
              difficulty: diff,
              canonicalId: card.canonicalId,
            ),
          ),
        );
        _loadAllData();
      },
    );
    _loadAllData();
  }

  Future<void> _cleanOrphan(UnifiedPuzzleCardData card) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('拼图资源已失效'),
        content: Text('该拼图资源已从本地或列表中移除，无法继续游玩。\n是否从记录与收藏中清理移除「${card.title}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('暂保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清理移除'),
          ),
        ],
      ),
    );

    if (ok == true) {
      await ProgressStore.instance.delete(card.canonicalId);
      await SnapshotStore.instance.deleteAllFor(card.canonicalId);
      await FavoriteStore.instance.remove(card.canonicalId);
      _loadAllData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);

    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          // 顶层子 Tab 切换栏
          Container(
            color: palette.surface,
            child: TabBar(
              labelColor: palette.brand,
              unselectedLabelColor: palette.secondaryText,
              indicatorColor: palette.brand,
              indicatorWeight: 2.5,
              labelStyle: styles.bodyBold.copyWith(
                fontSize: 14.5,
                fontWeight: FontWeight.bold,
              ),
              unselectedLabelStyle: styles.body.copyWith(fontSize: 14.5),
              tabs: [
                Tab(text: '进行中 (${_inProgressList.length})'),
                Tab(text: '收藏 (${_favoritesList.length})'),
                Tab(text: '已完成 (${_completedList.length})'),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 0.8),
          // Tab 视图内容区
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    children: [
                      // 1. 进行中子 Tab
                      _buildGridTab(
                        items: _inProgressList,
                        emptyEmoji: '🧩',
                        emptyTitle: '暂无进行中的拼图',
                        emptySub: '挑一张喜欢的拼图，开启拼图时光吧！',
                        actionButtonText: '去挑选拼图',
                        onAction: widget.onGoExplore,
                        palette: palette,
                        styles: styles,
                        tabType: _MyTabType.inProgress,
                      ),
                      // 2. 收藏子 Tab
                      _buildGridTab(
                        items: _favoritesList,
                        emptyEmoji: '❤️',
                        emptyTitle: '还没有收藏的拼图',
                        emptySub: '在选择难度面板中点击红心，可快捷收藏',
                        palette: palette,
                        styles: styles,
                        tabType: _MyTabType.favorites,
                      ),
                      // 3. 已完成子 Tab
                      _buildGridTab(
                        items: _completedList,
                        emptyEmoji: '🏆',
                        emptyTitle: '还没有完成过拼图',
                        emptySub: '通关任意一张拼图，即可在此记录辉煌战绩！',
                        palette: palette,
                        styles: styles,
                        tabType: _MyTabType.completed,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridTab({
    required List<UnifiedPuzzleCardData> items,
    required String emptyEmoji,
    required String emptyTitle,
    required String emptySub,
    String? actionButtonText,
    VoidCallback? onAction,
    required AppPalette palette,
    required AppTextStyles styles,
    required _MyTabType tabType,
  }) {
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadAllData,
        color: palette.brand,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 24),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(emptyEmoji, style: const TextStyle(fontSize: 48)),
                    const SizedBox(height: 12),
                    Text(emptyTitle, style: styles.h3.copyWith(fontSize: 16)),
                    const SizedBox(height: 6),
                    Text(
                      emptySub,
                      textAlign: TextAlign.center,
                      style: styles.caption.copyWith(
                        color: palette.secondaryText,
                        fontSize: 13,
                      ),
                    ),
                    if (actionButtonText != null && onAction != null) ...[
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: onAction,
                        icon: const Icon(
                          PhosphorIconsRegular.compass,
                          size: 16,
                        ),
                        label: Text(actionButtonText),
                        style: FilledButton.styleFrom(
                          backgroundColor: palette.brand,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadAllData,
      color: palette.brand,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 0.95,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final card = items[index];
                return _buildPuzzleCard(
                  card: card,
                  tabType: tabType,
                  palette: palette,
                  styles: styles,
                );
              }, childCount: items.length),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPuzzleCard({
    required UnifiedPuzzleCardData card,
    required _MyTabType tabType,
    required AppPalette palette,
    required AppTextStyles styles,
  }) {
    return InkWell(
      onTap: () => _handleCardClick(card),
      onLongPress: card.isOrphan ? () => _cleanOrphan(card) : null,
      borderRadius: BorderRadius.circular(16),
      child: Opacity(
        opacity: card.isOrphan ? 0.5 : 1.0,
        child: Container(
          decoration: BoxDecoration(
            color: palette.surfaceContainer,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: card.isOrphan
                  ? palette.divider
                  : palette.divider.withValues(alpha: 0.6),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 缩略图
              _buildCardImage(card),

              // 渐变黑遮罩（增强文字与标签可读性）
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.black.withValues(alpha: 0.45),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.65),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),

              // 左上角：来源色彩徽标
              Positioned(
                left: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: card.sourceColor.withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    card.sourceLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),

              // 右上角：根据子 Tab 展现不同角标
              Positioned(
                right: 8,
                top: 8,
                child: _buildTopRightBadge(card, tabType, palette),
              ),

              // 底部信息栏：标题、用时/副标题
              Positioned(
                left: 10,
                right: 10,
                bottom: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      card.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            card.isOrphan
                                ? '已失效 · 点击清理'
                                : (card.displaySubtitle ??
                                      (card.author != null
                                          ? 'By ${card.author}'
                                          : '')),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.8),
                              fontSize: 10.5,
                            ),
                          ),
                        ),
                        if (card.progressPercent > 0 &&
                            card.progressPercent < 100) ...[
                          Text(
                            '${card.progressPercent}%',
                            style: TextStyle(
                              color: palette.brandLight,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCardImage(UnifiedPuzzleCardData card) {
    if (card.imagePathOrUrl.isNotEmpty) {
      return AppCachedImage(
        imagePathOrUrl: card.imagePathOrUrl,
        fit: BoxFit.cover,
      );
    }
    return Container(
      color: Colors.grey.shade300,
      child: const Center(
        child: Icon(PhosphorIconsRegular.image, size: 28, color: Colors.grey),
      ),
    );
  }

  Widget _buildTopRightBadge(
    UnifiedPuzzleCardData card,
    _MyTabType tabType,
    AppPalette palette,
  ) {
    if (card.isOrphan) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Text(
          '失效',
          style: TextStyle(color: Colors.white70, fontSize: 10),
        ),
      );
    }

    switch (tabType) {
      case _MyTabType.inProgress:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (card.isCompleted) ...[
                Text(
                  '再挑战 · ',
                  style: TextStyle(
                    color: palette.brandLight,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
              Text(
                '${card.progressPercent}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        );

      case _MyTabType.completed:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '★' * card.maxStars,
                style: const TextStyle(
                  color: Colors.amber,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (card.bestTimeSeconds > 0) ...[
                const SizedBox(width: 3),
                Text(
                  _formatDuration(card.bestTimeSeconds),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        );

      case _MyTabType.favorites:
        return InkWell(
          onTap: () async {
            await FavoriteStore.instance.toggleFavorite(
              card.canonicalId,
              title: card.title,
              image: card.imagePathOrUrl,
              sourceLabel: card.sourceLabel,
              isLocalFile: card.isLocalFile,
              aspectRatioLabel: card.aspectRatio.name,
              author: card.author,
              tags: card.tags,
              preferredDifficultyKey: card.activeDifficultyKey.isNotEmpty
                  ? card.activeDifficultyKey
                  : card.highestDifficultyKey,
            );
            _loadAllData();
          },
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              PhosphorIconsFill.heart,
              color: Colors.redAccent,
              size: 15,
            ),
          ),
        );
    }
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m < 60) return '${m}m${s > 0 ? '$s' : ''}';
    final h = m ~/ 60;
    final remM = m % 60;
    return '${h}h${remM}m';
  }
}

enum _MyTabType { inProgress, favorites, completed }
