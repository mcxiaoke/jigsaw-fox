import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../data/game_repository.dart';
import '../../data/models/custom_puzzle_item.dart';
import '../../logic/content/app_content.dart';
import '../../logic/content/models/puzzle_pack_item.dart';
import '../../logic/download_manager.dart';
import '../../logic/image_source.dart';
import '../../widgets/app_cached_image.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../../widgets/downloaded_drawer_sheet.dart';
import '../crop_puzzle_page.dart';
import '../game_page.dart';
import '../import_pack_page.dart';
import '../online_image_picker_page.dart';
import '../pack_levels_page.dart';

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
      title: '自制拼图 · 难度选择',
      savedProgressPercent: item.isCompleted ? null : item.progressPercent,
      sourcePlatform: item.displaySource,
      sourceUrl: item.sourceUrl,
      onDelete: () async {
        await _repo.deleteCustomPuzzle(item.id);
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已删除自制拼图')),
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
              // 1. Top UGC Creation Action Cards (4 compact cards in 2x2 grid or horizontal wrap)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          // 1.1 Left: Local Gallery
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

                          // 1.2 Right: Import Pack (.zip)
                          Expanded(
                            child: _buildTopActionCard(
                              title: '导入关卡包',
                              subtitle: 'ZIP 扩展包',
                              iconWidget: const Icon(PhosphorIconsFill.downloadSimple, color: Color(0xFF00796B), size: 18),
                              gradientColors: const [Color(0xFFE0F2F1), Color(0xFFB2DFDB)],
                              borderColor: const Color(0xFF80CBC4),
                              textColor: const Color(0xFF004D40),
                              onTap: () async {
                                final pack = await ImportPackPage.push(context);
                                if (pack != null && mounted) {
                                  setState(() {});
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          // 1.3 Material Box (素材库)
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

                          // 1.4 Online Search
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
                    ],
                  ),
                ),
              ),

              // 2. Imported Packs Section (若有已导入扩展包，每行一个大 Card 展示，与活动风格对齐)
              ValueListenableBuilder<List<PuzzlePackItem>>(
                valueListenable: AppContent.instance.packs.packsNotifier,
                builder: (context, packs, _) {
                  if (packs.isEmpty) {
                    return const SliverToBoxAdapter(child: SizedBox.shrink());
                  }
                  return SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                '已导入扩展包',
                                style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold),
                              ),
                              Text(
                                '${packs.length} 个扩展包',
                                style: const TextStyle(fontSize: 12.5, color: Colors.black54),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: packs.length,
                            separatorBuilder: (ctx, i) => const SizedBox(height: 14),
                            itemBuilder: (ctx, idx) {
                              final pack = packs[idx];
                              return _buildLargePackCard(pack);
                            },
                          ),
                          const SizedBox(height: 6),
                        ],
                      ),
                    ),
                  );
                },
              ),

              // 3. Section Header for Custom Puzzles
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '自制关卡',
                        style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '共 ${customList.length} 个关卡',
                        style: const TextStyle(fontSize: 12.5, color: Colors.black54),
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
    final isNetwork = item.displaySource == '网络';

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

            // Top-left Source Badge Only (相册 / 网络，无假标题)
            Positioned(
              left: 10,
              top: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (isNetwork ? const Color(0xFF0277BD) : const Color(0xFF2E7D32))
                      .withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isNetwork ? PhosphorIconsRegular.globe : PhosphorIconsRegular.image,
                      color: Colors.white,
                      size: 11,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      item.displaySource,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
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

  Widget _buildLargePackCard(PuzzlePackItem pack) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E7EB), width: 1),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Cover Image with Overlays
          Stack(
            children: [
              SizedBox(
                height: 140,
                width: double.infinity,
                child: AppCachedImage(
                  imagePathOrUrl: pack.coverPath,
                  fit: BoxFit.cover,
                  targetWidth: 600,
                  targetHeight: 300,
                ),
              ),
              // Gradient Overlay
              Positioned.fill(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.black45, Colors.transparent, Colors.black54],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              ),
              // Top-left Pack Badge
              Positioned(
                left: 12,
                top: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2E7D32),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(PhosphorIconsFill.package, color: Colors.white, size: 13),
                      SizedBox(width: 4),
                      Text(
                        '扩展合辑',
                        style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
              // Top-right Source Badge
              Positioned(
                right: 12,
                top: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${pack.displaySource} • ${pack.displayFileSize}',
                    style: const TextStyle(color: Colors.white70, fontSize: 10.5),
                  ),
                ),
              ),
              // Bottom Title on Cover
              Positioned(
                left: 14,
                right: 14,
                bottom: 12,
                child: Text(
                  pack.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),

          // 2. Pack Description & Action Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pack.description.isNotEmpty ? pack.description : '精选拼图扩展关卡合辑',
                        style: const TextStyle(color: Colors.black54, fontSize: 12, height: 1.3),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F5E9),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '共 ${pack.levelCount} 关',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF2E7D32),
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  icon: const Icon(PhosphorIconsBold.play, size: 14),
                  label: const Text('进入挑战'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  onPressed: () => PackLevelsPage.push(context, pack),
                ),
              ],
            ),
          ),
        ],
      ),
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
