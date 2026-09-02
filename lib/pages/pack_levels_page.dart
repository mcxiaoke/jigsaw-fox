import 'dart:io';
import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import '../data/game_repository.dart';
import '../data/resume_helper.dart';
import '../data/snapshot_store.dart';
import '../logic/content/app_content.dart';
import '../logic/content/models/puzzle_level_item.dart';
import '../logic/content/models/puzzle_pack_item.dart';
import '../logic/puzzle_model.dart';
import '../theme/app_palette.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_cached_image.dart';
import '../widgets/choose_difficulty_sheet.dart';
import '../widgets/game_toast.dart';
import '../widgets/lazy_level_image.dart';
import 'game_page.dart';

/// 图包专属关卡列表页 (展示图包封面信息、关卡网格与一键物理删除)
class PackLevelsPage extends StatefulWidget {
  const PackLevelsPage({super.key, required this.pack});

  final PuzzlePackItem pack;

  static Future<void> push(BuildContext context, PuzzlePackItem pack) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => PackLevelsPage(pack: pack)));
  }

  @override
  State<PackLevelsPage> createState() => _PackLevelsPageState();
}

class _PackLevelsPageState extends State<PackLevelsPage> {
  late List<PuzzleLevelItem> _levels;

  @override
  void initState() {
    super.initState();
    _loadLevels();
  }

  void _loadLevels() {
    _levels = AppContent.instance.packs.getPackLevels(widget.pack);
  }

  Future<void> _confirmDeletePack() async {
    final palette = AppPalette.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除「${widget.pack.title}」图包'),
        content: Text(
          '确定要删除此扩展图包吗？\n将同时清理包内 ${_levels.length} 个关卡并释放 ${widget.pack.displayFileSize} 存储空间。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: palette.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final success = await AppContent.instance.packs.deletePack(
        widget.pack.id,
      );
      if (mounted) {
        if (success) {
          Navigator.of(context).pop();
        } else {
          GameToast.show(
            context,
            icon: PhosphorIconsRegular.warning,
            message: '删除失败，请重试',
            type: GameToastType.error,
          );
        }
      }
    }
  }

  static const _defaultDiff = PuzzleDifficulty(
    label: '4 × 4 (16 块)',
    rows: 4,
    cols: 4,
    recommended: true,
  );

  Future<void> _openLevel(PuzzleLevelItem level) async {
    final imageFile = File(level.imagePathOrUrl);
    if (!imageFile.existsSync()) {
      GameToast.show(
        context,
        icon: PhosphorIconsRegular.warning,
        message: '关卡图片文件不存在',
        type: GameToastType.error,
      );
      return;
    }
    final bytes = await imageFile.readAsBytes();
    if (!mounted) return;
    final canonicalId = level.id;
    final resumeResult = await ResumeHelper.maybeShowResumeDialog(
      context: context,
      canonicalId: canonicalId,
      fallbackDifficulty: _defaultDiff,
      isCompleted: false,
      title: '${widget.pack.title} · 第 ${level.order} 关',
      imageBytes: bytes,
    );
    if (resumeResult != null) {
      if (resumeResult == 'cancelled') {
        if (mounted) setState(() {});
        return;
      }
      if (resumeResult.startsWith('continue:')) {
        final k = resumeResult.substring('continue:'.length);
        final diff = await _diffForKey(k, _defaultDiff);
        final jsonStr = await SnapshotStore.instance.loadJsonString(
          canonicalId,
          k,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: bytes,
              difficulty: diff,
              canonicalId: canonicalId,
              packTitle: '${widget.pack.title} · 第 ${level.order} 关',
              initialSnapshotJson: jsonStr,
            ),
          ),
        );
        if (mounted) setState(() {});
        return;
      } else if (resumeResult.startsWith('restart:')) {
        final k = resumeResult.substring('restart:'.length);
        await ResumeHelper.clearResume(canonicalId, k);
        final diff = await _diffForKey(k, _defaultDiff);
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: bytes,
              difficulty: diff,
              canonicalId: canonicalId,
              packTitle: '${widget.pack.title} · 第 ${level.order} 关',
              initialSnapshotJson: null,
            ),
          ),
        );
        if (mounted) setState(() {});
        return;
      }
    }
    if (!mounted) return;
    final progress = await ResumeHelper.loadProgress(canonicalId);
    if (!mounted) return;
    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: bytes,
      initialDifficulty: _defaultDiff,
      completedPieceCounts: progress.completedPieceCounts.toSet(),
      canonicalId: canonicalId,
      isUnlocked: true,
      title: '${widget.pack.title} · 第 ${level.order} 关',
      sourcePlatform: widget.pack.displaySource,
      savedProgressPercent: progress.hasSnapshot
          ? progress.progressPercent
          : null,
      onResetProgress: () async {
        final prog = await ResumeHelper.loadProgress(canonicalId);
        if (prog.activeDifficultyKey.isNotEmpty) {
          await ResumeHelper.clearResume(canonicalId, prog.activeDifficultyKey);
        }
        await GameRepository.instance.updateGenericProgress(
          canonicalId: canonicalId,
          progressPercent: 0,
          snapshotJson: null,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: bytes,
              difficulty: _defaultDiff,
              canonicalId: canonicalId,
              packTitle: '${widget.pack.title} · 第 ${level.order} 关',
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
              imageBytes: bytes,
              difficulty: diff,
              canonicalId: canonicalId,
              packTitle: '${widget.pack.title} · 第 ${level.order} 关',
              initialSnapshotJson: snapJson,
            ),
          ),
        );
        if (mounted) setState(() {});
      },
    );
  }

  Future<PuzzleDifficulty> _diffForKey(
    String k,
    PuzzleDifficulty fallback,
  ) async {
    for (final d in PuzzleDifficulty.presets) {
      if (SnapshotStore.difficultyKeyFor(d) == k) return d;
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final pack = widget.pack;

    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(
        backgroundColor: palette.surface,
        foregroundColor: palette.primaryText,
        elevation: 0.5,
        scrolledUnderElevation: 0.5,
        title: Text(pack.title, style: styles.h3),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '删除此图包',
            icon: Icon(PhosphorIconsRegular.trash, color: palette.error),
            onPressed: _confirmDeletePack,
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          // 顶部图包 Header 卡片
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: palette.surfaceContainer,
                  border: Border.all(color: palette.divider, width: 1),
                ),
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 80,
                        height: 80,
                        // 默认 card 档位（360），与「我的拼图」图包大卡共用同一份缩略图
                        child: AppCachedImage(
                          imagePathOrUrl: pack.coverPath,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            pack.title,
                            style: styles.h3.copyWith(fontSize: 16),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (pack.description.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              pack.description,
                              style: styles.caption,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: palette.brand.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${pack.levelCount} 关卡',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: palette.brand,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                pack.displayFileSize,
                                style: styles.caption.copyWith(fontSize: 11),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '• ${pack.displaySource}',
                                style: styles.caption.copyWith(fontSize: 11),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 关卡 Grid
          if (_levels.isEmpty)
            SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Text(
                    '此图包中暂无关卡图片',
                    style: styles.caption.copyWith(color: palette.disabledText),
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 14,
                  childAspectRatio: 1.0,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final level = _levels[index];
                  return _buildLevelCard(level, palette);
                }, childCount: _levels.length),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 30)),
        ],
      ),
    );
  }

  Widget _buildLevelCard(PuzzleLevelItem level, AppPalette palette) {
    final isCompleted = level.isCompleted;

    return InkWell(
      onTap: () => _openLevel(level),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.divider, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            LazyLevelImage(level: level, fit: BoxFit.cover),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.3),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.3),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '#${level.order}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            if (isCompleted)
              Center(
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: palette.success.withValues(alpha: 0.8),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    PhosphorIconsBold.check,
                    color: palette.surface,
                    size: 22,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
