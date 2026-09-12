import 'package:flutter/material.dart';

import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:jigsawpuzzle/widgets/app_cached_image.dart';

/// 横幅卡片数据模型
class HeroBannerItem {
  const HeroBannerItem({
    required this.id,
    required this.title,
    required this.imagePathOrUrl,
    this.badgeText = '',
    this.badgeEmoji = '',
    this.badgeColor,
    this.subtitle = '',
    this.topRightBadge,
    this.onTap,
  });

  final String id;
  final String title;
  final String imagePathOrUrl;
  final String badgeText;
  final String badgeEmoji;
  final Color? badgeColor;
  final String subtitle;
  final Widget? topRightBadge;
  final VoidCallback? onTap;
}

/// 全平台自适应横向自由滑动横幅组件 (Horizontal Rails)
/// 移动端自然露边 Peek 引导，桌面与宽屏自然平铺多卡，彻底消灭拉伸失真与裁切问题
class AdaptiveHeroBanner extends StatelessWidget {
  const AdaptiveHeroBanner({
    required this.items,
    super.key,
    this.cardWidth = 290.0,
    this.cardHeight = 156.0,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final List<HeroBannerItem> items;
  final double cardWidth;
  final double cardHeight;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);

    return SizedBox(
      height: cardHeight,
      child: ListView.separated(
        padding: padding,
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: items.length,
        separatorBuilder: (context, index) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final item = items[index];
          return _buildBannerCard(context, item, palette, styles);
        },
      ),
    );
  }

  Widget _buildBannerCard(
    BuildContext context,
    HeroBannerItem item,
    AppPalette palette,
    AppTextStyles styles,
  ) {
    final badgeBg = item.badgeColor ?? palette.brand;

    return SizedBox(
      width: cardWidth,
      height: cardHeight,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: item.onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1. 封面底图
                AppCachedImage(
                  imagePathOrUrl: item.imagePathOrUrl,
                  targetDimension: ThumbnailDimension.eventCover,
                ),

                // 2. 暗色渐变遮罩 (保证所有浅色背景上文字清晰)
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.black.withValues(alpha: 0.65),
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.7),
                      ],
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      stops: const [0.0, 0.45, 1.0],
                    ),
                  ),
                ),

                // 3. 左上角 Badge 徽章
                if (item.badgeText.isNotEmpty)
                  Positioned(
                    left: 12,
                    top: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: badgeBg,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (item.badgeEmoji.isNotEmpty) ...[
                            Text(
                              item.badgeEmoji,
                              style: const TextStyle(fontSize: 10),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Text(
                            item.badgeText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // 4. 右上角徽章 (如下载状态)
                if (item.topRightBadge != null)
                  Positioned(
                    right: 12,
                    top: 12,
                    child: item.topRightBadge!,
                  ),

                // 5. 底部图文信息
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.title,
                        style: styles.h3.copyWith(
                          color: Colors.white,
                          fontSize: 15.5,
                          shadows: [
                            const Shadow(
                              color: Colors.black54,
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (item.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          item.subtitle,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            shadows: const [
                              Shadow(
                                color: Colors.black45,
                                blurRadius: 3,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
