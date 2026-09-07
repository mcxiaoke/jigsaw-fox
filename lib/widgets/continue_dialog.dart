import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/models/puzzle_state.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// Continue-or-restart dialog with brand identity.
///
/// Shows thumbnail, progress bar, elapsed time, and difficulty spec.
/// Two-button weight differentiation: "继续挑战" (brand solid) vs "退出" (ghost).
class ContinueDialog extends StatelessWidget {
  const ContinueDialog({
    required this.title, required this.imageBytes, required this.difficultyKey, required this.snapshot, required this.progressPercent, required this.onContinue, required this.onRestart, super.key,
  });

  final String title;
  final Uint8List imageBytes;
  final String difficultyKey;
  final PuzzleBoardState snapshot;
  final int progressPercent;
  final ValueChanged<String> onContinue;
  final ValueChanged<String> onRestart;

  static Future<String?> show({
    required BuildContext context,
    required String title,
    required Uint8List imageBytes,
    required String difficultyKey,
    required PuzzleBoardState snapshot,
    required int progressPercent,
  }) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => ContinueDialog(
        title: title,
        imageBytes: imageBytes,
        difficultyKey: difficultyKey,
        snapshot: snapshot,
        progressPercent: progressPercent,
        onContinue: (k) {
          Navigator.of(ctx).pop('continue:$k');
        },
        onRestart: (k) {
          Navigator.of(ctx).pop('restart:$k');
        },
      ),
    );
  }

  String _timeString(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final elapsed = snapshot.elapsedSeconds;
    final total = snapshot.totalPieces;

    return AlertDialog(
      backgroundColor: palette.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      title: Row(
        children: [
          Icon(
            PhosphorIconsFill.clockCounterClockwise,
            color: palette.brand,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: styles.h3.copyWith(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: palette.primaryText,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: Icon(
              PhosphorIconsBold.x,
              size: 18,
              color: palette.secondaryText,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Thumbnail
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(
                aspectRatio: 1.4,
                child: Image.memory(
                  imageBytes,
                  fit: BoxFit.cover,
                  // 解码期降采样：内容区宽 360px × 3 倍 DPR 足够清晰，
                  // 避免按原图分辨率全量解码（超分图可达数十 MB）
                  cacheWidth: 1080,
                  errorBuilder: (_, _, _) => ColoredBox(
                    color: palette.surfaceContainerLow,
                    child: Icon(
                      PhosphorIconsRegular.image,
                      size: 32,
                      color: palette.disabledText,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Progress info card
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: palette.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: palette.divider),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.continueDialog.progressLabel,
                            style: styles.caption,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$progressPercent%  $progressPercent/100',
                            style: styles.bodyBold.copyWith(
                              fontSize: 14,
                              color: palette.brand,
                            ),
                          ),
                        ],
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            t.continueDialog.timeLabel,
                            style: styles.caption,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _timeString(elapsed),
                            style: styles.bodyBold.copyWith(fontSize: 14),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progressPercent / 100.0,
                      minHeight: 6,
                      backgroundColor: palette.divider,
                      valueColor: AlwaysStoppedAnimation<Color>(palette.brand),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        total > 0
                            ? t.continueDialog.specPieces(
                                key: difficultyKey,
                                count: total,
                              )
                            : t.continueDialog.spec(key: difficultyKey),
                        style: styles.caption,
                      ),
                      Text(
                        t.continueDialog.piecesCount(
                          count: snapshot.pieces.length,
                        ),
                        style: styles.caption.copyWith(
                          color: palette.disabledText,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // Emotional hint
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: palette.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: palette.warning.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    PhosphorIconsFill.info,
                    size: 16,
                    color: palette.warning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      t.continueDialog.foxHint,
                      style: styles.caption.copyWith(
                        fontSize: 11.5,
                        color: palette.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        TextButton(
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (c) {
                return AlertDialog(
                  backgroundColor: palette.surfaceContainer,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  title: Text(
                    t.continueDialog.restartTitle,
                    style: styles.h3.copyWith(color: palette.primaryText),
                  ),
                  content: Text(
                    t.continueDialog.restartDesc,
                    style: styles.body.copyWith(color: palette.secondaryText),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: Text(
                        t.common.cancel,
                        style: TextStyle(color: palette.secondaryText),
                      ),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: palette.warning,
                      ),
                      onPressed: () => Navigator.pop(c, true),
                      child: Text(t.continueDialog.restartConfirm),
                    ),
                  ],
                );
              },
            );
            if (ok == true) onRestart(difficultyKey);
          },
          child: Text(
            t.continueDialog.btnRestart,
            style: TextStyle(color: palette.warning),
          ),
        ),
        FilledButton.icon(
          onPressed: () => onContinue(difficultyKey),
          icon: const Icon(PhosphorIconsFill.play, size: 16),
          label: Text(t.continueDialog.btnResume),
          style: FilledButton.styleFrom(
            backgroundColor: palette.brand,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ],
    );
  }
}
