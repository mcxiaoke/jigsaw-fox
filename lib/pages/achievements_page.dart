import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/game_repository.dart';
import '../data/progress_store.dart';
import '../services/achievement_service.dart';
import '../services/achievement_store.dart';
import '../services/economy_service.dart';
import '../services/sound_service.dart';

/// 全屏成就勋章与游戏数据统计页面（数据驱动，v3.3.1 设计）
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
  final _repo = GameRepository.instance;
  final _store = AchievementStore.instance;
  final _eco = EconomyService.instance;
  final _achService = AchievementService.instance;

  StreamSubscription<AchievementDefinition>? _unlockSub;
  int _distinct3Star = 0;
  int _totalStars = 0;
  int _totalSolved = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAsyncStats();
    _unlockSub = _achService.onAchievementUnlocked.listen((_) {
      if (mounted) _loadAsyncStats();
    });
  }

  @override
  void dispose() {
    _unlockSub?.cancel();
    super.dispose();
  }

  Future<void> _loadAsyncStats() async {
    await ProgressStore.instance.init();
    await _store.init();
    await _eco.init();

    final d3 = await ProgressStore.instance.getDistinctImagesWith3Star();
    final ts = await ProgressStore.instance.getTotalStars();
    final sv = await ProgressStore.instance.getTotalSolved();

    if (mounted) {
      setState(() {
        _distinct3Star = d3;
        _totalStars = ts > 0 ? ts : _repo.levels.fold<int>(0, (sum, l) => sum + l.stars);
        _totalSolved = sv;
        _loading = false;
      });
    }
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

  Future<void> _claimReward(AchievementDefinition def) async {
    final ok = await _achService.claimReward(def.id);
    if (ok && mounted) {
      SoundService.I.play(Sfx.coinsFly);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('成功领取成就奖励：+${def.coinReward} 金币！💰'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      _loadAsyncStats();
    }
  }

  @override
  Widget build(BuildContext context) {
    final completed = _totalSolved;
    final snapped = _repo.totalPiecesSnapped;
    final timeSec = _repo.totalPlayTimeSeconds;
    final coins = _eco.coins;

    final allDefs = AchievementService.allAchievements;
    final unlockedCount = allDefs.where((a) => _store.isUnlocked(a.id)).length;

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
              '$unlockedCount / ${allDefs.length} 已解锁',
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
              // 1. Stats Dashboard Header
              const Padding(
                padding: EdgeInsets.only(bottom: 10, left: 4),
                child: Text(
                  '数据统计看板',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87),
                ),
              ),

              // 2. Stats Grid
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
                      _buildStatCard(
                        '关卡累积星星',
                        '$_totalStars',
                        PhosphorIconsFill.star,
                        Colors.amber.shade800,
                        imageAsset: 'assets/icons/star_3d.png',
                      ),
                      _buildStatCard(
                        '3星拼图数',
                        '$_distinct3Star 张',
                        PhosphorIconsFill.trophy,
                        const Color(0xFFE65100),
                        imageAsset: 'assets/icons/trophy_3d.png',
                      ),
                      _buildStatCard(
                        '已通关图数',
                        '$completed 张',
                        PhosphorIconsBold.checkCircle,
                        const Color(0xFF2E7D32),
                      ),
                      _buildStatCard(
                        '拥有金币',
                        '$coins 💰',
                        PhosphorIconsFill.coins,
                        const Color(0xFFF57F17),
                      ),
                      _buildStatCard(
                        '已拼碎片',
                        '$snapped',
                        PhosphorIconsFill.puzzlePiece,
                        const Color(0xFF0288D1),
                      ),
                      _buildStatCard(
                        '总游玩时长',
                        _formatDuration(timeSec),
                        PhosphorIconsBold.timer,
                        const Color(0xFF7B1FA2),
                      ),
                    ],
                  );
                },
              ),

              const SizedBox(height: 20),

              // 3. Badges Section Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '成就勋章墙',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87),
                  ),
                  Text(
                    '共 ${allDefs.length} 项成就',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // 4. Badges List (Data Driven)
              if (_loading)
                const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
              else
                for (final def in allDefs) ...[
                  _buildAchievementCard(def),
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

  Widget _buildAchievementCard(AchievementDefinition def) {
    final isUnlocked = _store.isUnlocked(def.id);
    final isClaimed = _store.isClaimed(def.id);
    final current = def.type == AchievementType.derived
        ? (allDefsExcludingMaster().where((a) => _store.isUnlocked(a.id)).length)
        : _store.getCounter(def.metricKey);
    final progress = (current / def.target).clamp(0.0, 1.0);

    return Material(
      color: isUnlocked ? Colors.white : Colors.white.withValues(alpha: 0.85),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isUnlocked ? (isClaimed ? const Color(0xFFC8E6C9) : Colors.amber.shade400) : Colors.black12,
          width: isUnlocked ? 1.4 : 0.8,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: isUnlocked ? Colors.amber.shade50 : Colors.grey.shade100,
              child: isUnlocked
                  ? Image.asset('assets/icons/trophy_3d.png', width: 28, height: 28)
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
                        def.title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: isUnlocked ? Colors.black87 : Colors.black54,
                        ),
                      ),
                      if (isUnlocked)
                        if (isClaimed)
                          const Row(
                            children: [
                              Icon(PhosphorIconsFill.checkCircle, color: Color(0xFF2E7D32), size: 15),
                              SizedBox(width: 3),
                              Text(
                                '已领取',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: Color(0xFF2E7D32),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          )
                        else
                          FilledButton.tonal(
                            onPressed: () => _claimReward(def),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: Colors.amber.shade100,
                              foregroundColor: const Color(0xFF795548),
                            ),
                            child: Text(
                              '领 +${def.coinReward} 💰',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          )
                      else
                        Text(
                          def.metricKey == 'play_seconds'
                              ? '${(current ~/ 60)}/${(def.target ~/ 60)}分'
                              : '$current/${def.target}',
                          style: const TextStyle(fontSize: 11.5, color: Colors.black45, fontWeight: FontWeight.w500),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    def.description,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  if (!isUnlocked) ...[
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

  List<AchievementDefinition> allDefsExcludingMaster() {
    return AchievementService.allAchievements.where((a) => a.id != 'master_all').toList();
  }
}
