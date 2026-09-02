import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../logic/cache/level_image_resolver.dart';
import '../logic/content/app_content.dart';
import '../logic/content/models/puzzle_event_item.dart';
import '../logic/content/models/puzzle_level_item.dart';
import '../logic/puzzle_model.dart';
import '../theme/app_palette.dart';
import '../theme/app_text_styles.dart';
import '../widgets/choose_difficulty_sheet.dart';
import '../widgets/game_toast.dart';
import '../widgets/lazy_level_image.dart';
import 'game_page.dart';

/// 活动内关卡 Grid 页面
class EventLevelsPage extends StatefulWidget {
  const EventLevelsPage({super.key, required this.event});

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
  final _content = AppContent.instance.manager;
  bool _isLoading = false;
  late PuzzleEventItem _currentEvent;
  List<PuzzleLevelItem> _levels = [];

  @override
  void initState() {
    super.initState();
    _currentEvent = widget.event;
    _loadLevels();
  }

  Future<void> _loadLevels() async {
    setState(() => _isLoading = true);
    await _content.ensureEventDownloaded(_currentEvent);
    _levels = _content.getEventLevels(_currentEvent);
    setState(() => _isLoading = false);
  }

  Future<void> _openLevel(PuzzleLevelItem level, int index) async {
    Uint8List? imgBytes;
    String localPath = '';
    try {
      // 统一经 LevelImageResolver 落原图，保证与卡片缩略同文件，见缩略必可玩
      localPath = await LevelImageResolver.instance.resolveLevelLocalPath(level);
      if (localPath.startsWith('http')) {
        throw Exception('关卡图片下载失败，请检查网络后重试');
      }
      if (!mounted) return;
      if (localPath.startsWith('assets/')) {
        final data = await DefaultAssetBundle.of(context).load(localPath);
        imgBytes = data.buffer.asUint8List();
      } else if (File(localPath).existsSync()) {
        imgBytes = await File(localPath).readAsBytes();
      }
    } catch (e) {
      if (mounted) {
        GameToast.show(context, icon: Icons.error_outline, message: '图片加载失败: $e', type: GameToastType.error);
      }
      return;
    }

    if (imgBytes == null || !mounted) return;

    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: imgBytes,
      initialDifficulty: const PuzzleDifficulty(label: '4 × 4 (16 块)', rows: 4, cols: 4, recommended: true),
      completedPieceCounts: const {},
      isUnlocked: true,
      title: '${_currentEvent.title} · 第 $index 关',
      onStart: (diff) async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(imageBytes: imgBytes!, difficulty: diff, levelIndex: index),
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
        title: Text(_currentEvent.title, style: styles.h3.copyWith(fontSize: 17)),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: palette.brand))
          : _levels.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(PhosphorIconsRegular.empty, size: 48, color: palette.disabledText),
                      const SizedBox(height: 12),
                      Text('暂无可用关卡', style: styles.body.copyWith(color: palette.secondaryText)),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: palette.brand, foregroundColor: palette.surface),
                        onPressed: _loadLevels,
                        child: const Text('重试下载'),
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
                            border: Border.all(color: palette.divider, width: 1),
                          ),
                          child: Text(_currentEvent.desc, style: styles.body.copyWith(height: 1.4)),
                        ),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      sliver: SliverGrid(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 200,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 14,
                          childAspectRatio: 1.0,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final level = _levels[index];
                            return _buildLevelCard(level, index + 1, palette);
                          },
                          childCount: _levels.length,
                        ),
                      ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 32)),
                  ],
                ),
    );
  }

  Widget _buildLevelCard(PuzzleLevelItem level, int index, AppPalette palette) {
    return InkWell(
      onTap: () => _openLevel(level, index),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.divider, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            LazyLevelImage(
              level: level,
              fit: BoxFit.cover,
            ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black.withValues(alpha: 0.3), Colors.transparent, Colors.black.withValues(alpha: 0.4)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            Positioned(
              left: 8,
              top: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('第 $index 关', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ),
            Center(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: palette.brand,
                  shape: BoxShape.circle,
                ),
                child: Icon(PhosphorIconsFill.play, color: palette.surface, size: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
