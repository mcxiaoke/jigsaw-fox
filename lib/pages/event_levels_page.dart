import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:jigsawpuzzle/data/progress_store.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/cache/level_image_resolver.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/content/content_manager.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_event_item.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_level_item.dart';
import 'package:jigsawpuzzle/pages/game_page.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/services/recommend_service.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:jigsawpuzzle/widgets/choose_difficulty_sheet.dart';
import 'package:jigsawpuzzle/widgets/game_toast.dart';
import 'package:jigsawpuzzle/widgets/lazy_level_image.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

/// 活动内关卡 Grid 页面
class EventLevelsPage extends StatefulWidget {
  const EventLevelsPage({required this.event, super.key});

  final PuzzleEventItem event;

  static Future<void> open(BuildContext context, PuzzleEventItem event) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => EventLevelsPage(event: event)),
    );
  }

  @override
  State<EventLevelsPage> createState() => _EventLevelsPageState();
}

class _EventLevelsPageState extends State<EventLevelsPage> {
  final ContentManager _content = AppContent.instance.manager;
  bool _isLoading = false;
  late PuzzleEventItem _currentEvent;
  List<PuzzleLevelItem> _levels = [];

  @override
  void initState() {
    super.initState();
    _currentEvent = widget.event;
    unawaited(_loadLevels());
  }

  Future<void> _loadLevels() async {
    setState(() => _isLoading = true);
    try {
      if (_content.isEventDownloaded(_currentEvent)) {
        final cachedLevels = _content.getEventLevels(_currentEvent);
        if (cachedLevels.isNotEmpty) {
          if (mounted) {
            setState(() {
              _levels = cachedLevels;
              _isLoading = false;
            });
          }
          return;
        }
      }

      await _content.ensureEventDownloaded(_currentEvent);
      _levels = _content.getEventLevels(_currentEvent);
      AppLogger.events.info(
        'EventLevels loaded id=${_currentEvent.id} count=${_levels.length}',
      );
    } catch (e, st) {
      AppLogger.events.warning(
        'EventLevels load failed id=${_currentEvent.id}',
        e,
        st,
      );
      _levels = [];
      if (mounted) {
        GameToast.show(
          context,
          icon: PhosphorIconsRegular.warning,
          message: t.levels.networkFail,
          type: GameToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _openLevel(PuzzleLevelItem level, int index) async {
    Uint8List? imgBytes;
    var localPath = '';
    try {
      // 统一经 LevelImageResolver 落原图，保证与卡片缩略同文件，见缩略必可玩
      localPath = await LevelImageResolver.instance.resolveLevelLocalPath(
        level,
      );
      if (localPath.startsWith('http')) {
        if (mounted) {
          GameToast.show(
            context,
            icon: PhosphorIconsRegular.warning,
            message: t.levels.networkFail,
            type: GameToastType.error,
          );
        }
        return;
      }
      if (!mounted) return;
      if (localPath.startsWith('assets/')) {
        final data = await DefaultAssetBundle.of(context).load(localPath);
        imgBytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
      } else if (File(localPath).existsSync()) {
        imgBytes = await File(localPath).readAsBytes();
      }
    } catch (e, st) {
      AppLogger.events.warning(
        'EventLevels openLevel image fail id=${level.id}',
        e,
        st,
      );
      if (mounted) {
        GameToast.show(
          context,
          icon: PhosphorIconsRegular.warning,
          message: t.levels.imgLoadFailed(error: e),
          type: GameToastType.error,
        );
      }
      return;
    }

    if (imgBytes == null || !mounted) return;

    // 默认难度 = 全局推荐档（按 1:1 假定，面板解码后按实际比例校正）
    final defaultDiff = RecommendService.instance.squareDifficulty;

    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: defaultDiff,
      canonicalId: level.id,
      title: t.levels.titleOf(title: _currentEvent.displayTitle, index: index),
      onStart: (diff) async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: imgBytes!,
              difficulty: diff,
              canonicalId: level.id,
              packTitle: _currentEvent.displayTitle,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);

    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(
        backgroundColor: palette.surface,
        foregroundColor: palette.primaryText,
        elevation: 0.5,
        scrolledUnderElevation: 0.5,
        title: Text(
          _currentEvent.displayTitle,
          style: styles.h3.copyWith(fontSize: 17),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _levels.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    PhosphorIconsRegular.empty,
                    size: 48,
                    color: palette.disabledText,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    t.levels.empty,
                    style: styles.body.copyWith(color: palette.secondaryText),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: palette.brand,
                      foregroundColor: palette.surface,
                    ),
                    onPressed: _loadLevels,
                    child: Text(t.levels.retryDownload),
                  ),
                ],
              ),
            )
          : CustomScrollView(
              slivers: [
                if (_currentEvent.desc.isNotEmpty)
                  SliverToBoxAdapter(
                    child: Container(
                      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: palette.surfaceContainer,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: palette.divider),
                      ),
                      child: Text(
                        _currentEvent.desc,
                        style: styles.body.copyWith(height: 1.4),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 200,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 14,
                        ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final level = _levels[index];
                      return _buildLevelCard(level, index + 1, palette);
                    }, childCount: _levels.length),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
    );
  }

  Widget _buildLevelCard(PuzzleLevelItem level, int index, AppPalette palette) {
    final prog = ProgressStore.instance.getLevelProgress(level.id);
    final isCompleted = prog.isCompleted;
    final percent = prog.progressPercent;
    final isNew = level.isNew && !isCompleted;

    return InkWell(
      onTap: () => _openLevel(level, index),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.divider),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            LazyLevelImage(level: level),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.3),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.4),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            // NEW 角标 (与首页 Home 保持一致)
            if (isNew)
              Positioned(
                left: 0,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: const BoxDecoration(
                    color: Color(0xFFC97A2E),
                    borderRadius: BorderRadius.only(
                      topRight: Radius.circular(4),
                      bottomRight: Radius.circular(4),
                    ),
                  ),
                  child: const Text(
                    'New',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
              ),
            // 右上角状态 (完成/进度)
            if (isCompleted)
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.all(3.5),
                  decoration: const BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    PhosphorIconsBold.check,
                    color: Colors.white,
                    size: 11,
                  ),
                ),
              )
            else if (percent > 0)
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '$percent%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
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
