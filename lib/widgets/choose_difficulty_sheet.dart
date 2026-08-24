import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../logic/geometry/edge_layout.dart';
import '../logic/geometry/piece_shape.dart';
import '../logic/puzzle_model.dart';

/// Custom painter rendering dynamic jigsaw grid preview lines over selected puzzle image.
class _JigsawOverlayPainter extends CustomPainter {
  _JigsawOverlayPainter({
    required this.rows,
    required this.cols,
    this.seed = 42,
  }) : edgeLayout = EdgeLayout(rows: rows, cols: cols, seed: seed);

  final int rows;
  final int cols;
  final int seed;
  final EdgeLayout edgeLayout;

  static final Paint _shadowPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.6
    ..color = const Color(0x77000000)
    ..isAntiAlias = true;

  static final Paint _linePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0
    ..color = const Color(0xEEFFFFFF)
    ..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    if (rows <= 0 || cols <= 0 || size.width <= 0 || size.height <= 0) return;

    final pieceW = size.width / cols;
    final pieceH = size.height / rows;

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final edges = edgeLayout.edgesFor(r, c);
        final shape = PieceShape(
          edges: edges,
          width: pieceW,
          height: pieceH,
        );

        canvas.save();
        canvas.translate(c * pieceW, r * pieceH);
        canvas.drawPath(shape.path, _shadowPaint);
        canvas.drawPath(shape.path, _linePaint);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _JigsawOverlayPainter oldDelegate) {
    return oldDelegate.rows != rows ||
        oldDelegate.cols != cols ||
        oldDelegate.seed != seed;
  }
}

/// A bottom sheet dialog matching the commercial jigsaw piece selection UI (`choose.jpg`).
class ChooseDifficultySheet extends StatefulWidget {
  const ChooseDifficultySheet({
    super.key,
    required this.imageBytes,
    required this.initialDifficulty,
    required this.title,
    required this.onStart,
    this.completedPieceCounts = const {},
  });

  final Uint8List imageBytes;
  final PuzzleDifficulty initialDifficulty;
  final String title;
  final ValueChanged<PuzzleDifficulty> onStart;
  final Set<int> completedPieceCounts;

  static Future<void> show({
    required BuildContext context,
    required Uint8List imageBytes,
    required PuzzleDifficulty initialDifficulty,
    required String title,
    required ValueChanged<PuzzleDifficulty> onStart,
    Set<int> completedPieceCounts = const {},
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChooseDifficultySheet(
        imageBytes: imageBytes,
        initialDifficulty: initialDifficulty,
        title: title,
        onStart: onStart,
        completedPieceCounts: completedPieceCounts,
      ),
    );
  }

  @override
  State<ChooseDifficultySheet> createState() => _ChooseDifficultySheetState();
}

class _ChooseDifficultySheetState extends State<ChooseDifficultySheet> {
  late PuzzleDifficulty _selectedDifficulty;
  double _imageWidth = 1.0;
  double _imageHeight = 1.0;
  bool _imageLoaded = false;

  static const List<PuzzleDifficulty> _selectableOptions = [
    PuzzleDifficulty(label: '3 × 3 (9 块)', rows: 3, cols: 3),
    PuzzleDifficulty(label: '3 × 4 (12 块)', rows: 3, cols: 4),
    PuzzleDifficulty(label: '4 × 4 (16 块)', rows: 4, cols: 4),
    PuzzleDifficulty(label: '4 × 6 (24 块)', rows: 4, cols: 6),
    PuzzleDifficulty(label: '6 × 6 (36 块)', rows: 6, cols: 6),
    PuzzleDifficulty(label: '6 × 8 (48 块)', rows: 6, cols: 8),
    PuzzleDifficulty(label: '8 × 8 (64 块)', rows: 8, cols: 8),
    PuzzleDifficulty(label: '10 × 10 (100 块)', rows: 10, cols: 10),
    PuzzleDifficulty(label: '12 × 16 (192 块)', rows: 12, cols: 16),
    PuzzleDifficulty(label: '20 × 20 (400 块)', rows: 20, cols: 20),
  ];

  @override
  void initState() {
    super.initState();
    _selectedDifficulty = _selectableOptions.firstWhere(
      (d) =>
          d.pieceCount == widget.initialDifficulty.pieceCount,
      orElse: () => _selectableOptions[0],
    );
    _decodeImageSize();
  }

  Future<void> _decodeImageSize() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.imageBytes);
      final frame = await codec.getNextFrame();
      if (mounted) {
        setState(() {
          _imageWidth = frame.image.width.toDouble();
          _imageHeight = frame.image.height.toDouble();
          _imageLoaded = true;
        });
      }
    } catch (_) {}
  }

  PuzzleDifficulty get _effectiveDifficulty {
    if (!_imageLoaded || _imageWidth <= 0 || _imageHeight <= 0) {
      return _selectedDifficulty;
    }
    return _selectedDifficulty.adaptiveForSize(_imageWidth, _imageHeight);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final effectiveDiff = _effectiveDifficulty;
    final aspect = (_imageLoaded && _imageHeight > 0) ? (_imageWidth / _imageHeight) : 1.0;
    final isEffectivePassed = widget.completedPieceCounts.contains(effectiveDiff.pieceCount);

    return Container(
      height: size.height * 0.88,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Top bar with Cancel
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    '取消',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF2E7D32),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // High-res Image Preview with Real-time Jigsaw Grid Overlay (matching exact image aspect ratio)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Center(
                child: AspectRatio(
                  aspectRatio: aspect,
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black12,
                          blurRadius: 10,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(widget.imageBytes, fit: BoxFit.cover),
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _JigsawOverlayPainter(
                              rows: effectiveDiff.rows,
                              cols: effectiveDiff.cols,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 14),

          // Difficulty Selector Header with Adaptive spec indicator & Passed badge
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '选择难度 · ${effectiveDiff.rows}×${effectiveDiff.cols} (${effectiveDiff.pieceCount} 块)',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              if (isEffectivePassed) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF81C784)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle, size: 13, color: Color(0xFF2E7D32)),
                      SizedBox(width: 2),
                      Text(
                        '已通关',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2E7D32),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),

          // Puzzle Piece shaped difficulty selectors with passed indicators
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final opt in _selectableOptions) ...[
                  _buildPieceOption(opt),
                  const SizedBox(width: 12),
                ],
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Big Green Start Button
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
            child: SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onStart(effectiveDiff);
                },
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                  elevation: 2,
                ),
                child: Text(
                  isEffectivePassed ? '重玩此难度' : '开始',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPieceOption(PuzzleDifficulty opt) {
    final isSelected = opt.pieceCount == _selectedDifficulty.pieceCount;
    final isPassed = widget.completedPieceCounts.contains(opt.pieceCount);

    Color bgColor;
    Border border;
    List<BoxShadow>? shadows;
    Color iconColor;
    Color textColor;

    if (isSelected) {
      bgColor = const Color(0xFF2E7D32);
      border = Border.all(color: const Color(0xFF1B5E20), width: 2);
      shadows = [
        BoxShadow(
          color: const Color(0xFF2E7D32).withValues(alpha: 0.35),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ];
      iconColor = Colors.white;
      textColor = Colors.white;
    } else if (isPassed) {
      bgColor = const Color(0xFFE8F5E9); // Light green background for passed difficulty
      border = Border.all(color: const Color(0xFF81C784), width: 1.5);
      shadows = [
        BoxShadow(
          color: const Color(0xFF4CAF50).withValues(alpha: 0.15),
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ];
      iconColor = const Color(0xFF2E7D32);
      textColor = const Color(0xFF1B5E20);
    } else {
      bgColor = const Color(0xFFF0F2F5);
      border = Border.all(color: const Color(0xFFE0E0E0), width: 1);
      shadows = null;
      iconColor = Colors.black54;
      textColor = Colors.black87;
    }

    return InkWell(
      onTap: () => setState(() => _selectedDifficulty = opt),
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 70,
        height: 70,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: border,
          boxShadow: shadows,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.extension,
                  size: 22,
                  color: iconColor,
                ),
                const SizedBox(height: 3),
                Text(
                  '${opt.pieceCount}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
              ],
            ),
            if (isPassed)
              Positioned(
                top: 4,
                right: 4,
                child: Icon(
                  Icons.check_circle,
                  size: 14,
                  color: isSelected ? const Color(0xFFFFD54F) : const Color(0xFF2E7D32),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
