import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../logic/content/app_content.dart';
import '../logic/content/models/puzzle_event_item.dart';
import '../logic/content/models/puzzle_level_item.dart';
import '../logic/puzzle_model.dart';
import '../widgets/app_cached_image.dart';
import '../widgets/choose_difficulty_sheet.dart';
import 'game_page.dart';

/// 活动内关卡 Grid 页面
class EventLevelsPage extends StatefulWidget {
  const EventLevelsPage({
    super.key,
    required this.event,
  });

  final PuzzleEventItem event;

  static Future<void> open(BuildContext context, PuzzleEventItem event) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => EventLevelsPage(event: event),
      ),
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
    // 确保资源就绪 (如 Zip 解压)
    await _content.ensureEventDownloaded(_currentEvent);
    _levels = _content.getEventLevels(_currentEvent);
    setState(() => _isLoading = false);
  }

  Future<void> _openLevel(PuzzleLevelItem level, int index) async {
    Uint8List? imgBytes;
    if (level.isLocalFile && File(level.imagePathOrUrl).existsSync()) {
      imgBytes = await File(level.imagePathOrUrl).readAsBytes();
    } else {
      // 在线图片临时下载获取
      try {
        final downloaded = await _content.ensureMainLevelDownloaded(level);
        if (File(downloaded.imagePathOrUrl).existsSync()) {
          imgBytes = await File(downloaded.imagePathOrUrl).readAsBytes();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('图片加载失败: $e')),
          );
        }
        return;
      }
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
            builder: (_) => GamePage(
              imageBytes: imgBytes!,
              difficulty: diff,
              levelIndex: index,
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _currentEvent.title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _levels.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(PhosphorIconsRegular.empty, size: 48, color: Colors.black26),
                      const SizedBox(height: 12),
                      const Text('暂无可用关卡', style: TextStyle(color: Colors.black54)),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: _loadLevels,
                        child: const Text('重试下载'),
                      ),
                    ],
                  ),
                )
              : CustomScrollView(
                  slivers: [
                    // Top Event Info Header
                    if (_currentEvent.desc.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Container(
                          margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: const [
                              BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 1)),
                            ],
                          ),
                          child: Text(
                            _currentEvent.desc,
                            style: const TextStyle(color: Colors.black87, fontSize: 13, height: 1.4),
                          ),
                        ),
                      ),

                    // Level Grid
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
                            return _buildLevelCard(level, index + 1);
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

  Widget _buildLevelCard(PuzzleLevelItem level, int index) {
    return InkWell(
      onTap: () => _openLevel(level, index),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2)),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AppCachedImage(
              imagePathOrUrl: level.imagePathOrUrl,
              fit: BoxFit.cover,
              targetWidth: 360,
              targetHeight: 360,
            ),
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black45, Colors.transparent, Color(0xA6000000)],
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
                child: Text(
                  '第 $index 关',
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            Center(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Color(0xFF2E7D32),
                  shape: BoxShape.circle,
                ),
                child: const Icon(PhosphorIconsFill.play, color: Colors.white, size: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
