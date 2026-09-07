import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../logic/cache/image_cache_manager.dart';
import '../../logic/content/app_content.dart';
import '../../logic/content/models/puzzle_collection_item.dart';
import '../../logic/content/models/puzzle_event_item.dart';
import '../../services/app_logger.dart';
import '../../services/locale_service.dart';
import '../../services/sound_service.dart';
import '../../l10n/gen/strings.g.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_text_styles.dart';
import '../../widgets/adaptive_hero_banner.dart';
import '../../widgets/app_cached_image.dart';
import '../../widgets/game_toast.dart';
import '../collection_levels_page.dart';
import '../event_levels_page.dart';

/// 全新“图集”中心 Tab 视图
/// 1. 顶部 Banner：仅展示来自 events.json 的限时活动大卡片
/// 2. 下方网格：展示 collections 图集卡片，采用首页/每日统一的规格尺寸（maxCrossAxisExtent: 220, childAspectRatio: 1.0）
/// 3. 卡片只显示 title，不显示 desc；无需筛选分类标签
/// 4. 未下载的 Zip 图集禁止进入关卡页，点击就地触发下载
class CollectionsTabView extends StatefulWidget {
  const CollectionsTabView({super.key});

  @override
  State<CollectionsTabView> createState() => _CollectionsTabViewState();
}

class _CollectionsTabViewState extends State<CollectionsTabView> {
  final _content = AppContent.instance;

  @override
  void initState() {
    super.initState();
    _content.contentUpdateNotifier.addListener(_onUpdated);
    _content.collections.updateNotifier.addListener(_onUpdated);
    LocaleService.instance.addListener(_onUpdated);
  }

  @override
  void dispose() {
    LocaleService.instance.removeListener(_onUpdated);
    _content.contentUpdateNotifier.removeListener(_onUpdated);
    _content.collections.updateNotifier.removeListener(_onUpdated);
    super.dispose();
  }

  void _onUpdated() {
    if (mounted) setState(() {});
  }

  Future<void> _startDownload(PuzzleCollectionItem item) async {
    SoundService.I.play(Sfx.tap);
    AppLogger.content.info(
      'Collections start download id=${item.id} title=${item.title} isZip=${item.isZipType}',
    );
    try {
      final ok = await _content.collections.ensureCollectionDownloaded(item);
      if (mounted) {
        if (ok) {
          AppLogger.content.info('Collections download ok id=${item.id}');
          GameToast.show(
            context,
            icon: PhosphorIconsFill.checkCircle,
            message: t.collections.toastReady(title: item.title),
            type: GameToastType.success,
          );
        } else {
          AppLogger.content.warning(
            'Collections download failed id=${item.id}',
          );
          GameToast.show(
            context,
            icon: PhosphorIconsRegular.warning,
            message: t.collections.toastFailed,
            type: GameToastType.error,
          );
        }
      }
    } catch (e, st) {
      AppLogger.content.warning(
        'Collections download exception id=${item.id}',
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
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);

    // 1. 数据来源：collections 与 events
    final collections = _content.isInitialized
        ? _content.manager.getVisibleCollections()
        : <PuzzleCollectionItem>[];
    final visibleEvents = _content.isInitialized
        ? _content.manager.getVisibleEvents()
        : <PuzzleEventItem>[];

    // 2. 顶部 Banner：仅来自 events.json 的活动大卡片
    final heroItems = visibleEvents.map((ev) {
      return HeroBannerItem(
        id: ev.id,
        title: ev.displayTitle,
        subtitle: ev.displayDesc.isNotEmpty
            ? ev.displayDesc
            : t.events.subFallback,
        imagePathOrUrl:
            ev.coverUrl ?? (ev.levels.isNotEmpty ? ev.levels.first : ''),
        badgeText: t.events.badgeLimited,
        badgeEmoji: '🔥',
        badgeColor: const Color(0xFFD97706),
        onTap: () {
          SoundService.I.play(Sfx.tap);
          EventLevelsPage.open(context, ev);
        },
      );
    }).toList();

    return RefreshIndicator(
      onRefresh: () async => await _content.syncAll(),
      color: palette.brand,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          // 顶部焦点活动 Banner
          if (heroItems.isNotEmpty) ...[
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            SliverToBoxAdapter(
              child: AdaptiveHeroBanner(
                items: heroItems,
                cardWidth: 300,
                cardHeight: 160,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
          ] else ...[
            const SliverToBoxAdapter(child: SizedBox(height: 10)),
          ],

          // 栏目标题统计胶囊条 (对齐每日挑战 Stats Bar 样式与高度)
          if (collections.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
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
                            PhosphorIconsFill.folders,
                            color: palette.brand,
                            size: 20,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            t.collections.statsTitle,
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
                          color: palette.brand.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          t.collections.statsCount(count: collections.length),
                          style: TextStyle(
                            color: palette.brand,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 6)),

          // 下方图集网格 (与首页/每日相同规格: maxCrossAxisExtent: 220, childAspectRatio: 1.0)
          if (collections.isEmpty && visibleEvents.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('🦊', style: TextStyle(fontSize: 48)),
                    const SizedBox(height: 10),
                    Text(
                      t.collections.emptyAll,
                      style: styles.body.copyWith(color: palette.secondaryText),
                    ),
                    const SizedBox(height: 6),
                    Text(t.collections.emptyHint, style: styles.caption),
                    const SizedBox(height: 14),
                    ElevatedButton.icon(
                      icon: const Icon(
                        PhosphorIconsRegular.arrowClockwise,
                        size: 16,
                      ),
                      label: Text(t.common.sync),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: palette.brand,
                        foregroundColor: palette.surface,
                      ),
                      onPressed: () async => await _content.syncAll(),
                    ),
                  ],
                ),
              ),
            )
          else if (collections.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Column(
                    children: [
                      Icon(
                        PhosphorIconsRegular.folderDashed,
                        size: 40,
                        color: palette.disabledText,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        t.collections.emptyCollections,
                        style: styles.caption,
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.0,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final col = collections[index];
                  return _buildCollectionCard(context, col, palette, styles);
                }, childCount: collections.length),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 36)),
        ],
      ),
    );
  }

  Widget _buildCollectionCard(
    BuildContext context,
    PuzzleCollectionItem col,
    AppPalette palette,
    AppTextStyles styles,
  ) {
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: _content.collections.progressNotifier,
      builder: (context, progressMap, _) {
        final downloadProgress = progressMap[col.id] ?? col.downloadProgress;
        final isDownloading =
            col.downloadStatus == CollectionDownloadStatus.downloading ||
            (downloadProgress > 0 &&
                downloadProgress < 1.0 &&
                !col.isLocalDownloaded);

        final isZipNotDownloaded = col.isZipType && !col.isLocalDownloaded;

        // 关卡数：优先使用元数据 totalCount，若本地已下载但 totalCount 为 0 则动态获取
        int effectiveCount = col.totalCount;
        if (effectiveCount <= 0 && col.isLocalDownloaded) {
          effectiveCount = _content.manager.getCollectionLevels(col).length;
        }

        return InkWell(
          onTap: () {
            SoundService.I.play(Sfx.tap);
            // 如果是 zip 图集且未下载好，禁止进入，就地触发下载或提示
            if (isZipNotDownloaded) {
              if (isDownloading) {
                GameToast.show(
                  context,
                  icon: PhosphorIconsRegular.downloadSimple,
                  message: t.collections.downloading(
                    title: col.title,
                    percent: (downloadProgress * 100).toInt(),
                  ),
                  type: GameToastType.info,
                );
              } else {
                GameToast.show(
                  context,
                  icon: PhosphorIconsRegular.downloadSimple,
                  message: t.collections.startDownload(title: col.title),
                  type: GameToastType.info,
                );
                _startDownload(col);
              }
              return;
            }

            // 已就绪（已下载或在线图集），方可进入关卡列表
            CollectionLevelsPage.open(context, col);
          },
          borderRadius: BorderRadius.circular(14),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.divider, width: 1),
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
                // 1. 封面底图
                AppCachedImage(
                  imagePathOrUrl:
                      col.coverUrl ??
                      (col.levels.isNotEmpty ? col.levels.first : ''),
                  fit: BoxFit.cover,
                  targetDimension: ThumbnailDimension.card,
                ),

                // 2. 底部渐变阴影 (保证标题高可读性)
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.transparent, Colors.black87],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.45, 1.0],
                    ),
                  ),
                ),

                // 3. 右上角：下载状态/角标
                Positioned(
                  right: 8,
                  top: 8,
                  child: _buildDownloadBadge(
                    col: col,
                    isDownloading: isDownloading,
                    downloadProgress: downloadProgress,
                    palette: palette,
                  ),
                ),

                // 4. 底部图集标题 (仅有 title，不显示 desc)
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 8,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          col.displayTitle,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.bold,
                            shadows: [
                              Shadow(
                                color: Colors.black87,
                                blurRadius: 4,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (effectiveCount > 0) ...[
                        const SizedBox(width: 4),
                        Text(
                          t.collections.levelCount(count: effectiveCount),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            shadows: const [
                              Shadow(
                                color: Colors.black87,
                                blurRadius: 3,
                                offset: Offset(0, 1),
                              ),
                            ],
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
      },
    );
  }

  Widget _buildDownloadBadge({
    required PuzzleCollectionItem col,
    required bool isDownloading,
    required double downloadProgress,
    required AppPalette palette,
  }) {
    // 1. 已下载完成
    if (col.isLocalDownloaded) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              PhosphorIconsBold.check,
              color: Colors.greenAccent,
              size: 11,
            ),
            const SizedBox(width: 3),
            Text(
              t.collections.badgeDownloaded,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    // 2. 下载中
    if (isDownloading) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                value: downloadProgress > 0 ? downloadProgress : null,
                color: palette.brand,
                strokeWidth: 2,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              '${(downloadProgress * 100).toInt()}%',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    // 3. Zip 未下载：显示醒目的下载按钮
    if (col.isZipType) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: palette.brand.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              PhosphorIconsBold.downloadSimple,
              color: Colors.white,
              size: 11,
            ),
            const SizedBox(width: 3),
            Text(
              col.displayFileSize.isNotEmpty
                  ? col.displayFileSize
                  : t.collections.badgeDownload,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    // 4. Array 在线类型（不需要下载）
    return const SizedBox.shrink();
  }
}
