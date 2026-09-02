import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../services/sound_service.dart';
import '../theme/app_palette.dart';
import '../theme/app_text_styles.dart';

/// Full-screen Victory dialog with confetti, star animation, and stat roll-up.
///
/// Design spec (roadmap §4.1):
/// - Trigger: last piece placed → full-screen gradient overlay (300ms fade)
/// - Confetti: gold + amber particles falling down
/// - Center: completed image, 4px brand border, scale-in (0.8→1.0, elasticOut, 500ms)
/// - Stars: 3 stars light up sequentially (400ms interval)
/// - Stats: time, moves, reward with number roll animation (0→target, 800ms)
/// - Buttons: "保存壁纸"(ghost), "分享成绩"(brand), "下一关"(brand, most prominent)
class VictoryDialog extends StatefulWidget {
  const VictoryDialog({
    super.key,
    required this.imageBytes,
    this.stars = 3,
    this.elapsedSeconds = 0,
    this.moveCount = 0,
    this.rewardCoins = 0,
    this.onNextLevel,
    this.onShare,
    this.onSaveWallpaper,
  });

  final Uint8List imageBytes;
  final int stars;
  final int elapsedSeconds;
  final int moveCount;
  final int rewardCoins;

  /// Called when user taps "下一关". If null, button is hidden.
  final VoidCallback? onNextLevel;

  /// Called when user taps "分享成绩".
  final VoidCallback? onShare;

  /// Called when user taps "保存壁纸".
  final VoidCallback? onSaveWallpaper;

  static Future<void> show({
    required BuildContext context,
    required Uint8List imageBytes,
    int stars = 3,
    int elapsedSeconds = 0,
    int moveCount = 0,
    int rewardCoins = 0,
    VoidCallback? onNextLevel,
    VoidCallback? onShare,
    VoidCallback? onSaveWallpaper,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      builder: (_) => VictoryDialog(
        imageBytes: imageBytes,
        stars: stars,
        elapsedSeconds: elapsedSeconds,
        moveCount: moveCount,
        rewardCoins: rewardCoins,
        onNextLevel: onNextLevel,
        onShare: onShare,
        onSaveWallpaper: onSaveWallpaper,
      ),
    );
  }

  @override
  State<VictoryDialog> createState() => _VictoryDialogState();
}

class _VictoryDialogState extends State<VictoryDialog>
    with TickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final AnimationController _imageController;
  late final AnimationController _starController;
  late final AnimationController _statController;

  late final Animation<double> _fadeAnim;
  late final Animation<double> _imageScale;
  late final Animation<double> _statProgress;

  int _litStars = 0;
  int _displayedTime = 0;
  int _displayedMoves = 0;
  int _displayedCoins = 0;

  @override
  void initState() {
    super.initState();

    // Fade-in overlay (300ms)
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnim = CurvedAnimation(parent: _fadeController, curve: Curves.easeIn);

    // Image scale-in (500ms, elasticOut)
    _imageController = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );
    _imageScale = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _imageController, curve: Curves.elasticOut),
    );

    // Star lighting (sequential, 400ms each)
    _starController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );

    // Stat roll-up (800ms)
    _statController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _statProgress = CurvedAnimation(
      parent: _statController,
      curve: Curves.easeOutCubic,
    );

    _startAnimation();
  }

  Future<void> _startAnimation() async {
    // 1. Fade in overlay
    _fadeController.forward();

    await Future.delayed(const Duration(milliseconds: 200));

    // 2. Scale in image
    _imageController.forward();

    await Future.delayed(const Duration(milliseconds: 600));

    // 3. Light up stars sequentially
    for (int i = 0; i < widget.stars; i++) {
      if (!mounted) return;
      setState(() => _litStars = i + 1);
      SoundService.I.play(Sfx.snap, ignoreMute: true);
      await Future.delayed(const Duration(milliseconds: 400));
    }

    if (!mounted) return;

    // 4. Roll up stats
    _statController.forward();
    _statController.addListener(() {
      if (!mounted) return;
      final p = _statProgress.value;
      setState(() {
        _displayedTime = (widget.elapsedSeconds * p).round();
        _displayedMoves = (widget.moveCount * p).round();
        _displayedCoins = (widget.rewardCoins * p).round();
      });
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _imageController.dispose();
    _starController.dispose();
    _statController.dispose();
    super.dispose();
  }

  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);

    return AnimatedBuilder(
      animation: _fadeAnim,
      builder: (context, child) {
        return Container(
          color: palette.surface.withValues(alpha: 0.92 * _fadeAnim.value),
          child: child,
        );
      },
      child: Stack(
        children: [
          // Confetti layer
          Positioned.fill(
            child: CustomPaint(painter: _ConfettiPainter(palette)),
          ),

          // Main content
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Title
                  Text(
                    '拼图完成！',
                    style: styles.h1.copyWith(
                      fontSize: 24,
                      color: palette.brand,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Completed image with brand border
                  ScaleTransition(
                    scale: _imageScale,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: palette.brand, width: 4),
                        boxShadow: [
                          BoxShadow(
                            color: palette.brand.withValues(alpha: 0.3),
                            blurRadius: 20,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          widget.imageBytes,
                          width: 200,
                          height: 200,
                          fit: BoxFit.cover,
                          // 解码期降采样：展示盒 200px × 3 倍 DPR 足够清晰，
                          // 避免按原图分辨率全量解码（超分图可达数十 MB）
                          cacheWidth: 600,
                          errorBuilder: (_, _, _) => Container(
                            width: 200,
                            height: 200,
                            color: palette.surfaceContainer,
                            child: Icon(
                              PhosphorIconsFill.puzzlePiece,
                              size: 48,
                              color: palette.brand,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Stars
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(3, (i) {
                      final lit = i < _litStars;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: AnimatedScale(
                          scale: lit ? 1.0 : 0.6,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutBack,
                          child: Icon(
                            lit
                                ? PhosphorIconsFill.star
                                : PhosphorIconsRegular.star,
                            size: 36,
                            color: lit ? palette.gold : palette.disabledText,
                          ),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 20),

                  // Stats row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildStat(
                        icon: PhosphorIconsBold.clock,
                        label: '用时',
                        value: _formatTime(_displayedTime),
                        palette: palette,
                        styles: styles,
                      ),
                      _buildStat(
                        icon: PhosphorIconsBold.cursorClick,
                        label: '步数',
                        value: '$_displayedMoves',
                        palette: palette,
                        styles: styles,
                      ),
                      _buildStat(
                        icon: PhosphorIconsFill.coins,
                        label: '奖励',
                        value: '+$_displayedCoins',
                        color: palette.gold,
                        palette: palette,
                        styles: styles,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Action buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (widget.onSaveWallpaper != null)
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: widget.onSaveWallpaper,
                            icon: const Icon(
                              PhosphorIconsRegular.image,
                              size: 16,
                            ),
                            label: const Text('保存壁纸'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: palette.secondaryText,
                              side: BorderSide(color: palette.divider),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      if (widget.onSaveWallpaper != null &&
                          widget.onShare != null)
                        const SizedBox(width: 10),
                      if (widget.onShare != null)
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: widget.onShare,
                            icon: const Icon(
                              PhosphorIconsBold.shareNetwork,
                              size: 16,
                            ),
                            label: const Text('分享成绩'),
                            style: FilledButton.styleFrom(
                              backgroundColor: palette.surfaceContainer,
                              foregroundColor: palette.primaryText,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      if (widget.onShare != null && widget.onNextLevel != null)
                        const SizedBox(width: 10),
                      if (widget.onNextLevel != null)
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: widget.onNextLevel,
                            icon: const Icon(PhosphorIconsFill.play, size: 16),
                            label: const Text('下一关'),
                            style: FilledButton.styleFrom(
                              backgroundColor: palette.brand,
                              foregroundColor: palette.surface,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              elevation: 2,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  // Close button
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      '返回',
                      style: TextStyle(color: palette.secondaryText),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStat({
    required IconData icon,
    required String label,
    required String value,
    Color? color,
    required AppPalette palette,
    required AppTextStyles styles,
  }) {
    final c = color ?? palette.primaryText;
    return Column(
      children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(height: 4),
        Text(value, style: styles.monoSmall.copyWith(fontSize: 18, color: c)),
        const SizedBox(height: 2),
        Text(label, style: styles.caption.copyWith(fontSize: 11)),
      ],
    );
  }
}

/// Confetti particle painter — gold and amber particles falling down.
class _ConfettiPainter extends CustomPainter {
  final AppPalette palette;
  final List<_Particle> _particles;
  final Random _rng = Random();

  _ConfettiPainter(this.palette) : _particles = [], super() {
    for (int i = 0; i < 60; i++) {
      _particles.add(_Particle.random(_rng));
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final p in _particles) {
      final t = (now / 1000.0 - p.startTime) * p.speed;
      if (t < 0) continue;
      final dy = (t * 200) % (size.height + 40);
      final dx = p.x * size.width + sin(t * 2) * 30;
      final opacity = (1.0 - dy / (size.height + 40)).clamp(0.0, 1.0);

      final paint = Paint()
        ..color = p.color == 0
            ? palette.gold.withValues(alpha: opacity)
            : palette.brand.withValues(alpha: opacity)
        ..style = PaintingStyle.fill;

      canvas.save();
      canvas.translate(dx, dy - 20);
      canvas.rotate(t * 3);
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset.zero,
          width: p.size,
          height: p.size * 0.4,
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _Particle {
  final double x;
  final double startTime;
  final double speed;
  final int color;
  final double size;

  _Particle({
    required this.x,
    required this.startTime,
    required this.speed,
    required this.color,
    required this.size,
  });

  factory _Particle.random(Random rng) {
    return _Particle(
      x: rng.nextDouble(),
      startTime: rng.nextDouble() * 2,
      speed: 0.5 + rng.nextDouble() * 0.8,
      color: rng.nextInt(2),
      size: 4 + rng.nextDouble() * 6,
    );
  }
}
