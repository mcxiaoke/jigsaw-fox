import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:jigsawpuzzle/widgets/game_toast.dart';
import 'package:path_provider/path_provider.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// Social share card generator — produces a 1080x1920 portrait PNG
/// featuring the completed puzzle image, stats, and fox mascot watermark.
///
/// Roadmap P3 5.3: Social Share Card Generator
class ShareCardGenerator extends StatefulWidget {
  const ShareCardGenerator({
    required this.imageBytes,
    required this.elapsedSeconds,
    required this.pieceCount,
    required this.starCount,
    required this.stepCount,
    super.key,
    this.levelTitle,
  });

  final Uint8List imageBytes;
  final int elapsedSeconds;
  final int pieceCount;
  final int starCount; // 0-3
  final int stepCount;
  final String? levelTitle;

  /// Push as full-screen page
  static Future<void> open(
    BuildContext context, {
    required Uint8List imageBytes,
    required int elapsedSeconds,
    required int pieceCount,
    required int starCount,
    required int stepCount,
    String? levelTitle,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ShareCardGenerator(
          imageBytes: imageBytes,
          elapsedSeconds: elapsedSeconds,
          pieceCount: pieceCount,
          starCount: starCount,
          stepCount: stepCount,
          levelTitle: levelTitle,
        ),
      ),
    );
  }

  @override
  State<ShareCardGenerator> createState() => _ShareCardGeneratorState();
}

class _ShareCardGeneratorState extends State<ShareCardGenerator>
    with SingleTickerProviderStateMixin {
  final GlobalKey _repaintKey = GlobalKey();
  late AnimationController _fadeController;
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    unawaited(_fadeController.forward());
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  String _formatTime(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _exportPng() async {
    setState(() => _isExporting = true);
    try {
      final boundary =
          _repaintKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) throw Exception('Failed to encode PNG');

        final dir = await getTemporaryDirectory();
        final ts = DateTime.now().millisecondsSinceEpoch;
        final file = File('${dir.path}/share_card_$ts.png');
        await file.writeAsBytes(
          byteData.buffer.asUint8List(
            byteData.offsetInBytes,
            byteData.lengthInBytes,
          ),
        );
      } finally {
        image.dispose();
      }

      if (mounted) {
        GameToast.show(
          context,
          message: t.share.toastSaved,
          type: GameToastType.success,
          icon: PhosphorIconsFill.checkCircle,
        );
      }
      // best-effort：失败降级，不阻断主流程
      // ignore: avoid_catches_without_on_clauses
    } catch (e) {
      if (mounted) {
        GameToast.show(
          context,
          message: t.share.toastExportFailed(error: e),
          type: GameToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);

    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(
        backgroundColor: palette.surface,
        foregroundColor: palette.primaryText,
        elevation: 0.5,
        leading: IconButton(
          icon: Icon(
            PhosphorIconsBold.x,
            color: palette.secondaryText,
            size: 22,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(t.share.title, style: styles.h3.copyWith(fontSize: 18)),
        actions: [
          IconButton(
            icon: Icon(
              PhosphorIconsBold.shareNetwork,
              color: palette.brand,
              size: 22,
            ),
            tooltip: t.share.exportTooltip,
            onPressed: _isExporting ? null : _exportPng,
          ),
        ],
      ),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeController,
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Share Card (preview of 1080x1920) ──
                  RepaintBoundary(
                    key: _repaintKey,
                    child: AspectRatio(
                      aspectRatio: 1080 / 1920,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              palette.surfaceContainer,
                              palette.surfaceContainerLow,
                            ],
                          ),
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // ── Decorative confetti dots ──
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _ConfettiDotsPainter(palette: palette),
                              ),
                            ),

                            // ── Main content column ──
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 36,
                                vertical: 48,
                              ),
                              child: Column(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  // Title area
                                  Column(
                                    children: [
                                      Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          gradient: AppPalette.brandGradient,
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                        ),
                                        child: const Center(
                                          child: Text(
                                            '\u{1F98A}',
                                            style: TextStyle(fontSize: 26),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        t.share.completed,
                                        style: styles.h2.copyWith(
                                          color: palette.brand,
                                          fontSize: 26,
                                        ),
                                      ),
                                      if (widget.levelTitle != null) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          widget.levelTitle!,
                                          style: styles.caption.copyWith(
                                            color: palette.secondaryText,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ],
                                  ),

                                  // Puzzle image with brand border
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 16,
                                      ),
                                      child: AspectRatio(
                                        aspectRatio: 1,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                            border: Border.all(
                                              color: palette.brand,
                                              width: 3,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: palette.brand.withValues(
                                                  alpha: 0.2,
                                                ),
                                                blurRadius: 16,
                                                offset: const Offset(0, 4),
                                              ),
                                            ],
                                          ),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              18,
                                            ),
                                            child: Image.memory(
                                              widget.imageBytes,
                                              fit: BoxFit.cover,
                                              // 解码期降采样。分享卡导出用 pixelRatio: 2.0，
                                              // 卡面图区实际渲染约 270px → 导出约 540px，
                                              // 1080 已留足 2 倍余量，不影响导出清晰度。
                                              cacheWidth: 1080,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

                                  // Stars row
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: List.generate(3, (i) {
                                      final earned = i < widget.starCount;
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                        ),
                                        child: Icon(
                                          PhosphorIconsFill.star,
                                          size: 36,
                                          color: earned
                                              ? palette.gold
                                              : palette.divider,
                                        ),
                                      );
                                    }),
                                  ),

                                  // Stats row
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 16,
                                    ),
                                    decoration: BoxDecoration(
                                      color: palette.surface.withValues(
                                        alpha: 0.6,
                                      ),
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: palette.divider,
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceEvenly,
                                      children: [
                                        _buildStatItem(
                                          palette,
                                          icon: PhosphorIconsBold.clock,
                                          label: t.share.timeLabel,
                                          value: _formatTime(
                                            widget.elapsedSeconds,
                                          ),
                                        ),
                                        _buildDivider(palette),
                                        _buildStatItem(
                                          palette,
                                          icon: PhosphorIconsFill.puzzlePiece,
                                          label: t.share.piecesLabel,
                                          value: '${widget.pieceCount}',
                                        ),
                                        _buildDivider(palette),
                                        _buildStatItem(
                                          palette,
                                          icon: PhosphorIconsBold.handTap,
                                          label: t.share.stepsLabel,
                                          value: '${widget.stepCount}',
                                        ),
                                      ],
                                    ),
                                  ),

                                  // Footer watermark
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        '\u{1F98A} ${t.app.title}',
                                        style: styles.caption.copyWith(
                                          color: palette.secondaryText,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Action buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isExporting
                              ? null
                              : () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: palette.secondaryText,
                            side: BorderSide(
                              color: palette.divider,
                              width: 1.2,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: const Icon(
                            PhosphorIconsBold.arrowLeft,
                            size: 18,
                          ),
                          label: Text(t.common.back),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: FilledButton.icon(
                          onPressed: _isExporting ? null : _exportPng,
                          style: FilledButton.styleFrom(
                            backgroundColor: palette.brand,
                            foregroundColor: palette.surface,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            elevation: 2,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: _isExporting
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: palette.surface,
                                  ),
                                )
                              : const Icon(
                                  PhosphorIconsBold.downloadSimple,
                                  size: 18,
                                ),
                          label: Text(
                            _isExporting
                                ? t.share.exporting
                                : t.share.saveButton,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatItem(
    AppPalette palette, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: palette.brand),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: palette.primaryText,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: palette.secondaryText),
        ),
      ],
    );
  }

  Widget _buildDivider(AppPalette palette) {
    return Container(width: 1, height: 36, color: palette.divider);
  }
}

/// Decorative confetti dots scattered across the share card background.
class _ConfettiDotsPainter extends CustomPainter {
  const _ConfettiDotsPainter({required this.palette});

  final AppPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final colors = [
      palette.brand,
      palette.gold,
      palette.brandLight,
      palette.info,
      palette.success,
    ];
    final rng = int.parse(size.hashCode.toRadixString(16)) % 42;
    const dotCount = 24;
    for (var i = 0; i < dotCount; i++) {
      final seed = (i * 137 + rng) % 1000;
      final x = (seed % 100) / 100 * size.width;
      final y = ((seed * 7) % 100) / 100 * size.height;
      final r = 2.0 + (seed % 5);
      final color = colors[i % colors.length].withValues(alpha: 0.15);
      canvas.drawCircle(Offset(x, y), r, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
