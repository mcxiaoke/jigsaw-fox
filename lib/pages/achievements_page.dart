import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/game_repository.dart';

/// Full-screen Achievements and Gameplay Statistics page.
class AchievementsPage extends StatefulWidget {
  const AchievementsPage({super.key});

  /// Navigates to [AchievementsPage] as a standard full-screen route.
  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const AchievementsPage(),
      ),
    );
  }

  @override
  State<AchievementsPage> createState() => _AchievementsPageState();
}

class _AchievementsPageState extends State<AchievementsPage> {
  String _formatDuration(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    if (m < 60) return '$m 分 $s 秒';
    final h = m ~/ 60;
    final remM = m % 60;
    return '$h 小时 $remM 分';
  }

  @override
  Widget build(BuildContext context) {
    final repo = GameRepository.instance;
    final totalStars = repo.levels.fold<int>(0, (sum, l) => sum + l.stars);
    final completed = repo.totalCompletedLevels;
    final snapped = repo.totalPiecesSnapped;
    final timeSec = repo.totalPlayTimeSeconds;
    final avgTime = completed > 0 ? (timeSec ~/ completed) : 0;

    final badges = [
      _BadgeData(
        title: '初入拼界',
        desc: '完成首局拼图挑战',
        icon: PhosphorIconsFill.medal,
        imageAsset: 'assets/icons/medal_3d.png',
        current: completed,
        max: 1,
      ),
      _BadgeData(
        title: '拼图学徒',
        desc: '累计完成 5 局拼图',
        icon: PhosphorIconsFill.trophy,
        imageAsset: 'assets/icons/trophy_3d.png',
        current: completed,
        max: 5,
      ),
      _BadgeData(
        title: '拼图大师',
        desc: '累计完成 20 局拼图',
        icon: PhosphorIconsFill.crown,
        imageAsset: 'assets/icons/crown_3d.png',
        current: completed,
        max: 20,
      ),
      _BadgeData(
        title: '拼图传奇',
        desc: '累计完成 50 局拼图',
        icon: PhosphorIconsFill.diamond,
        imageAsset: 'assets/icons/diamond_3d.png',
        current: completed,
        max: 50,
      ),
      _BadgeData(
        title: '碎片收集者',
        desc: '累计拼合 50 块碎片',
        icon: PhosphorIconsRegular.puzzlePiece,
        imageAsset: 'assets/icons/puzzle_piece_3d.png',
        current: snapped,
        max: 50,
      ),
      _BadgeData(
        title: '拼图能手',
        desc: '累计拼合 200 块碎片',
        icon: PhosphorIconsFill.puzzlePiece,
        imageAsset: 'assets/icons/puzzle_piece_3d.png',
        current: snapped,
        max: 200,
      ),
      _BadgeData(
        title: '千锤百炼',
        desc: '累计拼合 1000 块碎片',
        icon: PhosphorIconsFill.sparkle,
        imageAsset: 'assets/icons/sparkle_3d.png',
        current: snapped,
        max: 1000,
      ),
      _BadgeData(
        title: '专注达人',
        desc: '累计游玩时间超过 30 分钟',
        icon: PhosphorIconsBold.timer,
        imageAsset: 'assets/icons/hourglass_3d.png',
        current: timeSec,
        max: 1800,
        isTime: true,
      ),
      _BadgeData(
        title: '沉浸探索',
        desc: '累计游玩时间超过 2 小时',
        icon: PhosphorIconsFill.hourglass,
        imageAsset: 'assets/icons/hourglass_3d.png',
        current: timeSec,
        max: 7200,
        isTime: true,
      ),
      _BadgeData(
        title: '每日不辍',
        desc: '通关至少 1 次每日拼图',
        icon: PhosphorIconsFill.calendarCheck,
        imageAsset: 'assets/icons/calendar_3d.png',
        current: repo.dailyChallenges.where((d) => d.isCompleted).length,
        max: 1,
      ),
      _BadgeData(
        title: '匠心自造',
        desc: '通关至少 1 次自制拼图',
        icon: PhosphorIconsBold.palette,
        imageAsset: 'assets/icons/palette_3d.png',
        current: repo.customPuzzles.where((c) => c.isCompleted).length,
        max: 1,
      ),
      _BadgeData(
        title: '高阶挑战者',
        desc: '完成 64 块以上高难度拼图',
        icon: PhosphorIconsFill.starFour,
        imageAsset: 'assets/icons/star_3d.png',
        current: repo.levels.where((l) => l.completedPieceCounts.any((c) => c >= 64)).length,
        max: 1,
      ),
    ];

    final unlockedCount = badges.where((b) => b.isUnlocked).length;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/icons/trophy_3d.png', width: 24, height: 24),
            const SizedBox(width: 8),
            const Text('成就与统计', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19)),
          ],
        ),
        centerTitle: false,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: Text(
              '$unlockedCount / ${badges.length} 已解锁',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange, fontSize: 12.5),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            children: [
              // 1. Stats Dashboard Cards
              const Padding(
                padding: EdgeInsets.only(bottom: 10, left: 4),
                child: Text(
                  '数据统计看板',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87),
                ),
              ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= 500;
                  final crossAxisCount = isWide ? 3 : 2;
                  return GridView.count(
                    crossAxisCount: crossAxisCount,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                    childAspectRatio: isWide ? 1.9 : 1.6,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      // Total Stars Card
                      _buildStatCard(
                        '关卡累积星星',
                        '$totalStars',
                        PhosphorIconsFill.star,
                        Colors.amber.shade800,
                        imageAsset: 'assets/icons/star_3d.png',
                      ),
                      // Completed Levels Card
                      _buildStatCard(
                        '完成局数',
                        '$completed',
                        PhosphorIconsBold.checkCircle,
                        const Color(0xFF2E7D32),
                      ),
                      // Snapped Pieces Card
                      _buildStatCard(
                        '已拼碎片',
                        '$snapped',
                        PhosphorIconsFill.puzzlePiece,
                        const Color(0xFF0288D1),
                      ),
                      // Play Time Card
                      _buildStatCard(
                        '总游玩时长',
                        _formatDuration(timeSec),
                        PhosphorIconsBold.timer,
                        const Color(0xFFE65100),
                      ),
                      // Average Time Card
                      _buildStatCard(
                        '平均局时',
                        completed > 0 ? _formatDuration(avgTime) : '--',
                        PhosphorIconsBold.gauge,
                        const Color(0xFF7B1FA2),
                      ),
                      // Badge Unlocked Card
                      _buildStatCard(
                        '成就解锁率',
                        '${(unlockedCount / badges.length * 100).toInt()}%',
                        PhosphorIconsFill.trophy,
                        const Color(0xFFC2185B),
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 20),

              // 2. Badges Section Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '成就勋章墙',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87),
                  ),
                  Text(
                    '共 ${badges.length} 项成就',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // 3. Badges List
              for (final b in badges) ...[
                _buildBadgeCard(b),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color, {
    String? imageAsset,
  }) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                if (imageAsset != null)
                  Image.asset(imageAsset, width: 20, height: 20)
                else
                  Icon(icon, color: color, size: 20),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBadgeCard(_BadgeData b) {
    final progress = (b.current / b.max).clamp(0.0, 1.0);

    return Material(
      color: b.isUnlocked ? Colors.white : Colors.white.withValues(alpha: 0.85),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: b.isUnlocked ? Colors.amber.shade300 : Colors.black12,
          width: b.isUnlocked ? 1.4 : 0.8,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: b.isUnlocked ? Colors.amber.shade50 : Colors.grey.shade100,
              child: b.isUnlocked
                  ? (b.imageAsset != null
                      ? Image.asset(b.imageAsset!, width: 28, height: 28)
                      : Icon(b.icon, color: Colors.amber.shade800, size: 22))
                  : Image.asset('assets/icons/lock_3d.png', width: 22, height: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        b.title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: b.isUnlocked ? Colors.black87 : Colors.black54,
                        ),
                      ),
                      if (b.isUnlocked)
                        const Row(
                          children: [
                            Icon(PhosphorIconsFill.checkCircle, color: Color(0xFF2E7D32), size: 15),
                            SizedBox(width: 3),
                            Text(
                              '已达成',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFF2E7D32),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        )
                      else
                        Text(
                          b.isTime ? '${(b.current ~/ 60)}/${(b.max ~/ 60)}分' : '${b.current}/${b.max}',
                          style: const TextStyle(fontSize: 11.5, color: Colors.black45, fontWeight: FontWeight.w500),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    b.desc,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  if (!b.isUnlocked) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 5,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2E7D32)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BadgeData {
  _BadgeData({
    required this.title,
    required this.desc,
    required this.icon,
    required this.current,
    required this.max,
    this.imageAsset,
    this.isTime = false,
  });

  final String title;
  final String desc;
  final IconData icon;
  final String? imageAsset;
  final int current;
  final int max;
  final bool isTime;

  bool get isUnlocked => current >= max;
}
