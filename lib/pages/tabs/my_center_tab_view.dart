import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:jigsawpuzzle/data/favorite_store.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/data/models/downloaded_image_item.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/data/resume_helper.dart';
import 'package:jigsawpuzzle/data/snapshot_store.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/cache/level_image_resolver.dart';
import 'package:jigsawpuzzle/logic/cache/local_image_locator.dart';
import 'package:jigsawpuzzle/logic/catalog_index.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/download_manager.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/logic/source_tag.dart';
import 'package:jigsawpuzzle/logic/unified_puzzle_resolver.dart';
import 'package:jigsawpuzzle/pages/crop_puzzle_page.dart';
import 'package:jigsawpuzzle/pages/game_page.dart';
import 'package:jigsawpuzzle/pages/import_pack_page.dart';
import 'package:jigsawpuzzle/pages/online_image_picker_page.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';
import 'package:jigsawpuzzle/services/recommend_service.dart';
import 'package:jigsawpuzzle/services/sound_service.dart';
import 'package:jigsawpuzzle/services/webview_service.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:jigsawpuzzle/widgets/app_cached_image.dart';
import 'package:jigsawpuzzle/widgets/choose_difficulty_sheet.dart';
import 'package:jigsawpuzzle/widgets/downloaded_drawer_sheet.dart';
import 'package:jigsawpuzzle/widgets/game_toast.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// My Center Tab view (aggregates In Progress, Favorites, Completed and Custom puzzles)
class MyCenterTabView extends StatefulWidget {
  const MyCenterTabView({super.key, this.onGoExplore, this.isActive = true});

  /// Callback when tapping "Explore Gallery" (switch back to Home Tab 0)
  final VoidCallback? onGoExplore;

  /// Whether current Tab is active/visible (triggers incremental refresh on IndexedStack switch)
  final bool isActive;

  @override
  State<MyCenterTabView> createState() => _MyCenterTabViewState();
}

class _MyCenterTabViewState extends State<MyCenterTabView> {
  bool _isLoading = true;
  List<UnifiedPuzzleCardData> _inProgressList = [];
  List<UnifiedPuzzleCardData> _favoritesList = [];
  List<UnifiedPuzzleCardData> _completedList = [];
  List<UnifiedPuzzleCardData> _customList = [];
  Timer? _debounceTimer;
  // P2-1：重载代次标记，防止并发多次异步查询交错时旧数据覆盖新数据。
  int _reloadSeq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(DownloadManager.instance.init());
    unawaited(_loadAllData());
    ProgressStore.instance.progressNotifier.addListener(_onExternalChanged);
    FavoriteStore.instance.idsNotifier.addListener(_onExternalChanged);
    GameRepository.instance.customPuzzlesNotifier.addListener(
      _onContentChanged,
    );
    AppContent.instance.contentUpdateNotifier.addListener(_onContentChanged);
    LocaleService.instance.addListener(_onLocaleChanged);
  }

  void _onLocaleChanged() {
    UnifiedCatalogIndex.invalidate();
    unawaited(_loadAllData());
    if (mounted) setState(() {});
  }

  void _onContentChanged() {
    UnifiedCatalogIndex.invalidate();
    _onExternalChanged();
  }

  @override
  void didUpdateWidget(covariant MyCenterTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      unawaited(_loadAllData());
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    LocaleService.instance.removeListener(_onLocaleChanged);
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
        unawaited(_loadAllData());
      }
    });
  }

  Future<void> _loadAllData() async {
    // P0-3 主方案：入口显式失效统一索引，重建覆盖本会话新下载的关卡元数据。
    // Tab 切换 / 下拉刷新 / 外部通知三条路径统一自愈，不依赖新增通知链路。
    // （P1-1 已先行落地，污染条目不会经重建扩散到「我的」页。）
    // P2-1：代次保护——异步间隙中若有更新的调用进入，本次结果直接丢弃。
    final seq = ++_reloadSeq;
    UnifiedCatalogIndex.invalidate();
    final catalogIndex = await UnifiedCatalogIndex.current();
    if (seq != _reloadSeq) return;
    final progressMap = await ProgressStore.instance.loadAllProgress();
    if (seq != _reloadSeq) return;
    final favoriteEntries = await FavoriteStore.instance
        .favoritesSortedByTime();
    if (seq != _reloadSeq) return;
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

    // 4. 自制关卡列表 (从 GameRepository.instance.customPuzzles 装配)
    final custom = <UnifiedPuzzleCardData>[];
    for (final cp in GameRepository.instance.customPuzzles) {
      final cid = GameRepository.canonicalForCustom(cp.id);
      final p = progressMap[cid];
      final card = resolver.resolve(canonicalId: cid, progress: p);
      custom.add(card);
    }
    // 排序：按最近游玩/最后保存时间倒序
    custom.sort((a, b) {
      final ta =
          a.lastPlayedAt ??
          a.lastSavedAt ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final tb =
          b.lastPlayedAt ??
          b.lastSavedAt ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return tb.compareTo(ta);
    });

    AppLogger.ui.info(
      'MyCenter loadAllData done inProgress=${inProgress.length} completed=${completed.length} favorites=${favorites.length} custom=${custom.length}',
    );
    // P2-1：setState 前再确认代次，旧查询结果不得覆盖新数据。
    if (seq != _reloadSeq) return;
    if (mounted) {
      setState(() {
        _inProgressList = inProgress;
        _completedList = completed;
        _favoritesList = favorites;
        _customList = custom;
        _isLoading = false;
      });
    }
  }

  /// P0-1：失败一律返回 null，由调用方显式提示。禁止以示例图/占位图
  /// 替代进入关卡（开发期遗留兜底已删除）。
  Future<Uint8List?> _resolveImageBytes(UnifiedPuzzleCardData card) async {
    const maxBytes = 20 * 1024 * 1024;
    try {
      if (card.isLocalFile) {
        final file = File(card.imagePathOrUrl);
        if (file.existsSync()) {
          final len = await file.length();
          if (len <= maxBytes) return await file.readAsBytes();
        }
      }
      if (card.imagePathOrUrl.startsWith('assets/')) {
        final data = await rootBundle.load(card.imagePathOrUrl);
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      }
      if (card.imagePathOrUrl.startsWith('http://') ||
          card.imagePathOrUrl.startsWith('https://')) {
        // P1-3：先查 LevelImageResolver 本地缓存，命中直接读盘（离线可玩，
        // 并复用 Single-Flight 去重）；未命中再单飞下载落盘后读。
        final url = card.imagePathOrUrl;
        try {
          final cached = LevelImageResolver.instance.getUrlLocalPathIfAvailable(
            url,
          );
          if (cached != null) {
            final file = File(cached);
            if (file.existsSync()) {
              final len = await file.length();
              if (len > 0 && len <= maxBytes) {
                return await file.readAsBytes();
              }
            }
          }
          final landed = await LevelImageResolver.instance.resolveUrlLocalPath(
            url,
          );
          if (landed.isNotEmpty) {
            final file = File(landed);
            if (file.existsSync()) {
              final len = await file.length();
              if (len > 0 && len <= maxBytes) {
                return await file.readAsBytes();
              }
            }
          }
          // best-effort：记录后降级继续
          // ignore: avoid_catches_without_on_clauses
        } catch (e, st) {
          AppLogger.ui.warning(
            'MyCenter resolver cache lookup failed cid=${card.canonicalId}',
            e,
            st,
          );
        }
        // P1-3 修正（⑤）：不再回落到裸 HttpClient。上一级
        // `resolveUrlLocalPath` 已按 Single-Flight 落盘并校验落盘结果；
        // 重复请求同一 URL 既不会落盘（下次仍需重下），又会让离线用户
        // 额外多等 8s（连接超时）+15s+20s 才看到提示，纯负收益。
        AppLogger.ui.warning(
          'MyCenter resolve bytes failed (no local cache) '
          'cid=${card.canonicalId} url=${AppLogger.sanitizeUrl(url)}',
        );
      }
      // best-effort：记录后降级继续
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      AppLogger.ui.warning(
        'MyCenter resolveImageBytes fallback cid=${card.canonicalId} src=${AppLogger.sanitizePath(card.imagePathOrUrl)}',
        e,
        st,
      );
      return null;
    }
    // P0-1：所有失败分支返回 null，不再加载任何兜底示例图。
    return null;
  }

  /// P0-5：孤儿卡多级取图（只读，不删数据）。
  /// ① `LocalImageLocator` 按 canonicalId 直查本地已下载图片；
  /// ② 回落通用解析（含 Resolver 本地缓存 + 网络）。
  /// 全部落空返回 null（调用方 Toast 提示，不进游戏、不弹删除框）。
  Future<Uint8List?> _resolveOrphanImageBytes(
    UnifiedPuzzleCardData card,
  ) async {
    const maxBytes = 20 * 1024 * 1024;
    try {
      final located = LocalImageLocator.locate(card.canonicalId);
      if (located != null && located.isNotEmpty) {
        if (located.startsWith('assets/')) {
          try {
            final data = await rootBundle.load(located);
            return data.buffer.asUint8List(
              data.offsetInBytes,
              data.lengthInBytes,
            );
            // best-effort：清理/降级失败可静默
          } catch (_) {} // ignore: avoid_catches_without_on_clauses
        } else {
          final file = File(located);
          if (file.existsSync()) {
            final len = await file.length();
            if (len > 0 && len <= maxBytes) {
              return await file.readAsBytes();
            }
          }
        }
      }
      // best-effort：记录后降级继续
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      AppLogger.ui.warning(
        'MyCenter orphan locate failed cid=${card.canonicalId}',
        e,
        st,
      );
    }
    return _resolveImageBytes(card);
  }

  Future<void> _handleCardClick(UnifiedPuzzleCardData card) async {
    try {
      AppLogger.debug(
        AppLogger.ui,
        'MyCenter card click cid=${card.canonicalId} isOrphan=${card.isOrphan}',
      );
      // P0-5（红线 R2）：主点击永不弹删除对话框。孤儿卡先可玩——多级取图后
      // 走正常入局流程；确实无图才 Toast 提示。删除记录仅允许长按主动触发。
      final Uint8List? imgBytes;
      if (card.isOrphan) {
        imgBytes = await _resolveOrphanImageBytes(card);
        if (!mounted) return;
        if (imgBytes == null) {
          GameToast.show(
            context,
            message: t.myCenter.toast.imageNotFound,
            type: GameToastType.warning,
          );
          return;
        }
      } else {
        imgBytes = await _resolveImageBytes(card);
        if (!mounted) return;
        // P0-1：图片不可用时显式提示且不进入游戏，禁止静默无响应。
        if (imgBytes == null) {
          GameToast.show(
            context,
            message: t.myCenter.toast.imageNotReady,
            type: GameToastType.warning,
          );
          return;
        }
      }

      await _enterGameWithBytes(card, imgBytes);
      // best-effort：记录后降级继续
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      // P0-1：点击链路整体兜底，严禁静默中断。
      AppLogger.ui.warning(
        'MyCenter handleCardClick failed cid=${card.canonicalId}',
        e,
        st,
      );
      if (mounted) {
        GameToast.show(
          context,
          message: t.myCenter.toast.openFailed,
          type: GameToastType.warning,
        );
      }
    }
  }

  /// 入局共用流程（正常卡与孤儿卡取图成功后均走此）：残局续玩 → 难度选择。
  Future<void> _enterGameWithBytes(
    UnifiedPuzzleCardData card,
    Uint8List imgBytes,
  ) async {
    if (card.hasActiveSnapshot) {
      final fallbackDiff = PuzzleDifficulty.presets.firstWhere(
        (d) => SnapshotStore.difficultyKeyFor(d) == card.activeDifficultyKey,
        orElse: () => RecommendService.instance.squareDifficulty,
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
          unawaited(_loadAllData());
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
          unawaited(_loadAllData());
        },
        onCancelled: () {
          if (mounted) unawaited(_loadAllData());
        },
      );
      if (handled) return;
    }

    // 2. 无快照或点“重选难度”，打开难度选择面板
    final initialDiff = PuzzleDifficulty.presets.firstWhere(
      (d) => SnapshotStore.difficultyKeyFor(d) == card.activeDifficultyKey,
      orElse: () => RecommendService.instance.squareDifficulty,
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
        unawaited(_loadAllData());
      },
    );
    unawaited(_loadAllData());
  }

  /// P0-5（红线 R2）：仅用户长按主动清理单条记录时调用。禁止在任何自动路径
  /// （初始化、同步、索引重建、点击）中调用。只删进度/快照/收藏记录，
  /// 不动已下载图片数据。
  Future<void> _cleanOrphan(UnifiedPuzzleCardData card) async {
    final tr = LocaleSettings.instance.currentTranslations;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.myCenter.orphanDialog.title),
        content: Text(tr.myCenter.orphanDialog.desc(title: card.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr.myCenter.orphanDialog.keep),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr.myCenter.orphanDialog.remove),
          ),
        ],
      ),
    );

    if (ok == true) {
      await ProgressStore.instance.delete(card.canonicalId);
      await SnapshotStore.instance.deleteAllFor(card.canonicalId);
      await FavoriteStore.instance.remove(card.canonicalId);
      unawaited(_loadAllData());
    }
  }

  Future<void> _createFromGallery() async {
    setState(() => _isLoading = true);
    try {
      final picker = ImagePicker();
      final files = await picker.pickMultiImage(imageQuality: 90);
      if (files.isEmpty) return;
      final imported = await DownloadManager.instance.importFromLocalFiles(
        files,
      );
      if (!mounted || imported.isEmpty) return;
      if (files.length == 1) {
        final item = imported.first;
        final file = File(item.localPath);
        final bytes = await file.readAsBytes();
        if (!mounted) return;
        final result = await CropPuzzlePage.push(
          context,
          bytes,
          sourceUrl: item.sourceUrl,
        );
        if (result != null && mounted) {
          unawaited(_loadAllData());
        }
      } else {
        if (mounted) {
          GameToast.show(
            context,
            icon: PhosphorIconsFill.archive,
            message: t.myCenter.toast.importSuccess(count: imported.length),
            type: GameToastType.success,
          );
          unawaited(_loadAllData());
        }
      }
      // best-effort：失败降级，不阻断主流程
      // ignore: avoid_catches_without_on_clauses
    } catch (e) {
      if (mounted) {
        GameToast.show(
          context,
          icon: PhosphorIconsRegular.warning,
          message: t.myCenter.toast.importFailed(error: '$e'),
          type: GameToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final tr = LocaleSettings.instance.currentTranslations;

    return DefaultTabController(
      length: 4,
      child: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) {
          return [
            // 顶部 4 大创作入口 (随列表滚动向上收起)
            SliverToBoxAdapter(child: _buildTopActionsRow(palette, styles)),
            // 顶层子 Tab 切换栏 (吸顶常驻)
            SliverPersistentHeader(
              pinned: true,
              delegate: _PinnedTabBarDelegate(
                tabBar: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.center,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 10),
                  labelColor: palette.brand,
                  unselectedLabelColor: palette.secondaryText,
                  indicatorColor: palette.brand,
                  indicatorWeight: 2.5,
                  labelStyle: styles.bodyBold.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                  unselectedLabelStyle: styles.body.copyWith(fontSize: 13),
                  tabs: [
                    Tab(
                      text: tr.myCenter.tabs.inProgress(
                        count: _inProgressList.length,
                      ),
                    ),
                    Tab(
                      text: tr.myCenter.tabs.favorites(
                        count: _favoritesList.length,
                      ),
                    ),
                    Tab(
                      text: tr.myCenter.tabs.completed(
                        count: _completedList.length,
                      ),
                    ),
                    Tab(
                      text: tr.myCenter.tabs.custom(count: _customList.length),
                    ),
                  ],
                ),
                backgroundColor: palette.surface,
              ),
            ),
          ];
        },
        // Tab 视图内容区
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  // 1. In Progress sub-tab
                  _buildGridTab(
                    items: _inProgressList,
                    emptyEmoji: '🧩',
                    emptyTitle: tr.myCenter.empty.inProgressTitle,
                    emptySub: tr.myCenter.empty.inProgressSub,
                    actionButtonText: tr.myCenter.empty.goExplore,
                    onAction: widget.onGoExplore,
                    palette: palette,
                    styles: styles,
                    tabType: _MyTabType.inProgress,
                  ),
                  // 2. Favorites sub-tab
                  _buildGridTab(
                    items: _favoritesList,
                    emptyEmoji: '❤️',
                    emptyTitle: tr.myCenter.empty.favoritesTitle,
                    emptySub: tr.myCenter.empty.favoritesSub,
                    palette: palette,
                    styles: styles,
                    tabType: _MyTabType.favorites,
                  ),
                  // 3. Completed sub-tab
                  _buildGridTab(
                    items: _completedList,
                    emptyEmoji: '🏆',
                    emptyTitle: tr.myCenter.empty.completedTitle,
                    emptySub: tr.myCenter.empty.completedSub,
                    palette: palette,
                    styles: styles,
                    tabType: _MyTabType.completed,
                  ),
                  // 4. Custom sub-tab
                  _buildGridTab(
                    items: _customList,
                    emptyEmoji: '🎨',
                    emptyTitle: tr.myCenter.empty.customTitle,
                    emptySub: tr.myCenter.empty.customSub,
                    actionButtonText: tr.myCenter.empty.create,
                    onAction: _createFromGallery,
                    palette: palette,
                    styles: styles,
                    tabType: _MyTabType.custom,
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildTopActionsRow(AppPalette palette, AppTextStyles styles) {
    final tr = LocaleSettings.instance.currentTranslations;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        children: [
          // 1. Gallery (primary highlight)
          Expanded(
            child: _buildTopActionCard(
              title: tr.myCenter.topActions.gallery,
              subtitle: tr.myCenter.topActions.gallerySub,
              icon: PhosphorIconsFill.image,
              iconColor: palette.brand,
              isPrimary: true,
              palette: palette,
              styles: styles,
              onTap: _createFromGallery,
            ),
          ),
          const SizedBox(width: 8),

          // 2. 在线搜图 (必应/网络图片)
          Expanded(
            child: _buildTopActionCard(
              title: tr.myCenter.topActions.online,
              subtitle: tr.myCenter.topActions.onlineSub,
              icon: PhosphorIconsFill.globeHemisphereWest,
              iconColor: palette.success,
              isPrimary: false,
              palette: palette,
              styles: styles,
              onTap: () async {
                if (!WebViewService.isOnlineSearchAvailable) {
                  GameToast.show(
                    context,
                    icon: PhosphorIconsRegular.warningCircle,
                    message: t.myCenter.toast.webviewMissing,
                    type: GameToastType.warning,
                  );
                  return;
                }
                await OnlineImagePickerPage.push(context);
                unawaited(_loadAllData());
              },
            ),
          ),
          const SizedBox(width: 8),

          // 3. 素材库
          Expanded(
            child: ValueListenableBuilder<List<DownloadedImageItem>>(
              valueListenable: DownloadManager.instance.itemsNotifier,
              builder: (context, items, _) {
                final count = items.length;
                return _buildTopActionCard(
                  title: tr.myCenter.topActions.archive,
                  subtitle: tr.myCenter.topActions.archiveSub(count: count),
                  icon: PhosphorIconsFill.archive,
                  iconColor: const Color(0xFF6366F1),
                  isPrimary: false,
                  palette: palette,
                  styles: styles,
                  onTap: () async {
                    await DownloadedDrawerSheet.show(context);
                    unawaited(_loadAllData());
                  },
                );
              },
            ),
          ),
          const SizedBox(width: 8),

          // 4. 导入图包 (ZIP)
          Expanded(
            child: _buildTopActionCard(
              title: tr.myCenter.topActions.import,
              subtitle: tr.myCenter.topActions.importSub,
              icon: PhosphorIconsFill.folderSimplePlus,
              iconColor: const Color(0xFFEC4899),
              isPrimary: false,
              palette: palette,
              styles: styles,
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ImportPackPage(),
                  ),
                );
                unawaited(_loadAllData());
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopActionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required bool isPrimary,
    required AppPalette palette,
    required AppTextStyles styles,
    required VoidCallback onTap,
  }) {
    return Container(
      height: 80,
      decoration: BoxDecoration(
        color: isPrimary
            ? palette.brand.withValues(alpha: 0.08)
            : palette.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isPrimary
              ? palette.brand.withValues(alpha: 0.3)
              : palette.divider,
          width: isPrimary ? 1.2 : 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 4,
            offset: const Offset(0, 1.5),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            SoundService.I.play(Sfx.tap);
            onTap();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(height: 3),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    title,
                    style: styles.bodyBold.copyWith(
                      fontSize: 12,
                      color: isPrimary ? palette.brand : palette.primaryText,
                    ),
                    maxLines: 1,
                  ),
                ),
                const SizedBox(height: 1),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    subtitle,
                    style: styles.caption.copyWith(
                      fontSize: 10,
                      color: palette.secondaryText,
                    ),
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGridTab({
    required List<UnifiedPuzzleCardData> items,
    required String emptyEmoji,
    required String emptyTitle,
    required String emptySub,
    required AppPalette palette,
    required AppTextStyles styles,
    required _MyTabType tabType,
    String? actionButtonText,
    VoidCallback? onAction,
  }) {
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadAllData,
        color: palette.brand,
        child: ListView(
          key: PageStorageKey<String>('my_empty_${tabType.name}'),
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
                        icon: Icon(
                          tabType == _MyTabType.custom
                              ? PhosphorIconsRegular.image
                              : PhosphorIconsRegular.compass,
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
        key: PageStorageKey<String>('my_grid_${tabType.name}'),
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
    final tr = LocaleSettings.instance.currentTranslations;
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
                    card.isOrphan
                        ? t.myCenter.card.orphan
                        : SourceTag.localize(card.sourceLabel),
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
                    if (card.title.isNotEmpty) ...[
                      Text(
                        card.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 4),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            card.isOrphan
                                ? tr.myCenter.card.orphanDesc
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
                            tr.myCenter.card.progress(
                              percent: card.progressPercent,
                            ),
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
      );
    }
    return ColoredBox(
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
    final tr = LocaleSettings.instance.currentTranslations;
    if (card.isOrphan) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          tr.myCenter.card.orphan,
          style: const TextStyle(color: Colors.white70, fontSize: 10),
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
                  '${tr.myCenter.card.retry} · ',
                  style: TextStyle(
                    color: palette.brandLight,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
              Text(
                tr.myCenter.card.progress(percent: card.progressPercent),
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
            unawaited(_loadAllData());
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

      case _MyTabType.custom:
        if (card.isCompleted) {
          return Container(
            padding: const EdgeInsets.all(4),
            decoration: const BoxDecoration(
              color: Colors.green,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              PhosphorIconsBold.check,
              color: Colors.white,
              size: 12,
            ),
          );
        } else if (card.progressPercent > 0) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              tr.myCenter.card.progress(percent: card.progressPercent),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          );
        }
        return const SizedBox.shrink();
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

enum _MyTabType { inProgress, favorites, completed, custom }

class _PinnedTabBarDelegate extends SliverPersistentHeaderDelegate {
  _PinnedTabBarDelegate({required this.tabBar, required this.backgroundColor});

  final TabBar tabBar;
  final Color backgroundColor;

  @override
  double get minExtent => tabBar.preferredSize.height + 1.0;

  @override
  double get maxExtent => tabBar.preferredSize.height + 1.0;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ColoredBox(
      color: backgroundColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [tabBar, const Divider(height: 1, thickness: 0.8)],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _PinnedTabBarDelegate oldDelegate) {
    return oldDelegate.tabBar != tabBar ||
        oldDelegate.backgroundColor != backgroundColor;
  }
}
