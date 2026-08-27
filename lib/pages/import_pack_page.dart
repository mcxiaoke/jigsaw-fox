import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import '../logic/content/app_content.dart';
import '../logic/content/models/puzzle_pack_item.dart';

/// 全屏扩展图包导入界面 (支持本地文件选择与网络 URL 下载)
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

  static const String _sampleTestUrl = 'http://192.168.1.118/data/www/game/test/packs/cyberpunk_with_manifest.zip';
  static const String _samplePureUrl = 'http://192.168.1.118/data/www/game/test/packs/cats_pure_images.zip';

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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('选择文件失败: $e')),
        );
      }
    }
  }

  Future<void> _startImport() async {
    final localPath = _localPathController.text.trim();
    final networkUrl = _networkUrlController.text.trim();

    if (localPath.isEmpty && networkUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请选择本地 ZIP 文件或输入网络下载地址')),
      );
      return;
    }

    setState(() {
      _isImporting = true;
      _statusMessage = localPath.isNotEmpty ? '正在解压并解析本地图包...' : '正在下载并解压网络图包...';
    });

    try {
      PuzzlePackItem pack;
      if (localPath.isNotEmpty) {
        pack = await AppContent.instance.packs.importFromLocalZip(localPath);
      } else {
        pack = await AppContent.instance.packs.importFromNetworkZip(networkUrl);
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('成功导入《${pack.title}》(共 ${pack.levelCount} 关)'),
          backgroundColor: const Color(0xFF2E7D32),
        ),
      );

      // 导入成功，自动关闭全屏界面并返回结果
      Navigator.of(context).pop(pack);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('导入失败: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('导入扩展图包 (.zip)', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部提示卡片
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFA5D6A7)),
              ),
              child: const Row(
                children: [
                  Icon(PhosphorIconsFill.info, color: Color(0xFF2E7D32), size: 22),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '支持导入任意包含 JPG/PNG/WebP 图片的 ZIP 压缩包；导入后将自动生成独立合辑，可随时整包删除。',
                      style: TextStyle(fontSize: 12.5, color: Color(0xFF1B5E20), height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 方式一：本地文件浏览
            _buildSectionHeader('📁 方式一：从本地文件选择'),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _localPathController,
                    readOnly: true,
                    decoration: InputDecoration(
                      hintText: '点击右侧按钮选择 .zip 文件',
                      hintStyle: const TextStyle(fontSize: 13, color: Colors.grey),
                      filled: true,
                      fillColor: Colors.grey.shade100,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey.shade300),
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
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),

            // 方式二：网络下载 URL
            _buildSectionHeader('🌐 方式二：输入网络下载地址'),
            const SizedBox(height: 10),
            TextField(
              controller: _networkUrlController,
              enabled: !_isImporting,
              decoration: InputDecoration(
                hintText: 'http://example.com/puzzle_pack.zip',
                hintStyle: const TextStyle(fontSize: 13, color: Colors.grey),
                filled: true,
                fillColor: Colors.grey.shade100,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                suffixIcon: _networkUrlController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(() => _networkUrlController.clear()),
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
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

            // 快捷填充测试 URL
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  avatar: const Icon(PhosphorIconsRegular.lightning, size: 14, color: Color(0xFFE65100)),
                  label: const Text('测试包: 赛博霓虹', style: TextStyle(fontSize: 11.5)),
                  backgroundColor: const Color(0xFFFFF3E0),
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
                  avatar: const Icon(PhosphorIconsRegular.lightning, size: 14, color: Color(0xFF0277BD)),
                  label: const Text('测试包: 纯图片猫咪', style: TextStyle(fontSize: 11.5)),
                  backgroundColor: const Color(0xFFE1F5FE),
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

            // 开始导入主按钮
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _isImporting ? null : _startImport,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 2,
                ),
                child: _isImporting
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _statusMessage,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
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
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 14.5,
        fontWeight: FontWeight.bold,
        color: Colors.black87,
      ),
    );
  }
}
