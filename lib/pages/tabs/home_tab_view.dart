import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../data/game_repository.dart';
import '../../data/models/level_item.dart';
import '../../widgets/app_cached_image.dart';
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

class HomeTabView extends StatefulWidget {
  const HomeTabView({super.key, required this.onSwitchToDaily});

  final VoidCallback onSwitchToDaily;

  @override
  State<HomeTabView> createState() => _HomeTabViewState();
}

class _HomeTabViewState extends State<HomeTabView> {
  final _repo = GameRepository.instance;
  LevelFilter _selectedFilter = LevelFilter.all;
  String _selectedTag = 'all';

  // 预设常用 6 大 Tag 分类 (中英文映射)
  static const List<Map<String, String>> _predefinedTags = [
    {'tag': 'all', 'label': '全部'},
    {'tag': 'animal', 'label': '萌宠'},
    {'tag': 'landscape', 'label': '风光'},
    {'tag': 'bird', 'label': '飞鸟'},
    {'tag': 'art', 'label': '艺术'},
    {'tag': 'architecture', 'label': '建筑'},
  ];

  List<LevelItem> _getFilteredLevels(List<LevelItem> all) {
    var list = all;

    // 1. 难度/状态过滤
    switch (_selectedFilter) {
      case LevelFilter.all:
        break;
      case LevelFilter.starter:
        list = list.where((l) => l.difficulty.pieceCount <= 16).toList();
        break;
      case LevelFilter.intermediate:
        list = list.where((l) => l.difficulty.pieceCount >= 24 && l.difficulty.pieceCount <= 36).toList();
        break;
      case LevelFilter.master:
        list = list.where((l) => l.difficulty.pieceCount >= 48).toList();
        break;
      case LevelFilter.completed:
        list = list.where((l) => l.isCompleted).toList();
        break;
      case LevelFilter.inProgress:
        list = list.where((l) => l.progressPercent > 0 && !l.isCompleted).toList();
        break;
    }

    // 2. Tag 过滤 (根据关卡 index 模拟或匹配内置分类)
    if (_selectedTag != 'all') {
      list = list.where((l) {
        // 内置 100 关根据分类区间映射 (1~20: 萌宠/风光, 21~40: 建筑, 41~60: 艺术, 等)
        if (_selectedTag == 'animal') return l.index % 5 == 1 || l.index % 5 == 3;
        if (_selectedTag == 'landscape') return l.index % 5 == 2 || l.index % 5 == 0;
        if (_selectedTag == 'bird') return l.index % 5 == 2;
        if (_selectedTag == 'art') return l.index % 5 == 4;
        if (_selectedTag == 'architecture') return l.index % 5 == 0;
        return true;
      }).toList();
    }

    return list;
  }

  Future<void> _openLevel(LevelItem level) async {
    final bytes = await rootBundle.load(level.assetPath);
    final imgBytes = bytes.buffer.asUint8List();

    if (!mounted) return;

    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: level.difficulty,
      completedPieceCounts: level.completedPieceCounts.toSet(),
      isUnlocked: level.isUnlocked,
      lockedMessage: '请先通关第 ${level.index - 1} 关解锁此关卡',
      title: '第 ${level.index} 关 · ${level.isUnlocked ? "难度选择" : "关卡预览(未解锁)"}',
      savedProgressPercent: level.isCompleted ? null : level.progressPercent,
      onResetProgress: () async {
        await _repo.updateLevelProgress(
          levelIndex: level.index,
          progressPercent: 0,
          snapshotJson: null,
          isCompleted: level.isCompleted,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes,
              difficulty: level.difficulty,
              levelIndex: level.index,
              initialSnapshotJson: null,
            ),
          ),
        );
        setState(() {});
      },
      onStart: (diff) async {
        final isSameDiff = diff.pieceCount == level.difficulty.pieceCount;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes,
              difficulty: diff,
              levelIndex: level.index,
              initialSnapshotJson: isSameDiff && !level.isCompleted ? level.savedSnapshotJson : null,
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
          // 1. Simplified Daily Challenge Hero Banner
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: InkWell(
                onTap: widget.onSwitchToDaily,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  height: 84,
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
                                Image.asset('assets/icons/sparkle_3d.png', width: 18, height: 18),
                                const SizedBox(width: 6),
                                Text(
                                  '${now.month}月${now.day}日 · 今日挑战',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (todayDaily.isCompleted) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                            const Text(
                              '点击开玩今日专属拼图',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          width: 60,
                          height: 60,
                          child: AppCachedImage(
                            imagePathOrUrl: todayDaily.assetPath,
                            fit: BoxFit.cover,
                            targetWidth: 160,
                            targetHeight: 160,
                            errorWidget: const Icon(PhosphorIconsFill.calendarCheck, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // 2. Smoothly Scrollable Level Filter Pills (Difficulty / Status)
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
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
                        fontSize: 12,
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

          // 3. New 6-Tag Category Filter Buttons
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  for (final item in _predefinedTags) ...[
                    ActionChip(
                      label: Text(item['label']!),
                      backgroundColor: _selectedTag == item['tag'] ? const Color(0xFFE8F5E9) : Colors.white,
                      side: BorderSide(
                        color: _selectedTag == item['tag'] ? const Color(0xFF2E7D32) : const Color(0xFFE0E0E0),
                        width: _selectedTag == item['tag'] ? 1.5 : 0.8,
                      ),
                      labelStyle: TextStyle(
                        color: _selectedTag == item['tag'] ? const Color(0xFF2E7D32) : Colors.black87,
                        fontWeight: _selectedTag == item['tag'] ? FontWeight.bold : FontWeight.normal,
                        fontSize: 12,
                      ),
                      onPressed: () {
                        setState(() => _selectedTag = item['tag']!);
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 6)),

          // 3. 100-Level Responsive Adaptive Grid (2 columns on narrow, 3-6 on wide)
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
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
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
            // Level Image with Downsampling Memory Cache
            AppCachedImage(
              imagePathOrUrl: level.assetPath,
              fit: BoxFit.cover,
              targetWidth: 360,
              targetHeight: 360,
              colorFilter: level.isUnlocked
                  ? null
                  : const ColorFilter.matrix(<double>[
                      0.2126, 0.7152, 0.0722, 0, 0,
                      0.2126, 0.7152, 0.0722, 0, 0,
                      0.2126, 0.7152, 0.0722, 0, 0,
                      0,      0,      0,      1, 0,
                    ]),
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
                      const Icon(PhosphorIconsFill.puzzlePiece, size: 12, color: Colors.black54),
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
                    (i) => Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: i < level.stars
                          ? Image.asset('assets/icons/star_3d.png', width: 16, height: 16)
                          : const Icon(PhosphorIconsRegular.star, color: Colors.amber, size: 16),
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
                      Icon(PhosphorIconsFill.play, color: Colors.white, size: 14),
                      SizedBox(width: 4),
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
                  child: Icon(PhosphorIconsBold.check, color: Colors.white, size: 24),
                ),
              )
            else if (!level.isUnlocked)
              Positioned(
                bottom: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    shape: BoxShape.circle,
                  ),
                  child: Image.asset(
                    'assets/icons/lock_3d.png',
                    width: 16,
                    height: 16,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
