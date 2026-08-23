import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/game_repository.dart';
import '../../data/models/level_item.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../game_page.dart';

/// Home tab view showcasing the 100-level linear main gallery matching commercial Jigsaw (`homea.jpg`).
class HomeTabView extends StatefulWidget {
  const HomeTabView({super.key, required this.onSwitchToDaily});

  final VoidCallback onSwitchToDaily;

  @override
  State<HomeTabView> createState() => _HomeTabViewState();
}

class _HomeTabViewState extends State<HomeTabView> {
  final _repo = GameRepository.instance;

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

    // If already has progress or user wants to pick difficulty, show choose sheet
    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: level.difficulty,
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
    final levels = _repo.levels;
    final now = DateTime.now();

    return RefreshIndicator(
      onRefresh: () async => setState(() {}),
      child: CustomScrollView(
        slivers: [
          // 1. Top Daily Puzzle Blue Gradient Card (matching homea.jpg)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: InkWell(
                onTap: widget.onSwitchToDaily,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  height: 96,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF29B6F6), Color(0xFF0288D1)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF0288D1).withValues(alpha:0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            '每日拼图',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${now.month} 月 ${now.day} 日',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha:0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.calendar_month,
                          color: Colors.white,
                          size: 30,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // 2. 100-Level 2-Column Grid (matching homea.jpg)
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
                  final level = levels[index];
                  return _buildLevelCard(level);
                },
                childCount: levels.length,
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _buildLevelCard(LevelItem level) {
    return InkWell(
      onTap: () => _openLevel(level),
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
            // Level Image (Color if unlocked, Grayscale if locked)
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

            // Subtle dark gradient for contrast
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black26, Colors.transparent, Colors.black45],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),

            // Top-right piece count badge or progress percent
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha:0.9),
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

            // Bottom-left Level Index Number
            Positioned(
              left: 10,
              bottom: 8,
              child: Text(
                '${level.index}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(color: Colors.black87, blurRadius: 4),
                  ],
                ),
              ),
            ),

            // Center Action: Green Play Capsule for unlocked level 1, or Lock Icon for locked levels
            if (level.isUnlocked && !level.isCompleted)
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
                  child: const Text(
                    'Play',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
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
                    color: Colors.black.withValues(alpha:0.55),
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
