import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../data/favorite_store.dart';
import '../../data/game_repository.dart';
import '../../data/models/downloaded_image_item.dart';
import '../../data/progress_store.dart';
import '../../data/resume_helper.dart';
import '../../data/snapshot_store.dart';
import '../../logic/catalog_index.dart';
import '../../logic/content/app_content.dart';
import '../../logic/download_manager.dart';
import '../../logic/puzzle_model.dart';
import '../../logic/unified_puzzle_resolver.dart';
import '../../services/sound_service.dart';
import '../../services/webview_service.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_text_styles.dart';
import '../../widgets/app_cached_image.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../../widgets/downloaded_drawer_sheet.dart';
import '../../widgets/game_toast.dart';
import '../crop_puzzle_page.dart';
import '../game_page.dart';
import '../import_pack_page.dart';
import '../online_image_picker_page.dart';

/// 全新“我的”中心 Tab 视图（聚合进行中、收藏、已完成与自制拼图）
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
  List<UnifiedPuzzleCardData> _customList = [];
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    DownloadManager.instance.init();
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

  Future<Uint8List> _resolveImageBytes(UnifiedPuzzleCardData card) async {
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
        final uri = Uri.tryParse(card.imagePathOrUrl);
        if (uri != null) {
          final client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 8)
            ..idleTimeout = const Duration(seconds: 8);
          try {
            final req = await client.getUrl(uri);
            final res = await req.close().timeout(const Duration(seconds: 15));
            if (res.statusCode == 200) {
              // chunked 场景 contentLength == -1，需流式限长
              if (res.contentLength > maxBytes) {
                throw Exception('image too large ${res.contentLength}');
              }
              final bytes = await consolidateHttpClientResponseBytes(
                res,
              ).timeout(const Duration(seconds: 20));
              if (bytes.length > maxBytes) {
                throw Exception('image too large ${bytes.length}');
              }
              // contentLength == -1 且超长已被上一行拦截
              if (res.contentLength == -1 && bytes.length > maxBytes) {
                throw Exception('image chunked too large');
              }
              return bytes;
            }
          } finally {
            client.close(force: true);
          }
        }
      }
    } catch (_) {}
    // 兜底图
    final data = await rootBundle.load('assets/samples/animal_01.webp');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
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
          sourceType: 'gallery',
          sourcePlatform: '本地相册',
          sourceUrl: item.sourceUrl,
        );
        if (result != null && mounted) {
          _loadAllData();
        }
      } else {
        if (mounted) {
          GameToast.show(
            context,
            icon: PhosphorIconsFill.archive,
            message: '已成功导入 ${imported.length} 张图片到素材库',
            type: GameToastType.success,
          );
          _loadAllData();
        }
      }
    } catch (e) {
      if (mounted) {
        GameToast.show(
          context,
          icon: PhosphorIconsRegular.warning,
          message: '选择图片失败: $e',
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
                  labelColor: palette.brand,
                  unselectedLabelColor: palette.secondaryText,
                  indicatorColor: palette.brand,
                  indicatorWeight: 2.5,
                  labelStyle: styles.bodyBold.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                  unselectedLabelStyle: styles.body.copyWith(fontSize: 14),
                  tabs: [
                    Tab(text: '进行中 (${_inProgressList.length})'),
                    Tab(text: '收藏 (${_favoritesList.length})'),
                    Tab(text: '已完成 (${_completedList.length})'),
                    Tab(text: '自制 (${_customList.length})'),
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
                  // 4. 自制子 Tab
                  _buildGridTab(
                    items: _customList,
                    emptyEmoji: '🎨',
                    emptyTitle: '暂无自制拼图',
                    emptySub: '点击上方「相册选图」等工具，打造专属自制拼图！',
                    actionButtonText: '相册选图制作',
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
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        children: [
          // 1. 相册选图 (主要高频入口，微高亮)
          Expanded(
            child: _buildTopActionCard(
              title: '相册选图',
              subtitle: '本地自制',
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
              title: '在线搜图',
              subtitle: '海量图库',
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
                    message: '当前系统未安装 WebView2 运行时，无法使用在线搜图',
                    type: GameToastType.warning,
                  );
                  return;
                }
                await OnlineImagePickerPage.push(context);
                _loadAllData();
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
                  title: '素材库',
                  subtitle: count > 0 ? '$count 张' : '历史图片',
                  icon: PhosphorIconsFill.archive,
                  iconColor: const Color(0xFF6366F1),
                  isPrimary: false,
                  palette: palette,
                  styles: styles,
                  onTap: () async {
                    await DownloadedDrawerSheet.show(context);
                    _loadAllData();
                  },
                );
              },
            ),
          ),
          const SizedBox(width: 8),

          // 4. 导入图包 (ZIP)
          Expanded(
            child: _buildTopActionCard(
              title: '导入图包',
              subtitle: 'ZIP扩展',
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
                _loadAllData();
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
                Text(
                  title,
                  style: styles.bodyBold.copyWith(
                    fontSize: 12,
                    color: isPrimary ? palette.brand : palette.primaryText,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  style: styles.caption.copyWith(
                    fontSize: 10,
                    color: palette.secondaryText,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
              '${card.progressPercent}%',
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
    return Container(
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
