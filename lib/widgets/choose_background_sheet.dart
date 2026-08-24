import 'package:flutter/material.dart';

import '../data/game_repository.dart';

/// A bottom sheet modal for choosing full-screen background wallpaper in puzzle gameplay.
class ChooseBackgroundSheet extends StatelessWidget {
  const ChooseBackgroundSheet({
    super.key,
    required this.selectedBackground,
    required this.onBackgroundSelected,
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
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final bgList = GameRepository.kBackgroundAssets;

    return Container(
      height: size.height * 0.65,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                    const Icon(Icons.wallpaper, color: Color(0xFF2E7D32), size: 22),
                    const SizedBox(width: 8),
                    Text(
                      '更换拼图背景',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.black54),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // 2. Wallpaper 3-Column Grid
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.75, // Wallpaper aspect ratio
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
                        color: isSelected ? const Color(0xFF2E7D32) : Colors.black12,
                        width: isSelected ? 3.0 : 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isSelected
                              ? const Color(0xFF2E7D32).withValues(alpha: 0.35)
                              : Colors.black12,
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
                          fit: BoxFit.cover,
                          errorBuilder: (ctx, err, stack) => Container(
                            color: const Color(0xFFE2E6EA),
                            child: const Center(
                              child: Icon(Icons.broken_image, color: Colors.black26),
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
                              decoration: const BoxDecoration(
                                color: Color(0xFF2E7D32),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.check,
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
                            color: Colors.black45,
                            child: Text(
                              '背景 ${index + 1}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
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
