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
    this.savedProgressPercent,
    this.onResetProgress,
  });

  final Uint8List imageBytes;
  final PuzzleDifficulty initialDifficulty;
  final String title;
  final ValueChanged<PuzzleDifficulty> onStart;
  final Set<int> completedPieceCounts;
  final bool isUnlocked;
  final String? lockedMessage;
  final Future<void> Function()? onDelete;
  final int? savedProgressPercent;
  final VoidCallback? onResetProgress;

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
    int? savedProgressPercent,
    VoidCallback? onResetProgress,
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
        savedProgressPercent: savedProgressPercent,
        onResetProgress: onResetProgress,
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

  PuzzleAspectRatio get _aspectRatio =>
      PuzzleAspectRatio.fromSize(_imageWidth, _imageHeight);

  List<DifficultyTier> get _currentTiers => _aspectRatio.tiers;

  @override
  void initState() {
    super.initState();
    _showGridOverlay = _repo.gridPreviewEnabled;
    final defaultTiers = PuzzleAspectRatio.square1x1.tiers;
    _selectedDifficulty = defaultTiers
        .firstWhere(
          (t) => t.difficulty.pieceCount == widget.initialDifficulty.pieceCount,
          orElse: () => defaultTiers[0],
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

          final aspect = PuzzleAspectRatio.fromSize(_imageWidth, _imageHeight);
          final tiers = aspect.tiers;
          _selectedDifficulty = tiers
              .firstWhere(
                (t) => t.difficulty.pieceCount == widget.initialDifficulty.pieceCount,
                orElse: () => tiers.firstWhere(
                  (t) => t.difficulty.recommended,
                  orElse: () => tiers[0],
                ),
              )
              .difficulty;
        });
      }
    } catch (_) {}
  }

  PuzzleDifficulty get _effectiveDifficulty {
    if (!_imageLoaded || _imageWidth <= 0 || _imageHeight <= 0) {
      return _selectedDifficulty;
    }
    // Match against current tiers
    final tiers = _currentTiers;
    return tiers
        .firstWhere(
          (t) => t.difficulty.pieceCount == _selectedDifficulty.pieceCount,
          orElse: () => tiers.firstWhere(
            (t) => t.difficulty.recommended,
            orElse: () => tiers[0],
          ),
        )
        .difficulty;
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
        content: Text('确定要永久删除「${widget.title}」吗？删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定删除'),
          ),
        ],
      ),
    );

    if (ok == true && mounted) {
      Navigator.of(context).pop();
      widget.onDelete?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveDiff = _effectiveDifficulty;
    final currentTiers = _currentTiers;

    final selectedTier = currentTiers.firstWhere(
      (t) => t.difficulty.pieceCount == effectiveDiff.pieceCount,
      orElse: () => currentTiers[0],
    );

    final isEffectivePassed =
        widget.completedPieceCounts.contains(effectiveDiff.pieceCount);

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Drag handle bar
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 44,
                  height: 4.5,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),

              // Header with Title & Action Icons
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.grid_view_rounded, color: Color(0xFF2E7D32), size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      fontSize: 17,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                // UGC Delete Button if available
                if (widget.onDelete != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 22),
                    tooltip: '删除此拼图',
                    onPressed: _confirmDelete,
                  ),

                // Grid preview lines toggle button
                IconButton(
                  icon: Icon(
                    _showGridOverlay ? Icons.grid_on : Icons.grid_off,
                    color: _showGridOverlay ? const Color(0xFF2E7D32) : Colors.grey,
                    size: 22,
                  ),
                  tooltip: _showGridOverlay ? '隐藏网格切线预览' : '显示网格切线预览',
                  onPressed: () {
                    setState(() {
                      _showGridOverlay = !_showGridOverlay;
                      _repo.gridPreviewEnabled = _showGridOverlay;
                    });
                  },
                ),

                IconButton(
                  icon: const Icon(Icons.close, color: Colors.black54, size: 22),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          const Divider(height: 1),
          const SizedBox(height: 10),

          // High-Res Image Preview with Dynamic Jigsaw Cut Grid Overlay
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  constraints: const BoxConstraints(
                    maxHeight: 200,
                    maxWidth: 320,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.10),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: AspectRatio(
                    aspectRatio: _imageLoaded && _imageWidth > 0 && _imageHeight > 0
                        ? _imageWidth / _imageHeight
                        : 1.0,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.memory(
                          widget.imageBytes,
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.medium,
                        ),
                        if (_showGridOverlay)
                          CustomPaint(
                            painter: _JigsawOverlayPainter(
                              rows: effectiveDiff.rows,
                              cols: effectiveDiff.cols,
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

          // Difficulty & Aspect Ratio Info Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                // Aspect Ratio Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE3F2FD),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF90CAF9)),
                  ),
                  child: Text(
                    _aspectRatio.label,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0D47A1),
                    ),
                  ),
                ),

                // Tier Tag Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    selectedTier.tag,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1B5E20),
                    ),
                  ),
                ),

                Text(
                  '${effectiveDiff.cols} × ${effectiveDiff.rows} (${effectiveDiff.pieceCount} 块)',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                    fontSize: 14.5,
                  ),
                ),

                Text(
                  '⏱️ ${selectedTier.estimatedMinutes}',
                  style: const TextStyle(fontSize: 11.5, color: Colors.black54),
                ),

                if (isEffectivePassed)
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
                        Icon(Icons.check_circle, size: 12, color: Color(0xFF2E7D32)),
                        SizedBox(width: 2),
                        Text(
                          '已通关',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF2E7D32),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Horizontal scroll of puzzle difficulty tiers for current aspect ratio
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final tier in currentTiers) ...[
                  _buildPieceOption(tier, isSelected: tier.difficulty.pieceCount == effectiveDiff.pieceCount),
                  const SizedBox(width: 10),
                ],
              ],
            ),
          ),

          const SizedBox(height: 18),

          // Big Start CTA Button with Saved Progress Detection
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Builder(
              builder: (context) {
                final hasSavedProgress = widget.savedProgressPercent != null && widget.savedProgressPercent! > 0;
                final isMatchingSavedDiff = _selectedDifficulty.pieceCount == widget.initialDifficulty.pieceCount;

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.isUnlocked && hasSavedProgress && isMatchingSavedDiff) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE8F5E9),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF81C784)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.history, size: 16, color: Color(0xFF2E7D32)),
                              const SizedBox(width: 6),
                              Text(
                                '⚡ 检测到未完成存档 (已拼 ${widget.savedProgressPercent}%)',
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF2E7D32),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    SizedBox(
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
                                  : (hasSavedProgress && isMatchingSavedDiff
                                      ? '继续游玩 (进度 ${widget.savedProgressPercent}%)'
                                      : (isEffectivePassed ? '重玩此难度' : '开始')),
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
                    if (widget.isUnlocked && hasSavedProgress && isMatchingSavedDiff && widget.onResetProgress != null) ...[
                      const SizedBox(height: 6),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.of(context).pop();
                          widget.onResetProgress?.call();
                        },
                        icon: const Icon(Icons.refresh, size: 16, color: Colors.black54),
                        label: const Text('放弃进度并重新开始', style: TextStyle(color: Colors.black54, fontSize: 13)),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
    ),
    );
  }

  Widget _buildPieceOption(DifficultyTier tier, {required bool isSelected}) {
    final opt = tier.difficulty;
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
        width: 76,
        height: 78,
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
