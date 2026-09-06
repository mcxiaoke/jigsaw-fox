import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/resume_helper.dart';
import '../data/snapshot_store.dart';
import '../logic/cache/level_image_resolver.dart';
import '../logic/content/app_content.dart';
import '../logic/content/models/puzzle_collection_item.dart';
import '../logic/content/models/puzzle_level_item.dart';
import '../logic/puzzle_model.dart';
import '../services/app_logger.dart';
import '../theme/app_palette.dart';
import '../theme/app_text_styles.dart';
import '../widgets/choose_difficulty_sheet.dart';
import '../widgets/game_toast.dart';
import '../widgets/lazy_level_image.dart';
import 'game_page.dart';

/// 图集详情关卡列表页面 (展示图集内所有关卡纯图 Card Grid，无 tag 过滤)
class CollectionLevelsPage extends StatefulWidget {
  const CollectionLevelsPage({super.key, required this.collection});

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
  final _content = AppContent.instance.manager;
  bool _isLoading = false;
  late PuzzleCollectionItem _currentCollection;
  List<PuzzleLevelItem> _levels = [];

  @override
  void initState() {
    super.initState();
    _currentCollection = widget.collection;
    _loadLevels();
  }

  Future<void> _loadLevels() async {
    setState(() => _isLoading = true);
    try {
      await _content.ensureCollectionDownloaded(_currentCollection);
      _levels = _content.getCollectionLevels(_currentCollection);
      AppLogger.content.info(
        'CollectionLevels loaded id=${_currentCollection.id} count=${_levels.length}',
      );
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
        title: Text('清理「${_currentCollection.title}」'),
        content: Text(
          '确定要清理已下载的本地资源吗？\n清理后可释放 ${_currentCollection.displayFileSize} 磁盘空间。您随时可以重新下载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: palette.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认清理'),
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
            message: '已释放图集本地存储空间',
            type: GameToastType.success,
          );
          Navigator.of(context).pop();
        } else {
          GameToast.show(
            context,
            icon: PhosphorIconsRegular.warning,
            message: '清理失败，请重试',
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
        throw Exception('关卡图片下载失败，请检查网络后重试');
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
          message: '图片加载失败: $e',
          type: GameToastType.error,
        );
      }
      return;
    }

    if (imgBytes == null || !mounted) return;

    final canonicalId = level.id;
    final progress = await ResumeHelper.loadProgress(canonicalId);
    if (!mounted) return;
    final fallbackDiff = PuzzleDifficulty.presets.firstWhere(
      (d) => SnapshotStore.difficultyKeyFor(d) == progress.activeDifficultyKey,
      orElse: () => const PuzzleDifficulty(
        label: '4 × 4 (16 块)',
        rows: 4,
        cols: 4,
        recommended: true,
      ),
    );

    // 1. 若有残局快照，优先进入断点续玩流程
    if (progress.hasSnapshot) {
      final handled = await ResumeHelper.tryHandleResumeFlow(
        context: context,
        canonicalId: canonicalId,
        fallbackDifficulty: fallbackDiff,
        isCompleted: progress.isCompleted,
        title: '${_currentCollection.title} · 第 $index 关',
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
      isUnlocked: true,
      title: '${_currentCollection.title} · 第 $index 关',
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
              initialSnapshotJson: null,
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
              packTitle: _currentCollection.title,
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
          _currentCollection.title,
          style: styles.h3.copyWith(fontSize: 17),
        ),
        actions: [
          if (_currentCollection.isLocalDownloaded &&
              _currentCollection.isZipType)
            IconButton(
              tooltip: '释放图集存储空间',
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
                    '暂无可用关卡',
                    style: styles.body.copyWith(color: palette.secondaryText),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: palette.brand,
                      foregroundColor: palette.surface,
                    ),
                    onPressed: _loadLevels,
                    child: const Text('重试加载'),
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
                        border: Border.all(color: palette.divider, width: 1),
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
                                  '共 ${_levels.length} 个关卡'
                                  '${_currentCollection.displayFileSize.isNotEmpty ? ' · ${_currentCollection.displayFileSize}' : ''}',
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
                          childAspectRatio: 1.0,
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

        return InkWell(
          onTap: () => _openLevel(level, index),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              color: palette.surfaceContainer,
              borderRadius: BorderRadius.circular(12),
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
                LazyLevelImage(level: level, fit: BoxFit.cover),
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
                // 关卡编号角标
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '第 $index 关',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
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
