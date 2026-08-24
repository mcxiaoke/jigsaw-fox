import 'package:flutter/material.dart';

import '../data/game_repository.dart';

class AchievementsDialog extends StatelessWidget {
  const AchievementsDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const AchievementsDialog(),
    );
  }

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
    final completed = repo.totalCompletedLevels;
    final snapped = repo.totalPiecesSnapped;
    final timeSec = repo.totalPlayTimeSeconds;
    final avgTime = completed > 0 ? (timeSec ~/ completed) : 0;

    final badges = [
      _BadgeData(
        title: '初入拼界',
        desc: '完成首局拼图挑战',
        icon: Icons.emoji_events_outlined,
        current: completed,
        max: 1,
      ),
      _BadgeData(
        title: '拼图学徒',
        desc: '累计完成 5 局拼图',
        icon: Icons.military_tech_outlined,
        current: completed,
        max: 5,
      ),
      _BadgeData(
        title: '拼图大师',
        desc: '累计完成 20 局拼图',
        icon: Icons.workspace_premium_outlined,
        current: completed,
        max: 20,
      ),
      _BadgeData(
        title: '拼图传奇',
        desc: '累计完成 50 局拼图',
        icon: Icons.diamond_outlined,
        current: completed,
        max: 50,
      ),
      _BadgeData(
        title: '碎片收集者',
        desc: '累计拼合 50 块碎片',
        icon: Icons.extension_outlined,
        current: snapped,
        max: 50,
      ),
      _BadgeData(
        title: '拼图能手',
        desc: '累计拼合 200 块碎片',
        icon: Icons.extension,
        current: snapped,
        max: 200,
      ),
      _BadgeData(
        title: '千锤百炼',
        desc: '累计拼合 1000 块碎片',
        icon: Icons.auto_awesome,
        current: snapped,
        max: 1000,
      ),
      _BadgeData(
        title: '专注达人',
        desc: '累计游玩时间超过 30 分钟',
        icon: Icons.timer_outlined,
        current: timeSec,
        max: 1800,
        isTime: true,
      ),
      _BadgeData(
        title: '沉浸探索',
        desc: '累计游玩时间超过 2 小时',
        icon: Icons.hourglass_top,
        current: timeSec,
        max: 7200,
        isTime: true,
      ),
      _BadgeData(
        title: '每日不辍',
        desc: '通关至少 1 次每日拼图',
        icon: Icons.calendar_month,
        current: repo.dailyChallenges.where((d) => d.isCompleted).length,
        max: 1,
      ),
      _BadgeData(
        title: '匠心自造',
        desc: '通关至少 1 次自制拼图',
        icon: Icons.palette_outlined,
        current: repo.customPuzzles.where((c) => c.isCompleted).length,
        max: 1,
      ),
      _BadgeData(
        title: '高阶挑战者',
        desc: '完成 64 块以上高难度拼图',
        icon: Icons.stars,
        current: repo.levels.where((l) => l.completedPieceCounts.any((c) => c >= 64)).length,
        max: 1,
      ),
    ];

    final unlockedCount = badges.where((b) => b.isUnlocked).length;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Row(
            children: [
              Icon(Icons.emoji_events, color: Colors.amber, size: 26),
              SizedBox(width: 10),
              Text('成就与统计', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 19)),
            ],
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '$unlockedCount / ${badges.length}',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.orange, fontSize: 13),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),

              // 1. Stats Dashboard Grid
              Row(
                children: [
                  Expanded(
                    child: _buildStatCard(
                      '完成局数',
                      '$completed',
                      Icons.check_circle_outline,
                      const Color(0xFF2E7D32),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildStatCard(
                      '已拼碎片',
                      '$snapped',
                      Icons.extension,
                      const Color(0xFF0288D1),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _buildStatCard(
                      '总游玩时长',
                      _formatDuration(timeSec),
                      Icons.timer_outlined,
                      const Color(0xFFE65100),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildStatCard(
                      '平均局时',
                      completed > 0 ? _formatDuration(avgTime) : '--',
                      Icons.speed,
                      const Color(0xFF7B1FA2),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 4),

              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '成就勋章墙',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
              const SizedBox(height: 8),

              // 2. Badges List
              for (final b in badges) ...[
                _buildBadgeRow(b),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF2E7D32),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('我知道了'),
        ),
      ],
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  Widget _buildBadgeRow(_BadgeData b) {
    final progress = (b.current / b.max).clamp(0.0, 1.0);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: b.isUnlocked ? const Color(0xFFFFF8E1) : Colors.grey.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: b.isUnlocked ? Colors.amber.shade300 : Colors.black12,
          width: b.isUnlocked ? 1.2 : 0.8,
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: b.isUnlocked ? Colors.amber.shade400 : Colors.grey.shade300,
            child: Icon(
              b.isUnlocked ? b.icon : Icons.lock_outline,
              color: b.isUnlocked ? Colors.white : Colors.grey.shade600,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
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
                        fontSize: 13.5,
                        color: b.isUnlocked ? Colors.black87 : Colors.black54,
                      ),
                    ),
                    if (b.isUnlocked)
                      const Row(
                        children: [
                          Icon(Icons.check_circle, color: Color(0xFF2E7D32), size: 14),
                          SizedBox(width: 2),
                          Text('已达成', style: TextStyle(fontSize: 11, color: Color(0xFF2E7D32), fontWeight: FontWeight.bold)),
                        ],
                      )
                    else
                      Text(
                        b.isTime ? '${(b.current ~/ 60)}/${(b.max ~/ 60)}分' : '${b.current}/${b.max}',
                        style: const TextStyle(fontSize: 11, color: Colors.black45),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  b.desc,
                  style: const TextStyle(fontSize: 11.5, color: Colors.black54),
                ),
                if (!b.isUnlocked) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
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
    this.isTime = false,
  });

  final String title;
  final String desc;
  final IconData icon;
  final int current;
  final int max;
  final bool isTime;

  bool get isUnlocked => current >= max;
}
