import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../l10n/gen/strings.g.dart';
import '../theme/app_palette.dart';
import '../theme/app_text_styles.dart';

/// Full-screen Gameplay Guide & Tips Page.
class HowToPlayPage extends StatelessWidget {
  const HowToPlayPage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const HowToPlayPage()));
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);

    final tips = [
      _TipItemData(
        icon: PhosphorIconsBold.handTap,
        color: palette.brand,
        title: t.howTo.t1.title,
        desc: t.howTo.t1.page,
      ),
      _TipItemData(
        icon: PhosphorIconsBold.stack,
        color: palette.info,
        title: t.howTo.t2.title,
        desc: t.howTo.t2.page,
      ),
      _TipItemData(
        icon: PhosphorIconsBold.magnifyingGlassPlus,
        color: palette.warning,
        title: t.howTo.t3.title,
        desc: t.howTo.t3.page,
      ),
      _TipItemData(
        icon: PhosphorIconsFill.stack,
        color: palette.info,
        title: t.howTo.t4.title,
        desc: t.howTo.t4.page,
      ),
      _TipItemData(
        icon: PhosphorIconsBold.cornersOut,
        color: palette.success,
        title: t.howTo.t5.title,
        desc: t.howTo.t5.page,
      ),
      _TipItemData(
        icon: PhosphorIconsBold.broom,
        color: palette.warning,
        title: t.howTo.t6.title,
        desc: t.howTo.t6.page,
      ),
    ];

    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(
        backgroundColor: palette.surface,
        foregroundColor: palette.primaryText,
        elevation: 0.5,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(PhosphorIconsBold.question, color: palette.brand, size: 22),
            const SizedBox(width: 8),
            Text(t.howTo.title, style: styles.h3.copyWith(fontSize: 19)),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            children: [
              // Welcome Banner
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      palette.brand.withValues(alpha: 0.12),
                      palette.info.withValues(alpha: 0.12),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: palette.brand.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: palette.brand.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        PhosphorIconsFill.sparkle,
                        color: palette.brand,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.howTo.welcomeTitle,
                            style: styles.bodyBold.copyWith(
                              fontSize: 15,
                              color: palette.brand,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            t.howTo.welcomeSub,
                            style: styles.caption.copyWith(height: 1.3),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // Tips list
              for (final tip in tips) ...[
                _buildTipCard(tip, palette, styles),
                const SizedBox(height: 12),
              ],

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTipCard(
    _TipItemData tip,
    AppPalette palette,
    AppTextStyles styles,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.divider, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: tip.color.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(tip.icon, color: tip.color, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tip.title,
                    style: styles.bodyBold.copyWith(fontSize: 15),
                  ),
                  const SizedBox(height: 4),
                  Text(tip.desc, style: styles.body.copyWith(height: 1.4)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TipItemData {
  const _TipItemData({
    required this.icon,
    required this.color,
    required this.title,
    required this.desc,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String desc;
}
