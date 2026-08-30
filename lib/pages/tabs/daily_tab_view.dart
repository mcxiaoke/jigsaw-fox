import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../data/game_repository.dart';
import '../../data/models/daily_challenge.dart';
import '../../data/resume_helper.dart';
import '../../data/snapshot_store.dart';
import '../../logic/image_source.dart';
import '../../widgets/app_cached_image.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../game_page.dart';

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
    final canonicalId = GameRepository.canonicalForDaily(item.date);
    final handled = await ResumeHelper.tryHandleResumeFlow(
      context: context,
      canonicalId: canonicalId,
      fallbackDifficulty: item.difficulty,
      isCompleted: item.isCompleted,
      title: '${item.date} 挑战',
      imageBytes: imgBytes,
      onClearRepo: (k) => _repo.updateDailyProgress(dateStr: item.date, progressPercent: 0, snapshotJson: null),
      onPushGame: (diff, jsonStr) async {
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GamePage(imageBytes: imgBytes, difficulty: diff, dailyDateStr: item.date, initialSnapshotJson: jsonStr)));
      },
      onCancelled: () {
        if (mounted) setState(() {});
      },
    );
    if (handled) {
      if (mounted) setState(() {});
      return;
    }
    if (!mounted) return;
    final progress = await ResumeHelper.loadProgress(canonicalId);
    final displayPercent = ResumeHelper.displayProgress(progress, item.progressPercent, item.isCompleted);
    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: item.difficulty,
      completedPieceCounts: item.completedPieceCounts.toSet(),
      title: '${item.date} 挑战 · 难度选择',
      savedProgressPercent: displayPercent == 0 ? null : displayPercent,
      onResetProgress: () async {
        final prog = await ResumeHelper.loadProgress(canonicalId);
        if (prog.activeDifficultyKey.isNotEmpty) {
          await ResumeHelper.clearResume(canonicalId, prog.activeDifficultyKey);
        }
        await _repo.updateDailyProgress(dateStr: item.date, progressPercent: 0, snapshotJson: null);
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GamePage(imageBytes: imgBytes, difficulty: item.difficulty, dailyDateStr: item.date, initialSnapshotJson: null)));
        setState(() {});
      },
      onStart: (diff) async {
        final dkey = SnapshotStore.difficultyKeyFor(diff);
        final snapJson = await SnapshotStore.instance.loadJsonString(canonicalId, dkey);
        final fallbackLegacy = (diff.pieceCount == item.difficulty.pieceCount && !item.isCompleted) ? item.savedSnapshotJson : null;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GamePage(imageBytes: imgBytes, difficulty: diff, dailyDateStr: item.date, initialSnapshotJson: snapJson ?? fallbackLegacy)));
        setState(() {});
      },
    );
  }

  int _calculateStreak(List<DailyChallengeItem> dailyList) {
    var streak = 0;
    final now = DateTime.now();
    for (var d = now.day; d >= 1; d--) {
      final match = dailyList.firstWhere((item) => item.dayNumber == d, orElse: () => dailyList.first);
      if (match.isCompleted) {
        streak++;
      } else if (d != now.day) {
        break;
      }
    }
    return streak;
  }

  static bool isValidDateStr(String dateStr) {
    final parts = dateStr.split('-');
    if (parts.length != 3) return false;
    final year = int.tryParse(parts[0]) ?? 0;
    final month = int.tryParse(parts[1]) ?? 0;
    final day = int.tryParse(parts[2]) ?? 0;
    if (year < 2000 || year > 2100 || month < 1 || month > 12) return false;
    final maxDays = DateTime(year, month + 1, 0).day;
    return day >= 1 && day <= maxDays;
  }

  @override
  Widget build(BuildContext context) {
    final dailyList = _repo.dailyChallenges;
    final now = DateTime.now();
    final todayStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final visibleDailyList = dailyList.where((d) {
      if (!isValidDateStr(d.date)) return false;
      return d.date.compareTo(todayStr) <= 0;
    }).toList();
    final todayItem = dailyList.firstWhere((d) => d.date == todayStr, orElse: () => visibleDailyList.isNotEmpty ? visibleDailyList.first : dailyList.first);
    final totalCompletedCount = visibleDailyList.where((d) => d.isCompleted).length;
    final streak = _calculateStreak(dailyList);
    final Map<String, List<DailyChallengeItem>> monthGroups = {};
    for (final item in visibleDailyList) {
      final monthKey = item.date.substring(0, 7);
      monthGroups.putIfAbsent(monthKey, () => []).add(item);
    }
    return RefreshIndicator(
      onRefresh: () async => setState(() {}),
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Card(
                elevation: 3,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
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
                                Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(8)), child: const Text('TODAY', style: TextStyle(color: Color(0xFF1B5E20), fontSize: 11, fontWeight: FontWeight.bold))),
                                const SizedBox(width: 6),
                                Text('${now.month} 月 ${now.day} 日', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black54)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text('${now.month}月${now.day}日 · 今日挑战', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87), maxLines: 1, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 14),
                            FilledButton.icon(
                              onPressed: () => _openDaily(todayItem),
                              icon: Icon(todayItem.isCompleted ? PhosphorIconsBold.arrowsClockwise : PhosphorIconsFill.play, size: 18),
                              label: Text(todayItem.isCompleted ? '已通关 (重玩)' : (todayItem.progressPercent > 0 ? '继续挑战' : '开始挑战'), style: const TextStyle(fontWeight: FontWeight.bold)),
                              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2E7D32), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: SizedBox(width: 130, height: 120, child: AppCachedImage(imagePathOrUrl: todayItem.assetPath, fit: BoxFit.cover, targetWidth: 360, targetHeight: 360, errorWidget: Image.asset(assetSamples[0], fit: BoxFit.cover))),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)]),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(children: [Image.asset('assets/icons/trophy_3d.png', width: 22, height: 22), const SizedBox(width: 6), Text('每日总进度: $totalCompletedCount/${visibleDailyList.length}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5))]),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [Image.asset('assets/icons/fire_3d.png', width: 18, height: 18), const SizedBox(width: 4), Text('连胜 $streak 天', style: const TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.bold, fontSize: 12))]),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          for (final entry in monthGroups.entries) ...[
            SliverToBoxAdapter(child: _buildMonthHeader(entry.key, entry.value)),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 220, crossAxisSpacing: 14, mainAxisSpacing: 14, childAspectRatio: 1.0),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final item = entry.value[index];
                  return _buildDailyCard(item);
                }, childCount: entry.value.length),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  Widget _buildMonthHeader(String monthKey, List<DailyChallengeItem> monthItems) {
    final parts = monthKey.split('-');
    final year = parts.isNotEmpty ? parts[0] : '';
    final month = parts.length > 1 ? int.tryParse(parts[1]) ?? 1 : 1;
    final headerTitle = '$year年$month月';
    final completedCount = monthItems.where((d) => d.isCompleted).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(children: [Container(width: 4, height: 16, decoration: BoxDecoration(color: const Color(0xFF2E7D32), borderRadius: BorderRadius.circular(2))), const SizedBox(width: 8), Text(headerTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87))]),
          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3), decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(10)), child: Text('已完成 $completedCount/${monthItems.length}', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Colors.grey.shade700))),
        ],
      ),
    );
  }

  Widget _buildDailyCard(DailyChallengeItem item) {
    return InkWell(
      onTap: () => _openDaily(item),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2))]),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AppCachedImage(imagePathOrUrl: item.assetPath, fit: BoxFit.cover, targetWidth: 360, targetHeight: 360, errorWidget: Image.asset(assetSamples[0], fit: BoxFit.cover)),
            Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [Colors.black45, Colors.transparent], begin: Alignment.topCenter, end: Alignment.center))),
            Positioned(top: 10, left: 10, child: Container(width: 34, height: 34, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.94), shape: BoxShape.circle, boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)]), alignment: Alignment.center, child: Text('${item.dayNumber}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87)))),
            if (item.isCompleted)
              Positioned(top: 10, right: 10, child: Container(padding: const EdgeInsets.all(5), decoration: const BoxDecoration(color: Color(0xFF2E7D32), shape: BoxShape.circle), child: const Icon(PhosphorIconsBold.check, color: Colors.white, size: 14)))
            else if (item.progressPercent > 0)
              Positioned(top: 10, right: 10, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(12)), child: Text('${item.progressPercent}%', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF2E7D32))))),
          ],
        ),
      ),
    );
  }
}
