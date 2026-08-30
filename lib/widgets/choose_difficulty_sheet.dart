import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/game_repository.dart';
import '../logic/geometry/edge_layout.dart';
import '../logic/geometry/piece_shape.dart';
import '../logic/puzzle_model.dart';
import '../services/sound_service.dart';
import '../services/unlock_service.dart';

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
    this.sourcePlatform,
    this.sourceUrl,
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
  final String? sourcePlatform;
  final String? sourceUrl;

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
    String? sourcePlatform,
    String? sourceUrl,
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
        sourcePlatform: sourcePlatform,
        sourceUrl: sourceUrl,
      ),
    );
  }

  @override
  State<ChooseDifficultySheet> createState() => _ChooseDifficultySheetState();
}

class _ChooseDifficultySheetState extends State<ChooseDifficultySheet> {
  final _repo = GameRepository.instance;
  final _unlockService = UnlockService.instance;
  late PuzzleDifficulty _selectedDifficulty;
  double _imageWidth = 1.0;
  double _imageHeight = 1.0;
  bool _imageLoaded = false;
  late bool _showGridOverlay;

  final Map<int, UnlockStatus> _tierUnlockStatuses = {};

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
    for (var i = 0; i < 7; i++) {
      _tierUnlockStatuses[i] = _unlockService.checkDifficultyUnlockSync(i);
    }
    _decodeImageSize();
    _loadTierUnlocks();
  }

  Future<void> _loadTierUnlocks() async {
    for (var i = 0; i < 7; i++) {
      final st = await _unlockService.checkDifficultyUnlock(i);
      if (mounted) {
        setState(() {
          _tierUnlockStatuses[i] = st;
        });
      }
    }
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
        _loadTierUnlocks();
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
            Icon(PhosphorIconsBold.trash, color: Colors.redAccent),
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

  Future<void> _handleStart(PuzzleDifficulty diff) async {
    // 针对 2:3/3:2 矩形 L2（54块）断层弹窗二次确认
    if (diff.pieceCount == 54 && _aspectRatio != PuzzleAspectRatio.square1x1) {
      final prefs = await SharedPreferences.getInstance();
      final skip = prefs.getBool('skip_l2_gap_warning') ?? false;
      if (!skip && mounted) {
        var doNotShowAgain = false;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(PhosphorIconsBold.info, color: Colors.orange),
                  SizedBox(width: 8),
                  Text('难度提示'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('当前 54 块相比新手 24 块难度提升较大，碎片较为小巧。是否继续进入挑战？'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Checkbox(
                        value: doNotShowAgain,
                        onChanged: (v) => setDialogState(() => doNotShowAgain = v ?? false),
                      ),
                      const Text('不再提示此类跨度', style: TextStyle(fontSize: 13, color: Colors.black87)),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('换个难度'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2E7D32)),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('立即挑战'),
                ),
              ],
            ),
          ),
        );

        // 仅当玩家确认进入（立即挑战）且勾选"不再提示"时才写入，避免"换个难度"也永久跳过提示
        if (doNotShowAgain && confirmed == true) {
          await prefs.setBool('skip_l2_gap_warning', true);
        }

        if (confirmed != true) return;
      }
    }

    if (mounted) {
      Navigator.of(context).pop();
      widget.onStart(diff);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveDiff = _effectiveDifficulty;
    final currentTiers = _currentTiers;

    final selectedTier = currentTiers.firstWhere(
      (t) => t.difficulty.pieceCount == effectiveDiff.pieceCount,
      orElse: () => currentTiers.firstWhere(
        (t) => t.difficulty.recommended,
        orElse: () => currentTiers[0],
      ),
    );

    final isEffectivePassed = widget.completedPieceCounts.contains(effectiveDiff.pieceCount);
    final unlockStatus = _tierUnlockStatuses[effectiveDiff.tierIndex];
    final isTierUnlocked = unlockStatus?.isUnlocked ?? true;
    final isFullyPlayable = widget.isUnlocked && isTierUnlocked;

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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            // Drag handle
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 12, bottom: 4),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header: Title + Close & Delete
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (widget.sourcePlatform != null && widget.sourceUrl != null) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.teal.shade50,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: Colors.teal.shade200, width: 0.8),
                                ),
                                child: Text(
                                  widget.sourcePlatform!,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.teal.shade800,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  widget.sourceUrl!,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (widget.onDelete != null)
                    IconButton(
                      icon: const Icon(PhosphorIconsBold.trash, color: Colors.redAccent, size: 20),
                      tooltip: '删除此自制拼图',
                      onPressed: _confirmDelete,
                    ),
                  IconButton(
                    icon: const Icon(PhosphorIconsBold.x, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // Puzzle Image Preview Card with Grid Overlay
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  width: 280,
                  height: 180,
                  color: const Color(0xFFF0F0F0),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(
                        widget.imageBytes,
                        fit: BoxFit.cover,
                      ),
                      if (_showGridOverlay)
                        CustomPaint(
                          painter: _JigsawOverlayPainter(
                            rows: effectiveDiff.rows,
                            cols: effectiveDiff.cols,
                          ),
                        ),
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: Material(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () {
                              SoundService.I.play(Sfx.tap);
                              setState(() {
                                _showGridOverlay = !_showGridOverlay;
                              });
                              _repo.gridPreviewEnabled = _showGridOverlay;
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _showGridOverlay ? PhosphorIconsFill.gridFour : PhosphorIconsRegular.gridFour,
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _showGridOverlay ? '切图网格' : '无网格',
                                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Locked banner if overall level is locked
            if (!widget.isUnlocked)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.amber.shade400),
                  ),
                  child: Row(
                    children: [
                      const Icon(PhosphorIconsFill.lockSimple, color: Colors.orange, size: 18),
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
              )
            else if (!isTierUnlocked && unlockStatus != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange.shade300),
                  ),
                  child: Row(
                    children: [
                      const Icon(PhosphorIconsFill.lockSimple, color: Colors.deepOrange, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          unlockStatus.reason,
                          style: const TextStyle(
                            color: Color(0xFFD84315),
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
                          Icon(PhosphorIconsFill.checkCircle, size: 12, color: Color(0xFF2E7D32)),
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
            const SizedBox(height: 4),
            Text(
              '⏱️ 预计耗时：${selectedTier.estimatedMinutes}',
              style: const TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 14),

            // Horizontal scroll of 7 difficulty tiers
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final tier in currentTiers) ...[
                    _buildPieceOption(
                      tier,
                      isSelected: tier.difficulty.pieceCount == effectiveDiff.pieceCount,
                      isLocked: _tierUnlockStatuses[tier.difficulty.tierIndex]?.isUnlocked == false,
                    ),
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
                      if (isFullyPlayable && hasSavedProgress && isMatchingSavedDiff) ...[
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
                                const Icon(PhosphorIconsBold.clockCounterClockwise, size: 16, color: Color(0xFF2E7D32)),
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
                          onPressed: isFullyPlayable
                              ? () => _handleStart(effectiveDiff)
                              : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: isFullyPlayable ? const Color(0xFF2E7D32) : Colors.grey.shade400,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(26),
                            ),
                            elevation: isFullyPlayable ? 2 : 0,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (!isFullyPlayable) ...[
                                const Icon(PhosphorIconsFill.lockSimple, size: 18, color: Colors.white70),
                                const SizedBox(width: 6),
                              ],
                              Text(
                                !widget.isUnlocked
                                    ? '关卡未解锁'
                                    : (!isTierUnlocked
                                        ? '未解锁'
                                        : (hasSavedProgress && isMatchingSavedDiff
                                            ? '继续游玩 (进度 ${widget.savedProgressPercent}%)'
                                            : (isEffectivePassed ? '重玩此难度' : '开始'))),
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (hasSavedProgress && isMatchingSavedDiff && widget.onResetProgress != null) ...[
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () {
                            widget.onResetProgress?.call();
                            Navigator.of(context).pop();
                          },
                          icon: const Icon(PhosphorIconsBold.arrowCounterClockwise, size: 16, color: Colors.grey),
                          label: const Text(
                            '放弃进度并重新开始',
                            style: TextStyle(fontSize: 13, color: Colors.grey),
                          ),
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

  Widget _buildPieceOption(DifficultyTier tier, {required bool isSelected, bool isLocked = false}) {
    final opt = tier.difficulty;
    final isPassed = widget.completedPieceCounts.contains(opt.pieceCount);

    Color bgColor;
    Border? border;
    List<BoxShadow>? shadows;
    Color iconColor;
    Color textColor;

    if (isSelected) {
      bgColor = isLocked ? Colors.orange.shade700 : const Color(0xFF2E7D32);
      border = Border.all(color: isLocked ? Colors.orange.shade900 : const Color(0xFF1B5E20), width: 2.5);
      shadows = [
        BoxShadow(
          color: (isLocked ? Colors.orange : const Color(0xFF2E7D32)).withValues(alpha: 0.35),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ];
      iconColor = Colors.white;
      textColor = Colors.white;
    } else if (isLocked) {
      bgColor = const Color(0xFFEEEEEE);
      border = Border.all(color: Colors.grey.shade400, width: 1);
      shadows = null;
      iconColor = Colors.grey;
      textColor = Colors.grey.shade700;
    } else if (isPassed) {
      bgColor = const Color(0xFFE8F5E9);
      border = Border.all(color: const Color(0xFFA5D6A7), width: 1.5);
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
      onTap: () {
        SoundService.I.play(Sfx.tap);
        if (isLocked) {
          // 设计 §7.2：点击锁定档位 Toast 提示差距，且不可选中
          final status = _tierUnlockStatuses[tier.difficulty.tierIndex];
          final gap = (status?.targetRequired ?? 0) - (status?.currentProgress ?? 0);
          final msg = gap > 0
              ? '再获得 $gap 张 3 星图即可解锁 ${tier.tag}'
              : '该档位尚未解锁';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(msg),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        setState(() => _selectedDifficulty = opt);
      },
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: border,
          boxShadow: shadows,
        ),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isLocked ? PhosphorIconsFill.lockSimple : PhosphorIconsFill.puzzlePiece,
                  size: 18,
                  color: iconColor,
                ),
                const SizedBox(height: 1),
                Text(
                  '${opt.pieceCount}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                Text(
                  tier.tag,
                  style: TextStyle(
                    fontSize: 9.0,
                    color: isSelected ? Colors.white70 : Colors.black45,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            if (isPassed && !isLocked)
              Positioned(
                top: 0,
                right: 0,
                child: Icon(
                  PhosphorIconsFill.checkCircle,
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
