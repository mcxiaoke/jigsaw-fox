import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../data/game_repository.dart';
import '../../data/models/custom_puzzle_item.dart';
import '../../logic/download_manager.dart';
import '../../logic/image_source.dart';
import '../../widgets/app_cached_image.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../../widgets/downloaded_drawer_sheet.dart';
import '../crop_puzzle_page.dart';
import '../game_page.dart';
import '../online_image_picker_page.dart';

/// "My Puzzles" (我的自制关卡) tab view supporting UGC creation, adaptive responsive grid, and play.
class MyPuzzlesTabView extends StatefulWidget {
  const MyPuzzlesTabView({super.key});

  @override
  State<MyPuzzlesTabView> createState() => _MyPuzzlesTabViewState();
}

class _MyPuzzlesTabViewState extends State<MyPuzzlesTabView> {
  final _repo = GameRepository.instance;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    DownloadManager.instance.init();
  }

  Future<void> _createFromGallery() async {
    setState(() => _loading = true);
    try {
      final picker = ImagePicker();
      final files = await picker.pickMultiImage(imageQuality: 90);
      if (files.isEmpty) return;

      final imported = await DownloadManager.instance.importFromLocalFiles(files);
      if (!mounted || imported.isEmpty) return;

      if (files.length == 1) {
        // Single pick: Auto-save to Material Box & seamlessly proceed to Crop
        final item = imported.first;
        final file = File(item.localPath);
        final bytes = await file.readAsBytes();
        if (!mounted) return;

        final result = await CropPuzzlePage.push(
          context,
          bytes,
          sourceType: 'gallery',
          sourcePlatform: '本地相册',
          sourceUrl: item.sourceUrl,
        );
        if (result != null && mounted) {
          setState(() {}); // refresh created puzzle
        }
      } else {
        // Multi pick: Batch imported into Material Box with instant action SnackBar
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已成功导入 ${imported.length} 张图片到素材库'),
              action: SnackBarAction(
                label: '查看素材库',
                textColor: const Color(0xFF81C784),
                onPressed: () {
                  DownloadedDrawerSheet.show(context);
                },
              ),
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择图片失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openCustom(CustomPuzzleItem item) async {
    Uint8List bytes;
    if (item.isLocalFile && !item.imagePathOrUrl.startsWith('assets/')) {
      final file = File(item.imagePathOrUrl);
      if (await file.exists()) {
        bytes = await file.readAsBytes();
      } else {
        final data = await rootBundle.load(assetSamples[0]);
        bytes = data.buffer.asUint8List();
      }
    } else if (item.imagePathOrUrl.startsWith('assets/')) {
      final data = await rootBundle.load(item.imagePathOrUrl);
      bytes = data.buffer.asUint8List();
    } else {
      final data = await rootBundle.load(assetSamples[0]);
      bytes = data.buffer.asUint8List();
    }

    if (!mounted) return;
    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: bytes,
      initialDifficulty: item.difficulty,
      completedPieceCounts: item.completedPieceCounts.toSet(),
      title: '${item.title} · 难度选择',
      savedProgressPercent: item.isCompleted ? null : item.progressPercent,
      sourcePlatform: item.sourcePlatform,
      sourceUrl: item.sourceUrl,
      onDelete: () async {
        await _repo.deleteCustomPuzzle(item.id);
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已删除「${item.title}」')),
          );
        }
      },
      onResetProgress: () async {
        await _repo.updateCustomProgress(
          id: item.id,
          progressPercent: 0,
          snapshotJson: null,
          isCompleted: item.isCompleted,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: bytes,
              difficulty: item.difficulty,
              customId: item.id,
              initialSnapshotJson: null,
            ),
          ),
        );
        setState(() {});
      },
      onStart: (diff) async {
        final isSameDiff = diff.pieceCount == item.difficulty.pieceCount;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: bytes,
              difficulty: diff,
              customId: item.id,
              initialSnapshotJson: isSameDiff && !item.isCompleted ? item.savedSnapshotJson : null,
            ),
          ),
        );
        setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<CustomPuzzleItem>>(
      valueListenable: _repo.customPuzzlesNotifier,
      builder: (context, customList, _) {
        return RefreshIndicator(
          onRefresh: () async => setState(() {}),
          child: CustomScrollView(
            slivers: [
              // 1. Top UGC Creation Action Cards (3 compact side-by-side cards)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                  child: Row(
                    children: [
                      // 1.1 Left Card: Local Gallery
                      Expanded(
                        child: _buildTopActionCard(
                          title: '相册选图',
                          subtitle: '批量导入',
                          iconWidget: _loading
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(color: Color(0xFF2E7D32), strokeWidth: 2),
                                )
                              : Image.asset('assets/icons/camera_3d.png', width: 20, height: 20),
                          gradientColors: const [Color(0xFFE8F5E9), Color(0xFFC8E6C9)],
                          borderColor: const Color(0xFF81C784),
                          textColor: const Color(0xFF1B5E20),
                          onTap: _loading ? null : _createFromGallery,
                        ),
                      ),
                      const SizedBox(width: 8),

                      // 1.2 Middle Card: Material Box (素材库)
                      Expanded(
                        child: ValueListenableBuilder(
                          valueListenable: DownloadManager.instance.itemsNotifier,
                          builder: (context, materialItems, _) {
                            return _buildTopActionCard(
                              title: '素材库',
                              subtitle: '${materialItems.length} 张素材',
                              iconWidget: const Icon(PhosphorIconsFill.archive, color: Color(0xFFE65100), size: 18),
                              gradientColors: const [Color(0xFFFFF3E0), Color(0xFFFFE0B2)],
                              borderColor: const Color(0xFFFFB74D),
                              textColor: const Color(0xFFE65100),
                              onTap: () async {
                                await DownloadedDrawerSheet.show(context);
                              },
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 8),

                      // 1.3 Right Card: Online Search
                      Expanded(
                        child: _buildTopActionCard(
                          title: '在线搜图',
                          subtitle: '海量图库',
                          iconWidget: const Icon(PhosphorIconsFill.globeHemisphereWest, color: Color(0xFF0277BD), size: 18),
                          gradientColors: const [Color(0xFFE1F5FE), Color(0xFFB3E5FC)],
                          borderColor: const Color(0xFF4FC3F7),
                          textColor: const Color(0xFF01579B),
                          onTap: () async {
                            await OnlineImagePickerPage.push(context);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 2. Section Header
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '我的自制合辑',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '共 ${customList.length} 个关卡',
                        style: const TextStyle(fontSize: 13, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ),

              // 3. Responsive Grid or Empty state
              if (customList.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(PhosphorIconsRegular.images, size: 48, color: Colors.grey),
                          SizedBox(height: 10),
                          Text('还没有自制拼图，点击上方「相册选图」或「素材库」开始制作吧！', style: TextStyle(color: Colors.grey)),
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
                        final item = customList[index];
                        return _buildCustomGridCard(item);
                      },
                      childCount: customList.length,
                    ),
                  ),
                ),

              const SliverToBoxAdapter(child: SizedBox(height: 28)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCustomGridCard(CustomPuzzleItem item) {
    return InkWell(
      onTap: () => _openCustom(item),
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
            // Thumbnail Image
            _buildThumbnail(item),

            // Top and Bottom gradients
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.black45, Colors.transparent, Colors.black54],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),

            // Top-left Title & Source Tag
            Positioned(
              left: 10,
              top: 10,
              right: 60,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.65),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      item.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: (item.sourceType == 'online'
                              ? const Color(0xFF0277BD)
                              : (item.sourceType == 'preset'
                                  ? const Color(0xFFE65100)
                                  : const Color(0xFF2E7D32)))
                          .withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          item.sourceType == 'online'
                              ? PhosphorIconsRegular.globe
                              : (item.sourceType == 'preset'
                                  ? PhosphorIconsRegular.puzzlePiece
                                  : PhosphorIconsRegular.image),
                          color: Colors.white,
                          size: 10,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          item.sourcePlatform,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Top-right piece count badge or progress
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
                    if (item.progressPercent > 0 && !item.isCompleted) ...[
                      Text(
                        '${item.progressPercent}%',
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
                        '${item.difficulty.pieceCount}',
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

            // Center Play or Checkmark
            if (item.isCompleted)
              const Center(
                child: CircleAvatar(
                  backgroundColor: Color(0xCC2E7D32),
                  radius: 20,
                  child: Icon(PhosphorIconsBold.check, color: Colors.white, size: 24),
                ),
              )
            else if (item.progressPercent == 0)
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
              ),

            // Bottom Progress Bar if in progress
            if (item.progressPercent > 0 && !item.isCompleted)
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: item.progressPercent / 100.0,
                    minHeight: 4,
                    backgroundColor: Colors.white38,
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF81C784)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(CustomPuzzleItem item) {
    return AppCachedImage(
      imagePathOrUrl: item.imagePathOrUrl,
      fit: BoxFit.cover,
      targetWidth: 360,
      targetHeight: 360,
      errorWidget: Image.asset(assetSamples[0], fit: BoxFit.cover),
    );
  }

  Widget _buildTopActionCard({
    required String title,
    required String subtitle,
    required Widget iconWidget,
    required List<Color> gradientColors,
    required Color borderColor,
    required Color textColor,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          height: 66,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: gradientColors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor, width: 1.2),
            boxShadow: const [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 4,
                offset: Offset(0, 1.5),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: Colors.white.withValues(alpha: 0.85),
                child: iconWidget,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.black54,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
