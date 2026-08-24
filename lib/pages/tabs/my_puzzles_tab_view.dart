import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/game_repository.dart';
import '../../data/models/custom_puzzle_item.dart';
import '../../logic/image_source.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../crop_puzzle_page.dart';
import '../game_page.dart';

/// "My Puzzles" (我的自制关卡) tab view supporting UGC creation, management, and play.
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

  Future<void> _playCustom(CustomPuzzleItem item) async {
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
      onStart: (diff) async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: bytes,
              difficulty: diff,
              customId: item.id,
              initialSnapshotJson: item.savedSnapshotJson,
            ),
          ),
        );
        setState(() {});
      },
    );
  }

  Future<void> _confirmDelete(CustomPuzzleItem item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.delete_outline, color: Colors.redAccent),
            SizedBox(width: 8),
            Text('删除自制关卡'),
          ],
        ),
        content: Text('确定要删除「${item.title}」及其本地拼图资源吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('确定删除'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _repo.deleteCustomPuzzle(item.id);
      if (mounted) setState(() {});
    }
  }

  String _formatDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final customList = _repo.customPuzzles;

    return RefreshIndicator(
      onRefresh: () async => setState(() {}),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        children: [
          // 1. New Creation Action Card
          InkWell(
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
                        : const Icon(Icons.add_photo_alternate, color: Colors.white, size: 26),
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
                          '导入本地相册相片，支持自由缩放裁剪与规格选择',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Color(0xFF2E7D32)),
                ],
              ),
            ),
          ),

          const SizedBox(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '我的拼图合辑',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              Text(
                '共 ${customList.length} 个关卡',
                style: const TextStyle(fontSize: 13, color: Colors.black54),
              ),
            ],
          ),
          const SizedBox(height: 12),

          if (customList.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 40),
              alignment: Alignment.center,
              child: const Column(
                children: [
                  Icon(Icons.photo_library_outlined, size: 48, color: Colors.grey),
                  SizedBox(height: 8),
                  Text('还没有自制拼图，点击上方按钮开始创建吧！', style: TextStyle(color: Colors.grey)),
                ],
              ),
            )
          else
            for (final item in customList) ...[
              _buildCustomCard(item),
              const SizedBox(height: 12),
            ],

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildCustomCard(CustomPuzzleItem item) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _playCustom(item),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 84,
                  height: 84,
                  child: _buildThumbnail(item),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '规格：${item.difficulty.pieceCount} 块 (${item.difficulty.rows}×${item.difficulty.cols})',
                      style: const TextStyle(fontSize: 12.5, color: Colors.black54),
                    ),
                    const SizedBox(height: 6),
                    if (item.isCompleted)
                      Row(
                        children: [
                          const Icon(Icons.check_circle, color: Color(0xFF2E7D32), size: 15),
                          const SizedBox(width: 4),
                          Text(
                            item.bestTimeSeconds > 0
                                ? '已完成 · 最快 ${_formatDuration(item.bestTimeSeconds)}'
                                : '已完成',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF2E7D32),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      )
                    else if (item.progressPercent > 0)
                      Text(
                        '当前进度：${item.progressPercent}%',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF0288D1),
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else
                      const Text(
                        '未开始',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                  ],
                ),
              ),

              // Action Buttons: Play + Delete
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton(
                    onPressed: () => _playCustom(item),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Text(item.progressPercent > 0 ? '继续' : '开始'),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 20),
                    tooltip: '删除关卡',
                    onPressed: () => _confirmDelete(item),
                  ),
                ],
              ),
            ],
          ),
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
