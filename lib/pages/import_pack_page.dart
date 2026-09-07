import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/logic/content/models/puzzle_pack_item.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:jigsawpuzzle/widgets/game_toast.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

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
          message: t.importPack.pickFailed(error: e),
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
        message: t.importPack.hintPickFile,
        type: GameToastType.warning,
      );
      return;
    }

    setState(() {
      _isImporting = true;
      _statusMessage = localPath.isNotEmpty
          ? t.importPack.extractingLocal
          : t.importPack.downloadingNet;
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
        message: t.importPack.imported(
          title: pack.title,
          count: pack.levelCount,
        ),
        type: GameToastType.success,
      );

      // Import success: auto-close fullscreen page and return result
      Navigator.of(context).pop(pack);
    } catch (e) {
      if (mounted) {
        GameToast.show(
          context,
          message: t.importPack.importFailedToast(error: e),
          type: GameToastType.error,
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
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);

    return Scaffold(
      backgroundColor: palette.surface,
      appBar: AppBar(
        backgroundColor: palette.surface,
        foregroundColor: palette.primaryText,
        elevation: 0,
        title: Text(
          t.importPack.appbarTitle,
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
                      t.importPack.infoBanner,
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
            _buildSectionHeader(t.importPack.methodLocal, palette, styles),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _localPathController,
                    readOnly: true,
                    style: TextStyle(color: palette.primaryText, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: t.importPack.browseHint,
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
                  label: Text(t.importPack.browse),
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
            _buildSectionHeader(t.importPack.methodNetwork, palette, styles),
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
                            setState(_networkUrlController.clear),
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
                  label: Text(
                    t.importPack.testChip1,
                    style: const TextStyle(fontSize: 11.5),
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
                  label: Text(
                    t.importPack.testChip2,
                    style: const TextStyle(fontSize: 11.5),
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
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            PhosphorIconsFill.downloadSimple,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            t.importPack.startImport,
                            style: const TextStyle(
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
