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
import '../widgets/app_cached_image.dart';
import '../widgets/choose_difficulty_sheet.dart';
import 'game_page.dart';

/// 图包专属关卡列表页 (展示图包封面信息、关卡网格与一键物理删除)
class PackLevelsPage extends StatefulWidget {
  const PackLevelsPage({
    super.key,
    required this.pack,
  });

  final PuzzlePackItem pack;

  static Future<void> push(BuildContext context, PuzzlePackItem pack) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PackLevelsPage(pack: pack)),
    );
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${widget.pack.title}」图包'),
        content: Text('确定要删除此扩展图包吗？\n将同时清理包内 ${_levels.length} 个关卡并释放 ${widget.pack.displayFileSize} 存储空间。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final success = await AppContent.instance.packs.deletePack(widget.pack.id);
      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已成功删除《${widget.pack.title}》')),
          );
          Navigator.of(context).pop();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('删除失败，请重试')),
          );
        }
      }
    }
  }

  static const _defaultDiff = PuzzleDifficulty(label: '4 × 4 (16 块)', rows: 4, cols: 4, recommended: true);

  Future<void> _openLevel(PuzzleLevelItem level) async {
    final imageFile = File(level.imagePathOrUrl);
    if (!imageFile.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('关卡图片文件不存在')));
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
        final jsonStr = await SnapshotStore.instance.loadJsonString(canonicalId, k);
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GamePage(imageBytes: bytes, difficulty: diff, canonicalId: canonicalId, packTitle: '${widget.pack.title} · 第 ${level.order} 关', initialSnapshotJson: jsonStr)));
        if (mounted) setState(() {});
        return;
      } else if (resumeResult.startsWith('restart:')) {
        final k = resumeResult.substring('restart:'.length);
        await ResumeHelper.clearResume(canonicalId, k);
        final diff = await _diffForKey(k, _defaultDiff);
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GamePage(imageBytes: bytes, difficulty: diff, canonicalId: canonicalId, packTitle: '${widget.pack.title} · 第 ${level.order} 关', initialSnapshotJson: null)));
        if (mounted) setState(() {});
        return;
      }
    }
    if (!mounted) return;
    final progress = await ResumeHelper.loadProgress(canonicalId);
    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: bytes,
      initialDifficulty: _defaultDiff,
      completedPieceCounts: progress.completedPieceCounts.toSet(),
      isUnlocked: true,
      title: '${widget.pack.title} · 第 ${level.order} 关',
      sourcePlatform: widget.pack.displaySource,
      savedProgressPercent: progress.hasSnapshot ? progress.progressPercent : null,
      onResetProgress: () async {
        final prog = await ResumeHelper.loadProgress(canonicalId);
        if (prog.activeDifficultyKey.isNotEmpty) {
          await ResumeHelper.clearResume(canonicalId, prog.activeDifficultyKey);
        }
        await GameRepository.instance.updateGenericProgress(canonicalId: canonicalId, progressPercent: 0, snapshotJson: null);
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GamePage(imageBytes: bytes, difficulty: _defaultDiff, canonicalId: canonicalId, packTitle: '${widget.pack.title} · 第 ${level.order} 关', initialSnapshotJson: null)));
        if (mounted) setState(() {});
      },
      onStart: (diff) async {
        final dkey = SnapshotStore.difficultyKeyFor(diff);
        final snapJson = await SnapshotStore.instance.loadJsonString(canonicalId, dkey);
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GamePage(imageBytes: bytes, difficulty: diff, canonicalId: canonicalId, packTitle: '${widget.pack.title} · 第 ${level.order} 关', initialSnapshotJson: snapJson)));
        if (mounted) setState(() {});
      },
    );
  }

  Future<PuzzleDifficulty> _diffForKey(String k, PuzzleDifficulty fallback) async {
    for (final d in PuzzleDifficulty.presets) {
      if (SnapshotStore.difficultyKeyFor(d) == k) return d;
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final pack = widget.pack;

    return Scaffold(
      appBar: AppBar(
        title: Text(pack.title, style: const TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '删除此图包',
            icon: const Icon(PhosphorIconsRegular.trash, color: Colors.redAccent),
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
                  color: Colors.white,
                  boxShadow: const [
                    BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2)),
                  ],
                ),
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    // 封面缩略
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 80,
                        height: 80,
                        child: AppCachedImage(
                          imagePathOrUrl: pack.coverPath,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    // 信息描述
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            pack.title,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (pack.description.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              pack.description,
                              style: const TextStyle(fontSize: 12, color: Colors.black54),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE8F5E9),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${pack.levelCount} 关卡',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF2E7D32),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                pack.displayFileSize,
                                style: const TextStyle(fontSize: 11, color: Colors.black45),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '• ${pack.displaySource}',
                                style: const TextStyle(fontSize: 11, color: Colors.black45),
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
            const SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Text('此图包中暂无关卡图片', style: TextStyle(color: Colors.grey)),
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
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final level = _levels[index];
                    return _buildLevelCard(level);
                  },
                  childCount: _levels.length,
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 30)),
        ],
      ),
    );
  }

  Widget _buildLevelCard(PuzzleLevelItem level) {
    final isCompleted = level.isCompleted;

    return InkWell(
      onTap: () => _openLevel(level),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 1.5)),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AppCachedImage(
              imagePathOrUrl: level.imagePathOrUrl,
              fit: BoxFit.cover,
              targetWidth: 360,
              targetHeight: 360,
            ),
            // 渐变遮罩
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black45, Colors.transparent, Colors.black45],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            // 左上角关卡编号
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
            // 已通关完成打勾
            if (isCompleted)
              const Center(
                child: CircleAvatar(
                  backgroundColor: Color(0xCC2E7D32),
                  radius: 18,
                  child: Icon(PhosphorIconsBold.check, color: Colors.white, size: 22),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
