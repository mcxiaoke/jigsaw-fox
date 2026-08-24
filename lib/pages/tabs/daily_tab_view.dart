import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../data/game_repository.dart';
import '../../data/models/daily_challenge.dart';
import '../../logic/image_source.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../game_page.dart';

/// Daily challenge tab view with streak stats, today's hero card, and monthly challenge calendar stream.
class DailyTabView extends StatefulWidget {
  const DailyTabView({super.key});

  @override
  State<DailyTabView> createState() => _DailyTabViewState();
}

class _DailyTabViewState extends State<DailyTabView> {
  final _repo = GameRepository.instance;

  Future<void> _openDaily(DailyChallengeItem item) async {
    Uint8List imgBytes;
    try {
      final bytes = await rootBundle.load(item.assetPath);
      imgBytes = bytes.buffer.asUint8List();
    } catch (_) {
      final bytes = await rootBundle.load(assetSamples[0]);
      imgBytes = bytes.buffer.asUint8List();
    }

    if (!mounted) return;
    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: item.difficulty,
      completedPieceCounts: item.completedPieceCounts.toSet(),
      title: '${item.date} 挑战 · 难度选择',
      savedProgressPercent: item.isCompleted ? null : item.progressPercent,
      onResetProgress: () async {
        await _repo.updateDailyProgress(
          dateStr: item.date,
          progressPercent: 0,
          snapshotJson: null,
          isCompleted: item.isCompleted,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes,
              difficulty: item.difficulty,
              dailyDateStr: item.date,
              initialSnapshotJson: null,
            ),
          ),
        );
        setState(() {});
      },
      onStart: (diff) async {
        final isSameDiff = diff.pieceCount == item.difficulty.pieceCount;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes,
              difficulty: diff,
              dailyDateStr: item.date,
              initialSnapshotJson: isSameDiff && !item.isCompleted ? item.savedSnapshotJson : null,
            ),
          ),
        );
        setState(() {});
      },
    );
  }

  int _calculateStreak(List<DailyChallengeItem> dailyList) {
    var streak = 0;
    final now = DateTime.now();
    for (var d = now.day; d >= 1; d--) {
      final match = dailyList.firstWhere(
        (item) => item.dayNumber == d,
        orElse: () => dailyList.first,
      );
      if (match.isCompleted) {
        streak++;
      } else if (d != now.day) {
        break;
      }
    }
    return streak;
  }

  @override
  Widget build(BuildContext context) {
    final dailyList = _repo.dailyChallenges;
    final now = DateTime.now();
    final todayItem = dailyList.firstWhere(
      (d) => d.dayNumber == now.day,
      orElse: () => dailyList.first,
    );

    final completedCount = dailyList.where((d) => d.isCompleted).length;
    final streak = _calculateStreak(dailyList);

    return RefreshIndicator(
      onRefresh: () async => setState(() {}),
      child: CustomScrollView(
        slivers: [
          // 1. Today's Hero Banner Card
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Card(
                elevation: 3,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(22),
                ),
                clipBehavior: Clip.antiAlias,
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE8F5E9),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Text(
                                    'TODAY',
                                    style: TextStyle(
                                      color: Color(0xFF1B5E20),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${now.month} 月 ${now.day} 日',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black54,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              todayItem.title.replaceFirst('${todayItem.dayNumber} 日 · ', ''),
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 14),
                            FilledButton.icon(
                              onPressed: () => _openDaily(todayItem),
                              icon: Icon(
                                todayItem.isCompleted ? PhosphorIconsBold.arrowsClockwise : PhosphorIconsFill.play,
                                size: 18,
                              ),
                              label: Text(
                                todayItem.isCompleted
                                    ? '已通关 (重玩)'
                                    : (todayItem.progressPercent > 0 ? '继续挑战' : '开始挑战'),
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF2E7D32),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 18,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(
                          width: 130,
                          height: 120,
                          child: Image.asset(
                            todayItem.assetPath,
                            fit: BoxFit.cover,
                            errorBuilder: (ctx, err, stack) => Image.asset(
                              assetSamples[0],
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // 2. Monthly Streak & Trophy Bar
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(PhosphorIconsFill.trophy, color: Colors.amber, size: 22),
                        const SizedBox(width: 6),
                        Text(
                          '${now.year}年${now.month}月进度: $completedCount/${dailyList.length}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(PhosphorIconsFill.fire, color: Colors.orange, size: 16),
                          const SizedBox(width: 3),
                          Text(
                            '连胜 $streak 天',
                            style: const TextStyle(
                              color: Colors.deepOrange,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 10)),

          // 3. 30-Day Responsive Adaptive Grid Stream
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 1.0,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final item = dailyList[index];
                  return _buildDailyCard(item);
                },
                childCount: dailyList.length,
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  Widget _buildDailyCard(DailyChallengeItem item) {
    return InkWell(
      onTap: () => _openDaily(item),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              item.assetPath,
              fit: BoxFit.cover,
              errorBuilder: (ctx, err, stack) => Image.asset(
                assetSamples[0],
                fit: BoxFit.cover,
              ),
            ),

            // Top and Bottom gradients
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black45, Colors.transparent, Colors.black54],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),

            // Top-left Round Day Badge
            Positioned(
              top: 10,
              left: 10,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.94),
                  shape: BoxShape.circle,
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 4),
                  ],
                ),
                alignment: Alignment.center,
                child: Text(
                  '${item.dayNumber}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ),
            ),

            // Bottom Title
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Text(
                item.title.replaceFirst('${item.dayNumber} 日 · ', ''),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // Top-right Completion check or Progress Percentage
            if (item.isCompleted)
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: const BoxDecoration(
                    color: Color(0xFF2E7D32),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(PhosphorIconsBold.check, color: Colors.white, size: 14),
                ),
              )
            else if (item.progressPercent > 0)
              Positioned(
                top: 10,
                right: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${item.progressPercent}%',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF2E7D32),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
