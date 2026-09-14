import 'package:flutter/material.dart';
import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';
import 'package:jigsawpuzzle/update/update_models.dart';
import 'package:jigsawpuzzle/update/update_service.dart';

/// 自动更新弹窗组件
class UpdateDialog extends StatefulWidget {
  const UpdateDialog({
    required this.checkResult,
    super.key,
  });

  final UpdateCheckResult checkResult;

  /// 便捷静态展示方法
  static Future<void> show(BuildContext context, UpdateCheckResult result) {
    return showDialog<void>(
      context: context,
      barrierDismissible: !result.isForceUpdate,
      builder: (ctx) => UpdateDialog(checkResult: result),
    );
  }

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _isDownloading = false;
  double _progress = 0;
  String _statusText = '';
  String? _errorMessage;

  UpdateManifest get manifest => widget.checkResult.manifest!;
  PlatformUpdateInfo get platformInfo => widget.checkResult.platformInfo!;
  bool get isForce => widget.checkResult.isForceUpdate;

  Translations get t => LocaleSettings.instance.currentTranslations;

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  Future<void> _startUpdate() async {
    setState(() {
      _isDownloading = true;
      _errorMessage = null;
      _progress = 0;
      _statusText = t.settings.updateDownloading(percent: '0');
    });

    try {
      final file = await UpdateService.instance.downloadAndVerify(
        platformInfo,
        onProgress: (received, total) {
          if (mounted && total > 0) {
            final percent = (received / total * 100).clamp(0, 100).toInt();
            setState(() {
              _progress = received / total;
              _statusText = t.settings.updateDownloading(percent: '$percent');
            });
          }
        },
      );

      if (!mounted) return;
      setState(() {
        _statusText = t.settings.updateInstalling;
      });

      await UpdateService.instance.executeInstall(file);
    } on Object catch (e) {
      AppLogger.update.severe('Update process failed: $e');
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final locale = LocaleSettings.currentLocale.languageCode;
    final notes = manifest.notesForLocale(locale);

    return PopScope(
      canPop: !isForce && !_isDownloading,
      child: Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: palette.surface,
        elevation: 6,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部标题与图标
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: palette.brand.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Icon(
                          Icons.system_update_rounded,
                          color: palette.brand,
                          size: 24,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.settings.updateDialogTitle(
                              version: 'v${manifest.version}',
                            ),
                            style: styles.h3.copyWith(fontSize: 18),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            t.settings.updateDialogSize(
                              size: _formatSize(platformInfo.size),
                            ),
                            style: styles.caption.copyWith(
                              color: palette.secondaryText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 18),

                // 更新日志展示区
                if (notes.isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 180),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: palette.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: palette.divider),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        notes,
                        style: styles.body.copyWith(
                          color: palette.primaryText,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                ],

                // 进度与错误提示
                if (_isDownloading) ...[
                  LinearProgressIndicator(
                    value: _progress > 0 ? _progress : null,
                    backgroundColor: palette.surfaceContainer,
                    valueColor: AlwaysStoppedAnimation<Color>(palette.brand),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _statusText,
                    style: styles.caption.copyWith(
                      color: palette.secondaryText,
                    ),
                  ),
                  const SizedBox(height: 14),
                ],

                if (_errorMessage != null) ...[
                  Text(
                    t.settings.updateInstallFailed(error: _errorMessage!),
                    style: styles.caption.copyWith(color: palette.error),
                  ),
                  const SizedBox(height: 14),
                ],

                // 底部操作按钮
                if (!_isDownloading)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (!isForce) ...[
                        TextButton(
                          onPressed: () async {
                            await UpdateService.instance.skipVersion(
                              manifest.versionCode,
                            );
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                          child: Text(
                            t.settings.updateBtnIgnore,
                            style: styles.captionBold.copyWith(
                              color: palette.disabledText,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(
                            t.settings.updateBtnLater,
                            style: styles.body.copyWith(
                              color: palette.secondaryText,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      ElevatedButton(
                        onPressed: _startUpdate,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: palette.brand,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                        ),
                        child: Text(
                          t.settings.updateBtnNow,
                          style: styles.bodyBold.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
