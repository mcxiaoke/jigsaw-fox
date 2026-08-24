import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../data/game_repository.dart';
import '../data/models/custom_puzzle_item.dart';
import '../logic/puzzle_model.dart';

enum CropRatio {
  square('1:1 正方形', 1.0, 1080, 1080),
  portrait('3:4 竖屏', 3 / 4, 1080, 1440),
  landscape('4:3 横屏', 4 / 3, 1440, 1080);

  const CropRatio(this.label, this.ratio, this.targetWidth, this.targetHeight);
  final String label;
  final double ratio; // width / height
  final double targetWidth;
  final double targetHeight;
}

/// Interactive photo cropping & puzzle creation page with large adaptive viewport and standard aspect ratios.
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
  PuzzleDifficulty _selectedDifficulty = PuzzleDifficulty.presets[0]; // default 3x3 for fast play
  ui.Image? _decodedImage;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    final codec = await ui.instantiateImageCodec(widget.rawBytes);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() => _decodedImage = frame.image);
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

      canvas.drawImageRect(
        _decodedImage!,
        srcRect,
        dstRect,
        ui.Paint()
          ..filterQuality = ui.FilterQuality.high
          ..isAntiAlias = true,
      );

      final picture = recorder.endRecording();
      final croppedUiImage =
          await picture.toImage(targetW.toInt(), targetH.toInt());
      final byteData =
          await croppedUiImage.toByteData(format: ui.ImageByteFormat.png);
      final pngBytes = byteData!.buffer.asUint8List();

      // Save PNG bytes to application sandbox
      final docsDir = await getApplicationDocumentsDirectory();
      final customDir = Directory('${docsDir.path}/custom_puzzles');
      if (!await customDir.exists()) {
        await customDir.create(recursive: true);
      }

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final savedFilePath = '${customDir.path}/custom_$timestamp.png';
      final file = File(savedFilePath);
      await file.writeAsBytes(pngBytes, flush: true);

      final title = _titleController.text.trim().isEmpty
          ? '自制拼图 $timestamp'
          : _titleController.text.trim();

      final newItem = CustomPuzzleItem(
        id: 'custom_$timestamp',
        title: title,
        imagePathOrUrl: savedFilePath,
        isLocalFile: true,
        difficulty: _selectedDifficulty,
        createdAt: DateTime.now(),
      );

      await GameRepository.instance.addCustomPuzzle(newItem);

      if (mounted) {
        Navigator.of(context).pop(newItem);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存自制关卡失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.sizeOf(context);

    // Calculate maximum comfortable viewport size based on screen dimensions
    final maxAvailW = min(media.width - 32, 540.0);
    final maxAvailH = max(240.0, media.height - 380.0);

    double boxW, boxH;
    if (maxAvailW / _selectedRatio.ratio <= maxAvailH) {
      boxW = maxAvailW;
      boxH = boxW / _selectedRatio.ratio;
    } else {
      boxH = maxAvailH;
      boxW = boxH * _selectedRatio.ratio;
    }

    final viewportSize = Size(boxW, boxH);

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      appBar: AppBar(
        title: const Text('裁剪与创建自制拼图', style: TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xFF121212),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_isSaving)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                ),
              ),
            )
          else
            TextButton(
              onPressed: () => _saveAndCreate(viewportSize),
              child: const Text(
                '保存',
                style: TextStyle(
                  color: Color(0xFF81C784),
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 10),

          // Standard Aspect Ratio Selector (1:1, 3:4, 4:3)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<CropRatio>(
              segments: const [
                ButtonSegment(
                  value: CropRatio.square,
                  label: Text('1:1 正方形'),
                  icon: Icon(Icons.crop_square, size: 18),
                ),
                ButtonSegment(
                  value: CropRatio.portrait,
                  label: Text('3:4 竖屏'),
                  icon: Icon(Icons.crop_portrait, size: 18),
                ),
                ButtonSegment(
                  value: CropRatio.landscape,
                  label: Text('4:3 横屏'),
                  icon: Icon(Icons.crop_landscape, size: 18),
                ),
              ],
              selected: {_selectedRatio},
              onSelectionChanged: (set) => _onRatioChanged(set.first),
              style: SegmentedButton.styleFrom(
                backgroundColor: const Color(0xFF2C2C2C),
                selectedBackgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white70,
                selectedForegroundColor: Colors.white,
              ),
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
                    prefixIcon: Icon(Icons.edit_outlined),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                    ),
                    contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '选择规格',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final diff in [
                        PuzzleDifficulty.presets[0], // 3x3 (9)
                        PuzzleDifficulty.presets[1], // 3x4 (12)
                        PuzzleDifficulty.presets[2], // 4x4 (16)
                        PuzzleDifficulty.presets[5], // 6x6 (36)
                        PuzzleDifficulty.presets[7], // 8x8 (64)
                        PuzzleDifficulty.presets[8], // 10x10 (100)
                      ]) ...[
                        ChoiceChip(
                          label: Text(diff.label),
                          selected: _selectedDifficulty == diff,
                          onSelected: (selected) {
                            if (selected) setState(() => _selectedDifficulty = diff);
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
                    icon: const Icon(Icons.check_circle_outline),
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
