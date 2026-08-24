import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/game_repository.dart';
import '../data/models/custom_puzzle_item.dart';
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
  const CropPuzzlePage({super.key, required this.rawBytes});

  final Uint8List rawBytes;

  static Future<CustomPuzzleItem?> push(BuildContext context, Uint8List bytes) {
    return Navigator.of(context).push<CustomPuzzleItem>(
      MaterialPageRoute(builder: (_) => CropPuzzlePage(rawBytes: bytes)),
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
      });
    }
  }

  @override
  void dispose() {
    _transformController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  void _onRatioChanged(CropRatio ratio) {
    setState(() {
      _selectedRatio = ratio;
      _transformController.value = Matrix4.identity();
      final tiers = ratio.aspectRatio.tiers;
      _selectedDifficulty = tiers.firstWhere(
        (t) => t.difficulty.recommended,
        orElse: () => tiers[0],
      ).difficulty;
    });
  }

  Future<void> _saveAndCreate(Size viewportSize) async {
    if (_decodedImage == null || _isSaving) return;
    setState(() => _isSaving = true);

    try {
      final matrix = _transformController.value;
      final scale = matrix.getMaxScaleOnAxis();
      final translation = matrix.getTranslation();

      final targetW = _selectedRatio.targetWidth;
      final targetH = _selectedRatio.targetHeight;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(
        recorder,
        ui.Rect.fromLTWH(0, 0, targetW, targetH),
      );

      final imgW = _decodedImage!.width.toDouble();
      final imgH = _decodedImage!.height.toDouble();

      // Viewport geometry
      final boxW = viewportSize.width;
      final boxH = viewportSize.height;

      // Base scale fitted into viewport box
      final scaleX = boxW / imgW;
      final scaleY = boxH / imgH;
      final baseScale = max(scaleX, scaleY);
      final currentTotalScale = baseScale * scale;

      final srcLeft = (-translation.x) / currentTotalScale;
      final srcTop = (-translation.y) / currentTotalScale;
      final srcW = boxW / currentTotalScale;
      final srcH = boxH / currentTotalScale;

      final srcRect = ui.Rect.fromLTWH(
        srcLeft.clamp(0.0, max(0.0, imgW - 1.0)),
        srcTop.clamp(0.0, max(0.0, imgH - 1.0)),
        srcW.clamp(1.0, imgW),
        srcH.clamp(1.0, imgH),
      );
      final dstRect = ui.Rect.fromLTWH(0, 0, targetW, targetH);

      final paint = Paint()
        ..filterQuality = ui.FilterQuality.high
        ..isAntiAlias = true;

      canvas.drawImageRect(_decodedImage!, srcRect, dstRect, paint);
      final croppedImage = await recorder.endRecording().toImage(
        targetW.toInt(),
        targetH.toInt(),
      );

      final byteData = await croppedImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw Exception('图片导出失败');
      final pngBytes = byteData.buffer.asUint8List();

      final dir = await getApplicationDocumentsDirectory();
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.of(context).size;

    // Viewport Max Dimensions in Crop Area
    final maxW = screenSize.width - 32;
    final maxH = screenSize.height * 0.44;

    final targetRatio = _selectedRatio.ratio;
    double boxW, boxH;

    if (targetRatio >= maxW / maxH) {
      boxW = maxW;
      boxH = boxW / targetRatio;
    } else {
      boxH = maxH;
      boxW = boxH * targetRatio;
    }

    final viewportSize = Size(boxW, boxH);
    final currentTiers = _selectedRatio.aspectRatio.tiers;

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
        actions: [
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: Column(
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
            child: Center(
              child: Container(
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
                    ? InteractiveViewer(
                        key: ValueKey(_selectedRatio),
                        transformationController: _transformController,
                        minScale: 0.8,
                        maxScale: 5.0,
                        boundaryMargin: const EdgeInsets.all(double.infinity),
                        child: RawImage(
                          image: _decodedImage,
                          fit: BoxFit.cover,
                        ),
                      )
                    : const Center(child: CircularProgressIndicator(color: Colors.white)),
              ),
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
                    onPressed: _isSaving ? null : () => _saveAndCreate(viewportSize),
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
    );
  }
}
