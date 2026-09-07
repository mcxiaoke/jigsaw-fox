import 'package:flutter/material.dart';
import 'package:jigsawpuzzle/data/game_repository.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// A bottom sheet modal for choosing full-screen background wallpaper in puzzle gameplay.
class ChooseBackgroundSheet extends StatelessWidget {
  const ChooseBackgroundSheet({
    required this.selectedBackground, required this.onBackgroundSelected, super.key,
  });

  final String selectedBackground;
  final ValueChanged<String> onBackgroundSelected;

  static Future<void> show({
    required BuildContext context,
    required String selectedBackground,
    required ValueChanged<String> onBackgroundSelected,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChooseBackgroundSheet(
        selectedBackground: selectedBackground,
        onBackgroundSelected: onBackgroundSelected,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final size = MediaQuery.sizeOf(context);
    const bgList = GameRepository.kBackgroundAssets;

    return Container(
      height: size.height * 0.65,
      decoration: BoxDecoration(
        color: palette.surfaceContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // 1. Top bar with Title & Close
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      PhosphorIconsBold.image,
                      color: palette.brand,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      t.background.title,
                      style: styles.h3.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                IconButton(
                  icon: Icon(PhosphorIconsBold.x, color: palette.secondaryText),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          Divider(height: 1, color: palette.divider),

          // 2. Wallpaper 3-Column Grid
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: bgList.length,
              itemBuilder: (context, index) {
                final bgPath = bgList[index];
                final isSelected = bgPath == selectedBackground;

                return InkWell(
                  onTap: () {
                    onBackgroundSelected(bgPath);
                    Navigator.of(context).pop();
                  },
                  borderRadius: BorderRadius.circular(14),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isSelected ? palette.brand : palette.divider,
                        width: isSelected ? 3.0 : 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isSelected
                              ? palette.brand.withValues(alpha: 0.35)
                              : Colors.black.withValues(alpha: 0.08),
                          blurRadius: isSelected ? 8 : 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.asset(
                          bgPath,
                          repeat: ImageRepeat.repeat,
                          errorBuilder: (ctx, err, stack) => ColoredBox(
                            color: palette.surfaceContainerLow,
                            child: Center(
                              child: Icon(
                                PhosphorIconsBold.imageBroken,
                                color: palette.disabledText,
                              ),
                            ),
                          ),
                        ),

                        // Selected indicator badge
                        if (isSelected)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color: palette.brand,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                PhosphorIconsBold.check,
                                color: Colors.white,
                                size: 14,
                              ),
                            ),
                          ),

                        // Bottom label
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            color: Colors.black.withValues(alpha: 0.45),
                            child: Text(
                              t.background.tableLabel(index: index + 1),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: palette.primaryText,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
