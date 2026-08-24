import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../data/game_repository.dart';
import '../../data/models/custom_puzzle_item.dart';
import '../../logic/image_source.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../crop_puzzle_page.dart';
import '../game_page.dart';

/// "My Puzzles" (我的自制关卡) tab view supporting UGC creation, adaptive responsive grid, and play.
class MyPuzzlesTabView extends StatefulWidget {
  const MyPuzzlesTabView({super.key});

  @override
  State<MyPuzzlesTabView> createState() => _MyPuzzlesTabViewState();
}

class _MyPuzzlesTabViewState extends State<MyPuzzlesTabView> {
  final _repo = GameRepository.instance;
  bool _loading = false;

  Future<void> _createFromGallery() async {
    setState(() => _loading = true);
    try {
      final source = GallerySource();
      final bytes = await source.loadBytes();
      if (!mounted) return;

      final result = await CropPuzzlePage.push(context, bytes);
      if (result != null && mounted) {
        setState(() {}); // refresh created puzzle
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择图片失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openCustom(CustomPuzzleItem item) async {
    Uint8List bytes;
    if (item.isLocalFile && !item.imagePathOrUrl.startsWith('assets/')) {
      final file = File(item.imagePathOrUrl);
      if (await file.exists()) {
        bytes = await file.readAsBytes();
      } else {
        final data = await rootBundle.load(assetSamples[0]);
        bytes = data.buffer.asUint8List();
      }
    } else if (item.imagePathOrUrl.startsWith('assets/')) {
      final data = await rootBundle.load(item.imagePathOrUrl);
      bytes = data.buffer.asUint8List();
    } else {
      final data = await rootBundle.load(assetSamples[0]);
      bytes = data.buffer.asUint8List();
    }

    if (!mounted) return;
    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: bytes,
      initialDifficulty: item.difficulty,
      completedPieceCounts: item.completedPieceCounts.toSet(),
      title: '${item.title} · 难度选择',
      savedProgressPercent: item.isCompleted ? null : item.progressPercent,
      onDelete: () async {
        await _repo.deleteCustomPuzzle(item.id);
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已删除「${item.title}」')),
          );
        }
      },
      onResetProgress: () async {
        await _repo.updateCustomProgress(
          id: item.id,
          progressPercent: 0,
          snapshotJson: null,
          isCompleted: item.isCompleted,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: bytes,
              difficulty: item.difficulty,
              customId: item.id,
              initialSnapshotJson: null,
            ),
          ),
        );
        setState(() {});
      },
      onStart: (diff) async {
        final isSameDiff = diff.pieceCount == item.difficulty.pieceCount;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: bytes,
              difficulty: diff,
              customId: item.id,
              initialSnapshotJson: isSameDiff && !item.isCompleted ? item.savedSnapshotJson : null,
            ),
          ),
        );
        setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final customList = _repo.customPuzzles;

    return RefreshIndicator(
      onRefresh: () async => setState(() {}),
      child: CustomScrollView(
        slivers: [
          // 1. Top UGC Creation Action Card
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: InkWell(
                onTap: _loading ? null : _createFromGallery,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  height: 92,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFE8F5E9), Color(0xFFC8E6C9)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF81C784), width: 1.5),
                    boxShadow: const [
                      BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2)),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: const Color(0xFF2E7D32),
                        radius: 24,
                        child: _loading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                              )
                            : const Icon(PhosphorIconsBold.imageSquare, color: Colors.white, size: 26),
                      ),
                      const SizedBox(width: 16),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '自制新拼图',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1B5E20),
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              '导入本地相册照片，支持自由缩放裁剪与多规格选择',
                              style: TextStyle(fontSize: 12, color: Colors.black54),
                            ),
                          ],
                        ),
                      ),
                      const Icon(PhosphorIconsBold.caretRight, color: Color(0xFF2E7D32)),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // 2. Section Header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '我的自制合辑',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '共 ${customList.length} 个关卡',
                    style: const TextStyle(fontSize: 13, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),

          // 3. Responsive Grid or Empty state
          if (customList.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Column(
                    children: [
                      Icon(PhosphorIconsRegular.images, size: 48, color: Colors.grey),
                      SizedBox(height: 10),
                      Text('还没有自制拼图，点击上方卡片导入相册创建吧！', style: TextStyle(color: Colors.grey)),
                    ],
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
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = customList[index];
                    return _buildCustomGridCard(item);
                  },
                  childCount: customList.length,
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  Widget _buildCustomGridCard(CustomPuzzleItem item) {
    return InkWell(
      onTap: () => _openCustom(item),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Thumbnail Image
            _buildThumbnail(item),

            // Top and Bottom gradients
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black45, Colors.transparent, Colors.black54],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),

            // Top-left Title
            Positioned(
              left: 10,
              top: 10,
              right: 50,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  item.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),

            // Top-right piece count badge or progress
            Positioned(
              top: 10,
              right: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item.progressPercent > 0 && !item.isCompleted) ...[
                      Text(
                        '${item.progressPercent}%',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2E7D32),
                        ),
                      ),
                    ] else ...[
                      const Icon(PhosphorIconsFill.puzzlePiece, size: 12, color: Colors.black54),
                      const SizedBox(width: 3),
                      Text(
                        '${item.difficulty.pieceCount}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Center Play or Checkmark
            if (item.isCompleted)
              const Center(
                child: CircleAvatar(
                  backgroundColor: Color(0xCC2E7D32),
                  radius: 20,
                  child: Icon(PhosphorIconsBold.check, color: Colors.white, size: 24),
                ),
              )
            else if (item.progressPercent == 0)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E7D32),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(color: Colors.black38, blurRadius: 6),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(PhosphorIconsFill.play, color: Colors.white, size: 14),
                      SizedBox(width: 4),
                      Text(
                        '开始',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Bottom Progress Bar if in progress
            if (item.progressPercent > 0 && !item.isCompleted)
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: item.progressPercent / 100.0,
                    minHeight: 4,
                    backgroundColor: Colors.white38,
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF81C784)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(CustomPuzzleItem item) {
    if (item.isLocalFile && !item.imagePathOrUrl.startsWith('assets/')) {
      final file = File(item.imagePathOrUrl);
      return Image.file(
        file,
        fit: BoxFit.cover,
        errorBuilder: (ctx, err, stack) => Image.asset(
          assetSamples[0],
          fit: BoxFit.cover,
        ),
      );
    } else if (item.imagePathOrUrl.startsWith('assets/')) {
      return Image.asset(
        item.imagePathOrUrl,
        fit: BoxFit.cover,
        errorBuilder: (ctx, err, stack) => Image.asset(
          assetSamples[0],
          fit: BoxFit.cover,
        ),
      );
    } else {
      return Image.asset(assetSamples[0], fit: BoxFit.cover);
    }
  }
}
