import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../logic/content/app_content.dart';
import '../../logic/content/models/puzzle_event_item.dart';
import '../../widgets/app_cached_image.dart';
import '../event_levels_page.dart';

/// 活动中心 Tab 页面 (横向大 Card 呈现各独立主题活动)
class EventsTabView extends StatefulWidget {
  const EventsTabView({super.key});

  @override
  State<EventsTabView> createState() => _EventsTabViewState();
}

class _EventsTabViewState extends State<EventsTabView> {
  final _content = AppContent.instance;

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
    final events = _content.isInitialized ? _content.manager.getVisibleEvents() : <PuzzleEventItem>[];

    return RefreshIndicator(
      onRefresh: () async => await _content.syncAll(),
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
                        const Icon(PhosphorIconsRegular.calendarBlank, size: 54, color: Colors.black26),
                        const SizedBox(height: 16),
                        const Text('暂无正在进行的活动', style: TextStyle(color: Colors.black54, fontSize: 15)),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          icon: const Icon(PhosphorIconsRegular.arrowClockwise, size: 16),
                          label: const Text('刷新同步'),
                          onPressed: () async => await _content.syncAll(),
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
                  physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: isWide ? 2 : 1,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    mainAxisExtent: 236,
                  ),
                  itemCount: events.length,
                  itemBuilder: (context, index) {
                    final event = events[index];
                    return _buildEventCard(context, event);
                  },
                );
              },
            ),
    );
  }

  Widget _buildEventCard(BuildContext context, PuzzleEventItem event) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => EventLevelsPage.open(context, event),
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
                    imagePathOrUrl: event.coverUrl ?? (event.levels.isNotEmpty ? event.levels.first : ''),
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    targetWidth: 720,
                    targetHeight: 360,
                  ),
                ),
                Positioned.fill(
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.black54, Colors.transparent, Color(0xBD000000)],
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
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: event.isActive ? const Color(0xFF2E7D32) : Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          event.isActive ? PhosphorIconsFill.sparkle : PhosphorIconsRegular.clockCounterClockwise,
                          color: Colors.white,
                          size: 13,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          event.isActive ? '限时进行中' : '往期活动',
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
                // Top-right Type Badge (Zip / Array)
                Positioned(
                  right: 12,
                  top: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      event.isZipType ? '离线整包' : '在线精选',
                      style: const TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                  ),
                ),
                // Bottom title on cover
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 12,
                  child: Text(
                    event.title,
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        event.desc.isNotEmpty ? event.desc : '精彩专题拼图挑战',
                        style: const TextStyle(color: Colors.black54, fontSize: 12, height: 1.3),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      icon: const Icon(PhosphorIconsBold.play, size: 14),
                      label: const Text('进入挑战'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2E7D32),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
