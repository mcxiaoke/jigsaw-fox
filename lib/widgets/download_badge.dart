import 'package:flutter/material.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// 统一的图集与活动下载状态角标
class DownloadBadge extends StatelessWidget {
  const DownloadBadge({
    required this.isDownloaded,
    required this.isDownloading,
    required this.downloadProgress,
    required this.isZipType,
    this.displayFileSize = '',
    super.key,
  });

  final bool isDownloaded;
  final bool isDownloading;
  final double downloadProgress;
  final bool isZipType;
  final String displayFileSize;

  @override
  Widget build(BuildContext context) {
    if (!isZipType) return const SizedBox.shrink();

    final palette = AppPalette.of(context);

    // 1. 已下载完成
    if (isDownloaded) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              PhosphorIconsBold.check,
              color: Colors.greenAccent,
              size: 11,
            ),
            const SizedBox(width: 3),
            Text(
              t.collections.badgeDownloaded,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    // 2. 下载中
    if (isDownloading) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                value: downloadProgress > 0 ? downloadProgress : null,
                color: palette.brand,
                strokeWidth: 2,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              '${(downloadProgress * 100).toInt()}%',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    // 3. Zip 未下载：显示醒目的下载按钮
    if (isZipType) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: palette.brand.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              PhosphorIconsBold.downloadSimple,
              color: Colors.white,
              size: 11,
            ),
            const SizedBox(width: 3),
            Text(
              displayFileSize.isNotEmpty
                  ? displayFileSize
                  : t.collections.badgeDownload,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    // 4. Array 在线类型（不需要下载）
    return const SizedBox.shrink();
  }
}
