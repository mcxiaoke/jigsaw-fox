import 'dart:async';

import 'package:flutter/material.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_collection_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:jigsawpuzzle/pages/collection_levels_page.dart';
import 'package:jigsawpuzzle/pages/event_levels_page.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';
import 'package:jigsawpuzzle/services/sound_service.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:jigsawpuzzle/widgets/adaptive_hero_banner.dart';
import 'package:jigsawpuzzle/widgets/app_cached_image.dart';
import 'package:jigsawpuzzle/widgets/download_badge.dart';
import 'package:jigsawpuzzle/widgets/game_toast.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

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
  final AppContent _content = AppContent.instance;

  @override
  void initState() {
    super.initState();
    _content.contentUpdateNotifier.addListener(_onUpdated);
    _content.collections.updateNotifier.addListener(_onUpdated);
    _content.events.updateNotifier.addListener(_onUpdated);
    _content.events.progressNotifier.addListener(_onUpdated);
    LocaleService.instance.addListener(_onUpdated);
  }

  @override
  void dispose() {
    LocaleService.instance.removeListener(_onUpdated);
    _content.contentUpdateNotifier.removeListener(_onUpdated);
    _content.collections.updateNotifier.removeListener(_onUpdated);
    _content.events.updateNotifier.removeListener(_onUpdated);
    _content.events.progressNotifier.removeListener(_onUpdated);
    super.dispose();
  }

  void _onUpdated() {
    if (mounted) setState(() {});
  }

  Future<void> _startDownloadEvent(PuzzleEventItem item) async {
    // P0-2（红线 R1）：已下架且本地无数据者禁止下载；本地已有数据仍可玩，无需下载。
    if (item.isDelisted && !_content.manager.isEventDownloaded(item)) {
      if (mounted) {
        GameToast.show(context, message: t.collections.delistedCantDownload);
      }
      return;
    }
    SoundService.I.play(Sfx.tap);
    AppLogger.events.info(
      'Collections start download event id=${item.id} title=${item.displayTitle} isZip=${item.isZipType}',
    );
    try {
      final ok = await _content.events.ensureEventDownloaded(item);
      if (mounted) {
        if (ok) {
          AppLogger.events.info('Collections download event ok id=${item.id}');
          GameToast.show(
            context,
            icon: PhosphorIconsFill.checkCircle,
            message: t.collections.toastReady(title: item.displayTitle),
            type: GameToastType.success,
          );
        } else {
          AppLogger.events.warning(
            'Collections download event failed id=${item.id}',
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
        'Collections download event exception id=${item.id}',
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

  Future<void> _startDownload(PuzzleCollectionItem item) async {
    // P0-2（红线 R1）：已下架且本地无数据者禁止下载。
    if (item.isDelisted && !item.isLocalDownloaded) {
      if (mounted) {
        GameToast.show(context, message: t.collections.delistedCantDownload);
      }
      return;
    }
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
      // best-effort：记录后降级继续
      // ignore: avoid_catches_without_on_clauses
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

    final heroItems = visibleEvents.map((ev) {
      final isNew = ev.isNew;
      final isDownloaded = _content.manager.isEventDownloaded(ev);
      final isDownloading = _content.events.isDownloading(ev.id);
      final downloadProgress = _content.events.getDownloadProgress(ev.id);

      return HeroBannerItem(
        id: ev.id,
        title: ev.displayTitle,
        subtitle: ev.displayDesc.isNotEmpty
            ? ev.displayDesc
            : t.events.subFallback,
        imagePathOrUrl:
            ev.coverUrl ?? (ev.levels.isNotEmpty ? ev.levels.first : ''),
        badgeText: ev.isDelisted
            ? t.collections.delistedBadge
            : (isNew ? 'NEW' : t.events.badgeLimited),
        badgeEmoji: isNew ? '✨' : '🔥',
        badgeColor: isNew ? const Color(0xFFC97A2E) : const Color(0xFFD97706),
        topRightBadge: DownloadBadge(
          isDownloaded: isDownloaded,
          isDownloading: isDownloading,
          downloadProgress: downloadProgress,
          isZipType: ev.isZipType,
          displayFileSize: ev.displayFileSize,
        ),
        onTap: () {
          SoundService.I.play(Sfx.tap);
          // P0-2：已下架且本地无数据者禁用下载入口；已下载者仍可进入游玩。
          if (ev.isDelisted && !isDownloaded) {
            GameToast.show(
              context,
              message: t.collections.delistedCantDownload,
            );
            return;
          }
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
                message: t.collections.startDownload(title: ev.displayTitle),
              );
              unawaited(_startDownloadEvent(ev));
            }
            return;
          }

          unawaited(EventLevelsPage.open(context, ev));
        },
      );
    }).toList();

    return RefreshIndicator(
      onRefresh: () async => _content.syncAll(),
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
                    border: Border.all(color: palette.divider),
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
                      onPressed: () async => _content.syncAll(),
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
        var effectiveCount = col.totalCount;
        if (effectiveCount <= 0 && col.isLocalDownloaded) {
          effectiveCount = _content.manager.getCollectionLevels(col).length;
        }

        return InkWell(
          onTap: () {
            SoundService.I.play(Sfx.tap);
            // P0-2：已下架且本地无数据者禁用下载入口；已下载者仍可进入游玩。
            if (col.isDelisted && !col.isLocalDownloaded) {
              GameToast.show(
                context,
                message: t.collections.delistedCantDownload,
              );
              return;
            }
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
                );
              } else {
                GameToast.show(
                  context,
                  icon: PhosphorIconsRegular.downloadSimple,
                  message: t.collections.startDownload(title: col.title),
                );
                unawaited(_startDownload(col));
              }
              return;
            }

            // 已就绪（已下载或在线图集），方可进入关卡列表
            unawaited(CollectionLevelsPage.open(context, col));
          },
          borderRadius: BorderRadius.circular(14),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.divider),
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

                // 3. 左上角：NEW 角标 (与首页 Home 保持一致)
                if (col.isNew && !col.isDelisted)
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

                // P0-2：已下架角标
                if (col.isDelisted)
                  Positioned(
                    left: 0,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: const BoxDecoration(
                        color: Color(0xFF6B7280),
                        borderRadius: BorderRadius.only(
                          topRight: Radius.circular(4),
                          bottomRight: Radius.circular(4),
                        ),
                      ),
                      child: Text(
                        t.collections.delistedBadge,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),

                // 4. 右上角：下载状态/角标
                Positioned(
                  right: 8,
                  top: 8,
                  child: DownloadBadge(
                    isDownloaded: col.isLocalDownloaded,
                    isDownloading: isDownloading,
                    downloadProgress: downloadProgress,
                    isZipType: col.isZipType,
                    displayFileSize: col.displayFileSize,
                  ),
                ),

                // 5. 底部图集标题与关卡数 (关卡数在标题上方一行，标题独占整行完整显示)
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 8,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (effectiveCount > 0) ...[
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
                        const SizedBox(height: 2),
                      ],
                      Text(
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
}
