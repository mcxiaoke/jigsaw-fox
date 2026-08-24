import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/game_repository.dart';
import '../../data/models/level_item.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../game_page.dart';

enum LevelFilter {
  all('全部关卡'),
  starter('新手 (9-16)'),
  intermediate('进阶 (24-36)'),
  master('大师 (48-100+)'),
  completed('已通关'),
  inProgress('进行中');

  const LevelFilter(this.label);
  final String label;
}

/// Home tab view showcasing the 100-level main gallery with category filters and rich level cards.
class HomeTabView extends StatefulWidget {
  const HomeTabView({super.key, required this.onSwitchToDaily});

  final VoidCallback onSwitchToDaily;

  @override
  State<HomeTabView> createState() => _HomeTabViewState();
}

class _HomeTabViewState extends State<HomeTabView> {
  final _repo = GameRepository.instance;
  LevelFilter _selectedFilter = LevelFilter.all;

  List<LevelItem> _getFilteredLevels(List<LevelItem> all) {
    switch (_selectedFilter) {
      case LevelFilter.all:
        return all;
      case LevelFilter.starter:
        return all.where((l) => l.difficulty.pieceCount <= 16).toList();
      case LevelFilter.intermediate:
        return all.where((l) => l.difficulty.pieceCount >= 24 && l.difficulty.pieceCount <= 36).toList();
      case LevelFilter.master:
        return all.where((l) => l.difficulty.pieceCount >= 48).toList();
      case LevelFilter.completed:
        return all.where((l) => l.isCompleted).toList();
      case LevelFilter.inProgress:
        return all.where((l) => l.progressPercent > 0 && !l.isCompleted).toList();
    }
  }

  Future<void> _openLevel(LevelItem level) async {
    if (!level.isUnlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('请先通关第 ${level.index - 1} 关解锁此关卡！')),
      );
      return;
    }

    final bytes = await rootBundle.load(level.assetPath);
    final imgBytes = bytes.buffer.asUint8List();

    if (!mounted) return;

    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: level.difficulty,
      completedPieceCounts: level.completedPieceCounts.toSet(),
      title: '第 ${level.index} 关 · 难度选择',
      onStart: (diff) async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes,
              difficulty: diff,
              levelIndex: level.index,
              initialSnapshotJson: level.savedSnapshotJson,
            ),
          ),
        );
        setState(() {}); // refresh progress
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final allLevels = _repo.levels;
    final filteredLevels = _getFilteredLevels(allLevels);
    final now = DateTime.now();

    // Find today's daily challenge status
    final todayDaily = _repo.dailyChallenges.firstWhere(
      (d) => d.dayNumber == now.day,
      orElse: () => _repo.dailyChallenges.first,
    );

    return RefreshIndicator(
      onRefresh: () async => setState(() {}),
      child: CustomScrollView(
        slivers: [
          // 1. Top Daily Puzzle Hero Banner
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: InkWell(
                onTap: widget.onSwitchToDaily,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  height: 100,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF0288D1), Color(0xFF005691)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF0288D1).withValues(alpha: 0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.auto_awesome, color: Colors.amberAccent, size: 16),
                                const SizedBox(width: 4),
                                const Text(
                                  '今日推荐挑战',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                if (todayDaily.isCompleted) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2E7D32),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text('已完成', style: TextStyle(color: Colors.white, fontSize: 10)),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${now.month} 月 ${now.day} 日 · ${todayDaily.title.replaceFirst('${todayDaily.dayNumber} 日 · ', '')}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 64,
                          height: 64,
                          child: Image.asset(
                            todayDaily.assetPath,
                            fit: BoxFit.cover,
                            errorBuilder: (ctx, err, stack) => const Icon(Icons.calendar_month, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // 2. Category Filter Pills
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  for (final filter in LevelFilter.values) ...[
                    ChoiceChip(
                      label: Text(filter.label),
                      selected: _selectedFilter == filter,
                      selectedColor: const Color(0xFF2E7D32),
                      backgroundColor: Colors.white,
                      labelStyle: TextStyle(
                        color: _selectedFilter == filter ? Colors.white : Colors.black87,
                        fontWeight: _selectedFilter == filter ? FontWeight.bold : FontWeight.normal,
                        fontSize: 13,
                      ),
                      onSelected: (selected) {
                        if (selected) setState(() => _selectedFilter = filter);
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 8)),

          // 3. 100-Level 2-Column Grid
          if (filteredLevels.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('暂无符合该筛选条件的关卡', style: TextStyle(color: Colors.black45)),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 14,
                  mainAxisSpacing: 14,
                  childAspectRatio: 1.0,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final level = filteredLevels[index];
                    return _buildLevelCard(level);
                  },
                  childCount: filteredLevels.length,
                ),
              ),
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  Widget _buildLevelCard(LevelItem level) {
    return InkWell(
      onTap: () => _openLevel(level),
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
            // Level Image
            if (level.isUnlocked)
              Image.asset(
                level.assetPath,
                fit: BoxFit.cover,
                errorBuilder: (ctx, err, stack) => Image.asset(
                  'assets/images/sample_01.jpg',
                  fit: BoxFit.cover,
                ),
              )
            else
              ColorFiltered(
                colorFilter: const ColorFilter.matrix(<double>[
                  0.2126, 0.7152, 0.0722, 0, 0,
                  0.2126, 0.7152, 0.0722, 0, 0,
                  0.2126, 0.7152, 0.0722, 0, 0,
                  0,      0,      0,      1, 0,
                ]),
                child: Image.asset(
                  level.assetPath,
                  fit: BoxFit.cover,
                  errorBuilder: (ctx, err, stack) => Image.asset(
                    'assets/images/sample_01.jpg',
                    fit: BoxFit.cover,
                  ),
                ),
              ),

            // Top and bottom gradients
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black38, Colors.transparent, Colors.black54],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),

            // Top-left Level Index Badge
            Positioned(
              left: 10,
              top: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '#${level.index}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

            // Top-right piece count badge or progress percent
            Positioned(
              top: 10,
              right: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (level.progressPercent > 0 && !level.isCompleted) ...[
                      Text(
                        '${level.progressPercent}%',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2E7D32),
                        ),
                      ),
                    ] else ...[
                      const Icon(Icons.extension, size: 12, color: Colors.black54),
                      const SizedBox(width: 3),
                      Text(
                        '${level.difficulty.pieceCount}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Bottom-left Star rating
            if (level.isCompleted)
              Positioned(
                left: 10,
                bottom: 8,
                child: Row(
                  children: List.generate(
                    3,
                    (i) => Icon(
                      i < level.stars ? Icons.star : Icons.star_border,
                      color: Colors.amber,
                      size: 16,
                    ),
                  ),
                ),
              )
            else if (level.progressPercent > 0)
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: level.progressPercent / 100.0,
                    minHeight: 4,
                    backgroundColor: Colors.white38,
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF81C784)),
                  ),
                ),
              ),

            // Center Action: Play Capsule for unlocked level, Check for completed, or Lock for locked
            if (level.isUnlocked && !level.isCompleted && level.progressPercent == 0)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E7D32),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(color: Colors.black38, blurRadius: 6),
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.play_arrow, color: Colors.white, size: 16),
                      SizedBox(width: 2),
                      Text(
                        '开始',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else if (level.isCompleted)
              const Center(
                child: CircleAvatar(
                  backgroundColor: Color(0xCC2E7D32),
                  radius: 20,
                  child: Icon(Icons.check, color: Colors.white, size: 24),
                ),
              )
            else if (!level.isUnlocked)
              Positioned(
                bottom: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.lock,
                    color: Colors.white70,
                    size: 16,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
