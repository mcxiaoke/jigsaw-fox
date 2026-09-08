import 'package:flutter/material.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/cache/image_cache_manager.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:jigsawpuzzle/pages/event_levels_page.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:jigsawpuzzle/widgets/app_cached_image.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// 活动中心 Tab 页面 (横向大 Card 呈现各独立主题活动)
class EventsTabView extends StatefulWidget {
  const EventsTabView({super.key});

  @override
  State<EventsTabView> createState() => _EventsTabViewState();
}

class _EventsTabViewState extends State<EventsTabView> {
  final AppContent _content = AppContent.instance;

  @override
  void initState() {
    super.initState();
    _content.contentUpdateNotifier.addListener(_onContentUpdated);
  }

  @override
  void dispose() {
    _content.contentUpdateNotifier.removeListener(_onContentUpdated);
    super.dispose();
  }

  void _onContentUpdated() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final events = _content.isInitialized
        ? _content.manager.getVisibleEvents()
        : <PuzzleEventItem>[];

    return RefreshIndicator(
      onRefresh: () async => _content.syncAll(),
      color: palette.brand,
      child: events.isEmpty
          ? LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('🦊', style: TextStyle(fontSize: 48)),
                        const SizedBox(height: 8),
                        Text(
                          t.events.emptyTitle,
                          style: styles.body.copyWith(
                            color: palette.secondaryText,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(t.events.emptyHint, style: styles.caption),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          icon: const Icon(
                            PhosphorIconsRegular.arrowClockwise,
                            size: 16,
                          ),
                          label: Text(t.common.sync),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: palette.brand,
                            foregroundColor: palette.surface,
                          ),
                          onPressed: () async => _content.syncAll(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 600;
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: isWide ? 2 : 1,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    mainAxisExtent: 236,
                  ),
                  itemCount: events.length,
                  itemBuilder: (context, index) {
                    final event = events[index];
                    return _buildEventCard(context, event, palette, styles);
                  },
                );
              },
            ),
    );
  }

  Widget _buildEventCard(
    BuildContext context,
    PuzzleEventItem event,
    AppPalette palette,
    AppTextStyles styles,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          AppLogger.debug(
            AppLogger.events,
            'Events tab open event id=${event.id} title=${event.title}',
          );
          EventLevelsPage.open(context, event);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Cover Image Banner
            Stack(
              children: [
                SizedBox(
                  height: 160,
                  width: double.infinity,
                  child: AppCachedImage(
                    imagePathOrUrl:
                        event.coverUrl ??
                        (event.levels.isNotEmpty ? event.levels.first : ''),
                    targetDimension: ThumbnailDimension.eventCover,
                  ),
                ),
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.black.withValues(alpha: 0.35),
                          Colors.transparent,
                          const Color(0xBD000000),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ),
                // Top-left Status Badge
                Positioned(
                  left: 12,
                  top: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: event.isActive ? palette.brand : Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          event.isActive
                              ? PhosphorIconsFill.sparkle
                              : PhosphorIconsRegular.clockCounterClockwise,
                          color: Colors.white,
                          size: 13,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          event.isActive
                              ? t.events.badgeActive
                              : t.events.badgePast,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Top-right Type Badge
                Positioned(
                  right: 12,
                  top: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      event.isZipType
                          ? t.events.badgeZip
                          : t.events.badgeOnline,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
                // Bottom title on cover
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 12,
                  child: Text(
                    event.displayTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),

            // 2. Event Description & Action Bar
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        event.displayDesc.isNotEmpty
                            ? event.displayDesc
                            : t.events.descFallback,
                        style: styles.caption.copyWith(height: 1.3),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      icon: const Icon(PhosphorIconsBold.play, size: 14),
                      label: Text(t.events.enter),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: palette.brand,
                        foregroundColor: palette.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      onPressed: () => EventLevelsPage.open(context, event),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
