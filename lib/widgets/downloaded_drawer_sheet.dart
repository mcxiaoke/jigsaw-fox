import 'dart:io';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/models/downloaded_image_item.dart';
import '../logic/download_manager.dart';
import '../pages/crop_puzzle_page.dart';
import '../theme/app_palette.dart';
import '../theme/app_text_styles.dart';
import '../widgets/app_cached_image.dart';
import '../widgets/game_toast.dart';

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

  Future<void> _makePuzzleFromItem(
    BuildContext context,
    DownloadedImageItem item,
  ) async {
    final file = File(item.localPath);
    if (!await file.exists()) {
      if (context.mounted) {
        GameToast.show(
          context,
          message: '素材文件不存在或已被清理',
          type: GameToastType.warning,
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
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: palette.surfaceContainer,
        title: Text(
          '清空素材库',
          style: styles.h3.copyWith(color: palette.primaryText),
        ),
        content: Text(
          '确定要清空所有待制作的素材图片吗？（不会影响已经制作成功的拼图关卡）',
          style: styles.body.copyWith(color: palette.secondaryText),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: palette.secondaryText)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: palette.error),
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
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.85;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: palette.surfaceContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
                color: palette.divider,
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          PhosphorIconsBold.archive,
                          color: palette.warning,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '素材库',
                          style: styles.h3.copyWith(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: palette.primaryText,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: palette.warning.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${items.length} 张素材',
                            style: TextStyle(
                              color: palette.warning,
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
                            icon: Icon(
                              PhosphorIconsRegular.trash,
                              size: 16,
                              color: palette.error,
                            ),
                            label: Text(
                              '清空全部',
                              style: TextStyle(
                                color: palette.error,
                                fontSize: 13,
                              ),
                            ),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                            ),
                          ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(
                            PhosphorIconsBold.x,
                            size: 20,
                            color: palette.secondaryText,
                          ),
                          tooltip: '关闭',
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
          Divider(height: 1, color: palette.divider),

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
                          Icon(
                            PhosphorIconsRegular.archive,
                            size: 56,
                            color: palette.disabledText,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '素材库暂无图片',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: palette.secondaryText,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '点击「相册选图」批量导入本地照片，或在「在线搜图」中一键下载，即可将图片加入素材库随时制作拼图。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: palette.disabledText,
                            ),
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
                    return _buildImageCard(context, item, palette, styles);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageCard(
    BuildContext context,
    DownloadedImageItem item,
    AppPalette palette,
    AppTextStyles styles,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.divider),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
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
                ),
                // Platform Tag
                Positioned(
                  left: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      item.sourcePlatform == '本地相册' ||
                              item.sourcePlatform == '相册'
                          ? '相册'
                          : '网络',
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: palette.brand.withValues(alpha: 0.85),
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
                    Icon(
                      PhosphorIconsRegular.frameCorners,
                      size: 13,
                      color: palette.secondaryText,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      item.resolutionLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: palette.primaryText,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(
                      PhosphorIconsRegular.hardDrive,
                      size: 13,
                      color: palette.disabledText,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      item.fileSizeLabel,
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.secondaryText,
                      ),
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
                      backgroundColor: palette.brand,
                      visualDensity: VisualDensity.compact,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                    ),
                    icon: const Icon(PhosphorIconsBold.puzzlePiece, size: 14),
                    label: const Text(
                      '制作拼图',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  onPressed: () => DownloadManager.instance.removeItem(item.id),
                  icon: Icon(
                    PhosphorIconsRegular.trash,
                    size: 16,
                    color: palette.secondaryText,
                  ),
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
