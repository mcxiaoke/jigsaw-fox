import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../logic/content/app_content.dart';
import '../logic/content/models/puzzle_pack_item.dart';
import '../theme/app_palette.dart';
import '../theme/app_text_styles.dart';
import '../widgets/game_toast.dart';

/// Fullscreen extended puzzle pack import page (supports local file selection and network URL download).
class ImportPackPage extends StatefulWidget {
  const ImportPackPage({super.key});

  static Future<PuzzlePackItem?> push(BuildContext context) {
    return Navigator.of(context).push<PuzzlePackItem>(
      MaterialPageRoute(builder: (_) => const ImportPackPage()),
    );
  }

  @override
  State<ImportPackPage> createState() => _ImportPackPageState();
}

class _ImportPackPageState extends State<ImportPackPage> {
  final _localPathController = TextEditingController();
  final _networkUrlController = TextEditingController();

  bool _isImporting = false;
  String _statusMessage = '';

  static const String _sampleTestUrl =
      'http://192.168.1.118/data/www/game/test/packs/cyberpunk_with_manifest.zip';
  static const String _samplePureUrl =
      'http://192.168.1.118/data/www/game/test/packs/cats_pure_images.zip';

  @override
  void dispose() {
    _localPathController.dispose();
    _networkUrlController.dispose();
    super.dispose();
  }

  Future<void> _pickLocalZip() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );

      if (result != null && result.files.single.path != null) {
        setState(() {
          _localPathController.text = result.files.single.path!;
          _networkUrlController.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        GameToast.show(
          context,
          message: '选择文件失败: $e',
          type: GameToastType.error,
        );
      }
    }
  }

  Future<void> _startImport() async {
    final localPath = _localPathController.text.trim();
    final networkUrl = _networkUrlController.text.trim();

    if (localPath.isEmpty && networkUrl.isEmpty) {
      GameToast.show(
        context,
        message: '请选择本地 ZIP 文件或输入网络下载地址',
        type: GameToastType.warning,
      );
      return;
    }

    setState(() {
      _isImporting = true;
      _statusMessage = localPath.isNotEmpty
          ? '正在解压并解析本地图包...'
          : '正在下载并解压网络图包...';
    });

    try {
      PuzzlePackItem pack;
      if (localPath.isNotEmpty) {
        pack = await AppContent.instance.packs.importFromLocalZip(localPath);
      } else {
        pack = await AppContent.instance.packs.importFromNetworkZip(networkUrl);
      }

      if (!mounted) return;

      GameToast.show(
        context,
        message: '成功导入《${pack.title}》(共 ${pack.levelCount} 关)',
        type: GameToastType.success,
      );

      // Import success: auto-close fullscreen page and return result
      Navigator.of(context).pop(pack);
    } catch (e) {
      if (mounted) {
        GameToast.show(context, message: '导入失败: $e', type: GameToastType.error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
          _statusMessage = '';
        });
      }
    }
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
        elevation: 0,
        title: Text(
          '导入扩展图包 (.zip)',
          style: styles.h3.copyWith(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Info banner
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: palette.brand.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: palette.brand.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(PhosphorIconsFill.info, color: palette.brand, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '支持导入任意包含 JPG/PNG/WebP 图片的 ZIP 压缩包；导入后将自动生成独立合辑，可随时整包删除。',
                      style: styles.body.copyWith(
                        color: palette.primaryText,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Method 1: Local file
            _buildSectionHeader('方式一：从本地文件选择', palette, styles),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _localPathController,
                    readOnly: true,
                    style: TextStyle(color: palette.primaryText, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '点击右侧按钮选择 .zip 文件',
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: palette.disabledText,
                      ),
                      filled: true,
                      fillColor: palette.surfaceContainerLow,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: palette.divider),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: palette.divider),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: _isImporting ? null : _pickLocalZip,
                  icon: const Icon(PhosphorIconsRegular.folderOpen, size: 16),
                  label: const Text('浏览...'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: palette.brand,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),

            // Method 2: Network URL
            _buildSectionHeader('方式二：输入网络下载地址', palette, styles),
            const SizedBox(height: 10),
            TextField(
              controller: _networkUrlController,
              enabled: !_isImporting,
              style: TextStyle(color: palette.primaryText, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'http://example.com/puzzle_pack.zip',
                hintStyle: TextStyle(fontSize: 13, color: palette.disabledText),
                filled: true,
                fillColor: palette.surfaceContainerLow,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                suffixIcon: _networkUrlController.text.isNotEmpty
                    ? IconButton(
                        icon: Icon(
                          Icons.clear,
                          size: 18,
                          color: palette.secondaryText,
                        ),
                        onPressed: () =>
                            setState(() => _networkUrlController.clear()),
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: palette.divider),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: palette.divider),
                ),
              ),
              onChanged: (_) {
                if (_localPathController.text.isNotEmpty) {
                  _localPathController.clear();
                }
                setState(() {});
              },
            ),
            const SizedBox(height: 8),

            // Quick-fill test URL chips
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  avatar: Icon(
                    PhosphorIconsRegular.lightning,
                    size: 14,
                    color: palette.warning,
                  ),
                  label: const Text(
                    '测试包: 赛博霓虹',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  backgroundColor: palette.warning.withValues(alpha: 0.12),
                  onPressed: _isImporting
                      ? null
                      : () {
                          setState(() {
                            _networkUrlController.text = _sampleTestUrl;
                            _localPathController.clear();
                          });
                        },
                ),
                ActionChip(
                  avatar: Icon(
                    PhosphorIconsRegular.lightning,
                    size: 14,
                    color: palette.info,
                  ),
                  label: const Text(
                    '测试包: 纯图片猫咪',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  backgroundColor: palette.info.withValues(alpha: 0.12),
                  onPressed: _isImporting
                      ? null
                      : () {
                          setState(() {
                            _networkUrlController.text = _samplePureUrl;
                            _localPathController.clear();
                          });
                        },
                ),
              ],
            ),
            const SizedBox(height: 36),

            // Start import button
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _isImporting ? null : _startImport,
                style: ElevatedButton.styleFrom(
                  backgroundColor: palette.brand,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 2,
                ),
                child: _isImporting
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _statusMessage,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(PhosphorIconsFill.downloadSimple, size: 20),
                          SizedBox(width: 8),
                          Text(
                            '开始导入并解析',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    String title,
    AppPalette palette,
    AppTextStyles styles,
  ) {
    return Text(
      title,
      style: styles.body.copyWith(
        fontSize: 14.5,
        fontWeight: FontWeight.bold,
        color: palette.primaryText,
      ),
    );
  }
}
