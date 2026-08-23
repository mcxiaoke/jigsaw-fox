import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../logic/image_source.dart';
import '../logic/puzzle_model.dart';
import 'game_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  PuzzleDifficulty _difficulty = PuzzleDifficulty.values[1];
  Uint8List? _imageBytes;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _pickRandomSample();
  }

  Future<void> _pickRandomSample() async {
    final source = AssetSource(
      assetSamples[DateTime.now().millisecondsSinceEpoch % assetSamples.length],
    );
    final bytes = await source.loadBytes();
    if (mounted) setState(() => _imageBytes = bytes);
  }

  Future<void> _loadFrom(PuzzleSource source, {String? errorHint}) async {
    setState(() => _loading = true);
    try {
      final bytes = await source.loadBytes();
      if (mounted) setState(() => _imageBytes = bytes);
    } on UserCancelledException {
      // user closed the picker, nothing to do
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorHint ?? '加载失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showUrlDialog() async {
    final controller =
        TextEditingController(text: 'https://picsum.photos/1200/900');
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('网络图片'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration:
                  const InputDecoration(hintText: 'https://...jpg/png'),
            ),
            const SizedBox(height: 8),
            Text(
              '注意：Web 平台要求图片服务器允许跨域(CORS)',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (url != null && url.isNotEmpty) {
      await _loadFrom(NetworkSource(url), errorHint: '下载失败，请检查网络或 URL');
    }
  }

  void _startGame() {
    final bytes = _imageBytes;
    if (bytes == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GamePage(imageBytes: bytes, difficulty: _difficulty),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Jigsaw Puzzle 拼图')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(16),
            shrinkWrap: true,
            children: [
              AspectRatio(
                aspectRatio: 4 / 3,
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_imageBytes != null)
                        Image.memory(_imageBytes!, fit: BoxFit.cover)
                      else
                        const Center(child: CircularProgressIndicator()),
                      if (_loading)
                        const ColoredBox(
                          color: Colors.black38,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SegmentedButton<PuzzleDifficulty>(
                segments: [
                  for (final d in PuzzleDifficulty.values)
                    ButtonSegment(value: d, label: Text(d.label)),
                ],
                selected: {_difficulty},
                onSelectionChanged: (selection) =>
                    setState(() => _difficulty = selection.first),
              ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: [
                  OutlinedButton.icon(
                    onPressed:
                        _loading ? null : () async => await _pickRandomSample(),
                    icon: const Icon(Icons.shuffle),
                    label: const Text('随机示例'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loading
                        ? null
                        : () =>
                            _loadFrom(GallerySource(), errorHint: '选择图片失败'),
                    icon: const Icon(Icons.photo_library),
                    label: const Text('相册选择'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _showUrlDialog,
                    icon: const Icon(Icons.cloud_download),
                    label: const Text('网络图片'),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _imageBytes == null ? null : _startGame,
                icon: const Icon(Icons.extension),
                label: Text(
                  '开始拼图（${_difficulty.label} · ${_difficulty.pieceCount} 块）',
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
