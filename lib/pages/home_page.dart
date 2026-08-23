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
  PuzzleDifficulty _difficulty = PuzzleDifficulty.presets[2]; // 4x4 recommended
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
      // User closed picker, ignore
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
              decoration: const InputDecoration(
                hintText: 'https://...jpg/png',
                labelText: '图片 URL',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '注意：Web 平台要求图片服务器允许跨域 (CORS)',
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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.extension, color: Colors.indigoAccent),
            SizedBox(width: 8),
            Text('异形拼图 Jigsaw Puzzle'),
          ],
        ),
        centerTitle: false,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            shrinkWrap: true,
            children: [
              AspectRatio(
                aspectRatio: 16 / 10,
                child: Card(
                  elevation: 3,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_imageBytes != null)
                        Image.memory(_imageBytes!, fit: BoxFit.cover)
                      else
                        const Center(child: CircularProgressIndicator()),
                      if (_loading)
                        const ColoredBox(
                          color: Colors.black45,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '选择难度',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final d in PuzzleDifficulty.presets)
                    ChoiceChip(
                      label: Text(d.label),
                      selected: _difficulty == d,
                      onSelected: (selected) {
                        if (selected) setState(() => _difficulty = d);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                '选择图源',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed:
                        _loading ? null : () async => await _pickRandomSample(),
                    icon: const Icon(Icons.shuffle),
                    label: const Text('随机精选'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loading
                        ? null
                        : () =>
                            _loadFrom(GallerySource(), errorHint: '选择图片失败'),
                    icon: const Icon(Icons.photo_library),
                    label: const Text('相册导入'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loading ? null : _showUrlDialog,
                    icon: const Icon(Icons.cloud_download),
                    label: const Text('网络链接'),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: _imageBytes == null ? null : _startGame,
                icon: const Icon(Icons.play_arrow),
                label: Text(
                  '开始拼图（${_difficulty.label}）',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
