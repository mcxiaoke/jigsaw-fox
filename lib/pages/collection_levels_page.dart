import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jigsawpuzzle/data/resume_helper.dart';
import 'package:jigsawpuzzle/data/snapshot_store.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/cache/level_image_resolver.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/content/content_manager.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_collection_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/logic/puzzle_model.dart';
import 'package:jigsawpuzzle/pages/game_page.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/services/recommend_service.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:jigsawpuzzle/widgets/choose_difficulty_sheet.dart';
import 'package:jigsawpuzzle/widgets/game_toast.dart';
import 'package:jigsawpuzzle/widgets/lazy_level_image.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// 图集详情关卡列表页面 (展示图集内所有关卡纯图 Card Grid，无 tag 过滤)
class CollectionLevelsPage extends StatefulWidget {
  const CollectionLevelsPage({required this.collection, super.key});

  final PuzzleCollectionItem collection;

  static Future<void> open(
    BuildContext context,
    PuzzleCollectionItem collection,
  ) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CollectionLevelsPage(collection: collection),
      ),
    );
  }

  @override
  State<CollectionLevelsPage> createState() => _CollectionLevelsPageState();
}

class _CollectionLevelsPageState extends State<CollectionLevelsPage> {
  final ContentManager _content = AppContent.instance.manager;
  bool _isLoading = false;
  late PuzzleCollectionItem _currentCollection;
  List<PuzzleLevelItem> _levels = [];

  @override
  void initState() {
    super.initState();
    _currentCollection = widget.collection;
    unawaited(_loadLevels());
  }

  Future<void> _loadLevels() async {
    setState(() => _isLoading = true);
    try {
      await _content.ensureCollectionDownloaded(_currentCollection);
      _levels = _content.getCollectionLevels(_currentCollection);
      AppLogger.content.info(
        'CollectionLevels loaded id=${_currentCollection.id} count=${_levels.length}',
      );
      // best-effort：记录后降级继续
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      AppLogger.content.warning(
        'CollectionLevels load failed id=${_currentCollection.id}',
        e,
        st,
      );
      _levels = [];
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _confirmDelete() async {
    final palette = AppPalette.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.collections.clearTitle(title: _currentCollection.displayTitle),
        ),
        content: Text(
          t.collections.clearDesc(size: _currentCollection.displayFileSize),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.common.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: palette.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.collections.confirmClear),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final ok = await _content.deleteDownloadedCollection(
        _currentCollection.id,
      );
      if (mounted) {
        if (ok) {
          GameToast.show(
            context,
            icon: PhosphorIconsRegular.trash,
            message: t.collections.toastCleared,
            type: GameToastType.success,
          );
          Navigator.of(context).pop();
        } else {
          GameToast.show(
            context,
            icon: PhosphorIconsRegular.warning,
            message: t.collections.toastClearFailed,
            type: GameToastType.error,
          );
        }
      }
    }
  }

  Future<void> _openLevel(PuzzleLevelItem level, int index) async {
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
      AppLogger.content.warning(
        'CollectionLevels openLevel image fail id=${level.id}',
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

    if (imgBytes == null || !mounted) return;

    final canonicalId = level.id;
    final progress = await ResumeHelper.loadProgress(canonicalId);
    if (!mounted) return;
    // 历史难度优先（该图玩过/有存档）；新图回退全局推荐档（面板按实际比例校正）
    final fallbackDiff = PuzzleDifficulty.presets.firstWhere(
      (d) => SnapshotStore.difficultyKeyFor(d) == progress.activeDifficultyKey,
      orElse: () => RecommendService.instance.squareDifficulty,
    );

    // 1. 若有残局快照，优先进入断点续玩流程
    if (progress.hasSnapshot) {
      final handled = await ResumeHelper.tryHandleResumeFlow(
        context: context,
        canonicalId: canonicalId,
        fallbackDifficulty: fallbackDiff,
        title: t.levels.titleOf(
          title: _currentCollection.displayTitle,
          index: index,
        ),
        imageBytes: imgBytes,
        onClearRepo: (dkey) async {
          await ResumeHelper.clearResume(canonicalId, dkey);
          if (mounted) setState(() {});
        },
        onPushGame: (diff, jsonStr) async {
          if (!mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => GamePage(
                imageBytes: imgBytes!,
                difficulty: diff,
                canonicalId: canonicalId,
                packTitle: _currentCollection.title,
                initialSnapshotJson: jsonStr,
              ),
            ),
          );
          if (mounted) setState(() {});
        },
        onCancelled: () {
          if (mounted) setState(() {});
        },
      );
      if (handled) return;
    }

    if (!mounted) return;

    // 2. 无残局或点重新选择，弹出难度选择面板
    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: fallbackDiff,
      completedPieceCounts: progress.completedPieceCounts.toSet(),
      canonicalId: canonicalId,
      title: t.levels.titleOf(
        title: _currentCollection.displayTitle,
        index: index,
      ),
      sourcePlatform: _currentCollection.displayTypeLabel,
      savedProgressPercent: progress.hasSnapshot
          ? progress.progressPercent
          : null,
      onResetProgress: () async {
        if (progress.activeDifficultyKey.isNotEmpty) {
          await ResumeHelper.clearResume(
            canonicalId,
            progress.activeDifficultyKey,
          );
        }
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes!,
              difficulty: fallbackDiff,
              canonicalId: canonicalId,
              packTitle: _currentCollection.title,
            ),
          ),
        );
        if (mounted) setState(() {});
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
              packTitle: _currentCollection.displayTitle,
              initialSnapshotJson: snapJson,
            ),
          ),
        );
        if (mounted) setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);

    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(
        backgroundColor: palette.surface,
        foregroundColor: palette.primaryText,
        elevation: 0.5,
        scrolledUnderElevation: 0.5,
        title: Text(
          _currentCollection.displayTitle,
          style: styles.h3.copyWith(fontSize: 17),
        ),
        actions: [
          if (_currentCollection.isLocalDownloaded &&
              _currentCollection.isZipType)
            IconButton(
              tooltip: t.collections.freeTooltip,
              icon: Icon(
                PhosphorIconsRegular.trash,
                color: palette.secondaryText,
              ),
              onPressed: _confirmDelete,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: palette.brand))
          : _levels.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    PhosphorIconsRegular.empty,
                    size: 48,
                    color: palette.disabledText,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    t.levels.empty,
                    style: styles.body.copyWith(color: palette.secondaryText),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: palette.brand,
                      foregroundColor: palette.surface,
                    ),
                    onPressed: _loadLevels,
                    child: Text(t.levels.retryLoad),
                  ),
                ],
              ),
            )
          : CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: [
                // 图集描述与统计卡片 (如有)
                if (_currentCollection.desc.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Container(
                      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: palette.surfaceContainer,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: palette.divider),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            PhosphorIconsFill.info,
                            color: palette.brand,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _currentCollection.desc,
                                  style: styles.body.copyWith(
                                    height: 1.4,
                                    fontSize: 13.5,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  _currentCollection.displayFileSize.isNotEmpty
                                      ? t.levels.countWithSize(
                                          count: _levels.length,
                                          size: _currentCollection
                                              .displayFileSize,
                                        )
                                      : t.levels.countLabel(
                                          count: _levels.length,
                                        ),
                                  style: styles.caption.copyWith(
                                    fontSize: 11.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // 关卡 Grid (与首页一致的 Card Grid，无 tag 过滤)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 200,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final level = _levels[index];
                      return _buildLevelCard(level, index + 1, palette, styles);
                    }, childCount: _levels.length),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
    );
  }

  Widget _buildLevelCard(
    PuzzleLevelItem level,
    int index,
    AppPalette palette,
    AppTextStyles styles,
  ) {
    return FutureBuilder(
      future: ResumeHelper.loadProgress(level.id),
      builder: (context, snapshot) {
        final progress = snapshot.data;
        final isCompleted = progress?.isCompleted == true;
        final percent = progress?.progressPercent ?? 0;
        final isNew = level.isNew && !isCompleted;

        return InkWell(
          onTap: () => _openLevel(level, index),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              color: palette.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
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
                LazyLevelImage(level: level),
                // 渐变保护
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.black.withValues(alpha: 0.45),
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.55),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
                // NEW 角标 (与首页 Home 保持一致)
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
                // 右上角状态 (完成/进度)
                if (isCompleted)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.all(3.5),
                      decoration: const BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        PhosphorIconsBold.check,
                        color: Colors.white,
                        size: 11,
                      ),
                    ),
                  )
                else if (percent > 0)
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$percent%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
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
