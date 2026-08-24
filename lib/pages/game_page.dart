import 'dart:async';

import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/game_repository.dart';
import '../game/jigsaw_puzzle_game.dart';
import '../logic/puzzle_model.dart';

/// Full-screen in-game puzzle page matching commercial Jigsaw (`play.jpg`).
class GamePage extends StatefulWidget {
  const GamePage({
    super.key,
    required this.imageBytes,
    required this.difficulty,
    this.levelIndex,
    this.dailyDateStr,
    this.customId,
    this.initialSnapshotJson,
  });

  final Uint8List imageBytes;
  final PuzzleDifficulty difficulty;
  final int? levelIndex;
  final String? dailyDateStr;
  final String? customId;
  final String? initialSnapshotJson;

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> {
  final _repo = GameRepository.instance;
  JigsawPuzzleGame? _game;

  bool _isSolved = false;
  int _seconds = 0;
  Timer? _timer;
  int _solvedPieces = 0;
  bool _showGhostPreview = false;
  bool _isBorderFiltered = false;

  // Multi-touch tracking for pinch-to-zoom & two-finger pan
  final Map<int, Offset> _pointerPositions = {};
  double _baseDistance = 0.0;
  double _baseZoom = 1.0;
  Offset _baseFocalPoint = Offset.zero;
  Vector2 _basePan = Vector2.zero();

  @override
  void initState() {
    super.initState();
    _startTimer();
    _loadImage();
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isSolved && mounted) {
        setState(() => _seconds++);
      }
    });
  }

  Future<void> _loadImage() async {
    final img = await decodeFlameImage(widget.imageBytes);
    final effectiveDiff = widget.difficulty
        .adaptiveForSize(img.width.toDouble(), img.height.toDouble());

    final game = JigsawPuzzleGame(
      image: img,
      rows: effectiveDiff.rows,
      cols: effectiveDiff.cols,
      initialSnapshotJson: widget.initialSnapshotJson,
      onSolved: _handleSolved,
      onPieceSnapped: () {
        _repo.recordSnapStats(pieceCount: 1);
      },
      onProgressChanged: (count) {
        if (mounted) setState(() => _solvedPieces = count);
        _autoSaveProgress();
      },
    );

    if (mounted) {
      setState(() {
        _game = game;
      });
    }
  }

  void _autoSaveProgress() {
    if (_game == null || _isSolved) return;
    final total = widget.difficulty.pieceCount;
    final percent = total > 0 ? (_solvedPieces * 100 ~/ total) : 0;
    final snapshot = _game!.exportSnapshotJson();

    if (widget.levelIndex != null) {
      _repo.updateLevelProgress(
        levelIndex: widget.levelIndex!,
        progressPercent: percent,
        snapshotJson: snapshot,
      );
    } else if (widget.dailyDateStr != null) {
      _repo.updateDailyProgress(
        dateStr: widget.dailyDateStr!,
        progressPercent: percent,
        snapshotJson: snapshot,
      );
    } else if (widget.customId != null) {
      _repo.updateCustomProgress(
        id: widget.customId!,
        progressPercent: percent,
        snapshotJson: snapshot,
      );
    }
  }

  void _handleSolved() {
    if (_isSolved) return;
    _timer?.cancel();
    setState(() {
      _isSolved = true;
      _solvedPieces = widget.difficulty.pieceCount;
    });

    _repo.recordSnapStats(durationSeconds: _seconds);

    if (widget.levelIndex != null) {
      _repo.updateLevelProgress(
        levelIndex: widget.levelIndex!,
        progressPercent: 100,
        isCompleted: true,
        stars: 3,
        timeSeconds: _seconds,
      );
    } else if (widget.dailyDateStr != null) {
      _repo.updateDailyProgress(
        dateStr: widget.dailyDateStr!,
        progressPercent: 100,
        isCompleted: true,
        timeSeconds: _seconds,
      );
    } else if (widget.customId != null) {
      _repo.updateCustomProgress(
        id: widget.customId!,
        progressPercent: 100,
        isCompleted: true,
        timeSeconds: _seconds,
      );
    }

    _showVictoryDialog();
  }

  String get _timeString {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _showFullImagePreview() {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.memory(widget.imageBytes, fit: BoxFit.contain),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭预览'),
            ),
          ],
        ),
      ),
    );
  }

  void _showVictoryDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Text('🎉 ', style: TextStyle(fontSize: 24)),
            Text('恭喜通关！', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  widget.imageBytes,
                  height: 160,
                  width: 300,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '总用时：$_timeString',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 4),
              Text(
                '规格：${widget.difficulty.label}',
                style: const TextStyle(fontSize: 14, color: Colors.black54),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('查看拼图'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2E7D32),
            ),
            child: const Text('返回列表'),
          ),
        ],
      ),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointerPositions[event.pointer] = event.localPosition;
    if (_pointerPositions.length == 2) {
      final p1 = _pointerPositions.values.first;
      final p2 = _pointerPositions.values.last;
      _baseDistance = (p1 - p2).distance;
      _baseZoom = _game?.zoom ?? 1.0;
      _baseFocalPoint = (p1 + p2) / 2;
      _basePan = _game?.panOffset.clone() ?? Vector2.zero();
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    _pointerPositions[event.pointer] = event.localPosition;
    if (_pointerPositions.length == 2 && _game != null) {
      final p1 = _pointerPositions.values.first;
      final p2 = _pointerPositions.values.last;
      final curDist = (p1 - p2).distance;
      final curFocal = (p1 + p2) / 2;
      if (_baseDistance > 10.0) {
        final scaleFactor = curDist / _baseDistance;
        final newZoom = (_baseZoom * scaleFactor).clamp(1.0, _game!.maxZoom);
        final panDelta = curFocal - _baseFocalPoint;
        final newPan = _basePan + Vector2(panDelta.dx, panDelta.dy);
        _game!.setZoomAndPan(newZoom, newPan);
        if (mounted) setState(() {});
      }
    } else if ((event.buttons & kMiddleMouseButton) != 0 && _game != null) {
      _game!.panBy(Vector2(event.delta.dx, event.delta.dy));
      if (mounted) setState(() {});
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    _pointerPositions.remove(event.pointer);
    if (_pointerPositions.length < 2) {
      _baseDistance = 0.0;
    }
    if (mounted) setState(() {});
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointerPositions.remove(event.pointer);
    if (_pointerPositions.length < 2) {
      _baseDistance = 0.0;
    }
    if (mounted) setState(() {});
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && _game != null) {
      final isCtrl = HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      final mousePos = event.localPosition;
      final inTray = mousePos.dy >= _game!.trayPosition.y;

      if (isCtrl || (!inTray && event.scrollDelta.dy.abs() > 0)) {
        final zoomDelta = -event.scrollDelta.dy * 0.003;
        _game!.zoomAt(Vector2(mousePos.dx, mousePos.dy), zoomDelta);
        if (mounted) setState(() {});
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE2E6EA),
      body: SafeArea(
        child: Stack(
          children: [
            // 1. Core Flame Game Canvas with Multi-Modal Zoom & Pan Gesture Listener
            if (_game != null)
              Positioned.fill(
                child: Listener(
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                  onPointerCancel: _onPointerCancel,
                  onPointerSignal: _onPointerSignal,
                  behavior: HitTestBehavior.translucent,
                  child: GameWidget(game: _game!),
                ),
              )
            else
              const Center(child: CircularProgressIndicator()),

            // 2. Ghost semi-transparent original image overlay (pixel-perfect with board)
            if (_showGhostPreview && _game != null)
              Positioned(
                left: _game!.boardTopLeft.x + _game!.panOffset.x,
                top: _game!.boardTopLeft.y + _game!.panOffset.y,
                width: _game!.boardSize.x * _game!.zoom,
                height: _game!.boardSize.y * _game!.zoom,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.35,
                    child: Image.memory(
                      widget.imageBytes,
                      fit: BoxFit.fill,
                    ),
                  ),
                ),
              ),

            // 3. Top 6-Button Toolbar matching play.jpg
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.white.withValues(alpha: 0.92),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Back arrow (auto-saves snapshot)
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.black87),
                      onPressed: () {
                        _autoSaveProgress();
                        Navigator.of(context).pop();
                      },
                    ),

                    // Border Filter Button
                    IconButton(
                      icon: Icon(
                        Icons.border_outer,
                        color: _isBorderFiltered ? const Color(0xFF2E7D32) : Colors.black54,
                      ),
                      tooltip: '边缘碎片筛选',
                      onPressed: () {
                        _game?.toggleBorderFilter();
                        setState(() => _isBorderFiltered = _game?.isBorderFilterActive ?? false);
                      },
                    ),

                    // Clean / Organize Tray Button (Broom / Sweep)
                    IconButton(
                      icon: const Icon(Icons.cleaning_services_outlined, color: Colors.black54),
                      tooltip: '一键整理托盘',
                      onPressed: () => _game?.organizeTray(),
                    ),

                    // Hint Button (Lightbulb)
                    IconButton(
                      icon: const Icon(Icons.lightbulb_outline, color: Colors.amber),
                      tooltip: '智能提示',
                      onPressed: () => _game?.hint(),
                    ),

                    // Ghost Transparency Eye
                    IconButton(
                      icon: Icon(
                        _showGhostPreview ? Icons.visibility : Icons.visibility_off_outlined,
                        color: _showGhostPreview ? const Color(0xFF2E7D32) : Colors.black54,
                      ),
                      tooltip: '半透明底图',
                      onPressed: () => setState(() => _showGhostPreview = !_showGhostPreview),
                    ),

                    // Full image thumbnail preview
                    IconButton(
                      icon: const Icon(Icons.image_outlined, color: Colors.black87),
                      tooltip: '查看原图',
                      onPressed: _showFullImagePreview,
                    ),
                  ],
                ),
              ),
            ),

            // 4. Floating Zoom Level Badge and Reset Button when zoomed
            if (_game != null && _game!.zoom > 1.02)
              Positioned(
                top: 54,
                right: 12,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      _game?.resetZoom();
                      setState(() {});
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.zoom_in, color: Colors.white, size: 16),
                          const SizedBox(width: 4),
                          Text(
                            '${(_game!.zoom * 100).toInt()}%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            '重置',
                            style: TextStyle(
                              color: Colors.amberAccent,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // 5. Floating Victory Banner when solved and dialog closed
            if (_isSolved)
              Positioned(
                bottom: 16,
                left: 20,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E7D32),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [
                      BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 4)),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '🎉 拼图完成！耗时 $_timeString',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Row(
                        children: [
                          TextButton(
                            onPressed: _showVictoryDialog,
                            child: const Text('结算成绩', style: TextStyle(color: Colors.white70)),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context),
                            style: FilledButton.styleFrom(backgroundColor: Colors.white),
                            child: const Text('返回', style: TextStyle(color: Color(0xFF2E7D32))),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
