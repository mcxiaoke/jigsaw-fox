import 'dart:io';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/models/downloaded_image_item.dart';
import '../logic/download_manager.dart';
import '../pages/crop_puzzle_page.dart';
import 'app_cached_image.dart';

/// Modal bottom sheet drawer for managing and selecting batch-downloaded online images.
class DownloadedDrawerSheet extends StatelessWidget {
  const DownloadedDrawerSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const DownloadedDrawerSheet(),
    );
  }

  Future<void> _makePuzzleFromItem(BuildContext context, DownloadedImageItem item) async {
    final file = File(item.localPath);
    if (!await file.exists()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('素材文件不存在或已被清理')),
        );
      }
      return;
    }

    final bytes = await file.readAsBytes();
    if (!context.mounted) return;

    Navigator.of(context).pop(); // Close bottom sheet

    final isLocalGallery = item.sourcePlatform == '本地相册';
    await CropPuzzlePage.push(
      context,
      bytes,
      sourceType: isLocalGallery ? 'gallery' : 'online',
      sourcePlatform: item.sourcePlatform,
      sourceUrl: item.sourceUrl,
    );
  }

  void _confirmClearAll(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空素材库'),
        content: const Text('确定要清空所有待制作的素材图片吗？（不会影响已经制作成功的拼图关卡）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await DownloadManager.instance.clearAll();
            },
            child: const Text('清空全部'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.85;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          // Drag handle
          Center(
            child: Container(
              width: 44,
              height: 4.5,
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // Header Title & Actions
          ValueListenableBuilder<List<DownloadedImageItem>>(
            valueListenable: DownloadManager.instance.itemsNotifier,
            builder: (context, items, _) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(PhosphorIconsBold.archive, color: Color(0xFFE65100), size: 22),
                        const SizedBox(width: 8),
                        Text(
                          '素材库',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF3E0),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${items.length} 张素材',
                            style: const TextStyle(
                              color: Color(0xFFE65100),
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        if (items.isNotEmpty)
                          TextButton.icon(
                            onPressed: () => _confirmClearAll(context),
                            icon: const Icon(PhosphorIconsRegular.trash, size: 16, color: Colors.redAccent),
                            label: const Text('清空全部', style: TextStyle(color: Colors.redAccent, fontSize: 13)),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                          ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(PhosphorIconsBold.x, size: 20),
                          tooltip: '关闭',
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
          const Divider(height: 1),

          // Body: Grid of Downloaded Images or Empty Placeholder
          Expanded(
            child: ValueListenableBuilder<List<DownloadedImageItem>>(
              valueListenable: DownloadManager.instance.itemsNotifier,
              builder: (context, items, _) {
                if (items.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(PhosphorIconsRegular.archive, size: 56, color: Colors.grey.shade400),
                          const SizedBox(height: 12),
                          const Text(
                            '素材库暂无图片',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black54),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '点击「相册选图」批量导入本地照片，或在「在线搜图」中一键下载，即可将图片加入素材库随时制作拼图。',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, color: Colors.black45),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 260,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return _buildImageCard(context, item);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageCard(BuildContext context, DownloadedImageItem item) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black12),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Thumbnail + Quality Badge
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                AppCachedImage(
                  imagePathOrUrl: item.localPath,
                  fit: BoxFit.cover,
                  targetWidth: 360,
                  targetHeight: 360,
                ),
                // Platform Tag
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      item.sourcePlatform,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                // Resolution Quality Badge
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E7D32).withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      item.qualityTag,
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

          // 2. Metadata info (Dimensions, size)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(PhosphorIconsRegular.frameCorners, size: 13, color: Colors.black54),
                    const SizedBox(width: 4),
                    Text(
                      item.resolutionLabel,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    const Icon(PhosphorIconsRegular.hardDrive, size: 13, color: Colors.black45),
                    const SizedBox(width: 4),
                    Text(
                      item.fileSizeLabel,
                      style: const TextStyle(fontSize: 11, color: Colors.black54),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // 3. Action Buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _makePuzzleFromItem(context, item),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      visualDensity: VisualDensity.compact,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                    ),
                    icon: const Icon(PhosphorIconsBold.puzzlePiece, size: 14),
                    label: const Text(
                      '制作拼图',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: () => DownloadManager.instance.removeItem(item.id),
                  icon: const Icon(PhosphorIconsRegular.trash, size: 16, color: Colors.black45),
                  visualDensity: VisualDensity.compact,
                  tooltip: '删除此图片',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
