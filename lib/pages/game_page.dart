import 'dart:async';
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
  PuzzleImage? _image;
  JigsawPuzzleGame? _game;
  bool _loading = true;
  String? _errorMessage;

  bool _showPreview = false;
  bool _isCompleted = false;
  int _solvedCount = 0;
  int _hintsUsed = 0;
  int _seconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadImageAndStartGame();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadImageAndStartGame() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final img = await decodeFlameImage(widget.imageBytes);
      if (!mounted) return;
      _image = img;
      _initNewGame(img);
      _startTimer();
      setState(() {
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = '图片加载失败: $e';
      });
    }
  }

  void _initNewGame(PuzzleImage img) {
    _isCompleted = false;
    _solvedCount = 0;
    _hintsUsed = 0;
    _game = JigsawPuzzleGame(
      image: img,
      rows: widget.difficulty.rows,
      cols: widget.difficulty.cols,
      onSolved: () => _handleSolved(context),
      onProgressChanged: (count) {
        if (mounted) {
          setState(() => _solvedCount = count);
        }
      },
    );
  }

  void _startTimer() {
    _timer?.cancel();
    _seconds = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_isCompleted) {
        setState(() => _seconds++);
      }
    });
  }

  void _restartGame() {
    if (_image == null) return;
    setState(() {
      _showPreview = false;
      _initNewGame(_image!);
      _startTimer();
    });
  }

  String _formatTime(int totalSec) {
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _handleSolved(BuildContext context) {
    _timer?.cancel();
    if (mounted) {
      setState(() => _isCompleted = true);
    }
    _showCompletionDialog(context);
  }

  void _showCompletionDialog(BuildContext context) {
    final timeStr = _formatTime(_seconds);

    showDialog<void>(
      context: context,
      barrierDismissible: true, // Allow tapping outside to view puzzle
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.emoji_events, size: 36, color: Colors.amber),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                '拼图完成！',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '关闭查看拼图',
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer.withAlpha(50),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('难度：${widget.difficulty.label}',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text('用时：$timeStr'),
                        const SizedBox(height: 4),
                        Text('提示次数：$_hintsUsed 次'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '💡 提示：点击「查看拼图」或对话框外部可返回棋盘欣赏与核对完整图片。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(),
            icon: const Icon(Icons.visibility),
            label: const Text('查看拼图'),
          ),
          OutlinedButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _restartGame();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalCount = widget.difficulty.pieceCount;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.difficulty.label,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              _isCompleted
                  ? '🎉 拼图已完成 · 耗时 ${_formatTime(_seconds)}'
                  : '用时 ${_formatTime(_seconds)} · 已对齐 $_solvedCount / $totalCount',
              style: theme.textTheme.bodySmall?.copyWith(
                color: _isCompleted
                    ? Colors.green
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: _isCompleted ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
        actions: [
          if (!_isCompleted) ...[
            IconButton(
              icon: const Icon(Icons.undo),
              tooltip: '撤销',
              onPressed: () {
                _game?.undo();
                setState(() {});
              },
            ),
            IconButton(
              icon: const Icon(Icons.redo),
              tooltip: '重做',
              onPressed: () {
                _game?.redo();
                setState(() {});
              },
            ),
            IconButton(
              icon: const Icon(Icons.lightbulb_outline),
              tooltip: '提示一块',
              onPressed: () {
                _game?.hint();
                setState(() => _hintsUsed++);
              },
            ),
          ],
          IconButton(
            icon: Icon(
              _showPreview ? Icons.visibility : Icons.visibility_off,
              color: _showPreview ? theme.colorScheme.primary : null,
            ),
            tooltip: '原图预览',
            onPressed: () => setState(() => _showPreview = !_showPreview),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新开始',
            onPressed: _restartGame,
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // 1. Flame Game Viewport
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_errorMessage != null)
              Center(child: Text(_errorMessage!))
            else if (_game != null)
              GameWidget(
                game: _game!,
              ),

            // 2. Full-scale overlay preview
            if (_showPreview)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(() => _showPreview = false),
                  child: Container(
                    color: Colors.black54,
                    alignment: Alignment.center,
                    child: Container(
                      margin: const EdgeInsets.all(32),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white, width: 3),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black87,
                            blurRadius: 16,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(9),
                        child: Image.memory(widget.imageBytes, fit: BoxFit.contain),
                      ),
                    ),
                  ),
                ),
              ),

            // 3. Completion Floating Banner (when dialog is dismissed)
            if (_isCompleted)
              Positioned(
                bottom: 16,
                left: 16,
                right: 16,
                child: Card(
                  elevation: 6,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.green, size: 28),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '拼图已完美完成！耗时 ${_formatTime(_seconds)}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _showCompletionDialog(context),
                          child: const Text('结算成绩'),
                        ),
                        FilledButton(
                          onPressed: _restartGame,
                          child: const Text('再来一局'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
