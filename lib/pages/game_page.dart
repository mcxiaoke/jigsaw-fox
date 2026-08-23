import 'dart:typed_data';

import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import '../game/jigsaw_puzzle_game.dart';
import '../logic/puzzle_model.dart';

class GamePage extends StatefulWidget {
  const GamePage({
    super.key,
    required this.imageBytes,
    required this.difficulty,
  });

  final Uint8List imageBytes;
  final PuzzleDifficulty difficulty;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> {
  late Future<PuzzleImage> _imageFuture;
  bool _showPreview = false;
  int _runId = 0;

  @override
  void initState() {
    super.initState();
    _imageFuture = decodeFlameImage(widget.imageBytes);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            FutureBuilder<PuzzleImage>(
              future: _imageFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('图片加载失败: ${snapshot.error}'));
                }
                return GameWidget(
                  key: ValueKey(_runId),
                  game: JigsawPuzzleGame(
                    image: snapshot.data!,
                    rows: widget.difficulty.rows,
                    cols: widget.difficulty.cols,
                    onSolved: () => _onSolved(context),
                  ),
                );
              },
            ),
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton.filledTonal(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back),
                    tooltip: '返回',
                  ),
                  const SizedBox(width: 4),
                  Text('${widget.difficulty.label} · ${widget.difficulty.pieceCount} 块'),
                  const Spacer(),
                  IconButton.filledTonal(
                    onPressed: () => setState(() => _showPreview = !_showPreview),
                    isSelected: _showPreview,
                    icon: const Icon(Icons.image_search),
                    tooltip: '预览原图',
                  ),
                  const SizedBox(width: 4),
                  IconButton.filledTonal(
                    onPressed: () {
                      setState(() {
                        _runId++;
                        _showPreview = false;
                      });
                    },
                    icon: const Icon(Icons.refresh),
                    tooltip: '重新开始',
                  ),
                ],
              ),
            ),
            if (_showPreview)
              IgnorePointer(
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.all(48),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white70, width: 2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(widget.imageBytes),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _onSolved(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Icon(Icons.emoji_events, size: 48, color: Colors.amber),
        content: const Text('恭喜完成拼图！'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              setState(() => _runId++);
            },
            child: const Text('再来一局'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              Navigator.of(context).pop();
            },
            child: const Text('返回首页'),
          ),
        ],
      ),
    );
  }
}
