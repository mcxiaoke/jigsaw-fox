import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../logic/models/puzzle_state.dart';

/// 续玩二选一弹窗：继续 / 重新开始
///
/// 展示缩略图、进度条、已用时、规格；多难度时以 SegmentedButton 切换
class ContinueDialog extends StatefulWidget {
  const ContinueDialog({
    super.key,
    required this.title,
    required this.imageBytes,
    required this.difficulties,
    required this.snapshots,
    required this.progressPercents,
    required this.onContinue,
    required this.onRestart,
  });

  final String title;
  final Uint8List imageBytes;
  final List<String> difficulties; // e.g. ["10x10", "15x15"]
  final Map<String, PuzzleBoardState> snapshots; // difficultyKey -> state
  final Map<String, int> progressPercents; // difficultyKey -> percent
  final ValueChanged<String> onContinue; // difficultyKey
  final ValueChanged<String> onRestart;

  static Future<String?> show({
    required BuildContext context,
    required String title,
    required Uint8List imageBytes,
    required List<String> difficulties,
    required Map<String, PuzzleBoardState> snapshots,
    required Map<String, int> progressPercents,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => ContinueDialog(
        title: title,
        imageBytes: imageBytes,
        difficulties: difficulties,
        snapshots: snapshots,
        progressPercents: progressPercents,
        onContinue: (k) {
          Navigator.of(ctx).pop('continue:$k');
        },
        onRestart: (k) {
          Navigator.of(ctx).pop('restart:$k');
        },
      ),
    );
  }

  @override
  State<ContinueDialog> createState() => _ContinueDialogState();
}

class _ContinueDialogState extends State<ContinueDialog> {
  late String _selectedKey;

  @override
  void initState() {
    super.initState();
    _selectedKey = widget.difficulties.isNotEmpty ? widget.difficulties.first : '';
    // 优先选进度最高的
    if (widget.difficulties.length > 1) {
      var best = _selectedKey;
      var bestP = -1;
      for (final k in widget.difficulties) {
        final p = widget.progressPercents[k] ?? 0;
        if (p > bestP) {
          bestP = p;
          best = k;
        }
      }
      _selectedKey = best;
    }
  }

  String _timeString(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.snapshots[_selectedKey];
    final percent = widget.progressPercents[_selectedKey] ?? 0;
    final elapsed = state?.elapsedSeconds ?? 0;
    final total = state?.totalPieces ?? 0;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
      title: Row(
        children: [
          const Icon(PhosphorIconsFill.clockCounterClockwise, color: Color(0xFF2E7D32), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(widget.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
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
            if (widget.difficulties.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<String>(
                    segments: [
                      for (final k in widget.difficulties)
                        ButtonSegment<String>(
                          value: k,
                          label: Text(k),
                          icon: Icon(widget.snapshots.containsKey(k) ? PhosphorIconsFill.play : PhosphorIconsRegular.play, size: 14),
                        ),
                    ],
                    selected: {_selectedKey},
                    onSelectionChanged: (s) => setState(() => _selectedKey = s.first),
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 1.4,
                child: Image.memory(
                  widget.imageBytes,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(color: Colors.grey.shade200, child: const Icon(PhosphorIconsRegular.image, size: 32, color: Colors.grey)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: const Color(0xFFF1F8E9), borderRadius: BorderRadius.circular(12)),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('已拼进度', style: TextStyle(fontSize: 11, color: Colors.black54)),
                        const SizedBox(height: 2),
                        Text('$percent%  $percent/100', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2E7D32))),
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
                      value: percent / 100.0,
                      minHeight: 6,
                      backgroundColor: Colors.black12,
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2E7D32)),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('规格 $_selectedKey  ${total > 0 ? "($total块)" : ""}', style: const TextStyle(fontSize: 11, color: Colors.black54)),
                      if (state != null) Text('碎片 ${state.pieces.length}', style: const TextStyle(fontSize: 11, color: Colors.black45)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.amber.shade200)),
              child: Row(
                children: [
                  const Icon(PhosphorIconsFill.info, size: 16, color: Colors.orange),
                  const SizedBox(width: 6),
                  const Expanded(child: Text('选择“继续”将恢复到上次退出时的位置', style: TextStyle(fontSize: 11.5, color: Color(0xFF6D4C00)))),
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
            if (ok == true) widget.onRestart(_selectedKey);
          },
          child: const Text('重新开始', style: TextStyle(color: Colors.orange)),
        ),
        FilledButton.icon(
          onPressed: () => widget.onContinue(_selectedKey),
          icon: const Icon(PhosphorIconsFill.play, size: 16),
          label: const Text('继续'),
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
        ),
      ],
    );
  }
}


