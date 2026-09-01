import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../logic/models/puzzle_state.dart';

/// 续玩二选一弹窗：继续 / 重新开始
///
/// 展示缩略图、进度条、已用时、规格（方案 A：单难度残局极简设计）
class ContinueDialog extends StatelessWidget {
  const ContinueDialog({
    super.key,
    required this.title,
    required this.imageBytes,
    required this.difficultyKey,
    required this.snapshot,
    required this.progressPercent,
    required this.onContinue,
    required this.onRestart,
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
      barrierDismissible: true,
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
    final elapsed = snapshot.elapsedSeconds;
    final total = snapshot.totalPieces;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      title: Row(
        children: [
          const Icon(PhosphorIconsFill.clockCounterClockwise, color: Color(0xFF2E7D32), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(PhosphorIconsBold.x, size: 18),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 1.4,
                child: Image.memory(
                  imageBytes,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    color: Colors.grey.shade200,
                    child: const Icon(PhosphorIconsRegular.image, size: 32, color: Colors.grey),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F8E9),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('已拼进度', style: TextStyle(fontSize: 11, color: Colors.black54)),
                        const SizedBox(height: 2),
                        Text(
                          '$progressPercent%  $progressPercent/100',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF2E7D32),
                          ),
                        ),
                      ]),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        const Text('已用时间', style: TextStyle(fontSize: 11, color: Colors.black54)),
                        const SizedBox(height: 2),
                        Text(_timeString(elapsed), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                      ]),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progressPercent / 100.0,
                      minHeight: 6,
                      backgroundColor: Colors.black12,
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2E7D32)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('规格 $difficultyKey  ${total > 0 ? "($total块)" : ""}', style: const TextStyle(fontSize: 11, color: Colors.black54)),
                      Text('碎片 ${snapshot.pieces.length}', style: const TextStyle(fontSize: 11, color: Colors.black45)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.shade200),
              ),
              child: const Row(
                children: [
                  Icon(PhosphorIconsFill.info, size: 16, color: Colors.orange),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '选择“继续”将恢复到上次退出时的位置',
                      style: TextStyle(fontSize: 11.5, color: Color(0xFF6D4C00)),
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
              builder: (c) => AlertDialog(
                title: const Text('重新开始？'),
                content: const Text('将清除该难度的存档进度，不可恢复，确定重新开始吗？'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.orange),
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('确定重开'),
                  ),
                ],
              ),
            );
            if (ok == true) onRestart(difficultyKey);
          },
          child: const Text('重新开始', style: TextStyle(color: Colors.orange)),
        ),
        FilledButton.icon(
          onPressed: () => onContinue(difficultyKey),
          icon: const Icon(PhosphorIconsFill.play, size: 16),
          label: const Text('继续'),
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
        ),
      ],
    );
  }
}
