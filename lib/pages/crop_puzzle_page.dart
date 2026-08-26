import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/game_repository.dart';
import '../data/models/custom_puzzle_item.dart';
import '../logic/image_upscaler.dart';
import '../logic/puzzle_model.dart';

enum CropRatio {
  square('1:1 正方形', 1.0, 1080, 1080, PuzzleAspectRatio.square1x1, PhosphorIconsBold.square),
  portrait2x3('2:3 竖屏', 2 / 3, 960, 1440, PuzzleAspectRatio.portrait2x3, PhosphorIconsBold.rectangle),
  landscape3x2('3:2 横屏', 3 / 2, 1440, 960, PuzzleAspectRatio.landscape3x2, PhosphorIconsBold.rectangle),
  portrait3x4('3:4 竖屏', 3 / 4, 1080, 1440, PuzzleAspectRatio.portrait3x4, PhosphorIconsBold.rectangle),
  landscape4x3('4:3 横屏', 4 / 3, 1440, 1080, PuzzleAspectRatio.landscape4x3, PhosphorIconsBold.rectangle);

  const CropRatio(this.label, this.ratio, this.targetWidth, this.targetHeight, this.aspectRatio, this.icon);
  final String label;
  final double ratio; // width / height
  final double targetWidth;
  final double targetHeight;
  final PuzzleAspectRatio aspectRatio;
  final IconData icon;
}

/// Interactive photo cropping & puzzle creation page with large adaptive viewport and 5 standard aspect ratios.
class CropPuzzlePage extends StatefulWidget {
  const CropPuzzlePage({
    super.key,
    required this.rawBytes,
    this.sourceType = 'gallery',
    this.sourcePlatform = '本地相册',
    this.sourceUrl,
  });

  final Uint8List rawBytes;
  final String sourceType;
  final String sourcePlatform;
  final String? sourceUrl;

  static Future<CustomPuzzleItem?> push(
    BuildContext context,
    Uint8List bytes, {
    String sourceType = 'gallery',
    String sourcePlatform = '本地相册',
    String? sourceUrl,
  }) {
    return Navigator.of(context).push<CustomPuzzleItem>(
      MaterialPageRoute(
        builder: (_) => CropPuzzlePage(
          rawBytes: bytes,
          sourceType: sourceType,
          sourcePlatform: sourcePlatform,
          sourceUrl: sourceUrl,
        ),
      ),
    );
  }

  @override
  State<CropPuzzlePage> createState() => _CropPuzzlePageState();
}

class _CropPuzzlePageState extends State<CropPuzzlePage> {
  final TransformationController _transformController = TransformationController();
  final TextEditingController _titleController =
      TextEditingController(text: '我的自制拼图');

  CropRatio _selectedRatio = CropRatio.square;
  late PuzzleDifficulty _selectedDifficulty;
  ui.Image? _decodedImage;
  bool _isSaving = false;
  bool _needsResetMatrix = false;

  @override
  void initState() {
    super.initState();
    final defaultTiers = _selectedRatio.aspectRatio.tiers;
    _selectedDifficulty = defaultTiers.firstWhere(
      (t) => t.difficulty.recommended,
      orElse: () => defaultTiers[0],
    ).difficulty;
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    final codec = await ui.instantiateImageCodec(widget.rawBytes);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() {
        _decodedImage = frame.image;
        // Automatically suggest closest ratio matching the uploaded photo
        final detected = PuzzleAspectRatio.fromSize(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        );
        _selectedRatio = CropRatio.values.firstWhere(
          (c) => c.aspectRatio == detected,
          orElse: () => CropRatio.square,
        );
        final tiers = _selectedRatio.aspectRatio.tiers;
        _selectedDifficulty = tiers.firstWhere(
          (t) => t.difficulty.recommended,
          orElse: () => tiers[0],
        ).difficulty;
        _needsResetMatrix = true;
      });
    }
  }

  @override
  void dispose() {
    _transformController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  Size _calculateBaseSize(Size viewportSize, ui.Image image) {
    final boxW = viewportSize.width;
    final boxH = viewportSize.height;
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    if (boxW <= 0 || boxH <= 0 || imgW <= 0 || imgH <= 0) {
      return viewportSize;
    }
    final baseScale = max(boxW / imgW, boxH / imgH);
    return Size(imgW * baseScale, imgH * baseScale);
  }

  /// 计算最大允许缩放倍率，限制不能放大超过原图原本物理分辨率
  double _calculateMaxScale(Size viewportSize, ui.Image? image) {
    if (image == null || viewportSize.width <= 0 || viewportSize.height <= 0) {
      return 1.0;
    }
    final boxW = viewportSize.width;
    final boxH = viewportSize.height;
    final imgW = image.width.toDouble();
    final imgH = image.height.toDouble();
    if (boxW <= 0 || boxH <= 0 || imgW <= 0 || imgH <= 0) {
      return 1.0;
    }
    final baseScale = max(boxW / imgW, boxH / imgH);
    if (baseScale <= 0) return 1.0;
    return max(1.0, 1.0 / baseScale);
  }

  Matrix4 _getInitialMatrix(Size viewportSize, ui.Image? image) {
    if (image == null || viewportSize.width <= 0 || viewportSize.height <= 0) {
      return Matrix4.identity();
    }
    final baseSize = _calculateBaseSize(viewportSize, image);
    final initTx = (viewportSize.width - baseSize.width) / 2.0;
    final initTy = (viewportSize.height - baseSize.height) / 2.0;
    return Matrix4.identity()..setTranslationRaw(initTx, initTy, 0.0);
  }

  void _onRatioChanged(CropRatio ratio) {
    setState(() {
      _selectedRatio = ratio;
      _needsResetMatrix = true;
      final tiers = ratio.aspectRatio.tiers;
      _selectedDifficulty = tiers.firstWhere(
        (t) => t.difficulty.recommended,
        orElse: () => tiers[0],
      ).difficulty;
    });
  }

  void _resetTransform(Size viewportSize) {
    if (_decodedImage != null) {
      _transformController.value = _getInitialMatrix(viewportSize, _decodedImage);
    } else {
      _transformController.value = Matrix4.identity();
    }
  }

  void _handlePointerScroll(PointerScrollEvent event, Size viewportSize, Size baseSize) {
    final matrix = _transformController.value;
    final currentScale = matrix.getMaxScaleOnAxis();

    // 限制最大缩放不超过原图原本分辨率
    final maxAllowedScale = _calculateMaxScale(viewportSize, _decodedImage);

    // Smooth stepless 4% delta zoom factor per scroll notch
    final factor = event.scrollDelta.dy < 0 ? 1.04 : 0.96;
    final targetScale = (currentScale * factor).clamp(1.0, maxAllowedScale);
    if ((targetScale - currentScale).abs() < 0.0001) return;

    final actualFactor = targetScale / currentScale;
    final localPos = event.localPosition;

    final currentTx = matrix.storage[12];
    final currentTy = matrix.storage[13];

    final newTx = localPos.dx - (localPos.dx - currentTx) * actualFactor;
    final newTy = localPos.dy - (localPos.dy - currentTy) * actualFactor;

    final boxW = viewportSize.width;
    final boxH = viewportSize.height;
    final scaledW = baseSize.width * targetScale;
    final scaledH = baseSize.height * targetScale;

    final minTx = boxW - scaledW;
    const maxTx = 0.0;
    final minTy = boxH - scaledH;
    const maxTy = 0.0;

    final clampedTx = newTx.clamp(minTx, maxTx);
    final clampedTy = newTy.clamp(minTy, maxTy);

    final newMatrix = Matrix4.diagonal3Values(targetScale, targetScale, 1.0)
      ..setTranslationRaw(clampedTx, clampedTy, 0.0);

    _transformController.value = newMatrix;
  }

  Future<void> _saveAndCreate(Size viewportSize) async {
    if (_decodedImage == null || _isSaving) return;
    setState(() => _isSaving = true);

    try {
      final matrix = _transformController.value;
      final currentScale = matrix.getMaxScaleOnAxis();

      final imgW = _decodedImage!.width.toDouble();
      final imgH = _decodedImage!.height.toDouble();

      // 1. 视口与基础映射
      final baseSize = _calculateBaseSize(viewportSize, _decodedImage!);
      final baseScale = baseSize.width / imgW;

      // 2. 精准计算当前视口裁切框在原图上的实际物理像素尺寸 (Natural Crop Dimensions)
      final realCropW = viewportSize.width / (baseScale * currentScale);
      final realCropH = viewportSize.height / (baseScale * currentScale);

      // 3. 短边最大 2160 上限限制 (4K 视网膜安全线，防止超大图引起显存暴涨)
      const maxShortSide = 2160.0;
      final shortSide = min(realCropW, realCropH);
      double targetW = realCropW;
      double targetH = realCropH;

      if (shortSide > maxShortSide) {
        final factor = maxShortSide / shortSide;
        targetW = realCropW * factor;
        targetH = realCropH * factor;
      }

      final targetWidthInt = max(1, targetW.round());
      final targetHeightInt = max(1, targetH.round());

      // 4. 离屏 Canvas 高质量重采样导出
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        ui.Rect.fromLTWH(0, 0, targetWidthInt.toDouble(), targetHeightInt.toDouble()),
      );

      // 视口到目标画布的导出缩放因子
      final exportFactor = targetWidthInt / viewportSize.width;
      canvas.scale(exportFactor, exportFactor);

      // 应用手势平移与缩放矩阵
      canvas.transform(matrix.storage);

      final paint = Paint()
        ..filterQuality = ui.FilterQuality.high
        ..isAntiAlias = true;

      canvas.drawImageRect(
        _decodedImage!,
        ui.Rect.fromLTWH(0, 0, imgW, imgH),
        ui.Rect.fromLTWH(0, 0, baseSize.width, baseSize.height),
        paint,
      );

      final croppedImage = await recorder.endRecording().toImage(
        targetWidthInt,
        targetHeightInt,
      );

      final byteData = await croppedImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw Exception('图片导出失败');
      Uint8List pngBytes = byteData.buffer.asUint8List();

      // 5. 低分辨率智能判定：若实际裁切像素短边 <= 750 或 长边 <= 1000，调用非 AI 超分辨率管线进行 2x 增强
      if (ImageUpscaler.shouldUpscale(
        width: targetWidthInt,
        height: targetHeightInt,
      )) {
        pngBytes = await ImageUpscaler.upscaleBytes(
          bytes: pngBytes,
          scale: 2.0,
          enableDenoise: true,
          denoiseStrength: 0.25,
          enableSharpen: true,
          sharpness: 0.45,
        );
      }

      final dir = await getApplicationSupportDirectory();
      final customDir = Directory('${dir.path}/custom_puzzles');
      if (!await customDir.exists()) {
        await customDir.create(recursive: true);
      }

      final fileName = 'puzzle_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File('${customDir.path}/$fileName');
      await file.writeAsBytes(pngBytes);

      final customItem = CustomPuzzleItem(
        id: 'ugc_${DateTime.now().millisecondsSinceEpoch}',
        title: _titleController.text.trim().isEmpty ? '我的自制拼图' : _titleController.text.trim(),
        imagePathOrUrl: file.path,
        isLocalFile: true,
        difficulty: _selectedDifficulty,
        createdAt: DateTime.now(),
        sourceType: widget.sourceType,
        sourcePlatform: widget.sourcePlatform,
        sourceUrl: widget.sourceUrl,
      );

      await GameRepository.instance.addCustomPuzzle(customItem);

      if (mounted) {
        Navigator.of(context).pop(customItem);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Size _currentViewportSize = Size.zero;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentTiers = _selectedRatio.aspectRatio.tiers;
    final targetRatio = _selectedRatio.ratio;

    return Scaffold(
      backgroundColor: const Color(0xFF181818),
      appBar: AppBar(
        backgroundColor: const Color(0xFF181818),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          '裁剪与自制拼图',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ),
      body: Stack(
        children: [
          Column(
        children: [
          const SizedBox(height: 8),

          // Standard 5 Aspect Ratios Horizontal Scroll Bar
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (final ratio in CropRatio.values) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      avatar: Icon(
                        ratio.icon,
                        size: 16,
                        color: _selectedRatio == ratio ? Colors.white : Colors.white70,
                      ),
                      label: Text(ratio.label),
                      selected: _selectedRatio == ratio,
                      selectedColor: const Color(0xFF2E7D32),
                      backgroundColor: const Color(0xFF2C2C2C),
                      labelStyle: TextStyle(
                        color: _selectedRatio == ratio ? Colors.white : Colors.white70,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                      ),
                      onSelected: (selected) {
                        if (selected) _onRatioChanged(ratio);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 10),

          // Large Interactive Cropping Viewport
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxW = max(50.0, constraints.maxWidth - 32);
                final maxH = max(50.0, constraints.maxHeight - 36);

                double boxW, boxH;
                if (targetRatio >= maxW / maxH) {
                  boxW = maxW;
                  boxH = boxW / targetRatio;
                } else {
                  boxH = maxH;
                  boxW = boxH * targetRatio;
                }

                final viewportSize = Size(boxW, boxH);
                _currentViewportSize = viewportSize;

                final baseSize = _decodedImage != null
                    ? _calculateBaseSize(viewportSize, _decodedImage!)
                    : viewportSize;

                if (_needsResetMatrix && _decodedImage != null) {
                  _needsResetMatrix = false;
                  _transformController.value = _getInitialMatrix(viewportSize, _decodedImage);
                }

                final maxAllowedScale = _calculateMaxScale(viewportSize, _decodedImage);

                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: boxW,
                        height: boxH,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF81C784), width: 2.5),
                          boxShadow: const [
                            BoxShadow(color: Colors.black87, blurRadius: 18),
                          ],
                        ),
                        child: _decodedImage != null
                            ? Stack(
                                children: [
                                  Positioned.fill(
                                    child: MouseRegion(
                                      cursor: SystemMouseCursors.grab,
                                      child: Listener(
                                        onPointerSignal: (event) {
                                          if (event is PointerScrollEvent) {
                                            _handlePointerScroll(event, viewportSize, baseSize);
                                          }
                                        },
                                        child: InteractiveViewer(
                                          key: ValueKey('$_selectedRatio-${viewportSize.width.toStringAsFixed(1)}-${viewportSize.height.toStringAsFixed(1)}'),
                                          transformationController: _transformController,
                                          minScale: 1.0,
                                          maxScale: maxAllowedScale,
                                          boundaryMargin: EdgeInsets.zero,
                                          clipBehavior: Clip.none,
                                          constrained: false,
                                          child: SizedBox(
                                            width: baseSize.width,
                                            height: baseSize.height,
                                            child: RawImage(
                                              image: _decodedImage,
                                              fit: BoxFit.fill,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  // Compact Top-Right Scale Percentage Pill (Click to reset 100% & center)
                                  Positioned(
                                    top: 10,
                                    right: 10,
                                    child: ValueListenableBuilder<Matrix4>(
                                      valueListenable: _transformController,
                                      builder: (context, matrix, _) {
                                        final scalePercent = (matrix.getMaxScaleOnAxis() * 100).round();
                                        final initMatrix = _getInitialMatrix(viewportSize, _decodedImage);
                                        final isChanged = scalePercent > 100 ||
                                            (matrix.storage[12] - initMatrix.storage[12]).abs() > 1.0 ||
                                            (matrix.storage[13] - initMatrix.storage[13]).abs() > 1.0;
                                        return Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            onTap: isChanged ? () => _resetTransform(viewportSize) : null,
                                            borderRadius: BorderRadius.circular(16),
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withValues(alpha: 0.65),
                                                borderRadius: BorderRadius.circular(16),
                                                border: Border.all(
                                                  color: isChanged ? const Color(0xFF81C784) : Colors.white24,
                                                  width: 1.2,
                                                ),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    isChanged ? PhosphorIconsBold.arrowsOutCardinal : PhosphorIconsRegular.magnifyingGlass,
                                                    size: 13,
                                                    color: isChanged ? const Color(0xFF81C784) : Colors.white70,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    '$scalePercent%',
                                                    style: TextStyle(
                                                      color: isChanged ? const Color(0xFF81C784) : Colors.white,
                                                      fontSize: 11.5,
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                  if (isChanged) ...[
                                                    const SizedBox(width: 4),
                                                    const Icon(PhosphorIconsBold.arrowCounterClockwise, size: 11, color: Colors.white70),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              )
                            : const Center(child: CircularProgressIndicator(color: Colors.white)),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(PhosphorIconsBold.handGrabbing, size: 13, color: Colors.white54),
                          SizedBox(width: 5),
                          Text(
                            '按住拖动调整裁切位置 · 双指或滚轮缩放',
                            style: TextStyle(color: Colors.white54, fontSize: 11.5),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),

          // Configuration Bottom Sheet
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: '自制关卡名称',
                    prefixIcon: Icon(PhosphorIconsBold.pencilSimple),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                    ),
                    contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      '选择规格',
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE3F2FD),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '正方形切片 · ${_selectedRatio.aspectRatio.label}',
                        style: const TextStyle(fontSize: 10.5, color: Color(0xFF0D47A1), fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final tier in currentTiers) ...[
                        ChoiceChip(
                          label: Text(tier.difficulty.label),
                          selected: _selectedDifficulty.pieceCount == tier.difficulty.pieceCount,
                          selectedColor: const Color(0xFFE8F5E9),
                          labelStyle: TextStyle(
                            color: _selectedDifficulty.pieceCount == tier.difficulty.pieceCount
                                ? const Color(0xFF2E7D32)
                                : Colors.black87,
                            fontWeight: FontWeight.bold,
                          ),
                          onSelected: (selected) {
                            if (selected) setState(() => _selectedDifficulty = tier.difficulty);
                          },
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: _isSaving ? null : () => _saveAndCreate(_currentViewportSize),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(PhosphorIconsBold.checkCircle),
                    label: Text(
                      _isSaving ? '正在保存...' : '保存自制关卡',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      if (_isSaving)
        Positioned.fill(
          child: Container(
            color: Colors.black.withValues(alpha: 0.65),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    color: Color(0xFF81C784),
                    strokeWidth: 3,
                  ),
                  SizedBox(height: 16),
                  Text(
                    '正在优化画质并生成自制关卡...',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  ),
);
  }
}
