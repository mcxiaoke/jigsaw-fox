import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/game_repository.dart';
import '../../data/models/daily_challenge.dart';
import '../../logic/image_source.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../game_page.dart';

/// Daily challenge tab view matching commercial Jigsaw (`homeb.jpg`).
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
      onStart: (diff) async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes,
              difficulty: diff,
              dailyDateStr: item.date,
              initialSnapshotJson: item.savedSnapshotJson,
            ),
          ),
        );
        setState(() {});
      },
    );
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

    return RefreshIndicator(
      onRefresh: () async => setState(() {}),
      child: CustomScrollView(
        slivers: [
          // 1. Today's Hero Banner (matching homeb.jpg)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Card(
                elevation: 3,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
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
                            const Text(
                              '今天',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${now.month} 月 ${now.day} 日',
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.black,
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: () => _openDaily(todayItem),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF2E7D32),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 10,
                                ),
                              ),
                              child: const Text(
                                '开始游戏',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(
                          width: 140,
                          height: 110,
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

          // 2. Month Title Header (e.g. 2026 年 8 月 (0/31))
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${now.year} 年 ${now.month} 月  ($completedCount/${dailyList.length})',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  const Icon(Icons.keyboard_arrow_down, color: Colors.black54),
                ],
              ),
            ),
          ),

          // 3. 30-Day Grid Stream (matching homeb.jpg)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
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
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
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

            // Top gradient
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black38, Colors.transparent],
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                ),
              ),
            ),

            // Top-left Round Day Badge (22, 21, 20...)
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha:0.92),
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

            // Top-right Progress Percentage (1%) or Complete check
            if (item.isCompleted)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Color(0xFF2E7D32),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, color: Colors.white, size: 14),
                ),
              )
            else if (item.progressPercent > 0)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha:0.9),
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
