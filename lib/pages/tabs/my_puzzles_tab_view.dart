import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../data/game_repository.dart';
import '../../data/models/custom_puzzle_item.dart';
import '../../data/resume_helper.dart';
import '../../data/snapshot_store.dart';
import '../../logic/content/app_content.dart';
import '../../logic/content/models/puzzle_pack_item.dart';
import '../../logic/download_manager.dart';
import '../../logic/image_source.dart';
import '../../services/webview_service.dart';
import '../../theme/app_palette.dart';
import '../../theme/app_text_styles.dart';
import '../../widgets/app_cached_image.dart';
import '../../widgets/choose_difficulty_sheet.dart';
import '../../widgets/downloaded_drawer_sheet.dart';
import '../../widgets/game_toast.dart';
import '../crop_puzzle_page.dart';
import '../game_page.dart';
import '../import_pack_page.dart';
import '../online_image_picker_page.dart';
import '../pack_levels_page.dart';

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
      final imported = await DownloadManager.instance.importFromLocalFiles(
        files,
      );
      if (!mounted || imported.isEmpty) return;
      if (files.length == 1) {
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
          setState(() {});
        }
      } else {
        if (mounted) {
          GameToast.show(
            context,
            icon: PhosphorIconsFill.archive,
            message: '已成功导入 ${imported.length} 张图片到素材库',
            type: GameToastType.success,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        GameToast.show(
          context,
          icon: PhosphorIconsRegular.warning,
          message: '选择图片失败: $e',
          type: GameToastType.error,
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
    final canonicalId = GameRepository.canonicalForCustom(item.id);
    final handled = await ResumeHelper.tryHandleResumeFlow(
      context: context,
      canonicalId: canonicalId,
      fallbackDifficulty: item.difficulty,
      isCompleted: item.isCompleted,
      title: '自制拼图',
      imageBytes: bytes,
      onClearRepo: (k) => _repo.updateCustomProgress(
        id: item.id,
        progressPercent: 0,
        snapshotJson: null,
      ),
      onPushGame: (diff, jsonStr) async {
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: bytes,
              difficulty: diff,
              customId: item.id,
              initialSnapshotJson: jsonStr,
            ),
          ),
        );
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
    final displayPercent = ResumeHelper.displayProgress(
      progress,
      item.progressPercent,
      item.isCompleted,
    );
    if (!mounted) return;
    await ChooseDifficultySheet.show(
      context: context,
      imageBytes: bytes,
      initialDifficulty: item.difficulty,
      completedPieceCounts: item.completedPieceCounts.toSet(),
      canonicalId: canonicalId,
      title: item.title,
      imagePathOrUrl: item.imagePathOrUrl,
      savedProgressPercent: displayPercent == 0 ? null : displayPercent,
      sourcePlatform: item.displaySource,
      sourceUrl: item.sourceUrl,
      onDelete: () async {
        await _repo.deleteCustomPuzzle(item.id);
        if (mounted) {
          setState(() {});
        }
      },
      onResetProgress: () async {
        final prog = await ResumeHelper.loadProgress(canonicalId);
        if (prog.activeDifficultyKey.isNotEmpty) {
          await ResumeHelper.clearResume(canonicalId, prog.activeDifficultyKey);
        }
        await _repo.updateCustomProgress(
          id: item.id,
          progressPercent: 0,
          snapshotJson: null,
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
        final dkey = SnapshotStore.difficultyKeyFor(diff);
        // 快照由 SnapshotStore 文件级管理；Item 旧快照字段
        // 遗留 fallback 已移除（改造后恒为 null，清理阶段 §11）
        final snapJson = await SnapshotStore.instance.loadJsonString(
          canonicalId,
          dkey,
        );
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GamePage(
              imageBytes: bytes,
              difficulty: diff,
              customId: item.id,
              initialSnapshotJson: snapJson,
            ),
          ),
        );
        setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);

    return ValueListenableBuilder<List<CustomPuzzleItem>>(
      valueListenable: _repo.customPuzzlesNotifier,
      builder: (context, customList, _) {
        return RefreshIndicator(
          onRefresh: () async => setState(() {}),
          color: palette.brand,
          child: CustomScrollView(
            slivers: [
              // Action Cards Row 1
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _buildTopActionCard(
                              title: '相册选图',
                              subtitle: '批量导入',
                              icon: _loading
                                  ? SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        color: palette.brand,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      PhosphorIconsFill.camera,
                                      color: palette.brand,
                                      size: 20,
                                    ),
                              palette: palette,
                              styles: styles,
                              onTap: _loading ? null : _createFromGallery,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildTopActionCard(
                              title: '导入关卡包',
                              subtitle: 'ZIP 扩展包',
                              icon: Icon(
                                PhosphorIconsFill.downloadSimple,
                                color: palette.info,
                                size: 18,
                              ),
                              palette: palette,
                              styles: styles,
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
                          Expanded(
                            child: ValueListenableBuilder(
                              valueListenable:
                                  DownloadManager.instance.itemsNotifier,
                              builder: (context, materialItems, _) {
                                return _buildTopActionCard(
                                  title: '素材库',
                                  subtitle: '${materialItems.length} 张素材',
                                  icon: Icon(
                                    PhosphorIconsFill.archive,
                                    color: palette.warning,
                                    size: 18,
                                  ),
                                  palette: palette,
                                  styles: styles,
                                  onTap: () async {
                                    await DownloadedDrawerSheet.show(context);
                                  },
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildTopActionCard(
                              title: '在线搜图',
                              subtitle: '海量图库',
                              icon: Icon(
                                PhosphorIconsFill.globeHemisphereWest,
                                color: palette.success,
                                size: 18,
                              ),
                              palette: palette,
                              styles: styles,
                              onTap: () async {
                                if (!WebViewService.isOnlineSearchAvailable) {
                                  GameToast.show(
                                    context,
                                    icon: PhosphorIconsRegular.warningCircle,
                                    message: '当前系统未安装 WebView2 运行时，无法使用在线搜图',
                                    type: GameToastType.warning,
                                  );
                                  return;
                                }
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
                              Text(
                                '已导入扩展包',
                                style: styles.h3.copyWith(fontSize: 16.5),
                              ),
                              Text(
                                '${packs.length} 个扩展包',
                                style: styles.caption,
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          ListView.separated(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: packs.length,
                            separatorBuilder: (ctx, i) =>
                                const SizedBox(height: 14),
                            itemBuilder: (ctx, idx) {
                              final pack = packs[idx];
                              return _buildLargePackCard(pack, palette, styles);
                            },
                          ),
                          const SizedBox(height: 6),
                        ],
                      ),
                    ),
                  );
                },
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('自制关卡', style: styles.h3.copyWith(fontSize: 16.5)),
                      Text('共 ${customList.length} 个关卡', style: styles.caption),
                    ],
                  ),
                ),
              ),
              if (customList.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: Column(
                        children: [
                          const Text('🦊', style: TextStyle(fontSize: 44)),
                          const SizedBox(height: 8),
                          Text(
                            '小狐狸抱着空篮子等你制作拼图',
                            style: styles.caption.copyWith(fontSize: 14),
                          ),
                          const SizedBox(height: 4),
                          Text('点击上方「相册选图」或「素材库」开始制作吧！', style: styles.caption),
                        ],
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 14,
                          childAspectRatio: 1.0,
                        ),
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final item = customList[index];
                      return _buildCustomGridCard(item, palette, styles);
                    }, childCount: customList.length),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 28)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCustomGridCard(
    CustomPuzzleItem item,
    AppPalette palette,
    AppTextStyles styles,
  ) {
    final isNetwork = item.displaySource == '网络';
    return InkWell(
      onTap: () => _openCustom(item),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: palette.divider, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildThumbnail(item),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.35),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.45),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            Positioned(
              left: 10,
              top: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (isNetwork ? palette.info : palette.brand).withValues(
                    alpha: 0.85,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isNetwork
                          ? PhosphorIconsRegular.globe
                          : PhosphorIconsRegular.image,
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
            Positioned(
              top: 10,
              right: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: palette.surface.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item.progressPercent > 0 && !item.isCompleted) ...[
                      Text(
                        '${item.progressPercent}%',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: palette.brand,
                        ),
                      ),
                    ] else ...[
                      Icon(
                        PhosphorIconsFill.puzzlePiece,
                        size: 12,
                        color: palette.secondaryText,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${item.difficulty.pieceCount}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: palette.primaryText,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (item.isCompleted)
              Center(
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: palette.success.withValues(alpha: 0.8),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    PhosphorIconsBold.check,
                    color: palette.surface,
                    size: 24,
                  ),
                ),
              )
            else if (item.progressPercent == 0)
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: palette.brand,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        PhosphorIconsFill.play,
                        color: palette.surface,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '开始',
                        style: TextStyle(
                          color: palette.surface,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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
                    backgroundColor: Colors.white.withValues(alpha: 0.3),
                    valueColor: AlwaysStoppedAnimation<Color>(palette.success),
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
      errorWidget: Image.asset(assetSamples[0], fit: BoxFit.cover),
    );
  }

  Widget _buildLargePackCard(
    PuzzlePackItem pack,
    AppPalette palette,
    AppTextStyles styles,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.divider, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              // 封面卡实际高度仅 140px，默认 card 档位（360），
              // 与图包详情页 header 共用同一份缩略图
              SizedBox(
                height: 140,
                width: double.infinity,
                child: AppCachedImage(
                  imagePathOrUrl: pack.coverPath,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.black.withValues(alpha: 0.35),
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.45),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.0, 0.45, 1.0],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                top: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: palette.brand,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        PhosphorIconsFill.package,
                        color: palette.surface,
                        size: 13,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '扩展合辑',
                        style: TextStyle(
                          color: palette.surface,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                right: 12,
                top: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${pack.displaySource} • ${pack.displayFileSize}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10.5,
                    ),
                  ),
                ),
              ),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pack.description.isNotEmpty
                            ? pack.description
                            : '精选拼图扩展关卡合辑',
                        style: styles.caption.copyWith(height: 1.3),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: palette.brand.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '共 ${pack.levelCount} 关',
                          style: TextStyle(
                            fontSize: 11,
                            color: palette.brand,
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
                    backgroundColor: palette.brand,
                    foregroundColor: palette.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
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
    required Widget icon,
    required AppPalette palette,
    required AppTextStyles styles,
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
            color: palette.surfaceContainer,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.divider, width: 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: palette.brand.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(child: icon),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: styles.bodyBold.copyWith(fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      style: styles.caption.copyWith(fontSize: 10),
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
