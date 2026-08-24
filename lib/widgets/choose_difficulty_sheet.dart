import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/game_repository.dart';
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

class DifficultyTier {
  const DifficultyTier({
    required this.difficulty,
    required this.tag,
    required this.estimatedMinutes,
  });

  final PuzzleDifficulty difficulty;
  final String tag;
  final String estimatedMinutes;
}

/// A bottom sheet dialog matching the commercial jigsaw piece selection UI.
class ChooseDifficultySheet extends StatefulWidget {
  const ChooseDifficultySheet({
    super.key,
    required this.imageBytes,
    required this.initialDifficulty,
    required this.title,
    required this.onStart,
    this.completedPieceCounts = const {},
    this.isUnlocked = true,
    this.lockedMessage,
    this.onDelete,
  });

  final Uint8List imageBytes;
  final PuzzleDifficulty initialDifficulty;
  final String title;
  final ValueChanged<PuzzleDifficulty> onStart;
  final Set<int> completedPieceCounts;
  final bool isUnlocked;
  final String? lockedMessage;
  final Future<void> Function()? onDelete;

  static Future<void> show({
    required BuildContext context,
    required Uint8List imageBytes,
    required PuzzleDifficulty initialDifficulty,
    required String title,
    required ValueChanged<PuzzleDifficulty> onStart,
    Set<int> completedPieceCounts = const {},
    bool isUnlocked = true,
    String? lockedMessage,
    Future<void> Function()? onDelete,
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
        isUnlocked: isUnlocked,
        lockedMessage: lockedMessage,
        onDelete: onDelete,
      ),
    );
  }

  @override
  State<ChooseDifficultySheet> createState() => _ChooseDifficultySheetState();
}

class _ChooseDifficultySheetState extends State<ChooseDifficultySheet> {
  final _repo = GameRepository.instance;
  late PuzzleDifficulty _selectedDifficulty;
  double _imageWidth = 1.0;
  double _imageHeight = 1.0;
  bool _imageLoaded = false;
  late bool _showGridOverlay;

  static const List<DifficultyTier> _tiers = [
    DifficultyTier(
      difficulty: PuzzleDifficulty(label: '3 × 3 (9 块)', rows: 3, cols: 3),
      tag: '新手入门',
      estimatedMinutes: '1~2分钟',
    ),
    DifficultyTier(
      difficulty: PuzzleDifficulty(label: '3 × 4 (12 块)', rows: 3, cols: 4),
      tag: '轻松休闲',
      estimatedMinutes: '2~3分钟',
    ),
    DifficultyTier(
      difficulty: PuzzleDifficulty(label: '4 × 4 (16 块)', rows: 4, cols: 4),
      tag: '经典标准',
      estimatedMinutes: '3~5分钟',
    ),
    DifficultyTier(
      difficulty: PuzzleDifficulty(label: '4 × 6 (24 块)', rows: 4, cols: 6),
      tag: '趣味进阶',
      estimatedMinutes: '5~8分钟',
    ),
    DifficultyTier(
      difficulty: PuzzleDifficulty(label: '6 × 6 (36 块)', rows: 6, cols: 6),
      tag: '探索挑战',
      estimatedMinutes: '8~12分钟',
    ),
    DifficultyTier(
      difficulty: PuzzleDifficulty(label: '6 × 8 (48 块)', rows: 6, cols: 8),
      tag: '高阶进阶',
      estimatedMinutes: '12~18分钟',
    ),
    DifficultyTier(
      difficulty: PuzzleDifficulty(label: '8 × 8 (64 块)', rows: 8, cols: 8),
      tag: '大师挑战',
      estimatedMinutes: '18~25分钟',
    ),
    DifficultyTier(
      difficulty: PuzzleDifficulty(label: '10 × 10 (100 块)', rows: 10, cols: 10),
      tag: '专家试炼',
      estimatedMinutes: '30+分钟',
    ),
    DifficultyTier(
      difficulty: PuzzleDifficulty(label: '12 × 16 (192 块)', rows: 12, cols: 16),
      tag: '宗师挑战',
      estimatedMinutes: '50+分钟',
    ),
    DifficultyTier(
      difficulty: PuzzleDifficulty(label: '20 × 20 (400 块)', rows: 20, cols: 20),
      tag: '终极地狱',
      estimatedMinutes: '1.5小时+',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _showGridOverlay = _repo.gridPreviewEnabled;
    _selectedDifficulty = _tiers
        .firstWhere(
          (t) => t.difficulty.pieceCount == widget.initialDifficulty.pieceCount,
          orElse: () => _tiers[0],
        )
        .difficulty;
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

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.delete_outline, color: Colors.redAccent),
            SizedBox(width: 8),
            Text('删除自制拼图'),
          ],
        ),
        content: Text('确定要删除「${widget.title}」吗？相关进度将被清除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('确定删除'),
          ),
        ],
      ),
    );

    if (ok == true && mounted) {
      Navigator.of(context).pop();
      await widget.onDelete?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final effectiveDiff = _effectiveDifficulty;
    final aspect = (_imageLoaded && _imageHeight > 0) ? (_imageWidth / _imageHeight) : 1.0;
    final isEffectivePassed = widget.completedPieceCounts.contains(effectiveDiff.pieceCount);

    final selectedTier = _tiers.firstWhere(
      (t) => t.difficulty.pieceCount == _selectedDifficulty.pieceCount,
      orElse: () => _tiers[0],
    );

    return Container(
      height: size.height * 0.90,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        children: [
          // Top bar with Title & Grid Preview toggle & Delete (if UGC) & Close
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _showGridOverlay ? Icons.grid_on : Icons.grid_off,
                    color: _showGridOverlay ? const Color(0xFF2E7D32) : Colors.black45,
                    size: 22,
                  ),
                  tooltip: _showGridOverlay ? '隐藏切片网格' : '显示切片网格',
                  onPressed: () {
                    setState(() => _showGridOverlay = !_showGridOverlay);
                    _repo.gridPreviewEnabled = _showGridOverlay;
                  },
                ),
                if (widget.onDelete != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 22),
                    tooltip: '删除此自制拼图',
                    onPressed: _confirmDelete,
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    '关闭',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.black54,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // High-res Image Preview with Real-time Jigsaw Grid Overlay
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
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
                          blurRadius: 12,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(widget.imageBytes, fit: BoxFit.cover),
                        if (_showGridOverlay)
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

          const SizedBox(height: 8),

          // Locked Level Tip Banner if level is not yet unlocked
          if (!widget.isUnlocked)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber.shade400),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.lock, color: Colors.orange, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.lockedMessage ?? '此关卡尚未解锁，请先通关前序关卡',
                        style: const TextStyle(
                          color: Color(0xFFE65100),
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 6),

          // Difficulty Info Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    selectedTier.tag,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1B5E20),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${effectiveDiff.rows} × ${effectiveDiff.cols} (${effectiveDiff.pieceCount} 块)',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '⏱️ ${selectedTier.estimatedMinutes}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
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
          ),
          const SizedBox(height: 12),

          // Horizontal scroll of puzzle difficulty tiers
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final tier in _tiers) ...[
                  _buildPieceOption(tier),
                  const SizedBox(width: 10),
                ],
              ],
            ),
          ),

          const SizedBox(height: 18),

          // Big Start CTA Button
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: widget.isUnlocked
                    ? () {
                        Navigator.of(context).pop();
                        widget.onStart(effectiveDiff);
                      }
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: widget.isUnlocked ? const Color(0xFF2E7D32) : Colors.grey.shade400,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                  ),
                  elevation: widget.isUnlocked ? 2 : 0,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (!widget.isUnlocked) ...[
                      const Icon(Icons.lock, size: 18, color: Colors.white70),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      !widget.isUnlocked
                          ? '关卡未解锁 (请先通关前序关卡)'
                          : (isEffectivePassed ? '重玩此难度' : '开始'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPieceOption(DifficultyTier tier) {
    final opt = tier.difficulty;
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
      bgColor = const Color(0xFFE8F5E9);
      border = Border.all(color: const Color(0xFF81C784), width: 1.5);
      shadows = null;
      iconColor = const Color(0xFF2E7D32);
      textColor = const Color(0xFF1B5E20);
    } else {
      bgColor = const Color(0xFFF4F6F8);
      border = Border.all(color: const Color(0xFFE0E0E0), width: 1);
      shadows = null;
      iconColor = Colors.black54;
      textColor = Colors.black87;
    }

    return InkWell(
      onTap: () => setState(() => _selectedDifficulty = opt),
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 72,
        height: 76,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: border,
          boxShadow: shadows,
        ),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.extension, size: 20, color: iconColor),
                const SizedBox(height: 2),
                Text(
                  '${opt.pieceCount}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                Text(
                  tier.tag,
                  style: TextStyle(
                    fontSize: 9.5,
                    color: isSelected ? Colors.white70 : Colors.black45,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            if (isPassed)
              Positioned(
                top: 0,
                right: 2,
                child: Icon(
                  Icons.check_circle,
                  size: 13,
                  color: isSelected ? const Color(0xFFFFD54F) : const Color(0xFF2E7D32),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
