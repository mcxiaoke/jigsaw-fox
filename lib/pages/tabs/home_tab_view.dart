import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../data/game_repository.dart';
import '../../data/models/level_item.dart';
import '../../data/resume_helper.dart';
import '../../data/snapshot_store.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_text_styles.dart';
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

  List<LevelItem> _getFilteredLevels(List<LevelItem> all) {
    var list = all;
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
    if (_selectedTag != 'all') {
      list = list.where((l) {
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
    final canonicalId = GameRepository.canonicalForLevel(level.index);
    final handled = await ResumeHelper.tryHandleResumeFlow(
      context: context,
      canonicalId: canonicalId,
      fallbackDifficulty: level.difficulty,
      isCompleted: level.isCompleted,
      title: '第 ${level.index} 关',
      imageBytes: imgBytes,
      onClearRepo: (k) => _repo.updateLevelProgress(levelIndex: level.index, progressPercent: 0, snapshotJson: null),
      onPushGame: (diff, jsonStr) async {
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GamePage(imageBytes: imgBytes, difficulty: diff, levelIndex: level.index, initialSnapshotJson: jsonStr)));
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
    final displayPercent = ResumeHelper.displayProgress(progress, level.progressPercent, level.isCompleted);
    if (!mounted) return;
    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: level.difficulty,
      completedPieceCounts: level.completedPieceCounts.toSet(),
      isUnlocked: level.isUnlocked,
      lockedMessage: '请先通关第 ${level.index - 1} 关解锁此关卡',
      title: '第 ${level.index} 关 · ${level.isUnlocked ? "难度选择" : "关卡预览(未解锁)"}',
      savedProgressPercent: displayPercent == 0 ? null : displayPercent,
      onResetProgress: () async {
        final prog = await ResumeHelper.loadProgress(canonicalId);
        if (prog.activeDifficultyKey.isNotEmpty) {
          await ResumeHelper.clearResume(canonicalId, prog.activeDifficultyKey);
        }
        await _repo.updateLevelProgress(levelIndex: level.index, progressPercent: 0, snapshotJson: null);
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GamePage(imageBytes: imgBytes, difficulty: level.difficulty, levelIndex: level.index, initialSnapshotJson: null)));
        setState(() {});
      },
      onStart: (diff) async {
        final dkey = SnapshotStore.difficultyKeyFor(diff);
        final snapJson = await SnapshotStore.instance.loadJsonString(canonicalId, dkey);
        final fallbackLegacy = (diff.pieceCount == level.difficulty.pieceCount && !level.isCompleted) ? level.savedSnapshotJson : null;
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => GamePage(imageBytes: imgBytes, difficulty: diff, levelIndex: level.index, initialSnapshotJson: snapJson ?? fallbackLegacy)));
        setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final allLevels = _repo.levels;
    final filteredLevels = _getFilteredLevels(allLevels);
    final now = DateTime.now();
    final todayStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final todayDaily = _repo.dailyChallenges.firstWhere(
      (d) => d.date == todayStr,
      orElse: () => _repo.dailyChallenges.first,
    );

    return RefreshIndicator(
      color: palette.brand,
      backgroundColor: palette.surfaceContainer,
      onRefresh: () async => setState(() {}),
      child: CustomScrollView(
        slivers: [
          // ── Banner ─────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: _DailyBanner(
                todayDaily: todayDaily,
                now: now,
                palette: palette,
                styles: styles,
                onTap: widget.onSwitchToDaily,
              ),
            ),
          ),

          // ── Filter Segmented Control ───────
          SliverToBoxAdapter(
            child: _FilterBar(
              selectedFilter: _selectedFilter,
              palette: palette,
              onChanged: (f) => setState(() => _selectedFilter = f),
            ),
          ),

          // ── Tag Chips ──────────────────────
          SliverToBoxAdapter(
            child: _TagChips(
              selectedTag: _selectedTag,
              palette: palette,
              onChanged: (t) => setState(() => _selectedTag = t),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 6)),

          // ── Level Grid ─────────────────────
          if (filteredLevels.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Column(
                    children: [
                      const Text('🦊', style: TextStyle(fontSize: 44)),
                      const SizedBox(height: 8),
                      Text(
                        '小狐狸没找到符合该条件的关卡',
                        style: styles.caption.copyWith(fontSize: 14),
                      ),
                    ],
                  ),
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
                    return _LevelCard(
                      level: level,
                      palette: palette,
                      styles: styles,
                      onTap: () => _openLevel(level),
                    );
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
}

// ═══════════════════════════════════════════════════
// Banner: full-bleed image + gradient overlay
// ═══════════════════════════════════════════════════
class _DailyBanner extends StatelessWidget {
  const _DailyBanner({
    required this.todayDaily,
    required this.now,
    required this.palette,
    required this.styles,
    required this.onTap,
  });

  final dynamic todayDaily;
  final DateTime now;
  final AppPalette palette;
  final AppTextStyles styles;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        height: 160,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Background image
            AppCachedImage(
              imagePathOrUrl: todayDaily.assetPath,
              fit: BoxFit.cover,
              targetWidth: 600,
              targetHeight: 320,
            ),
            // Gradient overlay (black → transparent)
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black87, Colors.transparent, Colors.black54],
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  stops: [0.0, 0.5, 1.0],
                ),
              ),
            ),
            // Content
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Tag row
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: palette.brand,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('🔥', style: TextStyle(fontSize: 10)),
                            const SizedBox(width: 4),
                            Text(
                              '每日挑战',
                              style: TextStyle(
                                color: palette.surface,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (todayDaily.isCompleted) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: palette.success,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '已完成',
                            style: TextStyle(
                              color: palette.surface,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${now.month}月${now.day}日 · 今日专属',
                    style: styles.h2.copyWith(
                      color: Colors.white,
                      fontSize: 20,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(PhosphorIconsFill.puzzlePiece, size: 12, color: Colors.white70),
                      const SizedBox(width: 4),
                      Text(
                        '${todayDaily.difficulty.pieceCount} 块拼图',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white24, width: 0.5),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('🪙', style: TextStyle(fontSize: 10)),
                            const SizedBox(width: 2),
                            Text(
                              '+50',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
// Filter Segmented Control
// ═══════════════════════════════════════════════════
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.selectedFilter,
    required this.palette,
    required this.onChanged,
  });

  final LevelFilter selectedFilter;
  final AppPalette palette;
  final ValueChanged<LevelFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: [
            for (final filter in LevelFilter.values) ...[
              _FilterChip(
                label: filter.label,
                isActive: selectedFilter == filter,
                palette: palette,
                onTap: () => onChanged(filter),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.isActive,
    required this.palette,
    required this.onTap,
  });

  final String label;
  final bool isActive;
  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? palette.brand : palette.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive ? palette.brand : palette.divider,
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            color: isActive ? palette.surface : palette.secondaryText,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
// Tag Chips
// ═══════════════════════════════════════════════════
class _TagChips extends StatelessWidget {
  const _TagChips({
    required this.selectedTag,
    required this.palette,
    required this.onChanged,
  });

  final String selectedTag;
  final AppPalette palette;
  final ValueChanged<String> onChanged;

  static const List<Map<String, String>> _tags = [
    {'tag': 'all', 'label': '全部'},
    {'tag': 'animal', 'label': '萌宠'},
    {'tag': 'landscape', 'label': '风光'},
    {'tag': 'bird', 'label': '飞鸟'},
    {'tag': 'art', 'label': '艺术'},
    {'tag': 'architecture', 'label': '建筑'},
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: [
            for (final item in _tags) ...[
              _TagChip(
                label: item['label']!,
                isActive: selectedTag == item['tag']!,
                palette: palette,
                onTap: () => onChanged(item['tag']!),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.label,
    required this.isActive,
    required this.palette,
    required this.onTap,
  });

  final String label;
  final bool isActive;
  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isActive
              ? palette.brand.withValues(alpha: 0.12)
              : palette.surfaceContainer,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isActive ? palette.brand.withValues(alpha: 0.4) : palette.divider,
            width: isActive ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
            color: isActive ? palette.brand : palette.secondaryText,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════
// Level Card (no title text, tag-like visuals)
// ═══════════════════════════════════════════════════
class _LevelCard extends StatelessWidget {
  const _LevelCard({
    required this.level,
    required this.palette,
    required this.styles,
    required this.onTap,
  });

  final LevelItem level;
  final AppPalette palette;
  final AppTextStyles styles;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Image
            AppCachedImage(
              imagePathOrUrl: level.assetPath,
              fit: BoxFit.cover,
              targetWidth: 360,
              targetHeight: 360,
            ),

            // Dark overlay for locked levels — warm grey wash instead of black
            if (!level.isUnlocked)
              Container(
                decoration: BoxDecoration(
                  color: palette.surface.withValues(alpha: 0.55),
                ),
              ),

            // Top gradient for pill readability
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black54, Colors.transparent],
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                ),
              ),
            ),

            // Bottom gradient for progress bar readability
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.transparent, Colors.black.withValues(alpha: 0.6)],
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),

            // ── Top-left: #index pill ──
            Positioned(
              left: 10,
              top: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '#${level.index}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),

            // ── Top-right: piece count pill ──
            Positioned(
              top: 10,
              right: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: palette.surface.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: palette.divider, width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(PhosphorIconsFill.puzzlePiece, size: 11, color: palette.secondaryText),
                    const SizedBox(width: 3),
                    Text(
                      '${level.difficulty.pieceCount}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: palette.primaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Center: play button (unlocked, not started) ──
            if (level.isUnlocked && !level.isCompleted && level.progressPercent == 0)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: AppPalette.brandGradient,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: palette.brand.withValues(alpha: 0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(PhosphorIconsFill.play, color: palette.surface, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        '开始',
                        style: TextStyle(
                          color: palette.surface,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // ── Bottom area ──
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Stars for completed
                  if (level.isCompleted)
                    Row(
                      children: List.generate(3, (i) {
                        return Padding(
                          padding: const EdgeInsets.only(right: 2),
                          child: i < level.stars
                              ? Icon(PhosphorIconsFill.star, color: palette.gold, size: 16)
                              : Icon(PhosphorIconsRegular.star, color: Colors.white.withValues(alpha: 0.4), size: 16),
                        );
                      }),
                    )
                  else if (level.progressPercent > 0)
                    // Progress bar for in-progress
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: level.progressPercent / 100.0,
                        minHeight: 4,
                        backgroundColor: Colors.white.withValues(alpha: 0.25),
                        valueColor: AlwaysStoppedAnimation<Color>(palette.brand),
                      ),
                    )
                  else if (!level.isUnlocked)
                    // Lock icon
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(PhosphorIconsFill.lockKey, color: palette.disabledText, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          '需 ${level.index * 2} 星解锁',
                          style: TextStyle(
                            color: palette.disabledText,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),

                  const SizedBox(height: 4),
                  // Meta info (piece count / time)
                  if (level.isCompleted)
                    Text(
                      '最佳 ${level.bestTimeSeconds > 0 ? '${(level.bestTimeSeconds ~/ 60)}:${(level.bestTimeSeconds % 60).toString().padLeft(2, '0')}' : '—'}',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 11,
                      ),
                    )
                  else if (level.progressPercent > 0)
                    Text(
                      '${level.progressPercent}%',
                      style: TextStyle(
                        color: palette.brand,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
