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
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final repo = GameRepository.instance;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(
        children: [
          Icon(Icons.emoji_events, color: Colors.amber),
          SizedBox(width: 10),
          Text('成就与统计'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Stats Grid
            Row(
              children: [
                Expanded(
                  child: _buildStatCard(
                    '完成关卡',
                    '${repo.totalCompletedLevels}',
                    Icons.check_circle_outline,
                    Colors.green,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildStatCard(
                    '已拼碎片',
                    '${repo.totalPiecesSnapped}',
                    Icons.extension,
                    Colors.blue,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _buildStatCard(
              '总游玩时长',
              _formatDuration(repo.totalPlayTimeSeconds),
              Icons.timer_outlined,
              Colors.orange,
            ),
            const SizedBox(height: 16),
            const Divider(),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '成就勋章',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
            const SizedBox(height: 8),
            _buildBadgeItem(
              '初出茅庐',
              '完成首局拼图挑战',
              repo.totalCompletedLevels >= 1,
            ),
            _buildBadgeItem(
              '拼图能手',
              '累计拼合 100 块碎片',
              repo.totalPiecesSnapped >= 100,
            ),
            _buildBadgeItem(
              '拼图大师',
              '累计完成 10 局拼图',
              repo.totalCompletedLevels >= 10,
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF2E7D32),
          ),
          child: const Text('知道了'),
        ),
      ],
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  Widget _buildBadgeItem(String title, String desc, bool unlocked) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: unlocked ? Colors.amber.shade100 : Colors.grey.shade200,
        child: Icon(
          unlocked ? Icons.stars : Icons.lock_outline,
          color: unlocked ? Colors.amber.shade800 : Colors.grey,
        ),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: unlocked ? Colors.black87 : Colors.grey,
        ),
      ),
      subtitle: Text(desc, style: const TextStyle(fontSize: 12)),
      trailing: unlocked
          ? const Icon(Icons.check, color: Colors.green, size: 20)
          : const Text('未达成', style: TextStyle(fontSize: 12, color: Colors.grey)),
    );
  }
}
